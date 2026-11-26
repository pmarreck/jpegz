//! validate tests, part 5 (split from validate.zig to keep files small).

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

test "DAC entries classify every Tc/Tb byte and every DC and AC conditioning value (T.81 B.2.4.3)" {
	// The fixture's DAC holds (0x00, 0x10): DC table 0 with L = 0, U = 1, and
	// (0x10, 0x05): AC table 0 with Kx = 5. B.2.4.3: Tc is 0 or 1, Tb is 0..3,
	// a DC Cs is L + 16U with 0 <= L <= U <= 15, and an AC Cs is Kx in 1..63.
	// Validate (2026-11-22): FAIL 53 exactly at the offending byte, once per
	// segment.
	const allocator = std.testing.allocator;
	const dac = findMarker(fixture_arith_8x8_gray, 0xcc).?;
	try std.testing.expectEqualSlices(u8, &.{ 0, 6, 0x00, 0x10, 0x10, 0x05 }, fixture_arith_8x8_gray[dac + 2 .. dac + 8]);
	const Field = enum { tc_tb, dc_cs, ac_cs };
	for ([_]Field{ .tc_tb, .dc_cs, .ac_cs }) |field| {
		const at: usize = switch (field) { .tc_tb => dac + 4, .dc_cs => dac + 5, .ac_cs => dac + 7 };
		for (0..256) |value| {
			const data = try allocator.dupe(u8, fixture_arith_8x8_gray);
			defer allocator.free(data);
			data[at] = @intCast(value);
			const invalid = switch (field) {
				// The first entry's Cs, 0x10, is a valid DC (L 0, U 1) and AC (Kx 16) value.
				.tc_tb => value >> 4 > 1 or value & 15 > 3,
				.dc_cs => value & 15 > value >> 4,
				.ac_cs => value < 1 or value > 63,
			};
			var report = try jpegz.validate(allocator, data);
			defer report.deinit(allocator);
			var records: usize = 0;
			for (report.findings.items) |f| if (f.code == .arithmetic_table_corrupt) {
				records += 1;
				try std.testing.expectEqual(jpegz.Severity.fail, f.severity);
				try std.testing.expect(f.offset_is_exact);
				try std.testing.expectEqual(@as(?u64, at), f.offset);
			};
			errdefer std.debug.print("{s} value 0x{x:0>2}: {d} records\n", .{ @tagName(field), value, records });
			try std.testing.expectEqual(@as(usize, @intFromBool(invalid)), records);
		}
	}
}

