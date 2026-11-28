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
const fail = @import("baseline.zig").fail;
const emitFinding = @import("baseline.zig").emitFinding;
const FrameInfo = @import("baseline.zig").FrameInfo;
const Error = @import("baseline.zig").Error;
const DecodeOptions = @import("baseline.zig").DecodeOptions;
const walkToNextScan = @import("baseline_markers.zig").walkToNextScan;
const rejectPostCoverageScans = @import("baseline_markers.zig").rejectPostCoverageScans;
const ScanSelection = @import("baseline_markers.zig").ScanSelection;
const ScanTables = @import("baseline_entropy.zig").ScanTables;
const CoefGrid = @import("baseline_entropy.zig").CoefGrid;
const decodeScanEntropy = @import("baseline_entropy.zig").decodeScanEntropy;
const transformBlockRow = @import("baseline_block.zig").transformBlockRow;
const transformBlockToPlane = @import("baseline_output.zig").transformBlockToPlane;
const assembleOutputT = @import("baseline_output.zig").assembleOutputT;

/// Unified scan decoder generic over sample precision `P` (8 or 12),
/// collapsing the former decodeScan / decodeScan12Gray / decodeScan12Rgb
/// triple. The entropy-decode front half (MCU geometry, per-component
/// plane allocation, T.81 §F.2 Huffman + dequant via
/// `decodeBlockCoefficients`) is precision-agnostic and shared. Phase 2
/// (IDCT) splits on a single `comptime P <= 8`: parallel u8 `idct8x8` vs
/// sequential u16 `idct8x8_12`, so the u16 instantiation never compiles the
/// u8-only parallel-IDCT path. The final stage (chroma upsample, YCbCr→RGB,
/// output packing) is shared via `assembleOutputT(P)`; 4-component CMYK/YCCK
/// (P=8 only) goes through `cmyk_mod.assemble`. P=8 is byte-identical to the
/// former decodeScan.
///
/// Sequential frames may split their components across several scans (T.81
/// §A.2, Ns < Nf), with table and restart segments between them. Phase 1
/// therefore runs once per scan into one whole-frame coefficient grid until
/// every component has been coded exactly once; Phases 2 and 3 run once.
/// `entropy_start` is the byte after the first SOS header in `data`.
pub fn decodeScanT(
    comptime P: u8,
    allocator: Allocator,
    data: []const u8,
    entropy_start: usize,
    frame: *FrameInfo,
    first_scan: ScanSelection,
    tables: ScanTables,
    options: DecodeOptions,
    app14_color_transform: cmyk_mod.ColorTransform,
    saw_jfif: bool,
) Error!types.Image {
    const Sample = if (P <= 8) u8 else u16;
    const channels: u8 = frame.num_components;
    const width: u32 = frame.width;
    const height: u32 = frame.height;

    // Compute max h/v sampling factors across all components. These
    // define the MCU size in pixels: max_h*8 wide × max_v*8 tall.
    // Per-component plane is sized at the component's natural
    // resolution: mcu_cols * comp.h_factor * 8 wide, etc.
    //
    // T.81 §A.2.2 carve-out: for a non-interleaved scan (Ns=1), the MCU
    // is always a single 8×8 block regardless of the component's
    // declared H/V factors — those factors are informational only and
    // don't change the entropy stream layout. So we force max_h = max_v
    // = 1 here, which makes the MCU loop iterate one block at a time.
    var max_h: u32 = 1;
    var max_v: u32 = 1;
    if (channels > 1) {
        var i: usize = 0;
        while (i < channels) : (i += 1) {
            const c = &frame.components[i];
            if (@as(u32, c.h_factor) > max_h) max_h = @intCast(c.h_factor);
            if (@as(u32, c.v_factor) > max_v) max_v = @intCast(c.v_factor);
        }
    }
    const mcu_pixel_w: u32 = max_h * 8;
    const mcu_pixel_h: u32 = max_v * 8;
    const mcu_cols: u32 = (width + mcu_pixel_w - 1) / mcu_pixel_w;
    const mcu_rows: u32 = (height + mcu_pixel_h - 1) / mcu_pixel_h;

    // Per-component plane dimensions (at component's natural resolution).
    // For non-interleaved scans (channels==1) the H/V factors are ignored
    // and the plane is just one block per MCU — matches the MCU loop.
    var plane_w: [4]u32 = .{ 0, 0, 0, 0 };
    var plane_h: [4]u32 = .{ 0, 0, 0, 0 };
    {
        var i: usize = 0;
        while (i < channels) : (i += 1) {
            const eff_h: u32 = if (channels == 1) 1 else @as(u32, frame.components[i].h_factor);
            const eff_v: u32 = if (channels == 1) 1 else @as(u32, frame.components[i].v_factor);
            plane_w[i] = mcu_cols * eff_h * 8;
            plane_h[i] = mcu_rows * eff_v * 8;
        }
    }

    var planes: [4][]Sample = .{ &.{}, &.{}, &.{}, &.{} };
    errdefer {
        var j: usize = 0;
        while (j < channels) : (j += 1) {
            if (planes[j].len > 0) allocator.free(planes[j]);
        }
    }
    {
        var i: usize = 0;
        while (i < channels) : (i += 1) {
            planes[i] = try allocator.alloc(Sample, plane_w[i] * plane_h[i]);
        }
    }

    // Phase 1 (entropy decode) is inherently serial — DC predictors chain
    // across MCUs within an RST segment. Phase 2 (IDCT + plane copy) is
    // per-block independent. Coefficients live in i32 (headroom for
    // DC*qt) in natural row-major order, one [64] block per 8×8 region.
    var blocks_w: [4]u32 = .{ 0, 0, 0, 0 };
    var blocks_h: [4]u32 = .{ 0, 0, 0, 0 };
    {
        var i: usize = 0;
        while (i < channels) : (i += 1) {
            const eff_h: u32 = if (channels == 1) 1 else @as(u32, frame.components[i].h_factor);
            const eff_v: u32 = if (channels == 1) 1 else @as(u32, frame.components[i].v_factor);
            blocks_w[i] = mcu_cols * eff_h;
            blocks_h[i] = mcu_rows * eff_v;
        }
    }
    var coef_buf: [4][]i32 = .{ &.{}, &.{}, &.{}, &.{} };
    defer {
        var j: usize = 0;
        while (j < channels) : (j += 1) {
            if (coef_buf[j].len > 0) allocator.free(coef_buf[j]);
        }
    }
    {
        var i: usize = 0;
        while (i < channels) : (i += 1) {
            const total_blocks: usize = @as(usize, blocks_w[i]) * @as(usize, blocks_h[i]);
            coef_buf[i] = try allocator.alloc(i32, total_blocks * 64);
        }
    }

    // ── Phase 1: serial entropy decode → coefficient buffer, per scan ────
    // A non-interleaved scan codes only the component's image-extent blocks,
    // so the MCU-padding blocks it skips must read as zero.
    if (first_scan.count != channels) {
        for (coef_buf[0..channels]) |buf| @memset(buf, 0);
    }
    const grid: CoefGrid = .{
        .channels = channels,
        .max_h = max_h,
        .max_v = max_v,
        .mcu_cols = mcu_cols,
        .mcu_rows = mcu_rows,
        .blocks_w = blocks_w,
        .coef_buf = coef_buf,
    };
    var scan = first_scan;
    var scan_start = entropy_start;
    var coded: [4]bool = .{ false, false, false, false };
    while (true) {
        for (scan.comp[0..scan.count], scan.cs_pos[0..scan.count]) |ci, cs_pos| {
            if (coded[ci]) {
                try emitFinding(options, .fail, .sos_component_mismatch, cs_pos,
                    "scan selects a component an earlier scan of this sequential frame already coded");
                return fail("scan_component_already_coded", error.InvalidMarker);
            }
            coded[ci] = true;
        }
        const end = try decodeScanEntropy(data, scan_start, frame, scan, grid, tables, options);
        // Recovered truncation leaves later components at zero, as libjpeg does.
        if (end.truncated) break;
        if (std.mem.allEqual(bool, coded[0..channels], true)) {
			try rejectPostCoverageScans(data, scan_start + end.consumed, options);
			break;
		}
        scan_start += end.consumed;
        scan = try walkToNextScan(data, &scan_start, frame, tables.quant, tables.dc, tables.ac,
            tables.restart_interval, options);
    }

    // Pool machinery is hoisted to function scope so `pool_ptr` survives to the
    // assembleOutputT call below. Only populated for P<=8 (the parallel IDCT +
    // color-convert fast path); P=12 stays single-threaded (pool_ptr null),
    // matching the rarity/size of 12-bit images.
    var pool: thread_pool.Pool = undefined;
    var pool_initialized = false;
    var pool_ptr: ?*thread_pool.Pool = null;
    defer if (pool_initialized) pool.deinit();

    // ── Phase 2: per-block IDCT into the per-component plane ───────
    if (comptime P <= 8) {
        // Per-block work is independent: each task reads its own coefficient
        // slot and writes a non-overlapping 8×8 region of the (already
        // allocated) component plane. No shared mutable state; safe to
        // parallelize without locks.
        const total_blocks: u64 = blk: {
            var sum: u64 = 0;
            for (0..channels) |ci_idx| {
                sum += @as(u64, blocks_w[ci_idx]) * @as(u64, blocks_h[ci_idx]);
            }
            break :blk sum;
        };
        // Below this threshold sequential beats parallel (thread spawn +
        // join ~50µs vs ~100ns per IDCT block → ~512-block crossover).
        const PARALLEL_BLOCKS_THRESHOLD: u64 = 512;
        const want_parallel: bool = options.threads != 1 and total_blocks >= PARALLEL_BLOCKS_THRESHOLD;

        if (want_parallel) {
            var n_workers: u32 = options.threads;
            if (options.threads == 0) {
                const cpu = std.Thread.getCpuCount() catch 1;
                n_workers = @intCast(@min(cpu, std.math.maxInt(u32)));
            }
            // Cap at the largest plausible work-item count (block rows for
            // IDCT, output rows for color convert) so the pool isn't
            // undersized for either stage.
            var max_units: u32 = height;
            for (0..channels) |ci_idx| {
                if (blocks_h[ci_idx] > max_units) max_units = blocks_h[ci_idx];
            }
            if (n_workers > max_units) n_workers = max_units;
            if (n_workers < 1) n_workers = 1;

            if (pool.init(.{ .allocator = allocator, .n_jobs = n_workers })) {
                pool_initialized = true;
                pool_ptr = &pool;
            } else |_| {
                // Pool init failed (OS thread limit, OOM, etc). Fall
                // through to the sequential path — decoding still succeeds.
            }
        }

        if (pool_ptr) |p| {
            // Parallel transform: one task per row of blocks per component.
            var wg: thread_pool.WaitGroup = .{};
            var ci: usize = 0;
            while (ci < channels) : (ci += 1) {
                var by_idx: u32 = 0;
                while (by_idx < blocks_h[ci]) : (by_idx += 1) {
                    p.spawnWg(&wg, transformBlockRow, .{
                        coef_buf[ci],
                        planes[ci],
                        plane_w[ci],
                        blocks_w[ci],
                        by_idx,
                    });
                }
            }
            p.waitAndWork(&wg);
        } else {
            // Sequential transform.
            var ci: usize = 0;
            while (ci < channels) : (ci += 1) {
                var by_idx: u32 = 0;
                while (by_idx < blocks_h[ci]) : (by_idx += 1) {
                    var bx_idx: u32 = 0;
                    while (bx_idx < blocks_w[ci]) : (bx_idx += 1) {
                        const linear: usize = (@as(usize, by_idx) * @as(usize, blocks_w[ci]) + @as(usize, bx_idx)) * 64;
                        const slot: *const [64]i32 = coef_buf[ci][linear..][0..64];
                        transformBlockToPlane(slot, planes[ci], plane_w[ci], bx_idx * 8, by_idx * 8);
                    }
                }
            }
        }
    } else {
        // P == 12: single-threaded IDCT (idct8x8_12) into the u16 planes; the
        // u8-typed parallel row worker above is never instantiated here.
        var ci: usize = 0;
        while (ci < channels) : (ci += 1) {
            var by_idx: u32 = 0;
            while (by_idx < blocks_h[ci]) : (by_idx += 1) {
                var bx_idx: u32 = 0;
                while (bx_idx < blocks_w[ci]) : (bx_idx += 1) {
                    const linear: usize = (@as(usize, by_idx) * @as(usize, blocks_w[ci]) + @as(usize, bx_idx)) * 64;
                    const slot: *const [64]i32 = coef_buf[ci][linear..][0..64];
                    var block: [64]u16 = undefined;
                    idct.idct8x8_12(slot, &block);
                    const ox: u32 = bx_idx * 8;
                    const oy: u32 = by_idx * 8;
                    var blk_y: u32 = 0;
                    while (blk_y < 8) : (blk_y += 1) {
                        var blk_x: u32 = 0;
                        while (blk_x < 8) : (blk_x += 1) {
                            planes[ci][(oy + blk_y) * plane_w[ci] + (ox + blk_x)] = block[blk_y * 8 + blk_x];
                        }
                    }
                }
            }
        }
    }

    // ── 4-component CMYK / YCCK (8-bit only) ───────────────────────
    if (comptime P <= 8) {
        if (channels == 4) {
            // Delegate to cmyk.zig (raw-CMYK pass-through or YCCK→CMYK per
            // APP14 ColorTransform). Pass per-component sampling factors +
            // frame maxima so it upsamples each plane to the canvas (avoids
            // over-reading subsampled chroma — validate_gui heap over-read,
            // 2026-05-31).
            const cmyk_comp_h: [4]u8 = .{
                @intCast(frame.components[0].h_factor), @intCast(frame.components[1].h_factor),
                @intCast(frame.components[2].h_factor), @intCast(frame.components[3].h_factor),
            };
            const cmyk_comp_v: [4]u8 = .{
                @intCast(frame.components[0].v_factor), @intCast(frame.components[1].v_factor),
                @intCast(frame.components[2].v_factor), @intCast(frame.components[3].v_factor),
            };
            const img = try cmyk_mod.assemble(
                allocator,
                width,
                height,
                plane_w,
                plane_h,
                cmyk_comp_h,
                cmyk_comp_v,
                max_h,
                max_v,
                .{ planes[0], planes[1], planes[2], planes[3] },
                app14_color_transform,
            );
            var p: usize = 0;
            while (p < channels) : (p += 1) allocator.free(planes[p]);
            return img;
        }
    }

    // ── 1- and 3-component (grayscale / RGB), any precision ────────
    // assembleOutputT does chroma upsample + YCbCr→RGB (or the grayscale crop),
    // selects u8 vs host-endian-u16 output by P, parallelizes color-convert on
    // pool_ptr when present (P=8), and takes ownership of the planes.
    const plane_w_3: [3]u32 = .{ plane_w[0], plane_w[1], plane_w[2] };
    const plane_h_3: [3]u32 = .{ plane_h[0], plane_h[1], plane_h[2] };
    const planes_3: [3][]Sample = .{ planes[0], planes[1], planes[2] };
    // gap D + Mode-2: decide whether a 3-component frame is already R,G,B
    // (pass through) or YCbCr (convert), mirroring libjpeg-turbo's
    // default_decompress_parms (jdmaster.c) precedence exactly:
    //   1. JFIF (APP0) marker present      ⇒ YCbCr
    //   2. else Adobe APP14 ColorTransform ⇒ 0 (enum .cmyk) RGB, 1/2 YCbCr/YCCK
    //   3. else guess from component IDs    ⇒ ('R','G','B')=(82,71,66) RGB,
    //                                          anything else (incl. 1,2,3) YCbCr
    // The original gap-D fix only covered case 2 (Adobe transform=0). A
    // JPEGTables-spliced TIFF strip (Mode 2) carries neither JFIF nor Adobe
    // and signals RGB purely through component IDs — case 3. The rule is
    // the same at every precision: a 12-bit RGB frame (cjpeg -precision 12
    // -rgb) passes through too, as in libjpeg-turbo.
    const rgb_passthrough = cmyk_mod.rgbPassthrough(channels, .{
        .saw_jfif = saw_jfif,
        .app14 = app14_color_transform,
    }, .{ frame.components[0].id, frame.components[1].id, frame.components[2].id });
    return assembleOutputT(P, allocator, frame, channels, width, height, max_h, max_v, plane_w_3, plane_h_3, &planes_3, pool_ptr, rgb_passthrough);
}
