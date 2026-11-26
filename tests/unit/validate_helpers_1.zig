//! Helpers shared by the validate test files (part 1 of 2).

const std = @import("std");
const jpegz = @import("jpegz");
const h2 = @import("validate_helpers_2.zig");
const mpfFile = h2.mpfFile;
const TrailingSeen = h2.TrailingSeen;
const trailingFindings = h2.trailingFindings;
const DnlRewrite = h2.DnlRewrite;
const dnlVariant = h2.dnlVariant;
const dnl_fixtures = h2.dnl_fixtures;
const scanEnd = h2.scanEnd;
const firstSos = h2.firstSos;
const DnlPlacement = h2.DnlPlacement;
const withDnls = h2.withDnls;
const sofHeightOffset = h2.sofHeightOffset;

pub const fixture_baseline_2x2_rgb = @embedFile("fixtures/baseline_2x2_rgb.jpg");

pub const fixture_progressive_8x8 = @embedFile("fixtures/progressive_8x8_rgb.jpg");

pub const fixture_lossless_4x4_gray8 = @embedFile("fixtures/lossless_4x4_gray8.jpg");

pub const fixture_arith_8x8_gray = @embedFile("fixtures/arith_baseline_8x8_gray.jpg");

/// Assert the report names `code` as a FAIL at exactly `offset`, and does not
/// also fall back to the generic huffman_table_corrupt bucket.
pub fn expectOnlyTypedFail(report: jpegz.ValidationReport, code: jpegz.FindingCode, offset: u64) !void {
	return expectOnlyTyped(report, .fail, code, offset);
}

pub fn expectExactTypedFailures(report: jpegz.ValidationReport, code: jpegz.FindingCode, offset: u64, expected: usize) !void {
	try std.testing.expectEqual(jpegz.Severity.fail, report.overall);
	var count: usize = 0;
	for (report.findings.items) |finding| {
		if (finding.severity != .fail) continue;
		try std.testing.expectEqual(code, finding.code);
		try std.testing.expectEqual(@as(?u64, offset), finding.offset);
		try std.testing.expect(finding.offset_is_exact);
		count += 1;
	}
	try std.testing.expectEqual(expected, count);
}

/// Match the complete set of mixed-padding FAILs to exact entropy-byte indexes,
/// excluding the generic Huffman fallback in validation and decoder sinks.
pub fn expectMixedPadFailures(findings: anytype, base: usize, indexes: []const usize) !void {
	var count: usize = 0;
	for (findings) |finding| {
		try std.testing.expect(finding.code != .huffman_table_corrupt);
		if (finding.code != .entropy_padding_not_ones) continue;
		try std.testing.expect(count < indexes.len);
		try std.testing.expectEqual(jpegz.Severity.fail, finding.severity);
		try std.testing.expect(finding.offset_is_exact);
		try std.testing.expectEqual(@as(?u64, base + indexes[count]), finding.offset);
		count += 1;
	}
	try std.testing.expectEqual(indexes.len, count);
}

pub fn expectOnlyTyped(report: jpegz.ValidationReport, severity: jpegz.Severity, code: jpegz.FindingCode, offset: u64) !void {
	var found = false;
	for (report.findings.items) |f| {
		if (f.severity == severity and f.code == code and f.offset == offset) found = true;
		if (f.code == .huffman_table_corrupt) {
			std.debug.print("generic huffman_table_corrupt alongside {s}\n", .{@tagName(code)});
			return error.TestUnexpectedResult;
		}
	}
	if (!found) {
		for (report.findings.items) |f| std.debug.print("  got {s} {s} @{?d}\n", .{ @tagName(f.severity), @tagName(f.code), f.offset });
		std.debug.print("expected {s} {s} @{d}\n", .{ @tagName(severity), @tagName(code), offset });
		return error.TestUnexpectedResult;
	}
}

