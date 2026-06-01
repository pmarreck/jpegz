//! Cleanroom 8-bit baseline JPEG decoder (T.81 SOF0).
//!
//! v1 scope:
//!   - 8-bit precision (T.81 §A.4)
//!   - Sequential DCT with Huffman entropy coding (SOF0)
//!   - 1 component (grayscale) or 3 components (RGB / YCbCr)
//!   - Sampling factors: all components 1×1 (no chroma subsampling)
//!   - No restart markers (DRI=0)
//!   - All segments present and well-formed
//!
//! Out of scope for this iteration (handled by libjpeg_wrapper fallback):
//!   - SOF1 (extended sequential), SOF2 (progressive), SOF3 (lossless)
//!   - Arithmetic-coded variants (SOF9/10/11)
//!   - Chroma subsampling (4:2:0, 4:2:2 — see Tier 1 fixtures)
//!   - Restart markers
//!   - 12-bit precision
//!   - CMYK / YCCK
//!
//! Reference: ITU-T T.81 (1992), Annex F (sequential DCT).

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

const builtin = @import("builtin");

/// Debug-only error annotation: in Debug builds, prints a tagged
/// trace line to stderr ("[baseline:tag] err.X") so the
/// cleanroom-diff tool can pinpoint where each error originates
/// without rewriting every call-site. In ReleaseFast/Safe/Small
/// builds the helper inlines to a plain `return err` with zero
/// runtime cost.
// Thin module-prefixed wrapper over the shared `diag.fail` (single
// implementation in decode/diag.zig). Call sites stay `fail("tag", err)`
// and still print "[baseline:tag] ErrorName" in Debug builds.
inline fn fail(comptime tag: []const u8, err: errors.DecodeError) errors.DecodeError {
    return @import("diag.zig").fail("baseline:" ++ tag, err);
}

/// Resync the entropy stream at a restart-interval boundary
/// (T.81 §F.2.1.3). Strict mode hard-fails on a missing or
/// wrong-cycle RSTm marker. Lenient mode + sink emits a warn finding
/// (`restart_marker_missing` or `restart_marker_unexpected`), resets
/// the DC predictors, advances `expected_rst` to the next position
/// in the 0xD0..0xD7 cycle, and continues. Any non-RST marker (EOI,
/// DNL, premature SOF) still hard-fails so callers see real
/// end-of-scan signals instead of pixel garbage.
fn handleRstResync(
    br: *bitstream.BitReader,
    expected_rst: *u8,
    prev_dc: *[4]i32,
    mcus_since_rst: *u32,
    options: DecodeOptions,
) errors.DecodeError!void {
    // Force the reader to look ahead for the marker — the bit
    // buffer may still hold padding bits that haven't triggered a
    // refill yet.
    br.seekToMarker();

    if (!br.marker_seen) {
        if (options.lenient) {
            if (options.findings_sink) |sink| {
                sink.emit(.warn, .restart_marker_missing,
                    @intCast(br.byte_pos),
                    "expected RSTm marker not found at restart-interval boundary; continuing with reset DC predictors")
                    catch return error.OutOfMemory;
            }
            prev_dc.* = .{ 0, 0, 0, 0 };
            mcus_since_rst.* = 0;
            expected_rst.* = 0xD0 + ((expected_rst.* - 0xD0 + 1) & 0x07);
            return;
        }
        return fail("rst_no_marker_seen", error.InvalidMarker);
    }

    if (br.marker_byte != expected_rst.*) {
        const got_rst = br.marker_byte >= 0xD0 and br.marker_byte <= 0xD7;
        if (options.lenient and got_rst) {
            if (options.findings_sink) |sink| {
                var buf: [96]u8 = undefined;
                const detail = std.fmt.bufPrint(&buf,
                    "expected RST{d} (0x{x:0>2}) but got RST{d} (0x{x:0>2})",
                    .{ expected_rst.* - 0xD0, expected_rst.*,
                       br.marker_byte - 0xD0, br.marker_byte })
                    catch buf[0..0];
                sink.emit(.warn, .restart_marker_unexpected,
                    @intCast(br.byte_pos), detail) catch return error.OutOfMemory;
            }
            prev_dc.* = .{ 0, 0, 0, 0 };
            mcus_since_rst.* = 0;
            // Resync expected_rst to the cycle after what we just saw.
            expected_rst.* = 0xD0 + ((br.marker_byte - 0xD0 + 1) & 0x07);
            br.skipPastMarker();
            return;
        }
        return fail("rst_wrong_marker", error.InvalidMarker);
    }

    // Happy path: marker matches.
    prev_dc.* = .{ 0, 0, 0, 0 };
    mcus_since_rst.* = 0;
    expected_rst.* = 0xD0 + ((expected_rst.* - 0xD0 + 1) & 0x07);
    br.skipPastMarker();
}

/// JPEG zig-zag scan order (T.81 Figure A.6). Maps zig-zag index
/// (the order in which AC coefficients arrive in the entropy stream)
/// to natural (row-major) order in the 8×8 block.
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

pub const ComponentInfo = struct {
    /// Component selector (Ci in T.81 SOF — usually 1 for Y, 2 for Cb, 3 for Cr).
    id: u8,
    /// Sampling factors. We only support 1×1 in v1.
    h_factor: u4,
    v_factor: u4,
    /// Quantization table selector (0..3).
    qt_index: u8,
    /// DC + AC Huffman table selectors (set when SOS parsed).
    dc_table: u8 = 0,
    ac_table: u8 = 0,
};

pub const FrameInfo = struct {
    precision: u8,
    height: u16,
    width: u16,
    num_components: u8,
    components: [4]ComponentInfo,
};

pub const Error = errors.DecodeError;

/// Caller-controlled options for the cleanroom decoder. Mirrors the
/// public `jpegz.DecodeOptions` shape so we can plumb it through
/// without depending on the parent module (avoids an import cycle).
/// Today only `threads` is honored; struct can grow more knobs.
pub const DecodeOptions = struct {
    threads: u8 = 1,
    /// Optional side-channel for spec-deviation findings. Caller owns
    /// the sink. `null` (default) skips emission entirely. Used both
    /// for `extraneous_bytes_before_marker` (always emits when sink
    /// is set, regardless of `lenient`) and — when `lenient` is also
    /// true — `insufficient_data` on truncated entropy.
    findings_sink: ?*findings_mod.FindingsSink = null,
    /// When false (default), the decoder is strict: truncated entropy
    /// returns `error.TruncatedStream`. When true, the decoder mirrors
    /// libjpeg-turbo's tolerant behavior — partial blocks left at zero,
    /// scan exits gracefully, the rest of the image decodes from there,
    /// and a `Finding(.warn, .insufficient_data)` is emitted via
    /// `findings_sink` (when one is attached). Useful for thumbnail
    /// generators, validators, viewers — any consumer that prefers
    /// best-effort over error. The general-purpose `jpegz.decode`
    /// stays strict by default.
    lenient: bool = false,
};

