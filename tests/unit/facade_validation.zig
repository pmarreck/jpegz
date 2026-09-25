const std = @import("std");
const jpegz = @import("jpegz");

const sof3_pair = [_]u8{ 0xff, 0xd8, 0xff, 0xc3, 0, 14, 12, 0, 1, 0, 1, 2, 1, 0x11, 0, 2, 0x11, 0 } ++
	[_]u8{ 0xff, 0xc4, 0, 20, 0, 1 } ++ ([_]u8{0} ** 15) ++ [_]u8{0} ++
	[_]u8{ 0xff, 0xda, 0, 10, 2, 1, 0, 2, 0, 1, 0, 0, 0x3f, 0xff, 0xd9 };

test "SOF3 header constraints preserve lossless precision and bound parser indices" {
	const allocator = std.testing.allocator;
	const cases = [_]struct { offset: usize, value: u8, verdict: jpegz.StrictVerdict }{
		.{ .offset = 6, .value = 2, .verdict = .valid },
		.{ .offset = 6, .value = 14, .verdict = .valid },
		.{ .offset = 6, .value = 16, .verdict = .valid },
		.{ .offset = 6, .value = 1, .verdict = .corrupt },
		.{ .offset = 13, .value = 0, .verdict = .corrupt },
		.{ .offset = 13, .value = 0x51, .verdict = .corrupt },
		.{ .offset = 15, .value = 1, .verdict = .corrupt },
		.{ .offset = 23, .value = 3, .verdict = .corrupt },
		.{ .offset = 39, .value = 17, .verdict = .corrupt },
		.{ .offset = 44, .value = 4, .verdict = .corrupt },
		.{ .offset = 46, .value = 0x40, .verdict = .corrupt },
		.{ .offset = 46, .value = 1, .verdict = .corrupt },
		.{ .offset = 47, .value = 1, .verdict = .corrupt },
		.{ .offset = 50, .value = 1, .verdict = .corrupt },
		.{ .offset = 51, .value = 0x10, .verdict = .corrupt },
	};
	for (cases) |case| {
		var bytes = sof3_pair;
		bytes[case.offset] = case.value;
		var result = try jpegz.validateAny(allocator, &bytes);
		defer result.deinit(allocator);
		try std.testing.expectEqual(case.verdict, result.verdict);
	}
}

test "SOF3 checks EOI and every byte of a truncated pair" {
	const allocator = std.testing.allocator;
	for (2..sof3_pair.len) |end| {
		var result = try jpegz.validateAny(allocator, sof3_pair[0..end]);
		defer result.deinit(allocator);
		try std.testing.expectEqual(jpegz.StrictVerdict.corrupt, result.verdict);
	}
	const surplus = sof3_pair[0..53].* ++ [_]u8{ 0x00, 0xff, 0xd9 };
	var result = try jpegz.validateAny(allocator, &surplus);
	defer result.deinit(allocator);
	try std.testing.expectEqual(jpegz.StrictVerdict.corrupt, result.verdict);
}

test "SOF3 preserves unused DQT and category16 controls" {
	const allocator = std.testing.allocator;
	const dqt = [_]u8{ 0xff, 0xdb, 0, 67, 0 } ++ ([_]u8{1} ** 64);
	const with_dqt = sof3_pair[0..2].* ++ dqt ++ sof3_pair[2..].*;
	var category16 = sof3_pair;
	category16[6] = 16;
	category16[39] = 16; // Two code0 symbols, no amplitude bits (H.1.2.2).
	var point_transform = sof3_pair;
	point_transform[51] = 1;
	for ([_][]const u8{ &with_dqt, &category16, &point_transform }) |data| {
		var result = try jpegz.validateAny(allocator, data);
		defer result.deinit(allocator);
		try std.testing.expectEqual(jpegz.StrictVerdict.valid, result.verdict);
	}
}

test "SOF3 keeps DNL unsupported and rejects reversed scan order" {
	const allocator = std.testing.allocator;
	var reversed = sof3_pair;
	reversed[45] = 2;
	reversed[47] = 1;
	var reversed_result = try jpegz.validateAny(allocator, &reversed);
	defer reversed_result.deinit(allocator);
	try std.testing.expectEqual(jpegz.StrictVerdict.corrupt, reversed_result.verdict);
	for ([_]u8{ 0, 1, 2 }) |height| {
		for ([_][]const u8{ &.{}, &.{0xff} }) |fill| {
			var prefix = sof3_pair[0..53].*;
			prefix[8] = height;
			const data = try std.mem.concat(allocator, u8, &.{ &prefix, fill, &.{ 0xff, 0xdc, 0, 4, 0, 1, 0xff, 0xd9 } });
			defer allocator.free(data);
			var result = try jpegz.validateAny(allocator, data);
			defer result.deinit(allocator);
			try std.testing.expectEqual(jpegz.StrictVerdict.unsupported, result.verdict);
		}
	}
}

