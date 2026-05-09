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

/// 4×4 12-bit grayscale baseline DCT (SOF1 extended sequential, NOT
/// SOF0 baseline — T.81 SOF0 is 8-bit-only). cjpeg `-baseline
/// -precision 12` emits this. Goes through libjpeg-turbo's
/// `jpeg12_read_scanlines` path via M1.4b's precision-range
/// dispatch in the wrapper. Cleanroom (SOF0-only) returns
/// NotImplemented and falls back.
const fixture_baseline_4x4_gray12_dct = @embedFile("fixtures/baseline_4x4_gray12_dct.jpg");

test "decode 4x4 12-bit grayscale baseline DCT (SOF1)" {
    const allocator = std.testing.allocator;
    var image = try jpegz.decode(allocator, fixture_baseline_4x4_gray12_dct);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 4), image.width);
    try std.testing.expectEqual(@as(u32, 4), image.height);
    try std.testing.expectEqual(@as(u8, 1), image.channels);
    try std.testing.expectEqual(@as(u8, 12), image.bits_per_sample);
    try std.testing.expectEqual(jpegz.PixelLayout.grayscale, image.layout);
    try std.testing.expectEqual(@as(usize, 32), image.pixels.len); // 4*4*2 (u16-aliased)
    // Source: uniform 0x0800 (mid-range 12-bit). Lossy DCT round-trip
    // at default quality keeps values close. Tight ±200 (out of 4095)
    // tolerance.
    const px = image.pixelsU16();
    try std.testing.expectEqual(@as(usize, 16), px.len);
    for (px) |s| {
        const delta = @as(i32, s) - 0x800;
        try std.testing.expect(@abs(delta) < 200);
    }
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

// ─────────────────────────────────────────────────────────────────────
// M2.1 cleanroom — 3-component RGB without subsampling (4:4:4).
// First fixture exercising the multi-component MCU loop in cleanroom.
// ─────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────
// M2.1c — real-world failure-mode reproducers. Each fixture below
// reproduces a class of CLEAN-ERR seen in the cleanroom-diff run
// against Peter's 4,125-JPEG corpus. Synthetic stand-ins generated
// via cjpeg with the matching encoder flags (per CLAUDE.md: do not
// commit Peter's actual corpus files; reproduce shape with cjpeg).
// ─────────────────────────────────────────────────────────────────────

/// 128×128 RGB baseline 4:4:4 with restart markers every 4 MCUs.
/// 256 MCUs total → 63 RSTm markers cycling 0..7. Reproduces the
/// `InvalidMarker` failure mode hit by petethumb128x128.jpg in the
/// real corpus. cjpeg `-sample 1x1 -restart 4B`.
const fixture_baseline_128x128_dri4 = @embedFile("fixtures/baseline_128x128_dri4.jpg");

test "decode 128x128 4:4:4 RGB baseline with DRI=4 (RST every 4 MCUs)" {
    const allocator = std.testing.allocator;
    var image = try jpegz.decode(allocator, fixture_baseline_128x128_dri4);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 128), image.width);
    try std.testing.expectEqual(@as(u32, 128), image.height);
    try std.testing.expectEqual(@as(u8, 3), image.channels);
    try std.testing.expectEqual(jpegz.PixelLayout.rgb, image.layout);
    try std.testing.expectEqual(@as(usize, 128 * 128 * 3), image.pixels.len);
    // Source: pixel(x, y) = ((2x)%256, (2y)%256, (x+y)%256). Lossy q=80
    // round-trip stays within ±25 per channel against that pattern.
    var y: u32 = 0;
    while (y < 128) : (y += 1) {
        var x: u32 = 0;
        while (x < 128) : (x += 1) {
            const i = (y * 128 + x) * 3;
            try std.testing.expect(@abs(@as(i16, image.pixels[i + 0]) - @as(i16, @intCast((x * 2) % 256))) < 25);
            try std.testing.expect(@abs(@as(i16, image.pixels[i + 1]) - @as(i16, @intCast((y * 2) % 256))) < 25);
            try std.testing.expect(@abs(@as(i16, image.pixels[i + 2]) - @as(i16, @intCast((x + y) % 256))) < 25);
        }
    }
}

/// 4×4 RGB baseline with all components at 1×1 sampling (no subsampling).
/// cjpeg's default produces 4:2:0; this fixture used `-sample 1x1`.
const fixture_baseline_4x4_rgb_444 = @embedFile("fixtures/baseline_4x4_rgb_444.jpg");

