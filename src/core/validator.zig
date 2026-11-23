//! Hand-written JPEG marker-chain walker for `jpegz.validate`. Pure
//! Zig (no FFI). Designed to be the start of the Phase-2 cleanroom
//! parser: as the cleanroom decoder lands codec-by-codec, this module
//! will share its marker-parse machinery.
//!
//! Behavior contract (from the design doc):
//!   - Returns Zig error only on OOM; structural problems are findings.
//!   - Does NOT fail-fast — accumulates every finding it can detect
//!     before returning.
//!   - Sets `Variant` from SOF marker even when `overall == .fail` so
//!     consumers know what was being attempted.

const std = @import("std");
const Allocator = std.mem.Allocator;
const errors = @import("errors.zig");
const huffman = @import("../decode/huffman.zig");
const baseline = @import("../decode/baseline.zig");
const jpeg_markers = @import("../decode/jpeg_markers.zig");
const jpegls = @import("../decode/jpegls.zig");
const types = @import("../jpegz.zig");

const Severity = errors.Severity;
const Variant = errors.Variant;
const FindingCode = errors.FindingCode;
const Finding = types.Finding;
const ValidationReport = types.ValidationReport;

/// Marker constants we care about (T.81 Table B.1 + JPEG-LS).
const Marker = struct {
    const SOI: u8 = 0xD8;
    const EOI: u8 = 0xD9;
    const SOS: u8 = 0xDA;
    const DHT: u8 = 0xC4;
    const DAC: u8 = 0xCC; // arithmetic conditioning
    const DQT: u8 = 0xDB;
    // SOF markers — see classifyVariant.
    const RST0: u8 = 0xD0;
    const RST7: u8 = 0xD7;
    const TEM: u8 = 0x01;
};

/// Map a SOFn marker byte to the corresponding Variant.
/// Returns null for non-SOF markers.
fn classifyVariant(byte: u8) ?Variant {
    return switch (byte) {
        0xC0 => .baseline_huffman,        // SOF0
        0xC1 => .extended_huffman,        // SOF1
        0xC2 => .progressive_huffman,     // SOF2
        0xC3 => .lossless_huffman,        // SOF3
        0xC5, 0xC6, 0xC7 => .unknown,     // SOF5/6/7 — differential huffman, treat as unknown
        // SOF8 (0xC8) is JPG (reserved); skip.
        0xC9 => .baseline_arithmetic,     // SOF9
        0xCA => .progressive_arithmetic,  // SOF10
        0xCB => .lossless_arithmetic,     // SOF11
        0xCD, 0xCE, 0xCF => .unknown,     // SOF13/14/15 — differential arithmetic
        0xF7 => .jpegls,                  // SOF55 (T.87)
        else => null,
    };
}

/// True if a marker byte has NO length field (standalone). T.81 B.1.1.3.
fn isStandaloneMarker(byte: u8) bool {
    return byte == Marker.SOI
        or byte == Marker.EOI
        or byte == Marker.TEM
        or (byte >= Marker.RST0 and byte <= Marker.RST7);
}

/// Big-endian u16 read; assumes data has at least 2 bytes from `at`.
fn readU16BE(data: []const u8, at: usize) u16 {
    return (@as(u16, data[at]) << 8) | @as(u16, data[at + 1]);
}

/// Add a finding to the report, allocating the optional detail string
/// from the report's allocator. Detail lifetime is tied to the report.
fn addFinding(
    report: *ValidationReport,
    allocator: Allocator,
    severity: Severity,
    code: FindingCode,
    offset: ?u64,
    detail: ?[]const u8,
) Allocator.Error!void {
    const stored_detail: ?[]const u8 = if (detail) |d|
        try allocator.dupe(u8, d)
    else
        null;
    errdefer if (stored_detail) |s| allocator.free(s);

    try report.findings.append(allocator, .{
        .severity = severity,
        .code = code,
        .offset = offset,
        .detail = stored_detail,
    });

    // Promote `overall` if this finding is more severe.
    if (severity.rank() > report.overall.rank()) {
        report.overall = severity;
    }
}

/// Mark a structurally identified header byte without claiming an EOF cursor
/// or an entropy decoder's later detection position is the damaged byte.
fn addExactFinding(report: *ValidationReport, allocator: Allocator, code: FindingCode, offset: usize, detail: []const u8) Allocator.Error!void {
	try addFinding(report, allocator, .fail, code, @intCast(offset), detail);
	report.findings.items[report.findings.items.len - 1].offset_is_exact = true;
}

/// Validation class of a codec finding, assigned when the report takes it from
/// the decoder (validate TERMINOLOGY A2 as rewritten 2026-11-05; approved rows
/// in docs/plan_context/severity-audit-2026-11-05.md). The decoder still
/// reports what it recovered from at its own severity; only the class in the
/// report changes, so detection and decoder control flow are untouched.
fn reportSeverity(code: FindingCode, emitted: Severity) Severity {
	return switch (code) {
		// Recovered damage: readers fill or resync, which hides the loss.
		.insufficient_data, .restart_marker_missing, .restart_marker_unexpected => .fail,
		// T.81 B.1.1.2 permits 0xFF fill before any marker: an observation.
		.entropy_fill_bytes => .info,
		else => emitted,
	};
}

const MpfTiff = struct { start: usize, end: usize };

/// Bytes after the first EOI (finding 212; owner ruling 2026-11-06 and
/// validate rules 2026-11-07). Images the MPF Index IFD places there are
/// consumed in order, as long as each starts where the previous ended: INFO
/// `mpf`. A remainder starting `PAR2\0PKT` is the owner's PAR2 trailer: INFO
/// `par2` at its start, for validate to verify. Anything else is a writer's
/// trailer, junk or fill: WARN `other` at the first uncovered byte.
fn reportTrailingData(report: *ValidationReport, allocator: Allocator, data: []const u8, start: usize, mpf: ?MpfTiff) Allocator.Error!void {
	var cur = start;
	if (mpf) |m| {
		var ranges: [16][2]usize = undefined;
		const n = mpfImageRanges(data, m, &ranges);
		std.mem.sortUnstable([2]usize, ranges[0..n], {}, struct {
			fn lessThan(_: void, a: [2]usize, b: [2]usize) bool {
				return a[0] < b[0];
			}
		}.lessThan);
		for (ranges[0..n]) |r| {
			if (r[0] == cur and r[1] > cur and r[1] <= data.len) cur = r[1];
		}
	}
	if (cur > start) {
		try addFinding(report, allocator, .info, .trailing_data_after_eoi, start, "mpf");
		report.findings.items[report.findings.items.len - 1].offset_is_exact = true;
	}
	if (cur == data.len) return;
	const par2 = std.mem.startsWith(u8, data[cur..], "PAR2\x00PKT");
	try addFinding(report, allocator, if (par2) .info else .warn, .trailing_data_after_eoi, cur, if (par2) "par2" else "other");
	report.findings.items[report.findings.items.len - 1].offset_is_exact = true;
}

/// The file ranges of the images an MPF Index IFD lists after the first
/// (CIPA DC-007 5.2.3: MP Entry tag 0xB002, 16 bytes per image, offsets from
/// the TIFF header; offset 0 is the file's own first image). Malformed or
/// out-of-range structures yield fewer ranges, never a read past `data`.
fn mpfImageRanges(data: []const u8, m: MpfTiff, out: *[16][2]usize) usize {
	const base = m.start;
	if (m.end < base + 8 or m.end > data.len) return 0;
	const tiff = data[base..m.end];
	const little = std.mem.eql(u8, tiff[0..2], "II");
	if (!little and !std.mem.eql(u8, tiff[0..2], "MM")) return 0;
	const endian: std.builtin.Endian = if (little) .little else .big;
	const ifd = std.mem.readInt(u32, tiff[4..8], endian);
	if (ifd > tiff.len or tiff.len - ifd < 2) return 0;
	const count = std.mem.readInt(u16, tiff[ifd..][0..2], endian);
	var entries_at: ?usize = null;
	var entries_len: usize = 0;
	for (0..count) |k| {
		const e = ifd + 2 + 12 * k;
		if (e + 12 > tiff.len) break;
		if (std.mem.readInt(u16, tiff[e..][0..2], endian) != 0xB002) continue;
		entries_len = std.mem.readInt(u32, tiff[e + 4 ..][0..4], endian);
		entries_at = std.mem.readInt(u32, tiff[e + 8 ..][0..4], endian);
	}
	const at = entries_at orelse return 0;
	var n: usize = 0;
	var k: usize = 0;
	while (n < out.len and k < entries_len / 16) : (k += 1) {
		const q = at + 16 * k;
		if (q > tiff.len or tiff.len - q < 16) break;
		const size = std.mem.readInt(u32, tiff[q + 4 ..][0..4], endian);
		const offset = std.mem.readInt(u32, tiff[q + 8 ..][0..4], endian);
		if (offset == 0) continue;
		const first = std.math.add(usize, base, offset) catch continue;
		const last = std.math.add(usize, first, size) catch continue;
		out[n] = .{ first, last };
		n += 1;
	}
	return n;
}