test "SOF3 two-component sampling validates complete MCU groups and rejects boundary damage" {
	// T.81 A.2.3: each lossless data unit is one sample, including edge
	// padding. A one-bit code 0 represents difference zero (H.2).
	const cases = [_]struct {
		sampling: [2]u8,
		width: u8,
		height: u8 = 1,
		entropy: []const u8,
		restart: u8 = 0,
		valid: bool = true,
	}{
		.{ .sampling = .{ 0x11, 0x11 }, .width = 1, .entropy = &.{0x3f} },
		.{ .sampling = .{ 0x21, 0x21 }, .width = 2, .entropy = &.{0x0f} },
		.{ .sampling = .{ 0x21, 0x21 }, .width = 3, .entropy = &.{0x00} },
		.{ .sampling = .{ 0x21, 0x11 }, .width = 3, .entropy = &.{0x03} },
		.{ .sampling = .{ 0x22, 0x11 }, .width = 1, .entropy = &.{0x07} },
		.{ .sampling = .{ 0x21, 0x21 }, .width = 2, .height = 2, .restart = 1, .entropy = &.{ 0x0f, 0xff, 0xd0, 0x0f } },
		.{ .sampling = .{ 0x21, 0x21 }, .width = 2, .height = 2, .restart = 1, .entropy = &.{ 0x0f, 0xff, 0xff, 0xd0, 0x0f } },
		.{ .sampling = .{ 0x21, 0x21 }, .width = 2, .height = 10, .restart = 1, .entropy = &.{ 0x0f, 0xff, 0xd0, 0x0f, 0xff, 0xd1, 0x0f, 0xff, 0xd2, 0x0f, 0xff, 0xd3, 0x0f, 0xff, 0xd4, 0x0f, 0xff, 0xd5, 0x0f, 0xff, 0xd6, 0x0f, 0xff, 0xd7, 0x0f, 0xff, 0xd0, 0x0f } },
		.{ .sampling = .{ 0x21, 0x21 }, .width = 2, .entropy = &.{0x1f}, .valid = false }, // Missing sample.
		.{ .sampling = .{ 0x21, 0x21 }, .width = 2, .entropy = &.{0x07}, .valid = false }, // Extra sample.
		.{ .sampling = .{ 0x21, 0x21 }, .width = 2, .entropy = &.{0x0e}, .valid = false }, // Zero pad bit.
		.{ .sampling = .{ 0x21, 0x21 }, .width = 2, .entropy = &.{ 0x0f, 0x00 }, .valid = false },
		.{ .sampling = .{ 0x21, 0x21 }, .width = 2, .height = 2, .restart = 1, .entropy = &.{ 0x0f, 0xff, 0xd1, 0x0f }, .valid = false },
		.{ .sampling = .{ 0x21, 0x21 }, .width = 3, .restart = 1, .entropy = &.{0x00}, .valid = false }, // Ri not whole rows.
	};
	const allocator = std.testing.allocator;
	for (cases) |case| {
		const header = [_]u8{ 0xff, 0xd8, 0xff, 0xc3, 0, 14, 12, 0, case.height, 0, case.width, 2, 1, case.sampling[0], 0, 2, case.sampling[1], 0 } ++
			[_]u8{ 0xff, 0xc4, 0, 20, 0, 1 } ++ ([_]u8{0} ** 15) ++ [_]u8{0} ++
			[_]u8{ 0xff, 0xdd, 0, 4, 0, case.restart, 0xff, 0xda, 0, 10, 2, 1, 0, 2, 0, 1, 0, 0 };
		const data = try std.mem.concat(allocator, u8, &.{ &header, case.entropy, &.{ 0xff, 0xd9 } });
		defer allocator.free(data);
		var result = try jpegz.validateAny(allocator, data);
		defer result.deinit(allocator);
		try std.testing.expectEqual(if (case.valid) jpegz.StrictVerdict.valid else .corrupt, result.verdict);
		if (!case.valid) {
			var located_failure = false;
			for (result.findings.items) |finding| {
				if (finding.severity == .fail and finding.offset != null and finding.offset.? < data.len)
					located_failure = true;
			}
			try std.testing.expect(located_failure);
		}
	}
}

test "SOF3 accepts different legal amplitudes and reports trailing data separately" {
	const allocator = std.testing.allocator;
	var header = sof3_pair[0..52].*;
	header[6] = 8;
	header[39] = 7; // code0, seven amplitude bits: 128+127=255 or 128+126=254.
	for ([_]u8{ 0x7f, 0x7e }) |amplitude| {
		const data = header ++ [_]u8{ amplitude, amplitude, 0xff, 0xd9 };
		var result = try jpegz.validateAny(allocator, &data);
		defer result.deinit(allocator);
		try std.testing.expectEqual(jpegz.StrictVerdict.valid, result.verdict);
	}
	const trailing = sof3_pair ++ [_]u8{0};
	var result = try jpegz.validateAny(allocator, &trailing);
	defer result.deinit(allocator);
	try std.testing.expectEqual(jpegz.StrictVerdict.valid, result.verdict);
	var found = false;
	for (result.findings.items) |finding| {
		if (finding.code == .trailing_data_after_eoi) {
			try std.testing.expectEqual(@as(?u64, sof3_pair.len), finding.offset);
			found = true;
		}
	}
	try std.testing.expect(found);
}

test "SOF3 standalone markers cannot masquerade as unsupported length-prefixed segments" {
	const allocator = std.testing.allocator;
	const tail = [_]u8{0} ** 65536; // FFD9 must not be misread as a plausible length.
	for ([_]u8{ 0xd8, 0xd0, 0x01, 0x00 }) |marker| {
		for ([_]usize{ 2, 53 }) |insertion| {
			const data = try std.mem.concat(allocator, u8, &.{ sof3_pair[0..insertion], &.{ 0xff, marker }, sof3_pair[insertion..], &tail });
			defer allocator.free(data);
			var result = try jpegz.validateAny(allocator, data);
			defer result.deinit(allocator);
			try std.testing.expectEqual(jpegz.StrictVerdict.corrupt, result.verdict);
		}
	}
}

