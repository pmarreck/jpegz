//! M1.3 — baseline + progressive wrap (libjpeg-turbo).
//!
//! TDD-red marker: these tests fail today because `jpegz.decode` returns
//! `error.NotImplemented`. They go green when the libjpeg-turbo wrapper
//! lands in `src/ffi/libjpeg_wrapper.zig`.

const std = @import("std");
const jpegz = @import("jpegz");

/// 2×2 RGB baseline JPEG (Y'CbCr internally, decoded to RGB by libjpeg-turbo).
/// Generated via `cjpeg -quality 90 -baseline` from a 2×2 PPM with
/// red/green/blue/white pixels. Roughly 690 bytes.
const fixture_baseline_2x2_rgb = @embedFile("fixtures/baseline_2x2_rgb.jpg");

test "decode 2x2 baseline RGB JPEG produces a 2x2 RGB Image" {
    const allocator = std.testing.allocator;

    var image = try jpegz.decode(allocator, fixture_baseline_2x2_rgb);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 2), image.width);
    try std.testing.expectEqual(@as(u32, 2), image.height);
    try std.testing.expectEqual(@as(u8, 3), image.channels);
    try std.testing.expectEqual(@as(u8, 8), image.bits_per_sample);
    try std.testing.expectEqual(jpegz.PixelLayout.rgb, image.layout);
    // Source was YCbCr (libjpeg's default for an encoded RGB JFIF).
    try std.testing.expectEqual(jpegz.ColorSpace.ycbcr, image.source_color_space);

    // Pixel buffer size = 2 * 2 * 3 = 12 bytes.
    try std.testing.expectEqual(@as(usize, 12), image.pixels.len);
    try std.testing.expectEqual(@as(usize, 6), image.rowStride());

    // Sanity check: at quality=90, pixel (1,1) was input 0xFFFFFF (white);
    // round-trip should keep it >= 240 in every channel.
    const px11 = image.pixels[1 * image.rowStride() + 1 * 3 ..][0..3];
    try std.testing.expect(px11[0] >= 240);
    try std.testing.expect(px11[1] >= 240);
    try std.testing.expect(px11[2] >= 240);
}

test "decode rejects empty input" {
    const empty: []const u8 = &[_]u8{};
    try std.testing.expectError(
        error.TruncatedStream,
        jpegz.decode(std.testing.allocator, empty),
    );
}

test "decode rejects non-JPEG input" {
    const garbage = "this is not a JPEG file at all";
    try std.testing.expectError(
        error.InvalidMarker,
        jpegz.decode(std.testing.allocator, garbage),
    );
}

/// 8×8 RGB progressive JPEG (SOF2). libjpeg-turbo decodes both
/// baseline and progressive through the same `decode` entry point —
/// this test confirms our wrapper doesn't accidentally restrict by SOF.
const fixture_progressive_8x8 = @embedFile("fixtures/progressive_8x8_rgb.jpg");

/// 4×4 8-bit grayscale lossless (SOF3) JPEG (predictor=1, all 0x80).
/// libjpeg-turbo 3.1+ supports lossless decoding via the same
/// `jpeg_read_scanlines` API used for SOF0/SOF1/SOF2 — for 8-bit
/// precision. 12/16-bit lossless requires `jpeg12_/jpeg16_` APIs and
/// is the M1.4b follow-up.
const fixture_lossless_4x4_gray8 = @embedFile("fixtures/lossless_4x4_gray8.jpg");

test "decode 4x4 8-bit grayscale lossless (SOF3) JPEG" {
    const allocator = std.testing.allocator;

    var image = try jpegz.decode(allocator, fixture_lossless_4x4_gray8);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 4), image.width);
    try std.testing.expectEqual(@as(u32, 4), image.height);
    try std.testing.expectEqual(@as(u8, 1), image.channels);
    try std.testing.expectEqual(@as(u8, 8), image.bits_per_sample);
    try std.testing.expectEqual(jpegz.PixelLayout.grayscale, image.layout);
    try std.testing.expectEqual(jpegz.ColorSpace.grayscale, image.source_color_space);
    try std.testing.expectEqual(@as(usize, 16), image.pixels.len);

    // Lossless round-trip: every byte should be exactly 0x80 (the input).
    for (image.pixels) |b| {
        try std.testing.expectEqual(@as(u8, 0x80), b);
    }
}

test "decode 8x8 progressive RGB JPEG" {
    const allocator = std.testing.allocator;

    var image = try jpegz.decode(allocator, fixture_progressive_8x8);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 8), image.width);
    try std.testing.expectEqual(@as(u32, 8), image.height);
    try std.testing.expectEqual(@as(u8, 3), image.channels);
    try std.testing.expectEqual(@as(u8, 8), image.bits_per_sample);
    try std.testing.expectEqual(jpegz.PixelLayout.rgb, image.layout);
    try std.testing.expectEqual(@as(usize, 8 * 8 * 3), image.pixels.len);
}