test "arithmetic decoded-value faults are 58 and 74 at the interval start, never 51 (validate 2026-11-22)" {
	// Single-byte mutations of libjpeg-turbo files, found by search. Offsets
	// are labeled as the interval (the SOS without DRI) and not exact.
	const allocator = std.testing.allocator;
	const seq = @embedFile("fixtures/arith_baseline_16x16_rgb_420.jpg");
	const prog = @embedFile("fixtures/arith_restart_32x32_rgb420_progressive_1b.jpg");
	try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xda }, seq[189..191]);
	const Case = struct { data: []const u8, at: usize, mask: u8, code: jpegz.FindingCode, offset: u64, detail: []const u8 };
	for ([_]Case{
		.{ .data = seq, .at = 271, .mask = 0x01, .code = .dct_coefficient_overflow, .offset = 189,
			.detail = "scan starting here: AC coefficient magnitude 2524 exceeds 1023 for 8-bit samples (T.81 F.1.2)" },
		// 1025 is category 11: past the 8-bit AC bound, short of the old 0x8000 guard.
		.{ .data = prog, .at = 365, .mask = 0x10, .code = .dct_coefficient_overflow, .offset = 388,
			.detail = "restart interval starting here: AC coefficient magnitude 1025 exceeds 1023 for 8-bit samples (T.81 F.1.2)" },
		.{ .data = seq, .at = 205, .mask = 0x92, .code = .dct_coefficient_overflow, .offset = 189,
			.detail = "scan starting here: DC difference magnitude 2048 exceeds 2047 for 8-bit samples (T.81 F.1.2)" },
		// 2048 is one past the 8-bit DC bound, in an interleaved DC scan's third interval.
		.{ .data = prog, .at = 217, .mask = 0xb1, .code = .dct_coefficient_overflow, .offset = 215,
			.detail = "restart interval starting here: DC difference magnitude 2048 exceeds 2047 for 8-bit samples (T.81 F.1.2)" },
		.{ .data = seq, .at = 316, .mask = 0x10, .code = .entropy_decode_invalid, .offset = 189,
			.detail = "scan starting here: AC zero run past Se=63" },
		// Entropy only: a pin at 257 (the scan's Se byte) became a scan-history
		// fault once history was judged (validate rulings I).
		.{ .data = prog, .at = 259, .mask = 0x80, .code = .entropy_decode_invalid, .offset = 259,
			.detail = "restart interval starting here: AC zero run past Se=5" },
	}) |case| {
		const data = try allocator.dupe(u8, case.data);
		defer allocator.free(data);
		data[case.at] ^= case.mask;
		var report = try jpegz.validate(allocator, data);
		defer report.deinit(allocator);
		var hits: usize = 0;
		for (report.findings.items) |f| {
			try std.testing.expect(f.code != .huffman_table_corrupt);
			if (f.code != case.code) continue;
			hits += 1;
			try std.testing.expectEqual(jpegz.Severity.fail, f.severity);
			try std.testing.expect(!f.offset_is_exact);
			try std.testing.expectEqual(@as(?u64, case.offset), f.offset);
			try std.testing.expectEqualStrings(case.detail, f.detail.?);
		}
		try std.testing.expectEqual(@as(usize, 1), hits);
	}
	// Every single-byte mutation of the entropy data: no arithmetic decode
	// error is reported as 51, and in the sequential file none arrives untyped.
	for ([_][]const u8{ seq, @embedFile("fixtures/arith_progressive_16x16_rgb_444.jpg") }, 0..) |pristine, which| {
		const sos = findMarker(pristine, 0xda).?;
		const start = sos + 2 + (@as(usize, pristine[sos + 2]) << 8 | pristine[sos + 3]);
		const data = try allocator.dupe(u8, pristine);
		defer allocator.free(data);
		for (start..pristine.len - 2) |i| {
			for ([_]u8{ 0x01, 0x10, 0x80, 0xff }) |mask| {
				data[i] = pristine[i] ^ mask;
				defer data[i] = pristine[i];
				var report = try jpegz.validate(allocator, data);
				defer report.deinit(allocator);
				for (report.findings.items) |f| {
					try std.testing.expect(f.code != .huffman_table_corrupt);
					if (which == 0 and f.code == .unknown_marker and f.detail != null) {
						for ([_][]const u8{ "BackendError", "InvalidMarker", "TruncatedStream" }) |name| {
							try std.testing.expect(!std.mem.eql(u8, f.detail.?, name));
						}
					}
				}
			}
		}
	}
}