test "JP2 dependency findings retain wire identities and severities" {
	const cases = [_]struct { raw: u32, name: []const u8, severity: jpegz.Severity, verdict: jpegz.StrictVerdict }{
		.{ .raw = 255, .name = "zero_bitplane_overflow", .severity = .fail, .verdict = .corrupt },
		.{ .raw = 256, .name = "packed_headers_mismatch", .severity = .fail, .verdict = .corrupt },
		.{ .raw = 257, .name = "jp2_trailing_bytes", .severity = .fail, .verdict = .corrupt },
		.{ .raw = 258, .name = "segmentation_symbol_mismatch", .severity = .fail, .verdict = .corrupt },
		.{ .raw = 259, .name = "profile_violation", .severity = .fail, .verdict = .corrupt },
		// E.2's encoder formula is informative, not a normative constraint.
		.{ .raw = 260, .name = "reversible_exponent_mismatch", .severity = .warn, .verdict = .valid },
	};
	for (cases) |case| {
		const mapped = jpegz.facade.mapJp2Finding(case.raw, case.severity, true);
		try std.testing.expectEqual(case.verdict, mapped.verdict);
		try std.testing.expectEqual(case.severity, mapped.severity);
		const code = mapped.code orelse return error.MissingJp2Finding;
		try std.testing.expectEqual(case.raw, @intFromEnum(code));
		try std.testing.expectEqualStrings(case.name, @tagName(code));
	}
	for ([_]u32{ 261, 299, 999 }) |raw| {
		const mapped = jpegz.facade.mapJp2Finding(raw, .fail, true);
		try std.testing.expectEqual(jpegz.StrictVerdict.indeterminate, mapped.verdict);
		try std.testing.expectEqual(@as(?jpegz.FindingCode, null), mapped.code);
	}
}

test "classic facade requires EOI even after a complete progressive scan" {
	const allocator = std.testing.allocator;
	const progressive = @embedFile("fixtures/progressive_8x8_rgb.jpg");
	const baseline = @embedFile("fixtures/baseline_2x2_rgb.jpg");
	const lossless = @embedFile("fixtures/lossless_4x4_gray8.jpg");
	// corruption-probe seed0x1234, truncation round46: 520 bytes cut to441.
	// The next SOS starts at441. Earlier completed scans plus EOI remain legal.
	try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xda }, progressive[441..443]);
	const early_complete = progressive[0..441].* ++ [_]u8{ 0xff, 0xd9 };
	const embedded_eoi = progressive[0..441].* ++ [_]u8{ 0xff, 0xfe, 0, 4, 0xff, 0xd9 };
	const dangling_ff = progressive[0..441].* ++ [_]u8{0xff};
	const cases = [_]struct { bytes: []const u8, valid: bool }{
		.{ .bytes = progressive, .valid = true },
		.{ .bytes = baseline, .valid = true },
		.{ .bytes = lossless, .valid = true },
		.{ .bytes = &early_complete, .valid = true },
		.{ .bytes = progressive[0..441], .valid = false },
		.{ .bytes = progressive[0 .. progressive.len - 2], .valid = false },
		.{ .bytes = baseline[0 .. baseline.len - 2], .valid = false },
		.{ .bytes = lossless[0 .. lossless.len - 2], .valid = false },
		.{ .bytes = &embedded_eoi, .valid = false },
		.{ .bytes = &dangling_ff, .valid = false },
	};
	for (cases) |case| {
		var result = try jpegz.validateAny(allocator, case.bytes);
		defer result.deinit(allocator);
		if (result.verdict != (if (case.valid) jpegz.StrictVerdict.valid else .corrupt)) {
			std.debug.print("EOI case len{d} valid{} got{s}\n", .{ case.bytes.len, case.valid, @tagName(result.verdict) });
		}
		try std.testing.expectEqual(if (case.valid) jpegz.StrictVerdict.valid else .corrupt, result.verdict);
	}
	// Preserve legacy recovery and the original finding's severity/location.
	var legacy = try jpegz.validate(allocator, progressive[0..441]);
	defer legacy.deinit(allocator);
	try std.testing.expect(legacy.isValid());
	var strict = try jpegz.validateAny(allocator, progressive[0..441]);
	defer strict.deinit(allocator);
	var found = false;
	for (strict.findings.items) |finding| {
		if (finding.code == .missing_eoi and finding.severity == .warn and finding.offset == 441) found = true;
	}
	try std.testing.expect(found);
}

test "classic facade distinguishes unchecked and unsupported codecs from validity" {
	const allocator = std.testing.allocator;
	const cases = [_]struct { sof: u8, sampling: u8 = 0x11, width: u8 = 1, verdict: jpegz.StrictVerdict }{
		.{ .sof = 0xc3, .verdict = .valid },
		.{ .sof = 0xc3, .sampling = 0x21, .verdict = .valid },
		.{ .sof = 0xc3, .sampling = 0x44, .verdict = .valid },
		.{ .sof = 0xc3, .sampling = 0x21, .width = 0, .verdict = .corrupt },
		.{ .sof = 0xc7, .verdict = .indeterminate },
		.{ .sof = 0xc7, .width = 0, .verdict = .corrupt },
	};
	for (cases) |case| {
		// Minimal lossless marker chain, DC code 0 => difference zero.
		// Differential SOF7 exercises a skipped codec, not a claim that this
		// synthetic chain proves a complete, valid hierarchical JPEG.
		const data = [_]u8{ 0xff, 0xd8, 0xff, case.sof, 0, 11, 8, 0, 1, 0, case.width, 1, 1, case.sampling, 0 } ++
			[_]u8{ 0xff, 0xc4, 0, 20, 0, 1 } ++ ([_]u8{0} ** 15) ++ [_]u8{0} ++
			[_]u8{ 0xff, 0xda, 0, 8, 1, 1, 0, 1, 0, 0, 0x7f, 0xff, 0xd9 };
		var legacy = try jpegz.validate(allocator, &data);
		defer legacy.deinit(allocator);
		try std.testing.expectEqual(case.verdict != .corrupt, legacy.isValid());
		var strict = try jpegz.validateAny(allocator, &data);
		defer strict.deinit(allocator);
		try std.testing.expectEqual(case.verdict, strict.verdict);
	}
	const jls = @embedFile("fixtures/jpegls_4x4_gray8.jls");
	var malformed_jls = jls.*;
	const sof = std.mem.indexOf(u8, jls, &.{ 0xff, 0xf7 }) orelse return error.MissingFixtureSof;
	@memset(malformed_jls[sof + 7 .. sof + 9], 0); // Zero width; retain SOF55 identification.
	const skipped = [_]struct { data: []const u8, verdict: jpegz.StrictVerdict }{
		.{ .data = jls, .verdict = .indeterminate },
		.{ .data = &malformed_jls, .verdict = .corrupt },
	};
	for (skipped) |case| {
		var legacy = try jpegz.validate(allocator, case.data);
		defer legacy.deinit(allocator);
		try std.testing.expectEqual(jpegz.Variant.jpegls, legacy.variant);
		try std.testing.expectEqual(case.verdict != .corrupt, legacy.isValid());
		var strict = try jpegz.validateAny(allocator, case.data);
		defer strict.deinit(allocator);
		try std.testing.expectEqual(case.verdict, strict.verdict);
	}
}

