//! Totality over single-byte damage: for small files from every decoder
//! family, each byte set to several values and XORed with several masks
//! must validate and decode to a result or an error, never a crash.
//!
//! jpegz.decode is reached by consumers (tiffz and others) on untrusted
//! input without validate in front of it. On 2026-11-26, 3,000 mutants of
//! 12-bit progressive files crashed it 20 times: an SOS table selector past
//! 3 and an Se past 63 reached unchecked indexes.

const std = @import("std");
const jpegz = @import("jpegz");

const Fixture = struct { name: []const u8, data: []const u8 };

const fixtures = [_]Fixture{
    .{ .name = "progressive gray 12-bit", .data = @embedFile("fixtures/progressive_8x8_gray12.jpg") },
    .{ .name = "progressive rgb", .data = @embedFile("fixtures/progressive_8x8_rgb.jpg") },
    .{ .name = "progressive rgb 12-bit 4:2:0", .data = @embedFile("fixtures/progressive_16x16_rgb12_420.jpg") },
    .{ .name = "progressive restarts", .data = @embedFile("fixtures/progressive_32x32_gray_dri.jpg") },
    .{ .name = "arithmetic progressive", .data = @embedFile("fixtures/arith_progressive_8x8_gray.jpg") },
    .{ .name = "arithmetic baseline", .data = @embedFile("fixtures/arith_baseline_8x8_gray.jpg") },
    .{ .name = "arithmetic baseline 4:2:2", .data = @embedFile("fixtures/arith_baseline_16x16_rgb_422.jpg") },
    .{ .name = "lossless gray", .data = @embedFile("fixtures/lossless_4x4_gray8.jpg") },
    .{ .name = "lossless rgb", .data = @embedFile("fixtures/lossless_4x4_rgb_pred1.jpg") },
    .{ .name = "baseline cmyk", .data = @embedFile("fixtures/baseline_4x4_cmyk.jpg") },
    .{ .name = "sequential 3-scan", .data = @embedFile("fixtures/seq_16x16_3scan.jpg") },
    .{ .name = "baseline 4:2:0", .data = @embedFile("fixtures/baseline_8x8_yuv420.jpg") },
    .{ .name = "jpeg-ls gray", .data = @embedFile("fixtures/jpegls_4x4_gray8.jls") },
};

// Boundary values for header fields, plus masks that flip nibbles and the
// sign bit wherever they land (entropy data, lengths, selectors).
const set_values = [_]u8{ 0x00, 0x0F, 0x3F, 0xF0, 0xFF };
const xor_masks = [_]u8{ 0x01, 0x10, 0x80 };

fn mutants(fixture: Fixture, context: anytype, comptime check: fn (@TypeOf(context), []const u8) anyerror!void) !void {
    const buf = try std.testing.allocator.alloc(u8, fixture.data.len);
    defer std.testing.allocator.free(buf);
    for (0..fixture.data.len) |off| {
        for (set_values) |v| {
            if (fixture.data[off] == v) continue;
            @memcpy(buf, fixture.data);
            buf[off] = v;
            try check(context, buf);
        }
        for (xor_masks) |m| {
            @memcpy(buf, fixture.data);
            buf[off] ^= m;
            try check(context, buf);
        }
    }
}

fn decodeOrError(_: void, data: []const u8) anyerror!void {
    // Any error return is a legitimate outcome; only a crash fails.
    var image = jpegz.decode(std.testing.allocator, data) catch return;
    image.deinit(std.testing.allocator);
}

fn validateOrError(_: void, data: []const u8) anyerror!void {
    var report = jpegz.validate(std.testing.allocator, data) catch |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
        return;
    };
    report.deinit(std.testing.allocator);
}

test "decode is total over single-byte damage to a file from every decoder family" {
    for (fixtures) |fixture| try mutants(fixture, {}, decodeOrError);
}

test "validate is total over single-byte damage to a file from every decoder family" {
    for (fixtures) |fixture| try mutants(fixture, {}, validateOrError);
}
