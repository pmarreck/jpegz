//! Part of baseline.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;
const errors = @import("../core/errors.zig");
const types = @import("../core/types.zig");
const bitstream = @import("bitstream.zig");
const huffman = @import("huffman.zig");
const idct = @import("idct.zig");
const color = @import("color.zig");
const cmyk_mod = @import("cmyk.zig");
const findings_mod = @import("findings.zig");
const thread_pool = @import("thread_pool.zig");
const jpeg_markers = @import("jpeg_markers.zig");
const builtin = @import("builtin");
const FrameInfo = @import("baseline.zig").FrameInfo;
const Error = @import("baseline.zig").Error;

/// Phase 2: IDCT a single 8×8 block of natural-order coefficients into
/// spatial samples and copy them into `plane` at (block_x_pixels,
/// block_y_pixels). Pure transform — no entropy state, no DC predictor
/// touch — so it's safe to call from a worker thread provided each call
/// reads its own `coeffs` and writes a non-overlapping 8×8 plane region.
pub fn transformBlockToPlane(
    coeffs: *const [64]i32,
    plane: []u8,
    plane_w: u32,
    block_x: u32,
    block_y: u32,
) void {
    var block: [64]u8 = undefined;
    idct.idct8x8(coeffs, &block);
    var by: u32 = 0;
    while (by < 8) : (by += 1) {
        var bx: u32 = 0;
        while (bx < 8) : (bx += 1) {
            const px: u32 = block_x + bx;
            const py: u32 = block_y + by;
            plane[py * plane_w + px] = block[by * 8 + bx];
        }
    }
}

/// Sample a component plane at canvas pixel (x, y) by mapping
/// canvas coords → component coords using the sampling factors.
/// Nearest-neighbor fallback for ratios we don't fancy-upsample.
inline fn sampleComponent(
    plane: []const u8,
    plane_w: u32,
    plane_h: u32,
    canvas_x: u32,
    canvas_y: u32,
    h_factor: u32,
    v_factor: u32,
    max_h: u32,
    max_v: u32,
) u8 {
    var cx: u32 = (canvas_x * h_factor) / max_h;
    var cy: u32 = (canvas_y * v_factor) / max_v;
    if (cx >= plane_w) cx = plane_w - 1;
    if (cy >= plane_h) cy = plane_h - 1;
    return plane[cy * plane_w + cx];
}

fn SampleT(comptime P: u8) type {
    return if (P <= 8) u8 else u16;
}