test "decode 4x4 RGB baseline 4:4:4 (no subsampling) — cleanroom path" {
    const allocator = std.testing.allocator;
    var image = try jpegz.decode(allocator, fixture_baseline_4x4_rgb_444);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 4), image.width);
    try std.testing.expectEqual(@as(u32, 4), image.height);
    try std.testing.expectEqual(@as(u8, 3), image.channels);
    try std.testing.expectEqual(@as(u8, 8), image.bits_per_sample);
    try std.testing.expectEqual(jpegz.PixelLayout.rgb, image.layout);
    try std.testing.expectEqual(jpegz.ColorSpace.ycbcr, image.source_color_space);
    try std.testing.expectEqual(@as(usize, 4 * 4 * 3), image.pixels.len);
    // Source: uniform R=0x80, G=0x40, B=0xA0. Quality=80 lossy round-trip;
    // every output pixel should land within ±20 per channel.
    var i: usize = 0;
    while (i < image.pixels.len) : (i += 3) {
        try std.testing.expect(@abs(@as(i16, image.pixels[i + 0]) - 0x80) < 20);
        try std.testing.expect(@abs(@as(i16, image.pixels[i + 1]) - 0x40) < 20);
        try std.testing.expect(@abs(@as(i16, image.pixels[i + 2]) - 0xA0) < 20);
    }
}

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
    // Source: uniform R=0x80 G=0x40 B=0xA0; quality=80 lossy. Every
    // pixel within ±25 per channel — proves restart-marker handling
    // is correct (a missed/mishandled RST realigns prev_dc and the
    // pixels go wildly off).
    var i: usize = 0;
    while (i < image.pixels.len) : (i += 3) {
        try std.testing.expect(@abs(@as(i16, image.pixels[i + 0]) - 0x80) < 25);
        try std.testing.expect(@abs(@as(i16, image.pixels[i + 1]) - 0x40) < 25);
        try std.testing.expect(@abs(@as(i16, image.pixels[i + 2]) - 0xA0) < 25);
    }
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
    // Source: uniform R=0x80 G=0x40 B=0xA0; lossy at quality=80 with
    // 4:2:0 chroma sub. Every pixel within ±25 per channel.
    var i: usize = 0;
    while (i < image.pixels.len) : (i += 3) {
        try std.testing.expect(@abs(@as(i16, image.pixels[i + 0]) - 0x80) < 25);
        try std.testing.expect(@abs(@as(i16, image.pixels[i + 1]) - 0x40) < 25);
        try std.testing.expect(@abs(@as(i16, image.pixels[i + 2]) - 0xA0) < 25);
    }
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
    var i: usize = 0;
    while (i < image.pixels.len) : (i += 3) {
        try std.testing.expect(@abs(@as(i16, image.pixels[i + 0]) - 0x80) < 25);
        try std.testing.expect(@abs(@as(i16, image.pixels[i + 1]) - 0x40) < 25);
        try std.testing.expect(@abs(@as(i16, image.pixels[i + 2]) - 0xA0) < 25);
    }
}

test "islow IDCT + fixed-point YCbCr matches libjpeg-turbo on 4:2:0 (max delta ≤ 2)" {
    // After replacing the float DCT-direct IDCT with libjpeg-turbo's
    // islow algorithm and the f32 YCbCr→RGB conversion with the fixed-point
    // version (jdcolor.c), max divergence vs. the wrapper drops to 2 LSB
    // sub-pixel rounding noise across the entire corpus. Asserting strict
    // byte-equality is too tight (1 LSB ties differ by integer-vs-float
    // rounding edge cases) — assert max-delta ≤ 2 instead.
    const allocator = std.testing.allocator;
    var cleanroom = try jpegz.internal.cleanroomDecode(allocator, fixture_baseline_8x8_yuv420);
    defer cleanroom.deinit(allocator);
    var wrapper = try jpegz.internal.wrapperDecode(allocator, fixture_baseline_8x8_yuv420);
    defer wrapper.deinit(allocator);
    try std.testing.expectEqual(wrapper.width, cleanroom.width);
    try std.testing.expectEqual(wrapper.height, cleanroom.height);
    var max_delta: u8 = 0;
    for (cleanroom.pixels, wrapper.pixels) |a, b| {
        const d: u8 = @intCast(@abs(@as(i32, a) - @as(i32, b)));
        if (d > max_delta) max_delta = d;
    }
    try std.testing.expect(max_delta <= 2);
}

