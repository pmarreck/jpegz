//! validate tests, part 8 (split from validate.zig to keep files small).

const std = @import("std");
const jpegz = @import("jpegz");
const h1 = @import("validate_helpers_1.zig");
const h2 = @import("validate_helpers_2.zig");
const fixture_baseline_2x2_rgb = h1.fixture_baseline_2x2_rgb;
const fixture_progressive_8x8 = h1.fixture_progressive_8x8;
const fixture_lossless_4x4_gray8 = h1.fixture_lossless_4x4_gray8;
const fixture_arith_8x8_gray = h1.fixture_arith_8x8_gray;
const expectOnlyTypedFail = h1.expectOnlyTypedFail;
const expectExactTypedFailures = h1.expectExactTypedFailures;
const expectMixedPadFailures = h1.expectMixedPadFailures;
const expectOnlyTyped = h1.expectOnlyTyped;
const expectZeroPadWarnings = h1.expectZeroPadWarnings;
const fixture_baseline_4x4_bogus_dht = h1.fixture_baseline_4x4_bogus_dht;
const fixture_baseline_4x4_with_exif = h1.fixture_baseline_4x4_with_exif;
const fixture_baseline_4x4_with_trailing = h1.fixture_baseline_4x4_with_trailing;
const findMarker = h1.findMarker;
const reportHasCode = h1.reportHasCode;
const countCode = h1.countCode;
const expectDhtSymbolPastBound = h1.expectDhtSymbolPastBound;
const expectOneExact = h1.expectOneExact;
const decodeFindings = h1.decodeFindings;
const segmentEndMarker = h1.segmentEndMarker;
const entropyStart = h1.entropyStart;
const losslessHead = h1.losslessHead;
const patchU16BE = h1.patchU16BE;
const findSof0Body = h1.findSof0Body;
const fixture_jp2_rgb = h1.fixture_jp2_rgb;
const fixture_jp2_lossless = h1.fixture_jp2_lossless;
const fixture_jp2_lossy97 = h1.fixture_jp2_lossy97;
const fixture_jp2_subsampled = h1.fixture_jp2_subsampled;
const fixture_jp2_yuv420 = h1.fixture_jp2_yuv420;
const fixture_jp2_yuv420_matching_depth = h1.fixture_jp2_yuv420_matching_depth;
const jp2_specificity_corpus = h1.jp2_specificity_corpus;
const findSoc = h1.findSoc;
const fixture_seq_16x16_3scan = h1.fixture_seq_16x16_3scan;
const fixture_seq_17x13_420_y_cbcr_rst = h1.fixture_seq_17x13_420_y_cbcr_rst;
const fixture_seq_23x19_422_rev_rst = h1.fixture_seq_23x19_422_rev_rst;
const fixture_seq_23x19_rgb12_420_3scan = h1.fixture_seq_23x19_rgb12_420_3scan;
const sof1TableFixture = h1.sof1TableFixture;
const losslessWithTable = h1.losslessWithTable;
const withoutDht = h1.withoutDht;
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