/// Decode an 8-bit baseline JPEG. Sequential / single-threaded.
///
/// Returns `error.NotImplemented` for any feature the v1 cleanroom
/// doesn't yet support (progressive, lossless, arithmetic, etc.) —
/// the caller (`src/jpegz.zig`) is expected to fall back to the
/// libjpeg-turbo wrapper in that case.
pub fn decode(allocator: Allocator, data: []const u8) Error!types.Image {
    return decodeWithOptions(allocator, data, .{});
}

/// Same as `decode` but accepts `DecodeOptions`. M2.1d landed the
/// caller-controlled threading surface; the parallelism implementation
/// is a follow-up — for now `threads` is accepted but the cleanroom
/// runs sequentially regardless. Default behavior unchanged.
pub fn decodeWithOptions(
    allocator: Allocator,
    data: []const u8,
    options: DecodeOptions,
) Error!types.Image {
    return decodeImpl(allocator, data, options);
}

fn decodeImpl(allocator: Allocator, data: []const u8, options: DecodeOptions) Error!types.Image {
    if (data.len < 4) return fail("entry_too_short", error.TruncatedStream);
    if (data[0] != 0xFF or data[1] != 0xD8) return fail("entry_no_soi", error.InvalidMarker);

    var pos: usize = 2;
    var frame: ?FrameInfo = null;
    var quant_tables: [4]?[64]u16 = .{ null, null, null, null };
    var dc_tables: [4]?huffman.HuffmanTable = .{ null, null, null, null };
    var ac_tables: [4]?huffman.HuffmanTable = .{ null, null, null, null };
    // Restart interval (DRI marker) — number of MCUs between RSTm
    // resync markers. 0 disables restart handling.
    var restart_interval: u32 = 0;
    // APP14 (Adobe) ColorTransform byte. Only consulted for
    // 4-component frames to pick CMYK vs YCCK assembly. `.none`
    // (no APP14 seen) → treat 4-comp as raw CMYK per libjpeg-turbo
    // default.
    var app14_color_transform: cmyk_mod.ColorTransform = .none;
    // Track whether the file declared JFIF (APP0 "JFIF\0") so that
    // we can flag colorspace conflicts when APP14 (Adobe) also shows
    // up with a non-YCbCr ColorTransform — JFIF implies YCbCr for
    // 3-component frames.
    var saw_jfif: bool = false;
    // Offset of the conflicting APP14 segment (set during walk; emit
    // happens after SOF arrives so the warning carries the SOF
    // component count if needed).
    var app14_conflict_offset: ?u64 = null;

    // ── Marker walk until we reach SOS ─────────────────────────
    while (pos + 1 < data.len) {
        // Tolerate "extraneous bytes before marker" — djpeg/libjpeg-turbo
        // recover from this and so do we (per T.81 §B.1.1.2 markers are
        // self-synchronizing). Scan forward to the next 0xFF byte.
        const skip_start = pos;
        while (pos < data.len and data[pos] != 0xFF) pos += 1;
        if (pos > skip_start) {
            if (options.findings_sink) |sink| {
                // Mirror libjpeg's "Corrupt JPEG data: N extraneous bytes
                // before marker 0xXX" warning text so consumers can grep
                // across cleanroom and wrapper paths uniformly.
                var buf: [96]u8 = undefined;
                const next_marker: u8 = if (pos + 1 < data.len) data[pos + 1] else 0;
                const detail = std.fmt.bufPrint(&buf,
                    "Corrupt JPEG data: {d} extraneous bytes before marker 0x{x:0>2}",
                    .{ pos - skip_start, next_marker }) catch buf[0..0];
                sink.emit(.warn, .extraneous_bytes_before_marker,
                    @intCast(skip_start), detail) catch return error.OutOfMemory;
            }
        }
        if (pos + 1 >= data.len) return fail("walker_eof_after_ff", error.TruncatedStream);
        // Skip 0xFF padding bytes (T.81 §B.1.1.2: legal "fill" but
        // non-canonical). Emit a warn finding so strict validators
        // see the spec deviation.
        const fill_start = pos;
        while (pos + 1 < data.len and data[pos + 1] == 0xFF) pos += 1;
        if (pos > fill_start) {
            if (options.findings_sink) |sink| {
                var buf: [80]u8 = undefined;
                const next_marker: u8 = if (pos + 1 < data.len) data[pos + 1] else 0;
                const detail = std.fmt.bufPrint(&buf,
                    "{d} extra 0xFF fill byte(s) before marker 0x{x:0>2}",
                    .{ pos - fill_start, next_marker }) catch buf[0..0];
                sink.emit(.warn, .entropy_fill_bytes,
                    @intCast(fill_start), detail) catch return error.OutOfMemory;
            }
        }
        if (pos + 1 >= data.len) return fail("walker_eof_after_ff", error.TruncatedStream);
        const marker = data[pos + 1];
        // 0xFF 0x00 here would be byte-stuffing inside an entropy stream —
        // we shouldn't see it during the marker walk (entropy data is
        // consumed by decodeScan after SOS, not here). Treat as garbage
        // and advance one byte.
        if (marker == 0x00) {
            pos += 1;
            continue;
        }
        pos += 2;

        switch (marker) {
            0xD9 => return fail("eoi_before_sos", error.TruncatedStream),
            0xC0, 0xC1 => { // SOF0 baseline DCT or SOF1 extended sequential DCT
                // Per T.81 §A.4.2 / F.1.1: at 8-bit precision the SOF1
                // bitstream is byte-identical to SOF0; only the marker
                // byte differs. At 12-bit precision SOF1 (extended
                // sequential, T.81 §F.1.1) is supported for both
                // 1-component grayscale (A1 Part A) and 3-component
                // YCbCr→RGB (A1 Part B). Other component counts at
                // P=12 still fall through to the wrapper.
                frame = try parseSof(data, pos);
                // 8-bit: 1/3/4 components (gray, RGB/YCbCr, CMYK/YCCK).
                // 12-bit: 1/3 only (CMYK 12-bit isn't in v1 scope).
                const p_ok = frame.?.precision == 8 or
                    (frame.?.precision == 12 and
                        (frame.?.num_components == 1 or frame.?.num_components == 3));
                if (!p_ok) return fail("sof_precision_not_supported", error.NotImplemented);
                if (frame.?.num_components == 0 or frame.?.num_components > 4)
                    return fail("sof_unsupported_ncomp", error.NotImplemented);
                if (frame.?.num_components == 2)
                    return fail("sof_unsupported_ncomp", error.NotImplemented);
                // APP14/JFIF colorspace-conflict warn fires here, now
                // that we know the component count. JFIF strictly
                // applies to 3-component frames (1-component is
                // grayscale; 4-component is outside JFIF's contract,
                // so APP14 always wins without conflict there).
                if (app14_conflict_offset != null and frame.?.num_components == 3) {
                    if (options.findings_sink) |sink| {
                        var buf: [128]u8 = undefined;
                        const ct_byte: u8 = switch (app14_color_transform) {
                            .cmyk => 0,
                            .ycbcr => 1,
                            .ycck => 2,
                            .none => 0xFF,
                        };
                        const detail = std.fmt.bufPrint(&buf,
                            "JFIF APP0 implies YCbCr but Adobe APP14 ColorTransform={d} disagrees",
                            .{ct_byte}) catch buf[0..0];
                        sink.emit(.warn, .adobe_app14_conflicts_jfif,
                            app14_conflict_offset, detail) catch return error.OutOfMemory;
                    }
                    app14_conflict_offset = null;
                }
                var i: usize = 0;
                while (i < frame.?.num_components) : (i += 1) {
                    const c = &frame.?.components[i];
                    if (c.h_factor < 1 or c.h_factor > 4 or c.v_factor < 1 or c.v_factor > 4)
                        return fail("sof_bad_sampling", error.NotImplemented);
                }
                pos += parseSegmentLength(data, pos);
            },
            0xC2, 0xC3 => return fail("sof_not_baseline", error.NotImplemented),
            0xC9, 0xCA, 0xCB => return fail("sof_arithmetic", error.NotImplemented),
            0xC4 => { // DHT
                try parseDht(data, pos, &dc_tables, &ac_tables);
                pos += parseSegmentLength(data, pos);
            },
            0xDB => { // DQT
                try parseDqt(data, pos, &quant_tables);
                pos += parseSegmentLength(data, pos);
            },
            0xDD => { // DRI — Define Restart Interval (T.81 §B.2.4.4)
                const seg_len = parseSegmentLength(data, pos);
                if (seg_len < 4 or pos + seg_len > data.len) return error.TruncatedStream;
                restart_interval = (@as(u32, data[pos + 2]) << 8) | data[pos + 3];
                pos += seg_len;
            },
            0xDA => { // SOS — entropy data follows
                if (frame == null) return fail("sos_before_sof", error.InvalidMarker);
                try parseSos(data, pos, &frame.?);
                pos += parseSegmentLength(data, pos);
                // 12-bit grayscale (A1 Part A) and 12-bit RGB (A1 Part B)
                // route to their own focused paths. Everything else
                // goes through the 8-bit pipeline.
                if (frame.?.precision == 12 and frame.?.num_components == 1) {
                    return try decodeScan12Gray(
                        allocator,
                        data[pos..],
                        &frame.?,
                        &quant_tables,
                        &dc_tables,
                        &ac_tables,
                        restart_interval,
                        options,
                    );
                }
                if (frame.?.precision == 12 and frame.?.num_components == 3) {
                    return try decodeScan12Rgb(
                        allocator,
                        data[pos..],
                        &frame.?,
                        &quant_tables,
                        &dc_tables,
                        &ac_tables,
                        restart_interval,
                        options,
                    );
                }
                return try decodeScan(
                    allocator,
                    data[pos..],
                    &frame.?,
                    &quant_tables,
                    &dc_tables,
                    &ac_tables,
                    restart_interval,
                    options,
                    app14_color_transform,
                );
            },
            // Standalone markers we can skip safely:
            0x01, 0xD0...0xD7 => continue, // TEM, RST0..RST7
            // APP0 — detect JFIF signature so we can flag colorspace
            // conflicts when APP14 also disagrees. Body is skipped
            // beyond the signature check.
            0xE0 => {
                const seg_len = parseSegmentLength(data, pos);
                if (seg_len >= 7 and pos + seg_len <= data.len) {
                    const body = data[pos + 2 .. pos + seg_len];
                    if (body.len >= 5 and std.mem.eql(u8, body[0..5], "JFIF\x00")) {
                        saw_jfif = true;
                    }
                }
                pos += seg_len;
            },
            // APP14 (Adobe) — parse out ColorTransform for 4-component
            // CMYK/YCCK disambiguation. Other APP segments are skipped.
            0xEE => {
                const app14_marker_offset = pos - 2; // FF EE byte position
                const seg_len = parseSegmentLength(data, pos);
                if (seg_len >= 2 and pos + seg_len <= data.len and pos + seg_len > pos + 2) {
                    const body = data[pos + 2 .. pos + seg_len];
                    if (cmyk_mod.parseApp14ColorTransform(body)) |ct| {
                        app14_color_transform = ct;
                        // JFIF implies YCbCr (3-component); APP14
                        // ColorTransform != ycbcr disagrees. Stash the
                        // marker offset; emit after we see SOF (we want
                        // the component count to confirm 3-comp scope,
                        // but the warning surfaces the moment we know).
                        if (saw_jfif and ct != .ycbcr) {
                            app14_conflict_offset = @intCast(app14_marker_offset);
                        }
                    }
                }
                pos += parseSegmentLength(data, pos);
            },
            // Length-prefixed markers we can skip (other APPn, COM, etc.):
            else => pos += parseSegmentLength(data, pos),
        }
    }

    return error.TruncatedStream;
}

