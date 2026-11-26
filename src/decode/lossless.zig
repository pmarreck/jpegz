//! Cleanroom lossless JPEG decoder (T.81 SOF3).
//!
//! T.81 §H — predictive lossless coding. No DCT, no quantization, no
//! IDCT rounding: each sample is reconstructed exactly as
//! `(predictor + diff) mod 2^precision`, where `diff` is the
//! Huffman-coded difference between the actual sample and the
//! predictor. The decoder uses one of seven predictor formulas
//! (selected via Ss in the SOS) computed from neighbors a (left),
//! b (above), and c (above-left).
//!
//! Coverage (2026-05-16 audit — 13 fixtures byte-perfect vs
//! libjpeg-turbo wrapper):
//!   - Precision 2..16 (gray8 / 12 / 14 / 16 fixtures all byte-exact).
//!   - 1- and 3-component (RGB lossless byte-exact), and 2- and 4-component
//!     frames (DNG CFA tiles) as raw component samples, exact against
//!     libjpeg-turbo-encoded formula samples.
//!   - All 7 predictors (Ss = 1..7) — each tested independently.
//!   - DRI / restart markers (lossless_16x16_gray_dri.jpg byte-exact).
//!
//! Output byte ordering: P ≤ 8 → `[]u8`; P > 8 → `[]u8` aliasing host-
//! endian `[]u16` (consumers reinterpret via `image.pixelsU16()`).
//!
//! Out of scope (falls back to libjpeg_wrapper via NotImplemented):
//!   - Non-1×1 component sampling factors (rare; tiff-with-jpeg-
//!     compression occasionally uses subsampled lossless).
//!
//! Reference: ITU-T T.81 §H.1 (Lossless mode, Annex H).

const std = @import("std");
const Allocator = std.mem.Allocator;
const errors = @import("../core/errors.zig");
const types = @import("../core/types.zig");
const bitstream = @import("bitstream.zig");
const huffman = @import("huffman.zig");
const findings_mod = @import("findings.zig");

pub const Error = errors.DecodeError;
const lframe = @import("lossless_frame.zig");
const RestartCtx = lframe.RestartCtx;
const ComponentInfo = lframe.ComponentInfo;
const FrameInfo = lframe.FrameInfo;
const ScanInfo = lframe.ScanInfo;
const parseSof = lframe.parseSof;
const parseDht = lframe.parseDht;
const parseSos = lframe.parseSos;
const sampleAt = lframe.sampleAt;
const writeSample = lframe.writeSample;
const computePredictorAt = lframe.computePredictorAt;
/// SOF3 syntax validation (see lossless_validate.zig).
pub const validate = @import("lossless_validate.zig").validate;

/// Optional findings sink + future knobs. Mirrors the pattern in
/// `baseline.zig`. Emit sites in lossless are the pre-SOS marker
/// walker (`extraneous_bytes_before_marker`, `entropy_fill_bytes`)
/// and the in-scan RST handler when `lenient = true` is set
/// (`restart_marker_missing` / `restart_marker_unexpected`).
/// Sample-stream tolerance is intentionally NOT added — a single
/// missing sample would cascade through the predictor chain.
pub const DecodeOptions = struct {
    findings_sink: ?*findings_mod.FindingsSink = null,
    /// When true + `findings_sink` attached, the decoder recovers
    /// from RST cycle mismatches and missing RST markers. Strict
    /// mode (default) returns `error.InvalidMarker`.
    lenient: bool = false,
};

/// Decode a lossless JPEG (T.81 SOF3).
///
/// FindingsSink: the pre-SOS marker walker tolerates "extraneous bytes
/// before marker" (T.81 §B.1.1.2 marker self-synchronization, mirroring
/// baseline). The walker scans forward past garbage to the next 0xFF
/// and emits `Finding(.warn, .extraneous_bytes_before_marker)` if a
/// sink is attached. Sample-stream tolerance is NOT added — a missing
/// sample would cascade through the predictor chain making recovery
/// meaningless.
///
/// Out-of-scope variants return `error.NotImplemented` (non-1×1
/// sampling factors, point transform Al > 0). The 13-fixture byte-
/// perfect coverage vs libjpeg-turbo wrapper (2026-05-16 audit) is
/// preserved: precision 2..16, 1- and 3-component, DRI > 0, all 7
/// predictors.
pub fn decode(allocator: Allocator, data: []const u8) Error!types.Image {
    return decodeWithOptions(allocator, data, .{});
}

