//! Arithmetic-coded JPEG decoder entry points (SOF9 / SOF10).
//!
//! SOF9 — extended sequential with arithmetic coding (T.81 §F.1.4).
//! SOF10 — progressive with arithmetic coding (T.81 §G.1) — Session 2.
//! SOF11 (lossless, arithmetic) is deferred — same A2 rationale:
//! `cjpeg -arithmetic -lossless` errors with "arithmetic coding is
//! not implemented", so the variant has no ground-truth encoder.
//!
//! This module is the SOF dispatcher + per-MCU orchestrator. Entropy
//! kernel (Q-coder + DC/AC binarization) lives in `arith_coder.zig`.
//! IDCT + assemble are reused from `baseline.zig` via newly-public
//! `transformBlockToPlane` and `assembleOutput` — the A3 refactor's
//! Phase-2 seam pays off here.
//!
//! Layout: this file holds the entry points, coefficient dumps and the
//! segment-end and fault helpers. arith_sequential.zig decodes SOF9
//! (sequential) frames and arith_progressive.zig decodes SOF10.

const std = @import("std");
const Allocator = std.mem.Allocator;
const errors = @import("../core/errors.zig");
const types = @import("../core/types.zig");
const arith_coder = @import("arith_coder.zig");
const baseline = @import("baseline.zig");
const progressive = @import("progressive.zig");
const findings_mod = @import("findings.zig");

// Parts of this decoder live in sibling files (see Layout above).
const decodeArithBaseline = @import("arith_sequential.zig").decodeArithBaseline;
const parseDac = @import("arith_sequential.zig").parseDac;
const decodeArithProgressive = @import("arith_progressive.zig").decodeArithProgressive;

pub const Error = errors.DecodeError;

// Force-import the Q-coder so its inline tests are discovered.
comptime {
    _ = arith_coder;
}

/// Caller-supplied knobs. Mirrors `baseline.DecodeOptions` shape so the
/// dispatcher can pass through a `FindingsSink` uniformly. The arith
/// progressive path is strict on marker prefix and the Q-coder
/// explicitly never uses `markerHit` (zero-bit-supply per T.81 §F.1.4),
/// The sink receives the marker walker's extraneous-bytes findings and the
/// typed restart-interval and scan-end findings (`finishSegment`).
/// `lenient` resynchronizes on an out-of-order RSTm instead of failing.
pub const DecodeOptions = struct {
    findings_sink: ?*findings_mod.FindingsSink = null,
    lenient: bool = false,
};

/// Where an arithmetic entropy segment ends (T.81 D.1.8, D.2.6), as offsets
/// into the coder's `data`.
const SegmentEnd = struct {
    /// First whole byte the coder never fetched, when any precede the marker.
    unread_at: ?usize,
    /// The 0xFF that introduces the ending marker, or null when data ends.
    marker_at: ?usize,
    marker: u8,
};

fn segmentEnd(qc: *const arith_coder.QCoder) SegmentEnd {
    if (qc.marker_seen) return .{ .unread_at = null, .marker_at = qc.pos - 2, .marker = qc.marker_byte };
    var p: usize = qc.pos;
    while (p < qc.data.len) : (p += 1) {
        if (qc.data[p] != 0xFF) continue;
        // 0xFF fill before a marker is not unread data (T.81 B.1.1.2).
        var q: usize = p + 1;
        while (q < qc.data.len and qc.data[q] == 0xFF) q += 1;
        if (q >= qc.data.len) break;
        if (qc.data[q] == 0x00) {
            p = q; // a stuffed 0xFF is entropy data
            continue;
        }
        return .{ .unread_at = if (p > qc.pos) qc.pos else null, .marker_at = q - 1, .marker = qc.data[q] };
    }
    return .{ .unread_at = if (qc.data.len > qc.pos) qc.pos else null, .marker_at = null, .marker = 0 };
}

