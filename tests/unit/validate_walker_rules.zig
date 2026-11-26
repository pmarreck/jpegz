//! validate tests, part 6 (split from validate.zig to keep files small).

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

test "progressive ZRL past Se is 74, and a file ending in unread bytes is truncated_stream" {
	const allocator = std.testing.allocator;
	// 8x8 gray progressive frame. DC table: code 0 -> category 0. AC table:
	// code 0 -> ZRL (0xF0), code 10 -> EOB.
	const head = [_]u8{ 0xff, 0xd8, 0xff, 0xdb, 0, 67, 0 } ++ ([_]u8{16} ** 64) ++
		[_]u8{ 0xff, 0xc2, 0, 11, 8, 0, 8, 0, 8, 1, 1, 0x11, 0 } ++
		[_]u8{ 0xff, 0xc4, 0, 20, 0x00, 1 } ++ ([_]u8{0} ** 15) ++ [_]u8{0} ++
		[_]u8{ 0xff, 0xc4, 0, 21, 0x10, 1, 1 } ++ ([_]u8{0} ** 14) ++ [_]u8{ 0xf0, 0x00 } ++
		[_]u8{ 0xff, 0xda, 0, 8, 1, 1, 0, 0, 0, 0, 0x7f } ++
		[_]u8{ 0xff, 0xda, 0, 8, 1, 1, 0, 1, 63, 0 };
	{
		// Four ZRLs from k = 1: 17, 33, 49, then 49 + 15 passes Se = 63.
		const data = head ++ [_]u8{ 0x0f, 0xff, 0xd9 };
		var report = try jpegz.validate(allocator, &data);
		defer report.deinit(allocator);
		errdefer for (report.findings.items) |f| std.debug.print("  {t} {?d} {s}\n", .{ f.code, f.offset, f.detail orelse "" });
		var hits: usize = 0;
		for (report.findings.items) |f| {
			try std.testing.expect(f.code != .huffman_table_corrupt);
			if (f.code != .entropy_decode_invalid) continue;
			hits += 1;
			try std.testing.expect(f.offset_is_exact and f.offset.? == head.len);
			try std.testing.expectEqualStrings("AC zero run past Se=63", f.detail.?);
		}
		try std.testing.expectEqual(@as(usize, 1), hits);
	}
	{
		// AC code 11 matches nothing (codes 0 and 10 only).
		const data = head ++ [_]u8{ 0xdf, 0xdf, 0xdf, 0xdf, 0xff, 0xd9 };
		var report = try jpegz.validate(allocator, &data);
		defer report.deinit(allocator);
		try expectOneExact(report.findings.items, .entropy_decode_invalid, head.len, "AC Huffman code matches no table entry");
		for (report.findings.items) |f| try std.testing.expect(f.code != .huffman_table_corrupt);
	}
	{
		// The AC scan's EOB, its padding, then one stray byte and no marker.
		const data = head ++ [_]u8{ 0xbf, 0x12 };
		var sink = jpegz.FindingsSink.init(allocator);
		defer sink.deinit();
		try std.testing.expectError(error.TruncatedStream, jpegz.decodeWithOptions(allocator, &data, .{ .findings_sink = &sink }));
		var hits: usize = 0;
		for (sink.items()) |f| if (f.code == .truncated_stream) {
			hits += 1;
			try std.testing.expect(f.offset_is_exact and f.offset.? == data.len);
		};
		try std.testing.expectEqual(@as(usize, 1), hits);
	}
}

