//! Allocation failure: every refused allocation, at every index, must come
//! back as error.OutOfMemory from validate and decode, with nothing leaked
//! and nothing freed twice (validate, 2026-11-26: a progressive decode
//! freed its coefficient buffers twice when a later allocation failed).

const std = @import("std");
const jpegz = @import("jpegz");

const Fixture = struct { name: []const u8, data: []const u8 };

// One or more files per decoder family and per allocation-heavy feature.
const fixtures = [_]Fixture{
    .{ .name = "progressive gray", .data = @embedFile("fixtures/progressive_8x8_gray.jpg") },
    .{ .name = "progressive rgb", .data = @embedFile("fixtures/progressive_8x8_rgb.jpg") },
    .{ .name = "progressive 12-bit 4:2:0", .data = @embedFile("fixtures/progressive_16x16_rgb12_420.jpg") },
    .{ .name = "progressive restarts", .data = @embedFile("fixtures/progressive_32x32_gray_dri.jpg") },
    .{ .name = "progressive restarts 4:2:0", .data = @embedFile("fixtures/huffman_restart_32x32_rgb420_progressive_1b.jpg") },
    .{ .name = "baseline 4:2:0", .data = @embedFile("fixtures/baseline_16x16_rgb_420.jpg") },
    .{ .name = "baseline 12-bit", .data = @embedFile("fixtures/baseline_16x16_rgb12_422.jpg") },
    .{ .name = "baseline cmyk", .data = @embedFile("fixtures/baseline_4x4_cmyk.jpg") },
    .{ .name = "ycck subsampled", .data = @embedFile("fixtures/cmyk_16x16_ycck_subsampled.jpg") },
    .{ .name = "sequential 3-scan", .data = @embedFile("fixtures/seq_16x16_3scan.jpg") },
    .{ .name = "mjpeg without DHT", .data = @embedFile("fixtures/historic_a3_mjpeg_no_dht.jpg") },
    .{ .name = "go 1.0 Se=0", .data = @embedFile("fixtures/go1_sos_zero_se_16x16.jpg") },
    .{ .name = "trailing data", .data = @embedFile("fixtures/baseline_4x4_with_trailing.jpg") },
    .{ .name = "arithmetic baseline", .data = @embedFile("fixtures/arith_baseline_16x16_rgb_420.jpg") },
    .{ .name = "arithmetic progressive", .data = @embedFile("fixtures/arith_progressive_16x16_rgb_420.jpg") },
    .{ .name = "arithmetic restarts", .data = @embedFile("fixtures/arith_restart_32x32_rgb420_progressive_1b.jpg") },
    .{ .name = "lossless gray", .data = @embedFile("fixtures/lossless_16x16_gray_dri.jpg") },
    .{ .name = "lossless rgb", .data = @embedFile("fixtures/lossless_16x16_rgb_p8_pt2_sel7_rst1.jpg") },
    .{ .name = "lossless 4-component", .data = @embedFile("fixtures/lossless_5x4_4comp_p12_pred7.jpg") },
    .{ .name = "jpeg-ls gray", .data = @embedFile("fixtures/jpegls_8x8_gray8_near2.jls") },
    .{ .name = "jpeg-ls rgb", .data = @embedFile("fixtures/jpegls_4x4_rgb8_ilv1.jls") },
};

fn validateOnce(allocator: std.mem.Allocator, data: []const u8) !void {
    var report = try jpegz.validate(allocator, data);
    report.deinit(allocator);
}

fn decodeOnce(allocator: std.mem.Allocator, data: []const u8) !void {
    var image = jpegz.decode(allocator, data) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Formats this build does not decode are not allocation failures.
        error.NotImplemented => return,
        else => return err,
    };
    image.deinit(allocator);
}

fn sweep(comptime f: anytype, fixture: Fixture) !void {
    std.testing.checkAllAllocationFailures(std.testing.allocator, f, .{fixture.data}) catch |err| {
        std.debug.print("allocation-failure sweep failed for {s}: {t}\n", .{ fixture.name, err });
        return err;
    };
}

test "validate returns OutOfMemory, leaks nothing and frees nothing twice at every refused allocation" {
    for (fixtures) |fixture| try sweep(validateOnce, fixture);
}

test "decode returns OutOfMemory, leaks nothing and frees nothing twice at every refused allocation" {
    for (fixtures) |fixture| try sweep(decodeOnce, fixture);
}
