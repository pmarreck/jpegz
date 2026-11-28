//! decode tests, part 2 (split from decode.zig to keep files small).

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

test "Mode-2 JPEGTables-spliced baseline is byte-perfect vs libjpeg-turbo" {
    const allocator = std.testing.allocator;
    var cleanroom = try jpegz.internal.cleanroomDecode(allocator, fixture_mode2_spliced);
    defer cleanroom.deinit(allocator);
    var wrapper = try jpegz.internal.wrapperDecode(allocator, fixture_mode2_spliced);
    defer wrapper.deinit(allocator);
    try std.testing.expectEqual(wrapper.width, cleanroom.width);
    try std.testing.expectEqual(wrapper.height, cleanroom.height);
    try std.testing.expectEqualSlices(u8, wrapper.pixels, cleanroom.pixels);
}

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

test "arithmetic cleanroom is byte-perfect on gray + 4:4:4 RGB (SOF9 + SOF10)" {
    // 2026-05-16 sweep: cleanroom arithmetic matches libjpeg-turbo
    // byte-for-byte on every grayscale arithmetic fixture and every
    // 4:4:4 RGB arithmetic fixture across both SOF9 (sequential) and
    // SOF10 (progressive). Subsampled-RGB cases (4:2:0/4:2:2/4:4:0)
    // show a stable ≤2 LSB residual on ~6-12% of pixels and are
    // covered by their own tolerance test below.
    const allocator = std.testing.allocator;
    const cases = [_][]const u8{
        fixture_arith_baseline_8x8_gray,
        fixture_arith_baseline_16x16_rgb_444,
        fixture_arith_progressive_8x8_gray,
        fixture_arith_progressive_16x16_rgb_444,
    };
    for (cases) |data| {
        var clean = try jpegz.internal.arithDecode(allocator, data);
        defer clean.deinit(allocator);
        var wrap = try jpegz.internal.wrapperDecode(allocator, data);
        defer wrap.deinit(allocator);
        try std.testing.expectEqualSlices(u8, wrap.pixels, clean.pixels);
    }
}

test "DCT cleanroom is byte-perfect vs libjpeg-turbo wrapper (8-bit + 12-bit, baseline + progressive)" {
    // 2026-05-16: after fixing PASS1_BITS to 1 at P=12 (matching
    // libjpeg-turbo's jidctint.c #if BITS_IN_JSAMPLE == 8 / #else
    // branch), every DCT fixture in tree decodes byte-identically to
    // libjpeg-turbo: 8-bit progressive (gray/RGB/DRI), 12-bit
    // progressive (gray + RGB at 4:4:4 / 4:2:0 / 4:2:2 / 4:4:0), and
    // 12-bit baseline DCT (gray + RGB at all 4 sampling factors).
    // 13 fixtures × byte-perfect locks the cleanroom rounding-mode
    // alignment in place; any future IDCT / dequant / YCbCr→RGB /
    // chroma-upsample tweak that drifts from libjpeg's output fails
    // this test immediately.
    const allocator = std.testing.allocator;
    const Case = struct { name: []const u8, data: []const u8 };
    const cases = [_]Case{
        .{ .name = "prog_8x8_gray",        .data = fixture_progressive_8x8_gray },
        .{ .name = "prog_8x8_rgb",         .data = fixture_progressive_8x8 },
        .{ .name = "prog_32x32_dri",       .data = fixture_progressive_32x32_dri },
        .{ .name = "prog_8x8_gray12",      .data = fixture_progressive_8x8_gray12 },
        .{ .name = "prog_16x16_rgb12_444", .data = fixture_progressive_16x16_rgb12_444 },
        .{ .name = "prog_16x16_rgb12_420", .data = fixture_progressive_16x16_rgb12_420 },
        .{ .name = "prog_16x16_rgb12_422", .data = fixture_progressive_16x16_rgb12_422 },
        .{ .name = "prog_16x16_rgb12_440", .data = fixture_progressive_16x16_rgb12_440 },
        .{ .name = "base_16x16_rgb12_444", .data = fixture_baseline_16x16_rgb12_444 },
        .{ .name = "base_16x16_rgb12_420", .data = fixture_baseline_16x16_rgb12_420 },
        .{ .name = "base_16x16_rgb12_422", .data = fixture_baseline_16x16_rgb12_422 },
        .{ .name = "base_16x16_rgb12_440", .data = fixture_baseline_16x16_rgb12_440 },
        .{ .name = "base_4x4_gray12_dct",  .data = fixture_baseline_4x4_gray12_dct },
    };
    for (cases) |c| {
        var clean = jpegz.internal.progressiveDecode(allocator, c.data) catch
            try jpegz.internal.cleanroomDecode(allocator, c.data);
        defer clean.deinit(allocator);
        var wrap = try jpegz.internal.wrapperDecode(allocator, c.data);
        defer wrap.deinit(allocator);
        try std.testing.expectEqual(wrap.pixels.len, clean.pixels.len);
        std.testing.expectEqualSlices(u8, wrap.pixels, clean.pixels) catch |err| {
            std.debug.print("byte-exact mismatch on {s}\n", .{c.name});
            return err;
        };
    }
}

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