test "an exactly full DHT is known defect 71 and decodes with its all-ones code" {
	const allocator = std.testing.allocator;
	// Differences in categories 0..3; codes 0, 10, 110 and the all-ones 111.
	const samples = [_]u8{ 128, 129, 127, 132, 135, 135, 131, 133 };
	const full = [_]u8{ 1, 1, 2 } ++ [_]u8{0} ** 13;
	const data = try losslessWithTable(allocator, 4, &samples, full, &.{ 0, 1, 2, 3 });
	defer allocator.free(data);

	var image = try jpegz.decode(allocator, data);
	defer image.deinit(allocator);
	try std.testing.expectEqualSlices(u8, &samples, image.pixels);

	var report = try jpegz.validate(allocator, data);
	defer report.deinit(allocator);
	// The BITS count for length 3 is at DHT body offset 1 + 2.
	const dht_body = 15 + 4;
	try expectOnlyTyped(report, .known_defect, .huffman_table_full_all_ones, dht_body + 3);
	try std.testing.expectEqual(jpegz.Severity.known_defect, report.overall);
	try std.testing.expect(report.isValid());
	try std.testing.expectEqual(.decoded, report.codec_check);

	// Control: the same samples with a table one code short of full (length 4
	// for category 3) carry no finding and decode identically.
	const spare = [_]u8{ 1, 1, 1, 1 } ++ [_]u8{0} ** 12;
	const control = try losslessWithTable(allocator, 4, &samples, spare, &.{ 0, 1, 2, 3 });
	defer allocator.free(control);
	var control_report = try jpegz.validate(allocator, control);
	defer control_report.deinit(allocator);
	try std.testing.expectEqual(jpegz.Severity.pass, control_report.overall);

	// Near miss: one codeword oversubscribed (three codes at length 3, a
	// fifth HUFFVAL byte, DHT length + 1) stays FAIL 51, not 71.
	const values_end = dht_body + 1 + 16 + 4;
	const over = try std.mem.concat(allocator, u8, &.{ data[0 .. dht_body + 3], &.{3}, data[dht_body + 4 .. values_end], &.{4}, data[values_end..] });
	defer allocator.free(over);
	over[dht_body - 1] += 1;
	var over_report = try jpegz.validate(allocator, over);
	defer over_report.deinit(allocator);
	try std.testing.expectEqual(jpegz.Severity.fail, over_report.overall);
	var generic = false;
	for (over_report.findings.items) |finding| {
		try std.testing.expect(finding.code != .huffman_table_full_all_ones);
		if (finding.code == .huffman_table_corrupt) generic = true;
	}
	try std.testing.expect(generic);
}

test "a full DHT in a baseline file is 71 and leaves the pixels unchanged" {
	const allocator = std.testing.allocator;
	// libjpeg-turbo's standard luma DC table (T.81 K.3) has Kraft sum 511/512;
	// one more code at length 9 fills it exactly. The image never uses it.
	const original = @embedFile("fixtures/historic_a3_control_with_dht.jpg");
	const k3_dc_bits = [_]u8{ 0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0 };
	const at = std.mem.indexOf(u8, original, &([_]u8{0x00} ++ k3_dc_bits)).?;
	const length_at = std.mem.lastIndexOf(u8, original[0..at], &.{ 0xff, 0xc4 }).? + 2;
	const values_end = at + 1 + 16 + 12;
	// The extra symbol is 11, within the 8-bit bound (rulings G); K.3 already
	// uses 0..11, so it repeats one.
	const data = try std.mem.concat(allocator, u8, &.{ original[0 .. at + 9], &.{2}, original[at + 10 .. values_end], &.{11}, original[values_end..] });
	defer allocator.free(data);
	const old_length = std.mem.readInt(u16, original[length_at..][0..2], .big);
	std.mem.writeInt(u16, data[length_at..][0..2], old_length + 1, .big);

	var report = try jpegz.validate(allocator, data);
	defer report.deinit(allocator);
	try expectOnlyTyped(report, .known_defect, .huffman_table_full_all_ones, at + 9);
	try std.testing.expectEqual(jpegz.Severity.known_defect, report.overall);
	var expected = try jpegz.decode(allocator, original);
	defer expected.deinit(allocator);
	var actual = try jpegz.decode(allocator, data);
	defer actual.deinit(allocator);
	try std.testing.expectEqualSlices(u8, expected.pixels, actual.pixels);
}

