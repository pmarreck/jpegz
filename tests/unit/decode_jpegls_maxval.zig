//! decode tests, part 4 (split from decode.zig to keep files small).

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

test "JPEG-LS malformed mapping tables are FAIL 126 with one token per rule" {
    const allocator = std.testing.allocator;
    const entries = map_src[9..265];
    const Case = struct { token: []const u8, data: []u8, offset: usize };
    var cases: std.ArrayList(Case) = .empty;
    defer {
        for (cases.items) |c| allocator.free(c.data);
        cases.deinit(allocator);
    }
    {
        const d = try allocator.dupe(u8, map_src);
        d[7] = 0;
        try cases.append(allocator, .{ .token = "tid_range", .data = d, .offset = 7 });
    }
    {
        const d = try allocator.dupe(u8, map_src);
        d[8] = 0;
        try cases.append(allocator, .{ .token = "wt_range", .data = d, .offset = 8 });
    }
    {
        // Wt 2 with 255 bytes of entries: not a whole number of entries.
        const seg = try lseMapping(allocator, 2, 1, 2, entries[0..255]);
        defer allocator.free(seg);
        try cases.append(allocator, .{ .token = "length", .data = try withTables(allocator, &.{seg}), .offset = 4 });
    }
    {
        const d = try allocator.dupe(u8, map_src);
        d[6] = 3;
        try cases.append(allocator, .{ .token = "continuation", .data = d, .offset = 2 });
    }
    {
        // A continuation whose TID differs from the table before it.
        const spec = try lseMapping(allocator, 2, 1, 1, entries[0..100]);
        defer allocator.free(spec);
        const cont = try lseMapping(allocator, 3, 9, 1, entries[100..]);
        defer allocator.free(cont);
        try cases.append(allocator, .{ .token = "continuation", .data = try withTables(allocator, &.{ spec, cont }), .offset = 2 + spec.len });
    }
    {
        // A continuation with another segment (COM) between it and its table.
        const spec = try lseMapping(allocator, 2, 1, 1, entries[0..100]);
        defer allocator.free(spec);
        const cont = try lseMapping(allocator, 3, 1, 1, entries[100..]);
        defer allocator.free(cont);
        const com = [_]u8{ 0xff, 0xfe, 0x00, 0x03, 0x41 };
        try cases.append(allocator, .{ .token = "continuation", .data = try withTables(allocator, &.{ spec, &com, cont }), .offset = 2 + spec.len + com.len });
    }
    {
        // A continuation whose Wt differs from the table before it.
        const spec = try lseMapping(allocator, 2, 1, 1, entries[0..100]);
        defer allocator.free(spec);
        const cont = try lseMapping(allocator, 3, 1, 2, entries[100..]);
        defer allocator.free(cont);
        try cases.append(allocator, .{ .token = "continuation", .data = try withTables(allocator, &.{ spec, cont }), .offset = 2 + spec.len });
    }
    {
        // 200 entries where MAXVAL 255 needs 256.
        const seg = try lseMapping(allocator, 2, 1, 1, entries[0..200]);
        defer allocator.free(seg);
        try cases.append(allocator, .{ .token = "entries", .data = try withTables(allocator, &.{seg}), .offset = 2 });
    }
    {
        // A second, unreferenced table with Wt 0 still FAILs.
        const spec = try lseMapping(allocator, 2, 1, 1, entries);
        defer allocator.free(spec);
        const bad = try lseMapping(allocator, 2, 7, 0, &.{0});
        defer allocator.free(bad);
        try cases.append(allocator, .{ .token = "wt_range", .data = try withTables(allocator, &.{ spec, bad }), .offset = 2 + spec.len + 6 });
    }
    for (cases.items) |c| {
        var report = try jpegz.validate(allocator, c.data);
        defer report.deinit(allocator);
        const f = onlyFail(report, .jpegls_mapping_table_invalid) orelse {
            dumpFindings(c.token, report);
            return error.TestUnexpectedResult;
        };
        if (!std.mem.startsWith(u8, f.detail.?, c.token) or !f.offset_is_exact or f.offset.? != c.offset) {
            std.debug.print("{s}: offset {?d} detail {s}\n", .{ c.token, f.offset, f.detail.? });
            return error.TestUnexpectedResult;
        }
    }
}