/// Assert the findings name all-zero entropy padding as exactly one exact WARN
/// per padded segment, at `base + index`, with no FAIL beside them.
pub fn expectZeroPadWarnings(findings: anytype, base: usize, indexes: []const usize) !void {
	var warnings: usize = 0;
	for (findings) |f| {
		if (f.severity == .fail) {
			std.debug.print("unexpected FAIL {s} @{?d}\n", .{ @tagName(f.code), f.offset });
			return error.TestUnexpectedResult;
		}
		if (f.code != .entropy_padding_zero_bits) continue;
		try std.testing.expectEqual(jpegz.Severity.known_defect, f.severity);
		try std.testing.expect(f.offset_is_exact);
		const offset = f.offset orelse return error.TestUnexpectedResult;
		for (indexes) |index| {
			if (offset == base + index) break;
		} else {
			std.debug.print("zero-padding WARN at unexpected offset {d}\n", .{offset});
			return error.TestUnexpectedResult;
		}
		warnings += 1;
	}
	try std.testing.expectEqual(indexes.len, warnings);
}

/// 4×4 baseline RGB JPEG whose DHT (Huffman table definition) was
/// corrupted by setting all 16 code-length counts to 0xFF — an
/// impossible declaration that fails libjpeg's Huffman validation
/// with "Bogus Huffman table definition". The structural marker walker
/// passes (DHT length and bracket are intact); only codec-level
/// integrity catches it.
pub const fixture_baseline_4x4_bogus_dht = @embedFile("fixtures/baseline_4x4_bogus_dht.jpg");

// ── M1.5c (per validate handoff 2026-05-06) — APPn presence + trailing data ──

pub const fixture_baseline_4x4_with_exif     = @embedFile("fixtures/baseline_4x4_with_exif.jpg");

pub const fixture_baseline_4x4_with_trailing = @embedFile("fixtures/baseline_4x4_with_trailing.jpg");

// ── Dormant T.81 code wiring (validation strictness for upstream Validate) ──
// A strict validator must surface table/structure-level spec violations that
// permissive libraries silently tolerate. Each new code is tested as a
// classifier over sets: it fires on the malformed set, stays silent on the
// well-formed one.

/// Offset of the first occurrence of marker byte `m` (the byte after a
/// 0xFF prefix) in `data`, or null. Helper for in-test corruption.
pub fn findMarker(data: []const u8, m: u8) ?usize {
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 1) {
        if (data[i] == 0xFF and data[i + 1] == m) return i;
    }
    return null;
}

pub fn reportHasCode(report: jpegz.ValidationReport, code: jpegz.FindingCode) bool {
    for (report.findings.items) |f| {
        if (f.code == code) return true;
    }
    return false;
}

pub fn countCode(report: jpegz.ValidationReport, code: jpegz.FindingCode, severity: jpegz.Severity, offset: u64) !usize {
	var n: usize = 0;
	for (report.findings.items) |f| if (f.code == code) {
		try std.testing.expectEqual(severity, f.severity);
		try std.testing.expect(f.offset_is_exact);
		try std.testing.expectEqual(@as(?u64, offset), f.offset);
		n += 1;
	};
	return n;
}

/// Validate rulings G (2026-11-23): a DHT symbol past the precision bound is
/// FAIL 51, exact at the symbol byte, and the report's only FAIL.
pub fn expectDhtSymbolPastBound(allocator: std.mem.Allocator, data: []const u8, symbol_at: usize) !void {
	var report = try jpegz.validate(allocator, data);
	defer report.deinit(allocator);
	errdefer for (report.findings.items) |f| std.debug.print("  {t} {?d} {s}\n", .{ f.code, f.offset, f.detail orelse "" });
	var fails: usize = 0;
	for (report.findings.items) |f| {
		if (f.severity != .fail) continue;
		fails += 1;
		try std.testing.expectEqual(jpegz.FindingCode.huffman_table_corrupt, f.code);
		try std.testing.expect(f.offset_is_exact);
		try std.testing.expectEqual(@as(?u64, symbol_at), f.offset);
		try std.testing.expect(std.mem.indexOf(u8, f.detail.?, "is past the T.81 bound") != null);
	}
	try std.testing.expectEqual(@as(usize, 1), fails);
}

/// One exact FAIL `code` at `offset` with `detail` among decoder findings.
pub fn expectOneExact(items: []const jpegz.Finding, code: jpegz.FindingCode, offset: usize, detail: []const u8) !void {
	errdefer for (items) |f| std.debug.print("  {t} {?d} {s}\n", .{ f.code, f.offset, f.detail orelse "" });
	var hits: usize = 0;
	for (items) |f| {
		if (f.code != code) continue;
		hits += 1;
		try std.testing.expect(f.severity == .fail and f.offset_is_exact);
		try std.testing.expectEqual(@as(?u64, offset), f.offset);
		try std.testing.expectEqualStrings(detail, f.detail.?);
	}
	try std.testing.expectEqual(@as(usize, 1), hits);
}