// Shared spec primitive (also re-exported for arith_decode, which
// imports `baseline.parseSegmentLength`). Single definition lives in
// segment.zig.
pub const parseSegmentLength = @import("segment.zig").parseSegmentLength;

pub fn parseSof(data: []const u8, pos: usize) Error!FrameInfo {
    const seg_len = parseSegmentLength(data, pos);
    if (seg_len < 8 or pos + seg_len > data.len) return error.TruncatedStream;
    var fi: FrameInfo = undefined;
    fi.precision = data[pos + 2];
    fi.height = (@as(u16, data[pos + 3]) << 8) | data[pos + 4];
    fi.width = (@as(u16, data[pos + 5]) << 8) | data[pos + 6];
    fi.num_components = data[pos + 7];
    if (fi.num_components == 0 or fi.num_components > 4) return fail("sof_bad_ncomp", error.InvalidMarker);
    if (seg_len < 8 + @as(usize, fi.num_components) * 3) return error.TruncatedStream;
    var i: usize = 0;
    while (i < fi.num_components) : (i += 1) {
        const off = pos + 8 + i * 3;
        fi.components[i] = .{
            .id = data[off],
            .h_factor = @intCast(data[off + 1] >> 4),
            .v_factor = @intCast(data[off + 1] & 0x0F),
            .qt_index = data[off + 2],
        };
    }
    return fi;
}

