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
//!   - 1- and 3-component (RGB lossless byte-exact).
//!   - All 7 predictors (Ss = 1..7) — each tested independently.
//!   - DRI / restart markers (lossless_16x16_gray_dri.jpg byte-exact).
//!
//! Output byte ordering: P ≤ 8 → `[]u8`; P > 8 → `[]u8` aliasing host-
//! endian `[]u16` (consumers reinterpret via `image.pixelsU16()`).
//!
//! Out of scope (falls back to libjpeg_wrapper via NotImplemented):
//!   - Non-1×1 component sampling factors (rare; tiff-with-jpeg-
//!     compression occasionally uses subsampled lossless).
//!   - Point transform Al > 0 (sample shifted up by Al; trivial when
//!     a fixture surfaces it).
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

/// State threaded into decodeScan for restart-marker handling.
const RestartCtx = struct {
    interval: u16, // 0 = no restarts
    samples_since: u32 = 0,
    expected_rst: u8 = 0xD0,
    /// True when the next sample(s) — one per scan-component for the
    /// MCU after RST — must use the initial predictor 2^(P-Pt-1) per
    /// T.81 §H.1.2.2. Cleared after each component's first sample of
    /// the next restart interval is emitted.
    force_initial: bool = false,
};

const ComponentInfo = struct {
    id: u8,
    h_factor: u4,
    v_factor: u4,
    dc_table: u8 = 0,
};

const FrameInfo = struct {
    precision: u8,
    height: u16,
    width: u16,
    num_components: u8,
    components: [4]ComponentInfo,
};

const ScanInfo = struct {
    num_components: u8,
    comp_indices: [4]usize,
    predictor: u8, // Ss; 1..7
    point_transform: u4, // Al
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
                const detail = std.fmt.bufPrint(&buf,
                    "Corrupt JPEG data: {d} extraneous bytes before marker 0x{x:0>2}",
                    .{ pos - skip_start, next_marker }) catch buf[0..0];
                sink.emit(.warn, .extraneous_bytes_before_marker,
                    @intCast(skip_start), detail) catch return error.OutOfMemory;
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
                const detail = std.fmt.bufPrint(&buf,
                    "{d} extra 0xFF fill byte(s) before marker 0x{x:0>2}",
                    .{ pos - fill_start, next_marker }) catch buf[0..0];
                sink.emit(.warn, .entropy_fill_bytes,
                    @intCast(fill_start), detail) catch return error.OutOfMemory;
            }
        }
        if (pos + 1 >= data.len) return error.TruncatedStream;
        const marker = data[pos + 1];
        pos += 2;
        switch (marker) {
            0xD9 => { saw_eoi = true; break; },
            0xC3 => { // SOF3 — lossless predictive
                frame = try parseSof(data, pos);
                // v1 supports 8/12/14/16-bit precision (any P in 2..16
                // per T.81 §H.1, but cjpeg only emits 8/12/16; 14 lands
                // via DNG raw). Output is u8-packed for P≤8 and
                // u16 host-endian for P>8.
                if (frame.?.precision < 2 or frame.?.precision > 16)
                    return error.NotImplemented;
                if (frame.?.num_components != 1 and frame.?.num_components != 3)
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
        // for 1; consumers reading `image.layout` get the right shape.
        .source_color_space = if (nc == 1) .grayscale else .rgb,
        .layout = if (nc == 1) .grayscale else .rgb,
    };
}

const parseSegmentLength = @import("segment.zig").parseSegmentLength;

/// Validate lossless Huffman syntax without allocating or upsampling pixels.
/// Supports a single full-component scan (1..4 components), including unequal
/// sampling. DNL and separated component scans remain explicitly unsupported.
/// Offsets identify the payload-relative detection cursor, not the byte whose
/// mutation caused desynchronization. No sample-domain or image-content claim.
pub fn validate(data: []const u8, sink: *findings_mod.FindingsSink) Error!void {
	var offset: usize = 0;
	validateSyntax(data, &offset) catch |err| {
		if (err != error.NotImplemented) {
			try sink.emit(.fail, if (err == error.TruncatedStream) .truncated_stream else .huffman_table_corrupt,
				@intCast(@min(offset, data.len)), @errorName(err));
		}
		return err;
	};
}

