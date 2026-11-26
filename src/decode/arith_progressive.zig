//! Progressive arithmetic decoding (SOF10): the marker walk, scans and per-block passes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const errors = @import("../core/errors.zig");
const types = @import("../core/types.zig");
const arith_coder = @import("arith_coder.zig");
const baseline = @import("baseline.zig");
const progressive = @import("progressive.zig");
const findings_mod = @import("findings.zig");
const Error = @import("arith_decode.zig").Error;
const DecodeOptions = @import("arith_decode.zig").DecodeOptions;
const reportFault = @import("arith_decode.zig").reportFault;
const finishSegment = @import("arith_decode.zig").finishSegment;
const parseDac = @import("arith_sequential.zig").parseDac;

pub fn decodeArithProgressive(allocator: Allocator, data: []const u8, options: DecodeOptions) Error!types.Image {
    var pos: usize = 2;
    var frame: ?progressive.FrameInfo = null;
    var quant_tables: [4]?[64]u16 = .{ null, null, null, null };
    var restart_interval: u32 = 0;
    var dac_dc_L: [4]u8 = .{ 0, 0, 0, 0 };
    var dac_dc_U: [4]u8 = .{ 1, 1, 1, 1 };
    var dac_ac_K: [4]u8 = .{ 5, 5, 5, 5 };

    var coefs: [3][]i16 = .{ &.{}, &.{}, &.{} };
    var blocks_w: [3]u32 = .{ 0, 0, 0 };
    var blocks_h: [3]u32 = .{ 0, 0, 0 };
    var max_h: u32 = 1;
    var max_v: u32 = 1;
    var seen_sof = false;
    var saw_eoi = false;
    var color_signals: progressive.ColorSignals = .{};

    // ScanState persists DAC overrides across scans; the per-scan
    // resets happen inside each SOS branch via `state.startScan(...)`.
    var state: arith_coder.ScanState = arith_coder.ScanState.init(&.{});

    errdefer {
        var i: usize = 0;
        while (i < 3) : (i += 1) if (coefs[i].len > 0) allocator.free(coefs[i]);
    }

    while (pos + 1 < data.len and !saw_eoi) {
        if (data[pos] != 0xFF) return error.InvalidMarker;
        while (pos + 1 < data.len and data[pos + 1] == 0xFF) pos += 1;
        if (pos + 1 >= data.len) return error.TruncatedStream;
        const marker = data[pos + 1];
        pos += 2;
        color_signals.observe(marker, data, pos);

        switch (marker) {
            0xD9 => {
                saw_eoi = true;
                break;
            },
            0xCA => { // SOF10
                frame = try progressive.parseSof(data, pos);
                if (frame.?.precision != 8) return error.NotImplemented;
                if (frame.?.num_components != 1 and frame.?.num_components != 3)
                    return error.NotImplemented;
                seen_sof = true;
                var i: usize = 0;
                while (i < frame.?.num_components) : (i += 1) {
                    const c = &frame.?.components[i];
                    if (c.h_factor < 1 or c.h_factor > 4 or c.v_factor < 1 or c.v_factor > 4)
                        return error.NotImplemented;
                    if (@as(u32, c.h_factor) > max_h) max_h = @intCast(c.h_factor);
                    if (@as(u32, c.v_factor) > max_v) max_v = @intCast(c.v_factor);
                }
                const mcu_pixel_w: u32 = max_h * 8;
                const mcu_pixel_h: u32 = max_v * 8;
                const mcu_cols: u32 = (frame.?.width + mcu_pixel_w - 1) / mcu_pixel_w;
                const mcu_rows: u32 = (frame.?.height + mcu_pixel_h - 1) / mcu_pixel_h;
                i = 0;
                while (i < frame.?.num_components) : (i += 1) {
                    const c = &frame.?.components[i];
                    blocks_w[i] = mcu_cols * @as(u32, c.h_factor);
                    blocks_h[i] = mcu_rows * @as(u32, c.v_factor);
                    const total: usize = @as(usize, blocks_w[i]) * @as(usize, blocks_h[i]) * 64;
                    coefs[i] = try allocator.alloc(i16, total);
                    @memset(coefs[i], 0);
                }
                pos += progressive.parseSegmentLength(data, pos);
            },
            0xC0...0xC3, 0xC5...0xC7, 0xC9, 0xCB => return error.NotImplemented,
            0xDB => { // DQT
                try progressive.parseDqt(data, pos, &quant_tables);
                pos += progressive.parseSegmentLength(data, pos);
            },
            0xCC => { // DAC
                try parseDac(data, pos, &dac_dc_L, &dac_dc_U, &dac_ac_K);
                pos += progressive.parseSegmentLength(data, pos);
            },
            0xDD => { // DRI
                const seg_len = progressive.parseSegmentLength(data, pos);
                if (seg_len < 4 or pos + seg_len > data.len) return error.TruncatedStream;
                restart_interval = (@as(u32, data[pos + 2]) << 8) | data[pos + 3];
                pos += seg_len;
            },
            0xDA => { // SOS
                if (!seen_sof) return error.InvalidMarker;
                const sos_at = pos - 2;
                const scan = try progressive.parseSos(data, pos, &frame.?);
                pos += progressive.parseSegmentLength(data, pos);
                // DAC overrides apply scan-wide; copy them onto the
                // ScanState before the per-scan reset (init zeros all
                // stats but preserves the DAC fields we just wrote).
                state.arith_dc_L = dac_dc_L;
                state.arith_dc_U = dac_dc_U;
                state.arith_ac_K = dac_ac_K;
                // Per jdarith.c start_pass: DC tables zeroed on Ss==0 &&
                // Ah==0; AC tables zeroed on Ss > 0.
                const reset_dc = (scan.ss == 0 and scan.ah == 0);
                const reset_ac = (scan.ss != 0);
                state.startScan(data[pos..], reset_dc, reset_ac);
                pos = try decodeArithProgressiveScan(
                    pos,
                    sos_at,
                    &state,
                    &frame.?,
                    &coefs,
                    &blocks_w,
                    &blocks_h,
                    max_h,
                    max_v,
                    &scan,
                    restart_interval,
                    options,
                );
            },
            0x01, 0xD0...0xD7 => continue,
            else => pos += progressive.parseSegmentLength(data, pos),
        }
    }

    if (!seen_sof) return error.InvalidMarker;
    return switch (frame.?.precision) {
        8 => try progressive.assembleProgressiveGeneric(
            8,
            allocator,
            &frame.?,
            &quant_tables,
            &coefs,
            &blocks_w,
            &blocks_h,
            max_h,
            max_v,
            progressive.frameRgbPassthrough(&frame.?, color_signals),
            null,
        ),
        else => return error.NotImplemented, // 12-bit progressive arithmetic — corpus has none yet.
    };
}

