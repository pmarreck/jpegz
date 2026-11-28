//! decode tests, part 7 (split from decode.zig to keep files small).

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

test "cleanroom lenient: RST cycle mismatch emits Finding(.warn, .restart_marker_unexpected) + recovers" {
    const allocator = std.testing.allocator;

    // baseline_128x128_dri4 has DRI=4 and natural RSTm cycle starting at
    // RST0 (0xD0). First FFD0 is at byte offset 652. Mutate it to FFD5
    // (RST5) so the decoder sees the wrong cycle byte. In strict mode
    // this returns error.InvalidMarker; in lenient mode + sink it must
    // emit a warn, resync, and decode the rest.
    const src = fixture_baseline_128x128_dri4;
    var corrupted = try allocator.alloc(u8, src.len);
    defer allocator.free(corrupted);
    @memcpy(corrupted, src);
    try std.testing.expectEqual(@as(u8, 0xFF), corrupted[652]);
    try std.testing.expectEqual(@as(u8, 0xD0), corrupted[653]);
    corrupted[653] = 0xD5; // RST5 — wrong cycle

    // Strict path: returns InvalidMarker.
    try std.testing.expectError(error.InvalidMarker,
        jpegz.internal.cleanroomDecode(allocator, corrupted));

    // Lenient + sink path: warn + recover.
    var sink = jpegz.FindingsSink.init(allocator);
    defer sink.deinit();
    var image = try jpegz.internal.cleanroomDecodeLenientWithFindings(allocator, corrupted, &sink);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 128), image.width);

    var found = false;
    for (sink.items()) |f| {
        if (f.severity == .warn and f.code == .restart_marker_unexpected) {
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "cleanroom lenient: an RST replaced by junk is FAIL 8 then 57 at the next RSTm" {
    const allocator = std.testing.allocator;

    // Same fixture; replace FFD0 (the first RST) with AA BB. The interval
    // ends with valid padding, so AA BB and the next interval's bytes are
    // whole bytes before the next marker, RST1: FAIL 8 at 652 (validate,
    // 2026-11-22). Like libjpeg, lenient decoding skips them to RST1, which
    // is out of order (57) and one ahead, so the second interval decodes as
    // empty and RST1 is then the expected marker. Strict decoding fails.
    const src = fixture_baseline_128x128_dri4;
    var corrupted = try allocator.alloc(u8, src.len);
    defer allocator.free(corrupted);
    @memcpy(corrupted, src);
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xd0 }, src[652..654]);
    corrupted[652] = 0xAA;
    corrupted[653] = 0xBB;
    const rst1 = std.mem.indexOfPos(u8, corrupted, 654, &.{ 0xff, 0xd1 }).?;

    var sink = jpegz.FindingsSink.init(allocator);
    defer sink.deinit();
    if (jpegz.internal.cleanroomDecodeLenientWithFindings(allocator, corrupted, &sink)) |image| {
        var img = image;
        img.deinit(allocator);
    } else |_| {}
    var extraneous: usize = 0;
    var unexpected: usize = 0;
    for (sink.items()) |f| {
        try std.testing.expect(f.code != .huffman_table_corrupt);
        if (f.code == .extraneous_bytes_before_marker) {
            extraneous += 1;
            try std.testing.expect(f.severity == .fail and f.offset_is_exact and f.offset.? == 652);
        }
        if (f.code == .restart_marker_unexpected) {
            unexpected += 1;
            try std.testing.expectEqual(@as(?u64, rst1), f.offset);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), extraneous);
    try std.testing.expectEqual(@as(usize, 1), unexpected);
    try std.testing.expectError(error.BackendError, jpegz.internal.cleanroomDecode(allocator, corrupted));
}

