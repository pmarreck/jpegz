//! Progressive assembly: dequantization, IDCT, upsampling and color output.

const std = @import("std");
const Allocator = std.mem.Allocator;
const errors = @import("../core/errors.zig");
const types = @import("../core/types.zig");
const bitstream = @import("bitstream.zig");
const huffman = @import("huffman.zig");
const idct = @import("idct.zig");
const color = @import("color.zig");
const cmyk_mod = @import("cmyk.zig");
const jpeg_markers = @import("jpeg_markers.zig");
const ZIGZAG = @import("progressive.zig").ZIGZAG;
const FrameInfo = @import("progressive.zig").FrameInfo;
const Error = @import("progressive.zig").Error;

/// Thin wrapper preserving the 8-bit entry-point API. Calls into the
/// comptime-P-generic version below at P=8.
fn assembleProgressive(
    allocator: Allocator,
    frame: *const FrameInfo,
    quant_tables: *const [4]?[64]u16,
    coefs: *[3][]i16,
    blocks_w: *const [3]u32,
    blocks_h: *const [3]u32,
    max_h: u32,
    max_v: u32,
) Error!types.Image {
    return assembleProgressiveGeneric(8, allocator, frame, quant_tables, coefs, blocks_w, blocks_h, max_h, max_v, false);
}

