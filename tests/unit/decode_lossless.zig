//! decode tests, part 6 (split from decode.zig to keep files small).

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

test "M2.8: lossless SOF3 cleanroom decodes 12/14/16-bit grayscale precision byte-for-byte" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { data: []const u8, bps: u8, expected: u16 }{
        .{ .data = fixture_lossless_4x4_gray12, .bps = 12, .expected = 0x0800 },
        .{ .data = fixture_lossless_4x4_gray14, .bps = 14, .expected = 0x2000 },
        .{ .data = fixture_lossless_4x4_gray16, .bps = 16, .expected = 0x8000 },
    };
    inline for (cases) |c| {
        var cleanroom = try jpegz.internal.losslessDecode(allocator, c.data);
        defer cleanroom.deinit(allocator);
        var wrapper = try jpegz.internal.wrapperDecode(allocator, c.data);
        defer wrapper.deinit(allocator);
        try std.testing.expectEqual(c.bps, cleanroom.bits_per_sample);
        try std.testing.expectEqual(wrapper.bits_per_sample, cleanroom.bits_per_sample);
        try std.testing.expectEqualSlices(u8, wrapper.pixels, cleanroom.pixels);
        const px = cleanroom.pixelsU16();
        for (px) |s| try std.testing.expectEqual(c.expected, s);
    }
}

test "M2.7: lossless SOF3 cleanroom decodes a JPEG with DRI > 0 byte-for-byte" {
    const allocator = std.testing.allocator;
    var cleanroom = try jpegz.internal.losslessDecode(allocator, fixture_lossless_dri);
    defer cleanroom.deinit(allocator);
    var wrapper = try jpegz.internal.wrapperDecode(allocator, fixture_lossless_dri);
    defer wrapper.deinit(allocator);
    try std.testing.expectEqualSlices(u8, wrapper.pixels, cleanroom.pixels);
}

test "M2.6: lossless SOF3 cleanroom decodes 3-component RGB byte-for-byte" {
    const allocator = std.testing.allocator;
    var cleanroom = try jpegz.internal.losslessDecode(allocator, fixture_lossless_4x4_rgb);
    defer cleanroom.deinit(allocator);
    var wrapper = try jpegz.internal.wrapperDecode(allocator, fixture_lossless_4x4_rgb);
    defer wrapper.deinit(allocator);
    try std.testing.expectEqual(wrapper.width, cleanroom.width);
    try std.testing.expectEqual(wrapper.height, cleanroom.height);
    try std.testing.expectEqual(wrapper.channels, cleanroom.channels);
    // Lossless = exact reconstruction; ANY pixel mismatch is a real bug.
    try std.testing.expectEqualSlices(u8, wrapper.pixels, cleanroom.pixels);
}

test "lossless direct decode rejects zero width before restart-row arithmetic" {
	const allocator = std.testing.allocator;
	for ([_]u8{ 0, 1 }) |interval| {
		const data = [_]u8{ 0xff, 0xd8, 0xff, 0xc3, 0, 11, 8, 0, 1, 0, 0, 1, 1, 0x11, 0 } ++
			[_]u8{ 0xff, 0xc4, 0, 20, 0, 1 } ++ ([_]u8{0} ** 15) ++ [_]u8{0} ++
			[_]u8{ 0xff, 0xdd, 0, 4, 0, interval, 0xff, 0xda, 0, 8, 1, 1, 0, 1, 0, 0, 0xff, 0xd9 };
		if (jpegz.internal.losslessDecode(allocator, &data)) |image| {
			var unexpected = image;
			unexpected.deinit(allocator);
			return error.ExpectedDecodeFailure;
		} else |err| try std.testing.expectEqual(error.InvalidMarker, err);
	}
}