test "JPEG-LS LSE MAXVAL decoding only under CharLS's RANGE-from-P coding is unsupported with INFO 127" {
    // Stock CharLS 3.0, MAXVAL 200 at P = 8: CharLS takes RANGE, qbpp, bpp
    // and LIMIT from 2^P - 1; T.87 A.2.1 takes them from MAXVAL.
    const allocator = std.testing.allocator;
    const data = @embedFile("fixtures/jpegls_16x16_gray8_maxval200.jls");
    try std.testing.expectError(error.NotImplemented, jpegz.jpegls_cleanroom_decode(allocator, data));
    var report = try jpegz.validate(allocator, data);
    defer report.deinit(allocator);
    try std.testing.expectEqual(.unsupported, report.codec_check);
    for (report.findings.items) |f| try std.testing.expect(f.severity != .fail);
    const f = maxvalDerivation(report) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(jpegz.Severity.info, f.severity);
    try std.testing.expect(f.offset_is_exact and f.offset.? == std.mem.indexOf(u8, data, &.{ 0xff, 0xf8 }).?);
    try std.testing.expect(std.mem.startsWith(u8, f.detail.?, "only_charls"));
}

test "JPEG-LS LSE MAXVAL scan clean under neither coding keeps the A.2.1 findings" {
    // The CharLS MAXVAL 200 stream cut inside its entropy data, then EOI:
    // both codings run out of data, so the A.2.1 truncation finding stands.
    const allocator = std.testing.allocator;
    const src = @embedFile("fixtures/jpegls_16x16_gray8_maxval200.jls");
    const sos = std.mem.indexOf(u8, src, &.{ 0xff, 0xda }).?;
    const cut = sos + 2 + std.mem.readInt(u16, src[sos + 2 ..][0..2], .big) + 20;
    const data = try std.mem.concat(allocator, u8, &.{ src[0..cut], &.{ 0xff, 0xd9 } });
    defer allocator.free(data);
    var report = try jpegz.validate(allocator, data);
    defer report.deinit(allocator);
    try std.testing.expect(maxvalDerivation(report) == null);
    const f = onlyFail(report, .insufficient_data) orelse {
        dumpFindings("maxval cut", report);
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(f.offset_is_exact and f.offset.? == cut);
}

test "JPEG-LS LSE MAXVAL below 2^P-1 decodes per T.87 A.2.1 (spec-coded, FFmpeg-verified)" {
    const allocator = std.testing.allocator;
    for ([_]struct { jls: []const u8, raw: []const u8, bits: u8 }{
        .{ .jls = @embedFile("fixtures/jpegls_32x32_gray8_maxval63.jls"), .raw = @embedFile("fixtures/jpegls_32x32_gray8_maxval63.raw"), .bits = 8 },
        .{ .jls = @embedFile("fixtures/jpegls_32x32_gray12_maxval1023.jls"), .raw = @embedFile("fixtures/jpegls_32x32_gray12_maxval1023.raw"), .bits = 12 },
    }) |case| {
        var image = try jpegz.jpegls_cleanroom_decode(allocator, case.jls);
        defer image.deinit(allocator);
        try std.testing.expectEqual(case.bits, image.bits_per_sample);
        // The raw files are u8, or little-endian u16; the image is host order.
        if (case.bits == 8) {
            try std.testing.expectEqualSlices(u8, case.raw, image.pixels);
        } else {
            try std.testing.expectEqual(case.raw.len, image.pixels.len);
            var i: usize = 0;
            while (i < case.raw.len) : (i += 2) {
                const want = std.mem.readInt(u16, case.raw[i..][0..2], .little);
                const got = std.mem.readInt(u16, image.pixels[i..][0..2], @import("builtin").cpu.arch.endian());
                try std.testing.expectEqual(want, got);
            }
        }
        var report = try jpegz.validate(allocator, case.jls);
        defer report.deinit(allocator);
        try std.testing.expectEqual(.decoded, report.codec_check);
        try std.testing.expect(maxvalDerivation(report) == null);
        for (report.findings.items) |f| try std.testing.expect(f.severity == .info);
    }
}

test "JPEG-LS MAXVAL oracle set: 144 stock CharLS 3.0 streams classify by coding" {
    const allocator = std.testing.allocator;
    const streams = comptime maxvalPack("fixtures/jpegls_maxval_charls30.jlspack");
    try std.testing.expectEqual(@as(usize, 144), streams.len);
    var only: usize = 0;
    var both: usize = 0;
    for (streams) |s| {
        var report = try jpegz.validate(allocator, s.data);
        defer report.deinit(allocator);
        for (report.findings.items) |f| if (f.severity == .fail) {
            std.debug.print("{s}: unexpected FAIL\n", .{s.name});
            return error.TestUnexpectedResult;
        };
        const f = maxvalDerivation(report) orelse {
            std.debug.print("{s}: no INFO 127\n", .{s.name});
            return error.TestUnexpectedResult;
        };
        if (bothCodings(s)) {
            try std.testing.expect(std.mem.startsWith(u8, f.detail.?, "also_charls"));
            try std.testing.expectEqual(.decoded, report.codec_check);
            var image = try jpegz.jpegls_cleanroom_decode(allocator, s.data);
            defer image.deinit(allocator);
            try std.testing.expect(s.matches(image));
            both += 1;
        } else {
            if (!std.mem.startsWith(u8, f.detail.?, "only_charls")) {
                std.debug.print("{s}: {s}\n", .{ s.name, f.detail.? });
                return error.TestUnexpectedResult;
            }
            try std.testing.expectEqual(.unsupported, report.codec_check);
            only += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 132), only);
    try std.testing.expectEqual(@as(usize, 12), both);
}

test "JPEG-LS MAXVAL oracle set: 72 spec-coded streams decode to their sources (T.87 A.2.1)" {
    const allocator = std.testing.allocator;
    const streams = comptime maxvalPack("fixtures/jpegls_maxval_specmode.jlspack");
    try std.testing.expectEqual(@as(usize, 72), streams.len);
    for (streams) |s| {
        var image = jpegz.jpegls_cleanroom_decode(allocator, s.data) catch |err| {
            std.debug.print("{s}: {s}\n", .{ s.name, @errorName(err) });
            return err;
        };
        defer image.deinit(allocator);
        if (!s.matches(image)) {
            std.debug.print("{s}: samples differ from the source\n", .{s.name});
            return error.TestUnexpectedResult;
        }
        var report = try jpegz.validate(allocator, s.data);
        defer report.deinit(allocator);
        try std.testing.expectEqual(.decoded, report.codec_check);
        for (report.findings.items) |f| try std.testing.expect(f.severity == .info);
        const f = maxvalDerivation(report);
        try std.testing.expectEqual(bothCodings(s), f != null);
        if (f) |info| try std.testing.expect(std.mem.startsWith(u8, info.detail.?, "also_charls"));
    }
}

test "JPEG-LS LSE MAXVAL stream valid under both codings is valid with INFO 127 also_charls" {
    // MAXVAL 63, NEAR 1, smooth content: stock and spec-mode CharLS write the
    // same bytes, so both codings decode it cleanly.
    const allocator = std.testing.allocator;
    const data = @embedFile("fixtures/jpegls_32x32_gray8_maxval63_near1.jls");
    const raw = @embedFile("fixtures/jpegls_32x32_gray8_maxval63_near1.raw");
    var image = try jpegz.jpegls_cleanroom_decode(allocator, data);
    defer image.deinit(allocator);
    try std.testing.expectEqual(raw.len, image.pixels.len);
    for (raw, image.pixels) |want, got| try std.testing.expect(@abs(@as(i16, want) - @as(i16, got)) <= 1);
    var report = try jpegz.validate(allocator, data);
    defer report.deinit(allocator);
    try std.testing.expectEqual(.decoded, report.codec_check);
    const f = maxvalDerivation(report) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(jpegz.Severity.info, f.severity);
    try std.testing.expect(f.offset_is_exact and f.offset.? == std.mem.indexOf(u8, data, &.{ 0xff, 0xf8 }).?);
    try std.testing.expect(std.mem.startsWith(u8, f.detail.?, "also_charls"));
}

test "B2.2 NEAR=2: JPEG-LS 8x8 grayscale near-lossless cleanroom (direct entry)" {
    const allocator = std.testing.allocator;
    var image = try jpegz.jpegls_cleanroom_decode(allocator, fixture_jpegls_8x8_gray8_near2);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 8), image.width);
    try std.testing.expectEqual(@as(u32, 8), image.height);
    try std.testing.expectEqual(@as(u8, 1), image.channels);
    try std.testing.expectEqual(@as(u8, 8), image.bits_per_sample);
    try std.testing.expectEqual(@as(usize, 64), image.pixels.len);

    // Near-lossless guarantee: every reconstructed sample is within
    // NEAR of the original. (NEAR=2 here.)
    const NEAR: i32 = 2;
    for (image.pixels, fixture_jpegls_8x8_gray8_near2_raw) |dec, orig| {
        const diff = @abs(@as(i32, dec) - @as(i32, orig));
        try std.testing.expect(diff <= NEAR);
    }
}

