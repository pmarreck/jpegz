//! decode tests, part 10 (split from decode.zig to keep files small).

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

test "JPEG-LS SOF55 Y = 0 with no DNL and no LSE ID 4 has no height (61, InvalidMarker)" {
    if (!jpegls_conformance.available) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    // No DNL at all, and a DNL whose NL is 0 (T.81 B.2.5: NL > 0).
    for ([_]?u16{ null, 0 }) |nl| {
        const data = try jlsWithDnl(allocator, jpegls_conformance.t8nde0, 0, nl);
        defer allocator.free(data);
        try std.testing.expectError(error.InvalidMarker, jpegz.jpegls_cleanroom_decode(allocator, data));
        var report = try jpegz.validate(allocator, data);
        defer report.deinit(allocator);
        try std.testing.expect(onlyFail(report, .invalid_dimensions) != null);
    }
}

test "JPEG-LS DNL with a nonzero SOF55 Y is 72 dnl_misplaced (WARN when NL agrees)" {
    if (!jpegls_conformance.available) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const src = jpegls_conformance.t8nde0;
    const y = std.mem.readInt(u16, src[std.mem.indexOf(u8, src, &.{ 0xff, 0xf7 }).? + 5 ..][0..2], .big);
    const data = try jlsWithDnl(allocator, src, y, y);
    defer allocator.free(data);
    var report = try jpegz.validate(allocator, data);
    defer report.deinit(allocator);
    const f = for (report.findings.items) |f| {
        if (f.code == .dnl_misplaced) break f;
    } else {
        dumpFindings("Y + DNL", report);
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqual(jpegz.Severity.warn, f.severity);
    try std.testing.expect(std.mem.startsWith(u8, f.detail.?, "with_nonzero_y"));
    try std.testing.expect(f.offset_is_exact and f.offset.? == jlsFirstScanEnd(src));
}

test "JPEG-LS point transform: output is Rx << Pt (T.87 4.3.2), 127 << 1 fits" {
    const allocator = std.testing.allocator;
    const data = try jlsWithPt(allocator, @embedFile("fixtures/jpegls_16x16_gray8_max127.jls"), 1);
    defer allocator.free(data);
    var image = try jpegz.jpegls_cleanroom_decode(allocator, data);
    defer image.deinit(allocator);
    for (0..16) |y| for (0..16) |x| {
        try std.testing.expectEqual(ptSample(x, y) * 2, image.pixels[y * 16 + x]);
    };
    var report = try jpegz.validate(allocator, data);
    defer report.deinit(allocator);
    try std.testing.expectEqual(.decoded, report.codec_check);
    for (report.findings.items) |f| try std.testing.expect(f.severity == .info);
}

test "JPEG-LS point transform overflow is FAIL 128 and saturates the sample" {
    const allocator = std.testing.allocator;
    const src = @embedFile("fixtures/jpegls_16x16_gray8_one128.jls");
    // Pt = 0: sample (5, 9) is 128 and the stream is valid.
    {
        var image = try jpegz.jpegls_cleanroom_decode(allocator, src);
        defer image.deinit(allocator);
        try std.testing.expectEqual(@as(u8, 128), image.pixels[5 * 16 + 9]);
    }
    const data = try jlsWithPt(allocator, src, 1);
    defer allocator.free(data);
    var image = try jpegz.jpegls_cleanroom_decode(allocator, data);
    defer image.deinit(allocator);
    for (0..16) |y| for (0..16) |x| {
        const want: u8 = if (y == 5 and x == 9) 255 else ptSample(x, y) * 2;
        try std.testing.expectEqual(want, image.pixels[y * 16 + x]);
    };
    var report = try jpegz.validate(allocator, data);
    defer report.deinit(allocator);
    const f = onlyFail(report, .jpegls_point_transform_overflow) orelse {
        dumpFindings("Pt overflow", report);
        return error.TestUnexpectedResult;
    };
    const sos = std.mem.indexOf(u8, data, &.{ 0xff, 0xda }).?;
    try std.testing.expectEqual(@as(u64, sos + 2 + std.mem.readInt(u16, data[sos + 2 ..][0..2], .big) - 1), f.offset.?);
    try std.testing.expect(!f.offset_is_exact);
    try std.testing.expect(std.mem.indexOf(u8, f.detail.?, "line 5, column 9: Rx 128 << Pt 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, f.detail.?, "1 sample(s)") != null);
}

test "JPEG-LS point transform applies to each ILV 0 scan, with one 128 per overflowing scan" {
    if (!jpegls_conformance.available) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const src = jpegls_conformance.t8c0e0;
    var plain = try jpegz.jpegls_cleanroom_decode(allocator, src);
    defer plain.deinit(allocator);
    const data = try jlsWithPt(allocator, src, 1);
    defer allocator.free(data);
    var image = try jpegz.jpegls_cleanroom_decode(allocator, data);
    defer image.deinit(allocator);
    var over = [_]bool{ false, false, false };
    for (plain.pixels, image.pixels, 0..) |rx, got, i| {
        if (@as(u16, rx) << 1 > 255) over[i % 3] = true;
        try std.testing.expectEqual(@as(u8, @intCast(@min(@as(u16, rx) << 1, 255))), got);
    }
    var report = try jpegz.validate(allocator, data);
    defer report.deinit(allocator);
    var fails: usize = 0;
    for (report.findings.items) |f| if (f.severity == .fail) {
        try std.testing.expectEqual(jpegz.FindingCode.jpegls_point_transform_overflow, f.code);
        fails += 1;
    };
    var want: usize = 0;
    for (over) |o| want += @intFromBool(o);
    try std.testing.expect(want > 0);
    try std.testing.expectEqual(want, fails);
}

test "JPEG-LS point transform on a 12-bit scan saturates at 4095 and counts every sample" {
    if (!jpegls_conformance.available) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const src = jpegls_conformance.t16e0;
    var plain = try jpegz.jpegls_cleanroom_decode(allocator, src);
    defer plain.deinit(allocator);
    const data = try jlsWithPt(allocator, src, 4);
    defer allocator.free(data);
    var image = try jpegz.jpegls_cleanroom_decode(allocator, data);
    defer image.deinit(allocator);
    var over: usize = 0;
    var i: usize = 0;
    while (i < plain.pixels.len) : (i += 2) {
        const rx = std.mem.readInt(u16, plain.pixels[i..][0..2], @import("builtin").cpu.arch.endian());
        const got = std.mem.readInt(u16, image.pixels[i..][0..2], @import("builtin").cpu.arch.endian());
        const shifted = @as(u32, rx) << 4;
        if (shifted > 4095) over += 1;
        try std.testing.expectEqual(@as(u16, @intCast(@min(shifted, 4095))), got);
    }
    try std.testing.expect(over > 0);
    var report = try jpegz.validate(allocator, data);
    defer report.deinit(allocator);
    const f = onlyFail(report, .jpegls_point_transform_overflow) orelse return error.TestUnexpectedResult;
    var buf: [32]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, f.detail.?, try std.fmt.bufPrint(&buf, "{d} sample(s)", .{over})) != null);
}

test "JPEG-LS mapping table specified twice: the later one replaces the earlier" {
    const allocator = std.testing.allocator;
    const entries = map_src[9..265];
    const junk = try lseMapping(allocator, 2, 1, 1, entries[0..10]);
    defer allocator.free(junk);
    const real = try lseMapping(allocator, 2, 1, 1, entries);
    defer allocator.free(real);
    const data = try withTables(allocator, &.{ junk, real });
    defer allocator.free(data);
    var image = try jpegz.jpegls_cleanroom_decode(allocator, data);
    defer image.deinit(allocator);
    try expectMapped(image);
}

test "JPEG-LS mapping table with two-byte entries validates; the decode API cannot map it" {
    // T.87 defines no interpretation for entries wider than one byte.
    const allocator = std.testing.allocator;
    var wide: [512]u8 = undefined;
    for (0..256) |i| {
        wide[2 * i] = @intCast(i);
        wide[2 * i + 1] = 0;
    }
    const seg = try lseMapping(allocator, 2, 1, 2, &wide);
    defer allocator.free(seg);
    const data = try withTables(allocator, &.{seg});
    defer allocator.free(data);
    try std.testing.expectError(error.NotImplemented, jpegz.jpegls_cleanroom_decode(allocator, data));
    var report = try jpegz.validate(allocator, data);
    defer report.deinit(allocator);
    try std.testing.expectEqual(.decoded, report.codec_check);
    for (report.findings.items) |f| try std.testing.expect(f.severity == .info);
}

test "JPEG-LS mapping table selected by one ILV 0 scan maps only that component" {
    if (!jpegls_conformance.available) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const src = jpegls_conformance.t8c0e0;
    var plain = try jpegz.jpegls_cleanroom_decode(allocator, src);
    defer plain.deinit(allocator);
    var invert: [256]u8 = undefined;
    for (&invert, 0..) |*e, i| e.* = @intCast(255 - i);
    const seg = try lseMapping(allocator, 2, 1, 1, &invert);
    defer allocator.free(seg);
    // The table goes before the first SOS; the second SOS selects it.
    const first = std.mem.indexOf(u8, src, &.{ 0xff, 0xda }).?;
    const data = try std.mem.concat(allocator, u8, &.{ src[0..first], seg, src[first..] });
    defer allocator.free(data);
    const scan1_end = std.mem.indexOfPos(u8, data, first + seg.len + jlsFirstScanEnd(data[first + seg.len ..]), &.{ 0xff, 0xda }).?;
    try std.testing.expectEqual(@as(u8, 1), data[scan1_end + 4]);
    data[scan1_end + 6] = 1;
    var image = try jpegz.jpegls_cleanroom_decode(allocator, data);
    defer image.deinit(allocator);
    for (plain.pixels, image.pixels, 0..) |want, got, i| {
        try std.testing.expectEqual(if (i % 3 == 1) 255 - want else want, got);
    }
    var report = try jpegz.validate(allocator, data);
    defer report.deinit(allocator);
    try std.testing.expectEqual(.decoded, report.codec_check);
    for (report.findings.items) |f| try std.testing.expect(f.severity == .info);
}

test "JPEG-LS subsampled frame whose height needs a padded last MCU drops the padding lines" {
    // t8sse0 with SOF Y = 253: still ceil(253 / 4) = 64 MCUs, so the same
    // entropy data codes R 253 lines (+3 padding), G 64 and B 127 (+1). The
    // decoder must drop the padding (T.87 B.4) and return cropped planes.
    if (!jpegls_conformance.available) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const data = try allocator.dupe(u8, jpegls_conformance.t8sse0);
    defer allocator.free(data);
    const sof = std.mem.indexOf(u8, data, &.{ 0xff, 0xf7 }).?;
    std.mem.writeInt(u16, data[sof + 5 ..][0..2], 253, .big);
    var planes = try jpegz.jpegls_cleanroom_decode_planes(allocator, data);
    defer for (&planes) |*plane| if (plane.*) |*image| image.deinit(allocator);
    const refs = [_][]const u8{ pgmSamples(jpegls_conformance.test8r), pgmSamples(jpegls_conformance.test8gr4), pgmSamples(jpegls_conformance.test8bs2) };
    const sizes = [_][2]u32{ .{ 256, 253 }, .{ 256, 64 }, .{ 128, 127 } };
    for (0..3) |c| {
        const plane = planes[c].?;
        try std.testing.expectEqual(sizes[c][0], plane.width);
        try std.testing.expectEqual(sizes[c][1], plane.height);
        try std.testing.expectEqualSlices(u8, refs[c][0 .. sizes[c][0] * sizes[c][1]], plane.pixels);
    }
    var report = try jpegz.validate(allocator, data);
    defer report.deinit(allocator);
    try std.testing.expectEqual(.decoded, report.codec_check);
    for (report.findings.items) |f| try std.testing.expect(f.severity == .info);
}

test "JPEG-LS subsampled scans with restarts, a point transform or sample interleave are NotImplemented" {
    if (!jpegls_conformance.available) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const src = jpegls_conformance.t8sse0;
    const sos = std.mem.indexOf(u8, src, &.{ 0xff, 0xda }).?;
    const ls = std.mem.readInt(u16, src[sos + 2 ..][0..2], .big);
    // A DRI before the SOS.
    const dri = try std.mem.concat(allocator, u8, &.{ src[0..sos], &.{ 0xff, 0xdd, 0x00, 0x04, 0x00, 0x10 }, src[sos..] });
    defer allocator.free(dri);
    // Pt = 1 in the SOS Al.
    const pt = try allocator.dupe(u8, src);
    defer allocator.free(pt);
    pt[sos + 2 + ls - 1] = 1;
    // ILV = 0.
    const ilv0 = try allocator.dupe(u8, src);
    defer allocator.free(ilv0);
    ilv0[sos + 2 + ls - 2] = 0;
    for ([_][]const u8{ dri, pt, ilv0 }) |data| {
        try std.testing.expectError(error.NotImplemented, jpegz.jpegls_cleanroom_decode_planes(allocator, data));
    }
}

test "JPEG-LS sample interleave over subsampled components is FAIL 129 at the ILV byte" {
    // T.87 C.2.3 allows ILV 2 only for components of equal size.
    if (!jpegls_conformance.available) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const data = try allocator.dupe(u8, jpegls_conformance.t8sse0);
    defer allocator.free(data);
    const sos = std.mem.indexOf(u8, data, &.{ 0xff, 0xda }).?;
    const ilv_at = sos + 2 + std.mem.readInt(u16, data[sos + 2 ..][0..2], .big) - 2;
    data[ilv_at] = 2;
    try std.testing.expectError(error.BackendError, jpegz.jpegls_cleanroom_decode_planes(allocator, data));
    var report = try jpegz.validate(allocator, data);
    defer report.deinit(allocator);
    const f = onlyFail(report, .jpegls_sample_interleave_subsampled) orelse {
        dumpFindings("129", report);
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(f.offset_is_exact and f.offset.? == ilv_at);
    try std.testing.expect(std.mem.endsWith(u8, f.detail.?, "Hi x Vi: 2x4 2x1 1x2"));
}