test "SOF component IDs (1, 2, 3, 1) are WARN 70 and decode by position; other duplicates FAIL" {
	const allocator = std.testing.allocator;
	// A29: baseline_4x4_cmyk.jpg with K's ID set from 4 to 1 in the SOF (175)
	// and the SOS selector (279) (HISTORIC_ENCODER_PROVENANCE.md).
	const exemplar = @embedFile("fixtures/historic_a29_cmyk_k_id1.jpg");
	const original = @embedFile("fixtures/baseline_4x4_cmyk.jpg");
	const sof_ids = [_]usize{ 166, 169, 172, 175 };
	const sos_ids = [_]usize{ 273, 275, 277, 279 };

	var report = try jpegz.validate(allocator, exemplar);
	defer report.deinit(allocator);
	try std.testing.expectEqual(jpegz.Severity.warn, report.overall);
	var warned = false;
	for (report.findings.items) |f| {
		try std.testing.expect(f.code != .sos_component_mismatch);
		if (f.code == .sof_component_id_duplicate) {
			try std.testing.expectEqual(jpegz.Severity.warn, f.severity);
			try std.testing.expectEqual(@as(?u64, 175), f.offset);
			try std.testing.expect(f.offset_is_exact);
			warned = true;
		}
	}
	try std.testing.expect(warned);
	try std.testing.expectEqual(.decoded, report.codec_check);
	var expected = try jpegz.decode(allocator, original);
	defer expected.deinit(allocator);
	var actual = try jpegz.decode(allocator, exemplar);
	defer actual.deinit(allocator);
	try std.testing.expectEqualSlices(u8, expected.pixels, actual.pixels);

	// Near misses: SOF IDs and SOS selectors (written to both), then only the
	// SOS order changed. Each must FAIL; 70 is FAIL unless the SOF is exact.
	const Case = struct { sof: [4]u8, sos: [4]u8, sof_warn: bool };
	const cases = [_]Case{
		.{ .sof = .{ 1, 1, 3, 4 }, .sos = .{ 1, 1, 3, 4 }, .sof_warn = false },
		.{ .sof = .{ 1, 2, 1, 4 }, .sos = .{ 1, 2, 1, 4 }, .sof_warn = false },
		.{ .sof = .{ 2, 2, 3, 1 }, .sos = .{ 2, 2, 3, 1 }, .sof_warn = false },
		.{ .sof = .{ 1, 2, 3, 1 }, .sos = .{ 1, 1, 2, 3 }, .sof_warn = true },
	};
	for (cases) |case| {
		const data = try allocator.dupe(u8, original);
		defer allocator.free(data);
		for (sof_ids, case.sof) |at, id| data[at] = id;
		for (sos_ids, case.sos) |at, id| data[at] = id;
		var r = try jpegz.validate(allocator, data);
		defer r.deinit(allocator);
		try std.testing.expectEqual(jpegz.Severity.fail, r.overall);
		var seventy: ?jpegz.Severity = null;
		for (r.findings.items) |f| {
			if (f.code == .sof_component_id_duplicate) seventy = f.severity;
		}
		try std.testing.expectEqual(@as(?jpegz.Severity, if (case.sof_warn) .warn else .fail), seventy);
	}
	// A three-component duplicate is never the writer pattern.
	const rgb = @embedFile("fixtures/baseline_2x2_rgb.jpg");
	const sof3 = std.mem.indexOf(u8, rgb, &.{ 0xff, 0xc0 }).?;
	const three = try allocator.dupe(u8, rgb);
	defer allocator.free(three);
	three[sof3 + 4 + 6 + 3 * 2] = three[sof3 + 4 + 6];
	var r3 = try jpegz.validate(allocator, three);
	defer r3.deinit(allocator);
	try std.testing.expectEqual(jpegz.Severity.fail, r3.overall);
	var failed = false;
	for (r3.findings.items) |f| {
		if (f.code == .sof_component_id_duplicate and f.severity == .fail and f.offset == sof3 + 4 + 6 + 3 * 2) failed = true;
	}
	try std.testing.expect(failed);
}

