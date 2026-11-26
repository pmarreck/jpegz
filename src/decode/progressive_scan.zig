//! Progressive scan decoding: restart handling, recovery, and one scan's MCU loop.

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
const jpeg_markers = @import("jpeg_markers.zig");
const dbg = @import("progressive.zig").dbg;
const FrameInfo = @import("progressive.zig").FrameInfo;
const ScanInfo = @import("progressive.zig").ScanInfo;
const Error = @import("progressive.zig").Error;
const DecodeOptions = @import("progressive.zig").DecodeOptions;
const decodeProgressiveBlock = @import("progressive_block.zig").decodeProgressiveBlock;

/// T.81 §F.2.1.3.2: at every restart-interval boundary, the entropy
/// stream is realigned: bit buffer flushed to the next byte boundary,
/// the upcoming RSTm marker (FF D0..D7) consumed, predictors reset.
/// For progressive scans, we additionally reset `eob_run` (an
/// EOB-run state that persists ACROSS blocks within a scan but
/// MUST NOT cross a restart marker).
fn handleRestart(
    br: *bitstream.BitReader,
    base: usize,
    prev_dc: *[3]i16,
    eob_run: *u32,
    expected_rst: *u8,
    recovery: *ScanRecovery,
) Error!void {
    const options = recovery.options;
    if (!recovery.truncated) {
        var boundary = br.*;
        // All-zero pad bits are a known encoder defect (finding 63): WARN, continue.
        const finished = boundary.finishHuffmanSegment();
        const complete = if (finished) |_| eob_run.* == 0 else |err| zero: {
            if (err == error.PaddingNotOnes) {
                if (options.findings_sink) |sink| try sink.emitExact(.fail, .entropy_padding_not_ones, base + boundary.padByteOffset(), "mixed Huffman pad bits before restart marker (T.81 F.1.2.3)");
                if (!options.lenient) return error.BackendError;
                break :zero eob_run.* == 0;
            }
            if (err != error.PaddingZeroBits or eob_run.* != 0) break :zero false;
            if (options.findings_sink) |sink| try sink.emitZeroPadding(base + boundary.padByteOffset(), boundary.padBitCount());
            break :zero true;
        };
        if (!complete) {
            if (!options.lenient) return error.BackendError;
            const trailing: ?bitstream.BitReader.TrailingBytes = if (finished) |_| null else |err| if (err == error.InvalidEntropyBoundary) boundary.trailingBytesAfterPadding() else null;
            if (options.findings_sink) |sink| {
                // Validate rulings 2026-11-22: an EOB run longer than the
                // interval's blocks is 74 at the interval end; whole bytes
                // after valid padding are FAIL 8 at the first.
                if (eob_run.* != 0) {
                    try sink.emit(.fail, .entropy_decode_invalid, @intCast(base + br.byte_pos), "restart interval end: EOB run continues past its last block");
                } else if (trailing) |t| {
                    var buf: [96]u8 = undefined;
                    const detail = std.fmt.bufPrint(&buf, "{d} whole {s} after valid padding before marker 0x{X:0>2}", .{
                        t.count, if (t.count == 1) "byte" else "bytes", t.marker,
                    }) catch buf[0..0];
                    try sink.emitExact(.fail, .extraneous_bytes_before_marker, @intCast(base + t.first), detail);
                } else {
                    try sink.emit(.fail, .huffman_table_corrupt, @intCast(base + br.byte_pos), "invalid progressive Huffman entropy at restart boundary");
                }
            }
            // Like libjpeg, skip whole extraneous bytes to the marker.
            if (eob_run.* == 0) if (trailing) |t| {
                br.byte_pos = t.marker_at;
            };
        }
    }
    br.seekToMarker();

    if (!br.marker_seen) {
        if (options.lenient) {
            if (options.findings_sink) |sink| {
                sink.emit(.warn, .restart_marker_missing, @intCast(base + br.byte_pos), "expected RSTm marker not found at restart-interval boundary; continuing with reset DC predictors") catch return error.OutOfMemory;
            }
            prev_dc.* = .{ 0, 0, 0 };
            eob_run.* = 0;
            expected_rst.* = 0xD0 + ((expected_rst.* - 0xD0 + 1) & 0x07);
            return;
        }
        return error.InvalidMarker;
    }

    var reported = false;
    while (br.marker_seen and br.marker_byte != expected_rst.*) {
        const got_rst = br.marker_byte >= 0xD0 and br.marker_byte <= 0xD7;
        if (options.lenient and got_rst) {
            if (!reported) if (options.findings_sink) |sink| {
                var buf: [96]u8 = undefined;
                const detail = std.fmt.bufPrint(&buf, "expected RST{d} (0x{x:0>2}) but got RST{d} (0x{x:0>2})", .{ expected_rst.* - 0xD0, expected_rst.*, br.marker_byte - 0xD0, br.marker_byte }) catch buf[0..0];
                sink.emit(.warn, .restart_marker_unexpected, @intCast(base + br.byte_pos), detail) catch return error.OutOfMemory;
            };
            reported = true;
            // libjpeg's jpeg_resync_to_restart, as on the sequential path.
            switch ((br.marker_byte -% expected_rst.*) & 0x07) {
                // One or two ahead: leave the marker; the expected interval
                // decodes as empty and later intervals keep their positions.
                1, 2 => {
                    prev_dc.* = .{ 0, 0, 0 };
                    eob_run.* = 0;
                    expected_rst.* = 0xD0 + ((expected_rst.* - 0xD0 + 1) & 0x07);
                    return;
                },
                // One or two behind: stale. Skip to the next marker.
                6, 7 => {
                    br.skipPastMarker();
                    var i = br.byte_pos;
                    while (i + 1 < br.data.len and !(br.data[i] == 0xFF and br.data[i + 1] != 0x00 and br.data[i + 1] != 0xFF)) i += 1;
                    br.byte_pos = @min(i, br.data.len);
                    br.seekToMarker();
                    continue;
                },
                // Too far either way: take it as the expected marker.
                else => {
                    expected_rst.* = br.marker_byte;
                    break;
                },
            }
        }
        return error.InvalidMarker;
    }
    if (!br.marker_seen) return error.TruncatedStream;

    prev_dc.* = .{ 0, 0, 0 };
    eob_run.* = 0;
    expected_rst.* = 0xD0 + ((expected_rst.* - 0xD0 + 1) & 0x07);
    br.skipPastMarker();
}