test "lossless data faults are typed: 74, 58, insufficient_data and restart 57 (validate 2026-11-22)" {
	const allocator = std.testing.allocator;
	// Codes: 0 -> category 0, 10 -> category 17 (past 16), or only code 0.
	const two = comptime losslessHead(.{ 1, 1 } ++ ([_]u8{0} ** 14), &.{ 0, 17 });
	const one = comptime losslessHead(.{1} ++ ([_]u8{0} ** 15), &.{0});
	const eight = comptime losslessHead(.{ 1, 1 } ++ ([_]u8{0} ** 14), &.{ 0, 8 });
	const Case = struct { data: []const u8, code: jpegz.FindingCode, offset: usize, exact: bool, detail: []const u8 };
	const cat17 = two ++ [_]u8{ 0xbf, 0xff, 0xd9 };
	const unmatched = one ++ [_]u8{ 0x80, 0x00, 0x00, 0x00, 0xff, 0xd9 };
	// Category 8 needs eight more bits; only six precede EOI.
	const short = eight ++ [_]u8{ 0xbf, 0xff, 0xd9 };
	{
		// Symbol 17 in the DHT (byte 37) is past 16 (rulings G); SOF3 syntax
		// validation still reports the decoded 58 for a table a walk misses.
		try expectDhtSymbolPastBound(allocator, &cat17, 37);
		var sink = jpegz.FindingsSink.init(allocator);
		defer sink.deinit();
		jpegz.internal.losslessValidateWithFindings(&cat17, &sink) catch {};
		try expectOneExact(sink.items(), .dct_coefficient_overflow, two.len, "difference category 17 exceeds 16 (T.81 H.1.2.2)");
	}
	for ([_]Case{
		.{ .data = &unmatched, .code = .entropy_decode_invalid, .offset = one.len, .exact = true, .detail = "difference Huffman code matches no table entry" },
		.{ .data = &short, .code = .insufficient_data, .offset = eight.len + 1, .exact = false, .detail = "Corrupt JPEG data: premature end of data segment" },
	}) |case| {
		var report = try jpegz.validate(allocator, case.data);
		defer report.deinit(allocator);
		errdefer for (report.findings.items) |f| std.debug.print("  {t} {?d} {s}\n", .{ f.code, f.offset, f.detail orelse "" });
		var hits: usize = 0;
		for (report.findings.items) |f| {
			try std.testing.expect(f.code != .huffman_table_corrupt);
			if (f.code != case.code) continue;
			hits += 1;
			try std.testing.expect(f.offset_is_exact == case.exact);
			try std.testing.expectEqual(@as(?u64, case.offset), f.offset);
			try std.testing.expectEqualStrings(case.detail, f.detail.?);
		}
		try std.testing.expectEqual(@as(usize, 1), hits);
		try std.testing.expect(!report.isValid());
	}
	const dri = @embedFile("fixtures/lossless_16x16_gray_dri.jpg");
	const rst = findMarker(dri, 0xd0).?;
	const eoi = dri.len - 2;
	var wrong = dri.*;
	wrong[rst + 1] = 0xd4;
	const final_rst = dri[0..eoi].* ++ [_]u8{ 0xff, 0xd7 } ++ dri[eoi..].*;
	for ([_]Case{
		.{ .data = &wrong, .code = .restart_marker_unexpected, .offset = rst, .exact = true, .detail = "expected RST0 (0xd0) but got RST4 (0xd4)" },
		.{ .data = &final_rst, .code = .restart_marker_unexpected, .offset = eoi, .exact = true, .detail = "restart marker after the final MCU of the scan" },
	}) |case| {
		var report = try jpegz.validate(allocator, case.data);
		defer report.deinit(allocator);
		errdefer for (report.findings.items) |f| std.debug.print("  {t} {?d} {s}\n", .{ f.code, f.offset, f.detail orelse "" });
		var hits: usize = 0;
		for (report.findings.items) |f| {
			try std.testing.expect(f.code != .huffman_table_corrupt);
			if (f.code != case.code) continue;
			hits += 1;
			try std.testing.expect(f.offset_is_exact and f.offset.? == case.offset);
			try std.testing.expectEqualStrings(case.detail, f.detail.?);
		}
		try std.testing.expectEqual(@as(usize, 1), hits);
	}
}