/// Report a decoded-value fault (validate rulings 2026-11-22) at the start of
/// its restart interval, or at the SOS without DRI, labeled as the interval
/// and not exact: the coder has read ahead of the damage by an unknown amount.
pub fn reportFault(state: *const arith_coder.ScanState, interval_start: usize, restarts: bool, options: DecodeOptions) Error!void {
    const s = options.findings_sink orelse return;
    const fault = state.fault;
    const where: []const u8 = if (restarts) "restart interval" else "scan";
    var buf: [128]u8 = undefined;
    switch (fault.kind) {
        .none => {},
        .magnitude => {
            const detail = std.fmt.bufPrint(&buf, "{s} starting here: {s} magnitude {d} exceeds {d} for {d}-bit samples (T.81 F.1.2)", .{
                where,                                                 if (fault.dc) "DC difference" else "AC coefficient", fault.magnitude,
                arith_coder.magnitudeLimit(state.precision, fault.dc), state.precision,
            }) catch buf[0..0];
            s.emit(.fail, .dct_coefficient_overflow, @intCast(interval_start), detail) catch return error.OutOfMemory;
        },
        .run_past_band => {
            const detail = std.fmt.bufPrint(&buf, "{s} starting here: AC zero run past Se={d}", .{ where, fault.se }) catch buf[0..0];
            s.emit(.fail, .entropy_decode_invalid, @intCast(interval_start), detail) catch return error.OutOfMemory;
        },
    }
}

/// Check the end of a restart interval or scan (validate rulings 2026-11-22).
/// Whole bytes the coder never fetched are FAIL 8 (`arithmetic_interval` or
/// `arithmetic_scan_end`): the D.1.8 flush emits only bytes a decoder
/// fetches. At an interval: the expected RSTm leaves the coder just past it
/// for `restart()`; another RSTm is 57 (lenient decodes resynchronize on it);
/// EOI, or data that ends, is `truncated_stream`; any other marker is 56.
/// At scan end an RSTm is 57; EOI and other markers end the scan normally.
/// `base` is the file offset of `qc.data[0]`. Returns the file offset of the
/// ending marker's 0xFF (the end of data when none follows the scan).
pub fn finishSegment(
    qc: *arith_coder.QCoder,
    base: usize,
    comptime where: enum { interval, scan_end },
    expected: *u8,
    options: DecodeOptions,
) Error!usize {
    const end = segmentEnd(qc);
    const sink = options.findings_sink;
    if (end.unread_at) |at| {
        if (sink) |s| s.emitExact(.fail, .extraneous_bytes_before_marker, @intCast(base + at), if (where == .interval) "arithmetic_interval" else "arithmetic_scan_end") catch return error.OutOfMemory;
        if (where == .interval and !options.lenient and end.marker_at != null and end.marker == expected.*)
            return error.InvalidMarker;
    }
    const marker_at = end.marker_at orelse {
        if (where == .scan_end) return base + qc.data.len;
        if (sink) |s| s.emitExact(.fail, .truncated_stream, @intCast(base + qc.data.len), "data ends where a restart marker and further restart intervals belong") catch return error.OutOfMemory;
        return error.TruncatedStream;
    };
    const m = end.marker;
    const is_rst = m >= 0xD0 and m <= 0xD7;
    if (where == .scan_end) {
        if (is_rst) {
            if (sink) |s| s.emitExact(.fail, .restart_marker_unexpected, @intCast(base + marker_at), "restart marker after the final MCU of the scan") catch return error.OutOfMemory;
            return error.BackendError;
        }
        return base + marker_at;
    }
    if (m == expected.*) {
        qc.pos = marker_at + 2;
        expected.* = 0xD0 + ((m - 0xD0 + 1) & 0x07);
        return base + marker_at;
    }
    if (is_rst) {
        if (sink) |s| {
            var buf: [64]u8 = undefined;
            const detail = std.fmt.bufPrint(&buf, "expected RST{d} (0x{x:0>2}) but got RST{d} (0x{x:0>2})", .{ expected.* - 0xD0, expected.*, m - 0xD0, m }) catch buf[0..0];
            s.emitExact(.fail, .restart_marker_unexpected, @intCast(base + marker_at), detail) catch return error.OutOfMemory;
        }
        if (!options.lenient) return error.InvalidMarker;
        qc.pos = marker_at + 2;
        expected.* = 0xD0 + ((m - 0xD0 + 1) & 0x07);
        return base + marker_at;
    }
    if (m == 0xD9) {
        if (sink) |s| s.emitExact(.fail, .truncated_stream, @intCast(base + marker_at), "EOI where a restart marker and further restart intervals belong") catch return error.OutOfMemory;
        return error.TruncatedStream;
    }
    if (sink) |s| {
        var buf: [64]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "marker 0x{x:0>2} where RST{d} belongs", .{ m, expected.* - 0xD0 }) catch buf[0..0];
        s.emitExact(.fail, .restart_marker_missing, @intCast(base + marker_at), detail) catch return error.OutOfMemory;
    }
    return error.InvalidMarker;
}