pub fn decodeWithOptions(allocator: Allocator, data: []const u8, options: DecodeOptions) Error!types.Image {
    if (data.len < 4) return error.TruncatedStream;
    if (data[0] != 0xFF or data[1] != 0xD8) return error.InvalidMarker;

    var pos: usize = 2;
    var frame: ?FrameInfo = null;
    var dc_tables: [4]?huffman.HuffmanTable = .{ null, null, null, null };
    var saw_eoi = false;
    var seen_sof = false;
    var pixels: ?[]u8 = null;
    var restart_interval: u16 = 0;
    errdefer if (pixels) |p| allocator.free(p);

    while (pos + 1 < data.len and !saw_eoi) {
        // Tolerate "extraneous bytes before marker" per T.81 §B.1.1.2 —
        // markers are self-synchronizing. Scan forward to the next
        // 0xFF; emit a warn finding (libjpeg JWRN_EXTRANEOUS_DATA
        // parity) when a sink is attached.
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
        switch (marker) {
            0xD9 => {
                saw_eoi = true;
                break;
            },
            0xC3 => { // SOF3 — lossless predictive
                frame = try parseSof(data, pos);
                // v1 supports 8/12/14/16-bit precision (any P in 2..16
                // per T.81 §H.1, but cjpeg only emits 8/12/16; 14 lands
                // via DNG raw). Output is u8-packed for P≤8 and
                // u16 host-endian for P>8.
                if (frame.?.precision < 2 or frame.?.precision > 16)
                    return error.NotImplemented;
                seen_sof = true;
                var i: usize = 0;
                while (i < frame.?.num_components) : (i += 1) {
                    const c = &frame.?.components[i];
                    if (c.h_factor != 1 or c.v_factor != 1) return error.NotImplemented;
                }
                pos += parseSegmentLength(data, pos);
            },
            0xC0, 0xC1, 0xC2 => return error.NotImplemented, // not lossless
            0xC9, 0xCA, 0xCB => return error.NotImplemented, // arithmetic
            0xC4 => { // DHT — only DC tables matter for lossless
                try parseDht(data, pos, &dc_tables);
                pos += parseSegmentLength(data, pos);
            },
            0xDB => { // DQT — irrelevant for lossless; skip body
                pos += parseSegmentLength(data, pos);
            },
            0xDD => { // DRI — restart interval (T.81 §F.2.1.3)
                const seg_len = parseSegmentLength(data, pos);
                if (seg_len != 4 or pos + seg_len > data.len) return error.TruncatedStream;
                restart_interval = (@as(u16, data[pos + 2]) << 8) | data[pos + 3];
                pos += seg_len;
            },
            0xDA => { // SOS
                if (!seen_sof) return error.InvalidMarker;
                const scan = try parseSos(data, pos, &frame.?);
                // Scan must cover all frame components in a single pass
                // (no progressive concept of "scan refines a subset"
                // exists in lossless; T.81 §H.1.2.1).
                if (scan.num_components != frame.?.num_components) return error.NotImplemented;
                if (scan.predictor < 1 or scan.predictor > 7) return error.NotImplemented;
                pos += parseSegmentLength(data, pos);
                pixels = try decodeScan(allocator, data, pos, &frame.?, &dc_tables, &scan, restart_interval, options);
                // Lossless decode is single-pass; assume EOI follows.
                break;
            },
            0x01, 0xD0...0xD7 => continue, // standalone markers
            else => pos += parseSegmentLength(data, pos), // skip APPn/COM/etc.
        }
    }

    if (!seen_sof) return error.InvalidMarker;
    if (pixels == null) return error.TruncatedStream;

    const nc = frame.?.num_components;
    return types.Image{
        .pixels = pixels.?,
        .width = frame.?.width,
        .height = frame.?.height,
        .channels = nc,
        .bits_per_sample = frame.?.precision,
        // For lossless, libjpeg-turbo does NO YCbCr→RGB conversion: the
        // raw component samples ARE the output. cjpeg with PPM input
        // writes R, G, B as-is. Mark as RGB for 3 components, grayscale
        // for 1. Two or four components (a DNG CFA tile pairs one
        // component per CFA color) carry no color model in SOF3, so they
        // are raw `components`, never guessed as CMYK.
        .source_color_space = switch (nc) {
            1 => .grayscale,
            3 => .rgb,
            else => .unknown,
        },
        .layout = switch (nc) {
            1 => .grayscale,
            3 => .rgb,
            else => .components,
        },
    };
}

const parseSegmentLength = @import("segment.zig").parseSegmentLength;