test "Huffman walker parity: DHT overruns, symbols past the bound, progressive tables and Ns (validate 2026-11-22, rulings F and G)" {
	const allocator = std.testing.allocator;
	{
		// BITS counts 4080 symbols in a 29-byte segment: 51 at the count
		// byte where the symbols stop fitting, the report's only FAIL.
		const bogus = @embedFile("fixtures/baseline_4x4_bogus_dht.jpg");
		var report = try jpegz.validate(allocator, bogus);
		defer report.deinit(allocator);
		var fails: usize = 0;
		for (report.findings.items) |f| if (f.severity == .fail) {
			fails += 1;
			try std.testing.expect(f.code == .huffman_table_corrupt and f.offset_is_exact and f.offset.? == 182);
			try std.testing.expectEqualStrings("DHT Tc=0 Th=0: BITS counts 4080 symbols but only 12 bytes remain in the segment", f.detail.?);
		};
		try std.testing.expectEqual(@as(usize, 1), fails);
	}
	// One 8x8 gray baseline block: DC table 0 (code 0 -> 0), AC table 0
	// (code 0 -> EOB), entropy 0x3f.
	const sof = [_]u8{ 0xff, 0xd8, 0xff, 0xdb, 0, 67, 0 } ++ ([_]u8{1} ** 64) ++
		[_]u8{ 0xff, 0xc0, 0, 11, 8, 0, 8, 0, 8, 1, 1, 0x11, 0 };
	const dc = [_]u8{ 0xff, 0xc4, 0, 20, 0x00, 1 } ++ ([_]u8{0} ** 15) ++ [_]u8{0};
	const ac = [_]u8{ 0xff, 0xc4, 0, 20, 0x10, 1 } ++ ([_]u8{0} ** 15) ++ [_]u8{0};
	const scan = [_]u8{ 0xff, 0xda, 0, 8, 1, 1, 0, 0, 63, 0, 0x3f, 0xff, 0xd9 };
	{
		const good = sof ++ dc ++ ac ++ scan;
		var report = try jpegz.validate(allocator, &good);
		defer report.deinit(allocator);
		try std.testing.expect(report.isValid());
	}
	{
		// A DHT ending inside a table's Tc/Th and BITS: 51 at the Tc/Th byte.
		const short = [_]u8{ 0xff, 0xc4, 0, 12, 0x01 } ++ ([_]u8{0} ** 9);
		const data = sof ++ dc ++ ac ++ short ++ scan;
		var report = try jpegz.validate(allocator, &data);
		defer report.deinit(allocator);
		try expectOneExact(report.findings.items, .huffman_table_corrupt, sof.len + dc.len + ac.len + 4, "DHT segment ends inside a table's Tc/Th and BITS header");
	}
	{
		// A sequential AC symbol 0x10 (run 1, size 0) has no meaning outside
		// progressive scans: past the bound (rulings G).
		var data = sof ++ dc ++ ac ++ scan;
		const symbol_at = sof.len + dc.len + ac.len - 1;
		data[symbol_at] = 0x10;
		try expectDhtSymbolPastBound(allocator, &data, symbol_at);
	}
	const rgb = @embedFile("fixtures/progressive_8x8_rgb.jpg");
	{
		// In a progressive frame 0x10 is EOBRUN 1 (T.81 G.1.2.2), within
		// the bound: the DHT stands, the decoder reports what follows.
		var data = rgb.*;
		data[260] ^= 0x10;
		var report = try jpegz.validate(allocator, &data);
		defer report.deinit(allocator);
		for (report.findings.items) |f| try std.testing.expect(f.code != .huffman_table_corrupt);
		try std.testing.expect(!report.isValid());
	}
	{
		// Lossless DC category 16 is within the bound (T.81 H.1.2.2).
		const head = comptime losslessHead(.{ 1, 1 } ++ ([_]u8{0} ** 14), &.{ 0, 16 });
		const data = head ++ [_]u8{ 0x3f, 0xff, 0xd9 };
		var report = try jpegz.validate(allocator, &data);
		defer report.deinit(allocator);
		try std.testing.expect(report.isValid());
	}
	{
		// A progressive AC scan naming undefined table 3: FAIL 69 at its
		// Td/Ta byte, with no decode-through 51 beside it.
		var data = rgb.*;
		data[267] = 0x03;
		var report = try jpegz.validate(allocator, &data);
		defer report.deinit(allocator);
		try expectExactTypedFailures(report, .huffman_tables_missing, 267, 1);
	}
	{
		// A DC refinement scan uses no table, so its Td is not judged.
		var data = rgb.*;
		data[410] = 0x30;
		var report = try jpegz.validate(allocator, &data);
		defer report.deinit(allocator);
		try std.testing.expect(report.isValid());
	}
	{
		// A later progressive scan with Ns = 5: the Ns code sequential scans
		// get, exact at Ns, instead of a generic 51.
		var data = rgb.*;
		data[265] = 5;
		var report = try jpegz.validate(allocator, &data);
		defer report.deinit(allocator);
		try expectExactTypedFailures(report, .sos_component_mismatch, 265, 1);
	}
	{
		// A first progressive scan with Ns = 0: 55 at Ns and nothing about
		// the misread tail fields (validate rulings H, 2026-11-23).
		var data = rgb.*;
		data[226] = 0;
		var report = try jpegz.validate(allocator, &data);
		defer report.deinit(allocator);
		try expectExactTypedFailures(report, .sos_component_mismatch, 226, 1);
	}
}