test "SOS table selectors outside T.81 Table B.3 are finding 75 (validate 2026-11-22)" {
	const allocator = std.testing.allocator;
	// One-block baseline gray frame with DC table 0 and AC table 0 defined.
	const pristine = [_]u8{ 0xff, 0xd8, 0xff, 0xdb, 0, 67, 0 } ++ ([_]u8{1} ** 64) ++
		[_]u8{ 0xff, 0xc0, 0, 11, 8, 0, 8, 0, 8, 1, 1, 0x11, 0 } ++
		[_]u8{ 0xff, 0xc4, 0, 20, 0x00, 1 } ++ ([_]u8{0} ** 15) ++ [_]u8{0} ++
		[_]u8{ 0xff, 0xc4, 0, 20, 0x10, 1 } ++ ([_]u8{0} ** 15) ++ [_]u8{0} ++
		[_]u8{ 0xff, 0xda, 0, 8, 1, 1, 0x00, 0, 63, 0, 0x3f, 0xff, 0xd9 };
	const sel = findMarker(&pristine, 0xda).? + 6;
	for (0..256) |value| {
		var data = pristine;
		data[sel] = @intCast(value);
		var report = try jpegz.validate(allocator, &data);
		defer report.deinit(allocator);
		const td = value >> 4;
		const ta = value & 15;
		// Above 3: no destination, FAIL. 1..3 name undefined tables here, which
		// finding 69 reports instead.
		const want: usize = @intFromBool(td > 3 or ta > 3);
		errdefer std.debug.print("Td/Ta 0x{x:0>2}\n", .{value});
		try std.testing.expectEqual(want, try countCode(report, .sos_table_selector_invalid, .fail, sel));
	}
	{
		// Define DC table 2 instead of 0 and select it: a baseline limit,
		// WARN; the scan still decodes. An extended (SOF1) frame allows it.
		var data = pristine;
		data[findMarker(&data, 0xc4).? + 4] = 0x02;
		data[sel] = 0x20;
		var report = try jpegz.validate(allocator, &data);
		defer report.deinit(allocator);
		try std.testing.expectEqual(@as(usize, 1), try countCode(report, .sos_table_selector_invalid, .warn, sel));
		try std.testing.expect(report.isValid());
		data[findMarker(&data, 0xc0).? + 1] = 0xc1;
		var extended = try jpegz.validate(allocator, &data);
		defer extended.deinit(allocator);
		try std.testing.expectEqual(@as(usize, 0), try countCode(extended, .sos_table_selector_invalid, .warn, sel));
	}
	{
		// Arithmetic scans: no conditioning destination above 3 either, and
		// the decoder never sees one, so nothing arrives untyped.
		const prog = @embedFile("fixtures/arith_progressive_16x16_rgb_444.jpg");
		const first = findMarker(prog, 0xda).? + 6;
		for ([_]usize{ first, first + 2, first + 4 }) |at| {
			for (0..256) |value| {
				const data = try allocator.dupe(u8, prog);
				defer allocator.free(data);
				data[at] = @intCast(value);
				var report = try jpegz.validate(allocator, data);
				defer report.deinit(allocator);
				const want: usize = @intFromBool(value >> 4 > 3 or value & 15 > 3);
				try std.testing.expectEqual(want, try countCode(report, .sos_table_selector_invalid, .fail, at));
				for (report.findings.items) |f| try std.testing.expect(f.code != .unknown_marker or
					f.detail == null or !std.mem.eql(u8, f.detail.?, "BackendError"));
			}
		}
	}
	{
		// Lossless: Td is judged; Ta is not (Table B.3 gives 0).
		const sel_ll = findMarker(fixture_lossless_4x4_gray8, 0xda).? + 6;
		for ([_]struct { value: u8, fails: usize }{ .{ .value = 0x01, .fails = 0 }, .{ .value = 0x0f, .fails = 0 }, .{ .value = 0x40, .fails = 1 } }) |case| {
			const data = try allocator.dupe(u8, fixture_lossless_4x4_gray8);
			defer allocator.free(data);
			data[sel_ll] = case.value;
			var report = try jpegz.validate(allocator, data);
			defer report.deinit(allocator);
			try std.testing.expectEqual(case.fails, try countCode(report, .sos_table_selector_invalid, .fail, sel_ll));
		}
	}
}