/// Public entry. Walks markers, classifies SOF9/SOF10/SOF11, dispatches.
/// Default-options entry — null sink, silent tolerance.
pub fn decode(allocator: Allocator, data: []const u8) Error!types.Image {
    return decodeWithOptions(allocator, data, .{});
}

/// Same as `decode` but accepts a `DecodeOptions`. Currently the only
/// honored knob is `findings_sink`: when non-null and the bitstream is
/// SOF9 sequential, the cleanroom emits a `Finding(.warn,
/// .extraneous_bytes_before_marker)` for each gap of non-0xFF bytes
/// the marker walker silently skips — mirroring libjpeg-turbo's
/// `JWRN_EXTRANEOUS_DATA`.
pub fn decodeWithOptions(
    allocator: Allocator,
    data: []const u8,
    options: DecodeOptions,
) Error!types.Image {
    if (data.len < 4) return error.TruncatedStream;
    if (data[0] != 0xFF or data[1] != 0xD8) return error.InvalidMarker;

    // Peek SOF: scan markers until we hit a SOFn byte to classify.
    // (Extraneous-bytes findings emit during the real decode walker
    // below, not this lightweight peek — the peek calls back into the
    // full decoder which re-walks from offset 0.)
    var pos: usize = 2;
    while (pos + 1 < data.len) {
        while (pos < data.len and data[pos] != 0xFF) pos += 1;
        if (pos + 1 >= data.len) return error.TruncatedStream;
        while (pos + 1 < data.len and data[pos + 1] == 0xFF) pos += 1;
        if (pos + 1 >= data.len) return error.TruncatedStream;
        const marker = data[pos + 1];
        if (marker == 0x00) {
            pos += 1;
            continue;
        }
        switch (marker) {
            0xC9 => return decodeArithBaseline(allocator, data, options),
            0xCA => return decodeArithProgressive(allocator, data, options),
            0xCB => return error.NotImplemented, // SOF11 deferred (no encoder produces it).
            0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7 => return error.NotImplemented,
            else => {
                pos += 2;
                // Length-prefixed marker — skip its payload. Standalone
                // markers (RST, TEM, EOI) wouldn't appear before SOF in a
                // well-formed JPEG; treat any length read here as best-effort.
                if (marker >= 0xD0 and marker <= 0xD7) continue;
                if (marker == 0x01 or marker == 0xD8 or marker == 0xD9) continue;
                pos += baseline.parseSegmentLength(data, pos);
            },
        }
    }
    return error.TruncatedStream;
}