test "B2.2 RGB16: JPEG-LS 4x4 RGB 16-bit cleanroom (direct entry)" {
    const allocator = std.testing.allocator;
    var image = try jpegz.jpegls_cleanroom_decode(allocator, fixture_jpegls_4x4_rgb16);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 4), image.width);
    try std.testing.expectEqual(@as(u32, 4), image.height);
    try std.testing.expectEqual(@as(u8, 3), image.channels);
    try std.testing.expectEqual(@as(u8, 16), image.bits_per_sample);
    try std.testing.expectEqual(jpegz.PixelLayout.rgb, image.layout);
    try std.testing.expectEqual(@as(usize, 4 * 4 * 3 * 2), image.pixels.len);
    const px = image.pixelsU16();
    try std.testing.expectEqual(@as(usize, 4 * 4 * 3), px.len);
    var y: u32 = 0;
    while (y < 4) : (y += 1) {
        var x: u32 = 0;
        while (x < 4) : (x += 1) {
            const off: usize = (@as(usize, y) * 4 + @as(usize, x)) * 3;
            try std.testing.expectEqual(@as(u16, @intCast(x * 0x4000)), px[off]);
            try std.testing.expectEqual(@as(u16, @intCast(y * 0x4000)), px[off + 1]);
            try std.testing.expectEqual(@as(u16, @intCast((x + y) * 0x2000)), px[off + 2]);
        }
    }
}