/// Known defect A2 (owner admission 2026-11-06, documented-producer path):
/// FFmpeg/Libav mjpegenc before commit b19313218c, and rtpdec_jpeg, wrote the
/// JFIF 1.02 version as the bytes 02 01. The match is exact: a JFIF APP0 with
/// those version bytes and nothing else wrong in it, meaning units 0..2,
/// nonzero densities (T.871) and a thumbnail that fills the segment exactly.
/// Any near match stays the ordinary WARN 67.
fn isFfmpegJfifVersion(body: []const u8) bool {
	const header_bytes: usize = 14;
	if (body.len < header_bytes or !std.mem.eql(u8, body[0..5], "JFIF\x00")) return false;
	if (body[5] != 2 or body[6] != 1 or body[7] > 2) return false;
	if (std.mem.readInt(u16, body[8..10], .big) == 0 or std.mem.readInt(u16, body[10..12], .big) == 0) return false;
	const rgb_bytes: usize = 3;
	return body.len == header_bytes + rgb_bytes * @as(usize, body[12]) * body[13];
}

fn checkSequentialScanField(report: *ValidationReport, allocator: Allocator, offset: usize,
	name: []const u8, observed: u8, required: u8) Allocator.Error!void
{
	if (observed == required) return;
	const detail = try std.fmt.allocPrint(allocator, "sequential SOS {s}={d}; required {d}", .{ name, observed, required });
	defer allocator.free(detail);
	try addExactFinding(report, allocator, .sequential_scan_invalid, offset, detail);
}

/// The first out-of-range Hi or Vi of a SOF (T.81 Table B.2: 1..4).
const BadSamplingFactor = struct { offset: usize, component: u8, name: []const u8, value: u8 };

/// Finding 66, one record per SOF (validate ruling 2026-11-22): the first
/// invalid factor, exact, with the frame's counts of invalid factors and of
/// the components that carry them.
fn reportSamplingFactors(report: *ValidationReport, allocator: Allocator, first: BadSamplingFactor,
	factors: usize, components: usize) Allocator.Error!void
{
	const detail = try std.fmt.allocPrint(allocator,
		"SOF component ID {d} {s}={d}; allowed 1..4; {d} invalid factor{s} in {d} component{s}", .{
			first.component, first.name, first.value,
			factors, if (factors == 1) "" else "s", components, if (components == 1) "" else "s",
		});
	defer allocator.free(detail);
	try addExactFinding(report, allocator, .sof_sampling_invalid, first.offset, detail);
}

