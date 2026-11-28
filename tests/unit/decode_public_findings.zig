//! decode tests, part 8 (split from decode.zig to keep files small).

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

test "public decoder preserves caller findings without duplicating format-probe warnings" {
	const allocator = std.testing.allocator;
	const fixtures = [_][]const u8{ fixture_baseline_2x2_rgb, fixture_progressive_8x8, fixture_lossless_4x4_gray8 };
	for (fixtures) |fixture| {
		const data = try std.mem.concat(allocator, u8, &.{ fixture[0..2], &.{0xff}, fixture[2..] });
		defer allocator.free(data);
		var sink = jpegz.FindingsSink.init(allocator);
		defer sink.deinit();
		try sink.emit(.info, .unknown_marker, 42, "caller-owned finding");
		var image = try jpegz.decodeWithOptions(allocator, data, .{ .findings_sink = &sink });
		defer image.deinit(allocator);
		try std.testing.expectEqual(@as(usize, 2), sink.items().len);
		try std.testing.expectEqualStrings("caller-owned finding", sink.items()[0].detail.?);
		try std.testing.expectEqual(jpegz.FindingCode.unknown_marker, sink.items()[0].code);
		try std.testing.expectEqual(jpegz.Severity.info, sink.items()[0].severity);
		try std.testing.expectEqual(@as(?u64, 42), sink.items()[0].offset);
		try std.testing.expectEqual(jpegz.FindingCode.entropy_fill_bytes, sink.items()[1].code);
		try std.testing.expectEqual(jpegz.Severity.warn, sink.items()[1].severity);
	}
}

test "public decoder rolls back unsupported probes but retains real error findings" {
	const allocator = std.testing.allocator;
	const cases = [_]struct { fixture: []const u8, sof: u8, unsupported: bool }{
		.{ .fixture = fixture_lossless_4x4_gray8, .sof = 0xc3, .unsupported = true },
		.{ .fixture = fixture_baseline_2x2_rgb, .sof = 0xc0, .unsupported = false },
	};
	for (cases) |case| {
		const data = try std.mem.concat(allocator, u8, &.{ case.fixture[0..2], &.{0xff}, case.fixture[2..] });
		defer allocator.free(data);
		const sof = std.mem.indexOf(u8, data, &.{ 0xff, case.sof }).?;
		if (case.unsupported) {
			data[sof + 11] = 0x21;
		} else {
			@memset(data[sof + 7 .. sof + 9], 0);
		}
		var sink = jpegz.FindingsSink.init(allocator);
		defer sink.deinit();
		try sink.emit(.info, .unknown_marker, 42, "caller-owned finding");
		const expected_error = if (case.unsupported) error.NotImplemented else error.InvalidMarker;
		try std.testing.expectError(expected_error, jpegz.decodeWithOptions(allocator, data, .{ .findings_sink = &sink }));
		try std.testing.expectEqual(@as(usize, if (case.unsupported) 1 else 2), sink.items().len);
		try std.testing.expectEqualStrings("caller-owned finding", sink.items()[0].detail.?);
		try std.testing.expectEqual(jpegz.FindingCode.unknown_marker, sink.items()[0].code);
		try std.testing.expectEqual(jpegz.Severity.info, sink.items()[0].severity);
		try std.testing.expectEqual(@as(?u64, 42), sink.items()[0].offset);
		if (!case.unsupported) {
			try std.testing.expectEqual(jpegz.FindingCode.entropy_fill_bytes, sink.items()[1].code);
			try std.testing.expectEqual(jpegz.Severity.warn, sink.items()[1].severity);
		}
	}
}

