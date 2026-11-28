//! decode tests, part 3 (split from decode.zig to keep files small).

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

test "JPEG-LS validate decodes intact streams without FAIL findings" {
    const allocator = std.testing.allocator;
    var streams: [12][]const u8 = undefined;
    var n: usize = 0;
    for ([_][]const u8{
        @embedFile("fixtures/jpegls_4x4_gray8.jls"),  @embedFile("fixtures/jpegls_4x4_gray16.jls"),
        @embedFile("fixtures/jpegls_4x4_rgb8.jls"),   @embedFile("fixtures/jpegls_4x4_rgb16.jls"),
        @embedFile("fixtures/jpegls_4x4_rgb8_ilv1.jls"), @embedFile("fixtures/jpegls_8x8_gray8_near2.jls"),
    }) |data| {
        streams[n] = data;
        n += 1;
    }
    if (jpegls_conformance.available) for ([_][]const u8{
        jpegls_conformance.t8nde0, jpegls_conformance.t8nde3, jpegls_conformance.t16e0,
        jpegls_conformance.t16e3, jpegls_conformance.test16_rm_5, jpegls_conformance.test8_ilv_sample_rm_7,
    }) |data| {
        streams[n] = data;
        n += 1;
    };
    for (streams[0..n], 0..) |data, i| {
        var report = try jpegz.validate(allocator, data);
        defer report.deinit(allocator);
        const failed = for (report.findings.items) |f| {
            if (f.severity == .fail or f.code == .extraneous_bytes_before_marker or f.code == .jpegls_padding_not_zeros) break true;
        } else false;
        if (failed or report.codec_check != .decoded) {
            var label: [16]u8 = undefined;
            dumpFindings(std.fmt.bufPrint(&label, "stream {d}", .{i}) catch "stream", report);
            return error.TestUnexpectedResult;
        }
    }
}

