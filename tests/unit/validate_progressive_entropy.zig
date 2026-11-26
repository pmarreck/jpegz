//! validate tests, part 1 (split from validate.zig to keep files small).

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

test "progressive early completion with EOI matches libjpeg" {
	const allocator = std.testing.allocator;
	const early_complete = fixture_progressive_8x8[0..441].* ++ [_]u8{ 0xff, 0xd9 };
	for ([_][]const u8{ fixture_progressive_8x8, &early_complete }) |data| {
		var decoded = try jpegz.decode(allocator, data);
		defer decoded.deinit(allocator);
		var oracle = try jpegz.internal.wrapperDecode(allocator, data);
		defer oracle.deinit(allocator);
		try std.testing.expectEqualSlices(u8, oracle.pixels, decoded.pixels);
	}
}

test "progressive DC first-pass categories obey sample precision" {
	const allocator = std.testing.allocator;
	for ([_]u8{ 8, 12 }) |precision| {
		for (0..17) |size| {
			// Code0 followed by amplitude 0 then size-1 ones gives -2^(size-1).
			// The remaining bits are all-one padding; FF entropy bytes are stuffed.
			const payload: []const u8 = if (size == 0) &.{0x7f} else if (size <= 7) &.{0x3f} else if (size <= 15) &.{ 0x3f, 0xff, 0 } else &.{ 0x3f, 0xff, 0, 0xff, 0 };
			const header = [_]u8{ 0xff, 0xd8, 0xff, 0xdb, 0, 67, 0 } ++ ([_]u8{1} ** 64) ++
				[_]u8{ 0xff, 0xc2, 0, 11, precision, 0, 8, 0, 8, 1, 1, 0x11, 0 } ++
				[_]u8{ 0xff, 0xc4, 0, 20, 0, 1 } ++ ([_]u8{0} ** 15) ++ [_]u8{@intCast(size)} ++
				[_]u8{ 0xff, 0xc4, 0, 20, 0x10, 1 } ++ ([_]u8{0} ** 15) ++ [_]u8{0} ++
				[_]u8{ 0xff, 0xda, 0, 8, 1, 1, 0, 0, 0, 0 };
			const data = try std.mem.concat(allocator, u8, &.{ &header, payload, &.{ 0xff, 0xda, 0, 8, 1, 1, 0, 1, 63, 0, 0x7f, 0xff, 0xd9 } });
			defer allocator.free(data);
			const valid = size <= precision + 3;
			if (valid) {
				var decoded = jpegz.decode(allocator, data) catch |err| {
					std.debug.print("rejected progressive DC category{d} at precision{d}: {s}\n", .{ size, precision, @errorName(err) });
					return err;
				};
				defer decoded.deinit(allocator);
				var oracle = try jpegz.internal.wrapperDecode(allocator, data);
				defer oracle.deinit(allocator);
				try std.testing.expectEqualSlices(u8, oracle.pixels, decoded.pixels);
			} else {
				try std.testing.expectError(error.BackendError, jpegz.decode(allocator, data));
			}
			var report = try jpegz.validate(allocator, data);
			defer report.deinit(allocator);
			try std.testing.expectEqual(valid, report.isValid());
		}
	}
}

test "progressive DC illegal categories remain errors after marker lookahead" {
	const allocator = std.testing.allocator;
	for ([_]u8{ 8, 12 }) |precision| {
		for ([_]bool{ true, false }) |valid| {
			// Two blocks: DC0 code0, then code10 and positive amplitude1.
			// The second lookup sees the marker with seven entropy bits buffered.
			const size: u8 = if (valid) 1 else precision + 4;
			const data = [_]u8{ 0xff, 0xd8, 0xff, 0xdb, 0, 67, 0 } ++ ([_]u8{1} ** 64) ++
				[_]u8{ 0xff, 0xc2, 0, 11, precision, 0, 8, 0, 16, 1, 1, 0x11, 0 } ++
				[_]u8{ 0xff, 0xc4, 0, 21, 0, 1, 1 } ++ ([_]u8{0} ** 14) ++ [_]u8{ 0, size } ++
				[_]u8{ 0xff, 0xc4, 0, 20, 0x10, 1 } ++ ([_]u8{0} ** 15) ++ [_]u8{0} ++
				[_]u8{ 0xff, 0xda, 0, 8, 1, 1, 0, 0, 0, 0, 0x5f, 0xff, 0xda, 0, 8, 1, 1, 0, 1, 63, 0, 0x3f, 0xff, 0xd9 };
			for ([_]bool{ false, true }) |lenient| {
				if (jpegz.decodeWithOptions(allocator, &data, .{ .lenient = lenient })) |image| {
					var decoded = image;
					defer decoded.deinit(allocator);
					try std.testing.expect(valid);
					var oracle = try jpegz.internal.wrapperDecode(allocator, &data);
					defer oracle.deinit(allocator);
					try std.testing.expectEqualSlices(u8, oracle.pixels, decoded.pixels);
				} else |err| {
					try std.testing.expect(!valid);
					try std.testing.expectEqual(error.BackendError, err);
				}
			}
			var report = try jpegz.validate(allocator, &data);
			defer report.deinit(allocator);
			try std.testing.expectEqual(valid, report.isValid());
		}
	}
}