test "public decoder forwards progressive and lossless recovery options" {
	const allocator = std.testing.allocator;
	const cases = [_]struct { data: []const u8, rst: usize }{
		.{ .data = fixture_progressive_32x32_dri, .rst = 149 },
		.{ .data = fixture_lossless_16x16_gray_dri, .rst = 115 },
	};
	for (cases) |case| {
		var expected = try jpegz.decode(allocator, case.data);
		defer expected.deinit(allocator);
		const damaged = try allocator.dupe(u8, case.data);
		defer allocator.free(damaged);
		try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xd0 }, damaged[case.rst .. case.rst + 2]);
		damaged[case.rst + 1] = 0xd3;
		try std.testing.expectError(error.InvalidMarker, jpegz.decode(allocator, damaged));
		var sink = jpegz.FindingsSink.init(allocator);
		defer sink.deinit();
		var recovered = try jpegz.decodeWithOptions(allocator, damaged, .{ .lenient = true, .findings_sink = &sink });
		defer recovered.deinit(allocator);
		try std.testing.expectEqualSlices(u8, expected.pixels, recovered.pixels);
		var warned = false;
		for (sink.items()) |finding| {
			if (finding.code == .restart_marker_unexpected and finding.severity == .warn) warned = true;
		}
		try std.testing.expect(warned);
		var recovered_without_sink = try jpegz.decodeWithOptions(allocator, damaged, .{ .lenient = true });
		defer recovered_without_sink.deinit(allocator);
		try std.testing.expectEqualSlices(u8, expected.pixels, recovered_without_sink.pixels);
	}
}

test "cleanroom progressive lenient: RST cycle mismatch → warn + recovers" {
    const allocator = std.testing.allocator;

    // progressive_32x32_gray_dri has DRI > 0 and the first FFD0 at
    // offset 149. Mutate to FFD3 (wrong cycle); strict path errors,
    // lenient path emits warn and recovers.
    const src = fixture_progressive_32x32_dri;
    var corrupted = try allocator.alloc(u8, src.len);
    defer allocator.free(corrupted);
    @memcpy(corrupted, src);
    try std.testing.expectEqual(@as(u8, 0xFF), corrupted[149]);
    try std.testing.expectEqual(@as(u8, 0xD0), corrupted[150]);
    corrupted[150] = 0xD3;

    // Strict path: returns InvalidMarker.
    try std.testing.expectError(error.InvalidMarker,
        jpegz.internal.progressiveDecode(allocator, corrupted));

    var sink = jpegz.FindingsSink.init(allocator);
    defer sink.deinit();
    var image = try jpegz.internal.progressiveDecodeLenientWithFindings(allocator, corrupted, &sink);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 32), image.width);

    var found = false;
    for (sink.items()) |f| {
        if (f.severity == .warn and f.code == .restart_marker_unexpected) found = true;
    }
    try std.testing.expect(found);
}

test "cleanroom lossless lenient: RST cycle mismatch → warn + recovers" {
    const allocator = std.testing.allocator;

    // lossless_16x16_gray_dri first FFD0 at offset 115. Mutate to FFD2.
    const src = fixture_lossless_16x16_gray_dri;
    var corrupted = try allocator.alloc(u8, src.len);
    defer allocator.free(corrupted);
    @memcpy(corrupted, src);
    try std.testing.expectEqual(@as(u8, 0xFF), corrupted[115]);
    try std.testing.expectEqual(@as(u8, 0xD0), corrupted[116]);
    corrupted[116] = 0xD2;

    // Strict path: returns InvalidMarker.
    try std.testing.expectError(error.InvalidMarker,
        jpegz.internal.losslessDecode(allocator, corrupted));

    var sink = jpegz.FindingsSink.init(allocator);
    defer sink.deinit();
    var image = try jpegz.internal.losslessDecodeLenientWithFindings(allocator, corrupted, &sink);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 16), image.width);

    var found = false;
    for (sink.items()) |f| {
        if (f.severity == .warn and f.code == .restart_marker_unexpected) found = true;
    }
    try std.testing.expect(found);
}

