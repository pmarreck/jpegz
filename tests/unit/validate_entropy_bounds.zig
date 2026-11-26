//! validate tests, part 2 (split from validate.zig to keep files small).

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

test "entropy padding is classified by its bits for every pad width" {
	// T.81 F.1.2.3 over the whole domain of 1..7 pad bits: all 1s is legal,
	// all 0s is the known encoder defect (63, WARN, bit count in the detail)
	// and any mix is damage (62, FAIL), each at the exact pad byte. One 8x8
	// gray block; DC code 0, AC EOB 000, ZRL 001, E1 010 and F1 011 (run 14
	// or 15, then amplitude 1). A block whose last coefficient is 63 has no EOB.
	// Bit strings are hand-packed, listed with their pad bits cleared.
	const header = [_]u8{ 0xff, 0xd8, 0xff, 0xdb, 0, 67, 0 } ++
		([_]u8{1} ** 64) ++
		[_]u8{ 0xff, 0xc0, 0, 11, 8, 0, 8, 0, 8, 1, 1, 0x11, 0 } ++
		[_]u8{ 0xff, 0xc4, 0, 20, 0, 1 } ++ ([_]u8{0} ** 15) ++ [_]u8{0} ++
		[_]u8{ 0xff, 0xc4, 0, 23, 0x10, 0, 0, 4 } ++ ([_]u8{0} ** 13) ++
		[_]u8{ 0, 0xf0, 0xe1, 0xf1 } ++
		[_]u8{ 0xff, 0xda, 0, 8, 1, 1, 0, 0, 63, 0 };
	const cases = [_]struct { entropy: []const u8, pad_bits: u3 }{
		.{ .entropy = &.{0x10}, .pad_bits = 1 }, // ZRL
		.{ .entropy = &.{ 0x12, 0xa0 }, .pad_bits = 2 }, // 2 ZRL, E1
		.{ .entropy = &.{ 0x12, 0x40 }, .pad_bits = 3 }, // 3 ZRL
		.{ .entropy = &.{0x00}, .pad_bits = 4 }, // EOB only
		.{ .entropy = &.{ 0x15, 0x00 }, .pad_bits = 5 }, // ZRL, E1
		.{ .entropy = &.{ 0x12, 0x00 }, .pad_bits = 6 }, // 2 ZRL
		.{ .entropy = &.{ 0x2b, 0xbb, 0x80 }, .pad_bits = 7 }, // E1, 3 F1: ends at 63
	};
	const allocator = std.testing.allocator;
	for (cases) |case| {
		const pad_offset = header.len + case.entropy.len - 1;
		const mask: u8 = @intCast((@as(u16, 1) << case.pad_bits) - 1);
		const variants = [_]struct { pad: u8, code: ?jpegz.FindingCode }{
			.{ .pad = mask, .code = null },
			.{ .pad = 0, .code = .entropy_padding_zero_bits },
			.{ .pad = 1, .code = if (case.pad_bits > 1) .entropy_padding_not_ones else null },
		};
		for (variants) |variant| {
			// B.1.1.5: an entropy byte that becomes 0xFF is followed by a stuffed
			// 0x00. Without it the byte reads as marker fill and the scan really
			// is short, which the decoder reports as insufficient data.
			const last = case.entropy[case.entropy.len - 1] | variant.pad;
			const stuffing: []const u8 = if (last == 0xff) &.{0x00} else &.{};
			const data = try std.mem.concat(allocator, u8, &.{ &header, case.entropy[0 .. case.entropy.len - 1], &.{last}, stuffing, &.{ 0xff, 0xd9 } });
			defer allocator.free(data);
			var report = try jpegz.validate(allocator, data);
			defer report.deinit(allocator);
			const code = variant.code orelse {
				for (report.findings.items) |finding| try std.testing.expect(finding.severity != .fail and
					finding.code != .entropy_padding_zero_bits and finding.code != .entropy_padding_not_ones);
				continue;
			};
			const severity: jpegz.Severity = if (code == .entropy_padding_zero_bits) .known_defect else .fail;
			try expectOnlyTyped(report, severity, code, pad_offset);
			try std.testing.expectEqual(severity == .known_defect, report.isValid());
			if (severity == .fail) continue;
			var count_buf: [16]u8 = undefined;
			const count = try std.fmt.bufPrint(&count_buf, "{d} pad bits", .{case.pad_bits});
			for (report.findings.items) |finding| {
				if (finding.code == code) try std.testing.expect(std.mem.startsWith(u8, finding.detail.?, count));
			}
			var decoded = try jpegz.decode(allocator, data);
			defer decoded.deinit(allocator);
			var oracle = jpegz.internal.wrapperDecode(allocator, data) catch |err| switch (err) {
				error.NotImplemented => continue,
				else => return err,
			};
			defer oracle.deinit(allocator);
			try std.testing.expectEqualSlices(u8, oracle.pixels, decoded.pixels);
		}
	}
}

