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
//!
//! Layout: this file holds the options, the entry points, the frame walk
//! (`decodeImpl`) and the restart-recovery helpers; the rest lives in
//!   - baseline_markers.zig: marker stepping, SOS parsing, K.3 tables
//!   - baseline_entropy.zig: one scan's entropy decode into coefficients
//!   - baseline_scan.zig: the per-scan driver (`decodeScanT`)
//!   - baseline_block.zig: block coefficient decoding and row transforms
//!   - baseline_output.zig: IDCT to planes and output assembly

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

// Parts of this decoder live in sibling files (see Layout above).
const nextMarker = @import("baseline_markers.zig").nextMarker;
pub const parseSegmentLength = @import("baseline_markers.zig").parseSegmentLength;
pub const parseSof = @import("baseline_markers.zig").parseSof;
pub const parseDqt = @import("baseline_markers.zig").parseDqt;
const parseDht = @import("baseline_markers.zig").parseDht;
pub const ScanSelection = @import("baseline_markers.zig").ScanSelection;
pub const parseSos = @import("baseline_markers.zig").parseSos;
const noTablesDefined = @import("baseline_markers.zig").noTablesDefined;
const installK3Tables = @import("baseline_markers.zig").installK3Tables;
pub const isKIdOneFrame = @import("baseline_markers.zig").isKIdOneFrame;
pub const isKIdOneScan = @import("baseline_markers.zig").isKIdOneScan;
const ScanTables = @import("baseline_entropy.zig").ScanTables;
const decodeScanT = @import("baseline_scan.zig").decodeScanT;
pub const transformBlockToPlane = @import("baseline_output.zig").transformBlockToPlane;
pub const assembleOutputT = @import("baseline_output.zig").assembleOutputT;
pub const assembleOutput = @import("baseline_output.zig").assembleOutput;

/// Debug-only error annotation: in Debug builds, prints a tagged
/// trace line to stderr ("[baseline:tag] err.X") so the
/// cleanroom-diff tool can pinpoint where each error originates
/// without rewriting every call-site. In ReleaseFast/Safe/Small
/// builds the helper inlines to a plain `return err` with zero
/// runtime cost.
// Thin module-prefixed wrapper over the shared `diag.fail` (single
// implementation in decode/diag.zig). Call sites stay `fail("tag", err)`
// and still print "[baseline:tag] ErrorName" in Debug builds.
pub inline fn fail(comptime tag: []const u8, err: errors.DecodeError) errors.DecodeError {
    return @import("diag.zig").fail("baseline:" ++ tag, err);
}

/// Emit a typed finding at the exact in-buffer file offset of the defect
/// byte, when a sink is attached.
pub fn emitFinding(
    options: DecodeOptions,
    severity: errors.Severity,
    code: errors.FindingCode,
    offset: usize,
    detail: []const u8,
) Error!void {
    if (options.findings_sink) |sink| try sink.emitExact(severity, code, @intCast(offset), detail);
}

/// Classify a Huffman segment ending (T.81 §F.1.2.3) and report it at its
/// absolute offset. All-zero pad bits are an admitted encoder defect (Intel
/// JPEG Library 1.51, Olympus camera firmware): `entropy_padding_zero_bits` at
/// severity `known_defect`. Mixed bits look like
/// damage: FAIL `entropy_padding_not_ones`. Whole bytes after valid padding are
/// FAIL 8, exact at the first (validate, 2026-11-22; formerly audit row 51b's
/// 51). Anything else stays `huffman_table_corrupt`. `base` is the file
/// offset of `br.data[0]`.
pub fn reportEntropyBoundary(
    br: *const bitstream.BitReader,
    err: anyerror,
    base: usize,
    options: DecodeOptions,
    context: []const u8,
) Error!void {
    if (err == error.PaddingZeroBits) {
        if (options.findings_sink) |sink| try sink.emitZeroPadding(base + br.padByteOffset(), br.padBitCount());
    } else if (err == error.PaddingNotOnes) {
        try emitFinding(options, .fail, .entropy_padding_not_ones, base + br.padByteOffset(),
            "pad bits before the marker are not all 1 (T.81 F.1.2.3)");
    } else if (err == error.InvalidEntropyBoundary and br.trailingBytesAfterPadding() != null) {
        const trailing = br.trailingBytesAfterPadding().?;
        var buf: [96]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "{d} whole {s} after valid padding before marker 0x{X:0>2}", .{
            trailing.count, if (trailing.count == 1) "byte" else "bytes", trailing.marker,
        }) catch buf[0..0];
        try emitFinding(options, .fail, .extraneous_bytes_before_marker, base + trailing.first, detail);
    } else {
        try emitFinding(options, .fail, .huffman_table_corrupt, base + br.byte_pos, context);
    }
}

