const std = @import("std");
const jpegz = @import("jpegz");

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
		.{ .sof = 0xc3, .sampling = 0x21, .verdict = .unsupported },
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
    };
    const cases = [_]Case{
        .{ .leaf_verdict = 0, .leaf_code = 0, .verdict = .valid, .code = null },
        .{ .leaf_verdict = 1, .leaf_code = 1, .verdict = .corrupt, .code = .jxl_invalid_signature },
        .{ .leaf_verdict = 1, .leaf_code = 2, .verdict = .corrupt, .code = .jxl_truncated },
        .{ .leaf_verdict = 1, .leaf_code = 3, .verdict = .corrupt, .code = .jxl_malformed },
        .{ .leaf_verdict = 2, .leaf_code = 4, .verdict = .unsupported, .code = .jxl_unsupported_feature },
        .{ .leaf_verdict = 3, .leaf_code = 5, .verdict = .indeterminate, .code = .jxl_resource_limit },
        .{ .leaf_verdict = 3, .leaf_code = 6, .verdict = .indeterminate, .code = .jxl_out_of_memory },
        .{ .leaf_verdict = 3, .leaf_code = 7, .verdict = .indeterminate, .code = .jxl_invalid_argument },
        .{ .leaf_verdict = 3, .leaf_code = 8, .verdict = .indeterminate, .code = .jxl_unclassified_decoder_error },
        .{ .leaf_verdict = 0, .leaf_code = 999, .verdict = .indeterminate, .code = null },
    };

    for (cases) |case| {
        const mapped = jpegz.facade.mapJxlFinding(case.leaf_verdict, case.leaf_code);
        try std.testing.expectEqual(case.verdict, mapped.verdict);
        try std.testing.expectEqual(case.code, mapped.code);
        if (case.code) |code| try std.testing.expectEqual(@as(u32, @intCast(179 + case.leaf_code)), @intFromEnum(code));
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

test "JPEG XL labeled corpus preserves valid unsupported and indeterminate" {
    const Case = struct {
        label: []const u8,
        bytes: []const u8,
        expected: jpegz.StrictVerdict,
    };
    const cases = [_]Case{
        .{ .label = "delta_palette known-good", .bytes = @embedFile("fixtures/jxl_delta_palette_valid.jxl"), .expected = .valid },
        .{ .label = "patches_lossless known-unsupported", .bytes = @embedFile("fixtures/jxl_patches_lossless_unsupported.jxl"), .expected = .unsupported },
        .{ .label = "bicycles known-indeterminate", .bytes = @embedFile("fixtures/jxl_bicycles_indeterminate.jxl"), .expected = .indeterminate },
    };
    for (cases) |case| {
        var result = try jpegz.jpegxl.validate(std.testing.allocator, case.bytes, jpegz.jpegxl.default_options);
        defer result.deinit(std.testing.allocator);
        if (result.verdict != case.expected) {
            std.debug.print("{s}: expected {t}, found {t}\n", .{ case.label, case.expected, result.verdict });
            return error.TestExpectedEqual;
        }
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
    try std.testing.expectEqual(@as(?u64, 0), finding.offset);
    try std.testing.expectEqual(@as(?u64, 91), finding.host_offset);
    try std.testing.expect(finding.offset_is_exact);
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
		.{ .label = "JXL known-unsupported", .bytes = @embedFile("fixtures/jxl_patches_lossless_unsupported.jxl"), .format = .jpeg_xl, .verdict = .unsupported },
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