pub fn parseDqt(
    data: []const u8,
    pos: usize,
    quant_tables: *[4]?[64]u16,
) Error!void {
    const seg_len = parseSegmentLength(data, pos);
    if (seg_len < 2 or pos + seg_len > data.len) return error.TruncatedStream;
    var off: usize = pos + 2;
    const seg_end = pos + seg_len;
    while (off < seg_end) {
        if (off >= data.len) return error.TruncatedStream;
        const pq_tq = data[off];
        const precision_id: u8 = pq_tq >> 4; // 0 = 8-bit, 1 = 16-bit
        const tq: u8 = pq_tq & 0x0F;
        if (tq > 3) return fail("dqt_bad_tq", error.InvalidMarker);
        off += 1;
        var table: [64]u16 = undefined;
        if (precision_id == 0) {
            // 8-bit values
            if (off + 64 > seg_end) return error.TruncatedStream;
            var i: usize = 0;
            while (i < 64) : (i += 1) {
                table[i] = data[off + i];
            }
            off += 64;
        } else if (precision_id == 1) {
            if (off + 128 > seg_end) return error.TruncatedStream;
            var i: usize = 0;
            while (i < 64) : (i += 1) {
                table[i] = (@as(u16, data[off + i * 2]) << 8) | data[off + i * 2 + 1];
            }
            off += 128;
        } else return fail("dqt_bad_precision_id", error.InvalidMarker);
        quant_tables[tq] = table;
    }
}

fn parseDht(
    data: []const u8,
    pos: usize,
    dc_tables: *[4]?huffman.HuffmanTable,
    ac_tables: *[4]?huffman.HuffmanTable,
) Error!void {
    const seg_len = parseSegmentLength(data, pos);
    if (seg_len < 2 or pos + seg_len > data.len) return error.TruncatedStream;
    var off: usize = pos + 2;
    const seg_end = pos + seg_len;
    while (off < seg_end) {
        if (off + 17 > seg_end) return error.TruncatedStream;
        const tc_th = data[off];
        const tc: u8 = tc_th >> 4; // 0 = DC, 1 = AC
        const th: u8 = tc_th & 0x0F;
        if (tc > 1 or th > 3) return fail("dht_bad_tc_th", error.InvalidMarker);
        off += 1;
        var bits: [16]u8 = undefined;
        var total: u16 = 0;
        for (0..16) |i| {
            bits[i] = data[off + i];
            total += bits[i];
        }
        off += 16;
        if (off + total > seg_end) return error.TruncatedStream;
        const values = data[off .. off + total];
        const t = huffman.HuffmanTable.buildFromDht(bits, values) catch
            return fail("dht_build_failed", error.InvalidMarker);
        if (tc == 0) dc_tables[th] = t else ac_tables[th] = t;
        off += total;
    }
}

pub fn parseSos(data: []const u8, pos: usize, frame: *FrameInfo) Error!void {
    const seg_len = parseSegmentLength(data, pos);
    if (seg_len < 6 or pos + seg_len > data.len) return error.TruncatedStream;
    const ns = data[pos + 2];
    if (ns != frame.num_components) return fail("sos_ns_mismatch", error.InvalidMarker);
    var i: usize = 0;
    while (i < ns) : (i += 1) {
        const off = pos + 3 + i * 2;
        const cs = data[off];
        const td_ta = data[off + 1];
        // Find the matching component in frame.components by ID.
        var j: usize = 0;
        while (j < frame.num_components) : (j += 1) {
            if (frame.components[j].id == cs) {
                frame.components[j].dc_table = td_ta >> 4;
                frame.components[j].ac_table = td_ta & 0x0F;
                break;
            }
        }
    }
    // Ss/Se/Ah/Al in the last 3 bytes — for baseline they're 0/63/0/0.
}