/// The decode API's findings for `data`, decoded leniently.
pub fn decodeFindings(allocator: std.mem.Allocator, data: []const u8, sink: *jpegz.FindingsSink) void {
	if (jpegz.decodeWithOptions(allocator, data, .{ .lenient = true, .findings_sink = sink })) |image| {
		var img = image;
		img.deinit(allocator);
	} else |_| {}
}

/// The first marker at or after `from` that ends an entropy segment (not a
/// stuffed byte or an RSTm).
pub fn segmentEndMarker(data: []const u8, from: usize) usize {
	var i = from;
	while (!(data[i] == 0xff and data[i + 1] != 0 and data[i + 1] != 0xff and (data[i + 1] < 0xd0 or data[i + 1] > 0xd7))) i += 1;
	return i;
}

pub fn entropyStart(data: []const u8, sos: usize) usize {
	return sos + 2 + (@as(usize, data[sos + 2]) << 8 | data[sos + 3]);
}

/// Two-sample 8-bit lossless (SOF3, predictor 1) frame with DC table 0
/// coded by `bits` and `values`; entropy data follows.
pub fn losslessHead(comptime bits: [16]u8, comptime values: []const u8) [2 + 13 + 5 + 16 + values.len + 10]u8 {
	return [_]u8{ 0xff, 0xd8, 0xff, 0xc3, 0, 11, 8, 0, 1, 0, 2, 1, 1, 0x11, 0 } ++
		[_]u8{ 0xff, 0xc4, 0, 2 + 1 + 16 + values.len, 0x00 } ++ bits ++ values[0..values.len].* ++
		[_]u8{ 0xff, 0xda, 0, 8, 1, 1, 0x00, 1, 0, 0 };
}

// ── Zero-dimension SOF (T.81 §B.2.2) ────────────────────────────────
// A SOF declaring width (X) = 0 or height (Y) = 0 is not a decodable
// image: X must be > 0, and Y = 0 is defined only with a DNL segment
// (which libjpeg rejects outright as "Empty JPEG image"). The marker
// walker reads the SOF dimensions, so it must reject the zero case too —
// independently of the cleanroom codec path (which never runs for
// variants it doesn't own, and which crashed in color.fancyUpsample on
// an empty component plane before this guard).

/// Duplicate `src` and overwrite the 16-bit big-endian field at `off`
/// (in the copy) with `value`. Caller owns the returned slice.
pub fn patchU16BE(allocator: std.mem.Allocator, src: []const u8, off: usize, value: u16) ![]u8 {
    const buf = try allocator.dupe(u8, src);
    buf[off] = @intCast(value >> 8);
    buf[off + 1] = @intCast(value & 0xFF);
    return buf;
}

/// Offset of the SOF0 segment length (the byte just past `0xFF 0xC0`).
/// baseline_2x2_rgb is encoded as SOF0 (marker 0xC0).
pub fn findSof0Body(data: []const u8) ?usize {
    var i: usize = 2;
    while (i + 1 < data.len) : (i += 1) {
        if (data[i] == 0xFF and data[i + 1] == 0xC0) return i + 2;
    }
    return null;
}

// ─────────────────────────────────────────────────────────────────────
// U1 — `jpeg2000.validate` must actually validate (facade milestone).
//
// jpegz is the whole-JPEG-family facade: `validate` consumes jpegz and
// must get T.800 corruption detection through it, in jpegz's own
// `FindingCode` vocabulary. `jpeg2000.validate` was a stub returning
// `.pass` + empty findings — a false negative BY CONSTRUCTION (a
// shredded JP2 reported PASS), while jp2z had real strict validation
// that jpegz simply never called.
//
// Tested as a CLASSIFIER OVER SETS, not a single example:
//   - sensitivity corpus: structural mutations that MUST be detected
//   - specificity corpus: every known-good fixture must NOT fail
// Without the specificity half a reject-everything stub scores 100%.
//
// Scope note: only STRUCTURAL corruption is in the must-detect bucket.
// Damage confined to packet/entropy bodies is legitimately may-ignore
// for a codestream walker — asserting on it would encode a promise the
// tier-1 layer doesn't make yet.