pub fn validate(allocator: Allocator, data: []const u8) Allocator.Error!ValidationReport {
    var report = ValidationReport{
        .overall = .pass,
        .variant = .unknown,
        .width = null,
        .height = null,
        .findings = .empty,
    };
    errdefer report.deinit(allocator);

    // ── Step 1: SOI check ──────────────────────────────────────
    if (data.len < 2 or data[0] != 0xFF or data[1] != 0xD8) {
        try addFinding(&report, allocator, .fail, .missing_soi, 0,
            "JPEG must start with SOI marker (0xFF 0xD8)");
        return report;
    }

    var pos: usize = 2;
    var seen_sof: bool = false;
    var sof_offset: ?u64 = null;
    var seen_sos: bool = false;
    var seen_eoi: bool = false;
    // Membership bitmap of component IDs (Ci) declared by the SOF, used
    // to validate SOS component selectors (Cs) cross-segment.
    var sof_comp_ids = [_]bool{false} ** 256;
	// Packed Hi/Vi sampling byte per declared component ID, for the MCU check.
	var sof_comp_hv = [_]u8{0} ** 256;
    var sof_component_count: u8 = 0;
	// Finding 70's WARN frame: four components with IDs exactly (1, 2, 3, 1).
	var sof_k_id_one = false;
	// Se byte of a sequential scan matching finding 68's Go signature; judged
	// after the walk, when the number of scans is known.
	var go_zero_se: ?usize = null;
	// The first MPF APP2's TIFF header and segment end (finding 212).
	var mpf_tiff: ?MpfTiff = null;
	// Finding 69: Huffman table destinations defined so far ([Tc][Th]), the
	// first scan, and the first Td/Ta byte naming a table not yet defined.
	var dht_defined = [2][4]bool{ .{ false, false, false, false }, .{ false, false, false, false } };
	var seen_dht = false;
	// DHT bodies, judged after the walk against the frame precision (a DHT
	// may precede the SOF).
	var dht_segments: std.ArrayList([2]usize) = .empty;
	defer dht_segments.deinit(allocator);
	var frame_precision: ?u8 = null;
	var first_sos_offset: ?usize = null;
	var first_missing_table: ?usize = null;
    var sos_count: u32 = 0; // number of SOS (scan) markers seen
	// T.81 Annex J: a DHP before the first frame makes the stream hierarchical,
	// where several frames are legal and later ones are differential.
	var hierarchical = false;
	var frame_differential = false;
	// Finding 72 (T.81 B.2.5): DNL placement, judged against the first frame.
	// frame_lines is Y when nonzero, else the NL of the DNL right after the
	// first scan; null while no count is declared.
	var frame_declared_y: ?u16 = null;
	var frame_lines: ?u16 = null;
	var frame_scans: u32 = 0;
	var frame_dnls: u32 = 0;
	var at_first_scan_end = false;
	// FAIL findings that do not stop the codec check or the EOI check. They
	// were WARN before 2026-11-05; reclassifying them must not drop findings.
	var nonblocking_fails: usize = 0;

    // ── Step 2: Walk markers ──────────────────────────────────
    while (pos < data.len) {
        // Each marker starts with one or more 0xFF fill bytes.
        if (data[pos] != 0xFF) {
            try addFinding(&report, allocator, .fail, .bad_marker_length, pos,
                "expected 0xFF at marker start");
            return report;
        }
        // Skip fill bytes (0xFF padding).
        while (pos < data.len and data[pos] == 0xFF) pos += 1;
        if (pos >= data.len) {
            try addFinding(&report, allocator, .fail, .truncated_stream, data.len,
                "stream ended at marker prefix");
            return report;
        }

        const marker_byte = data[pos];
        const marker_offset = pos - 1; // include the 0xFF
        pos += 1;
		const right_after_first_scan = at_first_scan_end;
		at_first_scan_end = false;
		// T.81 B.1.1.2 excludes zero as a marker byte. Entropy stuffing
		// and opaque APP payloads are consumed separately below.
		if (marker_byte == 0) {
			try addExactFinding(&report, allocator, .unknown_marker, marker_offset + 1,
				"zero marker byte outside entropy is forbidden by T.81 B.1.1.2");
			return report;
		}
		// Reserved semantics cannot be established by decoding around them.
		if (marker_byte >= 0x02 and marker_byte <= 0xbf) {
			// FAIL class (validate, 2026-11-05): no specified decode, damage
			// produces it and no writer is known.
			const detail = try std.fmt.allocPrint(allocator,
				"reserved JPEG marker FF{X:0>2}; marker semantics are not checked", .{marker_byte});
			defer allocator.free(detail);
			try addExactFinding(&report, allocator, .unknown_marker, marker_offset + 1, detail);
			nonblocking_fails += 1;
		}
		if (marker_byte == 0xde and !seen_sof) hierarchical = true;

        // ── Standalone markers (no length) ─────────────────────
        if (isStandaloneMarker(marker_byte)) {
            if (marker_byte == Marker.EOI) {
                seen_eoi = true;
                // pos already moved past the 0xFF and marker byte;
                // anything beyond pos is "trailing" data.
                if (pos < data.len) try reportTrailingData(&report, allocator, data, pos, mpf_tiff);
                break;
            }
            // SOI inside the stream (after position 0) is suspicious but
            // not required to fail — some embedded thumbnails carry one.
            // RST/TEM are no-op here.
            continue;
        }

        // ── Length-prefixed segment ────────────────────────────
        if (pos + 2 > data.len) {
            try addFinding(&report, allocator, .fail, .truncated_stream, pos,
                "stream ended before segment length");
            return report;
        }
        const seg_len = readU16BE(data, pos);
        if (seg_len < 2) {
            try addFinding(&report, allocator, .fail, .bad_marker_length, pos,
                "segment length must be >= 2");
            return report;
        }
        const seg_body_start = pos + 2;
        const seg_end = pos + seg_len; // length includes the 2 length bytes themselves
        if (seg_end > data.len) {
            try addFinding(&report, allocator, .fail, .truncated_stream, seg_end,
                "segment extends past end of stream");
            return report;
        }

        // ── APPn signature scan (M1.5c — validate handoff) ────
        // APPn markers (0xE0..0xEF) carry application-specific
        // payloads. The first few bytes of the body are a signature
        // that identifies the producer. Surface known producers as
        // INFO findings so validate / metadata pipelines don't have
        // to walk markers a second time. Body bounds are seg_body_start
        // to seg_end; the segment-length check above guarantees safety.
		// CIPA DC-007 Multi-Picture Format: remember the first MPF APP2's TIFF
		// header, whose Index IFD locates images stored after the first EOI.
		if (marker_byte == 0xE2 and mpf_tiff == null and seg_end >= seg_body_start + 4 and
			std.mem.eql(u8, data[seg_body_start .. seg_body_start + 4], "MPF\x00"))
		{
			mpf_tiff = .{ .start = seg_body_start + 4, .end = seg_end };
		}
        if (marker_byte >= 0xE0 and marker_byte <= 0xEF) {
            if (classifyAppSignature(marker_byte, data[seg_body_start..seg_end])) |code| {
                try addFinding(&report, allocator, .info, code, marker_offset, null);
            }
            // Embedded thumbnail (T.81 JFIF Annex B / JFXX extension). A JFIF
            // APP0 with nonzero Xthumbnail×Ythumbnail carries an inline RGB
            // thumbnail; a JFXX APP0 extension is a thumbnail by definition.
            if (marker_byte == 0xE0) {
                const body = data[seg_body_start..seg_end];
				const jfif_header_bytes: usize = 14;
				// The approved metadata rule is edition-specific. Generic APP0,
				// incomplete headers and other versions do not establish it.
				if (body.len >= jfif_header_bytes and std.mem.eql(u8, body[0..5], "JFIF\x00") and
					body[5] == 1 and (body[6] == 1 or body[6] == 2) and body[7] > 2)
				{
					const detail = try std.fmt.allocPrint(allocator,
						"JFIF 1.{d:0>2} metadata/profile violation: units={d}; expected 0, 1 or 2", .{ body[6], body[7] });
					defer allocator.free(detail);
					try addExactFinding(&report, allocator, .jfif_metadata_invalid, seg_body_start + 7, detail);
				}
				if (body.len >= jfif_header_bytes and std.mem.eql(u8, body[0..5], "JFIF\x00") and
					(body[5] > 1 or (body[5] == 1 and body[6] > 2)))
				{
					// WARN class (validate, 2026-11-05): a deviation with no
					// proven violation; JFIF 1.02 is the latest version. The
					// exact FFmpeg/Libav pattern is an admitted known defect.
					const known = isFfmpegJfifVersion(body);
					const detail = if (known)
						try allocator.dupe(u8, "JFIF version bytes 02 01: the byte-swapped 1.02 that FFmpeg/Libav mjpegenc (before b19313218c) and rtpdec_jpeg write; admitted known defect")
					else
						try std.fmt.allocPrint(allocator,
							"JFIF version {d}.{d:0>2}: not in the claimed spec version (latest is 1.02); metadata semantics are unchecked", .{ body[5], body[6] });
					defer allocator.free(detail);
					try addFinding(&report, allocator, if (known) .known_defect else .warn, .jfif_version_unchecked,
						seg_body_start + (if (body[5] > 1) @as(usize, 5) else 6), detail);
					report.findings.items[report.findings.items.len - 1].offset_is_exact = true;
				}
                if (body.len >= 14 and std.mem.eql(u8, body[0..5], "JFIF\x00")) {
                    if (body[12] != 0 and body[13] != 0)
                        try addFinding(&report, allocator, .info, .embedded_thumbnail_present,
                            marker_offset, "JFIF APP0 carries an embedded thumbnail");
                } else if (body.len >= 5 and std.mem.eql(u8, body[0..5], "JFXX\x00")) {
                    try addFinding(&report, allocator, .info, .embedded_thumbnail_present,
                        marker_offset, "JFXX APP0 extension thumbnail present");
                }
            }
        }

        // ── DQT: validate each quantization table header (T.81 §B.2.4) ──
        // Pq (high nibble) must be 0 (8-bit Q values) or 1 (16-bit); Tq (low
        // nibble, table destination) must be 0..3. A permissive decoder may
        // limp on a malformed table; a validator flags it so the spec
        // deviation is not silently swallowed.
		// ── DHT: an exactly full code space (finding 71, an admitted known defect) ──
		// The decoders accept the table; T.81 F.2.2.3 decodes it
		// deterministically. Malformed or oversubscribed tables are left to
		// the decode-through, which reports them as 51.
		if (marker_byte == Marker.DHT) {
			seen_dht = true;
			try dht_segments.append(allocator, .{ seg_body_start, seg_end });
			const bits_bytes: usize = 16;
			var hp: usize = seg_body_start;
			while (hp + 1 + bits_bytes <= seg_end) {
				const bits = data[hp + 1 ..][0..bits_bytes].*;
				var total: usize = 0;
				for (bits) |count| total += count;
				// Validate 2026-11-22: BITS counts that overrun the segment are 51,
				// exact at the count byte where the symbols stop fitting.
				const room = seg_end - (hp + 1 + bits_bytes);
				if (total > room) {
					var running: usize = 0;
					const at = for (bits, 0..) |count, i| {
						running += count;
						if (running > room) break hp + 1 + i;
					} else unreachable;
					const detail = try std.fmt.allocPrint(allocator,
						"DHT Tc={d} Th={d}: BITS counts {d} symbols but only {d} bytes remain in the segment",
						.{ data[hp] >> 4, data[hp] & 0x0F, total, room });
					defer allocator.free(detail);
					try addExactFinding(&report, allocator, .huffman_table_corrupt, at, detail);
					// Declared, though corrupt: not also a missing table (69).
					if (data[hp] >> 4 <= 1 and data[hp] & 0x0F <= 3) dht_defined[data[hp] >> 4][data[hp] & 0x0F] = true;
					break;
				}
				if (data[hp] >> 4 <= 1 and data[hp] & 0x0F <= 3) dht_defined[data[hp] >> 4][data[hp] & 0x0F] = true;
				switch (huffman.codeSpace(bits)) {
					.full_all_ones => |length| {
						const detail = try std.fmt.allocPrint(allocator,
							"DHT Tc={d} Th={d}: code space exactly full at length {d}, so its last code is the reserved all-ones codeword (Pentax, Ricoh and DJI DNG encoders); admitted known defect",
							.{ data[hp] >> 4, data[hp] & 0x0F, length });
						defer allocator.free(detail);
						// Exact: the BITS count for the length that fills the space.
						try addFinding(&report, allocator, .known_defect, .huffman_table_full_all_ones, hp + length, detail);
						report.findings.items[report.findings.items.len - 1].offset_is_exact = true;
					},
					.valid, .invalid => {},
				}
				hp += 1 + bits_bytes + total;
			} else if (hp < seg_end) {
				try addExactFinding(&report, allocator, .huffman_table_corrupt, hp,
					"DHT segment ends inside a table's Tc/Th and BITS header");
			}
		}

        if (marker_byte == Marker.DQT) {
            var qp: usize = seg_body_start;
            while (qp < seg_end) {
                const pqtq = data[qp];
                const pq = pqtq >> 4;
                const tq = pqtq & 0x0F;
                if (pq > 1 or tq > 3) {
                    try addFinding(&report, allocator, .fail, .quantization_table_corrupt,
                        qp, "DQT Pq must be 0 or 1 and Tq must be 0..3");
                    break; // table size is ambiguous once Pq is invalid
                }
				const elements_per_table: usize = 64;
				const element_bytes = @as(usize, pq) + 1;
				const table_bytes = 1 + elements_per_table * element_bytes;
				// A partial table cannot borrow coefficient bytes from the next segment.
				if (table_bytes > seg_end - qp) break;
				for (0..elements_per_table) |index| {
					const offset = qp + 1 + index * element_bytes;
					const zero = data[offset] == 0 and (pq == 0 or data[offset + 1] == 0);
					if (zero) try addExactFinding(&report, allocator, .quantization_table_corrupt,
						offset, "DQT quantization element Qk must be nonzero");
				}
				qp += table_bytes;
            }
        }

        // ── DAC: validate arithmetic conditioning entries (T.81 §B.2.4.3) ──
        // Each entry is a (Tc/Tb, Cs) pair: Tc (high nibble) must be 0 (DC)
        // or 1 (AC); Tb (low nibble, conditioning table destination) must be
        // 0..3. A DC Cs is L + 16U with 0 <= L <= U <= 15; an AC Cs is Kx in
        // 1..63. Validate (2026-11-22): FAIL 53 exactly at the first offending
        // byte, once per segment.
        if (marker_byte == Marker.DAC) {
            var dp: usize = seg_body_start;
            while (dp + 1 < seg_end) : (dp += 2) {
                const tctb = data[dp];
                const cs = data[dp + 1];
                if ((tctb >> 4) > 1 or (tctb & 0x0F) > 3) {
                    try addExactFinding(&report, allocator, .arithmetic_table_corrupt,
                        dp, "DAC Tc must be 0 or 1 and Tb must be 0..3");
                    break;
                }
                if (tctb >> 4 == 0 and cs & 0x0F > cs >> 4) {
                    var dbuf: [80]u8 = undefined;
                    try addExactFinding(&report, allocator, .arithmetic_table_corrupt, dp + 1,
                        std.fmt.bufPrint(&dbuf, "DAC DC conditioning needs L <= U; got L={d} U={d}",
                            .{ cs & 0x0F, cs >> 4 }) catch "DAC DC conditioning needs L <= U");
                    break;
                }
                if (tctb >> 4 == 1 and (cs < 1 or cs > 63)) {
                    var dbuf: [64]u8 = undefined;
                    try addExactFinding(&report, allocator, .arithmetic_table_corrupt, dp + 1,
                        std.fmt.bufPrint(&dbuf, "DAC AC Kx must be 1..63; got {d}", .{cs})
                            catch "DAC AC Kx must be 1..63");
                    break;
                }
            }
        }

        // ── SOF: identify variant and record dimensions ───────
        if (classifyVariant(marker_byte)) |variant| {
			frame_differential = switch (marker_byte) {
				0xc5, 0xc6, 0xc7, 0xcd, 0xce, 0xcf => true,
				else => false,
			};
			if (frame_differential and !hierarchical) {
				// FAIL (validate, 2026-11-21): nothing to difference against.
				try addExactFinding(&report, allocator, .differential_frame_without_dhp, marker_offset,
					"differential SOF with no DHP before it; T.81 J.1 allows differential frames only in hierarchical mode");
				nonblocking_fails += 1;
			}
            if (seen_sof and !hierarchical) {
				// FAIL class (validate, 2026-11-05): libjpeg refuses two SOF
				// markers and damage produces them.
                try addFinding(&report, allocator, .fail, .duplicate_sof, marker_offset,
                    "more than one SOF marker outside a hierarchical (DHP) stream (using first)");
				nonblocking_fails += 1;
            } else if (!seen_sof) {
                report.variant = variant;
                sof_offset = marker_offset;
                seen_sof = true;

                // SOF body layout (T.81 §B.2.2):
                //   0: precision (u8)
                //   1-2: height (u16 BE)
                //   3-4: width (u16 BE)
                //   5: number of components (u8)
                //   6+: per-component data (3 bytes each)
                if (seg_len < 8) {
                    try addFinding(&report, allocator, .fail, .bad_marker_length,
                        seg_body_start, "SOF segment too short for header fields");
                } else {
                    const precision = data[seg_body_start];
                    if (frame_precision == null) frame_precision = precision;
                    const declared_height = readU16BE(data, seg_body_start + 1);
                    const declared_width = readU16BE(data, seg_body_start + 3);
                    // T.81 B.2.5 and T.87 C.2.2: Y = 0 defers the line count
                    // to a DNL right after the first scan, as the decoders
                    // resolve it; JPEG-LS entropy data has its own stuffing.
                    const dnl_height: ?u16 = if (declared_height != 0)
                        null
                    else if (variant == .jpegls)
                        jpegls.dnlLines(data, seg_body_start - 2 + seg_len)
                    else
                        jpeg_markers.dnlLines(data, seg_body_start - 2 + seg_len);
                    // T.87 C.2.4.1.4: an LSE ID 4 fills a JPEG-LS dimension the
                    // SOF55 leaves at 0 (sizes above 65535).
                    const oversize: ?jpegls.Oversize = if (variant == .jpegls and (declared_height == 0 or declared_width == 0))
                        jpegls.oversizeDimensions(data)
                    else
                        null;
                    const width: u32 = if (declared_width != 0) declared_width else if (oversize) |o| o.width else 0;
                    const height: u32 = if (declared_height != 0) declared_height else if (dnl_height) |lines| lines else if (oversize) |o| o.height else 0;
					frame_declared_y = declared_height;
					frame_lines = if (declared_height != 0) declared_height else dnl_height;
                    report.width = width;
                    report.height = height;

                    // SOF3 Y=0 needs DNL and remains unsupported by its entropy
                    // validator. Other pixel decoders still require both sizes
                    // to prevent indexing empty planes.
                    if (width == 0 or (height == 0 and variant != .lossless_huffman)) {
                        try addFinding(&report, allocator, .fail, .invalid_dimensions,
                            seg_body_start + 1, "SOF declares zero width, or zero height with no DNL after the first scan");
                    }

                    // Nf (component count) must be >= 1 and the segment length
                    // must equal 8 + 3*Nf (T.81 §B.2.2: 1 prec + 2 H + 2 W + 1
                    // Nf + 3 bytes per component, plus the 2 length bytes). A
                    // mismatch means the declared count is inconsistent with
                    // the marker — flag rather than silently mis-parse.
                    const nf = data[seg_body_start + 5];
                    if (nf == 0 or @as(usize, seg_len) != 8 + 3 * @as(usize, nf)) {
                        try addFinding(&report, allocator, .fail, .sof_component_count_invalid,
                            seg_body_start + 5, "SOF Nf must be >= 1 and segment length must equal 8 + 3*Nf");
                    } else {
                        sof_component_count = nf;
						const k_id_one = [_]u8{ 1, 2, 3, 1 };
						sof_k_id_one = nf == 4 and variant != .jpegls and for (k_id_one, 0..) |id, k| {
							if (data[seg_body_start + 6 + 3 * k] != id) break false;
						} else true;
                        // Record each declared component ID (Ci) for the SOS cross-check.
						var bad_factors: usize = 0;
						var bad_components: usize = 0;
						var first_bad: ?BadSamplingFactor = null;
                        var ci: usize = 0;
                        while (ci < nf) : (ci += 1) {
							const component = data[seg_body_start + 6 + 3 * ci];
							const offset = seg_body_start + 7 + 3 * ci;
							// T.81 B.2.2: component IDs within a frame are distinct.
							if (sof_comp_ids[component] and variant != .jpegls) {
								const id_offset = seg_body_start + 6 + 3 * ci;
								if (sof_k_id_one) {
									try addFinding(&report, allocator, .warn, .sof_component_id_duplicate, id_offset,
										"SOF gives the fourth component the ID 1 already used by the first: the CMYK/YCCK writer pattern (1, 2, 3, 1)");
									report.findings.items[report.findings.items.len - 1].offset_is_exact = true;
								} else {
									const detail = try std.fmt.allocPrint(allocator, "SOF repeats component ID {d}", .{component});
									defer allocator.free(detail);
									try addExactFinding(&report, allocator, .sof_component_id_duplicate, id_offset, detail);
								}
							}
                            sof_comp_ids[component] = true;
							sof_comp_hv[component] = data[offset];
							// T.81 Table B.2: every T.81 frame's Hi and Vi are 1..4.
							// The JPEG-LS frame stays with the T.87 validator.
							if (variant == .jpegls) continue;
							var bad_here = false;
							for ([_]struct { name: []const u8, value: u8 }{
								.{ .name = "Hi (high nibble)", .value = data[offset] >> 4 },
								.{ .name = "Vi (low nibble)", .value = data[offset] & 15 },
							}) |factor| {
								if (factor.value >= 1 and factor.value <= 4) continue;
								bad_factors += 1;
								bad_here = true;
								if (first_bad == null) first_bad = .{ .offset = offset, .component = component, .name = factor.name, .value = factor.value };
							}
							if (bad_here) bad_components += 1;
                        }
						if (first_bad) |bad| try reportSamplingFactors(&report, allocator, bad, bad_factors, bad_components);
                    }

                    const lossless_precision = variant == .lossless_huffman or variant == .lossless_arithmetic;
                    if (if (lossless_precision) precision < 2 or precision > 16 else precision != 8 and precision != 12 and precision != 16) {
                        try addFinding(&report, allocator, .fail, .invalid_sof_precision,
                            seg_body_start, if (lossless_precision) "lossless SOF precision must be 2..16" else "SOF precision must be 8, 12, or 16");
                    } else if (precision == 12) {
                        try addFinding(&report, allocator, .info, .twelve_bit_precision,
                            seg_body_start, null);
                    } else if (precision == 16 and (variant == .lossless_huffman or
                        variant == .lossless_arithmetic))
                    {
                        try addFinding(&report, allocator, .info, .sixteen_bit_lossless,
                            seg_body_start, null);
                    }

                    // Surface .info hint for arithmetic-coded variants.
                    switch (variant) {
                        .baseline_arithmetic, .progressive_arithmetic, .lossless_arithmetic =>
                            try addFinding(&report, allocator, .info,
                                .arithmetic_coding_used, marker_offset, null),
                        else => {},
                    }
                }
            }
        } else if (marker_byte == Marker.SOS) {
            seen_sos = true;
            sos_count += 1;
			frame_scans += 1;
			if (first_sos_offset == null) first_sos_offset = marker_offset;
			// Finding 69: a sequential scan naming a Huffman table no DHT has
			// defined yet. Judged after the walk (see below).
			if (seen_sof and (report.variant == .baseline_huffman or report.variant == .extended_huffman) and
				seg_body_start < seg_end and first_missing_table == null)
			{
				const scan_ns = data[seg_body_start];
				// Only a complete selector list; Ss, Se and Ah/Al are not Td/Ta.
				const complete_list = seg_len == 6 + @as(usize, scan_ns) * 2;
				var sj: usize = 0;
				while (complete_list and sj < scan_ns) : (sj += 1) {
					const tdta = data[seg_body_start + 2 + 2 * sj];
					const td = tdta >> 4;
					const ta = tdta & 0x0F;
					if ((td <= 3 and !dht_defined[0][td]) or (ta <= 3 and !dht_defined[1][ta])) {
						first_missing_table = seg_body_start + 2 + 2 * sj;
						break;
					}
				}
			}
			// Validate 2026-11-22: a progressive scan naming an undefined table
			// gets finding 69 at its Td/Ta byte, as on the sequential path. A
			// DC first scan uses Td, an AC scan Ta, a DC refinement neither.
			if (seen_sof and report.variant == .progressive_huffman and
				seg_body_start < seg_end and first_missing_table == null)
			{
				const scan_ns = data[seg_body_start];
				if (seg_len == 6 + @as(usize, scan_ns) * 2) {
					const tail = seg_body_start + 1 + 2 * @as(usize, scan_ns);
					const ss = data[tail];
					const ah = data[tail + 2] >> 4;
					for (0..scan_ns) |sj| {
						const tdta = data[seg_body_start + 2 + 2 * sj];
						const td = tdta >> 4;
						const ta = tdta & 0x0F;
						const missing = if (ss == 0) ah == 0 and td <= 3 and !dht_defined[0][td] else ta <= 3 and !dht_defined[1][ta];
						if (missing) {
							// No K.3 fallback applies to progressive scans, so report
							// now; the FAIL also spares a redundant decode-through 51.
							first_missing_table = seg_body_start + 2 + 2 * sj;
							try addExactFinding(&report, allocator, .huffman_tables_missing, first_missing_table.?,
								"scan names a Huffman table that no DHT segment defines");
							break;
						}
					}
				}
			}
			// Validate 2026-11-22: SOS Ns outside 1..4 or above the SOF's Nf gets
			// the code the sequential check below gives it, on every T.81 path.
			const sequential_scan = report.variant == .baseline_huffman or report.variant == .extended_huffman;
			if (seen_sof and !sequential_scan and report.variant != .jpegls and seg_body_start < seg_end) {
				const ns = data[seg_body_start];
				if (ns == 0 or ns > 4 or (sof_component_count != 0 and ns > sof_component_count)) {
					try addExactFinding(&report, allocator, .sos_component_mismatch, seg_body_start,
						"SOS Ns must be 1..4 and cannot exceed SOF Nf");
				}
			}
			// Finding 75 (validate, 2026-11-22): an SOS Td/Ta outside T.81
			// Table B.3, exact at the byte. Above 3 no destination exists:
			// FAIL. In a baseline (SOF0) frame, 2 or 3 naming a defined table
			// breaks a baseline limit: WARN; an undefined table is finding 69's.
			// Lossless Ta (B.3 gives 0) is not judged; JPEG-LS has no Td/Ta.
			if (seen_sof and report.variant != .jpegls and seg_body_start < seg_end) {
				const scan_ns = data[seg_body_start];
				const lossless = report.variant == .lossless_huffman or report.variant == .lossless_arithmetic;
				if (seg_len == 6 + @as(usize, scan_ns) * 2) for (0..scan_ns) |sj| {
					const at = seg_body_start + 2 + 2 * sj;
					const td = data[at] >> 4;
					const ta = data[at] & 0x0F;
					const td_bad = td > 3;
					const ta_bad = !lossless and ta > 3;
					var dbuf: [112]u8 = undefined;
					if (td_bad or ta_bad) {
						const detail = (if (td_bad and ta_bad)
							std.fmt.bufPrint(&dbuf, "SOS component {d}: td={d} and ta={d} name no table destination (T.81 Table B.3: 0..3)", .{ data[at - 1], td, ta })
						else
							std.fmt.bufPrint(&dbuf, "SOS component {d}: {s}={d} names no table destination (T.81 Table B.3: 0..3)", .{ data[at - 1], if (td_bad) "td" else "ta", if (td_bad) td else ta })) catch "SOS Td/Ta outside T.81 Table B.3";
						try addExactFinding(&report, allocator, .sos_table_selector_invalid, at, detail);
					} else if (report.variant == .baseline_huffman and
						((td >= 2 and dht_defined[0][td]) or (ta >= 2 and dht_defined[1][ta])))
					{
						const detail = std.fmt.bufPrint(&dbuf, "SOS component {d}: {s}={d} in a baseline frame (T.81 Table B.3: 0..1)", .{ data[at - 1], if (td >= 2) "td" else "ta", if (td >= 2) td else ta }) catch "SOS Td/Ta above the baseline limit";
						try addFinding(&report, allocator, .warn, .sos_table_selector_invalid, at, detail);
						report.findings.items[report.findings.items.len - 1].offset_is_exact = true;
					}
				};
			}
			// T.81 B.2.3: diagnose sequential SOS shape before decoding can
			// mislabel a header fault as damaged Huffman entropy.
			const sequential_huffman = report.variant == .baseline_huffman or report.variant == .extended_huffman;
			if (seen_sof and sequential_huffman) {
				if (seg_body_start == seg_end or seg_len < 6) {
					try addExactFinding(&report, allocator, .bad_marker_length, pos,
						"sequential SOS length must equal 6 + 2*Ns");
				} else {
					const ns = data[seg_body_start];
					if (ns == 0 or ns > 4 or (sof_component_count != 0 and ns > sof_component_count)) {
						try addExactFinding(&report, allocator, .sos_component_mismatch, seg_body_start,
							"sequential SOS Ns must be 1..4 and cannot exceed SOF Nf");
					}
					if (seg_len != 6 + @as(usize, ns) * 2) {
						try addExactFinding(&report, allocator, .bad_marker_length, pos,
							"sequential SOS length must equal 6 + 2*Ns");
					}
				}
			}
            // Validate scan component selectors (Cs) reference SOF-declared
            // components (T.81 §B.2.3). SOS body: Ns, then Ns×(Cs, Td/Ta).
            // Only meaningful once a SOF has been seen (missing SOF is
            // reported separately) — otherwise the bitmap is empty.
            if (seen_sof and seg_body_start < seg_end) {
                const ns = data[seg_body_start];
				// Only a complete T.81 selector list establishes a repeated Cs.
				// JPEG-LS scan constraints remain owned by the T.87 validator.
				const check_duplicates = report.variant != .jpegls and seg_len == 6 + @as(usize, ns) * 2;
				var selected = [_]bool{false} ** 256;
                var cj: usize = 0;
				// Reserve Ss, Se and Ah/Al; an excessive Ns must not turn
				// those trailing parameters into apparent component selectors.
                while (cj < ns and seg_body_start + 5 + 2 * cj < seg_end) : (cj += 1) {
                    const cs = data[seg_body_start + 1 + 2 * cj];
					// Finding 70's frame resolves its one exact scan by position.
					const by_position = sof_k_id_one and baseline.isKIdOneScan(data[seg_body_start..seg_end]);
					if (check_duplicates and selected[cs] and !by_position) {
						try addExactFinding(&report, allocator, .sos_component_mismatch,
							seg_body_start + 1 + 2 * cj, "SOS repeats a component selector Cs");
					}
					selected[cs] = true;
                    if (!sof_comp_ids[cs]) {
                        try addFinding(&report, allocator, .fail, .sos_component_mismatch,
                            seg_body_start + 1 + 2 * cj,
                            "SOS component selector Cs not declared in SOF");
                    }
                }
				// T.81 B.2.3: an interleaved scan (Ns > 1) has at most 10 data
				// units per MCU. Out-of-range or undeclared factors are already
				// reported, so only an otherwise legal combination is judged.
				if (check_duplicates and ns > 1) {
					var units: usize = 0;
					var judged = true;
					for (0..ns) |index| {
						const cs = data[seg_body_start + 1 + 2 * index];
						const hv = sof_comp_hv[cs];
						const hi = hv >> 4;
						const vi = hv & 15;
						if (!sof_comp_ids[cs] or hi < 1 or hi > 4 or vi < 1 or vi > 4) judged = false;
						units += @as(usize, hi) * vi;
					}
					if (judged and units > 10) {
						const detail = try std.fmt.allocPrint(allocator,
							"interleaved scan MCU has {d} data units; T.81 B.2.3 allows at most 10", .{units});
						defer allocator.free(detail);
						try addExactFinding(&report, allocator, .sof_sampling_invalid, seg_body_start, detail);
					}
				}
            }

            // Validate the scan's spectral / predictor parameters per frame
            // type. SOS body tail is Ss, Se, AhAl after Ns×(Cs,Td/Ta).
            if (seen_sof and seg_body_start < seg_end) {
                const ns2 = data[seg_body_start];
                const spec_off = seg_body_start + 1 + 2 * @as(usize, ns2);
				// Validate rulings H (2026-11-23): an invalid Ns (already 55)
				// leaves Ss, Se, Ah and Al unlocated, so they are not judged.
				const ns_valid = report.variant == .jpegls or
					!(ns2 == 0 or ns2 > 4 or (sof_component_count != 0 and ns2 > sof_component_count));
                if (ns_valid and spec_off + 2 < seg_end) {
                    const ss = data[spec_off];
                    const se = data[spec_off + 1];
                    const ahal = data[spec_off + 2];
                    const ah = ahal >> 4;
                    const al = ahal & 0x0F;
                    switch (report.variant) {
						.baseline_huffman, .extended_huffman => if (ss == 0 and se == 0 and ahal == 0 and
							sos_count == 1 and ns2 == sof_component_count)
						{
							go_zero_se = spec_off + 1;
						} else {
							try checkSequentialScanField(&report, allocator, spec_off, "Ss", ss, 0);
							try checkSequentialScanField(&report, allocator, spec_off + 1, "Se", se, 63);
							try checkSequentialScanField(&report, allocator, spec_off + 2, "Ah (high nibble)", ah, 0);
							try checkSequentialScanField(&report, allocator, spec_off + 2, "Al (low nibble)", al, 0);
						},
                        .progressive_huffman, .progressive_arithmetic => {
                            // T.81 §G.1.1.1.1: Ss,Se ≤ 63 and Ah,Al ≤ 13; a DC
                            // scan (Ss=0) must have Se=0; an AC scan (Ss≠0) must
                            // have Se in Ss..63.
                            const bad = ss > 63 or se > 63 or ah > 13 or al > 13 or
                                (ss == 0 and se != 0) or (ss != 0 and se < ss);
                            if (bad) try addFinding(&report, allocator, .fail,
                                .progressive_scan_invalid, spec_off,
                                "progressive SOS spectral/approximation parameters violate T.81 §G");
                        },
                        .lossless_huffman, .lossless_arithmetic => {
                            // T.81 §H.1: Ss is the predictor selector (1..7);
                            // Ah must be 0 (lossless has no successive
                            // approximation — the byte carries only the point
                            // transform in Al).
                            // Table H.1: selection value 0 ("no prediction") is
                            // only for differential coding in hierarchical mode.
                            if (if (frame_differential) ss > 7 else ss < 1 or ss > 7)
                                try addFinding(&report, allocator, .fail,
                                    .lossless_predictor_invalid, spec_off,
                                    if (frame_differential) "differential lossless predictor (Ss) must be 0..7"
                                    else "lossless predictor (Ss) must be 1..7");
                            if (ah != 0)
                                try addFinding(&report, allocator, .fail,
                                    .lossless_pointtransform_invalid, spec_off + 2,
                                    "lossless scan must have Ah=0 (byte carries only point transform Al)");
                        },
                        else => {},
                    }
                }
            }
            // Entropy-coded data follows. Skip until we hit a non-RST,
            // non-padding marker (likely EOI, but could be another SOS
            // for progressive/multi-scan sequences).
            pos = seg_end;
            const new_pos = skipEntropyData(data, pos, report.variant == .jpegls);
            // If skipEntropyData reaches end without finding any marker,
            // surface as truncation. We treat "ran off the end" as the
            // entropy stream not being terminated by EOI (or a follow-on
            // marker), which is `truncated_stream`.
            if (new_pos == null) {
                try addFinding(&report, allocator, .fail, .truncated_stream,
                    data.len, "SOS entropy data not terminated by a marker");
                return report;
            }
            pos = new_pos.?;
			at_first_scan_end = frame_scans == 1;
            continue;
        }

		// Finding 72 (validate, 2026-11-21). Hierarchical streams are left to
		// their INFO "not checked": B.2.5 placement is judged for one frame.
		if (marker_byte == 0xdc and !hierarchical) {
			if (seg_len != 4) {
				try addFinding(&report, allocator, .fail, .bad_marker_length, pos,
					"DNL segment length must be 4");
			} else {
				const lines = readU16BE(data, seg_body_start);
				const proper = frame_declared_y == @as(u16, 0) and right_after_first_scan and frame_dnls == 0;
				if (!proper) {
					const token: []const u8 = if ((frame_declared_y orelse 0) != 0)
						"with_nonzero_y"
					else if (frame_dnls > 0)
						"repeated"
					else if (frame_scans == 0)
						"before_first_scan"
					else
						"after_later_scan";
					// FAIL only when two declared line counts conflict.
					const severity: Severity = if (frame_lines) |declared| (if (declared == lines) .warn else .fail) else .warn;
					const detail = try std.fmt.allocPrint(allocator,
						"{s}: DNL NL={d} outside the slot T.81 B.2.5 allows (right after the first scan of a Y=0 frame)", .{ token, lines });
					defer allocator.free(detail);
					try addFinding(&report, allocator, severity, .dnl_misplaced, marker_offset, detail);
					report.findings.items[report.findings.items.len - 1].offset_is_exact = true;
					if (severity == .fail) nonblocking_fails += 1;
				}
				frame_dnls += 1;
			}
		}

        pos = seg_end;
    }

    // ── Step 3: After-loop sanity ──────────────────────────────
	// Known defect 68 only when that scan was the frame's only scan; in a
	// multi-scan file the same bytes are an ordinary FAIL 64.
	if (go_zero_se) |se_offset| {
		if (sos_count == 1) {
			try addFinding(&report, allocator, .known_defect, .sequential_scan_zero_se, se_offset,
				"sequential SOS Ss=0 Se=0 Ah=Al=0 in the only scan: Go image/jpeg before 5f7bec69; admitted known defect");
			report.findings.items[report.findings.items.len - 1].offset_is_exact = true;
		} else {
			try checkSequentialScanField(&report, allocator, se_offset, "Se", 0, 63);
		}
	}

    if (!seen_sof) {
        try addFinding(&report, allocator, .fail, .duplicate_sof, null,
            "no SOF marker found");
    }
    if (!seen_sos) {
        try addFinding(&report, allocator, .fail, .truncated_stream, null,
            "no SOS marker found before stream end");
    }
    if (!seen_eoi and !blockingFail(&report, nonblocking_fails)) {
		// FAIL class: an interrupted transfer, with no known writer. It was
		// WARN because readers decode the pixels anyway, which no longer
		// counts (owner, 2026-11-06). The codec check still runs.
        try addFinding(&report, allocator, .fail, .missing_eoi, data.len,
            "stream lacks EOI marker (0xFF 0xD9)");
		nonblocking_fails += 1;
    }

    // Progressive frames decode in multiple scans; surface the count as an
    // observation (consumers may use it for quality / progressive-render hints).
    switch (report.variant) {
        .progressive_huffman, .progressive_arithmetic => {
            if (sos_count > 0) {
                var nbuf: [48]u8 = undefined;
                const detail = std.fmt.bufPrint(&nbuf, "{d} progressive scans", .{sos_count}) catch "progressive scans";
                try addFinding(&report, allocator, .info, .progressive_scan_count, null, detail);
            }
        },
        else => {},
    }

	// Validate rulings G (2026-11-23): a DHT symbol past T.81's bound for the
	// frame precision is FAIL 51, exact at the symbol byte. No producer in
	// either project's corpora writes one. DC categories are at most P+3
	// (lossless 16); AC sizes at most P+2; and outside progressive scans,
	// where G.1.2.2 makes them EOBRUN symbols, no size-0 symbol has a run of
	// 1 to 14. Before the codec check, so its decode-through 58 does not
	// repeat the same table fault.
	if (frame_precision) |p| if (report.variant != .jpegls) {
		const lossless = report.variant == .lossless_huffman or report.variant == .lossless_arithmetic;
		const progressive = report.variant == .progressive_huffman or report.variant == .progressive_arithmetic;
		segments: for (dht_segments.items) |segment| {
			var hp = segment[0];
			while (hp + 17 <= segment[1]) {
				const tc = data[hp] >> 4;
				var total: usize = 0;
				for (data[hp + 1 ..][0..16]) |count| total += count;
				if (hp + 17 + total > segment[1]) break;
				for (data[hp + 17 ..][0..total], 0..) |value, k| {
					const size = value & 0x0F;
					const run = value >> 4;
					const bad = if (tc == 0)
						value > (if (lossless) 16 else @as(usize, p) + 3)
					else
						size > @as(usize, p) + 2 or (!progressive and size == 0 and run >= 1 and run <= 14);
					if (!bad) continue;
					const detail = try std.fmt.allocPrint(allocator,
						"DHT Tc={d} Th={d}: symbol 0x{X:0>2} is past the T.81 bound for {d}-bit samples",
						.{ tc, data[hp] & 0x0F, value, p });
					defer allocator.free(detail);
					try addExactFinding(&report, allocator, .huffman_table_corrupt, hp + 17 + k, detail);
					break :segments;
				}
				hp += 17 + total;
			}
		}
	};

    // ── Step 4: Codec-level integrity ──────────────────────────
    // SOF3 consumes Huffman syntax without pixels or recovery. Other supported
    // variants run the cleanroom decoder with `lenient = true` + FindingsSink.
    // The marker walker catches
    // structural problems (missing markers, bad segment lengths,
    // truncation); decoding-through is the ground truth for
    // coefficient-level corruption — corrupt Huffman tables, bad
    // DCT coefficients, mismatched quantization tables.
    //
    // Cleanroom-only at runtime (per project architecture: libjpeg /
    // charls / openjpeg are build-time oracles only, used by tests
    // via `jpegz.internal.*`). Variants the cleanroom doesn't
    // recognize yield an INFO finding rather than FAIL — validator
    // doesn't have ground truth for those, so it stays silent on
    // codec correctness rather than slandering files libjpeg-turbo
    // would have accepted. CMYK and other un-cleanroomed variants
    // surface this way until their cleanroom paths land.
    //
    // We skip when:
    //   - The walker already found a fail-rated structural problem
    //     (the cleanroom would just rediscover it; saves cycles).
    //   - The variant is JPEG 2000 (separate `jpegz.jpeg2000`
    //     entry point with its own validation path).
    if (hierarchical and !blockingFail(&report, nonblocking_fails)) {
		// The cleanroom decoders do not implement Annex J. Say so, as for any
		// other unchecked variant, rather than decode only the first frame.
		report.codec_check = .unsupported;
		try addFinding(&report, allocator, .info, .unknown_marker, null,
			"hierarchical (DHP) process beyond cleanroom scope — codec integrity not checked");
	} else if (!blockingFail(&report, nonblocking_fails) and shouldRunCodecCheck(report.variant)) {
        var sink = types.FindingsSink.init(allocator);
        defer sink.deinit();

        const result = checkCodec(allocator, data, report.variant, &sink);

        // Drain sink → report findings (extraneous_bytes,
        // insufficient_data, etc.). Same severity/code/offset/detail
        // shape used by the marker walker, so the report is uniform.
        for (sink.items()) |f| {
            try addFinding(&report, allocator, reportSeverity(f.code, f.severity), f.code, f.offset, f.detail);
            report.findings.items[report.findings.items.len - 1].offset_is_exact = f.offset_is_exact;
        }

        if (result) |_| {
            // Codec traversal completed; decoder findings may report recovery.
            report.codec_check = .decoded;
        } else |err| switch (err) {
            error.NotImplemented => {
                report.codec_check = .unsupported;
                // Cleanroom doesn't own this variant yet — don't slander
                // the file with FAIL. Surface as INFO so strict
                // consumers know we didn't run codec check.
                try addFinding(&report, allocator, .info, .unknown_marker, null,
                    "codec variant beyond cleanroom v1 scope — codec integrity not checked");
            },
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                report.codec_check = .failed;
                // A decoder that already named the defect with an exact
                // offset needs no second, generic bucket for the same stop.
                const typed = for (sink.items()) |f| {
                    if (f.severity == .fail) break true;
                } else false;
                if (!typed) try addFinding(&report, allocator, .fail,
                    switch (report.variant) {
                        .jpegls, .baseline_arithmetic, .progressive_arithmetic, .lossless_arithmetic => mapTypedCodecError(err),
                        else => mapDecodeErrorToFindingCode(err),
                    },
                    null, @errorName(err));
            },
        }
    }

	// Finding 69 (A3, validate approved 2026-11-06). A sequential Huffman
	// frame with no DHT anywhere is the Motion-JPEG pattern: known defect
	// when every scan decodes completely with the T.81 K.3 tables (the
	// decoders install them), FAIL otherwise. With some DHT present, a scan
	// naming an undefined table is FAIL at that Td/Ta byte.
	const sequential_huffman_frame = report.variant == .baseline_huffman or report.variant == .extended_huffman;
	if (sequential_huffman_frame and first_sos_offset != null) {
		if (!seen_dht) {
			const complete = report.codec_check == .decoded and report.overall.rank() < Severity.fail.rank();
			if (complete) {
				try addFinding(&report, allocator, .known_defect, .huffman_tables_missing, first_sos_offset,
					"no DHT segment; every scan decodes completely with the T.81 Annex K.3 tables (Motion-JPEG); admitted known defect");
			} else {
				try addFinding(&report, allocator, .fail, .huffman_tables_missing, first_sos_offset,
					"no DHT segment, and the scans do not decode completely with the T.81 Annex K.3 tables");
			}
		} else if (first_missing_table) |offset| {
			try addExactFinding(&report, allocator, .huffman_tables_missing, offset,
				"scan names a Huffman table that no DHT segment defines");
		}
	}


    return report;
}