test "classic facade rejects recovered entropy damage but accepts legal fill" {
	const allocator = std.testing.allocator;
	const baseline = @embedFile("fixtures/baseline_2x2_rgb.jpg");
	const restart = @embedFile("fixtures/baseline_128x128_dri4.jpg");
	const progressive = @embedFile("fixtures/progressive_16x16_rgb12_444.jpg");
	const progressive_truncated = progressive[0 .. progressive.len - 18].* ++ [_]u8{ 0xff, 0xd9 };
	const legal_fill = baseline[0..2].* ++ [_]u8{ 0xff, 0xff } ++ baseline[2..].*;
	// Keep EOI intact: only the codec check can detect the missing entropy.
	const truncated = baseline[0 .. baseline.len - 26].* ++ [_]u8{ 0xff, 0xd9 };
	var wrong_restart = restart.*;
	var missing_restart = restart.*;
	try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xd0 }, restart[652..654]);
	wrong_restart[653] = 0xd5;
	@memcpy(missing_restart[652..654], &[_]u8{ 0xaa, 0xbb });
	const cases = [_]struct {
		bytes: []const u8,
		verdict: jpegz.StrictVerdict,
		warning: ?jpegz.FindingCode = null,
	}{
		.{ .bytes = baseline, .verdict = .valid },
		.{ .bytes = restart, .verdict = .valid },
		.{ .bytes = @embedFile("fixtures/progressive_8x8_rgb.jpg"), .verdict = .valid },
		.{ .bytes = @embedFile("fixtures/lossless_4x4_gray8.jpg"), .verdict = .valid },
		.{ .bytes = @embedFile("fixtures/arith_baseline_8x8_gray.jpg"), .verdict = .valid },
		.{ .bytes = &legal_fill, .verdict = .valid, .warning = .entropy_fill_bytes },
		.{ .bytes = &truncated, .verdict = .corrupt, .warning = .insufficient_data },
		.{ .bytes = progressive, .verdict = .valid },
		.{ .bytes = &progressive_truncated, .verdict = .corrupt, .warning = .insufficient_data },
		.{ .bytes = &wrong_restart, .verdict = .corrupt, .warning = .restart_marker_unexpected },
		.{ .bytes = &missing_restart, .verdict = .corrupt, .warning = .restart_marker_missing },
	};
	for (cases) |case| {
		var legacy = try jpegz.validate(allocator, case.bytes);
		defer legacy.deinit(allocator);
		var strict = try jpegz.validateAny(allocator, case.bytes);
		defer strict.deinit(allocator);
		if (case.warning) |code| {
			var found = false;
			for (strict.findings.items) |finding| {
				if (finding.code == code and finding.severity == .warn) found = true;
			}
			try std.testing.expect(found);
			// Pin the legacy API's recovery behavior separately from the verdict.
			if (code == .entropy_fill_bytes or code == .insufficient_data)
				try std.testing.expect(legacy.isValid());
		}
		try std.testing.expectEqual(case.verdict, strict.verdict);
	}
}