/// Walk one scan's blocks and dispatch to the matching arith handler.
/// Mirrors `progressive.decodeOneScan`'s iteration shape (multi-comp
/// MCU vs single-comp x_i/y_i grid). On RST: re-init ScanState's
/// Q-coder + selectively zero stats, but DON'T re-zero DAC state.
fn decodeArithProgressiveScan(
    entropy_start: usize,
    sos_at: usize,
    state: *arith_coder.ScanState,
    frame: *const progressive.FrameInfo,
    coefs: *[3][]i16,
    blocks_w: *const [3]u32,
    blocks_h: *const [3]u32,
    max_h: u32,
    max_v: u32,
    scan: *const progressive.ScanInfo,
    restart_interval: u32,
    options: DecodeOptions,
) Error!usize {
    var units_since_rst: u32 = 0;
    var expected_rst: u8 = 0xD0;
    var interval_start: usize = if (restart_interval > 0) entropy_start else sos_at;
    const reset_dc = (scan.ss == 0 and scan.ah == 0);
    const reset_ac = (scan.ss != 0);

    const handleArithRst = struct {
        fn run(
            s: *arith_coder.ScanState,
            base: usize,
            opts: DecodeOptions,
            expected: *u8,
            re_dc: bool,
            re_ac: bool,
        ) Error!usize {
            const marker_at = try finishSegment(&s.qcoder, base, .interval, expected, opts);
            // startScan applies the scan-type reset policy used at scan
            // start; the coder then resumes after the marker, at an
            // offset into the same buffer.
            const pos_after = s.qcoder.pos;
            s.startScan(s.qcoder.data, re_dc, re_ac);
            s.qcoder.pos = pos_after;
            return marker_at + 2;
        }
    }.run;

    if (scan.num_components > 1) {
        const mcu_cols: u32 = blocks_w[0] / @as(u32, frame.components[0].h_factor);
        const mcu_rows: u32 = blocks_h[0] / @as(u32, frame.components[0].v_factor);
        var my: u32 = 0;
        while (my < mcu_rows) : (my += 1) {
            var mx: u32 = 0;
            while (mx < mcu_cols) : (mx += 1) {
                if (restart_interval > 0 and units_since_rst == restart_interval) {
                    interval_start = try handleArithRst(state, entropy_start, options, &expected_rst, reset_dc, reset_ac);
                    units_since_rst = 0;
                }
                var ci: usize = 0;
                while (ci < scan.num_components) : (ci += 1) {
                    const comp_idx = scan.comp_indices[ci];
                    const comp = &frame.components[comp_idx];
                    const bh: u32 = @intCast(comp.h_factor);
                    const bv: u32 = @intCast(comp.v_factor);
                    var bv_i: u32 = 0;
                    while (bv_i < bv) : (bv_i += 1) {
                        var bh_i: u32 = 0;
                        while (bh_i < bh) : (bh_i += 1) {
                            const bx: u32 = mx * bh + bh_i;
                            const by: u32 = my * bv + bv_i;
                            const off: usize = (@as(usize, by) *
                                @as(usize, blocks_w[comp_idx]) +
                                @as(usize, bx)) * 64;
                            const block = coefs[comp_idx][off .. off + 64];
                            decodeArithProgressiveBlock(state, comp_idx, comp, block, scan) catch |err| {
                                if (err == error.BackendError) try reportFault(state, interval_start, restart_interval > 0, options);
                                return err;
                            };
                        }
                    }
                }
                units_since_rst += 1;
            }
        }
    } else {
        const comp_idx = scan.comp_indices[0];
        const comp = &frame.components[comp_idx];
        const W: u32 = frame.width;
        const H_full: u32 = frame.height;
        const xi: u32 = (W * @as(u32, comp.h_factor) + (8 * max_h) - 1) / (8 * max_h);
        const yi: u32 = (H_full * @as(u32, comp.v_factor) + (8 * max_v) - 1) / (8 * max_v);
        const stride: u32 = blocks_w[comp_idx];
        var by: u32 = 0;
        while (by < yi) : (by += 1) {
            var bx: u32 = 0;
            while (bx < xi) : (bx += 1) {
                if (restart_interval > 0 and units_since_rst == restart_interval) {
                    interval_start = try handleArithRst(state, entropy_start, options, &expected_rst, reset_dc, reset_ac);
                    units_since_rst = 0;
                }
                const off: usize = (@as(usize, by) * @as(usize, stride) +
                    @as(usize, bx)) * 64;
                const block = coefs[comp_idx][off .. off + 64];
                decodeArithProgressiveBlock(state, comp_idx, comp, block, scan) catch |err| {
                    if (err == error.BackendError) try reportFault(state, interval_start, restart_interval > 0, options);
                    return err;
                };
                units_since_rst += 1;
            }
        }
    }

    // The outer marker walk resumes at the marker that ends the scan.
    return finishSegment(&state.qcoder, entropy_start, .scan_end, &expected_rst, options);
}