test "Huffman data faults are 74, 58 and 8 exact at the code, not 51 (validate 2026-11-22)" {
	// One 8x8 gray block. DC table: code 0 -> category 0. AC table: three-bit
	// codes 000 EOB, 001 ZRL, 010 0xE1, 011 0xF1; codes 1xx match nothing,
	// which T.81 allows (incomplete tables).
	const header = [_]u8{ 0xff, 0xd8, 0xff, 0xdb, 0, 67, 0 } ++
		([_]u8{1} ** 64) ++
		[_]u8{ 0xff, 0xc0, 0, 11, 8, 0, 8, 0, 8, 1, 1, 0x11, 0 } ++
		[_]u8{ 0xff, 0xc4, 0, 20, 0, 1 } ++ ([_]u8{0} ** 15) ++ [_]u8{0} ++
		[_]u8{ 0xff, 0xc4, 0, 23, 0x10, 0, 0, 4 } ++ ([_]u8{0} ** 13) ++
		[_]u8{ 0, 0xf0, 0xe1, 0xf1 } ++
		[_]u8{ 0xff, 0xda, 0, 8, 1, 1, 0, 0, 63, 0 };
	const dc_value = std.mem.indexOf(u8, &header, &.{ 0xff, 0xc4, 0, 20 }).? + 21;
	const e1_value = std.mem.indexOf(u8, &header, &.{ 0xf0, 0xe1 }).? + 1;
	const Case = struct { patch_at: ?usize = null, patch: u8 = 0, entropy: []const u8, code: jpegz.FindingCode, at: usize, detail: []const u8 };
	const allocator = std.testing.allocator;
	for ([_]Case{
		// DC code 1: no entry.
		// Bytes after the bad code keep the reader's lookahead off the EOI.
		.{ .entropy = &.{ 0x80, 0x00, 0x00, 0x00, 0x00 }, .code = .entropy_decode_invalid, .at = 0, .detail = "DC Huffman code matches no table entry" },
		// DC 0, then AC code 100: no entry.
		.{ .entropy = &.{ 0x40, 0x00, 0x00, 0x00, 0x00 }, .code = .entropy_decode_invalid, .at = 0, .detail = "AC Huffman code matches no table entry" },
		// DC 0, four ZRLs: 1 -> 17 -> 33 -> 49 -> 65; the fourth starts in byte 1.
		.{ .entropy = &.{ 0x12, 0x4f }, .code = .entropy_decode_invalid, .at = 1, .detail = "AC zero run past Se=63" },
		// DC 0, four 0xF1 (run 15, size 1): the fourth run reaches k = 64; it
		// starts in byte 1. The trailing 1 bit and padding form a stuffed FF.
		.{ .entropy = &.{ 0x3b, 0xbb, 0xff, 0x00 }, .code = .entropy_decode_invalid, .at = 1, .detail = "AC zero run past Se=63" },
		// The DC code decodes category 12: past 11 at 8 bits.
		.{ .patch_at = dc_value, .patch = 12, .entropy = &.{ 0x0f }, .code = .dct_coefficient_overflow, .at = 0,
			.detail = "DC difference category 12 exceeds 11 for 8-bit samples (T.81 F.1.2.1)" },
		// AC code 010 decodes 0x1B: category 11, past 10.
		.{ .patch_at = e1_value, .patch = 0x1b, .entropy = &.{ 0x2f }, .code = .dct_coefficient_overflow, .at = 0,
			.detail = "AC coefficient category 11 exceeds 10 for 8-bit samples (T.81 F.1.2.2)" },
	}) |case| {
		var head = header;
		if (case.patch_at) |at| head[at] = case.patch;
		const data = try std.mem.concat(allocator, u8, &.{ &head, case.entropy, &.{ 0xff, 0xd9 } });
		defer allocator.free(data);
		if (case.patch_at) |at| {
			// The table itself is past the bound: the walk reports it (rulings
			// G), and the decoder's 58 stays for tables a walk misses.
			try expectDhtSymbolPastBound(allocator, data, at);
			var sink = jpegz.FindingsSink.init(allocator);
			defer sink.deinit();
			decodeFindings(allocator, data, &sink);
			try expectOneExact(sink.items(), case.code, header.len + case.at, case.detail);
			continue;
		}
		var report = try jpegz.validate(allocator, data);
		defer report.deinit(allocator);
		errdefer for (report.findings.items) |f| std.debug.print("  {t} {?d} {s}\n", .{ f.code, f.offset, f.detail orelse "" });
		var hits: usize = 0;
		for (report.findings.items) |f| {
			try std.testing.expect(f.code != .huffman_table_corrupt);
			if (f.code != case.code) continue;
			hits += 1;
			try std.testing.expect(f.severity == .fail and f.offset_is_exact);
			try std.testing.expectEqual(@as(?u64, header.len + case.at), f.offset);
			try std.testing.expectEqualStrings(case.detail, f.detail.?);
		}
		try std.testing.expectEqual(@as(usize, 1), hits);
	}
}

test "Huffman insufficient_data and restart-boundary whole bytes report file offsets" {
	const allocator = std.testing.allocator;
	{
		// Entropy cut 40 bytes in, then EOI: insufficient_data at the EOI,
		// a file offset (it was once reported relative to the scan).
		const src = @embedFile("fixtures/baseline_16x16_rgb12_420.jpg");
		const sos = findMarker(src, 0xda).?;
		const cut = sos + 2 + (@as(usize, src[sos + 2]) << 8 | src[sos + 3]) + 40;
		const data = try std.mem.concat(allocator, u8, &.{ src[0..cut], &.{ 0xff, 0xd9 } });
		defer allocator.free(data);
		var report = try jpegz.validate(allocator, data);
		defer report.deinit(allocator);
		var seen = false;
		for (report.findings.items) |f| if (f.code == .insufficient_data) {
			seen = true;
			try std.testing.expectEqual(@as(?u64, cut), f.offset);
		};
		try std.testing.expect(seen);
	}
	{
		// Two bytes inserted after a restart interval's valid padding: FAIL 8
		// at the first of them, not 51.
		const src = @embedFile("fixtures/baseline_128x128_dri4.jpg");
		const rst = findMarker(src, 0xd0).?;
		const data = try std.mem.concat(allocator, u8, &.{ src[0..rst], &.{ 0x12, 0x34 }, src[rst..] });
		defer allocator.free(data);
		var report = try jpegz.validate(allocator, data);
		defer report.deinit(allocator);
		var hits: usize = 0;
		for (report.findings.items) |f| {
			try std.testing.expect(f.code != .huffman_table_corrupt);
			if (f.code != .extraneous_bytes_before_marker or f.severity != .fail) continue;
			hits += 1;
			try std.testing.expect(f.offset_is_exact);
			try std.testing.expectEqual(@as(?u64, rst), f.offset);
			try std.testing.expectEqualStrings("2 whole bytes after valid padding before marker 0xD0", f.detail.?);
		}
		try std.testing.expectEqual(@as(usize, 1), hits);
	}
}