test "M2.5: progressive cleanroom decodes a JPEG with DRI > 0" {
    const allocator = std.testing.allocator;
    var cleanroom = try jpegz.internal.progressiveDecode(allocator, fixture_progressive_32x32_dri);
    defer cleanroom.deinit(allocator);
    var wrapper = try jpegz.internal.wrapperDecode(allocator, fixture_progressive_32x32_dri);
    defer wrapper.deinit(allocator);
    try std.testing.expectEqual(wrapper.width, cleanroom.width);
    try std.testing.expectEqual(wrapper.height, cleanroom.height);
    try std.testing.expectEqual(wrapper.channels, cleanroom.channels);
    var max_delta: u8 = 0;
    for (cleanroom.pixels, wrapper.pixels) |a, b| {
        const d: u8 = @intCast(@abs(@as(i32, a) - @as(i32, b)));
        if (d > max_delta) max_delta = d;
    }
    try std.testing.expect(max_delta <= 2);
}

test "B2: JPEG-LS 4x4 8-bit grayscale lossless round-trip via charls wrapper" {
    const allocator = std.testing.allocator;
    var image = try jpegz.decode(allocator, fixture_jpegls_4x4_gray8);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 4), image.width);
    try std.testing.expectEqual(@as(u32, 4), image.height);
    try std.testing.expectEqual(@as(u8, 1), image.channels);
    try std.testing.expectEqual(@as(u8, 8), image.bits_per_sample);
    try std.testing.expectEqual(jpegz.PixelLayout.grayscale, image.layout);
    try std.testing.expectEqual(@as(usize, 16), image.pixels.len);
    // Lossless: every pixel must match the gradient bit-exactly.
    for (image.pixels, 0..) |b, i| {
        try std.testing.expectEqual(@as(u8, @intCast(i << 4)), b);
    }
}

test "B2.2 §4: JPEG-LS 4x4 16-bit grayscale cleanroom (direct entry)" {
    const allocator = std.testing.allocator;
    var image = try jpegz.jpegls_cleanroom_decode(allocator, fixture_jpegls_4x4_gray16);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 4), image.width);
    try std.testing.expectEqual(@as(u32, 4), image.height);
    try std.testing.expectEqual(@as(u8, 1), image.channels);
    try std.testing.expectEqual(@as(u8, 16), image.bits_per_sample);
    try std.testing.expectEqual(@as(usize, 32), image.pixels.len);
    const px = image.pixelsU16();
    try std.testing.expectEqual(@as(usize, 16), px.len);
    for (px, 0..) |s, i| {
        try std.testing.expectEqual(@as(u16, @intCast(i * 0x1111)), s);
    }
}

test "B2: JPEG-LS 4x4 16-bit grayscale lossless round-trip" {
    const allocator = std.testing.allocator;
    var image = try jpegz.decode(allocator, fixture_jpegls_4x4_gray16);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 4), image.width);
    try std.testing.expectEqual(@as(u32, 4), image.height);
    try std.testing.expectEqual(@as(u8, 1), image.channels);
    try std.testing.expectEqual(@as(u8, 16), image.bits_per_sample);
    try std.testing.expectEqual(@as(usize, 32), image.pixels.len);
    const px = image.pixelsU16();
    try std.testing.expectEqual(@as(usize, 16), px.len);
    for (px, 0..) |s, i| {
        try std.testing.expectEqual(@as(u16, @intCast(i * 0x1111)), s);
    }
}