/// Diagnostic-only: same shape as `decodeArithBaseline`'s Phase 1 but
/// stops after entropy decode + un-zig-zag (NO dequant, NO IDCT). Output
/// matches libjpeg-turbo's `jpeg_read_coefficients` byte-for-byte when
/// the cleanroom arithmetic decoder is correct. Used by the M2.5 audit
/// to localize coefficient-level divergence on subsampled-RGB fixtures.
pub const CoefDump = struct {
    num_components: u8,
    blocks_w: [4]u32 = .{ 0, 0, 0, 0 },
    blocks_h: [4]u32 = .{ 0, 0, 0, 0 },
    coefs: [4][]i16 = .{ &.{}, &.{}, &.{}, &.{} },

    pub fn deinit(self: *CoefDump, allocator: Allocator) void {
        for (&self.coefs) |*slot| {
            if (slot.len > 0) allocator.free(slot.*);
        }
        self.* = undefined;
    }
};

pub fn dumpCoefsSof9(allocator: Allocator, data: []const u8) Error!CoefDump {
    if (data.len < 4) return error.TruncatedStream;
    if (data[0] != 0xFF or data[1] != 0xD8) return error.InvalidMarker;

    var pos: usize = 2;
    var frame: ?baseline.FrameInfo = null;
    var quant_tables: [4]?[64]u16 = .{ null, null, null, null };
    var restart_interval: u32 = 0;
    var dac_dc_L: [4]u8 = .{ 0, 0, 0, 0 };
    var dac_dc_U: [4]u8 = .{ 1, 1, 1, 1 };
    var dac_ac_K: [4]u8 = .{ 5, 5, 5, 5 };

    while (pos + 1 < data.len) {
        while (pos < data.len and data[pos] != 0xFF) pos += 1;
        if (pos + 1 >= data.len) return error.TruncatedStream;
        while (pos + 1 < data.len and data[pos + 1] == 0xFF) pos += 1;
        if (pos + 1 >= data.len) return error.TruncatedStream;
        const marker = data[pos + 1];
        if (marker == 0x00) {
            pos += 1;
            continue;
        }
        pos += 2;
        switch (marker) {
            0xD9 => return error.TruncatedStream,
            0xC9 => {
                frame = try baseline.parseSof(data, pos);
                if (frame.?.precision != 8) return error.NotImplemented;
                pos += baseline.parseSegmentLength(data, pos);
            },
            0xDB => {
                try baseline.parseDqt(data, pos, &quant_tables);
                pos += baseline.parseSegmentLength(data, pos);
            },
            0xCC => {
                try parseDac(data, pos, &dac_dc_L, &dac_dc_U, &dac_ac_K);
                pos += baseline.parseSegmentLength(data, pos);
            },
            0xDD => {
                const seg_len = baseline.parseSegmentLength(data, pos);
                if (seg_len < 4 or pos + seg_len > data.len) return error.TruncatedStream;
                restart_interval = (@as(u32, data[pos + 2]) << 8) | data[pos + 3];
                pos += seg_len;
            },
            0xDA => {
                if (frame == null) return error.InvalidMarker;
                const scan = try baseline.parseSos(data, pos, &frame.?);
                // The SOF9 path decodes one interleaved scan; split-component frames stay out of scope.
                if (scan.count != frame.?.num_components) return error.InvalidMarker;
                pos += baseline.parseSegmentLength(data, pos);
                return try dumpScanCoefsSof9(allocator, data[pos..], &frame.?, &dac_dc_L, &dac_dc_U, &dac_ac_K, restart_interval);
            },
            0x01, 0xD0...0xD7 => continue,
            else => pos += baseline.parseSegmentLength(data, pos),
        }
    }
    return error.TruncatedStream;
}