test "Go 1.0's Se=0 in the only sequential scan is known defect 68; near misses stay 64" {
	const allocator = std.testing.allocator;
	// Go image/jpeg before 5f7bec69 wrote 00 00 00 where 00 3f 00 belongs, in
	// one scan covering every component (golang/go issue 3916).
	const original = @embedFile("fixtures/baseline_2x2_rgb.jpg");
	const sos = std.mem.indexOf(u8, original, &.{ 0xff, 0xda }).?;
	const ns = original[sos + 4];
	try std.testing.expectEqual(@as(u8, 3), ns);
	const spec = sos + 5 + 2 * @as(usize, ns);
	try std.testing.expectEqualSlices(u8, &.{ 0, 63, 0 }, original[spec .. spec + 3]);

	const exemplar = try allocator.dupe(u8, original);
	defer allocator.free(exemplar);
	exemplar[spec + 1] = 0;
	var report = try jpegz.validate(allocator, exemplar);
	defer report.deinit(allocator);
	try expectOnlyTyped(report, .known_defect, .sequential_scan_zero_se, spec + 1);
	try std.testing.expectEqual(jpegz.Severity.known_defect, report.overall);
	try std.testing.expectEqual(.decoded, report.codec_check);
	for (report.findings.items) |f| try std.testing.expect(f.code != .sequential_scan_invalid);
	var expected = try jpegz.decode(allocator, original);
	defer expected.deinit(allocator);
	var actual = try jpegz.decode(allocator, exemplar);
	defer actual.deinit(allocator);
	try std.testing.expectEqualSlices(u8, expected.pixels, actual.pixels);

	// Near misses: another Se, the Go tail plus Ah=1, Ss=1 with Se=0.
	const Tail = struct { ss: u8, se: u8, ahal: u8 };
	for ([_]Tail{ .{ .ss = 0, .se = 5, .ahal = 0 }, .{ .ss = 0, .se = 0, .ahal = 0x10 }, .{ .ss = 1, .se = 0, .ahal = 0 } }) |tail| {
		const data = try allocator.dupe(u8, original);
		defer allocator.free(data);
		data[spec] = tail.ss;
		data[spec + 1] = tail.se;
		data[spec + 2] = tail.ahal;
		var r = try jpegz.validate(allocator, data);
		defer r.deinit(allocator);
		try std.testing.expectEqual(jpegz.Severity.fail, r.overall);
		var sixty_four = false;
		for (r.findings.items) |f| {
			try std.testing.expect(f.code != .sequential_scan_zero_se);
			if (f.code == .sequential_scan_invalid) sixty_four = true;
		}
		try std.testing.expect(sixty_four);
	}

	// The same scan followed by a second scan is not the Go file: FAIL 64 at
	// the first scan's Se byte.
	const eoi = original.len - 2;
	const two_scans = try std.mem.concat(allocator, u8, &.{ exemplar[0..eoi], exemplar[sos..eoi], exemplar[eoi..] });
	defer allocator.free(two_scans);
	var r2 = try jpegz.validate(allocator, two_scans);
	defer r2.deinit(allocator);
	try std.testing.expectEqual(jpegz.Severity.fail, r2.overall);
	var at_first = false;
	for (r2.findings.items) |f| {
		try std.testing.expect(f.code != .sequential_scan_zero_se);
		if (f.code == .sequential_scan_invalid and f.offset == spec + 1) at_first = true;
	}
	try std.testing.expect(at_first);
}

test "no DHT anywhere is known defect 69 when the K.3 tables decode every scan" {
	const allocator = std.testing.allocator;
	// A3: libjpeg-turbo cjpeg output with every DHT removed; its tables were
	// the K.3 tables (HISTORIC_ENCODER_PROVENANCE.md).
	const exemplar = @embedFile("fixtures/historic_a3_mjpeg_no_dht.jpg");
	const control = @embedFile("fixtures/historic_a3_control_with_dht.jpg");
	const stripped = try withoutDht(allocator, control, null);
	defer allocator.free(stripped);
	try std.testing.expectEqualSlices(u8, exemplar, stripped);
	const first_sos = std.mem.indexOf(u8, exemplar, &.{ 0xff, 0xda }).?;

	var report = try jpegz.validate(allocator, exemplar);
	defer report.deinit(allocator);
	try expectOnlyTyped(report, .known_defect, .huffman_tables_missing, first_sos);
	try std.testing.expectEqual(jpegz.Severity.known_defect, report.overall);
	var expected = try jpegz.decode(allocator, control);
	defer expected.deinit(allocator);
	var actual = try jpegz.decode(allocator, exemplar);
	defer actual.deinit(allocator);
	try std.testing.expectEqualSlices(u8, expected.pixels, actual.pixels);
	var control_report = try jpegz.validate(allocator, control);
	defer control_report.deinit(allocator);
	for (control_report.findings.items) |f| try std.testing.expect(f.code != .huffman_tables_missing);

	// Cut short: half the entropy data, then EOI. K.3 cannot decode it all.
	const half = first_sos + (exemplar.len - first_sos) / 2;
	const cut = try std.mem.concat(allocator, u8, &.{ exemplar[0..half], &.{ 0xff, 0xd9 } });
	defer allocator.free(cut);
	var cut_report = try jpegz.validate(allocator, cut);
	defer cut_report.deinit(allocator);
	try std.testing.expectEqual(jpegz.Severity.fail, cut_report.overall);
	var cut_fail = false;
	for (cut_report.findings.items) |f| {
		if (f.code == .huffman_tables_missing) {
			try std.testing.expectEqual(jpegz.Severity.fail, f.severity);
			cut_fail = true;
		}
	}
	try std.testing.expect(cut_fail);

	// Only the chrominance AC table missing: FAIL 69 at the first scan
	// component whose Ta names destination 1.
	const partial = try withoutDht(allocator, control, 0x11);
	defer allocator.free(partial);
	const sos = std.mem.indexOf(u8, partial, &.{ 0xff, 0xda }).?;
	var tdta_at: usize = 0;
	for (0..partial[sos + 4]) |k| {
		if (partial[sos + 6 + 2 * k] & 0x0f == 1) {
			tdta_at = sos + 6 + 2 * k;
			break;
		}
	}
	try std.testing.expect(tdta_at != 0);
	var partial_report = try jpegz.validate(allocator, partial);
	defer partial_report.deinit(allocator);
	try std.testing.expectEqual(jpegz.Severity.fail, partial_report.overall);
	var exact = false;
	for (partial_report.findings.items) |f| {
		if (f.code == .huffman_tables_missing and f.severity == .fail and f.offset == tdta_at and f.offset_is_exact) exact = true;
	}
	try std.testing.expect(exact);

	// A progressive file without DHT is not the Motion-JPEG pattern: no K.3
	// fallback, so FAIL 69 at the first scan's Td/Ta byte (validate,
	// 2026-11-22), and no generic 51 beside it.
	const progressive = @embedFile("fixtures/progressive_32x32_gray_dri.jpg");
	const bare = try withoutDht(allocator, progressive, null);
	defer allocator.free(bare);
	var p_report = try jpegz.validate(allocator, bare);
	defer p_report.deinit(allocator);
	try std.testing.expectEqual(jpegz.Severity.fail, p_report.overall);
	const p_sos = std.mem.indexOf(u8, bare, &.{ 0xff, 0xda }).?;
	try expectOnlyTyped(p_report, .fail, .huffman_tables_missing, p_sos + 6);
}

