//! M1.6 — JPEG 2000 decode wrap (openjpeg).
//!
//! Tests start TDD-red because `jpegz.jpeg2000.decode` is still a stub
//! returning `error.NotImplemented`. They go green when the openjpeg
//! wrapper lands in `src/ffi/openjpeg_wrapper.zig`.

const std = @import("std");
const jpegz = @import("jpegz");

/// 8×8 RGB JP2 file (lossy, 9/7 wavelet, 3 resolution levels).
/// Generated with `opj_compress -n 3 -r 5` from a uniform-color PPM.
const fixture_jp2_8x8_rgb = @embedFile("fixtures/jp2_8x8_rgb.jp2");

test "jpeg2000.decode 8x8 RGB JP2 produces an 8x8 RGB Image" {
    const allocator = std.testing.allocator;

    var image = try jpegz.jpeg2000.decode(allocator, fixture_jp2_8x8_rgb);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 8), image.width);
    try std.testing.expectEqual(@as(u32, 8), image.height);
    try std.testing.expectEqual(@as(u8, 3), image.channels);
    try std.testing.expectEqual(@as(u8, 8), image.bits_per_sample);
    try std.testing.expectEqual(jpegz.PixelLayout.rgb, image.layout);
    try std.testing.expectEqual(@as(usize, 8 * 8 * 3), image.pixels.len);

    // Source was a uniform color (R=0x80, G=0x40, B=0xA0). Lossy at -r 5
    // is mild compression; pixel (0,0) should be close to input.
    const r = image.pixels[0];
    const g = image.pixels[1];
    const b = image.pixels[2];
    try std.testing.expect(@abs(@as(i16, r) - 0x80) < 16);
    try std.testing.expect(@abs(@as(i16, g) - 0x40) < 16);
    try std.testing.expect(@abs(@as(i16, b) - 0xA0) < 16);
}

test "jpeg2000.decode rejects empty input" {
    const empty: []const u8 = &[_]u8{};
    try std.testing.expectError(
        error.TruncatedStream,
        jpegz.jpeg2000.decode(std.testing.allocator, empty),
    );
}

test "jpeg2000.decode rejects non-JP2 input" {
    const garbage = "this is not a JPEG 2000 file at all";
    try std.testing.expectError(
        error.InvalidJp2Codestream,
        jpegz.jpeg2000.decode(std.testing.allocator, garbage),
    );
}