/// True when a FAIL finding other than the reclassified non-blocking ones is
/// present: the codec check would only rediscover a structural fault.
fn blockingFail(report: *const ValidationReport, nonblocking_fails: usize) bool {
	var fails: usize = 0;
	for (report.findings.items) |finding| {
		if (finding.severity == .fail) fails += 1;
	}
	return fails > nonblocking_fails;
}

fn checkCodec(allocator: Allocator, data: []const u8, variant: Variant, sink: *types.FindingsSink) errors.DecodeError!void {
    if (variant == .lossless_huffman) return @import("../decode/lossless.zig").validate(data, sink);
    // Straight to the JPEG-LS decoder: the general dispatcher would fall
    // through an unsupported JPEG-LS scan into the T.81 decoders.
    if (variant == .jpegls) {
        // Subsampled planes are decoded and checked, then discarded.
        var planes: [4]?types.Image = .{ null, null, null, null };
        defer for (&planes) |*plane| if (plane.*) |*image| image.deinit(allocator);
        var image = try @import("../decode/jpegls.zig").decodeWithOptions(allocator, data, .{ .findings_sink = sink, .map_samples = false, .planes = &planes });
        image.deinit(allocator);
        return;
    }
    var image = try types.decodeWithOptions(allocator, data, .{ .lenient = true, .findings_sink = sink });
    image.deinit(allocator);
}