test "JPEG XL mapping is exhaustive and unknown future codes fail closed" {
    const Case = struct {
        leaf_verdict: i32,
        leaf_code: i32,
        verdict: jpegz.StrictVerdict,
        code: ?jpegz.FindingCode,
        severity: jpegz.Severity,
    };
    const cases = [_]Case{
        .{ .leaf_verdict = 0, .leaf_code = 0, .verdict = .valid, .code = null, .severity = .pass },
        .{ .leaf_verdict = 1, .leaf_code = 1, .verdict = .corrupt, .code = .jxl_invalid_signature, .severity = .fail },
        .{ .leaf_verdict = 1, .leaf_code = 2, .verdict = .corrupt, .code = .jxl_truncated, .severity = .fail },
        .{ .leaf_verdict = 1, .leaf_code = 3, .verdict = .corrupt, .code = .jxl_malformed, .severity = .fail },
        .{ .leaf_verdict = 2, .leaf_code = 4, .verdict = .unsupported, .code = .jxl_unsupported_feature, .severity = .warn },
        .{ .leaf_verdict = 3, .leaf_code = 5, .verdict = .indeterminate, .code = .jxl_resource_limit, .severity = .warn },
        .{ .leaf_verdict = 3, .leaf_code = 6, .verdict = .indeterminate, .code = .jxl_out_of_memory, .severity = .warn },
        .{ .leaf_verdict = 3, .leaf_code = 7, .verdict = .indeterminate, .code = .jxl_invalid_argument, .severity = .warn },
        .{ .leaf_verdict = 3, .leaf_code = 8, .verdict = .indeterminate, .code = .jxl_unclassified_decoder_error, .severity = .warn },
        .{ .leaf_verdict = 1, .leaf_code = 9, .verdict = .corrupt, .code = .jxl_nonzero_padding, .severity = .warn },
        .{ .leaf_verdict = 1, .leaf_code = 10, .verdict = .corrupt, .code = .jxl_invalid_context_map, .severity = .fail },
        .{ .leaf_verdict = 1, .leaf_code = 11, .verdict = .corrupt, .code = .jxl_invalid_ma_tree, .severity = .fail },
        .{ .leaf_verdict = 1, .leaf_code = 12, .verdict = .corrupt, .code = .jxl_invalid_ans_state, .severity = .fail },
        .{ .leaf_verdict = 1, .leaf_code = 13, .verdict = .corrupt, .code = .jxl_truncated_box_header, .severity = .warn },
        .{ .leaf_verdict = 1, .leaf_code = 14, .verdict = .corrupt, .code = .jxl_invalid_ac_nonzero_count, .severity = .fail },
        .{ .leaf_verdict = 0, .leaf_code = 999, .verdict = .indeterminate, .code = null, .severity = .warn },
    };

    for (cases) |case| {
        const mapped = jpegz.facade.mapJxlFinding(case.leaf_verdict, case.leaf_code);
        try std.testing.expectEqual(case.verdict, mapped.verdict);
        try std.testing.expectEqual(case.code, mapped.code);
        try std.testing.expectEqual(case.severity, mapped.severity);
        if (case.code) |code| {
            const expected_facade_code: u32 = if (case.leaf_code <= 8)
                @intCast(179 + case.leaf_code)
            else
                @intCast(180 + case.leaf_code);
            try std.testing.expectEqual(expected_facade_code, @intFromEnum(code));
        }
    }
}

test "JPEG XL entropy findings preserve names and reject inconsistent verdicts" {
    const cases = .{
        .{ @as(i32, 15), @as(u32, 195), "jxl_invalid_hybrid_uint_config" },
        .{ @as(i32, 16), @as(u32, 196), "jxl_invalid_histogram" },
    };
    inline for (cases) |case| {
        for (0..4) |raw_verdict| {
            const mapped = jpegz.facade.mapJxlFinding(@intCast(raw_verdict), case[0]);
            try std.testing.expectEqual(
                if (raw_verdict == 1) jpegz.StrictVerdict.corrupt else jpegz.StrictVerdict.indeterminate,
                mapped.verdict,
            );
            try std.testing.expect(mapped.code != null);
            try std.testing.expectEqual(case[1], @intFromEnum(mapped.code.?));
            try std.testing.expectEqualStrings(case[2], @tagName(mapped.code.?));
        }
    }
}

test "JPEG 2000 mapping preserves every public leaf code and fails closed" {
    const known_codes = [_]u32{
        1,   2,   3,   4,   5,
        140, 141, 142, 143, 144,
        145, 146, 207, 208, 250,
        251, 252, 253, 254,
    };
    for (known_codes) |raw| {
        const mapped = jpegz.facade.mapJp2Finding(raw, .warn, true);
        try std.testing.expect(mapped.code != null);
        try std.testing.expectEqual(
            if (raw == 1) @as(u32, 141) else raw,
            @intFromEnum(mapped.code.?),
        );
        try std.testing.expectEqual(
            if (raw == 145) jpegz.StrictVerdict.unsupported else jpegz.StrictVerdict.valid,
            mapped.verdict,
        );
    }

    const unknown = jpegz.facade.mapJp2Finding(999, .pass, true);
    try std.testing.expectEqual(jpegz.StrictVerdict.indeterminate, unknown.verdict);
    try std.testing.expectEqual(@as(?jpegz.FindingCode, null), unknown.code);
}

test "strict facade rejects mandatory JPEG-family signature mutations" {
    const jp2_good = @embedFile("fixtures/jp2_8x8_rgb.jp2");
    var jp2_bad = jp2_good.*;
    jp2_bad[4] = 'x';
    var jp2_result = try jpegz.jpeg2000.strictValidate(std.testing.allocator, &jp2_bad);
    defer jp2_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(jpegz.StrictVerdict.corrupt, jp2_result.verdict);

    const jxl_bad = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    var jxl_result = try jpegz.jpegxl.validate(std.testing.allocator, &jxl_bad, jpegz.jpegxl.default_options);
    defer jxl_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(jpegz.StrictVerdict.corrupt, jxl_result.verdict);
}

test "JPEG XL formerly unsupported corpus now validates completely" {
    const Case = struct {
        label: []const u8,
        bytes: []const u8,
        expected: jpegz.StrictVerdict,
    };
    const cases = [_]Case{
        .{ .label = "delta_palette known-good", .bytes = @embedFile("fixtures/jxl_delta_palette_valid.jxl"), .expected = .valid },
        .{ .label = "patches_lossless now supported", .bytes = @embedFile("fixtures/jxl_patches_lossless_unsupported.jxl"), .expected = .valid },
        .{ .label = "bicycles now supported", .bytes = @embedFile("fixtures/jxl_bicycles_indeterminate.jxl"), .expected = .valid },
    };
    for (cases) |case| {
        var result = try jpegz.jpegxl.validate(std.testing.allocator, case.bytes, jpegz.jpegxl.default_options);
        defer result.deinit(std.testing.allocator);
        if (result.verdict != case.expected) {
            std.debug.print("{s}: expected {t}, found {t}\n", .{ case.label, case.expected, result.verdict });
            return error.TestExpectedEqual;
        }
        try std.testing.expectEqual(@as(?bool, true), result.decode_complete);
        try std.testing.expectEqual(@as(?u64, 0), result.reported_finding_count);
    }
}

