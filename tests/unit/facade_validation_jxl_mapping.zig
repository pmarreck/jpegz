//! facade_validation tests, part 3 (split from facade_validation.zig to keep files small).

const std = @import("std");
const jpegz = @import("jpegz");
const h1 = @import("facade_validation_helpers.zig");
const sof3_pair = h1.sof3_pair;
const hierarchicalStream = h1.hierarchicalStream;

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
        .{ .leaf_verdict = 1, .leaf_code = 9, .verdict = .corrupt, .code = .jxl_nonzero_padding, .severity = .fail },
        .{ .leaf_verdict = 1, .leaf_code = 10, .verdict = .corrupt, .code = .jxl_invalid_context_map, .severity = .fail },
        .{ .leaf_verdict = 1, .leaf_code = 11, .verdict = .corrupt, .code = .jxl_invalid_ma_tree, .severity = .fail },
        .{ .leaf_verdict = 1, .leaf_code = 12, .verdict = .corrupt, .code = .jxl_invalid_ans_state, .severity = .fail },
        .{ .leaf_verdict = 1, .leaf_code = 13, .verdict = .corrupt, .code = .jxl_truncated_box_header, .severity = .fail },
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
		.{ @as(i32, 17), @as(u32, 197), "jxl_invalid_icc_symbol" },
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

test "JXL finding classifier separates every current pair from unknown and inconsistent pairs" {
	const raw_codes = [_]i32{ -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 67, 197, std.math.maxInt(i32) };
	for (raw_codes) |raw_code| {
		for (0..6) |value| {
			const raw_verdict: i32 = @as(i32, @intCast(value)) - 1;
			const known = raw_code >= 1 and raw_code <= 19;
			// Trailing data (19) without an origin is taken as WARN: valid.
			const expected_raw: i32 = if (raw_code == 4) 2 else if (raw_code >= 5 and raw_code <= 8) 3 else if (raw_code == 19) 0 else 1;
			const expected: jpegz.StrictVerdict = if (raw_code == 0 and raw_verdict == 0)
				.valid
			else if (!known or raw_verdict != expected_raw)
				.indeterminate
			else if (raw_code == 4)
				.unsupported
			else if (raw_code >= 5 and raw_code <= 8)
				.indeterminate
			else if (raw_code == 19)
				.valid
			else
				.corrupt;
			const mapped = jpegz.facade.mapJxlFinding(raw_verdict, raw_code);
			try std.testing.expectEqual(expected, mapped.verdict);
			try std.testing.expectEqual(known, mapped.code != null);
			if (known) {
				const wire: u32 = @intCast(raw_code + (if (raw_code <= 8) @as(i32, 179) else 180));
				try std.testing.expectEqual(wire, @intFromEnum(mapped.code.?));
			}
			// Owner, 2026-11-05: every corrupt pair, including nonzero padding (9)
			// and a truncated box header (13), is FAIL class.
			const severity: jpegz.Severity = if (expected == .valid) (if (raw_code == 19) .warn else .pass) else if (expected == .corrupt) .fail else .warn;
			try std.testing.expectEqual(severity, mapped.severity);
		}
	}
}