/// Phase 2 of progressive decode, generic over precision P ∈ {8, 12}.
///
/// Inputs: per-component i16 quantized DCT coefficient buffers (the
/// output of Phase 1, which is the multi-scan entropy decoder — its
/// shape is precision-agnostic because the SSSS limits and amplitude
/// ranges are derived from T.81 §F.1.4 / Table F.1 and work for any
/// P in {8, 12} given an i16 storage slot per coefficient).
///
/// Outputs: an `Image` with `bits_per_sample = P`. At P=8 the pixel
/// buffer is `[]u8` and the result is byte-identical to the previous
/// (non-generic) implementation. At P=12 the pixel buffer is `[]u8`
/// holding a host-endian `[]u16` view, range [0, 4095] per sample;
/// consumer reads via `image.pixelsU16()`.
///
/// Per-precision specialization (chosen at comptime, so each
/// instantiation gets one concrete code path with no runtime branch):
///   - IDCT: `idct.idct8x8Generic(P, ...)`
///   - Chroma upsample: `color.fancyUpsample` (P=8) or
///     `color.fancyUpsample12` (P=12)
///   - YCbCr→RGB: `color.ycbcrRowToRgb` (P=8) or `ycbcrRowToRgb12`
///     (P=12)
///
/// 12-bit support is the A3 milestone (2026-05-13). The 8-bit path
/// is unchanged behaviorally.
pub fn assembleProgressiveGeneric(
    comptime P: u8,
    allocator: Allocator,
    frame: *const FrameInfo,
    quant_tables: *const [4]?[64]u16,
    coefs: *[3][]i16,
    blocks_w: *const [3]u32,
    blocks_h: *const [3]u32,
    max_h: u32,
    max_v: u32,
    /// The 3-component frame already holds R,G,B (cmyk.rgbPassthrough).
    rgb_passthrough: bool,
) Error!types.Image {
    const Sample = idct.Sample(P); // u8 for P=8, u16 for P=12.
    const channels: u8 = frame.num_components;
    const width: u32 = frame.width;
    const height: u32 = frame.height;

    var planes: [3][]Sample = .{ &.{}, &.{}, &.{} };
    var plane_w: [3]u32 = .{ 0, 0, 0 };
    var plane_h: [3]u32 = .{ 0, 0, 0 };
    // Armed before the first allocation: a refusal at plane 1 or 2 must
    // free the planes already allocated (empty slices are skipped).
    errdefer {
        var j: usize = 0;
        while (j < channels) : (j += 1) if (planes[j].len > 0) allocator.free(planes[j]);
    }
    var i: usize = 0;
    while (i < channels) : (i += 1) {
        plane_w[i] = blocks_w[i] * 8;
        plane_h[i] = blocks_h[i] * 8;
        planes[i] = try allocator.alloc(Sample, plane_w[i] * plane_h[i]);
    }

    // Per block: dequant in zig-zag space, un-zig-zag, IDCT, copy.
    i = 0;
    while (i < channels) : (i += 1) {
        const comp = &frame.components[i];
        const qt = quant_tables[comp.qt_index] orelse return error.InvalidMarker;
        const bw = blocks_w[i];
        const bh = blocks_h[i];

        var by: u32 = 0;
        while (by < bh) : (by += 1) {
            var bx: u32 = 0;
            while (bx < bw) : (bx += 1) {
                const off: usize = (@as(usize, by) * @as(usize, bw) +
                    @as(usize, bx)) * 64;
                const zz = coefs[i][off .. off + 64];
                // Dequantize and un-zig-zag in i32, as baseline does (and
                // libjpeg's DEQUANTIZE): an i16 coefficient times a 16-bit
                // quantizer always fits, but often not back in an i16.
                var natural: [64]i32 = undefined;
                var n: usize = 0;
                while (n < 64) : (n += 1) {
                    natural[ZIGZAG[n]] = @as(i32, zz[n]) * @as(i32, qt[n]);
                }
                var block_pix: [64]Sample = undefined;
                idct.idct8x8Generic(P, &natural, &block_pix);
                // Copy 8×8 spatial block into plane.
                var py: u32 = 0;
                while (py < 8) : (py += 1) {
                    var px: u32 = 0;
                    while (px < 8) : (px += 1) {
                        const dst_x: u32 = bx * 8 + px;
                        const dst_y: u32 = by * 8 + py;
                        planes[i][dst_y * plane_w[i] + dst_x] = block_pix[py * 8 + px];
                    }
                }
            }
        }
    }

    // Free coefficient buffers (no longer needed). Each slot is emptied as
    // it is freed: the caller still owns `coefs`, and its errdefer frees
    // them again if a later allocation here fails.
    {
        var k: usize = 0;
        while (k < channels) : (k += 1) if (coefs[k].len > 0) {
            allocator.free(coefs[k]);
            coefs[k] = &.{};
        };
    }

    // Allocate output as []u8. For P=8 each sample is 1 byte. For P=12
    // it's 2 bytes (host-endian u16 byte view). Same shape as the
    // baseline 12-bit paths.
    const bytes_per_sample: usize = if (P == 8) 1 else 2;
    const out_samples: usize = @as(usize, width) * @as(usize, height) * @as(usize, channels);
    const pixels = try allocator.alloc(u8, out_samples * bytes_per_sample);
    errdefer allocator.free(pixels);

    if (channels == 1) {
        // Grayscale passthrough — copy Y plane directly into output.
        if (P == 8) {
            var y: u32 = 0;
            while (y < height) : (y += 1) {
                var x: u32 = 0;
                while (x < width) : (x += 1) {
                    pixels[y * width + x] = planes[0][y * plane_w[0] + x];
                }
            }
        } else {
            const out_u16: []align(1) u16 = std.mem.bytesAsSlice(u16, pixels);
            var y: u32 = 0;
            while (y < height) : (y += 1) {
                var x: u32 = 0;
                while (x < width) : (x += 1) {
                    out_u16[y * width + x] = planes[0][y * plane_w[0] + x];
                }
            }
        }
    } else {
        // Three-component path: produce a canvas at MCU resolution
        // (canvas_w/canvas_h), upsample each chroma plane via IJG fancy
        // upsampling so it lines up with Y, then convert row-by-row to
        // RGB using libjpeg-turbo's fixed-point math. Mirrors baseline
        // cleanroom's `assembleOutput` / `decodeScan12Rgb` so the two
        // paths produce byte-equal output for the same coefficient buf.
        const c1 = &frame.components[1];
        const c2 = &frame.components[2];
        const canvas_w: u32 = plane_w[0];
        const canvas_h: u32 = plane_h[0];

        const active_w1: u32 = (width * @as(u32, c1.h_factor) + max_h - 1) / max_h;
        const active_h1: u32 = (height * @as(u32, c1.v_factor) + max_v - 1) / max_v;
        const active_w2: u32 = (width * @as(u32, c2.h_factor) + max_h - 1) / max_h;
        const active_h2: u32 = (height * @as(u32, c2.v_factor) + max_v - 1) / max_v;

        const h_ratio_1: u32 = max_h / @as(u32, c1.h_factor);
        const v_ratio_1: u32 = max_v / @as(u32, c1.v_factor);
        const h_ratio_2: u32 = max_h / @as(u32, c2.h_factor);
        const v_ratio_2: u32 = max_v / @as(u32, c2.v_factor);

        // Upsample helpers diverge by precision; pick at comptime.
        const upsample = if (P == 8) color.fancyUpsample else color.fancyUpsample12;

        const cb_canvas: []const Sample = if (h_ratio_1 == 1 and v_ratio_1 == 1)
            planes[1]
        else
            try upsample(allocator, planes[1], plane_w[1], plane_h[1], canvas_w, canvas_h, active_w1, active_h1, h_ratio_1, v_ratio_1);
        defer if (h_ratio_1 != 1 or v_ratio_1 != 1) allocator.free(@constCast(cb_canvas));

        const cr_canvas: []const Sample = if (h_ratio_2 == 1 and v_ratio_2 == 1)
            planes[2]
        else
            try upsample(allocator, planes[2], plane_w[2], plane_h[2], canvas_w, canvas_h, active_w2, active_h2, h_ratio_2, v_ratio_2);
        defer if (h_ratio_2 != 1 or v_ratio_2 != 1) allocator.free(@constCast(cr_canvas));

        if (rgb_passthrough) {
            // Already R,G,B at canvas resolution: interleave, no transform.
            const out: []align(1) Sample = std.mem.bytesAsSlice(Sample, pixels);
            var y: u32 = 0;
            while (y < height) : (y += 1) {
                var x: u32 = 0;
                while (x < width) : (x += 1) {
                    const o = (y * width + x) * 3;
                    out[o + 0] = planes[0][y * canvas_w + x];
                    out[o + 1] = cb_canvas[y * canvas_w + x];
                    out[o + 2] = cr_canvas[y * canvas_w + x];
                }
            }
        } else if (P == 8) {
            var y: u32 = 0;
            while (y < height) : (y += 1) {
                color.ycbcrRowToRgb(planes[0], cb_canvas, cr_canvas, canvas_w, width, pixels, y);
            }
        } else {
            const pixels_u16: []align(1) u16 = std.mem.bytesAsSlice(u16, pixels);
            var y: u32 = 0;
            while (y < height) : (y += 1) {
                color.ycbcrRowToRgb12(planes[0], cb_canvas, cr_canvas, canvas_w, width, pixels_u16, y);
            }
        }
    }

    var p: usize = 0;
    while (p < channels) : (p += 1) allocator.free(planes[p]);

    return types.Image{
        .pixels = pixels,
        .width = width,
        .height = height,
        .channels = channels,
        .bits_per_sample = P,
        .source_color_space = if (channels == 1) .grayscale else if (rgb_passthrough) .rgb else .ycbcr,
        .layout = if (channels == 1) .grayscale else .rgb,
    };
}