test "B2.2 §3: JPEG-LS 4x4 RGB 8-bit cleanroom (direct entry, no charls fallback)" {
    const allocator = std.testing.allocator;
    var image = try jpegz.jpegls_cleanroom_decode(allocator, fixture_jpegls_4x4_rgb8);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 4), image.width);
    try std.testing.expectEqual(@as(u32, 4), image.height);
    try std.testing.expectEqual(@as(u8, 3), image.channels);
    try std.testing.expectEqual(@as(u8, 8), image.bits_per_sample);
    try std.testing.expectEqual(jpegz.PixelLayout.rgb, image.layout);
    try std.testing.expectEqual(@as(usize, 4 * 4 * 3), image.pixels.len);
    var y: u32 = 0;
    while (y < 4) : (y += 1) {
        var x: u32 = 0;
        while (x < 4) : (x += 1) {
            const off: usize = (@as(usize, y) * 4 + @as(usize, x)) * 3;
            try std.testing.expectEqual(@as(u8, @intCast(x * 0x40)), image.pixels[off]);
            try std.testing.expectEqual(@as(u8, @intCast(y * 0x40)), image.pixels[off + 1]);
            try std.testing.expectEqual(@as(u8, @intCast((x + y) * 0x20)), image.pixels[off + 2]);
        }
    }
}