test "lossless predictors reset for an entire restart row then resume below it" {
	// T.81 H.1.2.1. DC codes 00/01/10 represent categories 0/1/3.
	// 0x76 = 011|10110 encodes +1,+6; 0xa3 = 10100|011 encodes +4,+1.
	// The first row of EVERY interval uses horizontal prediction, regardless
	// of Ss. Rows below it use the selected predictor. No entropy encoder here.
	const allocator = std.testing.allocator;
	const second_row_right = [_]u8{ 134, 136, 130, 140, 137, 138, 135 };
	for (second_row_right, 1..) |right, predictor| {
		const cases = [_]struct { height: u8, interval: u8, entropy: []const u8, pixels: []const u8 }{
			.{ .height = 2, .interval = 2, .entropy = &.{ 0x76, 0xff, 0xd0, 0xa3 }, .pixels = &.{ 129, 135, 132, 133 } },
			.{ .height = 2, .interval = 0, .entropy = &.{ 0x76, 0xa3 }, .pixels = &.{ 129, 135, 133, right } },
			.{ .height = 4, .interval = 4, .entropy = &.{ 0x76, 0xa3, 0xff, 0xd0, 0x76, 0xa3 },
				.pixels = &.{ 129, 135, 133, right, 129, 135, 133, right } },
		};
		for (cases) |case| {
			const header = [_]u8{ 0xff, 0xd8, 0xff, 0xc3, 0, 11, 8, 0, case.height, 0, 2, 1, 1, 0x11, 0 } ++
				[_]u8{ 0xff, 0xc4, 0, 22, 0, 0, 3 } ++ ([_]u8{0} ** 14) ++ [_]u8{ 0, 1, 3 };
			const data = try std.mem.concat(allocator, u8, &.{ &header,
				&.{ 0xff, 0xdd, 0, 4, 0, case.interval, 0xff, 0xda, 0, 8, 1, 1, 0, @intCast(predictor), 0, 0 },
				case.entropy, &.{ 0xff, 0xd9 },
			});
			defer allocator.free(data);
			var decoded = try jpegz.decode(allocator, data);
			defer decoded.deinit(allocator);
			try std.testing.expectEqualSlices(u8, case.pixels, decoded.pixels);
			var oracle = jpegz.internal.wrapperDecode(allocator, data) catch |err| switch (err) {
				error.NotImplemented => continue,
				else => return err,
			};
			defer oracle.deinit(allocator);
			try std.testing.expectEqualSlices(u8, case.pixels, oracle.pixels);
		}
	}
}

test "M2.4: lossless SOF3 cleanroom decodes 4x4 gradient with predictors 2..7 byte-for-byte" {
    const allocator = std.testing.allocator;
    const expected = [_]u8{ 0x00, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80, 0x90, 0xA0, 0xB0, 0xC0, 0xD0, 0xE0, 0xF0 };
    const fixtures = [_][]const u8{
        fixture_lossless_gradient_pred2,
        fixture_lossless_gradient_pred3,
        fixture_lossless_gradient_pred4,
        fixture_lossless_gradient_pred5,
        fixture_lossless_gradient_pred6,
        fixture_lossless_gradient_pred7,
    };
    inline for (fixtures, 2..) |fix, psv| {
        var cleanroom = try jpegz.internal.losslessDecode(allocator, fix);
        defer cleanroom.deinit(allocator);
        var wrapper = try jpegz.internal.wrapperDecode(allocator, fix);
        defer wrapper.deinit(allocator);
        std.testing.expectEqualSlices(u8, wrapper.pixels, cleanroom.pixels) catch |e| {
            std.debug.print("predictor {d} mismatch vs wrapper\n", .{psv});
            return e;
        };
        std.testing.expectEqualSlices(u8, &expected, cleanroom.pixels) catch |e| {
            std.debug.print("predictor {d} mismatch vs original gradient\n", .{psv});
            return e;
        };
    }
}

test "M2.4: lossless SOF3 cleanroom decodes 4x4 gradient byte-for-byte (predictor 1)" {
    const allocator = std.testing.allocator;
    var cleanroom = try jpegz.internal.losslessDecode(allocator, fixture_lossless_gradient_pred1);
    defer cleanroom.deinit(allocator);
    var wrapper = try jpegz.internal.wrapperDecode(allocator, fixture_lossless_gradient_pred1);
    defer wrapper.deinit(allocator);
    try std.testing.expectEqualSlices(u8, wrapper.pixels, cleanroom.pixels);
    // Sanity: original pattern preserved.
    const expected = [_]u8{ 0x00, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80, 0x90, 0xA0, 0xB0, 0xC0, 0xD0, 0xE0, 0xF0 };
    try std.testing.expectEqualSlices(u8, &expected, cleanroom.pixels);
}