test "sequential entropy bounds classify legal endings and malformed runs" {
	// T.81 F.1.2.2 / F.2.2.2: ZRL represents exactly 16 AC zeros;
	// the block has 63 AC positions. Independent specification:
	// https://www.w3.org/Graphics/JPEG/itu-t81.pdf
	// One 8x8 grayscale block, unit quantization. DC code 0 means zero;
	// AC codes 000/001/010/011 mean EOB/ZRL/E1/F1 respectively.
	const header = [_]u8{ 0xff, 0xd8, 0xff, 0xdb, 0, 67, 0 } ++
		([_]u8{1} ** 64) ++
		[_]u8{ 0xff, 0xc0, 0, 11, 8, 0, 8, 0, 8, 1, 1, 0x11, 0 } ++
		[_]u8{ 0xff, 0xc4, 0, 20, 0, 1 } ++ ([_]u8{0} ** 15) ++ [_]u8{0} ++
		[_]u8{ 0xff, 0xc4, 0, 23, 0x10, 0, 0, 4 } ++ ([_]u8{0} ** 13) ++
		[_]u8{ 0, 0xf0, 0xe1, 0xf1 } ++
		[_]u8{ 0xff, 0xda, 0, 8, 1, 1, 0, 0, 63, 0 };
	const cases = [_]struct {
		entropy: []const u8,
		verdict: jpegz.StrictVerdict,
		width: u8 = 8,
		restart: ?u8 = null,
		legacy_valid: ?bool = null,
		recoverable_boundary_error: bool = false,
		// Padding faults lenient decoding must report; all are T.81 F.1.2.3 FAILs.
		padding_faults: usize = 1,
		// Typed FAIL the validator must name instead of huffman_table_corrupt,
		// at an absolute file offset. Entropy starts at 141, or 147 with DRI.
		code: ?jpegz.FindingCode = null,
		// All-zero padding is an admitted known defect: its own severity,
		// never WARN or FAIL (validate ruling 2026-11-06).
		severity: jpegz.Severity = .fail,
		// Report-level severity; a FAIL elsewhere must outrank a known defect.
		overall: ?jpegz.Severity = null,
		offset: u64 = 0,
		decode_error: anyerror = error.BackendError,
	}{
		// Explicit bit strings, padded with ones; no test-side entropy encoder.
		.{ .entropy = &.{0x0f}, .verdict = .valid }, // DC, EOB
		.{ .entropy = &.{0x11}, .verdict = .valid }, // DC, ZRL, EOB
		.{ .entropy = &.{ 0x12, 0x47 }, .verdict = .valid }, // 3 ZRL, EOB
		.{ .entropy = &.{ 0x12, 0xa7 }, .verdict = .valid }, // 2 ZRL, E1(+1), ZRL: ends at 64
		.{ .entropy = &.{ 0x12, 0x57 }, .verdict = .valid }, // 3 ZRL, E1(+1): nonzero at 63
		.{ .entropy = &.{ 0x12, 0x4f }, .verdict = .corrupt }, // 4 ZRL: 64 zeros in 63 slots
		.{ .entropy = &.{ 0x12, 0x5f }, .verdict = .corrupt }, // 3 ZRL, F1(+1): nonzero at 64
		.{ .entropy = &.{0x0e}, .verdict = .corrupt, .recoverable_boundary_error = true, .code = .entropy_padding_not_ones, .offset = 141 }, // One zero in the four final padding bits.
		.{ .entropy = &.{ 0x0f, 0x00 }, .verdict = .corrupt }, // Extra whole entropy byte.
		.{ .entropy = &.{ 0x0f, 0xff, 0x00 }, .verdict = .corrupt }, // Stuffed extra payload is not marker fill.
		.{ .entropy = &.{0x00}, .verdict = .known_defect, .legacy_valid = true, .code = .entropy_padding_zero_bits, .severity = .known_defect, .overall = .known_defect, .offset = 141 }, // Four 0 pad bits: a known encoder defect.
		.{ .entropy = &.{ 0x0f, 0xff, 0xff }, .verdict = .valid }, // Legal fill before EOI.
		.{ .entropy = &.{ 0x0f, 0xff, 0xd0 }, .verdict = .corrupt, .code = .restart_marker_unexpected, .offset = 142 }, // No restart after the final MCU.
		.{ .entropy = &.{0x00}, .width = 16, .verdict = .valid }, // Two blocks exactly fill one byte.
		.{ .entropy = &.{ 0x00, 0x0f }, .width = 17, .verdict = .valid }, // Partial edge MCU is still a whole block.
		.{ .entropy = &.{0x0f}, .restart = 2, .verdict = .valid }, // Final short interval needs no RST.
		.{ .entropy = &.{ 0x0f, 0xff, 0xd0 }, .restart = 1, .verdict = .corrupt, .code = .restart_marker_unexpected, .offset = 148 },
		.{ .entropy = &.{0x0f}, .width = 16, .restart = 1, .verdict = .corrupt, .code = .truncated_stream, .offset = 148, .decode_error = error.TruncatedStream }, // EOI where RST0 and a second interval belong.
		.{ .entropy = &.{ 0x0f, 0xff, 0xd0, 0x0f }, .width = 16, .restart = 1, .verdict = .valid },
		.{ .entropy = &.{ 0x0e, 0xff, 0xd0, 0x0f }, .width = 16, .restart = 1, .verdict = .corrupt, .recoverable_boundary_error = true, .code = .entropy_padding_not_ones, .offset = 147 },
		.{ .entropy = &.{ 0x0e, 0xff, 0xd0, 0x0e }, .width = 16, .restart = 1, .verdict = .corrupt, .recoverable_boundary_error = true, .padding_faults = 2, .code = .entropy_padding_not_ones, .offset = 147 }, // Every faulty segment is reported, not only the first.
		.{ .entropy = &.{ 0x00, 0xff, 0xd0, 0x0f }, .width = 16, .restart = 1, .verdict = .known_defect, .legacy_valid = true, .code = .entropy_padding_zero_bits, .severity = .known_defect, .overall = .known_defect, .offset = 147 }, // Zero padding before RST0.
		.{ .entropy = &.{ 0x00, 0xff, 0xd0, 0x00 }, .width = 16, .restart = 1, .verdict = .known_defect, .legacy_valid = true, .code = .entropy_padding_zero_bits, .severity = .known_defect, .overall = .known_defect, .offset = 150 }, // Zero padding in both segments.
		.{ .entropy = &.{ 0x00, 0xff, 0xd0, 0x0e }, .width = 16, .restart = 1, .verdict = .corrupt, .overall = .fail }, // Known-defect padding, then mixed bits: FAIL wins.
		.{ .entropy = &.{ 0x0f, 0x00, 0xff, 0xd0, 0x0f }, .width = 16, .restart = 1, .verdict = .corrupt },
		.{ .entropy = &.{ 0x0f, 0xff, 0x00, 0xff, 0xd0, 0x0f }, .width = 16, .restart = 1, .verdict = .corrupt },
		.{ .entropy = &.{ 0x0f, 0xff, 0xff, 0xd0, 0x0f }, .width = 16, .restart = 1, .verdict = .valid },
		.{ .entropy = &.{0x0f}, .width = 16, .verdict = .corrupt }, // Missing second MCU: recovered, FAIL class.
		.{ .entropy = &.{0x00}, .width = 17, .verdict = .corrupt }, // Missing partial-edge MCU: recovered, FAIL class.
	};
	const allocator = std.testing.allocator;
	for (cases) |case| {
		var case_header = header;
		const sof_start = 7 + 64; // SOI plus the complete DQT segment above.
		case_header[sof_start + 8] = case.width;
		const dri = [_]u8{ 0xff, 0xdd, 0, 4, 0, case.restart orelse 0 };
		const data = try std.mem.concat(allocator, u8, &.{
			case_header[0..2], if (case.restart != null) &dri else &.{},
			case_header[2..], case.entropy, &.{ 0xff, 0xd9 },
		});
		defer allocator.free(data);
		var result = try jpegz.validate(allocator, data);
		defer result.deinit(allocator);
		try std.testing.expectEqual(case.legacy_valid orelse (case.verdict == .valid), result.isValid());
		if (case.overall) |overall| try std.testing.expectEqual(overall, result.overall);
		if (case.code) |code| try expectOnlyTyped(result, case.severity, code, case.offset);
		if (case.recoverable_boundary_error) {
			var sink = jpegz.FindingsSink.init(allocator);
			defer sink.deinit();
			var recovered = try jpegz.decodeWithOptions(allocator, data, .{ .lenient = true, .findings_sink = &sink });
			defer recovered.deinit(allocator);
			var failures: usize = 0;
			var at_offset: usize = 0;
			for (sink.items()) |finding| {
				if (finding.code != .entropy_padding_not_ones or finding.severity != .fail) continue;
				failures += 1;
				if (finding.offset == case.offset) at_offset += 1;
			}
			try std.testing.expectEqual(case.padding_faults, failures);
			try std.testing.expectEqual(@as(usize, 1), at_offset);
			try std.testing.expectEqual(@as(u32, case.width), recovered.width);
			// Pad bits carry no image data, so recovery must match libjpeg-turbo,
			// which ignores them.
			if (jpegz.internal.wrapperDecode(allocator, data)) |oracle_image| {
				var oracle = oracle_image;
				defer oracle.deinit(allocator);
				try std.testing.expectEqualSlices(u8, oracle.pixels, recovered.pixels);
			} else |err| if (err != error.NotImplemented) return err;
		}
		if (case.verdict == .valid or case.verdict == .known_defect) {
			var decoded = try jpegz.decode(allocator, data);
			defer decoded.deinit(allocator);
			var oracle = jpegz.internal.wrapperDecode(allocator, data) catch |err| switch (err) {
				error.NotImplemented => continue, // Optional oracle excluded from this build.
				else => return err,
			};
			defer oracle.deinit(allocator);
			try std.testing.expectEqualSlices(u8, oracle.pixels, decoded.pixels);
		} else {
			// Strict decoding must reject the same malformed set as validation.
			if (jpegz.decode(allocator, data)) |image| {
				var unexpected = image;
				unexpected.deinit(allocator);
				return error.ExpectedDecodeFailure;
			} else |err| try std.testing.expectEqual(case.decode_error, err);
		}
	}
}

