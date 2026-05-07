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

/// 4×4 12-bit grayscale lossless. precision 12, all 0x800.
const fixture_lossless_4x4_gray12 = @embedFile("fixtures/lossless_4x4_gray12.jpg");

test "decode 4x4 12-bit grayscale lossless (SOF3) JPEG" {
    const allocator = std.testing.allocator;
    var image = try jpegz.decode(allocator, fixture_lossless_4x4_gray12);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 4), image.width);
    try std.testing.expectEqual(@as(u32, 4), image.height);
    try std.testing.expectEqual(@as(u8, 1), image.channels);
    try std.testing.expectEqual(@as(u8, 12), image.bits_per_sample);
    try std.testing.expectEqual(jpegz.PixelLayout.grayscale, image.layout);
    // []u16 view: 4*4 = 16 samples, 32 bytes total.
    try std.testing.expectEqual(@as(usize, 32), image.pixels.len);
    const px = image.pixelsU16();
    try std.testing.expectEqual(@as(usize, 16), px.len);
    for (px) |s| try std.testing.expectEqual(@as(u16, 0x800), s);
}

/// 4×4 14-bit grayscale lossless (precision 14, all 0x2000). DNG raw
/// commonly uses 14-bit precision (Sony/Nikon/Fuji sensors); jpegz's
/// libjpeg-turbo path routes precision 13..16 through jpeg16_*. M1.4b
/// originally checked precision == exactly 16; tiffz's DNG handoff
/// flagged 14-bit as in-scope, so the precision check now accepts
/// any 1..16 and routes by range.
const fixture_lossless_4x4_gray14 = @embedFile("fixtures/lossless_4x4_gray14.jpg");

test "decode 4x4 14-bit grayscale lossless (SOF3) JPEG (DNG path)" {
    const allocator = std.testing.allocator;
    var image = try jpegz.decode(allocator, fixture_lossless_4x4_gray14);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 4), image.width);
    try std.testing.expectEqual(@as(u32, 4), image.height);
    try std.testing.expectEqual(@as(u8, 1), image.channels);
    try std.testing.expectEqual(@as(u8, 14), image.bits_per_sample);
    try std.testing.expectEqual(jpegz.PixelLayout.grayscale, image.layout);
    try std.testing.expectEqual(@as(usize, 32), image.pixels.len);
    const px = image.pixelsU16();
    try std.testing.expectEqual(@as(usize, 16), px.len);
    for (px) |s| try std.testing.expectEqual(@as(u16, 0x2000), s);
}

// ─────────────────────────────────────────────────────────────────────
// Tier 1 — wrapper coverage verification (per Peter, 2026-05-06).
// Each of these fixtures is a real-world JPEG variant our wrapper
// claims to handle but never had explicit test coverage. They
// double as Phase 2 oracle test cases (cleanroom impl must produce
// byte-equal output to libjpeg-turbo for these inputs).
// ─────────────────────────────────────────────────────────────────────

/// T1.1: arithmetic-coded baseline (SOF9). Patents expired in early
/// 2000s; libjpeg-turbo decodes it via the same scanline path.
const fixture_baseline_4x4_arithmetic = @embedFile("fixtures/baseline_4x4_arithmetic.jpg");

test "decode 4x4 arithmetic-coded baseline JPEG (SOF9)" {
    const allocator = std.testing.allocator;
    var image = try jpegz.decode(allocator, fixture_baseline_4x4_arithmetic);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 4), image.width);
    try std.testing.expectEqual(@as(u32, 4), image.height);
    try std.testing.expectEqual(@as(u8, 3), image.channels);
    try std.testing.expectEqual(@as(u8, 8), image.bits_per_sample);
    try std.testing.expectEqual(jpegz.PixelLayout.rgb, image.layout);
}

/// T1.2: baseline JPEG with restart markers (DRI=2 every 2 MCUs).
/// Tests entropy-stream RST handling.
const fixture_baseline_16x16_restart = @embedFile("fixtures/baseline_16x16_restart.jpg");

test "decode 16x16 baseline JPEG with restart markers (DRI=2)" {
    const allocator = std.testing.allocator;
    var image = try jpegz.decode(allocator, fixture_baseline_16x16_restart);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 16), image.width);
    try std.testing.expectEqual(@as(u32, 16), image.height);
    try std.testing.expectEqual(@as(u8, 3), image.channels);
    try std.testing.expectEqual(@as(usize, 16 * 16 * 3), image.pixels.len);
}

/// T1.3: 4×4 CMYK JPEG (4 components, Adobe APP14 colorspace = CMYK).
const fixture_baseline_4x4_cmyk = @embedFile("fixtures/baseline_4x4_cmyk.jpg");