fn decodeScan(
    allocator: Allocator,
    data: []const u8,
    frame: *const FrameInfo,
    quant_tables: *const [4]?[64]u16,
    dc_tables: *const [4]?huffman.HuffmanTable,
    ac_tables: *const [4]?huffman.HuffmanTable,
    restart_interval: u32,
    options: DecodeOptions,
    app14_color_transform: cmyk_mod.ColorTransform,
) Error!types.Image {
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

    var planes: [4][]u8 = .{ &.{}, &.{}, &.{}, &.{} };
    {
        var i: usize = 0;
        while (i < channels) : (i += 1) {
            planes[i] = try allocator.alloc(u8, plane_w[i] * plane_h[i]);
        }
    }
    errdefer {
        var j: usize = 0;
        while (j < channels) : (j += 1) {
            if (planes[j].len > 0) allocator.free(planes[j]);
        }
    }

    // Two-pass pipeline structure. Phase 1 (entropy decode) is inherently
    // serial — DC predictors chain across MCUs within an RST segment.
    // Phase 2 (IDCT + plane copy) is per-block independent and is the
    // hook for parallelism (M2.1d follow-up). For each component we hold
    // a coefficient buffer of [num_blocks_y][num_blocks_x][64]i32 in
    // natural row-major order. Memory cost is modest: a 1500×1026 4:4:4
    // image is 188×129×3×64×4 = ~18.6 MB; a typical 216×216 photo is
    // 27×27×3×64×4 = ~559 KB.
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
    {
        var i: usize = 0;
        while (i < channels) : (i += 1) {
            const total_blocks: usize = @as(usize, blocks_w[i]) * @as(usize, blocks_h[i]);
            coef_buf[i] = try allocator.alloc(i32, total_blocks * 64);
        }
    }
    defer {
        var j: usize = 0;
        while (j < channels) : (j += 1) {
            if (coef_buf[j].len > 0) allocator.free(coef_buf[j]);
        }
    }

    var br = bitstream.BitReader.init(data);
    // Accumulator: T.81 §F.1.2.1 says DC predictor "shall be initialized
    // to 0 and reset whenever a restart marker is encountered." The
    // running value walks through coefficient differentials; use i32
    // so multi-block accumulation can't overflow i16's ±32767 range.
    // Sized [4] for 4-component (CMYK / YCCK) frames; 1- and 3-comp
    // scans only touch [0..channels).
    var prev_dc: [4]i32 = .{ 0, 0, 0, 0 };
    // Counts MCUs since the last RST. Reset to zero on every RST
    // (and at scan start). Used only when restart_interval > 0.
    var mcus_since_rst: u32 = 0;
    // Expected next RST marker byte (cycles 0xD0..0xD7). T.81 §F.2.1.3.
    var expected_rst: u8 = 0xD0;
    // Per-scan lenient recovery state — flips on first truncation; all
    // subsequent blocks short-circuit to zero coefs. No-op when
    // `options.lenient == false` (i.e., the leaves still hard-fail).
    var lenient_state: LenientState = .{
        .lenient = options.lenient,
        .sink = options.findings_sink,
    };

    // ── Phase 1: serial entropy decode → coefficient buffer ────
    var mcu_y: u32 = 0;
    while (mcu_y < mcu_rows) : (mcu_y += 1) {
        var mcu_x: u32 = 0;
        while (mcu_x < mcu_cols) : (mcu_x += 1) {
            // ── Restart-interval handling (T.81 §F.2.1.3.2) ────
            // After `restart_interval` MCUs, the entropy stream is
            // realigned: bit buffer flushed to next byte boundary,
            // an RSTm marker (FF D0..D7) consumed, prev_dc reset
            // to zero. Markers cycle through 0..7 across the scan.
            if (restart_interval > 0 and mcus_since_rst == restart_interval) {
                try handleRstResync(&br, &expected_rst, &prev_dc, &mcus_since_rst, options);
            }
            // Per T.81 §A.2.3 / F.1.5: when the scan has multiple
            // components, the MCU contains, for each component in
            // SOS order, (h_factor × v_factor) blocks. Within a
            // component's blocks: row-major (top-to-bottom, then
            // left-to-right). E.g. 4:2:0 RGB MCU: Y[0,0] Y[0,1]
            // Y[1,0] Y[1,1] Cb[0,0] Cr[0,0].
            var ci: usize = 0;
            while (ci < channels) : (ci += 1) {
                const comp = &frame.components[ci];
                // Per T.81 §A.2.2: non-interleaved scans (Ns=1) ignore the
                // component's declared H/V factors and emit one 8×8 block
                // per MCU. Otherwise honor the component's factors.
                const blocks_v_per_mcu: u32 = if (channels == 1) 1 else @intCast(comp.v_factor);
                const blocks_h_per_mcu: u32 = if (channels == 1) 1 else @intCast(comp.h_factor);
                var block_v: u32 = 0;
                while (block_v < blocks_v_per_mcu) : (block_v += 1) {
                    var block_h: u32 = 0;
                    while (block_h < blocks_h_per_mcu) : (block_h += 1) {
                        const block_idx_x: u32 = mcu_x * blocks_h_per_mcu + block_h;
                        const block_idx_y: u32 = mcu_y * blocks_v_per_mcu + block_v;
                        const linear: usize = (@as(usize, block_idx_y) * @as(usize, blocks_w[ci]) + @as(usize, block_idx_x)) * 64;
                        const slot: *[64]i32 = coef_buf[ci][linear..][0..64];
                        try decodeBlockCoefficients(
                            &br,
                            ci,
                            comp,
                            dc_tables,
                            ac_tables,
                            quant_tables,
                            &prev_dc,
                            slot,
                            frame.precision,
                            &lenient_state,
                        );
                    }
                }
            }
            mcus_since_rst += 1;
        }
    }

    // ── Phase 2: per-block IDCT + plane copy ──────────────────
    // Per-block work is independent: each task reads its own coefficient
    // slot and writes a non-overlapping 8×8 region of the (already
    // allocated) component plane. No shared mutable state; safe to
    // parallelize without locks.
    //
    // Decision tree:
    //   options.threads == 1 → sequential (zero pool overhead).
    //   small image (any plane has < PARALLEL_BLOCKS_THRESHOLD blocks)
    //     → sequential (thread setup eats the gains).
    //   else → thread_pool.Pool with options.threads workers (or
    //     std.Thread.getCpuCount() if options.threads == 0).
    const total_blocks: u64 = blk: {
        var sum: u64 = 0;
        for (0..channels) |ci_idx| {
            sum += @as(u64, blocks_w[ci_idx]) * @as(u64, blocks_h[ci_idx]);
        }
        break :blk sum;
    };
    // Below this threshold, sequential is faster than parallel. Tuned
    // based on benchmark results: thread spawn + join is ~50µs on macOS
    // arm64, and one IDCT block is ~100ns, so ~512 blocks is the
    // crossover. Round up so small images stay strictly sequential.
    const PARALLEL_BLOCKS_THRESHOLD: u64 = 512;
    const want_parallel: bool = options.threads != 1 and total_blocks >= PARALLEL_BLOCKS_THRESHOLD;

    // If parallelism is requested AND the image is big enough, set up
    // ONE pool and reuse it across both Phase 2 (IDCT) and the
    // color-conversion stage in assembleOutput. Spinning up two pools
    // for one decode would double the thread-creation overhead.
    var pool: thread_pool.Pool = undefined;
    var pool_initialized = false;
    var pool_ptr: ?*thread_pool.Pool = null;
    defer if (pool_initialized) pool.deinit();

    if (want_parallel) {
        var n_workers: u32 = options.threads;
        if (options.threads == 0) {
            const cpu = std.Thread.getCpuCount() catch 1;
            n_workers = @intCast(@min(cpu, std.math.maxInt(u32)));
        }
        // Cap at the largest plausible work item count (rows of blocks
        // for IDCT, output rows for color convert). We use the larger of
        // these two so the pool isn't undersized for either stage.
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
            // Pool init failed (OS thread limit, OOM, etc). Fall through
            // to the sequential path — decoding still succeeds, just
            // single-threaded.
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

    if (channels == 4) {
        // 4-component (CMYK / YCCK) assembly. Delegates to `cmyk.zig`
        // which handles both the raw-CMYK pass-through and the
        // YCCK→CMYK conversion (per APP14 `ColorTransform`). We free
        // the per-component planes after assembly succeeds (mirrors
        // `assembleOutput`'s built-in cleanup at line 1367 in the
        // 1/3-comp path).
        // cmyk.assemble upsamples each component to the canvas itself
        // (mirroring the 3-comp path), so pass the per-component sampling
        // factors + frame maxima. Passing raw subsampled planes without
        // this over-reads the smaller chroma buffers (validate_gui
        // heap over-read, 2026-05-31).
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
    // 1- and 3-component (grayscale / RGB / YCbCr) — existing path.
    const plane_w_3: [3]u32 = .{ plane_w[0], plane_w[1], plane_w[2] };
    const plane_h_3: [3]u32 = .{ plane_h[0], plane_h[1], plane_h[2] };
    const planes_3: [3][]u8 = .{ planes[0], planes[1], planes[2] };
    return assembleOutput(allocator, frame, channels, width, height, max_h, max_v, plane_w_3, plane_h_3, &planes_3, pool_ptr);
}

/// SOF1 12-bit extended sequential, 1-component grayscale (A1 milestone).
/// Focused path that reuses the precision-agnostic entropy decoder
/// (`decodeBlockCoefficients`) and routes through the 12-bit IDCT
/// (`idct.idct8x8_12`) into a `u16` plane, then byte-aliases that into
/// the `Image.pixels` field per the host-endian u16 convention shared
/// with the lossless cleanroom (M2.8).
///
/// Single-threaded: 12-bit photographs are rare; parallelism can be
/// added by reusing `transformBlockRow` once it's generic over P.
fn decodeScan12Gray(
    allocator: Allocator,
    data: []const u8,
    frame: *const FrameInfo,
    quant_tables: *const [4]?[64]u16,
    dc_tables: *const [4]?huffman.HuffmanTable,
    ac_tables: *const [4]?huffman.HuffmanTable,
    restart_interval: u32,
    options: DecodeOptions,
) Error!types.Image {
    const width: u32 = frame.width;
    const height: u32 = frame.height;
    const blocks_w: u32 = (width + 7) / 8;
    const blocks_h: u32 = (height + 7) / 8;
    const plane_w: u32 = blocks_w * 8;
    const plane_h: u32 = blocks_h * 8;

    // Coefficient buffer: i32 regardless of precision (entropy stream
    // values fit). One 64-coef block per 8×8 input region.
    const total_blocks: usize = @as(usize, blocks_w) * @as(usize, blocks_h);
    const coef_buf = try allocator.alloc(i32, total_blocks * 64);
    defer allocator.free(coef_buf);

    // Plane: u16 host-endian, [0, 4095].
    const plane = try allocator.alloc(u16, @as(usize, plane_w) * @as(usize, plane_h));
    defer allocator.free(plane);

    var br = bitstream.BitReader.init(data);
    var prev_dc: [4]i32 = .{ 0, 0, 0, 0 };
    var mcus_since_rst: u32 = 0;
    var expected_rst: u8 = 0xD0;
    var lenient_state: LenientState = .{
        .lenient = options.lenient,
        .sink = options.findings_sink,
    };

    // ── Phase 1: serial entropy decode (1 block per MCU) ──────────
    var by: u32 = 0;
    while (by < blocks_h) : (by += 1) {
        var bx: u32 = 0;
        while (bx < blocks_w) : (bx += 1) {
            if (restart_interval > 0 and mcus_since_rst == restart_interval) {
                br.seekToMarker();
                if (!br.marker_seen) return fail("rst_no_marker_seen", error.InvalidMarker);
                if (br.marker_byte != expected_rst) return fail("rst_wrong_marker", error.InvalidMarker);
                prev_dc = .{ 0, 0, 0, 0 };
                mcus_since_rst = 0;
                expected_rst = 0xD0 + ((expected_rst - 0xD0 + 1) & 0x07);
                br.skipPastMarker();
            }
            const linear: usize = (@as(usize, by) * @as(usize, blocks_w) + @as(usize, bx)) * 64;
            const slot: *[64]i32 = coef_buf[linear..][0..64];
            try decodeBlockCoefficients(
                &br,
                0, // single component, ci=0
                &frame.components[0],
                dc_tables,
                ac_tables,
                quant_tables,
                &prev_dc,
                slot,
                frame.precision,
                &lenient_state,
            );
            mcus_since_rst += 1;
        }
    }

    // ── Phase 2: IDCT each block, write into u16 plane ────────────
    by = 0;
    while (by < blocks_h) : (by += 1) {
        var bx: u32 = 0;
        while (bx < blocks_w) : (bx += 1) {
            const linear: usize = (@as(usize, by) * @as(usize, blocks_w) + @as(usize, bx)) * 64;
            const slot: *const [64]i32 = coef_buf[linear..][0..64];
            var block: [64]u16 = undefined;
            idct.idct8x8_12(slot, &block);
            var blk_y: u32 = 0;
            while (blk_y < 8) : (blk_y += 1) {
                var blk_x: u32 = 0;
                while (blk_x < 8) : (blk_x += 1) {
                    const px: u32 = bx * 8 + blk_x;
                    const py: u32 = by * 8 + blk_y;
                    plane[py * plane_w + px] = block[blk_y * 8 + blk_x];
                }
            }
        }
    }

    // ── Phase 3: crop plane to (width × height) and alias as u8 bytes ──
    const out_samples: usize = @as(usize, width) * @as(usize, height);
    const pixels = try allocator.alloc(u8, out_samples * 2);
    errdefer allocator.free(pixels);
    const out_u16: []align(1) u16 = std.mem.bytesAsSlice(u16, pixels);
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            out_u16[y * width + x] = plane[y * plane_w + x];
        }
    }

    return types.Image{
        .pixels = pixels,
        .width = width,
        .height = height,
        .channels = 1,
        .bits_per_sample = 12,
        .source_color_space = .grayscale,
        .layout = .grayscale,
    };
}

