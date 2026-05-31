//! 4-component (CMYK / YCCK) cleanroom decode helpers.
//!
//! Adobe-Photoshop-style 4-component baseline JPEGs come in two
//! flavors, distinguished by the APP14 (FF EE) marker's
//! `ColorTransform` byte:
//!
//!   - **CMYK** (ColorTransform=0, OR no APP14 present with
//!     num_components==4): the four components ARE C, M, Y, K.
//!     Decode straight through and emit interleaved [C, M, Y, K].
//!
//!   - **YCCK** (ColorTransform=2): the first three components are
//!     Y, Cb, Cr (same shape as 3-comp YCbCr); the fourth is K.
//!     libjpeg-turbo converts YCCK→CMYK internally before emitting
//!     samples, so byte-perfect parity requires the same conversion
//!     here: run YCbCr→RGB on the first three with the same
//!     16-bit SCALEBITS fixed-point constants used by `color.zig`,
//!     then invert (C=255-R, M=255-G, Y=255-B), and pass K
//!     unchanged.
//!
//! No other ColorTransform values are valid for 4-component JPEGs.
//! ColorTransform=1 is YCbCr (3-comp only). Anything outside {0, 2}
//! is treated as raw CMYK per libjpeg-turbo's behavior.
//!
//! Integer-only — same project-wide preference as `color.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../core/types.zig");
const errors = @import("../core/errors.zig");
const color = @import("color.zig");

pub const Error = errors.DecodeError;

/// APP14 ColorTransform values (Adobe APP14 spec byte 11 of payload).
/// `none` = no APP14 marker was seen; treat as raw CMYK for 4-comp,
/// or YCbCr for 3-comp (matches libjpeg-turbo's default).
pub const ColorTransform = enum(u8) {
    cmyk = 0,
    ycbcr = 1,
    ycck = 2,
    /// Sentinel: no APP14 segment was encountered in the marker walk.
    none = 0xFF,
};

/// Parse an Adobe APP14 (FF EE) segment body to extract the
/// ColorTransform byte. Returns `null` if the body doesn't have the
/// Adobe signature or is too short. `body` is the segment payload
/// AFTER the 2-byte length field (12 bytes for a well-formed Adobe
/// APP14).
///
/// Layout (T.81 informative; Adobe TN 5116):
///   bytes  0..5 : "Adobe\0"
///   byte   6    : DCTEncodeVersion (typically 100)
///   bytes  7..8 : APP14Flags0      (u16 BE)
///   bytes  9..10: APP14Flags1      (u16 BE)
///   byte   11   : ColorTransform   (0 = CMYK, 1 = YCbCr, 2 = YCCK)
pub fn parseApp14ColorTransform(body: []const u8) ?ColorTransform {
    if (body.len < 12) return null;
    if (!std.mem.eql(u8, body[0..6], "Adobe\x00")) return null;
    return switch (body[11]) {
        0 => .cmyk,
        1 => .ycbcr,
        2 => .ycck,
        else => .cmyk, // libjpeg-turbo treats unknown as CMYK (raw)
    };
}

/// Same integer fixed-point YCbCr→RGB constants `color.zig` uses
/// (libjpeg-turbo's jdcolor.c ycc_rgb_convert). Centralized here so
/// the YCCK conversion is byte-identical to the 3-comp path's
/// YCbCr→RGB without a cross-module dependency loop.
const FIX_CR_TO_R: i32 = 91881;
const FIX_CB_TO_G: i32 = -22554;
const FIX_CR_TO_G: i32 = -46802;
const FIX_CB_TO_B: i32 = 116130;
const FIX_HALF: i32 = 32768;

inline fn clamp255(v: i32) u8 {
    if (v < 0) return 0;
    if (v > 255) return 255;
    return @intCast(v);
}