test "decode 4x4 CMYK JPEG (Adobe APP14)" {
    const allocator = std.testing.allocator;
    var image = try jpegz.decode(allocator, fixture_baseline_4x4_cmyk);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 4), image.width);
    try std.testing.expectEqual(@as(u32, 4), image.height);
    try std.testing.expectEqual(@as(u8, 4), image.channels);
    try std.testing.expectEqual(@as(u8, 8), image.bits_per_sample);
    try std.testing.expectEqual(jpegz.PixelLayout.cmyk, image.layout);
    // source_color_space should be either .cmyk or .ycck (libjpeg-turbo
    // sets one based on the Adobe APP14 transform byte).
    const cs = image.source_color_space;
    try std.testing.expect(cs == .cmyk or cs == .ycck);
    try std.testing.expectEqual(@as(usize, 4 * 4 * 4), image.pixels.len);
}

/// T1.4: 4×4 grayscale baseline JPEG (1 component).
const fixture_baseline_4x4_grayscale = @embedFile("fixtures/baseline_4x4_grayscale.jpg");

test "decode 4x4 grayscale baseline JPEG (1 component)" {
    const allocator = std.testing.allocator;
    var image = try jpegz.decode(allocator, fixture_baseline_4x4_grayscale);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 4), image.width);
    try std.testing.expectEqual(@as(u32, 4), image.height);
    try std.testing.expectEqual(@as(u8, 1), image.channels);
    try std.testing.expectEqual(@as(u8, 8), image.bits_per_sample);
    try std.testing.expectEqual(jpegz.PixelLayout.grayscale, image.layout);
    try std.testing.expectEqual(jpegz.ColorSpace.grayscale, image.source_color_space);
    try std.testing.expectEqual(@as(usize, 4 * 4), image.pixels.len);
    // Input was uniform 0x80; quality=80 round-trip should keep all
    // pixels close to 0x80 (within ±20).
    for (image.pixels) |b| {
        const delta = @as(i16, @intCast(b)) - 0x80;
        try std.testing.expect(@abs(delta) < 20);
    }
}

/// T1.5a: 8×8 RGB JPEG with 4:2:0 chroma subsampling. libjpeg-turbo
/// upsamples to full-res RGB on output, so the consumer sees
/// `width=8 height=8 channels=3` regardless of internal subsampling.
const fixture_baseline_8x8_yuv420 = @embedFile("fixtures/baseline_8x8_yuv420.jpg");

test "decode 8x8 baseline JPEG with 4:2:0 chroma subsampling" {
    const allocator = std.testing.allocator;
    var image = try jpegz.decode(allocator, fixture_baseline_8x8_yuv420);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 8), image.width);
    try std.testing.expectEqual(@as(u32, 8), image.height);
    try std.testing.expectEqual(@as(u8, 3), image.channels);
    try std.testing.expectEqual(jpegz.PixelLayout.rgb, image.layout);
    try std.testing.expectEqual(@as(usize, 8 * 8 * 3), image.pixels.len);
}

/// T1.5b: 8×8 RGB JPEG with 4:2:2 chroma subsampling.
const fixture_baseline_8x8_yuv422 = @embedFile("fixtures/baseline_8x8_yuv422.jpg");

test "decode 8x8 baseline JPEG with 4:2:2 chroma subsampling" {
    const allocator = std.testing.allocator;
    var image = try jpegz.decode(allocator, fixture_baseline_8x8_yuv422);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 8), image.width);
    try std.testing.expectEqual(@as(u32, 8), image.height);
    try std.testing.expectEqual(@as(u8, 3), image.channels);
    try std.testing.expectEqual(jpegz.PixelLayout.rgb, image.layout);
}

/// 4×4 16-bit grayscale lossless. precision 16, all 0x8000.
const fixture_lossless_4x4_gray16 = @embedFile("fixtures/lossless_4x4_gray16.jpg");

test "decode 4x4 16-bit grayscale lossless (SOF3) JPEG" {
    const allocator = std.testing.allocator;
    var image = try jpegz.decode(allocator, fixture_lossless_4x4_gray16);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 4), image.width);
    try std.testing.expectEqual(@as(u32, 4), image.height);
    try std.testing.expectEqual(@as(u8, 1), image.channels);
    try std.testing.expectEqual(@as(u8, 16), image.bits_per_sample);
    try std.testing.expectEqual(jpegz.PixelLayout.grayscale, image.layout);
    try std.testing.expectEqual(@as(usize, 32), image.pixels.len);
    const px = image.pixelsU16();
    try std.testing.expectEqual(@as(usize, 16), px.len);
    for (px) |s| try std.testing.expectEqual(@as(u16, 0x8000), s);
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