test "JPEG-LS Golomb code past LIMIT is FAIL 122 and stops decoding" {
    const allocator = std.testing.allocator;
    const src = @embedFile("fixtures/jpegls_4x4_gray8.jls");
    // Entropy data is bytes 25..46 (EOI at 46). All zeros make the first
    // run-interruption code a unary prefix of 31 zeros; the escape is 22.
    var data = src.*;
    @memset(data[25..46], 0);
    try std.testing.expectError(error.BackendError, jpegz.jpegls_cleanroom_decode(allocator, &data));
    var report = try jpegz.validate(allocator, &data);
    defer report.deinit(allocator);
    const f = onlyFail(report, .jpegls_golomb_code_invalid) orelse {
        dumpFindings("zeroed entropy", report);
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(f.offset_is_exact and f.offset.? >= 25 and f.offset.? < 46);
}

test "JPEG-LS restart faults are FAIL 57 (wrong RSTm) and 56 (no RSTm) at the marker" {
    if (!jpegls_conformance.available) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    for ([_]struct { byte: u8, code: jpegz.FindingCode }{
        .{ .byte = 0xd3, .code = .restart_marker_unexpected },
        .{ .byte = 0xd9, .code = .restart_marker_missing },
    }) |case| {
        const data = try allocator.dupe(u8, jpegls_conformance.test16_rm_5);
        defer allocator.free(data);
        const first = std.mem.indexOf(u8, data, &.{ 0xff, 0xd0 }).?;
        const second = first + 2 + std.mem.indexOf(u8, data[first + 2 ..], &.{ 0xff, 0xd1 }).?;
        data[second + 1] = case.byte;
        var report = try jpegz.validate(allocator, data);
        defer report.deinit(allocator);
        const f = for (report.findings.items) |f| {
            if (f.code == case.code and f.severity == .fail) break f;
        } else {
            dumpFindings(@tagName(case.code), report);
            return error.TestUnexpectedResult;
        };
        try std.testing.expect(f.offset_is_exact);
        try std.testing.expectEqual(@as(u64, second), f.offset.?);
    }
}

test "JPEG-LS interval and scan ends: leftover bytes are 8, nonzero padding is FAIL 123" {
    if (!jpegls_conformance.available) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    // A byte inserted before a marker sits after the last coded bit: leftover.
    for ([_]struct { src: []const u8, marker: [2]u8, token: []const u8 }{
        .{ .src = jpegls_conformance.test16_rm_5, .marker = .{ 0xff, 0xd0 }, .token = "jpegls_interval" },
        .{ .src = jpegls_conformance.t8nde0, .marker = .{ 0xff, 0xd9 }, .token = "jpegls_scan_end" },
    }) |case| {
        const at = std.mem.lastIndexOf(u8, case.src[0 .. if (case.marker[1] == 0xd9) case.src.len else std.mem.indexOf(u8, case.src, &case.marker).? + 2], &case.marker).?;
        try std.testing.expect(case.src[at - 1] != 0xff);
        const data = try std.mem.concat(allocator, u8, &.{ case.src[0..at], &.{0x12}, case.src[at..] });
        defer allocator.free(data);
        var report = try jpegz.validate(allocator, data);
        defer report.deinit(allocator);
        const f = for (report.findings.items) |f| {
            if (f.code == .extraneous_bytes_before_marker) break f;
        } else {
            dumpFindings(case.token, report);
            return error.TestUnexpectedResult;
        };
        try std.testing.expect(f.offset_is_exact and f.offset.? == at);
        try std.testing.expectEqualStrings(case.token, f.detail.?);
    }
    // FF fill before a marker is marker syntax (T.87 C.1), not leftover data.
    {
        const src = jpegls_conformance.t8nde0;
        const at = src.len - 2;
        const filled = try std.mem.concat(allocator, u8, &.{ src[0..at], &.{ 0xff, 0xff }, src[at..] });
        defer allocator.free(filled);
        var report = try jpegz.validate(allocator, filled);
        defer report.deinit(allocator);
        for (report.findings.items) |item| {
            if (item.code == .extraneous_bytes_before_marker or item.code == .jpegls_padding_not_zeros) {
                dumpFindings("FF fill", report);
                return error.TestUnexpectedResult;
            }
        }
    }
    // The final entropy byte of t8nde0 ends in padding: set its lowest bit.
    {
        const src = jpegls_conformance.t8nde0;
        const last = src.len - 3;
        try std.testing.expectEqual(@as(u8, 0), src[last] & 1);
        const data = try allocator.dupe(u8, src);
        defer allocator.free(data);
        data[last] |= 1;
        var report = try jpegz.validate(allocator, data);
        defer report.deinit(allocator);
        const f = onlyFail(report, .jpegls_padding_not_zeros) orelse {
            dumpFindings("padding", report);
            return error.TestUnexpectedResult;
        };
        try std.testing.expect(f.offset_is_exact and f.offset.? == last);
    }
}

test "JPEG-LS LSE ID 1 outside Table C.1 is FAIL 121 at the LSE marker" {
    if (!jpegls_conformance.available) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    // t8nde0: FF F8 at 15, then Ll, ID 1, MAXVAL at 20, T1 22, T2 24, T3 26, RESET 28.
    const src = jpegls_conformance.t8nde0;
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xf8, 0, 13, 1, 0, 0xff, 0, 9, 0, 9, 0, 9, 0, 31 }, src[15..30]);
    for ([_]struct { at: usize, value: u16, token: []const u8 }{
        .{ .at = 20, .value = 256, .token = "maxval" },
        .{ .at = 22, .value = 10, .token = "thresholds" },
        .{ .at = 26, .value = 300, .token = "thresholds" },
        .{ .at = 28, .value = 2, .token = "reset" },
    }) |case| {
        const data = try allocator.dupe(u8, src);
        defer allocator.free(data);
        data[case.at] = @intCast(case.value >> 8);
        data[case.at + 1] = @truncate(case.value);
        var report = try jpegz.validate(allocator, data);
        defer report.deinit(allocator);
        const f = onlyFail(report, .jpegls_context_table_invalid) orelse {
            dumpFindings(case.token, report);
            return error.TestUnexpectedResult;
        };
        try std.testing.expect(f.offset_is_exact and f.offset.? == 15);
        try std.testing.expectEqualStrings(case.token, f.detail.?);
    }
}