/// Map a public `DecodeError` from the codec-integrity decode-through
/// to the closest `FindingCode` for validator output.
///
/// Bucketing rationale: the marker walker (validator step 1-3)
/// already catches genuine `bad_marker_length` / `missing_soi` /
/// real `truncated_stream` (data ends mid-segment) BEFORE the codec
/// check runs. Any decoder error that surfaces here means structural
/// scaffolding was sound but coefficient-level / table-level decode
/// failed — bucket everything as `huffman_table_corrupt` (the most
/// common cause) unless we have a more specific signal.
fn mapDecodeErrorToFindingCode(err: errors.DecodeError) FindingCode {
    return switch (err) {
        // DHT/DQT/DAC malformed internal data, bitstream desync from
        // corrupt tables, etc. — all bucket as huffman_table_corrupt.
        error.InvalidMarker          => .huffman_table_corrupt,
        error.BackendError           => .huffman_table_corrupt,
        error.TruncatedStream        => .huffman_table_corrupt,

        error.UnsupportedPrecision   => .invalid_sof_precision,
        error.InvalidJp2Codestream   => .jp2_invalid_codestream,

        // NotRowStreamable / CallbackAborted shouldn't surface in
        // validate's path (we don't stream rows); bucket them as
        // unknown_marker if they ever do.
        error.NotRowStreamable, error.CallbackAborted => .unknown_marker,
        error.NotImplemented, error.OutOfMemory => unreachable,
    };
}

