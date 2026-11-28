//! decode tests, part 1 (split from decode.zig to keep files small).

const std = @import("std");
const jpegz = @import("jpegz");
const h1 = @import("decode_helpers_1.zig");
const h2 = @import("decode_helpers_2.zig");
const fixture_baseline_2x2_rgb = h1.fixture_baseline_2x2_rgb;
const decodeAllocationControl = h1.decodeAllocationControl;
const fixture_progressive_8x8 = h1.fixture_progressive_8x8;
const fixture_lossless_4x4_gray8 = h1.fixture_lossless_4x4_gray8;
const fixture_lossless_4x4_gray12 = h1.fixture_lossless_4x4_gray12;
const fixture_baseline_4x4_gray12_dct = h1.fixture_baseline_4x4_gray12_dct;
const fixture_lossless_4x4_gray14 = h1.fixture_lossless_4x4_gray14;
const fixture_baseline_128x128_dri4 = h1.fixture_baseline_128x128_dri4;
const fixture_baseline_4x4_rgb_444 = h1.fixture_baseline_4x4_rgb_444;
const fixture_baseline_4x4_arithmetic = h1.fixture_baseline_4x4_arithmetic;
const fixture_baseline_16x16_restart = h1.fixture_baseline_16x16_restart;
const fixture_baseline_4x4_cmyk = h1.fixture_baseline_4x4_cmyk;
const fixture_cmyk_16x16_ycck_sub = h1.fixture_cmyk_16x16_ycck_sub;
const fixture_baseline_4x4_grayscale = h1.fixture_baseline_4x4_grayscale;
const fixture_baseline_8x8_yuv420 = h1.fixture_baseline_8x8_yuv420;
const fixture_baseline_8x8_yuv422 = h1.fixture_baseline_8x8_yuv422;
const fixture_mode2_spliced = h1.fixture_mode2_spliced;
const fixture_lossless_4x4_gray16 = h1.fixture_lossless_4x4_gray16;
const fixture_lossless_16x16_gray_dri = h1.fixture_lossless_16x16_gray_dri;
const fixture_progressive_8x8_gray = h1.fixture_progressive_8x8_gray;
const fixture_extended_2x2_rgb_sof1 = h1.fixture_extended_2x2_rgb_sof1;
const fixture_lossless_gradient_pred1 = h1.fixture_lossless_gradient_pred1;
const fixture_lossless_gradient_pred2 = h1.fixture_lossless_gradient_pred2;
const fixture_lossless_gradient_pred3 = h1.fixture_lossless_gradient_pred3;
const fixture_lossless_gradient_pred4 = h1.fixture_lossless_gradient_pred4;
const fixture_lossless_gradient_pred5 = h1.fixture_lossless_gradient_pred5;
const fixture_lossless_gradient_pred6 = h1.fixture_lossless_gradient_pred6;
const fixture_lossless_gradient_pred7 = h1.fixture_lossless_gradient_pred7;
const fixture_progressive_32x32_dri = h1.fixture_progressive_32x32_dri;
const fixture_arith_baseline_16x16_rgb_444 = h1.fixture_arith_baseline_16x16_rgb_444;
const fixture_arith_baseline_16x16_rgb_420 = h1.fixture_arith_baseline_16x16_rgb_420;
const fixture_arith_baseline_16x16_rgb_422 = h1.fixture_arith_baseline_16x16_rgb_422;
const fixture_arith_baseline_16x16_rgb_440 = h1.fixture_arith_baseline_16x16_rgb_440;
const fixture_arith_baseline_8x8_gray = h1.fixture_arith_baseline_8x8_gray;
const fixture_arith_restart_gray = h1.fixture_arith_restart_gray;
const fixture_arith_restart_rgb420 = h1.fixture_arith_restart_rgb420;
const fixture_arith_restart_rgb420_progressive = h1.fixture_arith_restart_rgb420_progressive;
const fixture_jpegls_4x4_gray8 = h1.fixture_jpegls_4x4_gray8;
const fixture_jpegls_4x4_gray16 = h1.fixture_jpegls_4x4_gray16;
const fixture_jpegls_4x4_rgb8 = h1.fixture_jpegls_4x4_rgb8;
const fixture_jpegls_4x4_rgb16 = h1.fixture_jpegls_4x4_rgb16;
const fixture_jpegls_8x8_gray8_near2 = h1.fixture_jpegls_8x8_gray8_near2;
const fixture_jpegls_8x8_gray8_near2_raw = h1.fixture_jpegls_8x8_gray8_near2_raw;
const jpegls_conformance = h1.jpegls_conformance;
const pgmSamples = h1.pgmSamples;
const onlyFail = h1.onlyFail;
const dumpFindings = h1.dumpFindings;
const map_src = h1.map_src;
const mapSample = h1.mapSample;
const expectMapped = h1.expectMapped;
const withTables = h1.withTables;
const lseMapping = h1.lseMapping;
const maxvalDerivation = h1.maxvalDerivation;
const MaxvalStream = h1.MaxvalStream;
const maxvalPack = h1.maxvalPack;
const bothCodings = h1.bothCodings;
const fixture_arith_progressive_16x16_rgb_444 = h1.fixture_arith_progressive_16x16_rgb_444;
const fixture_arith_progressive_16x16_rgb_420 = h1.fixture_arith_progressive_16x16_rgb_420;
const fixture_arith_progressive_16x16_rgb_422 = h1.fixture_arith_progressive_16x16_rgb_422;
const fixture_arith_progressive_16x16_rgb_440 = h1.fixture_arith_progressive_16x16_rgb_440;
const fixture_arith_progressive_8x8_gray = h1.fixture_arith_progressive_8x8_gray;
const ArithEnd = h1.ArithEnd;
const arithEnd = h1.arithEnd;
const fixture_progressive_16x16_rgb12_444 = h1.fixture_progressive_16x16_rgb12_444;
const fixture_progressive_16x16_rgb12_420 = h1.fixture_progressive_16x16_rgb12_420;
const fixture_progressive_16x16_rgb12_422 = h1.fixture_progressive_16x16_rgb12_422;
const fixture_progressive_16x16_rgb12_440 = h1.fixture_progressive_16x16_rgb12_440;
const fixture_progressive_8x8_gray12 = h1.fixture_progressive_8x8_gray12;
const fixture_lossless_4x4_rgb = h1.fixture_lossless_4x4_rgb;
const fixture_lossless_dri = h1.fixture_lossless_dri;
const fixture_baseline_16x16_rgb12_444 = h2.fixture_baseline_16x16_rgb12_444;
const fixture_baseline_16x16_rgb12_420 = h2.fixture_baseline_16x16_rgb12_420;
const fixture_baseline_16x16_rgb12_422 = h2.fixture_baseline_16x16_rgb12_422;
const fixture_baseline_16x16_rgb12_440 = h2.fixture_baseline_16x16_rgb12_440;
const fixture_jpegls_4x4_rgb8_ilv1 = h2.fixture_jpegls_4x4_rgb8_ilv1;
const fixture_baseline_16x16_rgb_marked = h2.fixture_baseline_16x16_rgb_marked;
const fixture_overflow_ac_8x8 = h2.fixture_overflow_ac_8x8;
const fixture_seq_16x16_3scan = h2.fixture_seq_16x16_3scan;
const fixture_seq_17x13_420_y_cbcr_rst = h2.fixture_seq_17x13_420_y_cbcr_rst;
const fixture_seq_23x19_422_rev_rst = h2.fixture_seq_23x19_422_rev_rst;
const fixture_seq_23x19_rgb12_420_3scan = h2.fixture_seq_23x19_rgb12_420_3scan;
const fixture_fuzz_progressive_ac_refine_al15 = h2.fixture_fuzz_progressive_ac_refine_al15;
const ProgScan = h2.ProgScan;
const appendSegment = h2.appendSegment;
const buildProgressiveGray = h2.buildProgressiveGray;
const dc_zero = h2.dc_zero;
const ProgCase = h2.ProgCase;
const progressive_range_cases = h2.progressive_range_cases;
const FrameFixture = h2.FrameFixture;
const frameFixture = h2.frameFixture;
const frame_fixtures = h2.frame_fixtures;
const jlsFirstScanEnd = h2.jlsFirstScanEnd;
const jlsWithDnl = h2.jlsWithDnl;
const jlsWithPt = h2.jlsWithPt;
const ptSample = h2.ptSample;