test "lenient Huffman resync follows libjpeg: a later RSTm leaves the interval empty, an earlier one is skipped" {
    // libjpeg's jpeg_resync_to_restart (jdmarker.c): finding RSTm where RSTn
    // belongs, with m one or two ahead, leaves the marker and decodes the
    // expected interval as empty, so later intervals keep their positions.
    // With m one or two behind, it skips to the next marker. Restart
    // intervals reset DC prediction, so the rest decodes as in the original.
    const allocator = std.testing.allocator;
    const src = fixture_baseline_128x128_dri4;
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xd0 }, src[652..654]);
    const rst1 = std.mem.indexOfPos(u8, src, 654, &.{ 0xff, 0xd1 }).?;
    var pristine = try jpegz.decode(allocator, src);
    defer pristine.deinit(allocator);
    {
        // RST0 and the second interval removed: RST1 arrives where RST0
        // belongs. The second interval (MCUs 4..7 of this 4:4:4 image: x 32
        // to 63, rows 0 to 7) has no data; every other pixel decodes as in
        // the original, in jpegz and in libjpeg-turbo alike. Inside the
        // empty interval libjpeg-turbo decodes its first MCU from zero fill
        // bits, so that region is not compared.
        const dropped = try std.mem.concat(allocator, u8, &.{ src[0..652], src[rst1..] });
        defer allocator.free(dropped);
        var sink = jpegz.FindingsSink.init(allocator);
        defer sink.deinit();
        var recovered = try jpegz.internal.cleanroomDecodeLenientWithFindings(allocator, dropped, &sink);
        defer recovered.deinit(allocator);
        var oracle = try jpegz.internal.wrapperDecode(allocator, dropped);
        defer oracle.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 128 * 128 * 3), recovered.pixels.len);
        try std.testing.expectEqualSlices(u8, &.{ 1, 0x11, 0, 2, 0x11, 1, 3, 0x11, 1 }, src[std.mem.indexOf(u8, src, &.{ 0xff, 0xc0 }).? + 10 ..][0..9]);
        for (0..128) |y| for (0..128) |x| {
            if (y < 8 and x >= 32 and x < 64) continue;
            const at = (y * 128 + x) * 3;
            try std.testing.expectEqualSlices(u8, pristine.pixels[at..][0..3], recovered.pixels[at..][0..3]);
            try std.testing.expectEqualSlices(u8, pristine.pixels[at..][0..3], oracle.pixels[at..][0..3]);
        };
        var unexpected: usize = 0;
        for (sink.items()) |f| {
            try std.testing.expect(f.code != .truncated_stream);
            if (f.code == .restart_marker_unexpected) {
                unexpected += 1;
                try std.testing.expectEqual(@as(?u64, 652), f.offset);
            }
        }
        try std.testing.expectEqual(@as(usize, 1), unexpected);
    }
    {
        // Stale RST7 and RST0 (two and one behind) inserted before RST1:
        // both skipped, one 57 for the resync, and every interval decodes as
        // in the original.
        const stale = try std.mem.concat(allocator, u8, &.{ src[0..rst1], &.{ 0xff, 0xd7, 0xff, 0xd0 }, src[rst1..] });
        defer allocator.free(stale);
        var sink = jpegz.FindingsSink.init(allocator);
        defer sink.deinit();
        var recovered = try jpegz.internal.cleanroomDecodeLenientWithFindings(allocator, stale, &sink);
        defer recovered.deinit(allocator);
        try std.testing.expectEqualSlices(u8, pristine.pixels, recovered.pixels);
        var unexpected: usize = 0;
        for (sink.items()) |f| {
            try std.testing.expect(f.code != .truncated_stream and f.code != .insufficient_data);
            if (f.code == .restart_marker_unexpected) {
                unexpected += 1;
                try std.testing.expectEqual(@as(?u64, rst1), f.offset);
            }
        }
        try std.testing.expectEqual(@as(usize, 1), unexpected);
    }
}

