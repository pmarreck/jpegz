const std = @import("std");
const jpegz = @import("jpegz");

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