fn validateSyntax(data: []const u8, offset: *usize) Error!void {
	if (data.len < 2) return error.TruncatedStream;
	if (data[0] != 0xff or data[1] != 0xd8) return error.InvalidMarker;
	var pos: usize = 2;
	var frame: ?FrameInfo = null;
	var tables: [4]?huffman.HuffmanTable = .{ null, null, null, null };
	var restart: u16 = 0;
	var scanned = false;
	while (true) {
		offset.* = pos;
		if (pos + 1 >= data.len) return error.TruncatedStream;
		if (data[pos] != 0xff) return error.InvalidMarker;
		while (pos + 1 < data.len and data[pos + 1] == 0xff) pos += 1;
		if (pos + 1 >= data.len) return error.TruncatedStream;
		const marker = data[pos + 1];
		pos += 2;
		if (marker == 0xd9) {
			if (!scanned) return error.TruncatedStream;
			// The public marker walker separately reports bytes after EOI.
			return;
		}
		if (marker == 0xdc) return error.NotImplemented; // DNL may redefine Y.
		// These have no length field; none is legal here in a SOF3 frame.
		if (marker == 0x00 or marker == 0x01 or marker == 0xd8 or
			(marker >= 0xd0 and marker <= 0xd7)) return error.InvalidMarker;
		const len = parseSegmentLength(data, pos);
		if (len < 2 or pos + len > data.len) return error.TruncatedStream;
		switch (marker) {
			0xc3 => {
				if (frame != null) return error.InvalidMarker;
				if (len >= 8 and data[pos + 7] > 4) return error.NotImplemented;
				frame = try parseSof(data, pos);
				if (frame.?.precision < 2 or frame.?.precision > 16 or frame.?.width == 0)
					return error.InvalidMarker;
				if (frame.?.height == 0) return error.NotImplemented;
			},
			0xc4 => try parseDht(data, pos, &tables),
			0xdd => {
				if (len != 4) return error.InvalidMarker;
				restart = (@as(u16, data[pos + 2]) << 8) | data[pos + 3];
			},
			0xda => {
				if (frame == null or scanned) return error.InvalidMarker;
				const scan = try parseSos(data, pos, &frame.?);
				if (scan.num_components != frame.?.num_components) return error.NotImplemented;
				if (scan.predictor < 1 or scan.predictor > 7) return error.InvalidMarker;
				if (scan.point_transform >= frame.?.precision) return error.NotImplemented;
				pos += len;
				pos = try validateEntropy(data, pos, &frame.?, &scan, &tables, restart, offset);
				scanned = true;
				continue;
			},
			0xdb, 0xe0...0xef, 0xfe => {}, // Unused DQT, application data, comments.
			else => return error.NotImplemented,
		}
		pos += len;
	}
}

fn validateEntropy(data: []const u8, start: usize, frame: *const FrameInfo, scan: *const ScanInfo,
	tables: *const [4]?huffman.HuffmanTable, restart: u16, offset: *usize) Error!usize
{
	var max_h: usize = 1;
	var max_v: usize = 1;
	var samples_per_mcu: usize = 0;
	for (frame.components[0..frame.num_components]) |comp| {
		max_h = @max(max_h, comp.h_factor);
		max_v = @max(max_v, comp.v_factor);
		samples_per_mcu += @as(usize, comp.h_factor) * comp.v_factor;
	}
	const interleaved = scan.num_components > 1;
	if (interleaved and samples_per_mcu > 10) return error.InvalidMarker;
	const columns = if (interleaved) std.math.divCeil(usize, frame.width, max_h) catch unreachable else frame.width;
	const rows = if (interleaved) std.math.divCeil(usize, frame.height, max_v) catch unreachable else frame.height;
	if (restart % columns != 0) return error.InvalidMarker;
	for (scan.comp_indices[0..scan.num_components]) |ci| {
		if (tables[frame.components[ci].dc_table] == null) return error.InvalidMarker;
	}
	var br = bitstream.BitReader.init(data[start..]);
	// Update the cursor even when lookahead encountered an early marker.
	errdefer offset.* = start + br.byte_pos;
	var expected_rst: u8 = 0xd0;
	for (0..columns * rows) |mcu| {
		if (restart != 0 and mcu != 0 and mcu % restart == 0) {
			const marker = br.finishHuffmanSegment() catch return entropyError(&br);
			if (marker == 0xdc) return error.NotImplemented;
			if (marker != expected_rst) return error.InvalidMarker;
			br.skipPastMarker();
			expected_rst = 0xd0 + ((expected_rst - 0xd0 + 1) & 7);
		}
		for (scan.comp_indices[0..scan.num_components]) |ci| {
			const comp = frame.components[ci];
			const count = if (interleaved) @as(usize, comp.h_factor) * comp.v_factor else 1;
			for (0..count) |_| {
				const category = tables[comp.dc_table].?.decode(&br) catch return entropyError(&br);
				if (category > 16) return error.BackendError;
				// H.1.2.2: category16 carries no amplitude; other nonzero
				// categories carry that many bits. Predictor4 can exceed P.
				if (category > 0 and category < 16)
					_ = br.readBits(@intCast(category)) catch return entropyError(&br);
			}
		}
	}
	const marker = br.finishHuffmanSegment() catch return entropyError(&br);
	if (marker == 0xdc) return error.NotImplemented;
	if (marker >= 0xd0 and marker <= 0xd7) return error.InvalidMarker;
	return start + br.byte_pos;
}