test "lenient progressive resync follows libjpeg too: an empty interval keeps later blocks in place" {
    // libjpeg-turbo, -progressive -restart 1B (HUFFMAN_RESTART_PROVENANCE.md).
    // The second scan is luma AC with one block per interval. Dropping its
    // RST0 and second interval leaves luma block 1 (x 8 to 15, rows 0 to 7)
    // without that scan's data; luma is not upsampled, so every other pixel
    // decodes as in the original.
    const allocator = std.testing.allocator;
    const src = @embedFile("fixtures/huffman_restart_32x32_rgb420_progressive_1b.jpg");
    const sos1 = std.mem.indexOf(u8, src, &.{ 0xff, 0xda }).?;
    const sos2 = std.mem.indexOfPos(u8, src, sos1 + 2, &.{ 0xff, 0xda }).?;
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 0, 1, 5 }, src[sos2 + 4 ..][0..5]);
    const rst0 = std.mem.indexOfPos(u8, src, sos2, &.{ 0xff, 0xd0 }).?;
    const rst1 = std.mem.indexOfPos(u8, src, rst0, &.{ 0xff, 0xd1 }).?;
    var pristine = try jpegz.decode(allocator, src);
    defer pristine.deinit(allocator);
    {
        const dropped = try std.mem.concat(allocator, u8, &.{ src[0..rst0], src[rst1..] });
        defer allocator.free(dropped);
        var sink = jpegz.FindingsSink.init(allocator);
        defer sink.deinit();
        var recovered = try jpegz.decodeWithOptions(allocator, dropped, .{ .lenient = true, .findings_sink = &sink });
        defer recovered.deinit(allocator);
        var oracle = try jpegz.internal.wrapperDecode(allocator, dropped);
        defer oracle.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 32 * 32 * 3), recovered.pixels.len);
        for (0..32) |y| for (0..32) |x| {
            if (y < 8 and x >= 8 and x < 16) continue;
            const at = (y * 32 + x) * 3;
            try std.testing.expectEqualSlices(u8, pristine.pixels[at..][0..3], recovered.pixels[at..][0..3]);
            try std.testing.expectEqualSlices(u8, pristine.pixels[at..][0..3], oracle.pixels[at..][0..3]);
        };
        var unexpected: usize = 0;
        for (sink.items()) |f| {
            try std.testing.expect(f.code != .truncated_stream);
            if (f.code == .restart_marker_unexpected) {
                unexpected += 1;
                try std.testing.expectEqual(@as(?u64, rst0), f.offset);
            }
        }
        try std.testing.expectEqual(@as(usize, 1), unexpected);
    }
    {
        // A stale RST0 before RST1: skipped; the image decodes as the original.
        const stale = try std.mem.concat(allocator, u8, &.{ src[0..rst1], &.{ 0xff, 0xd0 }, src[rst1..] });
        defer allocator.free(stale);
        var sink = jpegz.FindingsSink.init(allocator);
        defer sink.deinit();
        var recovered = try jpegz.decodeWithOptions(allocator, stale, .{ .lenient = true, .findings_sink = &sink });
        defer recovered.deinit(allocator);
        try std.testing.expectEqualSlices(u8, pristine.pixels, recovered.pixels);
        var unexpected: usize = 0;
        for (sink.items()) |f| {
            try std.testing.expect(f.code != .truncated_stream and f.code != .insufficient_data);
            if (f.code == .restart_marker_unexpected) {
                unexpected += 1;
                try std.testing.expectEqual(@as(?u64, rst1), f.offset);
            }
        }
        try std.testing.expectEqual(@as(usize, 1), unexpected);
    }
}

test "lossless difference category 16 decodes at every precision (T.81 H.1.2.2, modulo 2^16)" {
    // 2x2 gray, P = 15, predictor 4 (Ra + Rb - Rc). Samples 0, 32767 /
    // 32767, 32766. The last prediction is 32767 + 32767 - 0 = 65534, so
    // the difference is -32768, which is 32768 modulo 2^16: category 16,
    // no extra bits. libjpeg-turbo writes such files at 15-bit precision
    // (cjpeg -precision 15 -lossless 4); a decoder that allows category 16
    // only at 16-bit precision rejects them.
    // DC table: code 0 -> 15, code 10 -> 16.
    const data = [_]u8{ 0xff, 0xd8, 0xff, 0xc3, 0, 11, 15, 0, 2, 0, 2, 1, 1, 0x11, 0 } ++
        [_]u8{ 0xff, 0xc4, 0, 21, 0x00, 1, 1 } ++ ([_]u8{0} ** 14) ++ [_]u8{ 15, 16 } ++
        [_]u8{ 0xff, 0xda, 0, 8, 1, 1, 0x00, 4, 0, 0 } ++
        // 0 + 011111111111111 (-16384), 0 + 111111111111111 (+32767) twice,
        // then 10 (category 16) and six 1 pad bits; FF bytes stuffed.
        [_]u8{ 0x3f, 0xff, 0x00, 0x7f, 0xff, 0x00, 0x7f, 0xff, 0x00, 0xbf, 0xff, 0xd9 };
    const allocator = std.testing.allocator;
    var image = try jpegz.decode(allocator, &data);
    defer image.deinit(allocator);
    var oracle = try jpegz.internal.wrapperDecode(allocator, &data);
    defer oracle.deinit(allocator);
    try std.testing.expectEqualSlices(u8, oracle.pixels, image.pixels);
    const last = std.mem.readInt(u16, image.pixels[6..8], .little);
    try std.testing.expectEqual(@as(u16, 32766), last);
    var report = try jpegz.validate(allocator, &data);
    defer report.deinit(allocator);
    try std.testing.expect(report.isValid());
}