test "progressive AC first-pass categories obey sample precision" {
	// T.81 Tables F.2/F.7 as used by G.1.2.2: AC sizes0..10(P8),0..14(P12).
	// Codes0/10 mean EOB/size. Each nonzero is +2^(size-1), then EOB.
	// Literal bytes keep the test independent of jpegz's encoder/bit writer.
	const payloads = [_][]const u8{
		&.{0x7f}, &.{0xaf}, &.{0xa7}, &.{0xa3}, &.{0xa1}, &.{0xa0},
		&.{ 0xa0, 0x7f }, &.{ 0xa0, 0x3f }, &.{ 0xa0, 0x1f }, &.{ 0xa0, 0x0f },
		&.{ 0xa0, 0x07 }, &.{ 0xa0, 0x03 }, &.{ 0xa0, 0x01 }, &.{ 0xa0, 0x00 },
		&.{ 0xa0, 0x00, 0x7f }, &.{ 0xa0, 0x00, 0x3f },
	};
	const allocator = std.testing.allocator;
	for ([_]u8{ 8, 12 }) |precision| {
		for (payloads, 0..) |payload, size| {
			const header = [_]u8{ 0xff, 0xd8, 0xff, 0xdb, 0, 67, 0 } ++ ([_]u8{1} ** 64) ++
				[_]u8{ 0xff, 0xc2, 0, 11, precision, 0, 8, 0, 8, 1, 1, 0x11, 0 } ++
				[_]u8{ 0xff, 0xc4, 0, 20, 0, 1 } ++ ([_]u8{0} ** 15) ++ [_]u8{0} ++
				[_]u8{ 0xff, 0xc4, 0, 21, 0x10, 1, 1 } ++ ([_]u8{0} ** 14) ++
				[_]u8{ 0, @intCast(if (size == 0) 1 else size) } ++
				[_]u8{ 0xff, 0xda, 0, 8, 1, 1, 0, 0, 0, 0, 0x7f, 0xff, 0xda, 0, 8, 1, 1, 0, 1, 63, 0 };
			const data = try std.mem.concat(allocator, u8, &.{ &header, payload, &.{ 0xff, 0xd9 } });
			defer allocator.free(data);
			const valid = size <= precision + 2;
			if (jpegz.decode(allocator, data)) |image| {
				var decoded = image;
				defer decoded.deinit(allocator);
				if (!valid) {
					std.debug.print("accepted progressive AC category{d} at precision{d}\n", .{ size, precision });
					return error.ExpectedDecodeFailure;
				}
				var oracle = try jpegz.internal.wrapperDecode(allocator, data);
				defer oracle.deinit(allocator);
				try std.testing.expectEqualSlices(u8, oracle.pixels, decoded.pixels);
			} else |err| {
				try std.testing.expect(!valid);
				try std.testing.expectEqual(error.BackendError, err);
			}
			var report = try jpegz.validate(allocator, data);
			defer report.deinit(allocator);
			try std.testing.expectEqual(valid, report.isValid());
		}
	}
}

