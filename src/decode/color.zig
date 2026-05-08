//! Shared YCbCr→RGB color conversion + chroma upsampling helpers.
//!
//! Both baseline (SOF0) and progressive (SOF2) cleanroom decoders end
//! up with the same shape of output: per-component pixel planes (Y, Cb,
//! Cr at their respective sampling factors) that need to be assembled
//! into interleaved RGB output.
//!
//! Functions here are intentionally **integer-only** (no IEEE754):
//!   - `fancyUpsample` mirrors libjpeg-turbo's IJG fancy upsampling
//!     (jdsample.c h2v2_fancy_upsample, h2v1_fancy_upsample, etc.) —
//!     bilinear-with-rounding for typical 4:2:0/4:2:2 layouts, with
//!     active-frame boundary clamping so MCU-padded chroma never bleeds
//!     into visible pixels.
//!   - `ycbcrRowToRgb` mirrors libjpeg-turbo's jdcolor.c
//!     ycc_rgb_convert: 16-bit SCALEBITS fixed-point with
//!     Cred=91881, Cgreen_cb=-22554, Cgreen_cr=-46802, Cblue=116130,
//!     ONE_HALF=32768. Output is bit-identical to the wrapper.
//!
//! Float arithmetic is avoided per project preference (see
//! `~/.claude/projects/.../memory/feedback_prefer_integer_fixed_point.md`).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{OutOfMemory};

pub inline fn clampSampleI32(v: i32) u8 {
    if (v < 0) return 0;
    if (v > 255) return 255;
    return @intCast(v);
}

