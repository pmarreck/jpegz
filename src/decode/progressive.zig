//! Cleanroom 8/12-bit progressive JPEG decoder (T.81 SOF2).
//!
//! Progressive JPEG is fundamentally a different decoding model than
//! baseline: each scan carries only a *subset* of the DCT coefficients
//! (a contiguous spectral range Ss..Se in zig-zag order), and a single
//! file may have many scans interleaved. Each coefficient may also be
//! delivered in multiple "successive approximation" passes — first as
//! the upper bits (Ah=0, Al=k means "shift this value left by k"),
//! then refined by additional bits in subsequent scans (Ah>0).
//!
//! The decoder keeps a persistent coefficient buffer (per-component,
//! per-block, 64 i16 each) and updates it as each scan arrives. After
//! EOI, dequantize + un-zig-zag + IDCT every block to produce pixels.
//!
//! Reference: ITU-T T.81 §G (progressive DCT-based mode).
//!
//! Supported scope:
//!   - 8/12-bit precision (T.81 §A.4)
//!   - 1 component (grayscale) or 3 components (RGB / YCbCr)
//!   - Sampling factors: 1..4 each (handles 4:4:4, 4:2:0, 4:2:2)
//!   - Restart intervals with RST0..RST7 cycling
//! Unsupported layouts return NotImplemented; no runtime C fallback.
//!
//! Layout: this file holds the entry points, the marker walk and the frame
//! and scan headers. progressive_scan.zig decodes one scan (restarts and
//! recovery), progressive_block.zig holds the four per-block passes, and
//! progressive_assemble.zig dequantizes, runs the IDCT and produces pixels.

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

// Parts of this decoder live in sibling files (see Layout above).
const decodeOneScan = @import("progressive_scan.zig").decodeOneScan;
pub const assembleProgressiveGeneric = @import("progressive_assemble.zig").assembleProgressiveGeneric;

const PROG_DEBUG: bool = false;
pub inline fn dbg(comptime fmt: []const u8, args: anytype) void {
    if (comptime PROG_DEBUG) std.debug.print(fmt, args);
}