test "JPEG-LS LSE (FF F8) thresholds and RESET: T.87 conformance t8nde0 and t8nde3" {
    // ITU-T T.87 Annex E streams encoded by HP with T1=T2=T3=9 and RESET=31
    // in an LSE segment; test8bs2.pgm is the source image. t8nde0 is
    // lossless, t8nde3 is NEAR=3.
    if (!jpegls_conformance.available) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const want = pgmSamples(jpegls_conformance.test8bs2);
    for ([_]struct { data: []const u8, near: i32 }{
        .{ .data = jpegls_conformance.t8nde0, .near = 0 },
        .{ .data = jpegls_conformance.t8nde3, .near = 3 },
    }) |case| {
        var image = try jpegz.jpegls_cleanroom_decode(allocator, case.data);
        defer image.deinit(allocator);
        try std.testing.expectEqual(want.len, image.pixels.len);
        var worst: i32 = 0;
        for (image.pixels, want) |got, ref| worst = @max(worst, @as(i32, @intCast(@abs(@as(i32, got) - @as(i32, ref)))));
        if (worst > case.near) {
            std.debug.print("NEAR={d}: worst sample error {d}\n", .{ case.near, worst });
            return error.TestUnexpectedResult;
        }
    }
}

test "JPEG-LS 12-bit T.87 conformance t16e0 and t16e3 with default parameters" {
    // test16.pgm holds 12-bit samples as 16-bit big-endian PGM values.
    if (!jpegls_conformance.available) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const want = pgmSamples(jpegls_conformance.test16);
    for ([_]struct { data: []const u8, near: i32 }{
        .{ .data = jpegls_conformance.t16e0, .near = 0 },
        .{ .data = jpegls_conformance.t16e3, .near = 3 },
    }) |case| {
        var image = try jpegz.jpegls_cleanroom_decode(allocator, case.data);
        defer image.deinit(allocator);
        const got = image.pixelsU16();
        try std.testing.expectEqual(want.len / 2, got.len);
        var worst: i32 = 0;
        var bad: usize = 0;
        var first_bad: ?usize = null;
        for (got, 0..) |sample, i| {
            const ref: i32 = (@as(i32, want[2 * i]) << 8) | want[2 * i + 1];
            const err: i32 = @intCast(@abs(@as(i32, sample) - ref));
            worst = @max(worst, err);
            if (err > case.near) {
                bad += 1;
                if (first_bad == null) first_bad = i;
            }
        }
        if (worst > case.near) {
            const i = first_bad.?;
            std.debug.print("12-bit NEAR={d}: worst sample error {d}; {d} of {d} samples out of tolerance, first at {d} (got {d}, want {d})\n", .{ case.near, worst, bad, got.len, i, got[i], (@as(i32, want[2 * i]) << 8) | want[2 * i + 1] });
            return error.TestUnexpectedResult;
        }
    }
}

test "JPEG-LS restart intervals (DRI + RSTm) decode exactly: CharLS restart streams" {
    // CharLS test/data streams with a DRI before SOF55: 12-bit mono every
    // 5 lines; 8-bit RGB line- and sample-interleaved every 7 lines; and an
    // interval of 300, longer than the 256-line image, so no marker
    // appears. Lossless, so the source images are exact references.
    if (!jpegls_conformance.available) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    {
        var image = try jpegz.jpegls_cleanroom_decode(allocator, jpegls_conformance.test16_rm_5);
        defer image.deinit(allocator);
        const want = pgmSamples(jpegls_conformance.test16);
        const got = image.pixelsU16();
        try std.testing.expectEqual(want.len / 2, got.len);
        for (got, 0..) |sample, i| {
            const ref: u16 = (@as(u16, want[2 * i]) << 8) | want[2 * i + 1];
            if (sample != ref) {
                std.debug.print("test16_rm_5: sample {d} is {d}, want {d}\n", .{ i, sample, ref });
                return error.TestUnexpectedResult;
            }
        }
    }
    const want_rgb = pgmSamples(jpegls_conformance.test8);
    for ([_]struct { name: []const u8, data: []const u8 }{
        .{ .name = "line, every 7", .data = jpegls_conformance.test8_ilv_line_rm_7 },
        .{ .name = "sample, every 7", .data = jpegls_conformance.test8_ilv_sample_rm_7 },
        .{ .name = "sample, every 300", .data = jpegls_conformance.test8_ilv_sample_rm_300 },
        .{ .name = "none (one scan per component), every 7", .data = jpegls_conformance.test8_ilv_none_rm_7 },
    }) |case| {
        var image = try jpegz.jpegls_cleanroom_decode(allocator, case.data);
        defer image.deinit(allocator);
        try std.testing.expectEqual(@as(u8, 3), image.channels);
        if (std.mem.indexOfDiff(u8, want_rgb, image.pixels)) |i| {
            std.debug.print("{s}: byte {d} differs (len {d} vs {d})\n", .{ case.name, i, image.pixels.len, want_rgb.len });
            return error.TestUnexpectedResult;
        }
    }
    // A 3-byte Ri (DRI Lr = 5, T.87 C.2.5) names the same interval.
    {
        const src = jpegls_conformance.test16_rm_5;
        try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xdd, 0, 4, 0, 5 }, src[2..8]);
        const wide = try std.mem.concat(allocator, u8, &.{ src[0..2], &.{ 0xff, 0xdd, 0, 5, 0, 0, 5 }, src[8..] });
        defer allocator.free(wide);
        var a = try jpegz.jpegls_cleanroom_decode(allocator, src);
        defer a.deinit(allocator);
        var b = try jpegz.jpegls_cleanroom_decode(allocator, wide);
        defer b.deinit(allocator);
        try std.testing.expectEqualSlices(u8, a.pixels, b.pixels);
    }
    // RSTm must follow the modulo-8 sequence: renumber the second marker.
    {
        const bad = try allocator.dupe(u8, jpegls_conformance.test16_rm_5);
        defer allocator.free(bad);
        const first = std.mem.indexOf(u8, bad, &.{ 0xff, 0xd0 }).?;
        const second = first + 2 + std.mem.indexOf(u8, bad[first + 2 ..], &.{ 0xff, 0xd1 }).?;
        bad[second + 1] = 0xd3;
        // A restart fault stops decoding (finding 57 when validated).
        try std.testing.expectError(error.BackendError, jpegz.jpegls_cleanroom_decode(allocator, bad));
    }
}