/// SOF1 12-bit extended sequential, 3-component RGB (A1 Part B milestone).
/// Mirrors `decodeScan`'s MCU-walking structure but with `u16` per-component
/// planes, `idct.idct8x8_12` for the IDCT, and `color.fancyUpsample12` /
/// `color.ycbcrRowToRgb12` for chroma upsample + YCbCr→RGB conversion.
/// Single-threaded at this milestone; parallelism can come in a follow-on
/// once `transformBlockRow` is generic over P.
fn decodeScan12Rgb(
    allocator: Allocator,
    data: []const u8,
    frame: *const FrameInfo,
    quant_tables: *const [4]?[64]u16,
    dc_tables: *const [4]?huffman.HuffmanTable,
    ac_tables: *const [4]?huffman.HuffmanTable,
    restart_interval: u32,
    options: DecodeOptions,
) Error!types.Image {
    const channels: u8 = 3;
    const width: u32 = frame.width;
    const height: u32 = frame.height;

    // MCU dimensions = max(H/V) × 8 pixels per axis. Per-component plane
    // is at the component's natural resolution.
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
    const mcu_cols: u32 = (width + mcu_pixel_w - 1) / mcu_pixel_w;
    const mcu_rows: u32 = (height + mcu_pixel_h - 1) / mcu_pixel_h;

    var plane_w: [3]u32 = .{ 0, 0, 0 };
    var plane_h: [3]u32 = .{ 0, 0, 0 };
    var blocks_w: [3]u32 = .{ 0, 0, 0 };
    var blocks_h: [3]u32 = .{ 0, 0, 0 };
    i = 0;
    while (i < channels) : (i += 1) {
        const eff_h: u32 = @as(u32, frame.components[i].h_factor);
        const eff_v: u32 = @as(u32, frame.components[i].v_factor);
        plane_w[i] = mcu_cols * eff_h * 8;
        plane_h[i] = mcu_rows * eff_v * 8;
        blocks_w[i] = mcu_cols * eff_h;
        blocks_h[i] = mcu_rows * eff_v;
    }

    var planes: [3][]u16 = .{ &.{}, &.{}, &.{} };
    i = 0;
    while (i < channels) : (i += 1) {
        planes[i] = try allocator.alloc(u16, @as(usize, plane_w[i]) * @as(usize, plane_h[i]));
    }
    defer {
        var j: usize = 0;
        while (j < channels) : (j += 1) {
            if (planes[j].len > 0) allocator.free(planes[j]);
        }
    }

    var coef_buf: [3][]i32 = .{ &.{}, &.{}, &.{} };
    i = 0;
    while (i < channels) : (i += 1) {
        const total_blocks: usize = @as(usize, blocks_w[i]) * @as(usize, blocks_h[i]);
        coef_buf[i] = try allocator.alloc(i32, total_blocks * 64);
    }
    defer {
        var j: usize = 0;
        while (j < channels) : (j += 1) {
            if (coef_buf[j].len > 0) allocator.free(coef_buf[j]);
        }
    }

    // ── Phase 1: serial entropy decode → coef_buf ─────────────────
    var br = bitstream.BitReader.init(data);
    var prev_dc: [4]i32 = .{ 0, 0, 0, 0 };
    var mcus_since_rst: u32 = 0;
    var expected_rst: u8 = 0xD0;
    var lenient_state: LenientState = .{
        .lenient = options.lenient,
        .sink = options.findings_sink,
    };
    var mcu_y: u32 = 0;
    while (mcu_y < mcu_rows) : (mcu_y += 1) {
        var mcu_x: u32 = 0;
        while (mcu_x < mcu_cols) : (mcu_x += 1) {
            if (restart_interval > 0 and mcus_since_rst == restart_interval) {
                br.seekToMarker();
                if (!br.marker_seen) return fail("rst_no_marker_seen", error.InvalidMarker);
                if (br.marker_byte != expected_rst) return fail("rst_wrong_marker", error.InvalidMarker);
                prev_dc = .{ 0, 0, 0, 0 };
                mcus_since_rst = 0;
                expected_rst = 0xD0 + ((expected_rst - 0xD0 + 1) & 0x07);
                br.skipPastMarker();
            }
            var ci: usize = 0;
            while (ci < channels) : (ci += 1) {
                const comp = &frame.components[ci];
                const blocks_v_per_mcu: u32 = @intCast(comp.v_factor);
                const blocks_h_per_mcu: u32 = @intCast(comp.h_factor);
                var bv: u32 = 0;
                while (bv < blocks_v_per_mcu) : (bv += 1) {
                    var bh: u32 = 0;
                    while (bh < blocks_h_per_mcu) : (bh += 1) {
                        const bx: u32 = mcu_x * blocks_h_per_mcu + bh;
                        const by: u32 = mcu_y * blocks_v_per_mcu + bv;
                        const linear: usize = (@as(usize, by) * @as(usize, blocks_w[ci]) + @as(usize, bx)) * 64;
                        const slot: *[64]i32 = coef_buf[ci][linear..][0..64];
                        try decodeBlockCoefficients(
                            &br,
                            ci,
                            comp,
                            dc_tables,
                            ac_tables,
                            quant_tables,
                            &prev_dc,
                            slot,
                            frame.precision,
                            &lenient_state,
                        );
                    }
                }
            }
            mcus_since_rst += 1;
        }
    }

    // ── Phase 2: IDCT every block into the per-component u16 plane ──
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

    // ── Phase 3: upsample chroma to canvas, then YCbCr→RGB per row ──
    const canvas_w: u32 = plane_w[0];
    const canvas_h: u32 = plane_h[0];
    var canvas_planes: [3][]const u16 = undefined;
    var canvas_owned: [3]bool = .{ false, false, false };
    var canvas_buffers: [3][]u16 = undefined;
    defer {
        for (canvas_buffers, canvas_owned) |buf, owned| {
            if (owned) allocator.free(buf);
        }
    }
    for (0..channels) |idx| {
        const comp = &frame.components[idx];
        const h_ratio: u32 = max_h / @as(u32, comp.h_factor);
        const v_ratio: u32 = max_v / @as(u32, comp.v_factor);
        if (h_ratio == 1 and v_ratio == 1) {
            canvas_planes[idx] = planes[idx];
            canvas_owned[idx] = false;
        } else {
            const active_w: u32 = (width * @as(u32, comp.h_factor) + max_h - 1) / max_h;
            const active_h: u32 = (height * @as(u32, comp.v_factor) + max_v - 1) / max_v;
            const buf = try color.fancyUpsample12(
                allocator,
                planes[idx],
                plane_w[idx],
                plane_h[idx],
                canvas_w,
                canvas_h,
                active_w,
                active_h,
                h_ratio,
                v_ratio,
            );
            canvas_buffers[idx] = buf;
            canvas_planes[idx] = buf;
            canvas_owned[idx] = true;
        }
    }

    // ── Phase 4: allocate output (u16 byte-view) and color convert ──
    const out_u16_count: usize = @as(usize, width) * @as(usize, height) * @as(usize, channels);
    const pixels = try allocator.alloc(u8, out_u16_count * 2);
    errdefer allocator.free(pixels);
    const pixels_u16: []align(1) u16 = std.mem.bytesAsSlice(u16, pixels);
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        color.ycbcrRowToRgb12(
            canvas_planes[0],
            canvas_planes[1],
            canvas_planes[2],
            canvas_w,
            width,
            pixels_u16,
            y,
        );
    }

    return types.Image{
        .pixels = pixels,
        .width = width,
        .height = height,
        .channels = 3,
        .bits_per_sample = 12,
        .source_color_space = .ycbcr,
        .layout = .rgb,
    };
}