fn entropyError(br: *const bitstream.BitReader) Error {
	var boundary = br.*;
	if (boundary.marker_seen) boundary.seekToMarker();
	if (boundary.marker_seen and boundary.marker_byte == 0xdc) return error.NotImplemented;
	return if (br.byte_pos >= br.data.len) error.TruncatedStream else error.BackendError;
}

fn parseSof(data: []const u8, pos: usize) Error!FrameInfo {
    const seg_len = parseSegmentLength(data, pos);
    if (seg_len < 8 or pos + seg_len > data.len) return error.TruncatedStream;
    var fi: FrameInfo = undefined;
    fi.precision = data[pos + 2];
    fi.height = (@as(u16, data[pos + 3]) << 8) | data[pos + 4];
    fi.width = (@as(u16, data[pos + 5]) << 8) | data[pos + 6];
    fi.num_components = data[pos + 7];
    if (fi.num_components == 0 or fi.num_components > 4) return error.InvalidMarker;
    if (seg_len != 8 + @as(usize, fi.num_components) * 3) return error.InvalidMarker;
    var i: usize = 0;
    while (i < fi.num_components) : (i += 1) {
        const off = pos + 8 + i * 3;
        fi.components[i] = .{
            .id = data[off],
            .h_factor = @intCast(data[off + 1] >> 4),
            .v_factor = @intCast(data[off + 1] & 0x0F),
            // qt_index byte is at off+2 but is unused for lossless.
        };
        if (fi.components[i].h_factor < 1 or fi.components[i].h_factor > 4 or
            fi.components[i].v_factor < 1 or fi.components[i].v_factor > 4) return error.InvalidMarker;
        for (fi.components[0..i]) |previous| {
            if (previous.id == fi.components[i].id) return error.InvalidMarker;
        }
    }
    return fi;
}

fn parseDht(
    data: []const u8,
    pos: usize,
    dc_tables: *[4]?huffman.HuffmanTable,
) Error!void {
    const seg_len = parseSegmentLength(data, pos);
    if (seg_len < 2 or pos + seg_len > data.len) return error.TruncatedStream;
    var off: usize = pos + 2;
    const seg_end = pos + seg_len;
    while (off < seg_end) {
        if (off + 17 > seg_end) return error.TruncatedStream;
        const tc_th = data[off];
        const tc: u8 = tc_th >> 4;
        const th: u8 = tc_th & 0x0F;
        if (tc != 0 or th > 3) return error.InvalidMarker; // lossless uses DC tables only
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
        // T.81 C.2: canonical codes may neither overflow their width nor
        // use the all-one code (reserved for padding). Check before indexing.
        var code: u32 = 0;
        for (bits, 1..) |count, width| {
            code += count;
            if (code >= @as(u32, 1) << @intCast(width)) return error.InvalidMarker;
            code <<= 1;
        }
        const t = huffman.HuffmanTable.buildFromDht(bits, values) catch
            return error.InvalidMarker;
        dc_tables[th] = t;
        off += total;
    }
}