test "chroma two samples wide or narrower upsamples by replication, as libjpeg-turbo does" {
    // T.81 leaves upsampling to the decoder; jpegz matches libjpeg-turbo,
    // whose jinit_upsampler uses the fancy (triangle) h2v1 and h2v2 filters
    // only when the subsampled width exceeds 2 and replicates samples
    // otherwise. Each fixture's scans are interleaved with 16-pixel MCUs, so
    // narrowing its SOF width to 1..16 keeps the same entropy data.
    const allocator = std.testing.allocator;
    const fixtures = [_]struct { name: []const u8, data: []const u8 }{
        .{ .name = "8-bit 4:2:0", .data = @embedFile("fixtures/baseline_16x16_rgb_420.jpg") },
        .{ .name = "12-bit 4:2:0", .data = @embedFile("fixtures/baseline_16x16_rgb12_420.jpg") },
        .{ .name = "12-bit 4:2:2", .data = @embedFile("fixtures/baseline_16x16_rgb12_422.jpg") },
        .{ .name = "arithmetic 4:2:0", .data = @embedFile("fixtures/arith_baseline_16x16_rgb_420.jpg") },
        .{ .name = "arithmetic 4:2:2", .data = @embedFile("fixtures/arith_baseline_16x16_rgb_422.jpg") },
        .{ .name = "YCCK 4:2:0", .data = @embedFile("fixtures/cmyk_16x16_ycck_subsampled.jpg") },
    };
    for (fixtures) |fx| {
        // The first SOF0, SOF1 or SOF9: its width field is 7 bytes in.
        var sof: usize = 2;
        while (!(fx.data[sof] == 0xff and (fx.data[sof + 1] == 0xc0 or fx.data[sof + 1] == 0xc1 or fx.data[sof + 1] == 0xc9))) {
            sof += 2 + (@as(usize, fx.data[sof + 2]) << 8 | fx.data[sof + 3]);
        }
        try std.testing.expectEqual(@as(u16, 16), std.mem.readInt(u16, fx.data[sof + 7 ..][0..2], .big));
        var width: u16 = 1;
        while (width <= 6) : (width += 1) {
            errdefer std.debug.print("{s} at width {d}\n", .{ fx.name, width });
            const data = try allocator.dupe(u8, fx.data);
            defer allocator.free(data);
            std.mem.writeInt(u16, data[sof + 7 ..][0..2], width, .big);
            var ours = try jpegz.decode(allocator, data);
            defer ours.deinit(allocator);
            var oracle = try jpegz.internal.wrapperDecode(allocator, data);
            defer oracle.deinit(allocator);
            try std.testing.expectEqual(oracle.width, ours.width);
            try std.testing.expectEqualSlices(u8, oracle.pixels, ours.pixels);
        }
    }
}