test "progressive scan history is FAIL 59, one record per scan (validate rulings I, T.81 G.1.1.1)" {
	const allocator = std.testing.allocator;
	const Expect = struct { offset: u64, detail: []const u8 };
	const check = struct {
		fn run(a: std.mem.Allocator, data: []const u8, first: Expect) !void {
			var report = try jpegz.validate(a, data);
			defer report.deinit(a);
			errdefer for (report.findings.items) |f| std.debug.print("  {t} {?d} {s}\n", .{ f.code, f.offset, f.detail orelse "" });
			var history: ?jpegz.Finding = null;
			for (report.findings.items) |f| {
				if (f.severity != .fail) continue;
				try std.testing.expectEqual(jpegz.FindingCode.progressive_scan_invalid, f.code);
				try std.testing.expect(std.mem.startsWith(u8, f.detail.?, "history: "));
				if (history == null) history = f;
			}
			const h = history orelse return error.TestExpectedHistory;
			try std.testing.expect(h.offset_is_exact);
			try std.testing.expectEqual(@as(?u64, first.offset), h.offset);
			try std.testing.expectEqualStrings(first.detail, h.detail.?);
		}
	}.run;
	const rgb = @embedFile("fixtures/progressive_8x8_rgb.jpg");
	{
		// The component-1 AC scan (with its DHT) moved before the DC first
		// scan: FAIL at the moved scan's Ss.
		const moved = try std.mem.concat(allocator, u8, &.{ rgb[0..222], rgb[239..272], rgb[222..239], rgb[272..] });
		defer allocator.free(moved);
		try check(allocator, moved, .{ .offset = 251, .detail = "history: AC scan for component 1 before its DC first scan (T.81 G.1.1.1.1)" });
	}
	{
		// The first AC scan relabeled Ah=1 Al=0: coefficients 1..5 were
		// never coded, so Ah must be 0. FAIL at its AhAl byte.
		var data = rgb.*;
		try std.testing.expectEqual(@as(u8, 0x02), data[270]);
		data[270] = 0x10;
		try check(allocator, &data, .{ .offset = 270, .detail = "history: component 1 coefficient 1 has Ah=1, but no scan has coded it, so Ah must be 0 (T.81 G.1.1.1.2)" });
	}
	{
		// SOF10: the AC refinement at 0xAA refines 1..63 from Al 2;
		// relabeled Ah=1 Al=0, it skips a bit plane.
		const arith = @embedFile("fixtures/arith_progressive_8x8_gray.jpg");
		var data = arith.*;
		try std.testing.expectEqual(@as(u8, 0x21), data[0xaa + 9]);
		data[0xaa + 9] = 0x10;
		try check(allocator, &data, .{ .offset = 0xaa + 9, .detail = "history: component 1 coefficient 1 has Ah=1, but the last scan coding it had Al=2 (T.81 G.1.1.1.2)" });
	}
	// One root cause, one record: the relabeled scan above leaves a later
	// refinement inconsistent too, but only the first fault is reported.
	{
		var data = rgb.*;
		data[270] = 0x10;
		var report = try jpegz.validate(allocator, &data);
		defer report.deinit(allocator);
		try expectExactTypedFailures(report, .progressive_scan_invalid, 270, 1);
	}
	// Valid controls: the producer fixtures keep a clean history.
	for ([_][]const u8{ rgb, @embedFile("fixtures/arith_progressive_8x8_gray.jpg"), @embedFile("fixtures/huffman_restart_32x32_rgb420_progressive_1b.jpg"), @embedFile("fixtures/progressive_8x8_gray12.jpg") }) |data| {
		var report = try jpegz.validate(allocator, data);
		defer report.deinit(allocator);
		try std.testing.expect(report.isValid());
	}
}