/// Per-row worker: IDCT every block in row `by_idx` and write into the
/// plane. Pure compute over disjoint memory ranges (own slice of
/// `coef_buf` for input, own 8-pixel-tall stripe of `plane` for output)
/// so concurrent invocations on different rows don't race.
fn transformBlockRow(
    coef_buf: []const i32,
    plane: []u8,
    plane_w: u32,
    blocks_w_for_comp: u32,
    by_idx: u32,
) void {
    var bx_idx: u32 = 0;
    while (bx_idx < blocks_w_for_comp) : (bx_idx += 1) {
        const linear: usize = (@as(usize, by_idx) * @as(usize, blocks_w_for_comp) + @as(usize, bx_idx)) * 64;
        const slot: *const [64]i32 = coef_buf[linear..][0..64];
        transformBlockToPlane(slot, plane, plane_w, bx_idx * 8, by_idx * 8);
    }
}

/// Phase 1: decode a single 8×8 block from the entropy stream into the
/// natural-order coefficient buffer at `out`. Performs Huffman decode
/// (DC + 63 AC), dequantization in zig-zag space, and un-zig-zag into
/// natural order — but does NOT IDCT or write spatial samples. Splitting
/// this from the IDCT pass lets the second pass run in parallel later.
/// Updates `prev_dc[ci]` (DC differential per component, T.81 §F.2.2.1).
/// Per-scan recovery state for `lenient = true` mode. The scan
/// allocates one on the stack and threads `*LenientState` into every
/// block decode. The flag flips on the FIRST truncation in any block
/// of the scan; from that point on, every remaining block decode
/// short-circuits to zero coefficients (no extra findings, no
/// re-reading of an exhausted bitstream).
const LenientState = struct {
    lenient: bool,
    sink: ?*findings_mod.FindingsSink,
    truncation_seen: bool = false,

    inline fn emitOnce(self: *LenientState, byte_pos: usize) Error!void {
        if (self.truncation_seen) return;
        self.truncation_seen = true;
        if (self.sink) |s| {
            s.emit(.warn, .insufficient_data, @intCast(byte_pos),
                "Corrupt JPEG data: premature end of data segment") catch
                return error.OutOfMemory;
        }
    }
};