fn parseSos(data: []const u8, pos: usize, frame: *FrameInfo) Error!ScanInfo {
    const seg_len = parseSegmentLength(data, pos);
    if (seg_len < 6 or pos + seg_len > data.len) return error.TruncatedStream;
    var info: ScanInfo = undefined;
    info.num_components = data[pos + 2];
    if (info.num_components == 0 or info.num_components > 4)
        return error.InvalidMarker;
    if (seg_len != 6 + @as(usize, info.num_components) * 2) return error.InvalidMarker;
    var i: usize = 0;
    while (i < info.num_components) : (i += 1) {
        const off = pos + 3 + i * 2;
        const cs = data[off];
        const td_ta = data[off + 1];
        if (td_ta >> 4 > 3 or td_ta & 0x0f != 0) return error.InvalidMarker;
        var found: bool = false;
        var j: usize = 0;
        while (j < frame.num_components) : (j += 1) {
            if (frame.components[j].id == cs) {
                frame.components[j].dc_table = td_ta >> 4;
                info.comp_indices[i] = j;
                found = true;
                break;
            }
        }
        if (!found) return error.InvalidMarker;
        for (info.comp_indices[0..i]) |previous| {
            if (previous >= info.comp_indices[i]) return error.InvalidMarker;
        }
    }
    const tail_off = pos + 3 + @as(usize, info.num_components) * 2;
    info.predictor = data[tail_off];
    if (data[tail_off + 1] != 0) return error.InvalidMarker;
    const ah_al = data[tail_off + 2];
    if (ah_al >> 4 != 0) return error.InvalidMarker;
    info.point_transform = @intCast(ah_al & 0x0F);
    return info;
}

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
                if (boundary.finishHuffmanSegment()) |_| {} else |_| {
                    if (!options.lenient) return error.BackendError;
                    if (options.findings_sink) |sink| {
                        try sink.emit(.fail, .huffman_table_corrupt, @intCast(br.byte_pos),
                            "invalid Huffman entropy or padding at restart boundary");
                    }
                }
                br.seekToMarker();
                if (!br.marker_seen) {
                    if (options.lenient) {
                        if (options.findings_sink) |sink| {
                            sink.emit(.warn, .restart_marker_missing,
                                @intCast(br.byte_pos),
                                "expected RSTm marker not found at restart-interval boundary; continuing with reset predictors")
                                catch return error.OutOfMemory;
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
                            const detail = std.fmt.bufPrint(&buf,
                                "expected RST{d} (0x{x:0>2}) but got RST{d} (0x{x:0>2})",
                                .{ rst.expected_rst - 0xD0, rst.expected_rst,
                                   br.marker_byte - 0xD0, br.marker_byte })
                                catch buf[0..0];
                            sink.emit(.warn, .restart_marker_unexpected,
                                @intCast(br.byte_pos), detail) catch return error.OutOfMemory;
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
                    // T.81 §H.1.2.1: SSSS=16 represents diff = 32768 with
                    // no extra bits. Only legal at 16-bit precision.
                    if (frame.precision != 16) return error.BackendError;
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

    const marker = br.finishHuffmanSegment() catch return error.BackendError;
    if (marker >= 0xD0 and marker <= 0xD7) return error.BackendError;
    return out;
}

/// Read a single sample from the interleaved output buffer at (y, x, ci).
/// Sample is u8 for sample_bytes==1, u16 host-endian for sample_bytes==2.
inline fn sampleAt(
    out: []const u8,
    sample_bytes: usize,
    y: usize,
    x: usize,
    w: usize,
    nc: usize,
    ci: usize,
) i32 {
    const off = ((y * w + x) * nc + ci) * sample_bytes;
    if (sample_bytes == 1) return @intCast(out[off]);
    // Host-endian u16 read
    const lo: u16 = out[off];
    const hi: u16 = out[off + 1];
    const v: u16 = lo | (hi << 8);
    _ = .{}; // silence
    return @intCast(v);
}

inline fn writeSample(
    out: []u8,
    sample_bytes: usize,
    y: usize,
    x: usize,
    w: usize,
    nc: usize,
    ci: usize,
    value: u16,
) void {
    const off = ((y * w + x) * nc + ci) * sample_bytes;
    if (sample_bytes == 1) {
        out[off] = @intCast(value & 0xFF);
    } else {
        out[off] = @intCast(value & 0xFF);
        out[off + 1] = @intCast(value >> 8);
    }
}

inline fn computePredictorAt(
    selector: u8,
    out: []const u8,
    sample_bytes: usize,
    x: usize,
    y: usize,
    w: usize,
    nc: usize,
    ci: usize,
) i32 {
    const a: i32 = sampleAt(out, sample_bytes, y, x - 1, w, nc, ci);
    const b: i32 = sampleAt(out, sample_bytes, y - 1, x, w, nc, ci);
    const c: i32 = sampleAt(out, sample_bytes, y - 1, x - 1, w, nc, ci);
    return switch (selector) {
        1 => a,
        2 => b,
        3 => c,
        4 => a + b - c,
        5 => a + ((b - c) >> 1),
        6 => b + ((a - c) >> 1),
        7 => (a + b) >> 1,
        else => unreachable,
    };
}