test "JPEG-LS entropy that ends early is insufficient_data at the marker, truncated_stream at EOF" {
    if (!jpegls_conformance.available) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const src = jpegls_conformance.t8nde0;
    const cut = src.len / 2;
    // Cut mid-entropy and close with EOI: the walk is sound, reads stop at EOI.
    const early = try std.mem.concat(allocator, u8, &.{ src[0..cut], &.{ 0xff, 0xd9 } });
    defer allocator.free(early);
    var report = try jpegz.validate(allocator, early);
    defer report.deinit(allocator);
    const f = onlyFail(report, .insufficient_data) orelse {
        dumpFindings("cut + EOI", report);
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(f.offset_is_exact and f.offset.? == cut);
    // Truncation outranks the interval/scan-end checks (no 8 or 123 as well).
    for (report.findings.items) |item| {
        try std.testing.expect(item.code != .extraneous_bytes_before_marker and item.code != .jpegls_padding_not_zeros);
    }
    // Cut with no marker at all: the decoder alone sees the data end.
    var sink = jpegz.FindingsSink.init(allocator);
    defer sink.deinit();
    // Zero bits past the end may also form an invalid code; either way the
    // finding names the truncation, not the code.
    if (jpegz.internal.jpeglsDecodeWithFindings(allocator, src[0..cut], &sink)) |image| {
        var decoded = image;
        decoded.deinit(allocator);
    } else |_| {}
    var truncated = false;
    for (sink.items()) |item| {
        if (item.code == .truncated_stream and item.severity == .fail) truncated = true;
        if (item.code == .jpegls_golomb_code_invalid or item.code == .jpegls_invalid_run_mode) {
            std.debug.print("EOF cut reported a code fault: {t}\n", .{item.code});
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expect(truncated);
}

test "JPEG-LS ILV 0 (one scan per component): T.87 conformance t8c0e0 and t8c0e3" {
    // TEST8 coded with each component in its own scan, lossless and NEAR=3.
    if (!jpegls_conformance.available) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const want = pgmSamples(jpegls_conformance.test8);
    for ([_]struct { data: []const u8, near: i32 }{
        .{ .data = jpegls_conformance.t8c0e0, .near = 0 },
        .{ .data = jpegls_conformance.t8c0e3, .near = 3 },
    }) |case| {
        var image = try jpegz.jpegls_cleanroom_decode(allocator, case.data);
        defer image.deinit(allocator);
        try std.testing.expectEqual(@as(u8, 3), image.channels);
        try std.testing.expectEqual(want.len, image.pixels.len);
        var worst: i32 = 0;
        for (image.pixels, want) |got, ref| worst = @max(worst, @as(i32, @intCast(@abs(@as(i32, got) - @as(i32, ref)))));
        if (worst > case.near) {
            std.debug.print("ILV 0 NEAR={d}: worst sample error {d}\n", .{ case.near, worst });
            return error.TestUnexpectedResult;
        }
        var report = try jpegz.validate(allocator, case.data);
        defer report.deinit(allocator);
        try std.testing.expectEqual(.decoded, report.codec_check);
    }
    // A component coded by two scans (the second SOS names component 1 again).
    const twice = try allocator.dupe(u8, jpegls_conformance.t8c0e0);
    defer allocator.free(twice);
    const first_sos = std.mem.indexOf(u8, twice, &.{ 0xff, 0xda }).?;
    const second_sos = first_sos + 2 + std.mem.indexOf(u8, twice[first_sos + 2 ..], &.{ 0xff, 0xda }).?;
    twice[second_sos + 5] = twice[first_sos + 5];
    try std.testing.expectError(error.InvalidMarker, jpegz.jpegls_cleanroom_decode(allocator, twice));
}

test "JPEG-LS subsampled components decode to the T.87 Annex E reference planes: t8sse0/3" {
    // Line interleaved, R 256x256 (H 2, V 4), G 256x64 (H 2, V 1), B
    // 128x128 (H 1, V 2): each MCU is 4 lines of R, 1 of G and 2 of B
    // (T.87 B.2, B.4). The HP reference planes are the oracle: exact for
    // t8sse0, within NEAR 3 for t8sse3.
    if (!jpegls_conformance.available) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const refs = [_][]const u8{ pgmSamples(jpegls_conformance.test8r), pgmSamples(jpegls_conformance.test8gr4), pgmSamples(jpegls_conformance.test8bs2) };
    const sizes = [_][2]u32{ .{ 256, 256 }, .{ 256, 64 }, .{ 128, 128 } };
    for ([_][]const u8{ jpegls_conformance.t8sse0, jpegls_conformance.t8sse3 }, [_]u8{ 0, 3 }) |data, near| {
        var planes = try jpegz.jpegls_cleanroom_decode_planes(allocator, data);
        defer for (&planes) |*plane| if (plane.*) |*image| image.deinit(allocator);
        for (0..3) |c| {
            const plane = planes[c].?;
            try std.testing.expectEqual(sizes[c][0], plane.width);
            try std.testing.expectEqual(sizes[c][1], plane.height);
            try std.testing.expectEqual(refs[c].len, plane.pixels.len);
            for (refs[c], plane.pixels) |want, got| {
                try std.testing.expect(@max(want, got) - @min(want, got) <= near);
            }
        }
        try std.testing.expect(planes[3] == null);
        // One raster cannot hold unequal planes: the decode API still refuses.
        try std.testing.expectError(error.NotImplemented, jpegz.jpegls_cleanroom_decode(allocator, data));
        var report = try jpegz.validate(allocator, data);
        defer report.deinit(allocator);
        try std.testing.expectEqual(.decoded, report.codec_check);
        for (report.findings.items) |f| try std.testing.expect(f.severity == .info);
    }
}

test "JPEG-LS decodePlanes de-interleaves frames without subsampling" {
    if (!jpegls_conformance.available) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var image = try jpegz.jpegls_cleanroom_decode(allocator, jpegls_conformance.t8c0e0);
    defer image.deinit(allocator);
    var planes = try jpegz.jpegls_cleanroom_decode_planes(allocator, jpegls_conformance.t8c0e0);
    defer for (&planes) |*plane| if (plane.*) |*p| p.deinit(allocator);
    for (0..3) |c| {
        for (planes[c].?.pixels, 0..) |v, i| try std.testing.expectEqual(image.pixels[i * 3 + c], v);
    }
}

test "JPEG-LS LSE ID 4 oversize dimensions: 65536x1 and 1x65536" {
    // CharLS 3.0 writes SOF55 X = Y = 0 and an LSE ID 4 (T.87 C.2.4.1.4)
    // when a dimension exceeds 65535. Samples are the staircase v = i >> 8,
    // so the formula is the oracle.
    const allocator = std.testing.allocator;
    for ([_]struct { data: []const u8, width: u32, height: u32 }{
        .{ .data = @embedFile("fixtures/jpegls_65536x1_gray8.jls"), .width = 65536, .height = 1 },
        .{ .data = @embedFile("fixtures/jpegls_1x65536_gray8.jls"), .width = 1, .height = 65536 },
    }) |case| {
        var image = try jpegz.jpegls_cleanroom_decode(allocator, case.data);
        defer image.deinit(allocator);
        try std.testing.expectEqual(case.width, image.width);
        try std.testing.expectEqual(case.height, image.height);
        for (image.pixels, 0..) |sample, i| {
            if (sample != @as(u8, @intCast(i >> 8))) {
                std.debug.print("{d}x{d}: sample {d} is {d}\n", .{ case.width, case.height, i, sample });
                return error.TestUnexpectedResult;
            }
        }
        var report = try jpegz.validate(allocator, case.data);
        defer report.deinit(allocator);
        try std.testing.expectEqual(@as(?u32, case.width), report.width);
        try std.testing.expectEqual(@as(?u32, case.height), report.height);
        try std.testing.expectEqual(.decoded, report.codec_check);
        for (report.findings.items) |f| if (f.severity == .fail) {
            dumpFindings("oversize", report);
            return error.TestUnexpectedResult;
        };
    }
    // A nonzero SOF dimension beside a nonzero LSE value contradicts it.
    const src = @embedFile("fixtures/jpegls_65536x1_gray8.jls");
    var conflict = src.*;
    conflict[8] = 1; // SOF55 Y low byte: Y = 1 while the LSE also gives Ye = 1.
    try std.testing.expectError(error.InvalidMarker, jpegz.jpegls_cleanroom_decode(allocator, &conflict));
}

test "JPEG-LS mapping table (CharLS, TID 1, Wt 1) maps the decoded samples (T.87 clause 7)" {
    const allocator = std.testing.allocator;
    var image = try jpegz.jpegls_cleanroom_decode(allocator, map_src);
    defer image.deinit(allocator);
    try expectMapped(image);
    var report = try jpegz.validate(allocator, map_src);
    defer report.deinit(allocator);
    try std.testing.expectEqual(.decoded, report.codec_check);
    for (report.findings.items) |f| try std.testing.expect(f.severity == .info);
}

test "JPEG-LS mapping table split into LSE ID 2 and an ID 3 continuation decodes the same" {
    const allocator = std.testing.allocator;
    const entries = map_src[9..265];
    const spec = try lseMapping(allocator, 2, 1, 1, entries[0..100]);
    defer allocator.free(spec);
    const cont = try lseMapping(allocator, 3, 1, 1, entries[100..]);
    defer allocator.free(cont);
    const data = try withTables(allocator, &.{ spec, &.{ 0xff, 0xff }, cont });
    defer allocator.free(data);
    var image = try jpegz.jpegls_cleanroom_decode(allocator, data);
    defer image.deinit(allocator);
    try expectMapped(image);
    var report = try jpegz.validate(allocator, data);
    defer report.deinit(allocator);
    try std.testing.expectEqual(.decoded, report.codec_check);
    for (report.findings.items) |f| try std.testing.expect(f.severity == .info);
}

test "JPEG-LS scan naming an unspecified mapping table is FAIL 124 at its Tmi byte" {
    const allocator = std.testing.allocator;
    const data = try allocator.dupe(u8, map_src);
    defer allocator.free(data);
    data[284] = 2;
    try std.testing.expectError(error.BackendError, jpegz.jpegls_cleanroom_decode(allocator, data));
    var report = try jpegz.validate(allocator, data);
    defer report.deinit(allocator);
    const f = onlyFail(report, .jpegls_mapping_table_undefined) orelse {
        dumpFindings("124", report);
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(f.offset_is_exact and f.offset.? == 284);
}

test "JPEG-LS mapping table with a point transform is WARN 125; the table applies, Pt does not" {
    const allocator = std.testing.allocator;
    const data = try allocator.dupe(u8, map_src);
    defer allocator.free(data);
    data[287] = 1;
    var image = try jpegz.jpegls_cleanroom_decode(allocator, data);
    defer image.deinit(allocator);
    try expectMapped(image);
    var report = try jpegz.validate(allocator, data);
    defer report.deinit(allocator);
    try std.testing.expectEqual(.decoded, report.codec_check);
    var warned = false;
    for (report.findings.items) |f| {
        try std.testing.expect(f.severity != .fail);
        if (f.code == .jpegls_mapping_with_point_transform) {
            try std.testing.expectEqual(jpegz.Severity.warn, f.severity);
            try std.testing.expect(f.offset_is_exact and f.offset.? == 284);
            warned = true;
        }
    }
    try std.testing.expect(warned);
}