/// IJG "fancy" chroma upsampling. `src` is `src_w` × `src_h`; output is
/// `out_w` × `out_h`. `active_w` / `active_h` are the in-frame chroma
/// extents (`<= src_w/src_h`); boundary clamping uses these so MCU-pad
/// chroma never bleeds into visible pixels.
pub fn fancyUpsample(
    allocator: Allocator,
    src: []const u8,
    src_w: u32,
    src_h: u32,
    out_w: u32,
    out_h: u32,
    active_w: u32,
    active_h: u32,
    h_ratio: u32,
    v_ratio: u32,
) Error![]u8 {
    const dst = try allocator.alloc(u8, @as(usize, out_w) * @as(usize, out_h));
    errdefer allocator.free(dst);

    const cw: u32 = @max(active_w, 1);
    const ch: u32 = @max(active_h, 1);
    if (h_ratio == 2 and v_ratio == 2) {
        var cy: u32 = 0;
        while (cy < ch) : (cy += 1) {
            const cy_up: u32 = if (cy == 0) 0 else cy - 1;
            const cy_dn: u32 = if (cy + 1 < ch) cy + 1 else cy;
            var cx: u32 = 0;
            while (cx < cw) : (cx += 1) {
                const cx_lf: u32 = if (cx == 0) 0 else cx - 1;
                const cx_rt: u32 = if (cx + 1 < cw) cx + 1 else cx;
                const c: i32 = src[cy * src_w + cx];
                const c_l: i32 = src[cy * src_w + cx_lf];
                const c_r: i32 = src[cy * src_w + cx_rt];
                const c_u: i32 = src[cy_up * src_w + cx];
                const c_ul: i32 = src[cy_up * src_w + cx_lf];
                const c_ur: i32 = src[cy_up * src_w + cx_rt];
                const c_d: i32 = src[cy_dn * src_w + cx];
                const c_dl: i32 = src[cy_dn * src_w + cx_lf];
                const c_dr: i32 = src[cy_dn * src_w + cx_rt];
                const tl: i32 = (9 * c + 3 * c_l + 3 * c_u + c_ul + 8) >> 4;
                const tr: i32 = (9 * c + 3 * c_r + 3 * c_u + c_ur + 8) >> 4;
                const bl: i32 = (9 * c + 3 * c_l + 3 * c_d + c_dl + 8) >> 4;
                const br: i32 = (9 * c + 3 * c_r + 3 * c_d + c_dr + 8) >> 4;
                const ox: u32 = cx * 2;
                const oy: u32 = cy * 2;
                if (oy < out_h and ox < out_w) dst[oy * out_w + ox] = clampSampleI32(tl);
                if (oy < out_h and ox + 1 < out_w) dst[oy * out_w + ox + 1] = clampSampleI32(tr);
                if (oy + 1 < out_h and ox < out_w) dst[(oy + 1) * out_w + ox] = clampSampleI32(bl);
                if (oy + 1 < out_h and ox + 1 < out_w) dst[(oy + 1) * out_w + ox + 1] = clampSampleI32(br);
            }
        }
        return dst;
    }
    if (h_ratio == 2 and v_ratio == 1) {
        var cy: u32 = 0;
        while (cy < ch and cy < out_h) : (cy += 1) {
            var cx: u32 = 0;
            while (cx < cw) : (cx += 1) {
                const cx_lf: u32 = if (cx == 0) 0 else cx - 1;
                const cx_rt: u32 = if (cx + 1 < cw) cx + 1 else cx;
                const c: i32 = src[cy * src_w + cx];
                const c_l: i32 = src[cy * src_w + cx_lf];
                const c_r: i32 = src[cy * src_w + cx_rt];
                const lf: i32 = (3 * c + c_l + 2) >> 2;
                const rt: i32 = (3 * c + c_r + 2) >> 2;
                const ox: u32 = cx * 2;
                if (ox < out_w) dst[cy * out_w + ox] = clampSampleI32(lf);
                if (ox + 1 < out_w) dst[cy * out_w + ox + 1] = clampSampleI32(rt);
            }
        }
        return dst;
    }
    if (h_ratio == 1 and v_ratio == 2) {
        var cy: u32 = 0;
        while (cy < ch) : (cy += 1) {
            const cy_up: u32 = if (cy == 0) 0 else cy - 1;
            const cy_dn: u32 = if (cy + 1 < ch) cy + 1 else cy;
            var cx: u32 = 0;
            while (cx < cw and cx < out_w) : (cx += 1) {
                const c: i32 = src[cy * src_w + cx];
                const c_u: i32 = src[cy_up * src_w + cx];
                const c_d: i32 = src[cy_dn * src_w + cx];
                const up: i32 = (3 * c + c_u + 2) >> 2;
                const dn: i32 = (3 * c + c_d + 2) >> 2;
                const oy: u32 = cy * 2;
                if (oy < out_h) dst[oy * out_w + cx] = clampSampleI32(up);
                if (oy + 1 < out_h) dst[(oy + 1) * out_w + cx] = clampSampleI32(dn);
            }
        }
        return dst;
    }
    // Fallback: nearest-neighbor for 1×1 or unusual ratios.
    var y: u32 = 0;
    while (y < out_h) : (y += 1) {
        const sy: u32 = @min((y * src_h) / out_h, src_h - 1);
        var x: u32 = 0;
        while (x < out_w) : (x += 1) {
            const sx: u32 = @min((x * src_w) / out_w, src_w - 1);
            dst[y * out_w + x] = src[sy * src_w + sx];
        }
    }
    return dst;
}

/// Per-row YCbCr→RGB. `plane_y/cb/cr` are full-resolution (post-upsample)
/// canvas planes of dimension `canvas_w × canvas_h`. Writes `width*3`
/// bytes of interleaved RGB into `pixels` at row `y`.
pub fn ycbcrRowToRgb(
    plane_y: []const u8,
    plane_cb: []const u8,
    plane_cr: []const u8,
    canvas_w: u32,
    width: u32,
    pixels: []u8,
    y: u32,
) void {
    var x: u32 = 0;
    while (x < width) : (x += 1) {
        const off_in: usize = @as(usize, y) * @as(usize, canvas_w) + @as(usize, x);
        const Y: i32 = @intCast(plane_y[off_in]);
        const Cb: i32 = @as(i32, plane_cb[off_in]) - 128;
        const Cr: i32 = @as(i32, plane_cr[off_in]) - 128;
        const r: i32 = Y + ((Cr * 91881 + 32768) >> 16);
        const g: i32 = Y + ((Cb * -22554 + Cr * -46802 + 32768) >> 16);
        const b: i32 = Y + ((Cb * 116130 + 32768) >> 16);
        const out_off: usize = (@as(usize, y) * @as(usize, width) + @as(usize, x)) * 3;
        pixels[out_off + 0] = clampSampleI32(r);
        pixels[out_off + 1] = clampSampleI32(g);
        pixels[out_off + 2] = clampSampleI32(b);
    }
}
