//! Phase-1 scaffold smoke tests. Proves wiring; the heavy decode
//! tests live in `tests/unit/decode.zig` (added at M1.3).

const std = @import("std");
const jpegz = @import("jpegz");

test "version is exposed" {
    try std.testing.expect(jpegz.version.len > 0);
    try std.testing.expectEqualStrings("0.1.0", jpegz.version);
}

test "decode rejects empty data" {
    const empty: []const u8 = &[_]u8{};
    try std.testing.expectError(
        error.TruncatedStream,
        jpegz.decode(std.testing.allocator, empty),
    );
}

test "jpeg2000.decode rejects empty data" {
    const empty: []const u8 = &[_]u8{};
    try std.testing.expectError(
        error.TruncatedStream,
        jpegz.jpeg2000.decode(std.testing.allocator, empty),
    );
}

test "validate empty input fails fast at missing_soi" {
    // Smoke: just confirms validate is wired and returns a freeable
    // report. Detailed scenarios live in tests/unit/validate.zig.
    const empty: []const u8 = &[_]u8{};
    var report = try jpegz.validate(std.testing.allocator, empty);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(jpegz.Severity.fail, report.overall);
    try std.testing.expectEqual(jpegz.Variant.unknown, report.variant);
    try std.testing.expect(report.findings.items.len > 0);
}

test "decodeStreamingRows stub returns NotImplemented" {
    const empty: []const u8 = &[_]u8{};
    const cb = jpegz.RowCallback{
        .on_row = struct {
            fn cb(_: ?*anyopaque, _: []const u8, _: u32) anyerror!void {}
        }.cb,
    };
    try std.testing.expectError(
        error.NotImplemented,
        jpegz.decodeStreamingRows(std.testing.allocator, empty, cb),
    );
}

test "FindingCode numeric values are stable" {
    // Spot-check a few — these are wire-format values per the design
    // doc § 4.1; reordering is a wire-break.
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(jpegz.FindingCode.missing_soi));
    try std.testing.expectEqual(@as(u32, 50), @intFromEnum(jpegz.FindingCode.invalid_sof_precision));
    try std.testing.expectEqual(@as(u32, 100), @intFromEnum(jpegz.FindingCode.lossless_predictor_invalid));
    try std.testing.expectEqual(@as(u32, 200), @intFromEnum(jpegz.FindingCode.arithmetic_coding_used));
}
