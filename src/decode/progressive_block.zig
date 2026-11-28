//! Progressive block decoders: DC/AC first and refinement passes (T.81 G.1.2).

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
const ComponentInfo = @import("progressive.zig").ComponentInfo;
const ScanInfo = @import("progressive.zig").ScanInfo;
const Error = @import("progressive.zig").Error;
const ScanRecovery = @import("progressive_scan.zig").ScanRecovery;
const emitInsufficientData = @import("progressive_scan.zig").emitInsufficientData;

pub fn decodeProgressiveBlock(
    br: *bitstream.BitReader,
    comp: *const ComponentInfo,
    dc_tables: *const [4]?huffman.HuffmanTable,
    ac_tables: *const [4]?huffman.HuffmanTable,
    prev_dc: *[3]i16,
    eob_run: *u32,
    comp_idx: usize,
    block: []i16,
    scan: *const ScanInfo,
    precision: u8,
    recovery: *ScanRecovery,
) Error!void {
    // Marker lookahead can precede a valid EOB run's remaining zero blocks.
    // Only a decode leaf's explicit recovery path may skip later blocks.
    if (recovery.truncated) return;
    if (scan.ss == 0) {
        // DC scan
        if (scan.ah == 0) try decodeProgressiveDcFirst(br, comp, dc_tables, prev_dc, comp_idx, block, scan, precision, recovery) else try decodeProgressiveDcRefine(br, block, scan, recovery);
    } else {
        // AC scan (single-component)
        if (scan.ah == 0) try decodeProgressiveAcFirst(br, comp, ac_tables, eob_run, block, scan, precision, recovery) else try decodeProgressiveAcRefine(br, comp, ac_tables, eob_run, block, scan, recovery);
    }
}

/// T.81 §G.1.2.1 — DC, first pass (Ah=0).
/// The DC differential is decoded normally, then shifted left by Al
/// before storing. prev_dc tracks across blocks of the same component.
fn decodeProgressiveDcFirst(
    br: *bitstream.BitReader,
    comp: *const ComponentInfo,
    dc_tables: *const [4]?huffman.HuffmanTable,
    prev_dc: *[3]i16,
    comp_idx: usize,
    block: []i16,
    scan: *const ScanInfo,
    precision: u8,
    recovery: *ScanRecovery,
) Error!void {
    const dc_t = dc_tables[comp.dc_table] orelse return error.InvalidMarker;
    const dc_mark = br.mark();
    const dc_size: u8 = dc_t.decode(br) catch |e| {
        if (br.markerHit()) {
            try emitInsufficientData(recovery, br.byte_pos);
            return;
        }
        dbg("[prog:dc_first] huff fail comp={d} dc_table={d} byte_pos={d} bits_valid={d} buf=0x{x} err={s}\n", .{ comp_idx, comp.dc_table, br.byte_pos, br.bits_valid, br.buf, @errorName(e) });
        try recovery.fault(.entropy_decode_invalid, br.markOffset(dc_mark), "DC Huffman code matches no table entry", .{});
        return error.BackendError;
    };
    if (dc_size > precision + 3) {
        try recovery.fault(.dct_coefficient_overflow, br.markOffset(dc_mark), "DC difference category {d} exceeds {d} for {d}-bit samples (T.81 F.1.2.1)", .{ dc_size, precision + 3, precision });
        return error.BackendError;
    }
    var dc_diff: i16 = 0;
    if (dc_size > 0) {
        const bits = br.readBits(@intCast(dc_size)) catch {
            if (br.markerHit()) {
                try emitInsufficientData(recovery, br.byte_pos);
                return;
            }
            return error.TruncatedStream;
        };
        dc_diff = huffman.extendSign(bits, @intCast(dc_size));
    }
    // Corrupt differences can drive the predictor or its point-transformed
    // coefficient outside i16; report that as corrupt entropy data.
    prev_dc[comp_idx] = std.math.cast(i16, @as(i32, prev_dc[comp_idx]) + dc_diff) orelse return error.BackendError;
    block[0] = std.math.cast(i16, @as(i32, prev_dc[comp_idx]) << @intCast(scan.al)) orelse return error.BackendError;
}