test "baseline frees partial component allocations on every allocation failure" {
	const cases = [_]struct { data: []const u8, channels: u8 }{
		.{ .data = fixture_baseline_2x2_rgb, .channels = 3 },
		.{ .data = fixture_baseline_16x16_rgb_marked, .channels = 3 },
		.{ .data = fixture_baseline_16x16_rgb12_444, .channels = 3 },
		.{ .data = fixture_baseline_16x16_rgb12_420, .channels = 3 },
		.{ .data = fixture_baseline_4x4_cmyk, .channels = 4 },
	};
	for (cases) |case| {
		try std.testing.checkAllAllocationFailures(
			std.testing.allocator,
			decodeAllocationControl,
			.{ case.data, case.channels },
		);
	}
}

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

test "decode rejects SOF with zero height (no OOB crash)" {
    // A SOF declaring a zero dimension is not a decodable image (T.81
    // §B.2.2: X must be > 0; Y = 0 needs a DNL segment this decoder does
    // not support). The decoder must reject it, not run downstream MCU
    // assembly / chroma upsampling over an empty component plane — that
    // was an out-of-bounds crash in color.fancyUpsample.
    const allocator = std.testing.allocator;
    const buf = try allocator.dupe(u8, fixture_baseline_2x2_rgb);
    defer allocator.free(buf);
    // SOF0 = 0xFF 0xC0; body = len(2) precision(1) height(2)…; the 16-bit
    // height field is 5 bytes past the 0xFF marker start.
    var i: usize = 2;
    const sof = while (i + 1 < buf.len) : (i += 1) {
        if (buf[i] == 0xFF and buf[i + 1] == 0xC0) break i;
    } else unreachable;
    buf[sof + 5] = 0;
    buf[sof + 6] = 0;
    try std.testing.expectError(error.InvalidMarker, jpegz.decode(allocator, buf));
}

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