pub const fixture_jp2_rgb = @embedFile("fixtures/jp2_8x8_rgb.jp2");

pub const fixture_jp2_lossless = @embedFile("fixtures/jp2_8x8_lossless_5x3.jp2");

pub const fixture_jp2_lossy97 = @embedFile("fixtures/jp2_8x8_lossy_9x7.jp2");

pub const fixture_jp2_subsampled = @embedFile("fixtures/jp2_8x8_subsampled.jp2");

pub const fixture_jp2_yuv420 = @embedFile("fixtures/jp2_8x8_yuv420_asym.jp2");

// The original ffmpeg fixture declares BPC=8 (9 bits) but Ssiz=7 (8 bits).
// T.800 I.5.3.1 requires agreement. Preserve the original decoder fixture;
// correct only its container declaration for the validation specificity set.
pub const fixture_jp2_yuv420_matching_depth = blk: {
    var bytes = fixture_jp2_yuv420.*;
    bytes[58] = 7;
    break :blk bytes;
};

pub const jp2_specificity_corpus = [_][]const u8{
    fixture_jp2_rgb,
    fixture_jp2_lossless,
    fixture_jp2_lossy97,
    fixture_jp2_subsampled,
    &fixture_jp2_yuv420_matching_depth,
};

/// Offset of the JPEG 2000 SOC+SIZ marker pair (`FF4F FF51`) — the start
/// of the codestream inside the `jp2c` box. T.800 §A.4.1.
pub fn findSoc(data: []const u8) ?usize {
    var i: usize = 0;
    while (i + 3 < data.len) : (i += 1) {
        if (data[i] == 0xFF and data[i + 1] == 0x4F and
            data[i + 2] == 0xFF and data[i + 3] == 0x51) return i;
    }
    return null;
}

pub const fixture_seq_16x16_3scan = @embedFile("fixtures/seq_16x16_3scan.jpg");

pub const fixture_seq_17x13_420_y_cbcr_rst = @embedFile("fixtures/seq_17x13_420_y_cbcr_rst.jpg");

pub const fixture_seq_23x19_422_rev_rst = @embedFile("fixtures/seq_23x19_422_rev_rst.jpg");

pub const fixture_seq_23x19_rgb12_420_3scan = @embedFile("fixtures/seq_23x19_rgb12_420_3scan.jpg");

// Preserve the libjpeg-generated entropy while moving its table definitions
// and selectors together. Six specifications share one DHT with Lh=626:
// luma DC/AC, chroma DC/AC, and a second copy of the chroma pair.
// Omit APP0 so arbitrary component IDs do not claim JFIF conformance.
pub fn sof1TableFixture(allocator: std.mem.Allocator, dc_shift: u8, ac_shift: u8, first_id: u8) ![]u8 {
	const source = fixture_baseline_2x2_rgb;
	const data = try std.mem.concat(allocator, u8, &.{
		source[0..2], source[20..177], &.{ 0xff, 0xc4, 0x02, 0x72 },
		source[181..210], source[214..393], source[397..426], source[430..609],
		source[397..426], source[430..609], source[609..],
	});
	const sof = 140;
	const dht = 159;
	const sos = dht + 628;
	data[sof + 1] = 0xc1;
	const specifications = [_]usize{ 4, 33, 212, 241, 420, 449 };
	for (0..3) |component| {
		const index: u8 = @intCast(component);
		const dc = (index + dc_shift) % 4;
		const ac = (index + ac_shift) % 4;
		data[dht + specifications[component * 2]] = dc;
		data[dht + specifications[component * 2 + 1]] = 0x10 | ac;
		data[sof + 10 + component * 3] = first_id +% index;
		data[sos + 5 + component * 2] = first_id +% index;
		data[sos + 6 + component * 2] = (dc << 4) | ac;
	}
	return data;
}