test "JPEG XL sniper bolter and shotgun mutations are independently corrupt" {
    const good = @embedFile("fixtures/jxl_delta_palette_valid.jxl");
    var sniper = good.*;
    sniper[0] ^= 0x01;
    var bolter = good.*;
    bolter[0] = 0;
    var shotgun = good.*;
    @memset(shotgun[0..12], 0);
    const Case = struct { label: []const u8, bytes: []const u8 };
    const cases = [_]Case{
        .{ .label = "sniper one-bit signature flip", .bytes = &sniper },
        .{ .label = "bolter one-byte signature overwrite", .bytes = &bolter },
        .{ .label = "shotgun twelve-byte signature overwrite", .bytes = &shotgun },
    };
    for (cases) |case| {
        var result = try jpegz.jpegxl.validate(std.testing.allocator, case.bytes, jpegz.jpegxl.default_options);
        defer result.deinit(std.testing.allocator);
        if (result.verdict != .corrupt) {
            std.debug.print("{s}: expected corrupt, found {t}\n", .{ case.label, result.verdict });
            return error.TestExpectedEqual;
        }
    }
}

test "JPEG 2000 known-good and three mutation strengths classify as a set" {
    const good = @embedFile("fixtures/jp2_8x8_rgb.jp2");
    var valid = try jpegz.jpeg2000.strictValidate(std.testing.allocator, good);
    defer valid.deinit(std.testing.allocator);
    try std.testing.expectEqual(jpegz.StrictVerdict.valid, valid.verdict);

    var sniper = good.*;
    sniper[8] ^= 0x01;
    var bolter = good.*;
    bolter[4] = 0;
    var shotgun = good.*;
    @memset(shotgun[0..12], 0);
    const Case = struct { label: []const u8, bytes: []const u8 };
    const cases = [_]Case{
        .{ .label = "sniper one-bit JP2 signature flip", .bytes = &sniper },
        .{ .label = "bolter one-byte JP2 signature overwrite", .bytes = &bolter },
        .{ .label = "shotgun full JP2 signature overwrite", .bytes = &shotgun },
    };
    for (cases) |case| {
        var result = try jpegz.jpeg2000.strictValidate(std.testing.allocator, case.bytes);
        defer result.deinit(std.testing.allocator);
        if (result.verdict != .corrupt) {
            std.debug.print("{s}: expected corrupt, found {t}\n", .{ case.label, result.verdict });
            return error.TestExpectedEqual;
        }
    }
}

test "JPEG XL facade preserves leaf identity and exact host-relative offset" {
    const invalid = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    var options = jpegz.jpegxl.default_options;
    options.host_byte_offset = 91;
    var result = try jpegz.jpegxl.validate(std.testing.allocator, &invalid, options);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.findings.items.len);
    const finding = result.findings.items[0];
    try std.testing.expectEqual(jpegz.ValidatorSource.libjxlz, finding.source);
    try std.testing.expectEqual(@as(u32, 1), finding.leaf_code);
    try std.testing.expectEqual(jpegz.FindingCode.jxl_invalid_signature, finding.code.?);
    try std.testing.expect(!finding.is_assessed);
    try std.testing.expectEqual(@as(?u64, 0), finding.offset);
    try std.testing.expectEqual(@as(?u64, 91), finding.host_offset);
    try std.testing.expect(finding.offset_is_exact);
}

test "JPEG XL facade preserves warning then fatal findings and completion" {
    const clean = [_]u8{
        255, 10, 0, 0, 0, 128, 160, 184, 17, 8, 2, 1, 0, 64, 0, 137,
        160, 86, 21, 64, 2, 0, 194, 141, 120, 155, 2, 255, 170, 50, 0,
    };
    var options = jpegz.jpegxl.default_options;
    options.host_byte_offset = 1000;

    var valid = try jpegz.jpegxl.validate(std.testing.allocator, &clean, options);
    defer valid.deinit(std.testing.allocator);
    try std.testing.expectEqual(jpegz.StrictVerdict.valid, valid.verdict);
    try std.testing.expectEqual(@as(?bool, true), valid.decode_complete);
    try std.testing.expectEqual(@as(?u64, 0), valid.reported_finding_count);
    try std.testing.expectEqual(@as(?u64, 0), valid.reported_warning_count);
    try std.testing.expectEqual(@as(usize, 0), valid.findings.items.len);

    var warning_bytes = clean;
    warning_bytes[8] |= 32;
    var warning = try jpegz.jpegxl.validate(std.testing.allocator, &warning_bytes, options);
    defer warning.deinit(std.testing.allocator);
    try std.testing.expectEqual(jpegz.StrictVerdict.corrupt, warning.verdict);
    try std.testing.expectEqual(@as(?bool, true), warning.decode_complete);
    try std.testing.expectEqual(@as(?u64, 1), warning.reported_finding_count);
    try std.testing.expectEqual(@as(?u64, 1), warning.reported_warning_count);
    try std.testing.expectEqual(@as(usize, 1), warning.findings.items.len);
    try std.testing.expectEqual(jpegz.FindingCode.jxl_nonzero_padding, warning.findings.items[0].code.?);
    try std.testing.expectEqual(jpegz.Severity.warn, warning.findings.items[0].severity);
    try std.testing.expect(warning.findings.items[0].is_assessed);
    try std.testing.expectEqual(@as(?u64, 8), warning.findings.items[0].offset);
    try std.testing.expectEqual(@as(?u64, 1008), warning.findings.items[0].host_offset);

    var stopped = try jpegz.jpegxl.validate(std.testing.allocator, warning_bytes[0..9], options);
    defer stopped.deinit(std.testing.allocator);
    try std.testing.expectEqual(jpegz.StrictVerdict.corrupt, stopped.verdict);
    try std.testing.expectEqual(@as(?bool, false), stopped.decode_complete);
    try std.testing.expectEqual(@as(?u64, 2), stopped.reported_finding_count);
    try std.testing.expectEqual(@as(?u64, 1), stopped.reported_warning_count);
    try std.testing.expectEqual(@as(usize, 2), stopped.findings.items.len);
    try std.testing.expectEqual(jpegz.FindingCode.jxl_nonzero_padding, stopped.findings.items[0].code.?);
    try std.testing.expectEqual(jpegz.Severity.warn, stopped.findings.items[0].severity);
    try std.testing.expectEqual(jpegz.FindingCode.jxl_truncated, stopped.findings.items[1].code.?);
    try std.testing.expectEqual(jpegz.Severity.fail, stopped.findings.items[1].severity);
    try std.testing.expect(stopped.findings.items[1].is_assessed);
    try std.testing.expectEqual(@as(?u64, 9), stopped.findings.items[1].offset);
    try std.testing.expect(stopped.findings.items[1].offset_is_exact);
}