test "progressive per-scan rules: refinement Al = Ah - 1 and AC Ns = 1 are FAIL 59 (validate rulings I)" {
	const allocator = std.testing.allocator;
	const rgb = @embedFile("fixtures/progressive_8x8_rgb.jpg");
	{
		// The DC refinement scan at 404 (AhAl 0x10) relabeled Ah=2 Al=0.
		var data = rgb.*;
		try std.testing.expectEqual(@as(u8, 0x10), data[404 + 13]);
		data[404 + 13] = 0x20;
		var report = try jpegz.validate(allocator, &data);
		defer report.deinit(allocator);
		try expectExactTypedFailures(report, .progressive_scan_invalid, 404 + 13, 1);
		for (report.findings.items) |f| if (f.code == .progressive_scan_invalid)
			try std.testing.expectEqualStrings("refinement scan has Ah=2 and Al=0; Al must be Ah - 1 (T.81 G.1.1.1.1)", f.detail.?);
	}
	{
		// Three-component AC scan: the DC refinement scan at 404 (Ns 3)
		// relabeled Ss=1 Se=5, Ah=Al=0.
		var data = rgb.*;
		data[404 + 13] = 0x00;
		data[404 + 11] = 1;
		data[404 + 12] = 5;
		var report = try jpegz.validate(allocator, &data);
		defer report.deinit(allocator);
		try expectExactTypedFailures(report, .progressive_scan_invalid, 404 + 4, 1);
		for (report.findings.items) |f| if (f.code == .progressive_scan_invalid)
			try std.testing.expectEqualStrings("AC scan (Ss=1) has Ns=3; AC scans code one component (T.81 G.1.1.1.1)", f.detail.?);
	}
	{
		// The first AC scan (AhAl at 270) relabeled Ah=3 Al=0: one per-scan
		// record. Its coefficients stay unrecorded, and history stops, so the
		// later refinement of them is not reported as a second fault.
		var data = rgb.*;
		data[270] = 0x30;
		var report = try jpegz.validate(allocator, &data);
		defer report.deinit(allocator);
		try expectExactTypedFailures(report, .progressive_scan_invalid, 270, 1);
	}
}

test "validate: progressive_scan_count is INFO on progressive, absent on baseline" {
    const allocator = std.testing.allocator;

    // Positive: a progressive frame decodes in multiple scans.
    {
        var report = try jpegz.validate(allocator, fixture_progressive_8x8);
        defer report.deinit(allocator);
        try std.testing.expect(reportHasCode(report, .progressive_scan_count));
    }
    // Negative: a single-scan baseline must not carry the observation.
    {
        var report = try jpegz.validate(allocator, fixture_baseline_2x2_rgb);
        defer report.deinit(allocator);
        try std.testing.expect(!reportHasCode(report, .progressive_scan_count));
    }
}

test "validate: embedded_thumbnail_present detects JFIF APP0 thumbnail, silent when absent" {
    const allocator = std.testing.allocator;

    // Negative: the clean fixture's JFIF declares a 0×0 (absent) thumbnail.
    {
        var report = try jpegz.validate(allocator, fixture_baseline_2x2_rgb);
        defer report.deinit(allocator);
        try std.testing.expect(!reportHasCode(report, .embedded_thumbnail_present));
    }

    // Positive: splice a 1×1 thumbnail into the JFIF APP0 — set Xthumb=Ythumb=1,
    // insert 3 RGB bytes after Ythumb, bump the APP0 segment length 16 → 19.
    const orig = fixture_baseline_2x2_rgb;
    const app0 = findMarker(orig, 0xE0).?;
    const ins_at = app0 + 18; // first byte past the 16-byte APP0 segment
    const buf = try allocator.alloc(u8, orig.len + 3);
    defer allocator.free(buf);
    @memcpy(buf[0..ins_at], orig[0..ins_at]);
    buf[ins_at] = 0;
    buf[ins_at + 1] = 0;
    buf[ins_at + 2] = 0;
    @memcpy(buf[ins_at + 3 ..], orig[ins_at..]);
    buf[app0 + 2] = 0x00;
    buf[app0 + 3] = 0x13; // length 16 -> 19
    buf[app0 + 16] = 1; // Xthumbnail
    buf[app0 + 17] = 1; // Ythumbnail

    var report = try jpegz.validate(allocator, buf);
    defer report.deinit(allocator);
    try std.testing.expect(reportHasCode(report, .embedded_thumbnail_present));
}