/// Resync the entropy stream at a restart-interval boundary
/// (T.81 §F.2.1.3). Strict mode hard-fails on a missing or
/// wrong-cycle RSTm marker. Lenient mode + sink emits a warn finding
/// (`restart_marker_missing` or `restart_marker_unexpected`), resets
/// the DC predictors, advances `expected_rst` to the next position
/// in the 0xD0..0xD7 cycle, and continues. EOI in place of the RST is
/// truncation at an interval boundary (`truncated_stream`); any other
/// non-RST marker (DNL, premature SOF) still hard-fails so callers see real
/// end-of-scan signals instead of pixel garbage. `base` is the file offset of
/// `br.data[0]`.
pub fn handleRstResync(
    br: *bitstream.BitReader,
    base: usize,
    expected_rst: *u8,
    prev_dc: *[4]i32,
    mcus_since_rst: *u32,
    options: DecodeOptions,
    truncation_seen: *bool,
) errors.DecodeError!void {
    // Preserve opt-in pixel recovery, but never hide discarded entropy from
    // a validator. Check a copy so lenient resynchronization retains its input.
    var boundary = br.*;
    if (boundary.finishHuffmanSegment()) |_| {} else |err| {
        try reportEntropyBoundary(&boundary, err, base, options,
            "invalid Huffman entropy or padding at restart boundary");
        if (!options.lenient and err != error.PaddingZeroBits)
            return fail("rst_entropy_boundary", error.BackendError);
        // Like libjpeg, skip whole extraneous bytes to the marker (already
        // reported as FAIL 8) and resynchronize there.
        if (err == error.InvalidEntropyBoundary) if (boundary.trailingBytesAfterPadding()) |trailing| {
            br.byte_pos = trailing.marker_at;
        };
    }
    // Force the reader to look ahead for the marker — the bit
    // buffer may still hold padding bits that haven't triggered a
    // refill yet.
    br.seekToMarker();

    if (!br.marker_seen) {
        if (options.lenient) {
            if (options.findings_sink) |sink| {
                sink.emit(.warn, .restart_marker_missing,
                    @intCast(base + br.byte_pos),
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

    var reported = false;
    while (br.marker_seen and br.marker_byte != expected_rst.*) {
        const got_rst = br.marker_byte >= 0xD0 and br.marker_byte <= 0xD7;
        if (options.lenient and got_rst) {
            if (!reported) if (options.findings_sink) |sink| {
                var buf: [96]u8 = undefined;
                const detail = std.fmt.bufPrint(&buf,
                    "expected RST{d} (0x{x:0>2}) but got RST{d} (0x{x:0>2})",
                    .{ expected_rst.* - 0xD0, expected_rst.*,
                       br.marker_byte - 0xD0, br.marker_byte })
                    catch buf[0..0];
                sink.emit(.warn, .restart_marker_unexpected,
                    @intCast(base + br.byte_pos), detail) catch return error.OutOfMemory;
            };
            reported = true;
            // libjpeg's jpeg_resync_to_restart (jdmarker.c), by the distance
            // from the expected RSTn to the RSTm found:
            switch ((br.marker_byte -% expected_rst.*) & 0x07) {
                // One or two ahead: leave the marker, so the expected interval
                // decodes as empty and later intervals keep their positions.
                1, 2 => {
                    prev_dc.* = .{ 0, 0, 0, 0 };
                    mcus_since_rst.* = 0;
                    expected_rst.* = 0xD0 + ((expected_rst.* - 0xD0 + 1) & 0x07);
                    truncation_seen.* = false;
                    return;
                },
                // One or two behind: a stale marker. Skip to the next one and
                // decide again.
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
        if (br.marker_byte == 0xD9) {
            try emitFinding(options, .fail, .truncated_stream, base + br.byte_pos,
                "EOI where a restart marker and further restart intervals belong");
            return fail("rst_eoi_truncation", error.TruncatedStream);
        }
        return fail("rst_wrong_marker", error.InvalidMarker);
    }
    // Skipping stale markers ran off the end of the data.
    if (!br.marker_seen) return fail("rst_no_marker_after_resync", error.TruncatedStream);

    // Happy path: marker matches.
    prev_dc.* = .{ 0, 0, 0, 0 };
    mcus_since_rst.* = 0;
    expected_rst.* = 0xD0 + ((expected_rst.* - 0xD0 + 1) & 0x07);
    br.skipPastMarker();
    truncation_seen.* = false;
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

// Shared with progressive via jpeg_markers.zig (byte-identical frame
// types). Re-exported `pub` so arith_decode and others keep resolving
// baseline.FrameInfo / baseline.ComponentInfo.
pub const ComponentInfo = jpeg_markers.ComponentInfo;
pub const FrameInfo = jpeg_markers.FrameInfo;

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
        const marker = (try nextMarker(data, &pos, options)) orelse continue;

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
                // No DHT before the first scan: Motion-JPEG relies on the
                // T.81 K.3 tables, as libjpeg-turbo does (finding 69).
                if (noTablesDefined(&dc_tables, &ac_tables)) installK3Tables(&dc_tables, &ac_tables);
                const scan = try parseSos(data, pos, &frame.?);
                pos += parseSegmentLength(data, pos);
                // 12-bit grayscale (A1 Part A) and 12-bit RGB (A1 Part B) take
                // the u16-sample instantiation; the SOF gate above admits no
                // other 12-bit component counts.
                const tables: ScanTables = .{
                    .quant = &quant_tables,
                    .dc = &dc_tables,
                    .ac = &ac_tables,
                    .restart_interval = &restart_interval,
                };
                if (frame.?.precision == 12) {
                    return try decodeScanT(12, allocator, data, pos, &frame.?, scan, tables,
                        options, app14_color_transform, saw_jfif);
                }
                return try decodeScanT(8, allocator, data, pos, &frame.?, scan, tables,
                    options, app14_color_transform, saw_jfif);
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

// SOF / DQT / DHT parsing shared with progressive (see jpeg_markers.zig).