test "progressive Huffman data faults are typed: 74, 58, 8, 57 and truncated_stream (validate 2026-11-22)" {
	const allocator = std.testing.allocator;
	const rgb = @embedFile("fixtures/progressive_8x8_rgb.jpg");
	const dri = @embedFile("fixtures/progressive_32x32_gray_dri.jpg");
	// Single-byte mutations of libjpeg-turbo files, found by search.
	const Case = struct { data: []const u8, at: usize, mask: u8, code: jpegz.FindingCode, offset: u64, exact: bool, detail: []const u8 };
	for ([_]Case{
		.{ .data = rgb, .at = 236, .mask = 0x40, .code = .entropy_decode_invalid, .offset = 236, .exact = true, .detail = "DC Huffman code matches no table entry" },
		.{ .data = rgb, .at = 392, .mask = 0x02, .code = .entropy_decode_invalid, .offset = 403, .exact = true, .detail = "AC refinement symbol of size 2, not 1 (T.81 G.1.2.3)" },
		.{ .data = rgb, .at = 260, .mask = 0x10, .code = .entropy_decode_invalid, .offset = 272, .exact = false, .detail = "scan end: EOB run continues past the scan's last block" },
		.{ .data = dri, .at = 179, .mask = 0x20, .code = .entropy_decode_invalid, .offset = 193, .exact = true, .detail = "AC zero run past Se=5" },
		.{ .data = dri, .at = 180, .mask = 0x10, .code = .entropy_decode_invalid, .offset = 203, .exact = false, .detail = "restart interval end: EOB run continues past its last block" },
	}) |case| {
		const data = try allocator.dupe(u8, case.data);
		defer allocator.free(data);
		data[case.at] ^= case.mask;
		var report = try jpegz.validate(allocator, data);
		defer report.deinit(allocator);
		errdefer for (report.findings.items) |f| std.debug.print("  {t} {?d} {s}\n", .{ f.code, f.offset, f.detail orelse "" });
		var hits: usize = 0;
		for (report.findings.items) |f| {
			if (f.code != case.code or !std.mem.eql(u8, f.detail orelse "", case.detail)) continue;
			hits += 1;
			try std.testing.expect(f.severity == .fail and f.offset_is_exact == case.exact);
			try std.testing.expectEqual(@as(?u64, case.offset), f.offset);
		}
		try std.testing.expectEqual(@as(usize, 1), hits);
	}
	{
		// The DHT symbol at 179 becomes 0x0B, size 11, past 10 (rulings G);
		// the decoder still reports its 58 where the code is decoded.
		const data = try allocator.dupe(u8, dri);
		defer allocator.free(data);
		data[179] ^= 0x08;
		try expectDhtSymbolPastBound(allocator, data, 179);
		var sink = jpegz.FindingsSink.init(allocator);
		defer sink.deinit();
		decodeFindings(allocator, data, &sink);
		try expectOneExact(sink.items(), .dct_coefficient_overflow, 193, "AC coefficient category 11 exceeds 10 for 8-bit samples (T.81 F.1.2.2)");
	}
	// Constructed boundary cases on the first scan of the RGB file.
	const sos = findMarker(rgb, 0xda).?;
	const end = segmentEndMarker(rgb, entropyStart(rgb, sos));
	const Built = struct { bytes: []const u8, code: jpegz.FindingCode, offset: usize, detail: []const u8, exact: bool = true };
	const whole = try std.mem.concat(allocator, u8, &.{ rgb[0..end], &.{ 0x12, 0x34 }, rgb[end..] });
	defer allocator.free(whole);
	const final_rst = try std.mem.concat(allocator, u8, &.{ rgb[0..end], &.{ 0xff, 0xd3 }, rgb[end..] });
	defer allocator.free(final_rst);
	const cut = rgb[0..end];
	for ([_]Built{
		.{ .bytes = whole, .code = .extraneous_bytes_before_marker, .offset = end, .detail = "2 whole bytes after valid padding before marker 0xC4" },
		.{ .bytes = final_rst, .code = .restart_marker_unexpected, .offset = end, .detail = "restart marker after the final unit of the scan" },
		// The marker walk already reports the file ending inside the scan.
		.{ .bytes = cut, .code = .truncated_stream, .offset = end, .detail = "SOS entropy data not terminated by a marker", .exact = false },
	}) |case| {
		var report = try jpegz.validate(allocator, case.bytes);
		defer report.deinit(allocator);
		errdefer for (report.findings.items) |f| std.debug.print("  {t} {?d} {s}\n", .{ f.code, f.offset, f.detail orelse "" });
		var hits: usize = 0;
		for (report.findings.items) |f| {
			try std.testing.expect(f.code != .huffman_table_corrupt);
			if (f.code != case.code or !std.mem.eql(u8, f.detail orelse "", case.detail)) continue;
			hits += 1;
			try std.testing.expect(f.severity == .fail and f.offset_is_exact == case.exact);
			try std.testing.expectEqual(@as(?u64, case.offset), f.offset);
		}
		try std.testing.expectEqual(@as(usize, 1), hits);
	}
	{
		// The decoder reports the same end itself to a decode-API sink.
		var sink = jpegz.FindingsSink.init(allocator);
		defer sink.deinit();
		try std.testing.expectError(error.TruncatedStream, jpegz.decodeWithOptions(allocator, cut, .{ .findings_sink = &sink }));
		var hits: usize = 0;
		for (sink.items()) |f| if (f.code == .truncated_stream) {
			hits += 1;
			try std.testing.expect(f.offset_is_exact and f.offset.? == end);
			try std.testing.expectEqualStrings("file ends after a progressive scan, with no marker", f.detail.?);
		};
		try std.testing.expectEqual(@as(usize, 1), hits);
	}
}