/// JPEG-LS and arithmetic-coded decode errors with no typed finding (validate,
/// 2026-11-21 and 2026-11-22: never `huffman_table_corrupt`). Entropy faults
/// arrive typed (JPEG-LS: 120, 122, 56, 57 and 121 for LSE values;
/// arithmetic: 8, 56, 57, 58 and 74), so the remaining errors come from
/// segment content the marker walk does not parse. Exhaustive: a new
/// DecodeError does not compile until it is classified here.
fn mapTypedCodecError(err: errors.DecodeError) FindingCode {
    return switch (err) {
        error.TruncatedStream => .truncated_stream,
        error.InvalidMarker => .bad_marker_length,
        error.UnsupportedPrecision => .invalid_sof_precision,
        // Only reachable if a fault skipped its typed finding: flag it as
        // unclassified rather than guess a codec code.
        error.BackendError, error.InvalidJp2Codestream, error.NotRowStreamable, error.CallbackAborted => .unknown_marker,
        error.NotImplemented, error.OutOfMemory => unreachable,
    };
}

/// libjpeg-turbo handles SOF0/1/2/3/9/10/11. JPEG-LS, differential
/// variants, and JPEG 2000 don't reach this validator (JP2 has its
/// own path); skip the decode-through if the marker walker thinks the
/// variant is something else, otherwise libjpeg would just emit
/// "Unsupported JPEG process" and we'd add a redundant finding.
fn shouldRunCodecCheck(variant: Variant) bool {
    return switch (variant) {
        .baseline_huffman,
        .extended_huffman,
        .progressive_huffman,
        .lossless_huffman,
        .baseline_arithmetic,
        .progressive_arithmetic,
        .lossless_arithmetic,
        // The Zig JPEG-LS decoder reports its faults (validate, 2026-11-21).
        .jpegls,
        => true,
        // jpeg_xl never reaches this walker either — `validateAny` routes it
        // to libjxlz before any T.81 marker parsing happens.
        .unknown, .jpeg2000, .jpeg_xl => false,
    };
}