/// Assemble 4-component planes into interleaved CMYK pixels.
///
/// `planes` indices: [0]=C-or-Y, [1]=M-or-Cb, [2]=Y-or-Cr, [3]=K.
/// `plane_w` / `plane_h`: per-component canvas (already at output
/// resolution — subsampling is fully resolved before this call by
/// the same per-plane allocation the 3-comp baseline uses).
/// `width` / `height`: the visible image extent (planes may be
/// MCU-padded larger).
///
/// `color_transform == .ycck` → YCbCr→RGB on (Y,Cb,Cr), invert to
/// CMY, pass K. Anything else (`.cmyk` / `.none` / `.ycbcr`) → pass
/// all four through as raw CMYK bytes.
pub fn assemble(
    allocator: Allocator,
    width: u32,
    height: u32,
    plane_w: [4]u32,
    plane_h: [4]u32,
    comp_h: [4]u8,
    comp_v: [4]u8,
    max_h: u32,
    max_v: u32,
    planes: [4][]const u8,
    color_transform: ColorTransform,
) Error!types.Image {
    // Upsample each component to the MCU-padded canvas grid before
    // interleaving — mirrors the 3-component `assembleOutput` recipe
    // exactly (alias full-res planes; IJG fancy-upsample subsampled
    // ones) so subsampled CMYK/YCCK output stays byte-identical to
    // libjpeg-turbo. Without this, a quarter-size Cb/Cr plane indexed
    // at full-canvas coordinates over-reads its backing buffer
    // (validate_gui heap over-read, 2026-05-31).
    const canvas_w: u32 = @max(@max(plane_w[0], plane_w[1]), @max(plane_w[2], plane_w[3]));
    const canvas_h: u32 = @max(@max(plane_h[0], plane_h[1]), @max(plane_h[2], plane_h[3]));
    var canvas_planes: [4][]const u8 = .{ &.{}, &.{}, &.{}, &.{} };
    var canvas_owned: [4]bool = .{ false, false, false, false };
    defer {
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            if (canvas_owned[i]) allocator.free(canvas_planes[i]);
        }
    }
    {
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            const h_ratio: u32 = max_h / @as(u32, comp_h[i]);
            const v_ratio: u32 = max_v / @as(u32, comp_v[i]);
            if (h_ratio == 1 and v_ratio == 1) {
                // Full-resolution component — alias the plane directly.
                canvas_planes[i] = planes[i];
                canvas_owned[i] = false;
            } else {
                // Active in-frame extent: ceil(dim * factor / max). Uses
                // the FRAME dims (not MCU-padded plane dims) so boundary
                // clamping matches libjpeg-turbo.
                const active_w: u32 = (width * @as(u32, comp_h[i]) + max_h - 1) / max_h;
                const active_h: u32 = (height * @as(u32, comp_v[i]) + max_v - 1) / max_v;
                canvas_planes[i] = try color.fancyUpsample(
                    allocator,
                    planes[i],
                    plane_w[i],
                    plane_h[i],
                    canvas_w,
                    canvas_h,
                    active_w,
                    active_h,
                    h_ratio,
                    v_ratio,
                );
                canvas_owned[i] = true;
            }
        }
    }

    const out_len: usize = @as(usize, width) * @as(usize, height) * 4;
    const pixels = try allocator.alloc(u8, out_len);
    errdefer allocator.free(pixels);

    const is_ycck = color_transform == .ycck;

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            // Canvas planes are all `canvas_w × canvas_h`, so a single
            // canvas-stride offset indexes every component safely.
            const in_off: usize = @as(usize, y) * @as(usize, canvas_w) + @as(usize, x);
            const out_off: usize = (@as(usize, y) * @as(usize, width) + @as(usize, x)) * 4;

            if (is_ycck) {
                // Components 0/1/2 are Y/Cb/Cr; convert to RGB via the
                // same 16-bit SCALEBITS fixed-point as color.zig, then
                // invert to CMY. K (component 3) passes through.
                const Y: i32 = @intCast(canvas_planes[0][in_off]);
                const Cb: i32 = @as(i32, canvas_planes[1][in_off]) - 128;
                const Cr: i32 = @as(i32, canvas_planes[2][in_off]) - 128;
                const r: i32 = Y + ((Cr * FIX_CR_TO_R + FIX_HALF) >> 16);
                const g: i32 = Y + ((Cb * FIX_CB_TO_G + Cr * FIX_CR_TO_G + FIX_HALF) >> 16);
                const b: i32 = Y + ((Cb * FIX_CB_TO_B + FIX_HALF) >> 16);
                pixels[out_off + 0] = 255 - clamp255(r);
                pixels[out_off + 1] = 255 - clamp255(g);
                pixels[out_off + 2] = 255 - clamp255(b);
                pixels[out_off + 3] = canvas_planes[3][in_off];
            } else {
                pixels[out_off + 0] = canvas_planes[0][in_off];
                pixels[out_off + 1] = canvas_planes[1][in_off];
                pixels[out_off + 2] = canvas_planes[2][in_off];
                pixels[out_off + 3] = canvas_planes[3][in_off];
            }
        }
    }

    return types.Image{
        .pixels = pixels,
        .width = width,
        .height = height,
        .channels = 4,
        .bits_per_sample = 8,
        .source_color_space = switch (color_transform) {
            .ycck => .ycck,
            .cmyk, .none, .ycbcr => .cmyk,
        },
        .layout = .cmyk,
    };
}

test "parseApp14ColorTransform: YCCK fixture-like body" {
    // 12-byte Adobe APP14 body, ColorTransform=2 (YCCK)
    const body = [_]u8{
        'A', 'd', 'o', 'b', 'e', 0x00, // "Adobe\0"
        100,                            // DCTEncodeVersion
        0, 0,                           // Flags0
        0, 0,                           // Flags1
        2,                              // ColorTransform = YCCK
    };
    try std.testing.expectEqual(ColorTransform.ycck, parseApp14ColorTransform(&body).?);
}

test "parseApp14ColorTransform: CMYK ColorTransform=0" {
    const body = [_]u8{ 'A', 'd', 'o', 'b', 'e', 0x00, 100, 0, 0, 0, 0, 0 };
    try std.testing.expectEqual(ColorTransform.cmyk, parseApp14ColorTransform(&body).?);
}

test "parseApp14ColorTransform: non-Adobe APP14 returns null" {
    const body = [_]u8{ 'A', 'd', 'o', 'b', 'X', 0x00, 100, 0, 0, 0, 0, 2 };
    try std.testing.expectEqual(@as(?ColorTransform, null), parseApp14ColorTransform(&body));
}

test "parseApp14ColorTransform: short body returns null" {
    const body = [_]u8{ 'A', 'd', 'o', 'b' };
    try std.testing.expectEqual(@as(?ColorTransform, null), parseApp14ColorTransform(&body));
}