test "validate SOF with zero height → FAIL, invalid_dimensions" {
    const allocator = std.testing.allocator;
    // SOF body: length(2) precision(1) height(2) width(2)…; height @ +3.
    const body = findSof0Body(fixture_baseline_2x2_rgb).?;
    const patched = try patchU16BE(allocator, fixture_baseline_2x2_rgb, body + 3, 0);
    defer allocator.free(patched);
    var report = try jpegz.validate(allocator, patched);
    defer report.deinit(allocator);
    try std.testing.expectEqual(jpegz.Severity.fail, report.overall);
    try std.testing.expect(reportHasCode(report, .invalid_dimensions));
}

test "validate SOF with zero width → FAIL, invalid_dimensions" {
    const allocator = std.testing.allocator;
    // width @ +5 in the SOF body.
    const body = findSof0Body(fixture_baseline_2x2_rgb).?;
    const patched = try patchU16BE(allocator, fixture_baseline_2x2_rgb, body + 5, 0);
    defer allocator.free(patched);
    var report = try jpegz.validate(allocator, patched);
    defer report.deinit(allocator);
    try std.testing.expectEqual(jpegz.Severity.fail, report.overall);
    try std.testing.expect(reportHasCode(report, .invalid_dimensions));
}

test "jpeg2000.validate: decodable YUV fixture has inconsistent container depth" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(u8, 8), fixture_jp2_yuv420[58]);
    for ([_]usize{ 127, 130, 133 }) |offset| {
        try std.testing.expectEqual(@as(u8, 7), fixture_jp2_yuv420[offset]);
    }
    var malformed = try jpegz.jpeg2000.validate(allocator, fixture_jp2_yuv420);
    defer malformed.deinit(allocator);
    try std.testing.expectEqual(jpegz.Severity.fail, malformed.overall);
    try std.testing.expect(reportHasCode(malformed, .jp2_invalid_codestream));

    var corrected = try jpegz.jpeg2000.validate(allocator, &fixture_jp2_yuv420_matching_depth);
    defer corrected.deinit(allocator);
    try std.testing.expect(corrected.overall != .fail);
    try std.testing.expect(!reportHasCode(corrected, .jp2_invalid_codestream));
}

test "an AC-class DHT table in a lossless frame is FAIL 51 at its Tc/Th byte, and decoding continues" {
	// ffmpeg 9.0.1's ljpeg writes the four K.3 tables, two of them AC
	// class, which T.81 Table B.5 does not allow in a lossless frame. The
	// table is never selected: one exact 51, the pixels are unchanged, and
	// the rest of the file is still judged.
	const allocator = std.testing.allocator;
	const head = comptime losslessHead(.{ 1, 1 } ++ ([_]u8{0} ** 14), &.{ 0, 8 });
	const ac = [_]u8{ 0xff, 0xc4, 0, 21, 0x10, 1, 1 } ++ ([_]u8{0} ** 14) ++ [_]u8{ 0x00, 0x01 };
	// Insert the AC table right after the DC table's DHT (before SOS).
	const sos = head.len - 10;
	const clean = head ++ [_]u8{ 0x3f, 0xff, 0xd9 };
	const with_ac = head[0..sos].* ++ ac ++ head[sos..].* ++ [_]u8{ 0x3f, 0xff, 0xd9 };
	var report = try jpegz.validate(allocator, &with_ac);
	defer report.deinit(allocator);
	try expectOneExact(report.findings.items, .huffman_table_corrupt, sos + 4, "DHT Tc=1 Th=0: a lossless frame allows only Tc=0 tables (T.81 Table B.5)");
	var fails: usize = 0;
	for (report.findings.items) |f| fails += @intFromBool(f.severity == .fail);
	try std.testing.expectEqual(@as(usize, 1), fails);
	var a = try jpegz.decode(allocator, &clean);
	defer a.deinit(allocator);
	var b = try jpegz.decode(allocator, &with_ac);
	defer b.deinit(allocator);
	try std.testing.expectEqualSlices(u8, a.pixels, b.pixels);
	// A later entropy fault is still found: the codec check ran.
	const damaged = head[0..sos].* ++ ac ++ head[sos..].* ++ [_]u8{ 0xbf, 0xff, 0xd9 };
	var report2 = try jpegz.validate(allocator, &damaged);
	defer report2.deinit(allocator);
	var insufficient = false;
	for (report2.findings.items) |f| insufficient = insufficient or f.code == .insufficient_data;
	try std.testing.expect(insufficient);
}