test "progressive refinement rejects illegal decoded sizes even after marker lookahead" {
	// T.81 G.1.2.3: size1 introduces a coefficient; sizes2..15 are illegal.
	// Sweep the complete size domain before and after lookahead sees a marker.
	const allocator = std.testing.allocator;
	const eob = [_]u8{ 0xff, 0xc4, 0, 20, 0x10, 1 } ++ ([_]u8{0} ** 15) ++ [_]u8{0};
	for ([_]u8{ 8, 16 }) |width| {
		for (0..16) |size| {
			const header = [_]u8{ 0xff, 0xd8, 0xff, 0xdb, 0, 67, 0 } ++ ([_]u8{16} ** 64) ++
				[_]u8{ 0xff, 0xc2, 0, 11, 8, 0, 8, 0, width, 1, 1, 0x11, 0 } ++
				[_]u8{ 0xff, 0xc4, 0, 20, 0, 1 } ++ ([_]u8{0} ** 15) ++ [_]u8{0};
			const zeros: u8 = if (width == 8) 0x7f else 0x3f;
			// Codes0/10 mean EOB/selected size. Leave10=01 unused for size0.
			const table = [_]u8{ 0xff, 0xc4, 0, 21, 0x10, 1, 1 } ++ ([_]u8{0} ** 14) ++
				[_]u8{ 0, @intCast(if (size == 0) 1 else size) };
			const payload: u8 = if (size == 0) zeros else if (width == 8) 0xbf else 0x5f;
			const data = try std.mem.concat(allocator, u8, &.{
				&header, &eob, &.{ 0xff, 0xda, 0, 8, 1, 1, 0, 0, 0, 0, zeros },
				&.{ 0xff, 0xda, 0, 8, 1, 1, 0, 1, 63, 1, zeros },
				&table, &.{ 0xff, 0xda, 0, 8, 1, 1, 0, 1, 1, 0x10, payload },
				&eob, &.{ 0xff, 0xda, 0, 8, 1, 1, 0, 2, 63, 0x10, zeros, 0xff, 0xd9 },
			});
			defer allocator.free(data);
			const valid = size <= 1;
			if (valid) {
				var decoded = try jpegz.decode(allocator, data);
				defer decoded.deinit(allocator);
				var oracle = try jpegz.internal.wrapperDecode(allocator, data);
				defer oracle.deinit(allocator);
				try std.testing.expectEqual(size == 1, !std.mem.allEqual(u8, oracle.pixels, 128));
				try std.testing.expectEqualSlices(u8, oracle.pixels, decoded.pixels);
			} else {
				try std.testing.expectError(error.BackendError, jpegz.decode(allocator, data));
			}
			var report = try jpegz.validate(allocator, data);
			defer report.deinit(allocator);
			try std.testing.expectEqual(valid, report.isValid());
			if (!valid) {
				if (jpegz.decodeWithOptions(allocator, data, .{ .lenient = true })) |image| {
					var accepted = image;
					accepted.deinit(allocator);
					return error.ExpectedDecodeFailure;
				} else |err| try std.testing.expectEqual(error.BackendError, err);
			}
		}
	}
}