fn dumpScanCoefsSof9(
    allocator: Allocator,
    data: []const u8,
    frame: *const baseline.FrameInfo,
    dac_dc_L: *const [4]u8,
    dac_dc_U: *const [4]u8,
    dac_ac_K: *const [4]u8,
    restart_interval: u32,
) Error!CoefDump {
    // Coefficient dumps are strict and silent.
    const base: usize = 0;
    const options: DecodeOptions = .{};
    const channels: u8 = frame.num_components;
    var max_h: u32 = 1;
    var max_v: u32 = 1;
    var i: usize = 0;
    while (i < channels) : (i += 1) {
        const c = &frame.components[i];
        if (@as(u32, c.h_factor) > max_h) max_h = @intCast(c.h_factor);
        if (@as(u32, c.v_factor) > max_v) max_v = @intCast(c.v_factor);
    }
    const mcu_pixel_w: u32 = max_h * 8;
    const mcu_pixel_h: u32 = max_v * 8;
    const mcu_cols: u32 = (frame.width + mcu_pixel_w - 1) / mcu_pixel_w;
    const mcu_rows: u32 = (frame.height + mcu_pixel_h - 1) / mcu_pixel_h;

    var dump: CoefDump = .{ .num_components = channels };
    errdefer dump.deinit(allocator);
    i = 0;
    while (i < channels) : (i += 1) {
        const eff_h: u32 = if (channels == 1) 1 else @as(u32, frame.components[i].h_factor);
        const eff_v: u32 = if (channels == 1) 1 else @as(u32, frame.components[i].v_factor);
        const bw = mcu_cols * eff_h;
        const bh = mcu_rows * eff_v;
        dump.blocks_w[i] = bw;
        dump.blocks_h[i] = bh;
        const total: usize = @as(usize, bw) * @as(usize, bh) * 64;
        dump.coefs[i] = try allocator.alloc(i16, total);
        @memset(dump.coefs[i], 0);
    }

    var state = arith_coder.ScanState.init(data);
    state.arith_dc_L = dac_dc_L.*;
    state.arith_dc_U = dac_dc_U.*;
    state.arith_ac_K = dac_ac_K.*;

    var mcus_since_rst: u32 = 0;
    var expected_rst: u8 = 0xD0;
    var mcu_y: u32 = 0;
    while (mcu_y < mcu_rows) : (mcu_y += 1) {
        var mcu_x: u32 = 0;
        while (mcu_x < mcu_cols) : (mcu_x += 1) {
            if (restart_interval > 0 and mcus_since_rst == restart_interval) {
                _ = try finishSegment(&state.qcoder, base, .interval, &expected_rst, options);
                state.resetForRestart();
                mcus_since_rst = 0;
            }
            var ci: usize = 0;
            while (ci < channels) : (ci += 1) {
                const comp = &frame.components[ci];
                const bvm: u32 = if (channels == 1) 1 else @intCast(comp.v_factor);
                const bhm: u32 = if (channels == 1) 1 else @intCast(comp.h_factor);
                var bv: u32 = 0;
                while (bv < bvm) : (bv += 1) {
                    var bh: u32 = 0;
                    while (bh < bhm) : (bh += 1) {
                        const bx: u32 = mcu_x * bhm + bh;
                        const by: u32 = mcu_y * bvm + bv;
                        const off: usize = (@as(usize, by) * @as(usize, dump.blocks_w[ci]) + @as(usize, bx)) * 64;
                        // Decode block: dc + 63 ac, in zig-zag space; then
                        // un-zig-zag into natural order (no dequant).
                        var zz: [64]i32 = .{0} ** 64;
                        const dc = arith_coder.decodeDcSof9(&state, ci, comp.dc_table) catch return error.BackendError;
                        zz[0] = dc;
                        arith_coder.decodeAcSof9(&state, comp.ac_table, &zz) catch return error.BackendError;
                        var n: usize = 0;
                        while (n < 64) : (n += 1) {
                            dump.coefs[ci][off + baseline.ZIGZAG[n]] = @intCast(zz[n]);
                        }
                    }
                }
            }
            mcus_since_rst += 1;
        }
    }
    return dump;
}

// ─────── SOF10 (progressive arithmetic) ─────────────────────────
//
// Mirrors progressive.zig's marker walk + per-scan dispatch, but
// (a) accepts SOF10 + DAC markers instead of SOF2 + DHT, and
// (b) invokes arith_coder's 4 scan-type handlers in place of the
// Huffman ones. Phase 2 (dequant + IDCT + chroma upsample + color
// convert) is reused verbatim via `progressive.assembleProgressiveGeneric`.
