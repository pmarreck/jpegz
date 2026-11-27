//! Lossless reconstruction is modulo 2^16 at every precision (T.81 H.1.2;
//! libjpeg-turbo jdlossls.c UNDIFFERENCE: `(diff + predictor) & 0xFFFF`).
//! Damaged entropy that still decodes can push a sample past 2^P - 1.
//! Later predictions must see that 16-bit value, not one masked to P bits,
//! and the output is (value << Pt) truncated to the sample container.

const std = @import("std");
const jpegz = @import("jpegz");

const Case = struct { name: []const u8, data: []const u8, at: usize, value: u8 };

// Single-byte entropy damage found by a mutation sweep; each one decoded
// differently from libjpeg-turbo while jpegz masked samples to P bits.
const cases = [_]Case{
    .{ .name = "P=12, 4 components, predictor 7", .data = @embedFile("fixtures/lossless_5x4_4comp_p12_pred7.jpg"), .at = 70, .value = 0x77 },
    .{ .name = "P=12, Pt=3, predictor 1", .data = @embedFile("fixtures/lossless_16x16_gray_p12_pt3_sel1.jpg"), .at = 252, .value = 0x74 },
    .{ .name = "P=8, predictor 7", .data = @embedFile("fixtures/lossless_4x4_gradient_pred7.jpg"), .at = 70, .value = 0x01 },
    .{ .name = "P=12, Pt=3, row end", .data = @embedFile("fixtures/lossless_16x16_gray_p12_pt3_sel1.jpg"), .at = 104, .value = 0x57 },
    .{ .name = "P=12, Pt=3, later row", .data = @embedFile("fixtures/lossless_16x16_gray_p12_pt3_sel1.jpg"), .at = 202, .value = 0xd7 },
};

test "lossless samples past 2^P - 1 predict and output like libjpeg-turbo (modulo 2^16)" {
    const allocator = std.testing.allocator;
    for (cases) |case| {
        const data = try allocator.dupe(u8, case.data);
        defer allocator.free(data);
        try std.testing.expect(data[case.at] != case.value);
        data[case.at] = case.value;
        var ours = try jpegz.decode(allocator, data);
        defer ours.deinit(allocator);
        var oracle = try jpegz.internal.wrapperDecode(allocator, data);
        defer oracle.deinit(allocator);
        std.testing.expectEqualSlices(u8, oracle.pixels, ours.pixels) catch |err| {
            std.debug.print("lossless range case differs from libjpeg-turbo: {s}\n", .{case.name});
            return err;
        };
    }
}