test "progressive restart findings report file offsets, and whole bytes before an RSTm are FAIL 8" {
	const allocator = std.testing.allocator;
	const dri = @embedFile("fixtures/progressive_32x32_gray_dri.jpg");
	const rst = findMarker(dri, 0xd0).?;
	{
		var data = try allocator.dupe(u8, dri);
		defer allocator.free(data);
		data[rst + 1] = 0xd5;
		var report = try jpegz.validate(allocator, data);
		defer report.deinit(allocator);
		var seen = false;
		for (report.findings.items) |f| if (f.code == .restart_marker_unexpected) {
			seen = true;
			try std.testing.expectEqual(@as(?u64, rst), f.offset);
			break;
		};
		try std.testing.expect(seen);
	}
	{
		const data = try std.mem.concat(allocator, u8, &.{ dri[0..rst], &.{ 0x12, 0x34 }, dri[rst..] });
		defer allocator.free(data);
		var report = try jpegz.validate(allocator, data);
		defer report.deinit(allocator);
		var hits: usize = 0;
		for (report.findings.items) |f| {
			try std.testing.expect(f.code != .huffman_table_corrupt);
			if (f.code != .extraneous_bytes_before_marker or f.severity != .fail) continue;
			hits += 1;
			try std.testing.expect(f.offset_is_exact);
			try std.testing.expectEqual(@as(?u64, rst), f.offset);
		}
		try std.testing.expectEqual(@as(usize, 1), hits);
	}
	{
		// Entropy cut mid-scan, then EOI: insufficient_data at the EOI's file offset.
		const sos = findMarker(dri, 0xda).?;
		const cut = entropyStart(dri, sos) + 6;
		const data = try std.mem.concat(allocator, u8, &.{ dri[0..cut], &.{ 0xff, 0xd9 } });
		defer allocator.free(data);
		var sink = jpegz.FindingsSink.init(allocator);
		defer sink.deinit();
		if (jpegz.decodeWithOptions(allocator, data, .{ .lenient = true, .findings_sink = &sink })) |image| {
			var img = image;
			img.deinit(allocator);
		} else |_| {}
		var seen = false;
		for (sink.items()) |f| if (f.code == .insufficient_data) {
			seen = true;
			try std.testing.expectEqual(@as(?u64, cut), f.offset);
		};
		try std.testing.expect(seen);
	}
}

