//! Dequantization range: a legal quantizer can scale a coefficient past
//! i16, and neither validation nor decoding may trap on it.

const std = @import("std");
const jpegz = @import("jpegz");

const gray12 = @embedFile("fixtures/progressive_8x8_gray12.jpg");
// The 8-bit DQT body (Pq=0, Tq=0) starts at this offset in the fixture.
const dqt_values = 0x19;

fn expectMatchesLibjpegTurbo(allocator: std.mem.Allocator, data: []const u8) !void {
    var report = try jpegz.validate(allocator, data);
    defer report.deinit(allocator);
    try std.testing.expect(report.overall != .fail);
    var cleanroom = try jpegz.internal.progressiveDecode(allocator, data);
    defer cleanroom.deinit(allocator);
    var wrapper = try jpegz.internal.wrapperDecode(allocator, data);
    defer wrapper.deinit(allocator);
    const c = cleanroom.pixelsU16();
    const w = wrapper.pixelsU16();
    try std.testing.expectEqual(w.len, c.len);
    for (c, w) |a, b| try std.testing.expectEqual(b, a);
}

test "12-bit progressive coefficients scaled past i16 by a legal DQT decode like libjpeg-turbo" {
    const allocator = std.testing.allocator;
    // Single quantizer entries raised after encoding (found by mutation:
    // both trapped with an integer-cast panic in validate and decode).
    for ([_][2]u8{ .{ 0x21 - dqt_values, 0xED }, .{ 0x1B - dqt_values, 0xAD } }) |edit| {
        var data = gray12.*;
        try std.testing.expect(data[0x18] == 0x00); // Pq=0, Tq=0
        data[dqt_values + edit[0]] = edit[1];
        try expectMatchesLibjpegTurbo(allocator, &data);
    }
    // Every entry at the 8-bit maximum.
    var data = gray12.*;
    @memset(data[dqt_values..][0..64], 0xFF);
    try expectMatchesLibjpegTurbo(allocator, &data);
}