test "decodeWithOptions threading API: default options match decode()" {
    // M2.1d threading-control surface: jpegz.decode(..) and
    // jpegz.decodeWithOptions(.., .{}) must produce byte-identical
    // results. The options struct is additive; default `threads = 1`
    // is the same path the original `decode` always took.
    const allocator = std.testing.allocator;
    var a = try jpegz.decode(allocator, fixture_baseline_2x2_rgb);
    defer a.deinit(allocator);
    var b = try jpegz.decodeWithOptions(allocator, fixture_baseline_2x2_rgb, .{});
    defer b.deinit(allocator);
    try std.testing.expectEqual(a.width, b.width);
    try std.testing.expectEqual(a.height, b.height);
    try std.testing.expectEqual(a.channels, b.channels);
    try std.testing.expectEqualSlices(u8, a.pixels, b.pixels);
}

test "decodeWithOptions threading API: threads > 1 currently no-op (parallelism is M2.1d follow-up)" {
    // Surface contract: `threads = N` for any N is accepted today and
    // produces correct output. Parallel execution lands later; for
    // now the value is recorded but not acted on. This test guards
    // against regressions where someone wires `threads` through and
    // accidentally breaks the contract that "any value still decodes".
    const allocator = std.testing.allocator;
    var t1 = try jpegz.decodeWithOptions(allocator, fixture_baseline_2x2_rgb, .{ .threads = 1 });
    defer t1.deinit(allocator);
    var t4 = try jpegz.decodeWithOptions(allocator, fixture_baseline_2x2_rgb, .{ .threads = 4 });
    defer t4.deinit(allocator);
    var auto = try jpegz.decodeWithOptions(allocator, fixture_baseline_2x2_rgb, .{ .threads = 0 });
    defer auto.deinit(allocator);
    try std.testing.expectEqualSlices(u8, t1.pixels, t4.pixels);
    try std.testing.expectEqualSlices(u8, t1.pixels, auto.pixels);
}

test "fancy upsampling matches libjpeg-turbo on 4:2:0 (cleanroom == wrapper)" {
    // Tiny 2×2 4:2:0 fixture — chroma plane is 1×1 active in an 8×8
    // MCU-padded plane. Without active-frame boundary clamping, fancy
    // upsampling would pull garbage from padded chroma into visible
    // pixels (cleanroom showed (1,1) as 229,255,231 vs wrapper's
    // 247,246,251). After the fix every output pixel matches the
    // libjpeg-turbo wrapper byte-for-byte.
    const allocator = std.testing.allocator;
    var cleanroom = try jpegz.internal.cleanroomDecode(allocator, fixture_baseline_2x2_rgb);
    defer cleanroom.deinit(allocator);
    var wrapper = try jpegz.internal.wrapperDecode(allocator, fixture_baseline_2x2_rgb);
    defer wrapper.deinit(allocator);
    try std.testing.expectEqual(wrapper.width, cleanroom.width);
    try std.testing.expectEqual(wrapper.height, cleanroom.height);
    try std.testing.expectEqualSlices(u8, wrapper.pixels, cleanroom.pixels);
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
    // Source: uniform R=0xFF G=0x80 B=0x40; quality=85 progressive. ±25.
    var i: usize = 0;
    while (i < image.pixels.len) : (i += 3) {
        try std.testing.expect(@abs(@as(i16, image.pixels[i + 0]) - 0xFF) < 25);
        try std.testing.expect(@abs(@as(i16, image.pixels[i + 1]) - 0x80) < 25);
        try std.testing.expect(@abs(@as(i16, image.pixels[i + 2]) - 0x40) < 25);
    }
}

/// 8×8 grayscale progressive — simplest progressive case (1 component,
/// 6 scans: DC first + AC[1..5] + AC[6..63] + AC refine + DC refine + AC refine).
const fixture_progressive_8x8_gray = @embedFile("fixtures/progressive_8x8_gray.jpg");

test "decode 8x8 progressive grayscale (currently wrapper; cleanroom WIP)" {
    const allocator = std.testing.allocator;
    var image = try jpegz.decode(allocator, fixture_progressive_8x8_gray);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 8), image.width);
    try std.testing.expectEqual(@as(u32, 8), image.height);
    try std.testing.expectEqual(@as(u8, 1), image.channels);
    try std.testing.expectEqual(@as(u8, 8), image.bits_per_sample);
    try std.testing.expectEqual(jpegz.PixelLayout.grayscale, image.layout);
    try std.testing.expectEqual(@as(usize, 64), image.pixels.len);
    // Input was uniform 0x80; quality=85 progressive should round-trip
    // each pixel within ±15.
    for (image.pixels) |b| {
        try std.testing.expect(@abs(@as(i16, b) - 0x80) < 15);
    }
}