pub const ScanRecovery = struct {
    options: DecodeOptions,
    /// File offset of the scan's `br.data[0]`.
    base: usize = 0,
    truncated: bool = false,

    /// An exact FAIL at `byte_pos` within the scan data (validate rulings
    /// 2026-11-22: 74 for a code with no valid decode, 58 for a category past
    /// the precision bound, both at the code's first byte).
    pub fn fault(self: *const ScanRecovery, code: errors.FindingCode, byte_pos: usize, comptime fmt: []const u8, args: anytype) Error!void {
        const s = self.options.findings_sink orelse return;
        var buf: [128]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..0];
        s.emitExact(.fail, code, @intCast(self.base + byte_pos), detail) catch return error.OutOfMemory;
    }
};

/// Record one recovery warning per damaged restart interval (or scan without
/// restarts), using libjpeg's premature-end diagnostic text.
pub inline fn emitInsufficientData(
    recovery: *ScanRecovery,
    byte_pos: usize,
) Error!void {
    if (!recovery.options.lenient) return error.BackendError;
    if (recovery.truncated) return;
    recovery.truncated = true;
    if (recovery.options.findings_sink) |s| {
        s.emit(.warn, .insufficient_data, @intCast(recovery.base + byte_pos), "Corrupt JPEG data: premature end of data segment") catch
            return error.OutOfMemory;
    }
}