test "lossless entropy boundaries classify complete samples and restart intervals" {
	// T.81 H.1/H.2: one-bit DC code 0 gives difference zero. With predictor
	// 1 and precision 8, every sample is 128. Entropy bytes are hand-authored;
	// the external decoder checks the valid set independently.
	const cases = [_]struct {
		entropy: []const u8,
		valid: bool,
		width: u8 = 1,
		height: u8 = 1,
		restart: ?u8 = null,
		recoverable_boundary_error: bool = false,
		decode_error: jpegz.DecodeError = error.BackendError,
		zero_pad_at: []const usize = &.{}, // Entropy byte indexes of all-zero padding.
		mixed_pad_at: []const usize = &.{},
	}{
		.{ .entropy = &.{0x7f}, .valid = true },
		.{ .entropy = &.{0x00}, .width = 8, .valid = true },
		.{ .entropy = &.{ 0x00, 0x7f }, .width = 9, .valid = true },
		.{ .entropy = &.{ 0x7f, 0xff, 0xff }, .valid = true }, // Marker fill.
		.{ .entropy = &.{0x7e}, .valid = false, .mixed_pad_at = &.{0} }, // Mixed padding bits.
		.{ .entropy = &.{ 0x7f, 0xff, 0xd0, 0x7e }, .height = 2, .restart = 1, .valid = false, .mixed_pad_at = &.{3} },
		.{ .entropy = &.{0x00}, .valid = true, .zero_pad_at = &.{0} }, // Seven zero padding bits.
		.{ .entropy = &.{ 0x00, 0xff, 0xd0, 0x7f }, .height = 2, .restart = 1, .valid = true, .zero_pad_at = &.{0} },
		.{ .entropy = &.{ 0x00, 0xff, 0xd0, 0x00 }, .height = 2, .restart = 1, .valid = true, .zero_pad_at = &.{ 0, 3 } },
		.{ .entropy = &.{0x3f}, .valid = false, .mixed_pad_at = &.{0} }, // Extra sample within final byte.
		.{ .entropy = &.{ 0x7f, 0x00 }, .valid = false },
		.{ .entropy = &.{ 0x7f, 0xff, 0x00 }, .valid = false },
		.{ .entropy = &.{ 0x7f, 0xff, 0xd0 }, .valid = false },
		.{ .entropy = &.{0x01}, .width = 8, .valid = false }, // Missing eighth sample.
		.{ .entropy = &.{0x00}, .width = 9, .valid = false }, // Missing ninth sample.
		.{ .entropy = &.{0x7f}, .restart = 2, .valid = true },
		.{ .entropy = &.{0x3f}, .width = 2, .restart = 2, .valid = true },
		.{ .entropy = &.{ 0x3f, 0xff, 0xd0 }, .width = 2, .restart = 2, .valid = false },
		.{ .entropy = &.{ 0x7f, 0xff, 0xd0, 0x7f }, .height = 2, .restart = 1, .valid = true },
		.{ .entropy = &.{ 0x00, 0xff, 0xd0, 0x00 }, .width = 8, .height = 2, .restart = 8, .valid = true },
		.{ .entropy = &.{ 0x7f, 0xff, 0xff, 0xd0, 0x7f }, .height = 2, .restart = 1, .valid = true },
		.{ .entropy = &.{ 0x7e, 0xff, 0xd0, 0x7f }, .height = 2, .restart = 1, .valid = false, .recoverable_boundary_error = true, .mixed_pad_at = &.{0} },
		.{ .entropy = &.{ 0x7f, 0x00, 0xff, 0xd0, 0x7f }, .height = 2, .restart = 1, .valid = false },
		.{ .entropy = &.{ 0x7f, 0xff, 0x00, 0xff, 0xd0, 0x7f }, .height = 2, .restart = 1, .valid = false },
		// H.1.1 requires whole MCU rows, even if Ri exceeds the image size.
		.{ .entropy = &.{0x3f}, .width = 2, .restart = 4, .valid = true },
		.{ .entropy = &.{0x3f}, .width = 2, .restart = 3, .valid = false, .decode_error = error.InvalidMarker },
		.{ .entropy = &.{ 0x7f, 0xff, 0xd0, 0x7f }, .width = 2, .restart = 1, .valid = false, .decode_error = error.InvalidMarker },
		.{ .entropy = &.{ 0x1f, 0xff, 0xd0, 0x7f }, .width = 2, .height = 2, .restart = 3, .valid = false, .decode_error = error.InvalidMarker },
	};
	const allocator = std.testing.allocator;
	for (cases) |case| {
		const header = [_]u8{ 0xff, 0xd8, 0xff, 0xc3, 0, 11, 8, 0, case.height, 0, case.width, 1, 1, 0x11, 0 } ++
			[_]u8{ 0xff, 0xc4, 0, 20, 0, 1 } ++ ([_]u8{0} ** 15) ++ [_]u8{0};
		const dri = [_]u8{ 0xff, 0xdd, 0, 4, 0, case.restart orelse 0 };
		const data = try std.mem.concat(allocator, u8, &.{
			&header, if (case.restart != null) &dri else &.{},
			&.{ 0xff, 0xda, 0, 8, 1, 1, 0, 1, 0, 0 }, case.entropy, &.{ 0xff, 0xd9 },
		});
		defer allocator.free(data);
		var report = try jpegz.validate(allocator, data);
		defer report.deinit(allocator);
		try std.testing.expectEqual(case.valid, report.isValid());
		if (case.mixed_pad_at.len > 0) {
			const entropy_start = data.len - 2 - case.entropy.len;
			try expectMixedPadFailures(report.findings.items, entropy_start, case.mixed_pad_at);
			var sink = jpegz.FindingsSink.init(allocator);
			defer sink.deinit();
			try std.testing.expectError(error.BackendError, jpegz.decodeWithOptions(allocator, data, .{ .findings_sink = &sink }));
			try expectMixedPadFailures(sink.items(), entropy_start, case.mixed_pad_at);
		}
		if (case.zero_pad_at.len > 0) {
			const entropy_start = data.len - 2 - case.entropy.len;
			try expectZeroPadWarnings(report.findings.items, entropy_start, case.zero_pad_at);
			var sink = jpegz.FindingsSink.init(allocator);
			defer sink.deinit();
			var recovered = try jpegz.internal.losslessDecodeLenientWithFindings(allocator, data, &sink);
			defer recovered.deinit(allocator);
			try expectZeroPadWarnings(sink.items(), entropy_start, case.zero_pad_at);
		}
		if (case.valid) {
			var decoded = try jpegz.decode(allocator, data);
			defer decoded.deinit(allocator);
			try std.testing.expectEqual(@as(usize, case.width) * case.height, decoded.pixels.len);
			try std.testing.expect(std.mem.allEqual(u8, decoded.pixels, 128));
			var oracle = jpegz.internal.wrapperDecode(allocator, data) catch |err| switch (err) {
				error.NotImplemented => continue,
				else => return err,
			};
			defer oracle.deinit(allocator);
			try std.testing.expectEqualSlices(u8, oracle.pixels, decoded.pixels);
		} else {
			if (jpegz.decode(allocator, data)) |image| {
				var unexpected = image;
				unexpected.deinit(allocator);
				return error.ExpectedDecodeFailure;
			} else |err| try std.testing.expectEqual(case.decode_error, err);
		}
		if (case.recoverable_boundary_error) {
			var sink = jpegz.FindingsSink.init(allocator);
			defer sink.deinit();
			var recovered = try jpegz.internal.losslessDecodeLenientWithFindings(allocator, data, &sink);
			defer recovered.deinit(allocator);
			try std.testing.expect(std.mem.allEqual(u8, recovered.pixels, 128));
			try std.testing.expectEqual(@as(usize, 1), sink.items().len);
			try std.testing.expectEqual(jpegz.Severity.fail, sink.items()[0].severity);
			try expectMixedPadFailures(sink.items(), data.len - 2 - case.entropy.len, case.mixed_pad_at);
		}
	}
}

