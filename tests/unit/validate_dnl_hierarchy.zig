//! validate tests, part 9 (split from validate.zig to keep files small).

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

test "a DNL anywhere but right after the first scan of a Y=0 frame is 72 at its marker" {
	const allocator = std.testing.allocator;
	const progressive = fixture_progressive_8x8; // Y = 8, several scans
	// The same file with Y zeroed and a proper DNL after the first scan.
	const proper = try dnlVariant(allocator, progressive, .{});
	defer allocator.free(proper);
	const y_zero = try dnlVariant(allocator, progressive, .{ .dnl = false });
	defer allocator.free(y_zero);
	const Case = struct { name: []const u8, base: []const u8, scan: usize, lines: u16, severity: jpegz.Severity, token: []const u8, before_sos: bool = false };
	const cases = [_]Case{
		.{ .name = "nonzero Y, agreeing", .base = progressive, .scan = 1, .lines = 8, .severity = .warn, .token = "with_nonzero_y" },
		.{ .name = "nonzero Y, conflicting", .base = progressive, .scan = 1, .lines = 9, .severity = .fail, .token = "with_nonzero_y" },
		.{ .name = "repeated, agreeing", .base = proper, .scan = 2, .lines = 8, .severity = .warn, .token = "repeated" },
		.{ .name = "repeated, conflicting", .base = proper, .scan = 2, .lines = 7, .severity = .fail, .token = "repeated" },
		.{ .name = "repeated with NL 0", .base = proper, .scan = 2, .lines = 0, .severity = .fail, .token = "repeated" },
		.{ .name = "Y=0, only after a later scan", .base = y_zero, .scan = 2, .lines = 8, .severity = .warn, .token = "after_later_scan" },
		.{ .name = "Y=0, only before the first scan", .base = y_zero, .scan = 0, .lines = 8, .severity = .warn, .token = "before_first_scan", .before_sos = true },
	};
	for (cases) |case| {
		const at = if (case.before_sos) firstSos(case.base) else scanEnd(case.base, case.scan);
		const data = try withDnls(allocator, case.base, &.{.{ .at = at, .lines = case.lines }});
		defer allocator.free(data);
		var report = try jpegz.validate(allocator, data);
		defer report.deinit(allocator);
		var found: ?jpegz.Finding = null;
		var count: usize = 0;
		for (report.findings.items) |f| if (f.code == .dnl_misplaced) {
			found = f;
			count += 1;
		};
		const ok = if (found) |f| count == 1 and f.severity == case.severity and f.offset == at and f.offset_is_exact and
			std.mem.indexOf(u8, f.detail orelse "", case.token) != null else false;
		if (!ok) {
			std.debug.print("{s}: want {t} {s} at {d}, got {d} finding(s)\n", .{ case.name, case.severity, case.token, at, count });
			for (report.findings.items) |f| std.debug.print("  {t} {t} {?d} {?s}\n", .{ f.severity, f.code, f.offset, f.detail });
			return error.TestUnexpectedResult;
		}
	}
	// The proper DNL itself is not misplaced.
	var report = try jpegz.validate(allocator, proper);
	defer report.deinit(allocator);
	for (report.findings.items) |f| try std.testing.expect(f.code != .dnl_misplaced);
}

test "a differential SOF with no DHP before it is FAIL 73 at the SOF marker" {
	const allocator = std.testing.allocator;
	for ([_]struct { base: []const u8, sof: u8 }{
		.{ .base = @embedFile("fixtures/baseline_16x16_rgb_420.jpg"), .sof = 0xc5 },
		.{ .base = fixture_progressive_8x8, .sof = 0xc6 },
		.{ .base = fixture_lossless_4x4_gray8, .sof = 0xc7 },
		.{ .base = fixture_arith_8x8_gray, .sof = 0xcd },
		.{ .base = fixture_progressive_8x8, .sof = 0xce },
		.{ .base = fixture_lossless_4x4_gray8, .sof = 0xcf },
	}) |case| {
		const data = try allocator.dupe(u8, case.base);
		defer allocator.free(data);
		const sof = sofHeightOffset(data) - 5;
		data[sof + 1] = case.sof;
		var report = try jpegz.validate(allocator, data);
		defer report.deinit(allocator);
		const flagged = for (report.findings.items) |f| {
			if (f.code == .differential_frame_without_dhp and f.severity == .fail and f.offset == sof and f.offset_is_exact) break true;
		} else false;
		if (!flagged) {
			std.debug.print("SOF{X:0>2}: no FAIL 73 at {d}\n", .{ case.sof, sof });
			for (report.findings.items) |f| std.debug.print("  {t} {t} {?d} {?s}\n", .{ f.severity, f.code, f.offset, f.detail });
			return error.TestUnexpectedResult;
		}
	}
	// Each original stays free of 73.
	for ([_][]const u8{ fixture_progressive_8x8, fixture_lossless_4x4_gray8, fixture_arith_8x8_gray }) |data| {
		var report = try jpegz.validate(allocator, data);
		defer report.deinit(allocator);
		for (report.findings.items) |f| try std.testing.expect(f.code != .differential_frame_without_dhp);
	}
}