// ─────────────────────────────────────────────────────────────────────
// M2.2 — progressive cleanroom validation (gap-closer #1).
// These tests exercise `internal.progressiveDecode` directly, separate
// from the public dispatcher. They go green when the SOF2 code path in
// `src/decode/progressive.zig` matches libjpeg-turbo wrapper output
// closely enough to wire into dispatch.
// ─────────────────────────────────────────────────────────────────────

test "M2.2: progressive cleanroom decodes 8x8 grayscale fixture" {
    const allocator = std.testing.allocator;
    var cleanroom = try jpegz.internal.progressiveDecode(allocator, fixture_progressive_8x8_gray);
    defer cleanroom.deinit(allocator);
    var wrapper = try jpegz.internal.wrapperDecode(allocator, fixture_progressive_8x8_gray);
    defer wrapper.deinit(allocator);

    try std.testing.expectEqual(wrapper.width, cleanroom.width);
    try std.testing.expectEqual(wrapper.height, cleanroom.height);
    try std.testing.expectEqual(wrapper.channels, cleanroom.channels);
    try std.testing.expectEqual(wrapper.pixels.len, cleanroom.pixels.len);

    // ≤2 LSB tolerance, the same threshold baseline cleanroom uses
    // against wrapper output (sub-pixel rounding from float vs fixed-
    // point IDCT/color rounding).
    var max_delta: u8 = 0;
    for (cleanroom.pixels, wrapper.pixels) |a, b| {
        const d: u8 = @intCast(@abs(@as(i32, a) - @as(i32, b)));
        if (d > max_delta) max_delta = d;
    }
    try std.testing.expect(max_delta <= 2);
}

/// 2×2 RGB SOF1 (extended sequential, 8-bit precision) — generated by
/// patching `baseline_2x2_rgb.jpg`'s SOF0 (0xFF 0xC0) marker to SOF1
/// (0xFF 0xC1). For 8-bit precision the bitstream is identical to
/// SOF0; only the marker differs. T.81 §A.4.2 / F.1.1 requires the
/// decoder to accept SOF1 the same as SOF0 at 8-bit precision.
const fixture_extended_2x2_rgb_sof1 = @embedFile("fixtures/extended_2x2_rgb_sof1.jpg");

test "M2.3: extended sequential 8-bit SOF1 cleanroom decode matches wrapper" {
    const allocator = std.testing.allocator;
    var cleanroom = try jpegz.internal.cleanroomDecode(allocator, fixture_extended_2x2_rgb_sof1);
    defer cleanroom.deinit(allocator);
    var wrapper = try jpegz.internal.wrapperDecode(allocator, fixture_extended_2x2_rgb_sof1);
    defer wrapper.deinit(allocator);

    try std.testing.expectEqual(wrapper.width, cleanroom.width);
    try std.testing.expectEqual(wrapper.height, cleanroom.height);
    try std.testing.expectEqual(wrapper.channels, cleanroom.channels);
    try std.testing.expectEqualSlices(u8, wrapper.pixels, cleanroom.pixels);
}

test "M2.2: progressive cleanroom decodes 8x8 RGB fixture" {
    const allocator = std.testing.allocator;
    var cleanroom = try jpegz.internal.progressiveDecode(allocator, fixture_progressive_8x8);
    defer cleanroom.deinit(allocator);
    var wrapper = try jpegz.internal.wrapperDecode(allocator, fixture_progressive_8x8);
    defer wrapper.deinit(allocator);

    try std.testing.expectEqual(wrapper.width, cleanroom.width);
    try std.testing.expectEqual(wrapper.height, cleanroom.height);
    try std.testing.expectEqual(wrapper.channels, cleanroom.channels);
    try std.testing.expectEqual(wrapper.pixels.len, cleanroom.pixels.len);

    var max_delta: u8 = 0;
    for (cleanroom.pixels, wrapper.pixels) |a, b| {
        const d: u8 = @intCast(@abs(@as(i32, a) - @as(i32, b)));
        if (d > max_delta) max_delta = d;
    }
    try std.testing.expect(max_delta <= 2);
}