test "progressive AC first-pass runs cannot exceed the selected band" {
	// T.81 G.1.2.2: a ZRL represents 16 zeros within this scan's band.
	// One grayscale block, DC0 in its own scan. AC Huffman codes
	// 000/001/010/011 represent EOB/ZRL/E1/F1. Literal payloads below
	// are independent of the decoder; valid pixels also use libjpeg's oracle.
	const header = [_]u8{ 0xff, 0xd8, 0xff, 0xdb, 0, 67, 0 } ++ ([_]u8{16} ** 64) ++
		[_]u8{ 0xff, 0xc2, 0, 11, 8, 0, 8, 0, 8, 1, 1, 0x11, 0 } ++
		[_]u8{ 0xff, 0xc4, 0, 20, 0, 1 } ++ ([_]u8{0} ** 15) ++ [_]u8{0} ++
		[_]u8{ 0xff, 0xc4, 0, 23, 0x10, 0, 0, 4 } ++ ([_]u8{0} ** 13) ++ [_]u8{ 0, 0xf0, 0xe1, 0xf1 } ++
		[_]u8{ 0xff, 0xda, 0, 8, 1, 1, 0, 0, 0, 0, 0x7f };
	const cases = [_]struct { ac: []const u8, valid: bool, ss: u8 = 1, se: u8 = 63, nonzero: bool = false }{
		.{ .ac = &.{0x1f}, .valid = true },
		.{ .ac = &.{0x23}, .valid = true },
		.{ .ac = &.{ 0x24, 0x8f }, .valid = true },
		.{ .ac = &.{ 0x25, 0x4f }, .valid = true, .nonzero = true },
		.{ .ac = &.{ 0x24, 0xaf }, .valid = true, .nonzero = true },
		.{ .ac = &.{ 0x24, 0x9f }, .valid = false },
		.{ .ac = &.{ 0x24, 0xbf }, .valid = false },
		.{ .ac = &.{0x3f}, .ss = 1, .se = 16, .valid = true },
		.{ .ac = &.{0x3f}, .ss = 1, .se = 15, .valid = false },
		.{ .ac = &.{0x3f}, .ss = 48, .se = 63, .valid = true },
		.{ .ac = &.{0x3f}, .ss = 49, .se = 63, .valid = false },
		.{ .ac = &.{0x5f}, .ss = 1, .se = 15, .valid = true, .nonzero = true },
		.{ .ac = &.{0x5f}, .ss = 1, .se = 14, .valid = false },
		.{ .ac = &.{0x7f}, .ss = 1, .se = 16, .valid = true, .nonzero = true },
		.{ .ac = &.{0x7f}, .ss = 1, .se = 15, .valid = false },
	};
	const allocator = std.testing.allocator;
	for (cases, 0..) |case, index| {
		// Cover every AC position even when the tested scan is a narrow band.
		const before = [_]u8{ 0xff, 0xda, 0, 8, 1, 1, 0, 1, case.ss - 1, 0, 0x1f };
		const scan = [_]u8{ 0xff, 0xda, 0, 8, 1, 1, 0, case.ss, case.se, 0 };
		const after = [_]u8{ 0xff, 0xda, 0, 8, 1, 1, 0, case.se + 1, 63, 0, 0x1f };
		const data = try std.mem.concat(allocator, u8, &.{
			&header, if (case.ss > 1) &before else &.{}, &scan, case.ac,
			if (case.se < 63) &after else &.{}, &.{ 0xff, 0xd9 },
		});
		defer allocator.free(data);
		if (jpegz.decode(allocator, data)) |image| {
			var decoded = image;
			defer decoded.deinit(allocator);
			if (!case.valid) {
				std.debug.print("progressive AC run case {d}: accepted overflow\n", .{index});
				return error.ExpectedDecodeFailure;
			}
			var oracle = try jpegz.internal.wrapperDecode(allocator, data);
			defer oracle.deinit(allocator);
			try std.testing.expectEqual(case.nonzero, !std.mem.allEqual(u8, oracle.pixels, 128));
			try std.testing.expectEqualSlices(u8, oracle.pixels, decoded.pixels);
		} else |err| {
			try std.testing.expect(!case.valid);
			try std.testing.expectEqual(error.BackendError, err);
		}
		var report = try jpegz.validate(allocator, data);
		defer report.deinit(allocator);
		try std.testing.expectEqual(case.valid, report.isValid());
	}
}