test "B2: JPEG-LS 4x4 RGB 8-bit lossless round-trip" {
    const allocator = std.testing.allocator;
    var image = try jpegz.decode(allocator, fixture_jpegls_4x4_rgb8);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 4), image.width);
    try std.testing.expectEqual(@as(u32, 4), image.height);
    try std.testing.expectEqual(@as(u8, 3), image.channels);
    try std.testing.expectEqual(@as(u8, 8), image.bits_per_sample);
    try std.testing.expectEqual(jpegz.PixelLayout.rgb, image.layout);
    try std.testing.expectEqual(@as(usize, 4 * 4 * 3), image.pixels.len);
    var y: u32 = 0;
    while (y < 4) : (y += 1) {
        var x: u32 = 0;
        while (x < 4) : (x += 1) {
            const off: usize = (@as(usize, y) * 4 + @as(usize, x)) * 3;
            try std.testing.expectEqual(@as(u8, @intCast(x * 0x40)), image.pixels[off]);
            try std.testing.expectEqual(@as(u8, @intCast(y * 0x40)), image.pixels[off + 1]);
            try std.testing.expectEqual(@as(u8, @intCast((x + y) * 0x20)), image.pixels[off + 2]);
        }
    }
}

test "B1 SOF10: arithmetic progressive cleanroom (gray + RGB at all sampling factors)" {
    const allocator = std.testing.allocator;
    const RgbCase = struct { data: []const u8 };
    const rgb_cases = [_]RgbCase{
        .{ .data = fixture_arith_progressive_16x16_rgb_444 },
        .{ .data = fixture_arith_progressive_16x16_rgb_420 },
        .{ .data = fixture_arith_progressive_16x16_rgb_422 },
        .{ .data = fixture_arith_progressive_16x16_rgb_440 },
    };
    inline for (rgb_cases) |c| {
        var cleanroom = try jpegz.internal.arithDecode(allocator, c.data);
        defer cleanroom.deinit(allocator);
        var wrapper = try jpegz.internal.wrapperDecode(allocator, c.data);
        defer wrapper.deinit(allocator);
        try std.testing.expectEqual(@as(u8, 8), cleanroom.bits_per_sample);
        try std.testing.expectEqual(@as(u8, 3), cleanroom.channels);
        try std.testing.expectEqual(@as(u32, 16), cleanroom.width);
        try std.testing.expectEqual(@as(u32, 16), cleanroom.height);
        try std.testing.expectEqual(jpegz.PixelLayout.rgb, cleanroom.layout);
        try std.testing.expectEqual(wrapper.pixels.len, cleanroom.pixels.len);
        // 2026-05-16: libjpeg-turbo asymmetric-bias fancy upsample fix in
        // color.fancyUpsample / baseline.fancyUpsample brought subsampled-
        // RGB arith from ≤2 LSB to byte-exact. Tightened from ≤4 to ==0.
        try std.testing.expectEqualSlices(u8, wrapper.pixels, cleanroom.pixels);
    }
    {
        var cleanroom = try jpegz.internal.arithDecode(allocator, fixture_arith_progressive_8x8_gray);
        defer cleanroom.deinit(allocator);
        var wrapper = try jpegz.internal.wrapperDecode(allocator, fixture_arith_progressive_8x8_gray);
        defer wrapper.deinit(allocator);
        try std.testing.expectEqual(@as(u8, 1), cleanroom.channels);
        try std.testing.expectEqual(jpegz.PixelLayout.grayscale, cleanroom.layout);
        var max_delta: u8 = 0;
        for (cleanroom.pixels, wrapper.pixels) |a, b| {
            const d: u8 = @intCast(@abs(@as(i32, a) - @as(i32, b)));
            if (d > max_delta) max_delta = d;
        }
        try std.testing.expect(max_delta <= 2);
    }
}