pub fn decodeOneScan(
    data: []const u8,
    entropy_start: usize,
    frame: *const FrameInfo,
    dc_tables: *const [4]?huffman.HuffmanTable,
    ac_tables: *const [4]?huffman.HuffmanTable,
    coefs: *[3][]i16,
    blocks_w: *const [3]u32,
    blocks_h: *const [3]u32,
    max_h: u32,
    max_v: u32,
    scan: *const ScanInfo,
    restart_interval: u16,
    options: DecodeOptions,
) Error!usize {
    var recovery: ScanRecovery = .{ .options = options, .base = entropy_start };
    var br = bitstream.BitReader.init(data[entropy_start..]);
    var prev_dc: [3]i16 = .{ 0, 0, 0 };
    var eob_run: u32 = 0;
    // RST handling state. T.81 §F.2.1.3: every `restart_interval` MCUs
    // (or blocks for single-component scans), the encoder emits an
    // RSTm marker (FF D0..D7), the decoder flushes the bit buffer to a
    // byte boundary, resets `prev_dc` (and our progressive `eob_run`),
    // and consumes the RST marker. RSTm cycles 0..7.
    var units_since_rst: u32 = 0;
    var expected_rst: u8 = 0xD0;

    // Two iteration shapes:
    //   - Multi-component (interleaved) scan: walk MCUs the same way
    //     baseline does, decoding (h_factor × v_factor) blocks per
    //     component per MCU. Per T.81 §G.1.1.1.1: only the DC scans
    //     are typically multi-component (Ss=0, Se=0).
    //   - Single-component scan: the more common case for AC scans.
    //     Walk all blocks of that component in row-major order
    //     (block-by-block, not MCU-by-MCU).
    if (scan.num_components > 1) {
        const mcu_cols: u32 = blocks_w[0] / @as(u32, frame.components[0].h_factor);
        const mcu_rows: u32 = blocks_h[0] / @as(u32, frame.components[0].v_factor);
        var my: u32 = 0;
        while (my < mcu_rows) : (my += 1) {
            var mx: u32 = 0;
            while (mx < mcu_cols) : (mx += 1) {
                if (restart_interval > 0 and units_since_rst == restart_interval) {
                    try handleRestart(&br, entropy_start, &prev_dc, &eob_run, &expected_rst, &recovery);
                    recovery.truncated = false;
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
                            const block_x: u32 = mx * bh + bh_i;
                            const block_y: u32 = my * bv + bv_i;
                            const off: usize = (@as(usize, block_y) *
                                @as(usize, blocks_w[comp_idx]) +
                                @as(usize, block_x)) * 64;
                            const block = coefs[comp_idx][off .. off + 64];
                            try decodeProgressiveBlock(
                                &br,
                                comp,
                                dc_tables,
                                ac_tables,
                                &prev_dc,
                                &eob_run,
                                comp_idx,
                                block,
                                scan,
                                frame.precision,
                                &recovery,
                            );
                        }
                    }
                }
                units_since_rst += 1;
            }
        }
    } else {
        const comp_idx = scan.comp_indices[0];
        const comp = &frame.components[comp_idx];
        // T.81 §A.2.4: For single-component (Ns=1) scans, the iteration
        // bounds use the COMPONENT's own image-aligned block grid, NOT
        // the MCU-padded grid used by multi-component scans:
        //   xi = ceil(W * Hi / (8 * Hmax))
        //   yi = ceil(H * Vi / (8 * Vmax))
        // For 4:2:0 luma at 549×304: blocks_w[0]=70 (MCU-padded) but
        // single-component xi=69. Walking all 70 columns mis-syncs the
        // bitstream because the encoder only wrote 69 blocks per row in
        // this scan — the 70th column gets coefficient updates ONLY in
        // multi-component (DC interleaved) scans. Iteration: stride is
        // still `blocks_w[comp_idx]` (the buffer width), but the inner
        // loop bound is the per-spec component image extent.
        const W: u32 = frame.width;
        const H_full: u32 = frame.height;
        const xi: u32 = (W * @as(u32, comp.h_factor) + (8 * max_h) - 1) / (8 * max_h);
        const yi: u32 = (H_full * @as(u32, comp.v_factor) + (8 * max_v) - 1) / (8 * max_v);
        const bw: u32 = xi;
        const bh: u32 = yi;
        const stride: u32 = blocks_w[comp_idx];
        var by: u32 = 0;
        while (by < bh) : (by += 1) {
            var bx: u32 = 0;
            while (bx < bw) : (bx += 1) {
                if (restart_interval > 0 and units_since_rst == restart_interval) {
                    try handleRestart(&br, entropy_start, &prev_dc, &eob_run, &expected_rst, &recovery);
                    recovery.truncated = false;
                    units_since_rst = 0;
                }
                const off: usize = (@as(usize, by) * @as(usize, stride) +
                    @as(usize, bx)) * 64;
                const block = coefs[comp_idx][off .. off + 64];
                try decodeProgressiveBlock(
                    &br,
                    comp,
                    dc_tables,
                    ac_tables,
                    &prev_dc,
                    &eob_run,
                    comp_idx,
                    block,
                    scan,
                    frame.precision,
                    &recovery,
                );
                units_since_rst += 1;
            }
        }
    }

    // Recovered truncation already has a warning; its unfinished EOB counter
    // is not proof of an overlong run. Completed geometry must consume both
    // the EOB run and every entropy bit except all-one byte padding.
    if (!recovery.truncated) {
        if (eob_run != 0) {
            // Validate 2026-11-22: 74, at the scan end (the EOBRUN code's
            // position is not tracked), labeled as the scan end.
            if (options.findings_sink) |sink| try sink.emit(.fail, .entropy_decode_invalid, @intCast(entropy_start + br.byte_pos), "scan end: EOB run continues past the scan's last block");
            return error.BackendError;
        }
        _ = br.finishHuffmanSegment() catch |err| zero: {
            if (err == error.PaddingNotOnes) {
                if (options.findings_sink) |sink| try sink.emitExact(.fail, .entropy_padding_not_ones, entropy_start + br.padByteOffset(), "mixed Huffman pad bits before scan marker (T.81 F.1.2.3)");
            }
            if (err == error.InvalidEntropyBoundary) if (br.trailingBytesAfterPadding()) |t| {
                if (options.findings_sink) |sink| {
                    var buf: [96]u8 = undefined;
                    const detail = std.fmt.bufPrint(&buf, "{d} whole {s} after valid padding before marker 0x{X:0>2}", .{
                        t.count, if (t.count == 1) "byte" else "bytes", t.marker,
                    }) catch buf[0..0];
                    try sink.emitExact(.fail, .extraneous_bytes_before_marker, entropy_start + t.first, detail);
                }
            } else {
                // No marker before the data ends: the file ends after the scan.
                var probe = br;
                probe.seekToMarker();
                if (!probe.marker_seen and probe.byte_pos + 1 >= probe.data.len) {
                    if (options.findings_sink) |sink| try sink.emitExact(.fail, .truncated_stream, entropy_start + br.data.len, "file ends after a progressive scan, with no marker");
                    return error.TruncatedStream;
                }
            };
            if (err != error.PaddingZeroBits) return error.BackendError;
            if (options.findings_sink) |sink| try sink.emitZeroPadding(entropy_start + br.padByteOffset(), br.padBitCount());
            br.seekToMarker();
            break :zero 0;
        };
    } else br.seekToMarker();
    if (!br.marker_seen) {
        dbg("[prog:scan_end] no marker after scan: byte_pos={d} bits_valid={d}\n", .{ br.byte_pos, br.bits_valid });
        if (options.findings_sink) |sink| try sink.emitExact(.fail, .truncated_stream, entropy_start + br.data.len, "file ends after a progressive scan, with no marker");
        return error.TruncatedStream;
    }
    if (br.marker_byte >= 0xd0 and br.marker_byte <= 0xd7) {
        if (options.findings_sink) |sink| try sink.emitExact(.fail, .restart_marker_unexpected, entropy_start + br.byte_pos, "restart marker after the final unit of the scan");
        return error.BackendError;
    }
    return entropy_start + br.byte_pos;
}