/// Decode the entropy-coded scan into a `width*height`-byte pixel
/// buffer. Sample reconstruction per T.81 §H.1.2:
///   sample[x,y] = (predictor(x,y) + diff[x,y]) mod 2^precision
/// with predictor selected by Ss (1..7) and special handling for the
/// first sample of the image and the first sample of each row.
fn decodeScan(
    allocator: Allocator,
    data: []const u8,
    entropy_start: usize,
    frame: *const FrameInfo,
    dc_tables: *const [4]?huffman.HuffmanTable,
    scan: *const ScanInfo,
    restart_interval: u16,
    options: DecodeOptions,
) Error![]u8 {
    const width: usize = frame.width;
    const height: usize = frame.height;
    if (width == 0) return error.InvalidMarker;
    // T.81 H.1.1: lossless restarts span whole MCU rows. All supported
    // components use 1x1 sampling, so an MCU row contains width MCUs.
    if (restart_interval % width != 0) return error.InvalidMarker;
    const nc: usize = scan.num_components;
    const sample_bytes: usize = if (frame.precision <= 8) 1 else 2;
    // Output is interleaved per-pixel: pixel(x,y) starts at
    // out[(y*width + x)*nc*sample_bytes]. For P>8 each sample is
    // u16 host-endian — same shape libjpeg-turbo's jpeg16_ path emits.
    const out = try allocator.alloc(u8, width * height * nc * sample_bytes);
    errdefer allocator.free(out);
    @memset(out, 0);

    // Per-component Huffman table pointers (indexed by scan-component
    // position 0..nc-1, NOT by frame component index). Predictor state
    // is per-component too.
    var dc_tables_per_comp: [4]*const huffman.HuffmanTable = undefined;
    {
        var i: usize = 0;
        while (i < nc) : (i += 1) {
            const ci = scan.comp_indices[i];
            const comp = &frame.components[ci];
            // Take a pointer to the optional's payload after verifying
            // it's set. Lifetime is the parent decode function's locals.
            if (dc_tables[comp.dc_table] == null) return error.InvalidMarker;
            dc_tables_per_comp[i] = &dc_tables[comp.dc_table].?;
        }
    }

    // Initial predictor for the very first sample: 2^(P - Pt - 1).
    // For 8-bit Pt=0: initial = 128.
    const precision: u8 = frame.precision;
    const pt: u4 = scan.point_transform;
    const initial_pred: i32 = @as(i32, 1) << @intCast(@as(u8, precision) - @as(u8, pt) - 1);
    const sample_mask: i32 = (@as(i32, 1) << @intCast(precision)) - 1;

    var br = bitstream.BitReader.init(data[entropy_start..]);
    var rst: RestartCtx = .{ .interval = restart_interval };

    // For multi-component scans, per T.81 §A.2.4 / §H.1.2.1, samples are
    // interleaved per-MCU. With 1×1 sampling everywhere (our v1 limit),
    // each MCU = 1 sample per component, in scan-component order. So the
    // outer iteration is the same as single-component (per-pixel walk),
    // with an inner loop over components.
    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            // Per T.81 §F.2.1.3: every `restart_interval` MCUs the
            // entropy stream realigns. For lossless 1×1, each MCU = 1
            // sample per component. After RST, the next MCU's first
            // sample uses the initial predictor (per §H.1.2.2).
            if (rst.interval > 0 and rst.samples_since == rst.interval) {
                // Validate before discarding padding. A copy preserves the
                // existing cursor when opt-in recovery needs to resynchronize.
                var boundary = br;
                if (boundary.finishHuffmanSegment()) |_| {} else |err| if (err == error.PaddingZeroBits) {
                    // A known encoder defect (finding 63): WARN and continue.
                    if (options.findings_sink) |sink| try sink.emitZeroPadding(entropy_start + boundary.padByteOffset(), boundary.padBitCount());
                } else {
                    if (err == error.PaddingNotOnes) {
                        if (options.findings_sink) |sink| try sink.emitExact(.fail, .entropy_padding_not_ones, entropy_start + boundary.padByteOffset(), "mixed Huffman pad bits before restart marker (T.81 F.1.2.3)");
                    }
                    if (!options.lenient) return error.BackendError;
                    if (err != error.PaddingNotOnes) if (options.findings_sink) |sink| {
                        try sink.emit(.fail, .huffman_table_corrupt, @intCast(br.byte_pos), "invalid Huffman entropy or padding at restart boundary");
                    };
                }
                br.seekToMarker();
                if (!br.marker_seen) {
                    if (options.lenient) {
                        if (options.findings_sink) |sink| {
                            sink.emit(.warn, .restart_marker_missing, @intCast(br.byte_pos), "expected RSTm marker not found at restart-interval boundary; continuing with reset predictors") catch return error.OutOfMemory;
                        }
                        rst.expected_rst = 0xD0 + ((rst.expected_rst - 0xD0 + 1) & 0x07);
                        rst.samples_since = 0;
                        rst.force_initial = true;
                    } else {
                        return error.InvalidMarker;
                    }
                } else if (br.marker_byte != rst.expected_rst) {
                    const got_rst = br.marker_byte >= 0xD0 and br.marker_byte <= 0xD7;
                    if (options.lenient and got_rst) {
                        if (options.findings_sink) |sink| {
                            var buf: [96]u8 = undefined;
                            const detail = std.fmt.bufPrint(&buf, "expected RST{d} (0x{x:0>2}) but got RST{d} (0x{x:0>2})", .{ rst.expected_rst - 0xD0, rst.expected_rst, br.marker_byte - 0xD0, br.marker_byte }) catch buf[0..0];
                            sink.emit(.warn, .restart_marker_unexpected, @intCast(br.byte_pos), detail) catch return error.OutOfMemory;
                        }
                        rst.expected_rst = 0xD0 + ((br.marker_byte - 0xD0 + 1) & 0x07);
                        br.skipPastMarker();
                        rst.samples_since = 0;
                        rst.force_initial = true;
                    } else {
                        return error.InvalidMarker;
                    }
                } else {
                    rst.expected_rst = 0xD0 + ((rst.expected_rst - 0xD0 + 1) & 0x07);
                    br.skipPastMarker();
                    rst.samples_since = 0;
                    rst.force_initial = true;
                }
            }
            var ci_scan: usize = 0;
            while (ci_scan < nc) : (ci_scan += 1) {
                const pred: i32 = if ((x == 0 and y == 0) or rst.force_initial)
                    initial_pred
                else if (rst.samples_since < width)
                    sampleAt(out, sample_bytes, y, x - 1, width, nc, ci_scan)
                else if (x == 0)
                    sampleAt(out, sample_bytes, y - 1, x, width, nc, ci_scan)
                else
                    computePredictorAt(scan.predictor, out, sample_bytes, x, y, width, nc, ci_scan);

                const ssss: u8 = dc_tables_per_comp[ci_scan].decode(&br) catch return error.BackendError;
                if (ssss > 16) return error.BackendError;
                var diff: i32 = 0;
                if (ssss == 16) {
                    // T.81 H.1.2.2: SSSS=16 is the difference 32768, with no
                    // extra bits. Differences are taken modulo 2^16 at every
                    // precision, and predictors 4 to 7 can leave the P-bit
                    // range, so a valid file below 16 bits can need it
                    // (libjpeg-turbo writes them at 15 bits with predictor 4).
                    diff = 32768;
                } else if (ssss > 0) {
                    const bits = br.readBits(@intCast(ssss)) catch return error.TruncatedStream;
                    diff = @intCast(huffman.extendSign(bits, @intCast(ssss)));
                }
                const sample: i32 = (pred + diff) & sample_mask;
                writeSample(out, sample_bytes, y, x, width, nc, ci_scan, @intCast(sample));
            }
            // After the MCU's components are all decoded, clear the
            // initial-predictor flag and bump the per-RST counter.
            rst.force_initial = false;
            rst.samples_since += 1;
        }
    }

    const marker = br.finishHuffmanSegment() catch |err| zero: {
        if (err == error.PaddingNotOnes) {
            if (options.findings_sink) |sink| try sink.emitExact(.fail, .entropy_padding_not_ones, entropy_start + br.padByteOffset(), "mixed Huffman pad bits before scan marker (T.81 F.1.2.3)");
        }
        if (err != error.PaddingZeroBits) return error.BackendError;
        if (options.findings_sink) |sink| try sink.emitZeroPadding(entropy_start + br.padByteOffset(), br.padBitCount());
        br.seekToMarker();
        if (!br.marker_seen) return error.BackendError;
        break :zero br.marker_byte;
    };
    if (marker >= 0xD0 and marker <= 0xD7) return error.BackendError;
    // T.81 A.4: "The output of the decoder is rescaled by multiplying by
    // 2^Pt." Prediction runs on the reduced samples above, so the rescale
    // follows the whole scan. The mask keeps the P-bit sample width that
    // reconstruction already imposes.
    if (pt > 0) {
        var i: usize = 0;
        while (i < width * height * nc) : (i += 1) {
            const reduced = sampleAt(out, sample_bytes, 0, i, 0, 1, 0);
            writeSample(out, sample_bytes, 0, i, 0, 1, 0, @intCast((reduced << pt) & sample_mask));
        }
    }
    return out;
}
