//! M1.5 — `jpegz.validate` tests. Walks the bitstream, accumulates
//! Findings, returns a structured ValidationReport. Never fails-fast
//! on structural errors (per the design doc — validate-mode wants the
//! complete picture, not the first failure).

const std = @import("std");
const jpegz = @import("jpegz");

const fixture_baseline_2x2_rgb = @embedFile("fixtures/baseline_2x2_rgb.jpg");
const fixture_progressive_8x8 = @embedFile("fixtures/progressive_8x8_rgb.jpg");
const fixture_lossless_4x4_gray8 = @embedFile("fixtures/lossless_4x4_gray8.jpg");
const fixture_arith_8x8_gray = @embedFile("fixtures/arith_baseline_8x8_gray.jpg");

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
	}{
		.{}, // Two blocks, byte-aligned EOB2.
		.{ .dc = &.{0x1f}, .ac = &.{0x01}, .width = 17 }, // Three blocks, partial edge.
		.{ .ac = &.{0x60}, .table = &lookahead }, // Marker lookahead with pending EOB.
		.{ .ac = &.{0x01}, .table = &eob6 }, // One all-one padding bit.
		.{ .ac = &.{ 0x00, 0xff, 0xff } }, // Legal marker fill.
		.{ .ri = 2 }, // Exact final interval needs no RST.
		.{ .ri = 3 }, // Short final interval.
		.{ .width = 32, .ri = 2, .dc = &.{ 0x3f, 0xff, 0xd0, 0x3f }, .ac = &.{ 0x00, 0xff, 0xd0, 0x00 } },
		.{ .width = 40, .ri = 3, .dc = &.{ 0x1f, 0xff, 0xd0, 0x3f }, .ac = &.{ 0x01, 0xff, 0xd0, 0x00 } },
		.{ .refine = &.{0x00} }, // Zero history requires no correction bits.
		.{ .ac = &.{0x60}, .table = &lookahead, .refine = &.{ 0x00, 0x7f } }, // AC1=+2, correction0.
		.{ .ac = &.{0x60}, .table = &lookahead, .refine = &.{ 0x00, 0xff, 0x00 } }, // AC1=+3, stuffed correction1.
		.{ .dc = &.{0x3e}, .valid = false }, // Zero DC padding bit.
		.{ .table = &eob6, .valid = false }, // Zero AC padding bit.
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
		.{ .width = 32, .ri = 2, .dc = &.{ 0x3e, 0xff, 0xd0, 0x3f }, .ac = &.{ 0x00, 0xff, 0xd0, 0x00 }, .valid = false, .recovered_boundary_failure = true },
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
		try std.testing.expectEqual(case.valid or case.insufficient_count > 0, report.isValid());
		if (case.insufficient_count > 0 or case.recovered_boundary_failure) {
			var sink = jpegz.FindingsSink.init(allocator);
			defer sink.deinit();
			var recovered = try jpegz.decodeWithOptions(allocator, data, .{ .lenient = true, .findings_sink = &sink });
			defer recovered.deinit(allocator);
			var insufficient: usize = 0;
			var boundary_failures: usize = 0;
			for (sink.items()) |finding| {
				if (finding.code == .insufficient_data and finding.severity == .warn) insufficient += 1;
				if (finding.code == .huffman_table_corrupt and finding.severity == .fail) boundary_failures += 1;
			}
			try std.testing.expectEqual(case.insufficient_count, insufficient);
			try std.testing.expectEqual(@as(usize, if (case.recovered_boundary_failure) 1 else 0), boundary_failures);
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
	}{
		// Explicit bit strings, padded with ones; no test-side entropy encoder.
		.{ .entropy = &.{0x0f}, .verdict = .valid }, // DC, EOB
		.{ .entropy = &.{0x11}, .verdict = .valid }, // DC, ZRL, EOB
		.{ .entropy = &.{ 0x12, 0x47 }, .verdict = .valid }, // 3 ZRL, EOB
		.{ .entropy = &.{ 0x12, 0xa7 }, .verdict = .valid }, // 2 ZRL, E1(+1), ZRL: ends at 64
		.{ .entropy = &.{ 0x12, 0x57 }, .verdict = .valid }, // 3 ZRL, E1(+1): nonzero at 63
		.{ .entropy = &.{ 0x12, 0x4f }, .verdict = .corrupt }, // 4 ZRL: 64 zeros in 63 slots
		.{ .entropy = &.{ 0x12, 0x5f }, .verdict = .corrupt }, // 3 ZRL, F1(+1): nonzero at 64
		.{ .entropy = &.{0x0e}, .verdict = .corrupt }, // One zero in the four final padding bits.
		.{ .entropy = &.{ 0x0f, 0x00 }, .verdict = .corrupt }, // Extra whole entropy byte.
		.{ .entropy = &.{ 0x0f, 0xff, 0x00 }, .verdict = .corrupt }, // Stuffed extra payload is not marker fill.
		.{ .entropy = &.{0x00}, .verdict = .corrupt }, // Two blocks where geometry requires one.
		.{ .entropy = &.{ 0x0f, 0xff, 0xff }, .verdict = .valid }, // Legal fill before EOI.
		.{ .entropy = &.{ 0x0f, 0xff, 0xd0 }, .verdict = .corrupt }, // No restart after the final MCU.
		.{ .entropy = &.{0x00}, .width = 16, .verdict = .valid }, // Two blocks exactly fill one byte.
		.{ .entropy = &.{ 0x00, 0x0f }, .width = 17, .verdict = .valid }, // Partial edge MCU is still a whole block.
		.{ .entropy = &.{0x0f}, .restart = 2, .verdict = .valid }, // Final short interval needs no RST.
		.{ .entropy = &.{ 0x0f, 0xff, 0xd0 }, .restart = 1, .verdict = .corrupt },
		.{ .entropy = &.{ 0x0f, 0xff, 0xd0, 0x0f }, .width = 16, .restart = 1, .verdict = .valid },
		.{ .entropy = &.{ 0x0e, 0xff, 0xd0, 0x0f }, .width = 16, .restart = 1, .verdict = .corrupt, .recoverable_boundary_error = true },
		.{ .entropy = &.{ 0x0f, 0x00, 0xff, 0xd0, 0x0f }, .width = 16, .restart = 1, .verdict = .corrupt },
		.{ .entropy = &.{ 0x0f, 0xff, 0x00, 0xff, 0xd0, 0x0f }, .width = 16, .restart = 1, .verdict = .corrupt },
		.{ .entropy = &.{ 0x0f, 0xff, 0xff, 0xd0, 0x0f }, .width = 16, .restart = 1, .verdict = .valid },
		.{ .entropy = &.{0x0f}, .width = 16, .verdict = .corrupt, .legacy_valid = true }, // Missing second MCU.
		.{ .entropy = &.{0x00}, .width = 17, .verdict = .corrupt, .legacy_valid = true }, // Missing partial-edge MCU.
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
		if (case.recoverable_boundary_error) {
			var sink = jpegz.FindingsSink.init(allocator);
			defer sink.deinit();
			var recovered = try jpegz.decodeWithOptions(allocator, data, .{ .lenient = true, .findings_sink = &sink });
			defer recovered.deinit(allocator);
			var failures: usize = 0;
			for (sink.items()) |finding| {
				if (finding.code == .huffman_table_corrupt and finding.severity == .fail) failures += 1;
			}
			try std.testing.expectEqual(@as(usize, 1), failures);
			try std.testing.expectEqual(@as(u32, case.width), recovered.width);
		}
		if (case.verdict == .valid) {
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
			} else |err| try std.testing.expectEqual(error.BackendError, err);
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
	}{
		.{ .entropy = &.{0x7f}, .valid = true },
		.{ .entropy = &.{0x00}, .width = 8, .valid = true },
		.{ .entropy = &.{ 0x00, 0x7f }, .width = 9, .valid = true },
		.{ .entropy = &.{ 0x7f, 0xff, 0xff }, .valid = true }, // Marker fill.
		.{ .entropy = &.{0x7e}, .valid = false }, // Zero padding bit.
		.{ .entropy = &.{0x3f}, .valid = false }, // Extra sample within final byte.
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
		.{ .entropy = &.{ 0x7e, 0xff, 0xd0, 0x7f }, .height = 2, .restart = 1, .valid = false, .recoverable_boundary_error = true },
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
			try std.testing.expectEqual(jpegz.FindingCode.huffman_table_corrupt, sink.items()[0].code);
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

/// 4×4 baseline RGB JPEG whose DHT (Huffman table definition) was
/// corrupted by setting all 16 code-length counts to 0xFF — an
/// impossible declaration that fails libjpeg's Huffman validation
/// with "Bogus Huffman table definition". The structural marker walker
/// passes (DHT length and bracket are intact); only codec-level
/// integrity catches it.
const fixture_baseline_4x4_bogus_dht = @embedFile("fixtures/baseline_4x4_bogus_dht.jpg");

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

// ── M1.5c (per validate handoff 2026-05-06) — APPn presence + trailing data ──

const fixture_baseline_4x4_with_exif     = @embedFile("fixtures/baseline_4x4_with_exif.jpg");
const fixture_baseline_4x4_with_trailing = @embedFile("fixtures/baseline_4x4_with_trailing.jpg");

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

test "validate surfaces EXIF presence (APP1 'Exif\\0\\0') as INFO" {
    const allocator = std.testing.allocator;
    var report = try jpegz.validate(allocator, fixture_baseline_4x4_with_exif);
    defer report.deinit(allocator);

    try std.testing.expect(report.isValid());
    var found_jfif = false;
    var found_exif = false;
    for (report.findings.items) |f| {
        if (f.code == .jfif_metadata_present) found_jfif = true;
        if (f.code == .exif_metadata_present) found_exif = true;
    }
    try std.testing.expect(found_jfif);
    try std.testing.expect(found_exif);
}

test "validate surfaces trailing-data-after-EOI as INFO" {
    const allocator = std.testing.allocator;
    var report = try jpegz.validate(allocator, fixture_baseline_4x4_with_trailing);
    defer report.deinit(allocator);

    // Trailing data is INFO (the file is decodable; this is just a
    // notable observation), so overall stays at .info or .pass-derived.
    try std.testing.expect(report.isValid());
    var found = false;
    var offset_seen: ?u64 = null;
    for (report.findings.items) |f| {
        if (f.code == .trailing_data_after_eoi) {
            found = true;
            offset_seen = f.offset;
        }
    }
    try std.testing.expect(found);
    // Offset should point at the byte immediately after EOI.
    try std.testing.expect(offset_seen != null);
}

test "validate surfaces libjpeg-style insufficient_data tolerance as Finding(warn)" {
    // Architecture decision (NEXT_STEPS.md §"Validation-strictness"):
    // when the decoder tolerates a spec deviation that libjpeg-turbo
    // would WARNMS about, validate(...) must surface a Finding(.warn).
    //
    // Setup: take a clean baseline JPEG, truncate bytes from the END
    // of its entropy stream, then re-attach the FFD9 EOI marker.
    // libjpeg sees a structurally-complete file (jpeg_read_header
    // succeeds), but `jpeg_read_scanlines` hits the EOI marker before
    // every block is decoded → emits JWRN_HIT_MARKER. The validator
    // surface should map that into Finding(.warn, .insufficient_data).
    const allocator = std.testing.allocator;
    const full = fixture_baseline_2x2_rgb;
    // Sanity: existing fixture ends with the EOI marker.
    try std.testing.expectEqual(@as(u8, 0xFF), full[full.len - 2]);
    try std.testing.expectEqual(@as(u8, 0xD9), full[full.len - 1]);

    // Strip the last 24 bytes of entropy (well inside the scan), then
    // re-attach the 2-byte EOI so the structural walker is satisfied.
    const cut: usize = 24;
    var corrupted = try allocator.alloc(u8, full.len - cut);
    defer allocator.free(corrupted);
    @memcpy(corrupted[0 .. full.len - cut - 2], full[0 .. full.len - cut - 2]);
    corrupted[full.len - cut - 2] = 0xFF;
    corrupted[full.len - cut - 1] = 0xD9;

    var report = try jpegz.validate(allocator, corrupted);
    defer report.deinit(allocator);

    // Must surface at least one .warn finding tagged insufficient_data.
    var found_warn = false;
    for (report.findings.items) |f| {
        if (f.severity == .warn and f.code == .insufficient_data) {
            found_warn = true;
        }
    }
    try std.testing.expect(found_warn);
    // Overall must not regress to .fail — libjpeg recovers, so should we.
    try std.testing.expect(report.overall != .fail);
}

test "validate non-JPEG bytes → FAIL, missing_soi finding" {
    const allocator = std.testing.allocator;
    const garbage = "this is not a JPEG file at all";

    var report = try jpegz.validate(allocator, garbage);
    defer report.deinit(allocator);

    try std.testing.expectEqual(jpegz.Severity.fail, report.overall);
    var found_missing_soi = false;
    for (report.findings.items) |f| {
        if (f.code == .missing_soi) found_missing_soi = true;
    }
    try std.testing.expect(found_missing_soi);
}

// ── Dormant T.81 code wiring (validation strictness for upstream Validate) ──
// A strict validator must surface table/structure-level spec violations that
// permissive libraries silently tolerate. Each new code is tested as a
// classifier over sets: it fires on the malformed set, stays silent on the
// well-formed one.

/// Offset of the first occurrence of marker byte `m` (the byte after a
/// 0xFF prefix) in `data`, or null. Helper for in-test corruption.
fn findMarker(data: []const u8, m: u8) ?usize {
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 1) {
        if (data[i] == 0xFF and data[i + 1] == m) return i;
    }
    return null;
}

fn reportHasCode(report: jpegz.ValidationReport, code: jpegz.FindingCode) bool {
    for (report.findings.items) |f| {
        if (f.code == code) return true;
    }
    return false;
}

test "validate: quantization_table_corrupt classifies bad Pq/Tq, silent on clean" {
    const allocator = std.testing.allocator;

    // Negative: the clean fixture's DQTs are well-formed — no quant finding.
    {
        var report = try jpegz.validate(allocator, fixture_baseline_2x2_rgb);
        defer report.deinit(allocator);
        try std.testing.expect(!reportHasCode(report, .quantization_table_corrupt));
    }

    // Positive: corrupt the first DQT's PqTq byte (FF DB Lhi Llo, then PqTq)
    // two distinct illegal ways (T.81 §B.2.4: Pq∈{0,1}, Tq∈{0..3}).
    const bad_pqtq = [_]u8{ 0x50, 0x07 }; // Pq=5 ; Tq=7
    for (bad_pqtq) |pqtq| {
        const buf = try allocator.dupe(u8, fixture_baseline_2x2_rgb);
        defer allocator.free(buf);
        const dqt = findMarker(buf, 0xDB).?;
        buf[dqt + 4] = pqtq;

        var report = try jpegz.validate(allocator, buf);
        defer report.deinit(allocator);
        try std.testing.expect(reportHasCode(report, .quantization_table_corrupt));
    }
}

test "validate: sof_component_count_invalid classifies Nf=0 and length-inconsistent Nf" {
    const allocator = std.testing.allocator;

    // Negative: clean fixture (SOF0 Nf=3, length 17 = 8 + 3*3) is consistent.
    {
        var report = try jpegz.validate(allocator, fixture_baseline_2x2_rgb);
        defer report.deinit(allocator);
        try std.testing.expect(!reportHasCode(report, .sof_component_count_invalid));
    }

    // Positive: corrupt the SOF0 Nf byte (body offset 5: prec,H,H,W,W,Nf).
    // Nf=0 is invalid; Nf=5 makes seg_len(17) != 8 + 3*Nf(23) — inconsistent.
    const bad_nf = [_]u8{ 0x00, 0x05 };
    for (bad_nf) |nf| {
        const buf = try allocator.dupe(u8, fixture_baseline_2x2_rgb);
        defer allocator.free(buf);
        const sof = findMarker(buf, 0xC0).?; // FF C0 (SOF0)
        buf[sof + 2 + 2 + 5] = nf; // FF C0 Lhi Llo, then body[5] = Nf

        var report = try jpegz.validate(allocator, buf);
        defer report.deinit(allocator);
        try std.testing.expect(reportHasCode(report, .sof_component_count_invalid));
    }
}

test "validate: sos_component_mismatch classifies Cs not declared in SOF, silent on clean" {
    const allocator = std.testing.allocator;

    // Negative: clean fixture's SOS selectors (1,2,3) all match the SOF.
    {
        var report = try jpegz.validate(allocator, fixture_baseline_2x2_rgb);
        defer report.deinit(allocator);
        try std.testing.expect(!reportHasCode(report, .sos_component_mismatch));
    }

    // Positive: corrupt the first SOS component selector (Cs0) to an ID not
    // present in the SOF component list. Body: FF DA Lhi Llo Ns Cs0 ... so
    // Cs0 is at sos+5. 0x63 = 99 (not a declared component).
    const buf = try allocator.dupe(u8, fixture_baseline_2x2_rgb);
    defer allocator.free(buf);
    const sos = findMarker(buf, 0xDA).?;
    buf[sos + 5] = 0x63;

    var report = try jpegz.validate(allocator, buf);
    defer report.deinit(allocator);
    try std.testing.expect(reportHasCode(report, .sos_component_mismatch));
}

test "validate: progressive_scan_invalid classifies bad spectral selection, silent on clean" {
    const allocator = std.testing.allocator;

    // Negative: every scan in the clean progressive fixture is well-formed.
    {
        var report = try jpegz.validate(allocator, fixture_progressive_8x8);
        defer report.deinit(allocator);
        try std.testing.expect(!reportHasCode(report, .progressive_scan_invalid));
    }

    // Positive: force the first SOS to Ss=0, Se=5 — a DC scan (Ss=0) must
    // have Se=0 (T.81 §G.1.1.1.1). SOS body: Ns, Ns×(Cs,Td/Ta), Ss, Se, AhAl.
    const buf = try allocator.dupe(u8, fixture_progressive_8x8);
    defer allocator.free(buf);
    const sos = findMarker(buf, 0xDA).?;
    const body = sos + 4;
    const ns = buf[body];
    const ss_off = body + 1 + 2 * @as(usize, ns);
    buf[ss_off] = 0;
    buf[ss_off + 1] = 5;

    var report = try jpegz.validate(allocator, buf);
    defer report.deinit(allocator);
    try std.testing.expect(reportHasCode(report, .progressive_scan_invalid));
}

test "validate: lossless_predictor_invalid classifies predictor outside 1..7" {
    const allocator = std.testing.allocator;

    {
        var report = try jpegz.validate(allocator, fixture_lossless_4x4_gray8);
        defer report.deinit(allocator);
        try std.testing.expect(!reportHasCode(report, .lossless_predictor_invalid));
    }

    // SOS Ss = predictor selector; valid 1..7 (T.81 §H.1). Try 0 and 8.
    const bad_pred = [_]u8{ 0, 8 };
    for (bad_pred) |p| {
        const buf = try allocator.dupe(u8, fixture_lossless_4x4_gray8);
        defer allocator.free(buf);
        const sos = findMarker(buf, 0xDA).?;
        const body = sos + 4;
        const ns = buf[body];
        const ss_off = body + 1 + 2 * @as(usize, ns);
        buf[ss_off] = p;

        var report = try jpegz.validate(allocator, buf);
        defer report.deinit(allocator);
        try std.testing.expect(reportHasCode(report, .lossless_predictor_invalid));
    }
}

test "validate: lossless_pointtransform_invalid classifies nonzero Ah in lossless scan" {
    const allocator = std.testing.allocator;

    {
        var report = try jpegz.validate(allocator, fixture_lossless_4x4_gray8);
        defer report.deinit(allocator);
        try std.testing.expect(!reportHasCode(report, .lossless_pointtransform_invalid));
    }

    // Lossless has no successive approximation: the AhAl byte must have
    // Ah=0 (it carries only the point transform Al). Set Ah=1.
    const buf = try allocator.dupe(u8, fixture_lossless_4x4_gray8);
    defer allocator.free(buf);
    const sos = findMarker(buf, 0xDA).?;
    const body = sos + 4;
    const ns = buf[body];
    const ahal_off = body + 1 + 2 * @as(usize, ns) + 2;
    buf[ahal_off] = 0x10; // Ah=1, Al=0

    var report = try jpegz.validate(allocator, buf);
    defer report.deinit(allocator);
    try std.testing.expect(reportHasCode(report, .lossless_pointtransform_invalid));
}

test "validate: arithmetic_table_corrupt classifies bad Tc/Tb in DAC, silent on clean" {
    const allocator = std.testing.allocator;

    // Negative: clean arithmetic fixture's DAC is well-formed.
    {
        var report = try jpegz.validate(allocator, fixture_arith_8x8_gray);
        defer report.deinit(allocator);
        try std.testing.expect(!reportHasCode(report, .arithmetic_table_corrupt));
    }

    // Positive: a DAC entry is (Tc/Tb, Cs). Tc (high nibble) must be 0 or 1;
    // Tb (low nibble) must be 0..3 (T.81 §B.2.4.3). Corrupt the first entry.
    const bad_tctb = [_]u8{ 0x20, 0x05 }; // Tc=2 ; Tb=5
    for (bad_tctb) |tctb| {
        const buf = try allocator.dupe(u8, fixture_arith_8x8_gray);
        defer allocator.free(buf);
        const dac = findMarker(buf, 0xCC).?;
        buf[dac + 4] = tctb; // FF CC Lhi Llo, then TcTb

        var report = try jpegz.validate(allocator, buf);
        defer report.deinit(allocator);
        try std.testing.expect(reportHasCode(report, .arithmetic_table_corrupt));
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
fn patchU16BE(allocator: std.mem.Allocator, src: []const u8, off: usize, value: u16) ![]u8 {
    const buf = try allocator.dupe(u8, src);
    buf[off] = @intCast(value >> 8);
    buf[off + 1] = @intCast(value & 0xFF);
    return buf;
}

/// Offset of the SOF0 segment length (the byte just past `0xFF 0xC0`).
/// baseline_2x2_rgb is encoded as SOF0 (marker 0xC0).
fn findSof0Body(data: []const u8) ?usize {
    var i: usize = 2;
    while (i + 1 < data.len) : (i += 1) {
        if (data[i] == 0xFF and data[i + 1] == 0xC0) return i + 2;
    }
    return null;
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

const fixture_jp2_rgb = @embedFile("fixtures/jp2_8x8_rgb.jp2");
const fixture_jp2_lossless = @embedFile("fixtures/jp2_8x8_lossless_5x3.jp2");
const fixture_jp2_lossy97 = @embedFile("fixtures/jp2_8x8_lossy_9x7.jp2");
const fixture_jp2_subsampled = @embedFile("fixtures/jp2_8x8_subsampled.jp2");
const fixture_jp2_yuv420 = @embedFile("fixtures/jp2_8x8_yuv420_asym.jp2");

const jp2_specificity_corpus = [_][]const u8{
    fixture_jp2_rgb,
    fixture_jp2_lossless,
    fixture_jp2_lossy97,
    fixture_jp2_subsampled,
    fixture_jp2_yuv420,
};

/// Offset of the JPEG 2000 SOC+SIZ marker pair (`FF4F FF51`) — the start
/// of the codestream inside the `jp2c` box. T.800 §A.4.1.
fn findSoc(data: []const u8) ?usize {
    var i: usize = 0;
    while (i + 3 < data.len) : (i += 1) {
        if (data[i] == 0xFF and data[i + 1] == 0x4F and
            data[i + 2] == 0xFF and data[i + 3] == 0x51) return i;
    }
    return null;
}

test "jpeg2000.validate: structural corruption set is detected (sensitivity)" {
    const allocator = std.testing.allocator;
    const src = fixture_jp2_rgb;
    const soc = findSoc(src).?;

    const Mutation = struct { name: []const u8, apply: *const fn ([]u8, usize) void };
    const mutations = [_]Mutation{
        .{
            .name = "JP2 signature box magic smashed ('jP  ' → 'XXXX')",
            .apply = struct {
                fn f(buf: []u8, _: usize) void {
                    @memset(buf[4..8], 'X');
                }
            }.f,
        },
        .{
            .name = "SOC marker smashed (codestream start destroyed)",
            .apply = struct {
                fn f(buf: []u8, soc_off: usize) void {
                    buf[soc_off] = 0x00;
                    buf[soc_off + 1] = 0x00;
                }
            }.f,
        },
        .{
            .name = "SIZ marker smashed (frame geometry unreadable)",
            .apply = struct {
                fn f(buf: []u8, soc_off: usize) void {
                    buf[soc_off + 2] = 0x00;
                    buf[soc_off + 3] = 0x00;
                }
            }.f,
        },
    };

    for (mutations) |m| {
        const buf = try allocator.dupe(u8, src);
        defer allocator.free(buf);
        m.apply(buf, soc);

        var report = try jpegz.jpeg2000.validate(allocator, buf);
        defer report.deinit(allocator);

        std.testing.expectEqual(jpegz.Severity.fail, report.overall) catch |e| {
            std.debug.print("jp2 mutation not detected: {s}\n", .{m.name});
            return e;
        };
    }

    // Truncation is its own shape (shorter buffer, not an in-place edit).
    // Cut to the first third — signature + ftyp survive, the codestream
    // does not.
    var report = try jpegz.jpeg2000.validate(allocator, src[0 .. src.len / 3]);
    defer report.deinit(allocator);
    try std.testing.expectEqual(jpegz.Severity.fail, report.overall);
}

test "jpeg2000.validate: every known-good JP2 fixture does not fail (specificity)" {
    const allocator = std.testing.allocator;
    for (jp2_specificity_corpus, 0..) |fixture, idx| {
        var report = try jpegz.jpeg2000.validate(allocator, fixture);
        defer report.deinit(allocator);
        std.testing.expect(report.overall != .fail) catch |e| {
            std.debug.print("false positive on known-good JP2 fixture #{d}\n", .{idx});
            return e;
        };
    }
}

test "jpeg2000.validate: reports a JP2-specific finding code, not a bare severity" {
    const allocator = std.testing.allocator;
    const src = fixture_jp2_rgb;
    const buf = try allocator.dupe(u8, src);
    defer allocator.free(buf);
    @memset(buf[4..8], 'X'); // smash the signature box magic

    var report = try jpegz.jpeg2000.validate(allocator, buf);
    defer report.deinit(allocator);

    // The whole point of the facade is ONE error vocabulary: consumers
    // must get an actionable jpegz FindingCode, not just `.fail`.
    try std.testing.expect(report.findings.items.len > 0);
    try std.testing.expect(reportHasCode(report, .jp2_invalid_signature) or
        reportHasCode(report, .jp2_invalid_codestream));
}

// A finding code that jpegz does not declare must not be renamed into an
// ALARMING one. Delegation translates jp2z's registry into jpegz's, and any
// code jpegz lacks previously degraded to `jp2_invalid_codestream` — so a
// perfectly healthy JP2 reported "invalid codestream" purely because
// `jp2_packets_walked_to_end` (254, a success signal meaning the walker
// consumed every tile-part byte) had no jpegz equivalent. A false alarm on a
// clean file is worse than a missing detail: it trains consumers to ignore
// the code.
test "jpeg2000.validate: clean JP2 reports no failure-flavored code" {
    const allocator = std.testing.allocator;
    for (jp2_specificity_corpus, 0..) |fixture, idx| {
        var report = try jpegz.jpeg2000.validate(allocator, fixture);
        defer report.deinit(allocator);

        std.testing.expect(!reportHasCode(report, .jp2_invalid_codestream)) catch |e| {
            std.debug.print("clean JP2 fixture #{d} reported jp2_invalid_codestream\n", .{idx});
            return e;
        };
        std.testing.expect(!reportHasCode(report, .jp2_invalid_signature)) catch |e| {
            std.debug.print("clean JP2 fixture #{d} reported jp2_invalid_signature\n", .{idx});
            return e;
        };
    }
}

// The success signal itself must survive translation intact, not merely
// avoid being renamed to something scary. jp2z emits
// `jp2_packets_walked_to_end` when the walker consumed every tile-part body
// byte; that is exactly the kind of positive evidence `validate` wants.
test "jpeg2000.validate: preserves jp2z's informational codes verbatim" {
    const allocator = std.testing.allocator;
    var report = try jpegz.jpeg2000.validate(allocator, fixture_jp2_rgb);
    defer report.deinit(allocator);

    try std.testing.expect(reportHasCode(report, .jp2_uses_5x3_wavelet));
    try std.testing.expect(reportHasCode(report, .jp2_packets_walked_to_end));
}

// ── Totality: validate must never panic, whatever the bytes say ──────
//
// `validate` is the function every consumer reaches for when it does NOT
// trust its input. A panic is therefore the one failure mode it cannot have:
// it is uncatchable in Zig, so a single crafted file takes down the whole
// host process (it took down tiffz's validateAllStripsAndTiles).
//
// The defect class: T.81 table-destination selectors are wider than the
// tables they select. SOF's Tq is a full byte (0..255) and SOS's Td/Ta are
// 4 bits each (0..15), but all three index 4-element arrays. Any value above
// 3 indexed straight out of bounds. Same family as `sof_zero_dimension`,
// which was an OOB crash in color.fancyUpsample.

test "validate reports, never panics, on an out-of-range SOS table selector" {
	// SOS layout (T.81 §B.2.3): FF DA, Ls(2), Ns(1), then Ns x (Cs, Td|Ta).
	// Td/Ta is one byte of two 4-bit destination selectors, so 0xFF asks for
	// DC table 15 and AC table 15 out of the four that exist.
	const allocator = std.testing.allocator;
	var data = fixture_baseline_2x2_rgb.*;
	const sos = findMarker(&data, 0xDA) orelse return error.SkipZigTest;
	data[sos + 6] = 0xFF; // Td|Ta of the first scan component

	var report = try jpegz.validate(allocator, &data);
	defer report.deinit(allocator);
	// Reaching this line at all is the assertion that matters; a panic would
	// abort the test binary rather than fail this test.
	try std.testing.expectEqual(jpegz.Severity.fail, report.overall);
	try std.testing.expect(report.findings.items.len > 0);
}

test "validate reports, never panics, on an out-of-range SOF quant selector" {
	// SOF0 layout (T.81 §B.2.2): FF C0, Lf(2), P, Y(2), X(2), Nf, then
	// Nf x (C, H|V, Tq). Tq is a whole byte, so it can name table 255 of 4.
	const allocator = std.testing.allocator;
	var data = fixture_baseline_2x2_rgb.*;
	const sof = findMarker(&data, 0xC0) orelse return error.SkipZigTest;
	data[sof + 12] = 0xFF; // Tq of the first frame component

	var report = try jpegz.validate(allocator, &data);
	defer report.deinit(allocator);
	try std.testing.expectEqual(jpegz.Severity.fail, report.overall);
	try std.testing.expect(report.findings.items.len > 0);
}

test "validate is total over every single-byte mutation of a real JPEG" {
	// The two cases above were found by reading the code after tiffz hit a
	// panic in the wild. This sweeps the whole file so the NEXT unchecked
	// index is found by the suite rather than by a downstream consumer's
	// crash: a classifier over a set, not two hand-picked examples.
	const allocator = std.testing.allocator;
	for (0..fixture_baseline_2x2_rgb.len) |off| {
		for ([_]u8{ 0x00, 0x0F, 0x3F, 0xF0, 0xFF }) |val| {
			var data = fixture_baseline_2x2_rgb.*;
			if (data[off] == val) continue;
			data[off] = val;
			var report = jpegz.validate(allocator, &data) catch |err| {
				// An error return is a legitimate outcome; a panic is not.
				try std.testing.expectEqual(error.OutOfMemory, err);
				continue;
			};
			report.deinit(allocator);
		}
	}
}