test "M2.4: lossless 8-bit grayscale SOF3 cleanroom matches wrapper byte-for-byte" {
    // T.81 §H — Lossless predictive coding. Sample values reconstructed
    // exactly via predictor + Huffman-coded difference; no DCT, no
    // quantization, no IDCT rounding. Cleanroom output MUST be
    // byte-identical to wrapper for any SOF3 input we accept.
    const allocator = std.testing.allocator;
    var cleanroom = try jpegz.internal.losslessDecode(allocator, fixture_lossless_4x4_gray8);
    defer cleanroom.deinit(allocator);
    var wrapper = try jpegz.internal.wrapperDecode(allocator, fixture_lossless_4x4_gray8);
    defer wrapper.deinit(allocator);
    try std.testing.expectEqual(wrapper.width, cleanroom.width);
    try std.testing.expectEqual(wrapper.height, cleanroom.height);
    try std.testing.expectEqual(wrapper.channels, cleanroom.channels);
    try std.testing.expectEqual(wrapper.bits_per_sample, cleanroom.bits_per_sample);
    try std.testing.expectEqualSlices(u8, wrapper.pixels, cleanroom.pixels);
}

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

// ── Cleanroom FindingsSink (NEXT_STEPS §"Validation-strictness") ─────
//
// The cleanroom baseline decoder tolerates "extraneous bytes before
// marker" (T.81 §B.1.1.2 marker self-synchronization) — same behavior
// as djpeg/libjpeg-turbo, which would WARNMS about it. When a caller
// attaches a `FindingsSink`, the cleanroom must surface that tolerance
// as a `Finding(.warn, .extraneous_bytes_before_marker)` so strict
// consumers (validate, format-integrity tools) see the spec deviation.

test "cleanroom emits Finding(.warn, .extraneous_bytes_before_marker) when tolerated" {
    const allocator = std.testing.allocator;

    // Inject 4 garbage bytes between SOI (offset 0..1) and the next
    // marker. The cleanroom's marker walker scans forward past 0xAA's
    // until it finds the next 0xFF, decode succeeds (tolerance), and
    // the sink should receive a warn finding for the skip.
    var corrupted = try allocator.alloc(u8, fixture_baseline_2x2_rgb.len + 4);
    defer allocator.free(corrupted);
    @memcpy(corrupted[0..2], fixture_baseline_2x2_rgb[0..2]);
    corrupted[2] = 0xAA;
    corrupted[3] = 0xAA;
    corrupted[4] = 0xAA;
    corrupted[5] = 0xAA;
    @memcpy(corrupted[6..], fixture_baseline_2x2_rgb[2..]);

    var sink = jpegz.FindingsSink.init(allocator);
    defer sink.deinit();

    var image = try jpegz.internal.cleanroomDecodeWithFindings(allocator, corrupted, &sink);
    defer image.deinit(allocator);

    // Decode must still succeed — tolerance is the whole point.
    try std.testing.expectEqual(@as(u32, 2), image.width);
    try std.testing.expectEqual(@as(u32, 2), image.height);

    // Sink must have at least one warn for the injected extraneous bytes.
    var found = false;
    var offset_seen: ?u64 = null;
    for (sink.items()) |f| {
        if (f.severity == .warn and f.code == .extraneous_bytes_before_marker) {
            found = true;
            offset_seen = f.offset;
        }
    }
    try std.testing.expect(found);
    // Offset should point at the first injected garbage byte (just after SOI).
    try std.testing.expectEqual(@as(?u64, 2), offset_seen);
}

test "cleanroom emits no findings for clean baseline JPEG" {
    const allocator = std.testing.allocator;

    var sink = jpegz.FindingsSink.init(allocator);
    defer sink.deinit();

    var image = try jpegz.internal.cleanroomDecodeWithFindings(
        allocator, fixture_baseline_2x2_rgb, &sink);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), sink.items().len);
}