test "validate clean baseline JPEG → valid, baseline_huffman" {
    const allocator = std.testing.allocator;

    var report = try jpegz.validate(allocator, fixture_baseline_2x2_rgb);
    defer report.deinit(allocator);

    // .info is fine — cjpeg-emitted JFIF marker triggers an INFO finding.
    try std.testing.expect(report.isValid());
    try std.testing.expect(report.overall != .fail);
    try std.testing.expectEqual(jpegz.Variant.baseline_huffman, report.variant);
    try std.testing.expectEqual(@as(?u32, 2), report.width);
    try std.testing.expectEqual(@as(?u32, 2), report.height);
    // No fail findings.
    for (report.findings.items) |f| {
        try std.testing.expect(f.severity != .fail);
    }
}

test "validate clean progressive JPEG → valid, progressive_huffman" {
    const allocator = std.testing.allocator;

    var report = try jpegz.validate(allocator, fixture_progressive_8x8);
    defer report.deinit(allocator);

    try std.testing.expect(report.isValid());
    try std.testing.expect(report.overall != .fail);
    try std.testing.expectEqual(jpegz.Variant.progressive_huffman, report.variant);
    try std.testing.expectEqual(@as(?u32, 8), report.width);
    try std.testing.expectEqual(@as(?u32, 8), report.height);
}