test "progressive boundaries account for EOB runs padding and refinement bits" {
	// T.81 G.1.2 and F.1.2.3, independently reviewed before implementation.
	// Literal entropy bytes, not a test-side encoder. DC code0 => category0.
	// AC eob7: code0000000 => EOB2 + extension; eob6 leaves one pad bit.
	// AC lookahead: code0 => 01, code10000 => 10. Byte60 encodes AC1=+1
	// then EOB2, forcing marker lookahead before the last block decrements EOB.
	const eob7 = [_]u8{ 0xff, 0xc4, 0, 20, 0x10 } ++ ([_]u8{0} ** 6) ++ [_]u8{1} ++ ([_]u8{0} ** 9) ++ [_]u8{0x10};
	const eob6 = [_]u8{ 0xff, 0xc4, 0, 20, 0x10 } ++ ([_]u8{0} ** 5) ++ [_]u8{1} ++ ([_]u8{0} ** 10) ++ [_]u8{0x10};
	const eob5 = [_]u8{ 0xff, 0xc4, 0, 20, 0x10 } ++ ([_]u8{0} ** 4) ++ [_]u8{1} ++ ([_]u8{0} ** 11) ++ [_]u8{0x10};
	const lookahead = [_]u8{ 0xff, 0xc4, 0, 21, 0x10, 1, 0, 0, 0, 1 } ++ ([_]u8{0} ** 11) ++ [_]u8{ 1, 0x10 };
	const cases = [_]struct {
		dc: []const u8 = &.{0x3f},
		ac: []const u8 = &.{0x00},
		width: u8 = 16,
		ri: u8 = 0,
		table: []const u8 = &eob7,
		refine: ?[]const u8 = null,
		recovery_ac: ?[]const u8 = null,
		valid: bool = true,
		insufficient_count: usize = 0,
		recovered_boundary_failure: bool = false,
		// All-zero padding (a known encoder defect): WARN at these entropy
		// byte indexes of the DC or AC scan.
		zero_pad_scan: enum { dc, ac } = .dc,
		zero_pad_at: []const usize = &.{},
		mixed_pad_at: []const usize = &.{},
		mixed_pad_scan: enum { dc, ac, refinement } = .dc,
	}{
		.{}, // Two blocks, byte-aligned EOB2.
		.{ .dc = &.{0x1f}, .ac = &.{0x01}, .width = 17 }, // Three blocks, partial edge.
		.{ .ac = &.{0x60}, .table = &lookahead }, // Marker lookahead with pending EOB.
		.{ .ac = &.{0x01}, .table = &eob6 }, // One all-one padding bit.
		.{ .ac = &.{0x03}, .table = &eob5 }, // Two all-one AC padding bits.
		.{ .ac = &.{0x01}, .table = &eob5, .valid = false, .mixed_pad_scan = .ac, .mixed_pad_at = &.{0} },
		.{ .ac = &.{0x00}, .table = &eob5, .zero_pad_scan = .ac, .zero_pad_at = &.{0} },
		.{ .ac = &.{ 0x00, 0xff, 0xff } }, // Legal marker fill.
		.{ .ri = 2 }, // Exact final interval needs no RST.
		.{ .ri = 3 }, // Short final interval.
		.{ .width = 32, .ri = 2, .dc = &.{ 0x3f, 0xff, 0xd0, 0x3f }, .ac = &.{ 0x00, 0xff, 0xd0, 0x00 } },
		.{ .width = 32, .ri = 2, .dc = &.{ 0x3f, 0xff, 0xd0, 0x3f }, .ac = &.{ 0x01, 0xff, 0xd0, 0x03 }, .table = &eob5, .valid = false, .recovered_boundary_failure = true, .mixed_pad_scan = .ac, .mixed_pad_at = &.{0} },
		.{ .width = 40, .ri = 3, .dc = &.{ 0x1f, 0xff, 0xd0, 0x3f }, .ac = &.{ 0x01, 0xff, 0xd0, 0x00 } },
		.{ .refine = &.{0x00} }, // Zero history requires no correction bits.
		.{ .ac = &.{0x60}, .table = &lookahead, .refine = &.{ 0x00, 0x7f } }, // AC1=+2, correction0.
		.{ .ac = &.{0x60}, .table = &lookahead, .refine = &.{ 0x00, 0x7e }, .valid = false, .mixed_pad_scan = .refinement, .mixed_pad_at = &.{1} },
		.{ .ac = &.{0x60}, .table = &lookahead, .refine = &.{ 0x00, 0xff, 0x00 } }, // AC1=+3, stuffed correction1.
		.{ .dc = &.{0x3e}, .valid = false, .mixed_pad_at = &.{0} }, // Mixed DC padding bits.
		.{ .table = &eob6, .zero_pad_scan = .ac, .zero_pad_at = &.{0} }, // One zero AC padding bit.
		.{ .dc = &.{0x00}, .zero_pad_at = &.{0} }, // Six zero DC padding bits.
		.{ .width = 32, .ri = 2, .dc = &.{ 0x00, 0xff, 0xd0, 0x00 }, .ac = &.{ 0x00, 0xff, 0xd0, 0x00 }, .zero_pad_at = &.{ 0, 3 } }, // Zero padding at RST and EOI.
		.{ .dc = &.{0x3d}, .valid = false, .mixed_pad_at = &.{0} },
		.{ .width = 32, .ri = 2, .dc = &.{ 0x3f, 0xff, 0xd0, 0x3d }, .ac = &.{ 0x00, 0xff, 0xd0, 0x00 }, .valid = false, .mixed_pad_at = &.{3} },
		.{ .ac = &.{ 0x00, 0x00 }, .valid = false }, // Surplus entropy byte.
		.{ .ac = &.{ 0x00, 0xff, 0x00 }, .valid = false }, // Surplus stuffed byte.
		.{ .dc = &.{0x7f}, .width = 8, .valid = false }, // EOB2 exceeds one block.
		.{ .ac = &.{0x01}, .valid = false }, // EOB3 exceeds two blocks.
		.{ .ac = &.{ 0x00, 0xff, 0xd0 }, .valid = false }, // Final RST without DRI.
		.{ .ri = 2, .ac = &.{ 0x00, 0xff, 0xd0 }, .valid = false },
		.{ .dc = &.{0x7f}, .valid = false, .insufficient_count = 1 }, // Missing second DC block.
		.{ .dc = &.{0x00}, .width = 65, .ac = &.{ 0x01, 0x01, 0x01 }, .valid = false, .insufficient_count = 1 }, // Byte-aligned missing ninth DC block.
		.{ .dc = &.{0x1f}, .width = 17, .valid = false, .insufficient_count = 1 }, // EOB2 undersupplies three blocks.
		.{ .ac = &.{0x60}, .table = &lookahead, .refine = &.{0x00}, .valid = false, .insufficient_count = 1 }, // Missing correction for a prior nonzero.
		.{ .width = 32, .ri = 2, .dc = &.{ 0x3e, 0xff, 0xd0, 0x3f }, .ac = &.{ 0x00, 0xff, 0xd0, 0x00 }, .valid = false, .recovered_boundary_failure = true, .mixed_pad_at = &.{0} },
		.{ .width = 32, .ri = 2, .dc = &.{ 0x3f, 0xff, 0xd0, 0x3f }, .ac = &.{ 0x01, 0xff, 0xd0, 0x00 }, .valid = false, .recovered_boundary_failure = true }, // EOB crosses restart.
		.{ .width = 40, .ri = 3, .dc = &.{ 0x1f, 0xff, 0xd0, 0x3f }, .ac = &.{ 0x00, 0xff, 0xd0, 0x00 }, .valid = false, .insufficient_count = 1 },
		.{ .width = 64, .ri = 3, .dc = &.{ 0x3f, 0xff, 0xd0, 0x3f, 0xff, 0xd1, 0x3f }, .ac = &.{ 0x01, 0xff, 0xd0, 0x01, 0xff, 0xd1, 0x00 }, .valid = false, .insufficient_count = 2 },
		.{ .width = 32, .ri = 2, .dc = &.{ 0x3f, 0xff, 0xd0, 0x3f }, .ac = &.{ 0xff, 0xd0, 0x60 }, .table = &lookahead, .valid = false, .insufficient_count = 1, .recovery_ac = &.{ 0x83, 0xff, 0xd0, 0x60 } }, // Recovery resumes before the nonzero second interval.
	};
	const allocator = std.testing.allocator;
	for (cases, 0..) |case, case_index| {
		const header = [_]u8{ 0xff, 0xd8, 0xff, 0xdb, 0, 67, 0 } ++ ([_]u8{16} ** 64) ++
			[_]u8{ 0xff, 0xc2, 0, 11, 8, 0, 8, 0, case.width, 1, 1, 0x11, 0 } ++
			[_]u8{ 0xff, 0xc4, 0, 20, 0, 1 } ++ ([_]u8{0} ** 15) ++ [_]u8{0};
		const dri = [_]u8{ 0xff, 0xdd, 0, 4, 0, case.ri };
		const ac_sos = [_]u8{ 0xff, 0xda, 0, 8, 1, 1, 0, 1, 63, if (case.refine != null) 1 else 0 };
		const refinement_header = eob7 ++ [_]u8{ 0xff, 0xda, 0, 8, 1, 1, 0, 1, 63, 0x10 };
		const data = try std.mem.concat(allocator, u8, &.{
			&header, &dri, case.table, &.{ 0xff, 0xda, 0, 8, 1, 1, 0, 0, 0, 0 }, case.dc,
			&ac_sos, case.ac, if (case.refine != null) &refinement_header else &.{}, case.refine orelse &.{}, &.{ 0xff, 0xd9 },
		});
		defer allocator.free(data);
		if (jpegz.decode(allocator, data)) |image| {
			var decoded = image;
			defer decoded.deinit(allocator);
			if (!case.valid) {
				std.debug.print("progressive boundary case {d}: accepted malformed stream\n", .{case_index});
				return error.ExpectedDecodeFailure;
			}
			var oracle = try jpegz.internal.wrapperDecode(allocator, data);
			defer oracle.deinit(allocator);
			try std.testing.expectEqualSlices(u8, oracle.pixels, decoded.pixels);
		} else |err| {
			if (case.valid) {
				std.debug.print("progressive boundary case {d}: rejected valid stream ({s})\n", .{ case_index, @errorName(err) });
				return err;
			}
			try std.testing.expectEqual(error.BackendError, err);
		}
		var report = try jpegz.validate(allocator, data);
		defer report.deinit(allocator);
		// Recovered truncation is FAIL class in the report (validate, 2026-11-05).
		try std.testing.expectEqual(case.valid, report.isValid());
		const dc_start = header.len + dri.len + case.table.len + 10;
		const mixed_start = switch (case.mixed_pad_scan) {
			.dc => dc_start,
			.ac => dc_start + case.dc.len + ac_sos.len,
			.refinement => dc_start + case.dc.len + ac_sos.len + case.ac.len + refinement_header.len,
		};
		if (case.mixed_pad_at.len > 0) {
			try expectMixedPadFailures(report.findings.items, mixed_start, case.mixed_pad_at);
			var sink = jpegz.FindingsSink.init(allocator);
			defer sink.deinit();
			try std.testing.expectError(error.BackendError, jpegz.decodeWithOptions(allocator, data, .{ .findings_sink = &sink }));
			try expectMixedPadFailures(sink.items(), mixed_start, case.mixed_pad_at);
		}
		if (case.zero_pad_at.len > 0) {
			const scan_start = if (case.zero_pad_scan == .dc) dc_start else dc_start + case.dc.len + ac_sos.len;
			try expectZeroPadWarnings(report.findings.items, scan_start, case.zero_pad_at);
		}
		if (case.insufficient_count > 0 or case.recovered_boundary_failure) {
			var sink = jpegz.FindingsSink.init(allocator);
			defer sink.deinit();
			var recovered = try jpegz.decodeWithOptions(allocator, data, .{ .lenient = true, .findings_sink = &sink });
			defer recovered.deinit(allocator);
			var insufficient: usize = 0;
			var boundary_failures: usize = 0;
			for (sink.items()) |finding| {
				if (finding.code == .insufficient_data and finding.severity == .warn) insufficient += 1;
				// An EOB run crossing a restart is 74 (validate, 2026-11-22).
				if (finding.severity == .fail and finding.code == (if (case.mixed_pad_at.len > 0) jpegz.FindingCode.entropy_padding_not_ones else .entropy_decode_invalid)) boundary_failures += 1;
			}
			try std.testing.expectEqual(case.insufficient_count, insufficient);
			try std.testing.expectEqual(@as(usize, if (case.recovered_boundary_failure) 1 else 0), boundary_failures);
			if (case.mixed_pad_at.len > 0) try expectMixedPadFailures(sink.items(), mixed_start, case.mixed_pad_at);
			if (case.recovery_ac) |ac| {
				const ac_start = header.len + dri.len + case.table.len + 10 + case.dc.len + ac_sos.len;
				const complete = try std.mem.concat(allocator, u8, &.{ data[0..ac_start], ac, data[ac_start + case.ac.len ..] });
				defer allocator.free(complete);
				var oracle = try jpegz.internal.wrapperDecode(allocator, complete);
				defer oracle.deinit(allocator);
				try std.testing.expect(!std.mem.allEqual(u8, oracle.pixels, 128));
				try std.testing.expectEqualSlices(u8, oracle.pixels, recovered.pixels);
			} else if (case.refine == null) {
				try std.testing.expect(std.mem.allEqual(u8, recovered.pixels, 128));
			}
		}
	}
}

test "zero entropy padding warns and decodes to libjpeg-turbo pixels" {
	// Synthetic reproduction of zero padding also observed in encoder output:
	// this fixture is ImageMagick output with its final entropy byte edited.
	// Pad bits before EOI are 0
	// (T.81 F.1.2.3). Pad bits carry no image data, so strict decoding must
	// accept the file and match libjpeg-turbo, which ignores them.
	const data = @embedFile("fixtures/zero_pad_16x16_420.jpg");
	const allocator = std.testing.allocator;
	var result = try jpegz.validate(allocator, data);
	defer result.deinit(allocator);
	try std.testing.expect(result.isValid());
	try expectOnlyTyped(result, .known_defect, .entropy_padding_zero_bits, 293);
	var image = try jpegz.decode(allocator, data);
	defer image.deinit(allocator);
	var oracle = jpegz.internal.wrapperDecode(allocator, data) catch |err| switch (err) {
		error.NotImplemented => return error.SkipZigTest,
		else => return err,
	};
	defer oracle.deinit(allocator);
	try std.testing.expectEqualSlices(u8, oracle.pixels, image.pixels);
}