fn decodeBlockCoefficients(
    br: *bitstream.BitReader,
    ci: usize,
    comp: *const ComponentInfo,
    dc_tables: *const [4]?huffman.HuffmanTable,
    ac_tables: *const [4]?huffman.HuffmanTable,
    quant_tables: *const [4]?[64]u16,
    prev_dc: *[4]i32,
    out: *[64]i32,
    precision: u8,
    lenient: *LenientState,
) Error!void {
    // Lenient short-circuit: once truncation has been detected anywhere
    // in this scan, every remaining block decodes as zero. This produces
    // the same partial-recovery shape libjpeg-turbo emits: pixels up to
    // the truncation point are real, everything past is solid gray
    // (post-IDCT of an all-zero coefficient block + level shift).
    if (lenient.truncation_seen) {
        @memset(out, 0);
        return;
    }

    const dc_t = dc_tables[comp.dc_table] orelse return fail("block_dc_table_null", error.InvalidMarker);
    const ac_t = ac_tables[comp.ac_table] orelse return fail("block_ac_table_null", error.InvalidMarker);
    const qt = quant_tables[comp.qt_index] orelse return fail("block_qt_null", error.InvalidMarker);

    // T.81 §F.1.4.1 (DC), §F.1.4.2 (AC), Table F.1: at P=8 DC SSSS ≤ 11
    // and AC SSSS ≤ 10; at P=12 (extended sequential) DC SSSS ≤ 15 and
    // AC SSSS ≤ 14. Same arithmetic shape across the precisions —
    // DC max = P + 3, AC max = P + 2.
    const max_dc_size: u8 = precision + 3; // 11 for P=8, 15 for P=12
    const max_ac_size: u8 = precision + 2; // 10 for P=8, 14 for P=12

    // Coefficients accumulate in zig-zag order during entropy decode;
    // dequantized in zig-zag (matches DQT layout per T.81 §B.2.4.1);
    // un-zig-zagged for IDCT input (which expects natural row-major).
    // i32 for headroom: DC*qt can exceed i16 range on adversarial input.
    var zz: [64]i32 = .{0} ** 64;

    // ── DC coefficient (T.81 §F.2.2.1) ─────────────────────────
    const dc_size: u8 = dc_t.decode(br) catch {
        if (lenient.lenient and br.marker_seen) {
            try lenient.emitOnce(br.byte_pos);
            @memset(out, 0);
            return;
        }
        return fail("dc_huffman_decode_failed", error.BackendError);
    };
    if (dc_size > max_dc_size) return fail("dc_size_too_large", error.BackendError);
    var dc_diff: i32 = 0;
    if (dc_size > 0) {
        const bits = br.readBits(@intCast(dc_size)) catch {
            if (lenient.lenient) {
                try lenient.emitOnce(br.byte_pos);
                @memset(out, 0);
                return;
            }
            return error.TruncatedStream;
        };
        dc_diff = huffman.extendSign(bits, @intCast(dc_size));
    }
    prev_dc[ci] += dc_diff;
    zz[0] = prev_dc[ci];

    // ── 63 AC coefficients (T.81 §F.2.2.2) ─────────────────────
    var k: usize = 1;
    while (k < 64) {
        const rs: u8 = ac_t.decode(br) catch {
            if (lenient.lenient and br.marker_seen) {
                try lenient.emitOnce(br.byte_pos);
                @memset(out, 0);
                return;
            }
            return fail("ac_huffman_decode_failed", error.BackendError);
        };
        if (rs == 0x00) break; // EOB — rest of block is zero
        if (rs == 0xF0) {
            k += 16; // ZRL — 16 zeros (already zeroed; just advance)
            continue;
        }
        const run: u8 = rs >> 4;
        const size: u8 = rs & 0x0F;
        if (size == 0 or size > max_ac_size) return fail("ac_bad_size", error.BackendError);
        k += run;
        if (k >= 64) return fail("ac_k_overflow", error.BackendError);
        const bits = br.readBits(@intCast(size)) catch {
            if (lenient.lenient) {
                try lenient.emitOnce(br.byte_pos);
                @memset(out, 0);
                return;
            }
            return error.TruncatedStream;
        };
        const val = huffman.extendSign(bits, @intCast(size));
        zz[k] = val;
        k += 1;
    }

    // ── Dequantize in zig-zag space, then un-zig-zag into natural order ──
    var n: usize = 0;
    while (n < 64) : (n += 1) {
        out[ZIGZAG[n]] = zz[n] * @as(i32, qt[n]);
    }
}

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

/// After all blocks are decoded into per-component planes, convert
/// to interleaved output (grayscale or RGB) at canvas resolution.
/// Subsampled chroma is upsampled nearest-neighbor (good enough for
/// v2; proper cosited / midpoint reconstruction is a future
/// refinement when image-quality consumers ask).
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
    const out_len: usize = @as(usize, width) * @as(usize, height) * @as(usize, channels);
    const pixels = try allocator.alloc(u8, out_len);
    errdefer allocator.free(pixels);

    if (channels == 1) {
        var y: u32 = 0;
        while (y < height) : (y += 1) {
            var x: u32 = 0;
            while (x < width) : (x += 1) {
                pixels[y * width + x] = planes[0][y * plane_w[0] + x];
            }
        }
    } else {
        const c0 = &frame.components[0];
        const c1 = &frame.components[1];
        const c2 = &frame.components[2];
        // Upsample each component to the canvas grid (max_h × max_v scale)
        // using IJG fancy filter when the ratio is 2× in either axis;
        // nearest-neighbor otherwise. Producing full-resolution per-component
        // planes once is cheaper than per-pixel fancy interpolation, and
        // matches libjpeg-turbo's default "fancy upsampling" output (matching
        // is the non-obvious part: without this our pixels diverge by ~mean
        // 0.5–3 from libjpeg's default decode in the chroma transition zones).
        // Luma is at full canvas resolution; reuse its dimensions.
        const canvas_w: u32 = plane_w[0];
        const canvas_h: u32 = plane_h[0];
        var canvas_planes: [3][]u8 = undefined;
        var canvas_owned: [3]bool = .{ false, false, false };
        defer {
            for (canvas_planes, canvas_owned) |p, owned| {
                if (owned) allocator.free(p);
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
                canvas_planes[ci_idx] = try color.fancyUpsample(
                    allocator,
                    planes[ci_idx],
                    plane_w[ci_idx],
                    plane_h[ci_idx],
                    canvas_w,
                    canvas_h,
                    active_w,
                    active_h,
                    h_ratio,
                    v_ratio,
                );
                canvas_owned[ci_idx] = true;
            }
        }
        _ = c0;
        _ = c1;
        _ = c2;
        // Color conversion is per-row independent. Parallelize it on the
        // same thread pool used for IDCT when one is supplied.
        if (pool) |p| {
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
    }

    // Free intermediate planes.
    var p: usize = 0;
    while (p < channels) : (p += 1) allocator.free(planes[p]);

    return types.Image{
        .pixels = pixels,
        .width = width,
        .height = height,
        .channels = channels,
        .bits_per_sample = 8,
        .source_color_space = if (channels == 1) .grayscale else .ycbcr,
        .layout = if (channels == 1) .grayscale else .rgb,
    };
}