/// JPEG zig-zag scan order (T.81 Figure A.6). Same table baseline uses.
pub const ZIGZAG: [64]u8 = .{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

// Shared with baseline via jpeg_markers.zig (byte-identical frame types).
pub const ComponentInfo = jpeg_markers.ComponentInfo;
pub const FrameInfo = jpeg_markers.FrameInfo;

pub const ScanInfo = struct {
    num_components: u8,
    /// component_index_in_frame[i] for each scan-component i in 0..num_components
    comp_indices: [4]usize,
    ss: u8,
    se: u8,
    ah: u4,
    al: u4,
};

pub const Error = errors.DecodeError;

/// Diagnostic-only: progressive decode result with natural-order quantized
/// coefficients per component (post-entropy, pre-IDCT). For byte-level diff
/// against libjpeg-turbo's `jpeg_read_coefficients()` output (which is also
/// natural-order). Caller must `freeCoefDump(allocator, dump)` after use.
pub const CoefDump = struct {
    num_components: u8,
    blocks_w: [3]u32,
    blocks_h: [3]u32,
    coefs: [3][]i16, // natural-order, length blocks_w[i]*blocks_h[i]*64

    pub fn deinit(self: *CoefDump, allocator: Allocator) void {
        var i: usize = 0;
        while (i < self.num_components) : (i += 1) {
            if (self.coefs[i].len > 0) allocator.free(self.coefs[i]);
        }
        self.* = undefined;
    }
};

/// Decode the bitstream as far as `decode()` does, but instead of running
/// IDCT + color conversion, return the per-block dequantized coefficients
/// in NATURAL order (un-zig-zagged). The dequantization step IS applied
/// (matching libjpeg's `jpeg_read_coefficients` output, which is also
/// post-entropy but PRE-dequant — so the caller of this function should
/// know which one they want; here we dequant for parity with our own
/// `assembleProgressive` intermediate state).
///
/// Actually: libjpeg's `jpeg_read_coefficients` returns RAW (post-entropy,
/// PRE-dequant) coefficients in natural order. To match, we skip the
/// dequant step here and return the raw zig-zag-then-natural-permuted
/// coefficients.
pub fn decodeAndDumpCoefs(allocator: Allocator, data: []const u8) Error!CoefDump {
    // Same body as decode() up through the SOS scan-loop, but skip the
    // assembleProgressive step. Then un-zig-zag the per-block coefficients
    // into natural order to match libjpeg's `jpeg_read_coefficients`.
    if (data.len < 4) return error.TruncatedStream;
    if (data[0] != 0xFF or data[1] != 0xD8) return error.InvalidMarker;

    var pos: usize = 2;
    var frame: ?FrameInfo = null;
    var quant_tables: [4]?[64]u16 = .{ null, null, null, null };
    var dc_tables: [4]?huffman.HuffmanTable = .{ null, null, null, null };
    var ac_tables: [4]?huffman.HuffmanTable = .{ null, null, null, null };
    var coefs: [3][]i16 = .{ &.{}, &.{}, &.{} };
    var blocks_w: [3]u32 = .{ 0, 0, 0 };
    var blocks_h: [3]u32 = .{ 0, 0, 0 };
    var max_h: u32 = 1;
    var max_v: u32 = 1;
    var saw_eoi = false;
    var seen_sof = false;
    var restart_interval: u16 = 0;

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
        switch (marker) {
            0xD9 => {
                saw_eoi = true;
                break;
            },
            0xC2 => {
                frame = try parseSof(data, pos);
                // T.81 §G.1 progressive: 8-bit and 12-bit are both spec
                // and both produced by libjpeg-turbo (12-bit via
                // -progressive -precision 12). A3 (2026-05-13) closes
                // the 12-bit row via assembleProgressiveGeneric(12).
                if (frame.?.precision != 8 and frame.?.precision != 12)
                    return error.UnsupportedPrecision;
                if (frame.?.num_components != 1 and frame.?.num_components != 3) return error.NotImplemented;
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
                pos += parseSegmentLength(data, pos);
            },
            0xC0, 0xC1, 0xC3 => return error.NotImplemented,
            0xC9, 0xCA, 0xCB => return error.NotImplemented,
            0xC4 => {
                try parseDht(data, pos, &dc_tables, &ac_tables);
                pos += parseSegmentLength(data, pos);
            },
            0xDB => {
                try parseDqt(data, pos, &quant_tables);
                pos += parseSegmentLength(data, pos);
            },
            0xDD => { // DRI — restart interval
                const seg_len = parseSegmentLength(data, pos);
                if (seg_len != 4 or pos + seg_len > data.len) return error.TruncatedStream;
                restart_interval = (@as(u16, data[pos + 2]) << 8) | data[pos + 3];
                pos += seg_len;
            },
            0xDA => {
                if (!seen_sof) return error.InvalidMarker;
                const scan = try parseSos(data, pos, &frame.?);
                pos += parseSegmentLength(data, pos);
                pos = try decodeOneScan(data, pos, &frame.?, &dc_tables, &ac_tables, &coefs, &blocks_w, &blocks_h, max_h, max_v, &scan, restart_interval, .{});
            },
            0x01, 0xD0...0xD7 => continue,
            else => pos += parseSegmentLength(data, pos),
        }
    }
    if (!seen_sof) return error.InvalidMarker;

    // Un-zig-zag each block in place: coefs[ci][block_off..+64] is in
    // zig-zag order; rewrite as natural order so it matches libjpeg's
    // `jpeg_read_coefficients` output (which IS in natural order).
    var ci: u8 = 0;
    while (ci < frame.?.num_components) : (ci += 1) {
        const total_blocks: usize = @as(usize, blocks_w[ci]) * @as(usize, blocks_h[ci]);
        var bi: usize = 0;
        while (bi < total_blocks) : (bi += 1) {
            const off = bi * 64;
            var zz: [64]i16 = undefined;
            @memcpy(&zz, coefs[ci][off..][0..64]);
            var n: usize = 0;
            while (n < 64) : (n += 1) {
                coefs[ci][off + ZIGZAG[n]] = zz[n];
            }
        }
    }

    return CoefDump{
        .num_components = frame.?.num_components,
        .blocks_w = blocks_w,
        .blocks_h = blocks_h,
        .coefs = coefs,
    };
}

/// Caller-supplied knobs. Structurally mirrors `baseline.DecodeOptions`
/// so the dispatcher can pass through a `FindingsSink` uniformly.
/// A null sink suppresses findings; it does not enable recovery.
pub const DecodeOptions = struct {
    findings_sink: ?*findings_mod.FindingsSink = null,
    /// Opt into partial-pixel recovery for truncated entropy and restart
    /// deviations. An attached sink records warnings or failure findings.
    lenient: bool = false,
};

/// Decode a supported progressive JPEG (T.81 SOF2), with recovery disabled.
pub fn decode(allocator: Allocator, data: []const u8) Error!types.Image {
    return decodeWithOptions(allocator, data, .{});
}