test "JPEG XL trailing header invalidity survives recovery and resource limits" {
    const clean = [_]u8{
        255, 10, 0, 0, 0, 128, 160, 184, 17, 8, 2, 1, 0, 64, 0, 137,
        160, 86, 21, 64, 2, 0, 194, 141, 120, 155, 2, 255, 170, 50, 0,
    };
    // Signature, ftyp and a length-delimited jxlc box containing the control.
    const header = [_]u8{
        0, 0, 0, 12, 'J', 'X', 'L', ' ', 13, 10, 135, 10,
        0, 0, 0, 20, 'f', 't', 'y', 'p', 'j', 'x', 'l', ' ',
        0, 0, 0, 0, 'j', 'x', 'l', ' ',
        0, 0, 0, 8 + clean.len, 'j', 'x', 'l', 'c',
    };
    const boxed = header ++ clean;
    const input = boxed ++ [_]u8{ 0, 0, 0, 8, 't', 'e', 's', 't' };
    var options = jpegz.jpegxl.default_options;
    options.host_byte_offset = 1000;
    for (0..9) |tail| {
        var result = try jpegz.jpegxl.validate(std.testing.allocator, input[0 .. boxed.len + tail], options);
        defer result.deinit(std.testing.allocator);
        const valid = tail == 0 or tail == 8;
        try std.testing.expectEqual(if (valid) jpegz.StrictVerdict.valid else .corrupt, result.verdict);
        try std.testing.expectEqual(@as(?bool, true), result.decode_complete);
        try std.testing.expectEqual(@as(usize, if (valid) 0 else 1), result.findings.items.len);
        if (!valid) {
            const finding = result.findings.items[0];
            try std.testing.expectEqual(jpegz.FindingCode.jxl_truncated_box_header, finding.code.?);
            try std.testing.expectEqual(jpegz.Severity.warn, finding.severity);
            try std.testing.expectEqual(@as(?u64, boxed.len), finding.offset);
            try std.testing.expectEqual(@as(?u64, 1000 + boxed.len), finding.host_offset);
            try std.testing.expect(finding.offset_is_exact);
        }
    }
    options.max_pixels = 0;
    var limited = try jpegz.jpegxl.validate(std.testing.allocator, input[0 .. boxed.len + 1], options);
    defer limited.deinit(std.testing.allocator);
    try std.testing.expectEqual(jpegz.StrictVerdict.corrupt, limited.verdict);
    try std.testing.expectEqual(@as(?bool, false), limited.decode_complete);
    try std.testing.expectEqual(@as(usize, 2), limited.findings.items.len);
    try std.testing.expectEqual(jpegz.FindingCode.jxl_truncated_box_header, limited.findings.items[0].code.?);
    try std.testing.expectEqual(jpegz.FindingCode.jxl_resource_limit, limited.findings.items[1].code.?);
}

// ── U2: family-wide container sniffing + one-call validation ──────────
//
// A sniffer is a FILTER, so these test it as a classifier over sets
// (sensitivity + specificity corpora) rather than as a predicate over one
// happy example. A sniffer that answered `.jpeg` unconditionally would pass
// any single positive case.

test "sniff classifies the whole JPEG family and rejects foreign containers" {
	const Case = struct {
		label: []const u8,
		bytes: []const u8,
		expected: jpegz.ValidationFormat,
	};
	const zeros = [_]u8{0} ** 16;
	const cases = [_]Case{
		// Sensitivity — every family member jpegz claims to cover.
		.{ .label = "T.81 baseline JPEG", .bytes = @embedFile("fixtures/baseline_4x4_rgb_444.jpg"), .expected = .jpeg },
		.{ .label = "T.87 JPEG-LS", .bytes = @embedFile("fixtures/jpegls_4x4_gray8.jls"), .expected = .jpeg },
		.{ .label = "T.800 JP2 container", .bytes = @embedFile("fixtures/jp2_8x8_rgb.jp2"), .expected = .jpeg2000 },
		.{ .label = "T.800 raw J2K codestream", .bytes = &[_]u8{ 0xFF, 0x4F, 0xFF, 0x51 }, .expected = .jpeg2000 },
		// SOC alone decides. `file(1)` keys on SOC+SIZ, but a codestream whose
		// SIZ is damaged is exactly the case worth routing to jp2z: it answers
		// with a precise marker-level finding, where "unrecognized container"
		// would throw away everything the first two bytes already told us.
		.{ .label = "J2K codestream with a smashed SIZ", .bytes = &[_]u8{ 0xFF, 0x4F, 0x00, 0x00 }, .expected = .jpeg2000 },
		.{ .label = "18181 JXL bare codestream", .bytes = @embedFile("fixtures/jxl_delta_palette_valid.jxl"), .expected = .jpeg_xl },
		.{ .label = "18181 JXL ISOBMFF container", .bytes = @embedFile("fixtures/jxl_patches_lossless_unsupported.jxl"), .expected = .jpeg_xl },
		// Specificity — a classifier that claims everything is useless.
		.{ .label = "PNG", .bytes = "\x89PNG\r\n\x1a\n", .expected = .unknown },
		.{ .label = "GIF89a", .bytes = "GIF89a", .expected = .unknown },
		.{ .label = "PDF", .bytes = "%PDF-1.7", .expected = .unknown },
		.{ .label = "TIFF little-endian", .bytes = "II\x2a\x00", .expected = .unknown },
		.{ .label = "all zeros", .bytes = &zeros, .expected = .unknown },
		.{ .label = "empty input", .bytes = "", .expected = .unknown },
		.{ .label = "lone 0xFF", .bytes = &[_]u8{0xFF}, .expected = .unknown },
		.{ .label = "0xFF then a foreign second byte", .bytes = &[_]u8{ 0xFF, 0x00 }, .expected = .unknown },
	};
	for (cases) |case| {
		const got = jpegz.sniff(case.bytes);
		if (got != case.expected) {
			std.debug.print("{s}: expected {t}, found {t}\n", .{ case.label, case.expected, got });
			return error.TestExpectedEqual;
		}
	}
}