test "validate clean lossless JPEG → valid, lossless_huffman" {
    const allocator = std.testing.allocator;

    var report = try jpegz.validate(allocator, fixture_lossless_4x4_gray8);
    defer report.deinit(allocator);

    try std.testing.expect(report.isValid());
    try std.testing.expect(report.overall != .fail);
    try std.testing.expectEqual(jpegz.Variant.lossless_huffman, report.variant);
    try std.testing.expectEqual(@as(?u32, 4), report.width);
    try std.testing.expectEqual(@as(?u32, 4), report.height);
}

test "validate truncated JPEG → FAIL, truncated_stream finding" {
    const allocator = std.testing.allocator;

    // Slice off the trailing 30 bytes (drops EOI + tail of entropy data).
    const truncated = fixture_baseline_2x2_rgb[0 .. fixture_baseline_2x2_rgb.len - 30];

    var report = try jpegz.validate(allocator, truncated);
    defer report.deinit(allocator);

    try std.testing.expectEqual(jpegz.Severity.fail, report.overall);
    // At least one finding must indicate truncation.
    var found_truncation = false;
    for (report.findings.items) |f| {
        if (f.code == .truncated_stream and f.severity == .fail) {
            found_truncation = true;
        }
    }
    try std.testing.expect(found_truncation);
}