test "cleanroom progressive emits Finding(.warn, .entropy_fill_bytes) for extra 0xFF" {
    const allocator = std.testing.allocator;

    const src = fixture_progressive_8x8;
    var corrupted = try allocator.alloc(u8, src.len + 2);
    defer allocator.free(corrupted);
    @memcpy(corrupted[0..2], src[0..2]); // SOI
    corrupted[2] = 0xFF;
    corrupted[3] = 0xFF;
    @memcpy(corrupted[4..], src[2..]);

    var sink = jpegz.FindingsSink.init(allocator);
    defer sink.deinit();

    var image = try jpegz.internal.progressiveDecodeWithFindings(allocator, corrupted, &sink);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 8), image.width);
    var found = false;
    for (sink.items()) |f| {
        if (f.severity == .warn and f.code == .entropy_fill_bytes) found = true;
    }
    try std.testing.expect(found);
}

test "cleanroom lossless emits Finding(.warn, .entropy_fill_bytes) for extra 0xFF" {
    const allocator = std.testing.allocator;

    const src = fixture_lossless_4x4_gray8;
    var corrupted = try allocator.alloc(u8, src.len + 2);
    defer allocator.free(corrupted);
    @memcpy(corrupted[0..2], src[0..2]);
    corrupted[2] = 0xFF;
    corrupted[3] = 0xFF;
    @memcpy(corrupted[4..], src[2..]);

    var sink = jpegz.FindingsSink.init(allocator);
    defer sink.deinit();

    var image = try jpegz.internal.losslessDecodeWithFindings(allocator, corrupted, &sink);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 4), image.width);
    var found = false;
    for (sink.items()) |f| {
        if (f.severity == .warn and f.code == .entropy_fill_bytes) found = true;
    }
    try std.testing.expect(found);
}

test "cleanroom progressive emits Finding(.warn, .extraneous_bytes_before_marker)" {
    const allocator = std.testing.allocator;

    // Inject 4 garbage bytes between SOI and the next marker. Progressive
    // walker should scan forward past them (mirroring baseline's tolerance
    // per T.81 §B.1.1.2 marker self-synchronization); decode succeeds; sink
    // receives a warn for the skip.
    var corrupted = try allocator.alloc(u8, fixture_progressive_8x8.len + 4);
    defer allocator.free(corrupted);
    @memcpy(corrupted[0..2], fixture_progressive_8x8[0..2]);
    corrupted[2] = 0xAA;
    corrupted[3] = 0xAA;
    corrupted[4] = 0xAA;
    corrupted[5] = 0xAA;
    @memcpy(corrupted[6..], fixture_progressive_8x8[2..]);

    var sink = jpegz.FindingsSink.init(allocator);
    defer sink.deinit();

    var image = try jpegz.internal.progressiveDecodeWithFindings(allocator, corrupted, &sink);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 8), image.width);
    try std.testing.expectEqual(@as(u32, 8), image.height);

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

test "cleanroom lossless emits Finding(.warn, .extraneous_bytes_before_marker)" {
    const allocator = std.testing.allocator;

    // Inject 4 garbage bytes between SOI and the next marker. Lossless
    // walker should scan forward past them (mirroring baseline's pre-SOS
    // tolerance — note this only applies to the marker walker; sample-
    // stream tolerance would cascade through the predictor and is
    // intentionally NOT added). Decode succeeds; sink receives a warn.
    var corrupted = try allocator.alloc(u8, fixture_lossless_4x4_gray8.len + 4);
    defer allocator.free(corrupted);
    @memcpy(corrupted[0..2], fixture_lossless_4x4_gray8[0..2]);
    corrupted[2] = 0xAA;
    corrupted[3] = 0xAA;
    corrupted[4] = 0xAA;
    corrupted[5] = 0xAA;
    @memcpy(corrupted[6..], fixture_lossless_4x4_gray8[2..]);

    var sink = jpegz.FindingsSink.init(allocator);
    defer sink.deinit();

    var image = try jpegz.internal.losslessDecodeWithFindings(allocator, corrupted, &sink);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 4), image.width);
    try std.testing.expectEqual(@as(u32, 4), image.height);

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