/// A minimal one-component 8-bit lossless (SOF3, predictor 1) stream whose
/// entropy data is coded with `bits`/`values`, the DNG pattern of finding 71.
/// Category SSSS for each difference is coded, then its SSSS extra bits.
pub fn losslessWithTable(allocator: std.mem.Allocator, width: u8, samples: []const u8, bits: [16]u8, values: []const u8) ![]u8 {
	const height: u8 = @intCast(samples.len / width);
	// Canonical codes (T.81 Annex C), allowing an exactly full table.
	var codes: [16]u16 = undefined;
	var lengths: [16]u5 = undefined;
	var code: u32 = 0;
	var k: usize = 0;
	for (bits, 1..) |count, len| {
		for (0..count) |_| {
			codes[values[k]] = @intCast(code);
			lengths[values[k]] = @intCast(len);
			code += 1;
			k += 1;
		}
		code <<= 1;
	}
	var out: std.ArrayList(u8) = .empty;
	errdefer out.deinit(allocator);
	try out.appendSlice(allocator, &.{ 0xff, 0xd8, 0xff, 0xc3, 0, 11, 8, 0, height, 0, width, 1, 1, 0x11, 0 });
	try out.appendSlice(allocator, &.{ 0xff, 0xc4, 0, @intCast(2 + 1 + 16 + values.len), 0x00 });
	try out.appendSlice(allocator, &bits);
	try out.appendSlice(allocator, values);
	try out.appendSlice(allocator, &.{ 0xff, 0xda, 0, 8, 1, 1, 0x00, 1, 0, 0 });
	var acc: u32 = 0;
	var nbits: u5 = 0;
	const Writer = struct {
		fn put(o: *std.ArrayList(u8), a: std.mem.Allocator, accp: *u32, np: *u5, value: u32, n: u5) !void {
			var i: u5 = n;
			while (i > 0) {
				i -= 1;
				accp.* = (accp.* << 1) | ((value >> i) & 1);
				np.* += 1;
				if (np.* == 8) {
					const byte: u8 = @intCast(accp.* & 0xff);
					try o.append(a, byte);
					if (byte == 0xff) try o.append(a, 0x00);
					accp.* = 0;
					np.* = 0;
				}
			}
		}
	};
	for (samples, 0..) |sample, index| {
		const x = index % width;
		const predicted: i32 = if (index == 0) 128 else if (x == 0) samples[index - width] else samples[index - 1];
		const diff: i32 = @as(i32, sample) - predicted;
		const magnitude: u32 = @abs(diff);
		const category: u5 = if (magnitude == 0) 0 else @intCast(32 - @clz(magnitude));
		try Writer.put(&out, allocator, &acc, &nbits, codes[category], lengths[category]);
		if (category != 0) {
			const extra: u32 = if (diff > 0) @intCast(diff) else @intCast(diff + (@as(i32, 1) << category) - 1);
			try Writer.put(&out, allocator, &acc, &nbits, extra, category);
		}
	}
	if (nbits != 0) try Writer.put(&out, allocator, &acc, &nbits, 0xff, 8 - nbits); // 1-bit padding
	try out.appendSlice(allocator, &.{ 0xff, 0xd9 });
	return out.toOwnedSlice(allocator);
}

/// Copy `data` without its DHT segments (Tc/Th filter: null removes all).
/// Walks the marker chain and copies each scan's entropy data unchanged.
pub fn withoutDht(allocator: std.mem.Allocator, data: []const u8, only_tcth: ?u8) ![]u8 {
	var out: std.ArrayList(u8) = .empty;
	errdefer out.deinit(allocator);
	try out.appendSlice(allocator, data[0..2]);
	var pos: usize = 2;
	while (pos + 4 <= data.len) {
		const marker = data[pos + 1];
		if (marker == 0xd9) break;
		const len = std.mem.readInt(u16, data[pos + 2 ..][0..2], .big);
		var end = pos + 2 + len;
		if (marker == 0xda) {
			while (end + 1 < data.len and !(data[end] == 0xff and data[end + 1] != 0 and (data[end + 1] < 0xd0 or data[end + 1] > 0xd7))) end += 1;
		}
		const drop = marker == 0xc4 and (only_tcth == null or data[pos + 4] == only_tcth.?);
		if (!drop) try out.appendSlice(allocator, data[pos..end]);
		pos = end;
	}
	try out.appendSlice(allocator, data[pos..]);
	return out.toOwnedSlice(allocator);
}

