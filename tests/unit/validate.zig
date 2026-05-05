//! M1.5 — `jpegz.validate` tests. Walks the bitstream, accumulates
//! Findings, returns a structured ValidationReport. Never fails-fast
//! on structural errors (per the design doc — validate-mode wants the
//! complete picture, not the first failure).

const std = @import("std");
const jpegz = @import("jpegz");

const fixture_baseline_2x2_rgb = @embedFile("fixtures/baseline_2x2_rgb.jpg");
const fixture_progressive_8x8 = @embedFile("fixtures/progressive_8x8_rgb.jpg");
const fixture_lossless_4x4_gray8 = @embedFile("fixtures/lossless_4x4_gray8.jpg");

test "validate clean baseline JPEG → PASS, baseline_huffman" {
    const allocator = std.testing.allocator;

    var report = try jpegz.validate(allocator, fixture_baseline_2x2_rgb);
    defer report.deinit(allocator);

    try std.testing.expectEqual(jpegz.Severity.pass, report.overall);
    try std.testing.expectEqual(jpegz.Variant.baseline_huffman, report.variant);
    try std.testing.expectEqual(@as(?u32, 2), report.width);
    try std.testing.expectEqual(@as(?u32, 2), report.height);
    try std.testing.expect(report.isValid());
    try std.testing.expectEqual(@as(usize, 0), report.findings.items.len);
}

test "validate clean progressive JPEG → PASS, progressive_huffman" {
    const allocator = std.testing.allocator;

    var report = try jpegz.validate(allocator, fixture_progressive_8x8);
    defer report.deinit(allocator);

    try std.testing.expectEqual(jpegz.Severity.pass, report.overall);
    try std.testing.expectEqual(jpegz.Variant.progressive_huffman, report.variant);
    try std.testing.expectEqual(@as(?u32, 8), report.width);
    try std.testing.expectEqual(@as(?u32, 8), report.height);
}

test "validate clean lossless JPEG → PASS, lossless_huffman" {
    const allocator = std.testing.allocator;

    var report = try jpegz.validate(allocator, fixture_lossless_4x4_gray8);
    defer report.deinit(allocator);

    try std.testing.expectEqual(jpegz.Severity.pass, report.overall);
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