test "trailing data after EOI: MPF images and PAR2 are INFO, anything else WARN" {
	const allocator = std.testing.allocator;
	const primary = @embedFile("fixtures/baseline_2x2_rgb.jpg");
	const second = primary;
	const par2 = "PAR2\x00PKT" ++ [_]u8{0} ** 56;
	const Expect = struct { severity: jpegz.Severity, at: usize, detail: []const u8 };
	const Case = struct { name: []const u8, size_delta: i32 = 0, offset_delta: i32 = 0, tail: []const u8 = "", mpf: bool = true, expect: []const Expect };
	const app2_total: usize = 2 + 2 + 4 + 8 + 42 + 32;
	const second_at = 2 + app2_total + (primary.len - 2);
	const second_end = second_at + second.len;
	const cases = [_]Case{
		.{ .name = "MPF covers the second image", .expect = &.{.{ .severity = .info, .at = second_at, .detail = "mpf" }} },
		.{ .name = "MPF then PAR2", .tail = par2, .expect = &.{ .{ .severity = .info, .at = second_at, .detail = "mpf" }, .{ .severity = .info, .at = second_end, .detail = "par2" } } },
		.{ .name = "MPF then CRLF", .tail = "\r\n", .expect = &.{ .{ .severity = .info, .at = second_at, .detail = "mpf" }, .{ .severity = .warn, .at = second_end, .detail = "other" } } },
		.{ .name = "MPF size one short", .size_delta = -1, .expect = &.{ .{ .severity = .info, .at = second_at, .detail = "mpf" }, .{ .severity = .warn, .at = second_end - 1, .detail = "other" } } },
		.{ .name = "MPF offset one short", .offset_delta = -1, .expect = &.{.{ .severity = .warn, .at = second_at, .detail = "other" }} },
	};
	for (cases) |case| {
		const data = try mpfFile(allocator, primary, second, case.size_delta, case.offset_delta, case.tail);
		defer allocator.free(data);
		var report = try jpegz.validate(allocator, data);
		defer report.deinit(allocator);
		var got: [4]TrailingSeen = undefined;
		const n = trailingFindings(report, &got);
		var ok = n == case.expect.len;
		if (ok) for (case.expect, got[0..n]) |e, g| {
			if (e.severity != g.severity or g.offset != e.at or !std.mem.eql(u8, e.detail, g.detail)) ok = false;
		};
		if (!ok) {
			std.debug.print("trailing case '{s}': {d} findings\n", .{ case.name, n });
			for (got[0..@min(n, 4)]) |g| std.debug.print("  {s} @{?d} {s}\n", .{ @tagName(g.severity), g.offset, g.detail });
			return error.TestUnexpectedResult;
		}
		try std.testing.expect(report.isValid());
	}

	// Without MPF: PAR2 is INFO, a cut PAR2 magic and a CRLF are WARN.
	const Plain = struct { tail: []const u8, severity: jpegz.Severity, detail: []const u8 };
	for ([_]Plain{
		.{ .tail = par2, .severity = .info, .detail = "par2" },
		.{ .tail = "PAR2\x00PKX" ++ [_]u8{0} ** 8, .severity = .warn, .detail = "other" },
		.{ .tail = "\r\n", .severity = .warn, .detail = "other" },
		.{ .tail = &([_]u8{0} ** 32), .severity = .warn, .detail = "other" },
	}) |plain| {
		const data = try std.mem.concat(allocator, u8, &.{ primary, plain.tail });
		defer allocator.free(data);
		var report = try jpegz.validate(allocator, data);
		defer report.deinit(allocator);
		var got: [4]TrailingSeen = undefined;
		try std.testing.expectEqual(@as(usize, 1), trailingFindings(report, &got));
		try std.testing.expectEqual(plain.severity, got[0].severity);
		try std.testing.expectEqual(@as(?u64, primary.len), got[0].offset);
		try std.testing.expectEqualStrings(plain.detail, got[0].detail);
	}
}