fn decodeArithProgressiveBlock(
    state: *arith_coder.ScanState,
    ci: usize,
    comp: *const progressive.ComponentInfo,
    block: []i16,
    scan: *const progressive.ScanInfo,
) Error!void {
    // NOTE: do NOT early-return on `marker_seen`. Unlike the Huffman
    // progressive path (which checks `br.markerHit()` because its
    // bit-reader exhausts on marker), the arithmetic Q-coder supplies
    // zero bits past a marker (T.81 §F.1.4 — "supply zero data until
    // decoding is complete"). libjpeg's per-scan loop calls
    // `arith_decode` for every block regardless of marker state, and
    // we must mirror that to keep the per-block decode count right.

    const sof9_to_decode = struct {
        fn map(e: arith_coder.ArithError) Error {
            return switch (e) {
                error.BackendError, error.TruncatedStream, error.InvalidMarker => error.BackendError,
            };
        }
    }.map;

    if (scan.ss == 0) {
        if (scan.ah == 0) {
            arith_coder.decodeDcFirstArith(
                state,
                ci,
                comp.dc_table,
                scan.al,
                block,
            ) catch |e| return sof9_to_decode(e);
        } else {
            arith_coder.decodeDcRefineArith(state, scan.al, block);
        }
    } else {
        if (scan.ah == 0) {
            arith_coder.decodeAcFirstArith(
                state,
                comp.ac_table,
                scan.ss,
                scan.se,
                scan.al,
                block,
            ) catch |e| return sof9_to_decode(e);
        } else {
            arith_coder.decodeAcRefineArith(
                state,
                comp.ac_table,
                scan.ss,
                scan.se,
                scan.al,
                block,
            ) catch |e| return sof9_to_decode(e);
        }
    }
}