/// Walk past entropy-coded scan data to the next marker. Inside an SOS,
/// any literal 0xFF in the entropy stream is escaped as 0xFF 0x00; a
/// real marker is 0xFF followed by a non-zero, non-RST byte. RST markers
/// (0xFF D0..D7) are intra-scan resets and DO continue the scan.
///
/// Map an APPn marker (0xE0..0xEF) + its segment body to a known
/// producer signature, returning the corresponding INFO `FindingCode`
/// or null if the signature is unrecognized.
///
/// Signatures are NUL-terminated identifiers at the start of the body
/// (T.81 doesn't standardize this; it's de-facto industry convention).
/// We match prefix bytes only — values inside the segment are not
/// parsed. validate's metadata pipeline handles deeper inspection.
fn classifyAppSignature(marker: u8, body: []const u8) ?FindingCode {
    return switch (marker) {
        // APP0 — JFIF / JFXX
        0xE0 => if (startsWith(body, "JFIF\x00") or startsWith(body, "JFXX\x00"))
            FindingCode.jfif_metadata_present
        else
            null,

        // APP1 — Exif or XMP (most common; Adobe also uses APP1)
        0xE1 => blk: {
            if (startsWith(body, "Exif\x00\x00")) break :blk FindingCode.exif_metadata_present;
            if (startsWith(body, "http://ns.adobe.com/xap/1.0/\x00"))
                break :blk FindingCode.xmp_metadata_present;
            break :blk null;
        },

        // APP2 — ICC profile
        0xE2 => if (startsWith(body, "ICC_PROFILE\x00"))
            FindingCode.icc_profile_present
        else
            null,

        // APP13 — Photoshop IRB
        0xED => if (startsWith(body, "Photoshop 3.0\x00"))
            FindingCode.photoshop_irb_present
        else
            null,

        else => null,
    };
}