/// T.81 §G.1.2.3 — DC refinement pass (Ah>0). Read 1 bit, shift-OR into
/// the DC coefficient at bit position Al.
fn decodeProgressiveDcRefine(
    br: *bitstream.BitReader,
    block: []i16,
    scan: *const ScanInfo,
    recovery: *ScanRecovery,
) Error!void {
    const bit = br.readBits(1) catch {
        if (br.markerHit()) {
            try emitInsufficientData(recovery, br.byte_pos);
            return;
        }
        return error.TruncatedStream;
    };
    if (bit == 1) {
        block[0] = std.math.cast(i16, @as(i32, block[0]) | (@as(i32, 1) << @intCast(scan.al))) orelse return error.BackendError;
    }
}

/// T.81 §G.1.2.2 — AC first pass (Ah=0). Like baseline AC decode but:
///  - EOB run extension: RS values 0x10..0xE0 mean "end-of-band run for
///    2^run + extension blocks", including the current block.
///  - Decoded value shifted left by Al before storing.
fn decodeProgressiveAcFirst(
    br: *bitstream.BitReader,
    comp: *const ComponentInfo,
    ac_tables: *const [4]?huffman.HuffmanTable,
    eob_run: *u32,
    block: []i16,
    scan: *const ScanInfo,
    precision: u8,
    recovery: *ScanRecovery,
) Error!void {
    if (eob_run.* > 0) {
        eob_run.* -= 1;
        return;
    }
    const ac_t = ac_tables[comp.ac_table] orelse return error.InvalidMarker;

    var k: u8 = scan.ss;
    while (k <= scan.se) {
        const ac_mark = br.mark();
        const rs: u8 = ac_t.decode(br) catch |e| {
            if (br.markerHit()) {
                try emitInsufficientData(recovery, br.byte_pos);
                return;
            }
            try recovery.fault(.entropy_decode_invalid, br.markOffset(ac_mark), "AC Huffman code matches no table entry", .{});
            dbg("[prog:ac_first] huff fail ac_table={d} k={d} ss={d} se={d} byte_pos={d} bits_valid={d} buf=0x{x} err={s}\n", .{ comp.ac_table, k, scan.ss, scan.se, br.byte_pos, br.bits_valid, br.buf, @errorName(e) });
            return error.BackendError;
        };
        const run: u8 = rs >> 4;
        const size: u8 = rs & 0x0F;
        if (size > precision + 2) {
            try recovery.fault(.dct_coefficient_overflow, br.markOffset(ac_mark), "AC coefficient category {d} exceeds {d} for {d}-bit samples (T.81 F.1.2.2)", .{ size, precision + 2, precision });
            return error.BackendError;
        }
        if (size == 0) {
            if (run == 15) {
                // ZRL — 16 zeros
                if (@as(u16, k) + 15 > scan.se) {
                    try recovery.fault(.entropy_decode_invalid, br.markOffset(ac_mark), "AC zero run past Se={d}", .{scan.se});
                    return error.BackendError;
                }
                k += 16;
                continue;
            } else {
                // EOB run includes this block; decrement it after extension.
                eob_run.* = (@as(u32, 1) << @intCast(run));
                if (run > 0) {
                    const extra = br.readBits(@intCast(run)) catch {
                        if (br.markerHit()) {
                            try emitInsufficientData(recovery, br.byte_pos);
                            return;
                        }
                        return error.TruncatedStream;
                    };
                    eob_run.* += @intCast(extra);
                }
                eob_run.* -= 1;
                break;
            }
        }
        k += run;
        if (k > scan.se) {
            // The decoded run is out of band even if lookahead saw a marker.
            dbg("[prog:ac_first] k>se after run k={d} se={d} byte_pos={d}\n", .{ k, scan.se, br.byte_pos });
            try recovery.fault(.entropy_decode_invalid, br.markOffset(ac_mark), "AC zero run past Se={d}", .{scan.se});
            return error.BackendError;
        }
        const bits = br.readBits(@intCast(size)) catch {
            if (br.markerHit()) {
                try emitInsufficientData(recovery, br.byte_pos);
                return;
            }
            return error.TruncatedStream;
        };
        const val = huffman.extendSign(bits, @intCast(size));
        block[k] = std.math.cast(i16, @as(i32, val) << @intCast(scan.al)) orelse return error.BackendError;
        k += 1;
    }
}