test "sniff separates the JP2 and JXL signature boxes that differ only in type" {
	// Both containers open with a 12-byte box: length 0x0000000C, a 4-byte
	// type, then 0D 0A 87 0A. ONLY bytes 4..8 tell them apart ("jP  " vs
	// "JXL "), so a sniffer keyed on the length or the trailing bytes routes
	// every JXL file into the JPEG 2000 validator and still looks correct on
	// a single-fixture test.
	const jp2 = @embedFile("fixtures/jp2_8x8_rgb.jp2");
	const jxl = @embedFile("fixtures/jxl_patches_lossless_unsupported.jxl");
	try std.testing.expect(std.mem.eql(u8, jp2[0..4], jxl[0..4]));
	try std.testing.expect(std.mem.eql(u8, jp2[8..12], jxl[8..12]));
	try std.testing.expect(!std.mem.eql(u8, jp2[4..8], jxl[4..8]));
	try std.testing.expectEqual(jpegz.ValidationFormat.jpeg2000, jpegz.sniff(jp2));
	try std.testing.expectEqual(jpegz.ValidationFormat.jpeg_xl, jpegz.sniff(jxl));

	// Same frame, foreign type: belongs to neither.
	var foreign = jp2[0..12].*;
	@memcpy(foreign[4..8], "ftyp");
	try std.testing.expectEqual(jpegz.ValidationFormat.unknown, jpegz.sniff(&foreign));
}

test "validateAny routes each family member to the validator that owns it" {
	const Case = struct {
		label: []const u8,
		bytes: []const u8,
		format: jpegz.ValidationFormat,
		verdict: jpegz.StrictVerdict,
	};
	const cases = [_]Case{
		.{ .label = "baseline JPEG", .bytes = @embedFile("fixtures/baseline_4x4_rgb_444.jpg"), .format = .jpeg, .verdict = .valid },
		.{ .label = "JP2", .bytes = @embedFile("fixtures/jp2_8x8_rgb.jp2"), .format = .jpeg2000, .verdict = .valid },
		.{ .label = "JXL known-good", .bytes = @embedFile("fixtures/jxl_delta_palette_valid.jxl"), .format = .jpeg_xl, .verdict = .valid },
		.{ .label = "JXL patches supported", .bytes = @embedFile("fixtures/jxl_patches_lossless_unsupported.jxl"), .format = .jpeg_xl, .verdict = .valid },
	};
	for (cases) |case| {
		var result = try jpegz.validateAny(std.testing.allocator, case.bytes);
		defer result.deinit(std.testing.allocator);
		if (result.format != case.format or result.verdict != case.verdict) {
			std.debug.print("{s}: expected {t}/{t}, found {t}/{t}\n", .{
				case.label, case.format, case.verdict, result.format, result.verdict,
			});
			return error.TestExpectedEqual;
		}
	}
}

test "validateAny calls an unrecognized container indeterminate, never valid" {
	// `.valid` here would be a false negative for every non-JPEG byte string
	// on disk; `.corrupt` would be a false positive, since unrecognized bytes
	// are not evidence of damage. Only `.indeterminate` is honest.
	const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0DIHDR";
	var result = try jpegz.validateAny(std.testing.allocator, png);
	defer result.deinit(std.testing.allocator);
	try std.testing.expectEqual(jpegz.ValidationFormat.unknown, result.format);
	try std.testing.expectEqual(jpegz.StrictVerdict.indeterminate, result.verdict);
	try std.testing.expect(!result.isValid());
	try std.testing.expectEqual(@as(usize, 1), result.findings.items.len);
	try std.testing.expectEqual(jpegz.FindingCode.unrecognized_container, result.findings.items[0].code.?);
}

test "a JP2 with a destroyed signature box is not misdiagnosed as a JPEG missing SOI" {
	// The C CLI's ad-hoc sniffer fell through to the JPEG path here and
	// reported `missing_soi — JPEG must start with SOI marker`, naming a
	// T.81 marker that does not exist anywhere in T.800. Routing must never
	// invent a format the bytes never claimed.
	const good = @embedFile("fixtures/jp2_8x8_rgb.jp2");
	var smashed = good.*;
	@memset(smashed[0..12], 0);
	var result = try jpegz.validateAny(std.testing.allocator, &smashed);
	defer result.deinit(std.testing.allocator);
	try std.testing.expect(result.format != .jpeg);
	try std.testing.expect(!result.isValid());
	for (result.findings.items) |finding| {
		if (finding.code) |code| try std.testing.expect(code != .missing_soi);
	}
}
