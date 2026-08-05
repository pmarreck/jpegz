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