/// T.81 §G.1.2.3 — AC refinement pass (Ah>0). Per the procedure:
///   While k ≤ Se:
///     Read RS = (run, size).
///     Determine new_val (size != 0) or set ZRL/EOB run state.
///     Walk forward across `run` zero positions (and any number of
///     existing nonzeros), refining each existing nonzero by 1 bit.
///     If a new_val is pending, place it at the position after the
///     last walked zero. ZRL = "16 zeros, no new nonzero".
///     EOB run takes effect for SUBSEQUENT blocks; in the current
///     block, refine remaining nonzeros and stop.
fn decodeProgressiveAcRefine(
    br: *bitstream.BitReader,
    comp: *const ComponentInfo,
    ac_tables: *const [4]?huffman.HuffmanTable,
    eob_run: *u32,
    block: []i16,
    scan: *const ScanInfo,
    recovery: *ScanRecovery,
) Error!void {
    const ac_t = ac_tables[comp.ac_table] orelse return error.InvalidMarker;
    const positive: i16 = @as(i16, @intCast(@as(i32, 1) << @intCast(scan.al)));
    const negative: i16 = -positive;

    var k: u8 = scan.ss;

    if (eob_run.* > 0) {
        // EOB-run carry-over from a previous block: just refine
        // remaining nonzeros in this block, no new nonzeros.
        while (k <= scan.se) : (k += 1) {
            try refineExistingNonzero(br, block, k, positive, negative, recovery);
        }
        eob_run.* -= 1;
        return;
    }

    while (k <= scan.se) {
        const ac_mark = br.mark();
        const rs: u8 = ac_t.decode(br) catch |e| {
            if (br.markerHit()) {
                try emitInsufficientData(recovery, br.byte_pos);
                return;
            }
            try recovery.fault(.entropy_decode_invalid, br.markOffset(ac_mark), "AC Huffman code matches no table entry", .{});
            const remaining: usize = if (br.byte_pos < br.data.len) br.data.len - br.byte_pos else 0;
            const next3: [3]u8 = if (br.byte_pos + 2 < br.data.len) .{ br.data[br.byte_pos], br.data[br.byte_pos + 1], br.data[br.byte_pos + 2] } else .{ 0, 0, 0 };
            dbg("[prog:ac_refine] huff fail ac_table={d} k={d} byte_pos={d} bytes_left={d} next3={x:0>2}{x:0>2}{x:0>2} buf=0x{x} bits_valid={d} marker_seen={} err={s}\n", .{ comp.ac_table, k, br.byte_pos, remaining, next3[0], next3[1], next3[2], br.buf, br.bits_valid, br.marker_seen, @errorName(e) });
            return error.BackendError;
        };
        const run_field: u8 = rs >> 4;
        const size: u8 = rs & 0x0F;
        var zeros_remaining: u8 = run_field;
        var has_pending_new: bool = false;
        var new_val: i16 = 0;

        if (size != 0) {
            if (size != 1) {
                dbg("[prog:ac_refine] size!=1 (size={d}) k={d} se={d} byte_pos={d}\n", .{ size, k, scan.se, br.byte_pos });
                // T.81 G.1.2.3 allows only size 1 in refinement.
                try recovery.fault(.entropy_decode_invalid, br.markOffset(ac_mark), "AC refinement symbol of size {d}, not 1 (T.81 G.1.2.3)", .{size});
                return error.BackendError;
            }
            const bit = br.readBits(1) catch {
                if (br.markerHit()) {
                    try emitInsufficientData(recovery, br.byte_pos);
                    return;
                }
                return error.TruncatedStream;
            };
            new_val = if (bit == 1) positive else negative;
            has_pending_new = true;
        } else if (run_field == 15) {
            // ZRL: 16 zeros, no new value.
            zeros_remaining = 16;
        } else {
            // EOB run: 2^run blocks (current + future), refine remaining
            // nonzeros in this block, mark eob_run for following blocks.
            var count: u32 = (@as(u32, 1) << @intCast(run_field));
            if (run_field > 0) {
                const extra = br.readBits(@intCast(run_field)) catch {
                    if (br.markerHit()) {
                        try emitInsufficientData(recovery, br.byte_pos);
                        return;
                    }
                    return error.TruncatedStream;
                };
                count += @intCast(extra);
            }
            eob_run.* = count - 1; // current block consumed inline below
            while (k <= scan.se) : (k += 1) {
                try refineExistingNonzero(br, block, k, positive, negative, recovery);
            }
            return;
        }

        // Walk forward refining existing nonzeros, decrement zeros_remaining
        // for each zero seen. Per libjpeg-turbo jdphuff.c
        // decode_mcu_AC_refine, the inner loop breaks when `--r < 0` —
        // i.e., AFTER decrementing on the (run+1)-th zero. For ZRL
        // (run=15, size=0) this is the 16th zero. For non-ZRL with new
        // value, this is the (R+1)-th zero where the new value is
        // placed.
        //
        // Critical: for ZRL, we must break IMMEDIATELY after the 16th
        // zero is decremented — without iterating once more. Otherwise,
        // a nonzero appearing right after the 16-zero window would be
        // refined here even though the encoder wrote no refinement bit
        // for it (it belongs to the NEXT RS code).
        const is_zrl = (size == 0 and run_field == 15);
        var reached = false;
        while (k <= scan.se) {
            if (block[k] != 0) {
                try refineExistingNonzero(br, block, k, positive, negative, recovery);
            } else {
                if (zeros_remaining == 0) {
                    if (has_pending_new) {
                        block[k] = new_val;
                        k += 1;
                    }
                    reached = true;
                    break;
                }
                zeros_remaining -= 1;
                if (is_zrl and zeros_remaining == 0) {
                    // 16th zero just decremented for ZRL — break before
                    // refining any nonzero that follows. Advance past
                    // this zero so the outer RS loop resumes after it.
                    k += 1;
                    reached = true;
                    break;
                }
            }
            k += 1;
        }
        if (!reached) {
            // The band ended before the code's run did: no valid encoder
            // writes that, as for a first scan's run past Se. libjpeg-turbo
            // then stores the new value through jpeg_natural_order[64],
            // clobbering coefficient 63; jpegz reports the fault.
            try recovery.fault(.entropy_decode_invalid, br.markOffset(ac_mark), "AC refinement zero run past Se={d}", .{scan.se});
            return error.BackendError;
        }
    }
}

inline fn refineExistingNonzero(
    br: *bitstream.BitReader,
    block: []i16,
    k: u8,
    positive: i16,
    negative: i16,
    recovery: *ScanRecovery,
) Error!void {
    if (recovery.truncated or block[k] == 0) return;
    const bit = br.readBits(1) catch {
        if (br.markerHit()) {
            try emitInsufficientData(recovery, br.byte_pos);
            return;
        }
        return error.TruncatedStream;
    };
    if (bit == 0) return;
    // Refinement: add ±positive in the direction of the existing sign.
    const step: i32 = if (block[k] > 0) positive else negative;
    block[k] = std.math.cast(i16, @as(i32, block[k]) + step) orelse return error.BackendError;
}