test "lenient Huffman decoding resumes after a restart that follows truncated data" {
    // Three bytes cut from the end of the first restart interval: its data
    // runs into RST0 (insufficient_data). RST0 restarts decoding, as
    // libjpeg clears its insufficient-data flag, so every later interval
    // decodes exactly as in the pristine file.
    const allocator = std.testing.allocator;
    const src = fixture_baseline_128x128_dri4;
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xd0 }, src[652..654]);
    const cut = try std.mem.concat(allocator, u8, &.{ src[0..649], src[652..] });
    defer allocator.free(cut);
    var sink = jpegz.FindingsSink.init(allocator);
    defer sink.deinit();
    var damaged = try jpegz.internal.cleanroomDecodeLenientWithFindings(allocator, cut, &sink);
    defer damaged.deinit(allocator);
    var pristine = try jpegz.decode(allocator, src);
    defer pristine.deinit(allocator);
    var insufficient: usize = 0;
    for (sink.items()) |f| insufficient += @intFromBool(f.code == .insufficient_data);
    try std.testing.expectEqual(@as(usize, 1), insufficient);
    // The bottom 16 rows lie far past the damaged first interval.
    const row = @as(usize, pristine.width) * pristine.channels;
    const tail = row * 16;
    try std.testing.expectEqualSlices(u8, pristine.pixels[pristine.pixels.len - tail ..], damaged.pixels[damaged.pixels.len - tail ..]);
}