test "validate empty input → FAIL, missing_soi finding" {
    const allocator = std.testing.allocator;
    const empty: []const u8 = &[_]u8{};

    var report = try jpegz.validate(allocator, empty);
    defer report.deinit(allocator);

    try std.testing.expectEqual(jpegz.Severity.fail, report.overall);
    try std.testing.expectEqual(jpegz.Variant.unknown, report.variant);

    var found_missing_soi = false;
    for (report.findings.items) |f| {
        if (f.code == .missing_soi and f.severity == .fail) {
            found_missing_soi = true;
        }
    }
    try std.testing.expect(found_missing_soi);
}

test "validate corrupted DHT → FAIL with codec-level finding" {
    const allocator = std.testing.allocator;

    var report = try jpegz.validate(allocator, fixture_baseline_4x4_bogus_dht);
    defer report.deinit(allocator);

    try std.testing.expectEqual(jpegz.Severity.fail, report.overall);
    // Marker walker still classifies the variant from the SOF marker.
    try std.testing.expectEqual(jpegz.Variant.baseline_huffman, report.variant);

    // At least one finding must be the codec-level Huffman fail.
    var found_codec_fail = false;
    for (report.findings.items) |f| {
        if (f.severity == .fail and f.code == .huffman_table_corrupt) {
            found_codec_fail = true;
        }
    }
    try std.testing.expect(found_codec_fail);
}

test "validate surfaces JFIF presence as INFO finding" {
    const allocator = std.testing.allocator;
    var report = try jpegz.validate(allocator, fixture_baseline_2x2_rgb);
    defer report.deinit(allocator);

    try std.testing.expect(report.isValid());
    var found = false;
    for (report.findings.items) |f| {
        if (f.code == .jfif_metadata_present and f.severity == .info) found = true;
    }
    try std.testing.expect(found);
}