fn startsWith(haystack: []const u8, prefix: []const u8) bool {
    return haystack.len >= prefix.len and std.mem.eql(u8, haystack[0..prefix.len], prefix);
}

/// Returns the byte offset of the 0xFF that begins the next "real"
/// marker (so the outer parser can re-enter its 0xFF-handling loop).
/// Returns null if the stream ends without a terminating marker.
/// `bit_stuffed` (JPEG-LS): T.87 A.1.3 bit-stuffs instead of byte-stuffing, so an FF
/// followed by a byte below 0x80 is entropy data, not a marker.
fn skipEntropyData(data: []const u8, start: usize, bit_stuffed: bool) ?usize {
    var i = start;
    while (i < data.len) {
        if (data[i] != 0xFF) {
            i += 1;
            continue;
        }
        // 0xFF: peek next byte (skipping fill 0xFFs).
        var j = i + 1;
        while (j < data.len and data[j] == 0xFF) j += 1;
        if (j >= data.len) return null;
        const next = data[j];
        if (bit_stuffed and j == i + 1 and next < 0x80) {
            i = j + 1;
            continue;
        }
        if (next == 0x00) {
            // 0xFF 0x00 = stuffed literal, continues entropy data.
            i = j + 1;
            continue;
        }
        if (next >= Marker.RST0 and next <= Marker.RST7) {
            // Restart marker, scan continues.
            i = j + 1;
            continue;
        }
        // Real marker — return position of the 0xFF (so outer loop
        // re-enters at the marker prefix).
        return i;
    }
    return null;
}