test "JPEG 2000 mapping preserves every public leaf code and fails closed" {
    const known_codes = [_]u32{
        1,   2,   3,   4,   5,
        140, 141, 142, 143, 144,
        145, 146, 207, 208, 250,
        251, 252, 253, 254, 261,
    };
    for (known_codes) |raw| {
        const mapped = jpegz.facade.mapJp2Finding(raw, .warn, true);
        try std.testing.expect(mapped.code != null);
        try std.testing.expectEqual(
            if (raw == 1) @as(u32, 141) else raw,
            @intFromEnum(mapped.code.?),
        );
        try std.testing.expectEqual(
            if (raw == 145) jpegz.StrictVerdict.unsupported else if (raw == 261) jpegz.StrictVerdict.corrupt else jpegz.StrictVerdict.valid,
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

test "JPEG XL findings expose their libjxlz leaf code as the re-exported enum" {
	if (!jpegz.facade.with_jxl) return error.SkipZigTest;
	const LeafCode = jpegz.jpegxl.FindingCode;
	const jxl_bad = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
	var result = try jpegz.jpegxl.validate(std.testing.allocator, &jxl_bad, jpegz.jpegxl.default_options);
	defer result.deinit(std.testing.allocator);
	try std.testing.expect(result.findings.items.len > 0);
	var saw_signature = false;
	for (result.findings.items) |finding| {
		try std.testing.expectEqual(jpegz.ValidatorSource.libjxlz, finding.source);
		const leaf = jpegz.jpegxl.leafCode(finding) orelse return error.TestExpectedLeafCode;
		try std.testing.expectEqual(finding.leaf_code, @as(u32, @bitCast(@as(i32, @intFromEnum(leaf)))));
		// A consumer switches exhaustively, so a new leaf code is a compile error.
		switch (leaf) {
			.JXL_VALIDATION_FINDING_INVALID_SIGNATURE => saw_signature = true,
			else => {},
		}
	}
	try std.testing.expect(saw_signature);

	// Control: a jpegz finding with an in-range number is not a libjxlz code.
	var jpeg_result = try jpegz.validateAny(std.testing.allocator, @embedFile("fixtures/baseline_2x2_rgb.jpg")[0..10]);
	defer jpeg_result.deinit(std.testing.allocator);
	try std.testing.expect(jpeg_result.findings.items.len > 0);
	for (jpeg_result.findings.items) |finding| {
		try std.testing.expectEqual(@as(?LeafCode, null), jpegz.jpegxl.leafCode(finding));
	}
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

test "JPEG XL signature bit, byte and full-header mutations are independently corrupt" {
    const good = @embedFile("fixtures/jxl_delta_palette_valid.jxl");
    var flipped_signature_bit = good.*;
    flipped_signature_bit[0] ^= 0x01;
    var cleared_signature_byte = good.*;
    cleared_signature_byte[0] = 0;
    var cleared_signature = good.*;
    @memset(cleared_signature[0..12], 0);
    const Case = struct { label: []const u8, bytes: []const u8 };
    const cases = [_]Case{
        .{ .label = "one-bit signature flip", .bytes = &flipped_signature_bit },
        .{ .label = "one signature byte cleared", .bytes = &cleared_signature_byte },
        .{ .label = "twelve-byte signature cleared", .bytes = &cleared_signature },
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

test "JPEG 2000 known-good and signature mutations classify as a set" {
    const good = @embedFile("fixtures/jp2_8x8_rgb.jp2");
    var valid = try jpegz.jpeg2000.strictValidate(std.testing.allocator, good);
    defer valid.deinit(std.testing.allocator);
    try std.testing.expectEqual(jpegz.StrictVerdict.valid, valid.verdict);

    var flipped_signature_bit = good.*;
    flipped_signature_bit[8] ^= 0x01;
    var cleared_signature_byte = good.*;
    cleared_signature_byte[4] = 0;
    var cleared_signature = good.*;
    @memset(cleared_signature[0..12], 0);
    const Case = struct { label: []const u8, bytes: []const u8 };
    const cases = [_]Case{
        .{ .label = "one-bit JP2 signature flip", .bytes = &flipped_signature_bit },
        .{ .label = "one JP2 signature byte cleared", .bytes = &cleared_signature_byte },
        .{ .label = "full JP2 signature cleared", .bytes = &cleared_signature },
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
    try std.testing.expectEqual(jpegz.Severity.fail, warning.findings.items[0].severity);
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
    try std.testing.expectEqual(jpegz.Severity.fail, stopped.findings.items[0].severity);
    try std.testing.expectEqual(jpegz.FindingCode.jxl_truncated, stopped.findings.items[1].code.?);
    try std.testing.expectEqual(jpegz.Severity.fail, stopped.findings.items[1].severity);
    try std.testing.expect(stopped.findings.items[1].is_assessed);
    try std.testing.expectEqual(@as(?u64, 9), stopped.findings.items[1].offset);
    try std.testing.expect(stopped.findings.items[1].offset_is_exact);
}

test "JPEG XL trailing header invalidity survives recovery and resource limits" {
    // libjxlz (12d575fa, owner-approved): after a complete container, a cut
    // box header is damage only when its type can still be one of the twelve
    // ISO/IEC 18181-2 box types. One to four zero bytes are zero fill (WARN
    // 199), and bytes that cannot begin a defined type are trailing data
    // (WARN 199).
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
    const Expect = enum { clean, warn, fail };
    const Trailer = struct { box: [8]u8, expect: [9]Expect };
    const trailers = [_]Trailer{
        // An empty "xml " box, a defined type: every cut after the size field
        // can still be its header, so it stays FAIL at the header's offset.
        .{ .box = .{ 0, 0, 0, 8, 'x', 'm', 'l', ' ' }, .expect = .{ .clean, .warn, .warn, .warn, .fail, .fail, .fail, .fail, .clean } },
        // An empty box of an undefined type: once the type bytes rule out
        // every defined type, the cut tail is trailing data; the whole box is
        // an unknown box, which Part 2 allows.
        .{ .box = .{ 0, 0, 0, 8, 't', 'e', 's', 't' }, .expect = .{ .clean, .warn, .warn, .warn, .fail, .warn, .warn, .warn, .clean } },
    };
    var options = jpegz.jpegxl.default_options;
    options.host_byte_offset = 1000;
    for (trailers) |trailer| {
        const input = boxed ++ trailer.box;
        for (trailer.expect, 0..) |expect, tail| {
            errdefer std.debug.print("trailer {s}, tail {d}\n", .{ trailer.box[4..8], tail });
            var result = try jpegz.jpegxl.validate(std.testing.allocator, input[0 .. boxed.len + tail], options);
            defer result.deinit(std.testing.allocator);
            try std.testing.expectEqual(if (expect == .fail) jpegz.StrictVerdict.corrupt else .valid, result.verdict);
            try std.testing.expectEqual(@as(?bool, true), result.decode_complete);
            try std.testing.expectEqual(@as(usize, if (expect == .clean) 0 else 1), result.findings.items.len);
            if (expect == .clean) continue;
            const finding = result.findings.items[0];
            try std.testing.expectEqual(if (expect == .fail) jpegz.FindingCode.jxl_truncated_box_header else .jxl_trailing_data, finding.code.?);
            try std.testing.expectEqual(if (expect == .fail) jpegz.Severity.fail else .warn, finding.severity);
            try std.testing.expectEqual(@as(?u64, boxed.len), finding.offset);
            try std.testing.expectEqual(@as(?u64, 1000 + boxed.len), finding.host_offset);
            if (expect == .fail) try std.testing.expect(finding.offset_is_exact);
        }
    }
    // A resource limit does not hide a cut header of a defined type.
    const input = boxed ++ trailers[0].box;
    options.max_pixels = 0;
    var limited = try jpegz.jpegxl.validate(std.testing.allocator, input[0 .. boxed.len + 5], options);
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