test "cleanroom progressive emits Finding(.warn, .insufficient_data) on truncated entropy" {
    const allocator = std.testing.allocator;

    // Cut bytes off the end of the last scan's entropy data, then
    // re-attach FFD9. Cleanroom progressive sees markerHit mid-scan
    // and tolerates it (libjpeg `insufficient_data` parity); the sink
    // receives the first-detection warn. We use the 1190-byte 16×16
    // 12-bit RGB fixture because its final scan has ~39 bytes of
    // entropy, leaving room to cut within entropy without landing in
    // an upstream DHT segment. (The small 8×8 fixtures have ~1-byte
    // trailing scans that any non-trivial cut would punch right
    // through a header.)
    const full = fixture_progressive_16x16_rgb12_444;
    try std.testing.expectEqual(@as(u8, 0xFF), full[full.len - 2]);
    try std.testing.expectEqual(@as(u8, 0xD9), full[full.len - 1]);

    const cut: usize = 16;
    var corrupted = try allocator.alloc(u8, full.len - cut);
    defer allocator.free(corrupted);
    @memcpy(corrupted[0 .. full.len - cut - 2], full[0 .. full.len - cut - 2]);
    corrupted[full.len - cut - 2] = 0xFF;
    corrupted[full.len - cut - 1] = 0xD9;

    var sink = jpegz.FindingsSink.init(allocator);
    defer sink.deinit();

    var image = try jpegz.internal.progressiveDecodeWithFindings(allocator, corrupted, &sink);
    defer image.deinit(allocator);

    // Decode succeeded — tolerance was exercised.
    try std.testing.expectEqual(@as(u32, 16), image.width);
    try std.testing.expectEqual(@as(u32, 16), image.height);

    // Sink must have at least one warn for insufficient_data.
    var found = false;
    for (sink.items()) |f| {
        if (f.severity == .warn and f.code == .insufficient_data) found = true;
    }
    try std.testing.expect(found);
}

test "cleanroom progressive emits no findings for clean fixture" {
    const allocator = std.testing.allocator;

    var sink = jpegz.FindingsSink.init(allocator);
    defer sink.deinit();

    var image = try jpegz.internal.progressiveDecodeWithFindings(
        allocator, fixture_progressive_8x8, &sink);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), sink.items().len);
}

test "cleanroom arith SOF9 emits Finding(.warn, .extraneous_bytes_before_marker)" {
    const allocator = std.testing.allocator;

    // Inject 4 garbage bytes between SOI and the next marker. SOF9
    // walker scans forward past them; decode succeeds; sink receives
    // a warn for the skip.
    var corrupted = try allocator.alloc(u8, fixture_arith_baseline_8x8_gray.len + 4);
    defer allocator.free(corrupted);
    @memcpy(corrupted[0..2], fixture_arith_baseline_8x8_gray[0..2]);
    corrupted[2] = 0xAA;
    corrupted[3] = 0xAA;
    corrupted[4] = 0xAA;
    corrupted[5] = 0xAA;
    @memcpy(corrupted[6..], fixture_arith_baseline_8x8_gray[2..]);

    var sink = jpegz.FindingsSink.init(allocator);
    defer sink.deinit();

    var image = try jpegz.internal.arithDecodeWithFindings(allocator, corrupted, &sink);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 8), image.width);

    var found = false;
    var offset_seen: ?u64 = null;
    for (sink.items()) |f| {
        if (f.severity == .warn and f.code == .extraneous_bytes_before_marker) {
            found = true;
            offset_seen = f.offset;
        }
    }
    try std.testing.expect(found);
    try std.testing.expectEqual(@as(?u64, 2), offset_seen);
}

test "cleanroom JPEG-LS emits Finding(.warn, .extraneous_bytes_before_marker)" {
    const allocator = std.testing.allocator;

    // Inject 4 garbage bytes between SOI and the next marker. JPEG-LS
    // walker scans forward past them; decode succeeds; sink receives
    // a warn for the skip.
    var corrupted = try allocator.alloc(u8, fixture_jpegls_4x4_gray8.len + 4);
    defer allocator.free(corrupted);
    @memcpy(corrupted[0..2], fixture_jpegls_4x4_gray8[0..2]);
    corrupted[2] = 0xAA;
    corrupted[3] = 0xAA;
    corrupted[4] = 0xAA;
    corrupted[5] = 0xAA;
    @memcpy(corrupted[6..], fixture_jpegls_4x4_gray8[2..]);

    var sink = jpegz.FindingsSink.init(allocator);
    defer sink.deinit();

    var image = try jpegz.internal.jpeglsDecodeWithFindings(allocator, corrupted, &sink);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 4), image.width);

    var found = false;
    var offset_seen: ?u64 = null;
    for (sink.items()) |f| {
        if (f.severity == .warn and f.code == .extraneous_bytes_before_marker) {
            found = true;
            offset_seen = f.offset;
        }
    }
    try std.testing.expect(found);
    try std.testing.expectEqual(@as(?u64, 2), offset_seen);
}