test "DNL after the first scan supplies the height a SOF Y of 0 leaves open" {
	const allocator = std.testing.allocator;
	for (dnl_fixtures) |case| {
		const data = try dnlVariant(allocator, case.data, .{});
		defer allocator.free(data);
		var original = try jpegz.decode(allocator, case.data);
		defer original.deinit(allocator);
		var decoded = jpegz.decode(allocator, data) catch |err| {
			std.debug.print("{s}: DNL variant rejected: {s}\n", .{ case.name, @errorName(err) });
			return err;
		};
		defer decoded.deinit(allocator);
		try std.testing.expectEqual(original.width, decoded.width);
		try std.testing.expectEqual(original.height, decoded.height);
		try std.testing.expectEqualSlices(u8, original.pixels, decoded.pixels);

		var want = try jpegz.validate(allocator, case.data);
		defer want.deinit(allocator);
		var report = try jpegz.validate(allocator, data);
		defer report.deinit(allocator);
		if (report.overall != want.overall or report.height != want.height or report.codec_check != .decoded) {
			std.debug.print("{s}: overall {t} (want {t}), height {?d} (want {?d}), codec check {t}\n", .{ case.name, report.overall, want.overall, report.height, want.height, report.codec_check });
			for (report.findings.items) |f| std.debug.print("  {t} {t} {?d} {?s}\n", .{ f.severity, f.code, f.offset, f.detail });
			return error.TestUnexpectedResult;
		}
	}
}

test "SOF Y of 0 without a DNL giving a nonzero line count stays FAIL 61" {
	const allocator = std.testing.allocator;
	for (dnl_fixtures) |case| {
		for ([_]DnlRewrite{ .{ .dnl = false }, .{ .lines = 0 } }) |rewrite| {
			const data = try dnlVariant(allocator, case.data, rewrite);
			defer allocator.free(data);
			if (jpegz.decode(allocator, data)) |image| {
				var decoded = image;
				decoded.deinit(allocator);
				std.debug.print("{s}: decoded with dnl={} lines={?d}\n", .{ case.name, rewrite.dnl, rewrite.lines });
				return error.TestUnexpectedResult;
			} else |_| {}
			var report = try jpegz.validate(allocator, data);
			defer report.deinit(allocator);
			const flagged = for (report.findings.items) |f| {
				if (f.code == .invalid_dimensions and f.severity == .fail) break true;
			} else false;
			if (!flagged) {
				std.debug.print("{s}: no FAIL 61 with dnl={} lines={?d}\n", .{ case.name, rewrite.dnl, rewrite.lines });
				return error.TestUnexpectedResult;
			}
		}
	}
}