// ── Lenient mode (loose-coupled cleanroom truncation recovery) ─────
//
// `DecodeOptions.lenient = true` switches the cleanroom from strict
// (default) to libjpeg-turbo-style "tolerate truncation, surface a
// Finding(.warn, .insufficient_data) via the sink, return partial
// pixels". Useful for thumbnail generators, image viewers, validate's
// strictness audits — any consumer that prefers "best-effort decode"
// to "error". Default decode behavior is unchanged.

test "default baseline cleanroom errors on truncated entropy (strict regression)" {
    const allocator = std.testing.allocator;

    // Same truncation pattern as validate.zig's wrapper-WARNMS test.
    const full = fixture_baseline_2x2_rgb;
    try std.testing.expectEqual(@as(u8, 0xFF), full[full.len - 2]);
    try std.testing.expectEqual(@as(u8, 0xD9), full[full.len - 1]);

    const cut: usize = 24;
    var corrupted = try allocator.alloc(u8, full.len - cut);
    defer allocator.free(corrupted);
    @memcpy(corrupted[0 .. full.len - cut - 2], full[0 .. full.len - cut - 2]);
    corrupted[full.len - cut - 2] = 0xFF;
    corrupted[full.len - cut - 1] = 0xD9;

    // Default cleanroom MUST refuse — strict by design. The exact
    // error depends on whether the truncation lands in a Huffman code
    // (→ BackendError) or while reading magnitude bits
    // (→ TruncatedStream); either is a hard refusal.
    const result = jpegz.internal.cleanroomDecode(allocator, corrupted);
    if (result) |img| {
        var i = img;
        i.deinit(allocator);
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expect(err == error.TruncatedStream or err == error.BackendError);
    }
}

test "lenient baseline cleanroom recovers truncation, emits insufficient_data warn" {
    const allocator = std.testing.allocator;

    const full = fixture_baseline_2x2_rgb;
    const cut: usize = 24;
    var corrupted = try allocator.alloc(u8, full.len - cut);
    defer allocator.free(corrupted);
    @memcpy(corrupted[0 .. full.len - cut - 2], full[0 .. full.len - cut - 2]);
    corrupted[full.len - cut - 2] = 0xFF;
    corrupted[full.len - cut - 1] = 0xD9;

    var sink = jpegz.FindingsSink.init(allocator);
    defer sink.deinit();

    var image = try jpegz.internal.cleanroomDecodeLenientWithFindings(
        allocator, corrupted, &sink);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 2), image.width);
    try std.testing.expectEqual(@as(u32, 2), image.height);

    var found = false;
    for (sink.items()) |f| {
        if (f.severity == .warn and f.code == .insufficient_data) found = true;
    }
    try std.testing.expect(found);
}

// ── Public-API lenient + sink (jpegz.DecodeOptions promotion) ──────
//
// Same lenient semantics as `internal.cleanroomDecodeLenientWithFindings`
// but routed through the PUBLIC dispatcher entry point
// `jpegz.decodeWithOptions(allocator, data, .{ .lenient = true,
// .findings_sink = &sink })`. This is the surface LLMs / external
// consumers should target.

test "public decodeWithOptions: lenient + sink recovers truncated baseline" {
    const allocator = std.testing.allocator;

    const full = fixture_baseline_2x2_rgb;
    const cut: usize = 24;
    var corrupted = try allocator.alloc(u8, full.len - cut);
    defer allocator.free(corrupted);
    @memcpy(corrupted[0 .. full.len - cut - 2], full[0 .. full.len - cut - 2]);
    corrupted[full.len - cut - 2] = 0xFF;
    corrupted[full.len - cut - 1] = 0xD9;

    var sink = jpegz.FindingsSink.init(allocator);
    defer sink.deinit();

    var image = try jpegz.decodeWithOptions(allocator, corrupted, .{
        .lenient = true,
        .findings_sink = &sink,
    });
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 2), image.width);
    var found = false;
    for (sink.items()) |f| {
        if (f.severity == .warn and f.code == .insufficient_data) found = true;
    }
    try std.testing.expect(found);
}