/// After all blocks are decoded into per-component planes, convert to
/// interleaved output (grayscale or RGB) at canvas resolution, generic over
/// sample precision `P`: P=8 emits `u8` bytes, P=12 emits a host-endian `u16`
/// byte-view. Subsampled chroma is IJG-fancy-upsampled (`color.fancyUpsample` /
/// `fancyUpsample12`) to match libjpeg-turbo's default "fancy upsampling"
/// output (matching is the non-obvious part: without it our pixels diverge by
/// ~mean 0.5–3 from libjpeg in chroma transition zones). For P=8 this is
/// byte-identical to the former u8-only path incl. the thread-pool
/// color-convert fast path; P=12 mirrors the former decodeScan12Gray/Rgb
/// tails. Takes ownership of `planes` (frees them on success).
pub fn assembleOutputT(
    comptime P: u8,
    allocator: Allocator,
    frame: *const FrameInfo,
    channels: u8,
    width: u32,
    height: u32,
    max_h: u32,
    max_v: u32,
    plane_w: [3]u32,
    plane_h: [3]u32,
    planes: *const [3][]SampleT(P),
    pool: ?*thread_pool.Pool,
    rgb_passthrough: bool,
) Error!types.Image {
    const Sample = SampleT(P);
    const out_count: usize = @as(usize, width) * @as(usize, height) * @as(usize, channels);
    const pixels = try allocator.alloc(u8, out_count * @sizeOf(Sample));
    errdefer allocator.free(pixels);

    if (channels == 1) {
        // Grayscale: crop plane[0] to (width × height).
        if (comptime P <= 8) {
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
        // Upsample each component to the canvas grid (max_h × max_v scale)
        // using the IJG fancy filter when the ratio is 2× in either axis;
        // nearest-neighbor otherwise. Producing full-resolution per-component
        // planes once is cheaper than per-pixel interpolation. Luma is at full
        // canvas resolution; reuse its dimensions.
        const canvas_w: u32 = plane_w[0];
        const canvas_h: u32 = plane_h[0];
        var canvas_planes: [3][]const Sample = undefined;
        var canvas_owned: [3]bool = .{ false, false, false };
        var canvas_buffers: [3][]Sample = undefined;
        defer {
            for (canvas_buffers, canvas_owned) |buf, owned| {
                if (owned) allocator.free(buf);
            }
        }
        for (0..3) |ci_idx| {
            const comp = &frame.components[ci_idx];
            const h_ratio: u32 = max_h / @as(u32, comp.h_factor);
            const v_ratio: u32 = max_v / @as(u32, comp.v_factor);
            if (h_ratio == 1 and v_ratio == 1) {
                // No upsampling needed — alias the existing plane.
                canvas_planes[ci_idx] = planes[ci_idx];
                canvas_owned[ci_idx] = false;
            } else {
                // Active in-frame chroma extent: ceil(width * h_factor / max_h)
                // (width here is the FRAME width, not MCU-padded plane width).
                const active_w: u32 = (width * @as(u32, comp.h_factor) + max_h - 1) / max_h;
                const active_h: u32 = (height * @as(u32, comp.v_factor) + max_v - 1) / max_v;
                if (comptime P <= 8) {
                    const buf = try color.fancyUpsample(allocator, planes[ci_idx], plane_w[ci_idx], plane_h[ci_idx], canvas_w, canvas_h, active_w, active_h, h_ratio, v_ratio);
                    canvas_buffers[ci_idx] = buf;
                    canvas_planes[ci_idx] = buf;
                } else {
                    const buf = try color.fancyUpsample12(allocator, planes[ci_idx], plane_w[ci_idx], plane_h[ci_idx], canvas_w, canvas_h, active_w, active_h, h_ratio, v_ratio);
                    canvas_buffers[ci_idx] = buf;
                    canvas_planes[ci_idx] = buf;
                }
                canvas_owned[ci_idx] = true;
            }
        }
        // Color conversion is per-row independent. For P=8 it parallelizes on
        // the shared IDCT thread pool when supplied; P=12 stays sequential.
        if (comptime P <= 8) {
            if (rgb_passthrough) {
                // RGB passthrough — the 3 components are already R,G,B at canvas
                // resolution; interleave directly, no chroma transform (gap D).
                var y: u32 = 0;
                while (y < height) : (y += 1) {
                    var x: u32 = 0;
                    while (x < width) : (x += 1) {
                        const o = (y * width + x) * 3;
                        pixels[o + 0] = canvas_planes[0][y * canvas_w + x];
                        pixels[o + 1] = canvas_planes[1][y * canvas_w + x];
                        pixels[o + 2] = canvas_planes[2][y * canvas_w + x];
                    }
                }
            } else if (pool) |p| {
                var wg: thread_pool.WaitGroup = .{};
                var y: u32 = 0;
                while (y < height) : (y += 1) {
                    p.spawnWg(&wg, color.ycbcrRowToRgb, .{
                        canvas_planes[0],
                        canvas_planes[1],
                        canvas_planes[2],
                        canvas_w,
                        width,
                        pixels,
                        y,
                    });
                }
                p.waitAndWork(&wg);
            } else {
                var y: u32 = 0;
                while (y < height) : (y += 1) {
                    color.ycbcrRowToRgb(canvas_planes[0], canvas_planes[1], canvas_planes[2], canvas_w, width, pixels, y);
                }
            }
        } else {
            const pixels_u16: []align(1) u16 = std.mem.bytesAsSlice(u16, pixels);
            var y: u32 = 0;
            while (y < height) : (y += 1) {
                if (rgb_passthrough) {
                    var x: u32 = 0;
                    while (x < width) : (x += 1) {
                        const o = (y * width + x) * 3;
                        pixels_u16[o + 0] = canvas_planes[0][y * canvas_w + x];
                        pixels_u16[o + 1] = canvas_planes[1][y * canvas_w + x];
                        pixels_u16[o + 2] = canvas_planes[2][y * canvas_w + x];
                    }
                } else {
                    color.ycbcrRowToRgb12(canvas_planes[0], canvas_planes[1], canvas_planes[2], canvas_w, width, pixels_u16, y);
                }
            }
        }
    }

    // Free intermediate planes.
    var p: usize = 0;
    while (p < channels) : (p += 1) allocator.free(planes[p]);

    return types.Image{
        .pixels = pixels,
        .width = width,
        .height = height,
        .channels = channels,
        .bits_per_sample = if (comptime P <= 8) 8 else 12,
        .source_color_space = if (channels == 1) .grayscale else if (rgb_passthrough) .rgb else .ycbcr,
        .layout = if (channels == 1) .grayscale else .rgb,
    };
}

/// u8 entry point preserved for `arith_decode` (SOF9) and any other caller
/// holding `[3][]u8` planes — thin wrapper over `assembleOutputT(8, ...)`.
pub fn assembleOutput(
    allocator: Allocator,
    frame: *const FrameInfo,
    channels: u8,
    width: u32,
    height: u32,
    max_h: u32,
    max_v: u32,
    plane_w: [3]u32,
    plane_h: [3]u32,
    planes: *const [3][]u8,
    pool: ?*thread_pool.Pool,
) Error!types.Image {
    return assembleOutputT(8, allocator, frame, channels, width, height, max_h, max_v, plane_w, plane_h, planes, pool, false);
}