test "cleanroom emits Finding(.warn, .entropy_fill_bytes) for extra 0xFF in marker prefix" {
    const allocator = std.testing.allocator;

    // T.81 §B.1.1.2: any number of 0xFF bytes preceding a marker NN
    // is legal "fill". The canonical encoding emits exactly one. We
    // inject 2 extra 0xFFs in front of APP0 (FF E0); the cleanroom
    // marker walker scans past them silently today — this test forces
    // a warn emission with the fill count.
    //
    // Layout: SOI(2) | inject 2x 0xFF | APP0 marker (FF E0 ...) | rest
    const src = fixture_baseline_2x2_rgb;
    var corrupted = try allocator.alloc(u8, src.len + 2);
    defer allocator.free(corrupted);
    @memcpy(corrupted[0..2], src[0..2]); // SOI
    corrupted[2] = 0xFF;
    corrupted[3] = 0xFF;
    @memcpy(corrupted[4..], src[2..]); // FF E0 ... — APP0 onward

    var sink = jpegz.FindingsSink.init(allocator);
    defer sink.deinit();

    var image = try jpegz.internal.cleanroomDecodeWithFindings(allocator, corrupted, &sink);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 2), image.width);

    var found = false;
    for (sink.items()) |f| {
        if (f.severity == .warn and f.code == .entropy_fill_bytes) {
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "cleanroom emits Finding(.warn, .adobe_app14_conflicts_jfif) when both present and APP14 disagrees" {
    const allocator = std.testing.allocator;

    // baseline_2x2_rgb.jpg starts with SOI(2) + JFIF APP0(18 bytes). Inject
    // a 16-byte APP14 (Adobe, ColorTransform=0 / unknown/raw RGB) right
    // after the JFIF segment but before DQT. JFIF implies YCbCr for
    // 3-component; APP14 ColorTransform=0 disagrees → conflict warn.
    const app14: [16]u8 = .{
        0xFF, 0xEE,             // APP14 marker
        0x00, 0x0E,             // segment length = 14 (2 + 12)
        'A', 'd', 'o', 'b', 'e', 0x00, // "Adobe\0"
        0x64,                   // DCTEncodeVersion = 100
        0x00, 0x00,             // APP14Flags0
        0x00, 0x00,             // APP14Flags1
        0x00,                   // ColorTransform = 0 (CMYK / raw RGB)
    };

    const src = fixture_baseline_2x2_rgb;
    var corrupted = try allocator.alloc(u8, src.len + app14.len);
    defer allocator.free(corrupted);
    // SOI + JFIF APP0 occupy bytes 0..19 (SOI=2 + APP0 length 0x10+2=18).
    @memcpy(corrupted[0..20], src[0..20]);
    @memcpy(corrupted[20..36], &app14);
    @memcpy(corrupted[36..], src[20..]);

    var sink = jpegz.FindingsSink.init(allocator);
    defer sink.deinit();

    var image = try jpegz.internal.cleanroomDecodeWithFindings(allocator, corrupted, &sink);
    defer image.deinit(allocator);

    // Decode must still succeed (libjpeg honors APP14 over JFIF here).
    try std.testing.expectEqual(@as(u32, 2), image.width);
    try std.testing.expectEqual(@as(u32, 2), image.height);

    var found = false;
    for (sink.items()) |f| {
        if (f.severity == .warn and f.code == .adobe_app14_conflicts_jfif) {
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "cleanroom emits NO Finding(.adobe_app14_conflicts_jfif) when APP14 says YCbCr (agreement)" {
    const allocator = std.testing.allocator;

    // Same setup but APP14 ColorTransform=1 (YCbCr) — agrees with JFIF.
    // No conflict, no finding.
    const app14: [16]u8 = .{
        0xFF, 0xEE, 0x00, 0x0E,
        'A', 'd', 'o', 'b', 'e', 0x00,
        0x64, 0x00, 0x00, 0x00, 0x00,
        0x01, // ColorTransform = 1 (YCbCr)
    };

    const src = fixture_baseline_2x2_rgb;
    var corrupted = try allocator.alloc(u8, src.len + app14.len);
    defer allocator.free(corrupted);
    @memcpy(corrupted[0..20], src[0..20]);
    @memcpy(corrupted[20..36], &app14);
    @memcpy(corrupted[36..], src[20..]);

    var sink = jpegz.FindingsSink.init(allocator);
    defer sink.deinit();

    var image = try jpegz.internal.cleanroomDecodeWithFindings(allocator, corrupted, &sink);
    defer image.deinit(allocator);

    for (sink.items()) |f| {
        try std.testing.expect(!(f.code == .adobe_app14_conflicts_jfif));
    }
}

test "an Adobe ColorTransform other than 0 means the encoder's transform, as libjpeg-turbo reads it" {
    // Adobe defines ColorTransform 0 (none), 1 (YCbCr) and 2 (YCCK). For any
    // other byte, libjpeg-turbo warns (JWRN_ADOBE_XFORM) and assumes the
    // encoder's transform: YCbCr for three components, YCCK for four, as it
    // also does for 2 with three components and 1 with four. jpegz used to
    // read undefined bytes as "no transform" and pass the samples through.
    const allocator = std.testing.allocator;
    const fixtures = [_][]const u8{
        @embedFile("fixtures/rgb_8x8_p8_baseline.jpg"),
        @embedFile("fixtures/rgb_8x8_p12_baseline.jpg"),
        @embedFile("fixtures/rgb_8x8_p8_progressive.jpg"),
        @embedFile("fixtures/rgb_8x8_p12_progressive.jpg"),
        @embedFile("fixtures/rgb_8x8_p8_arith_progressive.jpg"),
        @embedFile("fixtures/baseline_4x4_cmyk.jpg"),
        @embedFile("fixtures/cmyk_16x16_ycck_subsampled.jpg"),
    };
    const transform_at = 17; // byte 11 of the APP14 body that starts at 2
    for (fixtures, 0..) |fixture, fi| {
        try std.testing.expectEqualStrings("Adobe\x00", fixture[6..12]);
        for ([_]u8{ 0, 1, 2, 3, 0x80, 0xfe, 0xff }) |transform| {
            errdefer std.debug.print("fixture {d}, ColorTransform {d}\n", .{ fi, transform });
            const data = try allocator.dupe(u8, fixture);
            defer allocator.free(data);
            data[transform_at] = transform;
            var ours = try jpegz.decode(allocator, data);
            defer ours.deinit(allocator);
            var oracle = try jpegz.internal.wrapperDecode(allocator, data);
            defer oracle.deinit(allocator);
            try std.testing.expectEqual(oracle.channels, ours.channels);
            try std.testing.expectEqualSlices(u8, oracle.pixels, ours.pixels);
        }
    }
}