/// Decode with optional recovery and findings. A recovered truncated restart
/// interval (or scan without restarts) emits one insufficient_data warning.
pub fn decodeWithOptions(
    allocator: Allocator,
    data: []const u8,
    options: DecodeOptions,
) Error!types.Image {
    if (data.len < 4) return error.TruncatedStream;
    if (data[0] != 0xFF or data[1] != 0xD8) return error.InvalidMarker;

    var pos: usize = 2;
    var frame: ?FrameInfo = null;
    var quant_tables: [4]?[64]u16 = .{ null, null, null, null };
    var dc_tables: [4]?huffman.HuffmanTable = .{ null, null, null, null };
    var ac_tables: [4]?huffman.HuffmanTable = .{ null, null, null, null };
    var coefs: [3][]i16 = .{ &.{}, &.{}, &.{} };
    var blocks_w: [3]u32 = .{ 0, 0, 0 };
    var blocks_h: [3]u32 = .{ 0, 0, 0 };
    var max_h: u32 = 1;
    var max_v: u32 = 1;
    var saw_eoi = false;
    var seen_sof = false;
    // EOB-run state persists ACROSS blocks within a single scan (T.81
    // §G.1.2.2 EOBRUN counter). Reset to zero at scan start.
    var eob_run: u32 = 0;
    _ = &eob_run; // populated inside scan-decoders
    var restart_interval: u16 = 0;
    // JFIF / Adobe APP14 seen before the frame decides RGB passthrough.
    var color_signals: cmyk_mod.ColorSignals = .{};

    errdefer {
        var i: usize = 0;
        while (i < 3) : (i += 1) if (coefs[i].len > 0) allocator.free(coefs[i]);
    }

    while (pos + 1 < data.len and !saw_eoi) {
        // Tolerate "extraneous bytes before marker" per T.81 §B.1.1.2 —
        // markers are self-synchronizing. Mirrors baseline.zig's
        // pattern; emit a warn finding when a sink is attached.
        const skip_start = pos;
        while (pos < data.len and data[pos] != 0xFF) pos += 1;
        if (pos > skip_start) {
            if (options.findings_sink) |sink| {
                var buf: [96]u8 = undefined;
                const next_marker: u8 = if (pos + 1 < data.len) data[pos + 1] else 0;
                const detail = std.fmt.bufPrint(&buf, "Corrupt JPEG data: {d} extraneous bytes before marker 0x{x:0>2}", .{ pos - skip_start, next_marker }) catch buf[0..0];
                sink.emit(.warn, .extraneous_bytes_before_marker, @intCast(skip_start), detail) catch return error.OutOfMemory;
            }
        }
        if (pos + 1 >= data.len) return error.TruncatedStream;
        // Skip 0xFF padding bytes (T.81 §B.1.1.2 fill); emit warn so
        // strict validators see deviations from canonical encoding.
        const fill_start = pos;
        while (pos + 1 < data.len and data[pos + 1] == 0xFF) pos += 1;
        if (pos > fill_start) {
            if (options.findings_sink) |sink| {
                var buf: [80]u8 = undefined;
                const next_marker: u8 = if (pos + 1 < data.len) data[pos + 1] else 0;
                const detail = std.fmt.bufPrint(&buf, "{d} extra 0xFF fill byte(s) before marker 0x{x:0>2}", .{ pos - fill_start, next_marker }) catch buf[0..0];
                sink.emit(.warn, .entropy_fill_bytes, @intCast(fill_start), detail) catch return error.OutOfMemory;
            }
        }
        if (pos + 1 >= data.len) return error.TruncatedStream;
        const marker = data[pos + 1];
        pos += 2;
        color_signals.observe(marker, data, pos);

        switch (marker) {
            0xD9 => { // EOI
                saw_eoi = true;
                break;
            },
            0xC2 => { // SOF2 — progressive DCT
                frame = try parseSof(data, pos);
                // T.81 §G.1 progressive at 8-bit OR 12-bit precision.
                // 12-bit support is A3 (2026-05-13); dispatch on
                // precision at assemble time via Phase 2 comptime
                // specialization.
                if (frame.?.precision != 8 and frame.?.precision != 12)
                    return error.UnsupportedPrecision;
                if (frame.?.num_components != 1 and frame.?.num_components != 3)
                    return error.NotImplemented;
                seen_sof = true;
                // Compute max sampling factors and per-component block grid.
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

                // Allocate persistent zig-zag-ordered coefficient buffers
                // for every block of every component. Size: blocks_w *
                // blocks_h * 64 i16 entries each.
                i = 0;
                while (i < frame.?.num_components) : (i += 1) {
                    const c = &frame.?.components[i];
                    blocks_w[i] = mcu_cols * @as(u32, c.h_factor);
                    blocks_h[i] = mcu_rows * @as(u32, c.v_factor);
                    const total: usize = @as(usize, blocks_w[i]) * @as(usize, blocks_h[i]) * 64;
                    coefs[i] = try allocator.alloc(i16, total);
                    @memset(coefs[i], 0);
                }
                pos += parseSegmentLength(data, pos);
            },
            0xC0, 0xC1, 0xC3 => return error.NotImplemented, // not progressive
            0xC9, 0xCA, 0xCB => return error.NotImplemented, // arithmetic
            0xC4 => { // DHT
                try parseDht(data, pos, &dc_tables, &ac_tables);
                pos += parseSegmentLength(data, pos);
            },
            0xDB => { // DQT
                try parseDqt(data, pos, &quant_tables);
                pos += parseSegmentLength(data, pos);
            },
            0xDD => { // DRI — restart interval
                const seg_len = parseSegmentLength(data, pos);
                if (seg_len != 4 or pos + seg_len > data.len) return error.TruncatedStream;
                restart_interval = (@as(u16, data[pos + 2]) << 8) | data[pos + 3];
                pos += seg_len;
            }, // DRI in progressive — v1.x follow-up
            0xDA => { // SOS
                if (!seen_sof) return error.InvalidMarker;
                const scan = try parseSos(data, pos, &frame.?);
                pos += parseSegmentLength(data, pos);
                // Decode this scan into coefficient buffers; return the
                // byte position past the entropy data (just before the
                // next marker's 0xFF).
                pos = try decodeOneScan(
                    data,
                    pos,
                    &frame.?,
                    &dc_tables,
                    &ac_tables,
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
            // Standalone markers we can skip safely.
            0x01, 0xD0...0xD7 => continue,
            // Length-prefixed markers we can skip (APPn, COM, etc.).
            else => pos += parseSegmentLength(data, pos),
        }
    }

    if (!seen_sof) return error.InvalidMarker;

    // ── Final pass: dequant + IDCT each block, emit pixels ────────
    // Dispatch on precision at comptime via the generic Phase 2.
    const rgb_passthrough = frameRgbPassthrough(&frame.?, color_signals);
    return switch (frame.?.precision) {
        8 => try assembleProgressiveGeneric(8, allocator, &frame.?, &quant_tables, &coefs, &blocks_w, &blocks_h, max_h, max_v, rgb_passthrough, options.findings_sink),
        12 => try assembleProgressiveGeneric(12, allocator, &frame.?, &quant_tables, &coefs, &blocks_w, &blocks_h, max_h, max_v, rgb_passthrough, options.findings_sink),
        else => unreachable, // gated above
    };
}

pub const parseSegmentLength = @import("segment.zig").parseSegmentLength;

pub const ColorSignals = cmyk_mod.ColorSignals;

/// libjpeg-turbo's RGB precedence for this frame (see cmyk.rgbPassthrough).
pub fn frameRgbPassthrough(frame: *const FrameInfo, signals: cmyk_mod.ColorSignals) bool {
    if (frame.num_components != 3) return false;
    return cmyk_mod.rgbPassthrough(3, signals, .{ frame.components[0].id, frame.components[1].id, frame.components[2].id });
}

// SOF / DQT / DHT parsing shared with baseline (see jpeg_markers.zig).
pub const parseSof = jpeg_markers.parseSof;

pub const parseDqt = jpeg_markers.parseDqt;

const parseDht = jpeg_markers.parseDht;

pub fn parseSos(data: []const u8, pos: usize, frame: *FrameInfo) Error!ScanInfo {
    const seg_len = parseSegmentLength(data, pos);
    if (seg_len < 6 or pos + seg_len > data.len) return error.TruncatedStream;
    var info: ScanInfo = undefined;
    info.num_components = data[pos + 2];
    if (info.num_components == 0 or info.num_components > 4)
        return error.InvalidMarker;

    var i: usize = 0;
    while (i < info.num_components) : (i += 1) {
        const off = pos + 3 + i * 2;
        const cs = data[off];
        const td_ta = data[off + 1];
        var found: bool = false;
        var j: usize = 0;
        while (j < frame.num_components) : (j += 1) {
            if (frame.components[j].id == cs) {
                frame.components[j].dc_table = td_ta >> 4;
                frame.components[j].ac_table = td_ta & 0x0F;
                info.comp_indices[i] = j;
                found = true;
                break;
            }
        }
        if (!found) return error.InvalidMarker;
    }
    const tail_off = pos + 3 + info.num_components * 2;
    info.ss = data[tail_off];
    info.se = data[tail_off + 1];
    const ah_al = data[tail_off + 2];
    info.ah = @intCast(ah_al >> 4);
    info.al = @intCast(ah_al & 0x0F);
    // T.81 §G.1.1.1.1 bounds Al to 0..13; the validator reports larger
    // values as progressive_scan_invalid. Rejecting them here also keeps
    // the refinement bit `1 << Al` within i16.
    if (info.al > 13) return error.InvalidMarker;
    return info;
}