test "islow IDCT + fixed-point YCbCr + fancy upsample is byte-perfect on 4:2:0" {
    // 2026-05-16: after applying libjpeg-turbo's asymmetric +8/+7 bias
    // to color.fancyUpsample / baseline.fancyUpsample (H2V2, H2V1,
    // H1V2 — see fancyUpsample12 for the same pattern at P=12), the
    // 8-bit subsampled pipeline matches libjpeg byte-for-byte.
    // Tightened from ≤2 LSB to == 0.
    const allocator = std.testing.allocator;
    var cleanroom = try jpegz.internal.cleanroomDecode(allocator, fixture_baseline_8x8_yuv420);
    defer cleanroom.deinit(allocator);
    var wrapper = try jpegz.internal.wrapperDecode(allocator, fixture_baseline_8x8_yuv420);
    defer wrapper.deinit(allocator);
    try std.testing.expectEqual(wrapper.width, cleanroom.width);
    try std.testing.expectEqual(wrapper.height, cleanroom.height);
    try std.testing.expectEqualSlices(u8, wrapper.pixels, cleanroom.pixels);
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

test "fancy upsampling: 16x16 RGB 4:2:0 Huffman is byte-perfect vs libjpeg-turbo" {
    // 2026-05-16: catches the asymmetric-bias rounding regression. The
    // 8x8 fixtures happened to be byte-perfect by content coincidence
    // even when the bias was wrong; 16x16 surfaces the issue (max_delta
    // = 2 before the fix). Generated via:
    //   cjpeg -sample 2x2,1x1,1x1 <gradient_16x16.ppm>
    const data = @embedFile("fixtures/baseline_16x16_rgb_420.jpg");
    const allocator = std.testing.allocator;
    var cleanroom = try jpegz.internal.cleanroomDecode(allocator, data);
    defer cleanroom.deinit(allocator);
    var wrapper = try jpegz.internal.wrapperDecode(allocator, data);
    defer wrapper.deinit(allocator);
    try std.testing.expectEqualSlices(u8, wrapper.pixels, cleanroom.pixels);
}

