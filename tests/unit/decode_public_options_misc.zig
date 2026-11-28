//! decode tests, part 9 (split from decode.zig to keep files small).

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

test "public decodeWithOptions: default options stay strict" {
    const allocator = std.testing.allocator;
    const full = fixture_baseline_2x2_rgb;
    const cut: usize = 24;
    var corrupted = try allocator.alloc(u8, full.len - cut);
    defer allocator.free(corrupted);
    @memcpy(corrupted[0 .. full.len - cut - 2], full[0 .. full.len - cut - 2]);
    corrupted[full.len - cut - 2] = 0xFF;
    corrupted[full.len - cut - 1] = 0xD9;

    const result = jpegz.decodeWithOptions(allocator, corrupted, .{});
    if (result) |img| {
        var i = img;
        i.deinit(allocator);
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expect(err == error.TruncatedStream or err == error.BackendError);
    }
}

test "B2.x: JPEG-LS 4x4 RGB 8-bit line-interleaved (ILV=1) cleanroom" {
    const allocator = std.testing.allocator;
    var image = try jpegz.jpegls_cleanroom_decode(allocator, fixture_jpegls_4x4_rgb8_ilv1);
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

// ── CMYK cleanroom (M2.4-ish — 4-component baseline) ────────────────
//
// libjpeg-turbo handles two flavors of 4-comp baseline JPEG:
//   - APP14 ColorTransform=0 → raw CMYK; output is C, M, Y, K bytes
//     per pixel (no color conversion)
//   - APP14 ColorTransform=2 → YCCK (Y/Cb/Cr/K source); libjpeg
//     converts internally to CMYK by running YCbCr→RGB on the first
//     three channels then inverting (C=255-R, M=255-G, Y=255-B) and
//     passing K through.
// (ColorTransform=1 only applies to 3-comp; not relevant here.)
//
// The committed fixture is YCCK (APP14 byte 11 = 0x02). Byte-perfect
// parity with the wrapper requires both the 4-channel scan path AND
// the YCCK→CMYK conversion using the same fixed-point YCbCr→RGB
// constants as the existing 3-comp path.

test "cleanroom CMYK 4x4 byte-perfect vs wrapper (YCCK ColorTransform=2)" {
    const allocator = std.testing.allocator;

    var cleanroom = try jpegz.internal.cleanroomDecode(allocator, fixture_baseline_4x4_cmyk);
    defer cleanroom.deinit(allocator);

    var wrapper = try jpegz.internal.wrapperDecode(allocator, fixture_baseline_4x4_cmyk);
    defer wrapper.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 4), cleanroom.width);
    try std.testing.expectEqual(@as(u32, 4), cleanroom.height);
    try std.testing.expectEqual(@as(u8, 4), cleanroom.channels);
    try std.testing.expectEqual(jpegz.PixelLayout.cmyk, cleanroom.layout);
    try std.testing.expectEqual(@as(usize, 4 * 4 * 4), cleanroom.pixels.len);

    // Byte-perfect against the libjpeg-turbo wrapper.
    try std.testing.expectEqualSlices(u8, wrapper.pixels, cleanroom.pixels);
}

test "cmyk cleanroom 16x16 YCCK SUBSAMPLED chroma byte-perfect vs wrapper (heap-overrun regression)" {
    // Regression for the validate_gui heap over-read (2026-05-31): the
    // 4-component assembler indexed quarter-size Cb/Cr planes at full
    // canvas coordinates, reading off the end of the buffer. Decoding
    // this subsampled YCCK fixture must (a) not crash and (b) be byte-
    // identical to libjpeg-turbo (the cleanroom now upsamples each
    // component with the same IJG fancy upsampler the 3-comp path uses).
    const allocator = std.testing.allocator;
    var cleanroom = try jpegz.internal.cleanroomDecode(allocator, fixture_cmyk_16x16_ycck_sub);
    defer cleanroom.deinit(allocator);
    var wrapper = try jpegz.internal.wrapperDecode(allocator, fixture_cmyk_16x16_ycck_sub);
    defer wrapper.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 16), cleanroom.width);
    try std.testing.expectEqual(@as(u32, 16), cleanroom.height);
    try std.testing.expectEqual(@as(u8, 4), cleanroom.channels);
    try std.testing.expectEqual(jpegz.PixelLayout.cmyk, cleanroom.layout);
    try std.testing.expectEqual(@as(usize, 16 * 16 * 4), cleanroom.pixels.len);
    try std.testing.expectEqual(wrapper.channels, cleanroom.channels);
    try std.testing.expectEqualSlices(u8, wrapper.pixels, cleanroom.pixels);
}

test "RGB-marked baseline (Adobe APP14 transform=0) decodes as RGB, byte-matching libjpeg" {
    const allocator = std.testing.allocator;
    var cleanroom = try jpegz.internal.cleanroomDecode(allocator, fixture_baseline_16x16_rgb_marked);
    defer cleanroom.deinit(allocator);
    var wrapper = try jpegz.internal.wrapperDecode(allocator, fixture_baseline_16x16_rgb_marked);
    defer wrapper.deinit(allocator);
    try std.testing.expectEqual(wrapper.width, cleanroom.width);
    try std.testing.expectEqual(wrapper.height, cleanroom.height);
    // Source color space must be reported as RGB (not YCbCr).
    try std.testing.expectEqual(jpegz.ColorSpace.rgb, cleanroom.source_color_space);
    // Pixels must be the RGB passthrough libjpeg produces (no chroma transform).
    try std.testing.expectEqualSlices(u8, wrapper.pixels, cleanroom.pixels);
}

test "IDCT overflow: out-of-range coefficient decodes without panic + emits dct_coefficient_overflow" {
    const allocator = std.testing.allocator;
    var sink = jpegz.FindingsSink.init(allocator);
    defer sink.deinit();
    // Must NOT panic (formerly did). Decode succeeds with wrapped (best-effort)
    // pixels, matching libjpeg's silent-wrap behavior on the same bytes.
    var img = try jpegz.decodeWithOptions(allocator, fixture_overflow_ac_8x8, .{ .findings_sink = &sink });
    defer img.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 8), img.width);
    try std.testing.expectEqual(@as(u32, 8), img.height);
    // The overflow is surfaced as a fail-severity finding, not swallowed.
    var found = false;
    for (sink.items()) |f| {
        if (f.code == .dct_coefficient_overflow and f.severity == .fail) found = true;
    }
    try std.testing.expect(found);
}

test "multi-scan sequential DCT decodes byte-identically to libjpeg-turbo" {
	const allocator = std.testing.allocator;
	const Case = struct { name: []const u8, data: []const u8 };
	const cases = [_]Case{
		.{ .name = "seq_16x16_3scan", .data = fixture_seq_16x16_3scan },
		.{ .name = "seq_17x13_420_y_cbcr_rst", .data = fixture_seq_17x13_420_y_cbcr_rst },
		.{ .name = "seq_23x19_422_rev_rst", .data = fixture_seq_23x19_422_rev_rst },
		.{ .name = "seq_23x19_rgb12_420_3scan", .data = fixture_seq_23x19_rgb12_420_3scan },
	};
	for (cases) |c| {
		var clean = jpegz.internal.cleanroomDecode(allocator, c.data) catch |err| {
			std.debug.print("cleanroom rejected {s}: {s}\n", .{ c.name, @errorName(err) });
			return err;
		};
		defer clean.deinit(allocator);
		var wrap = try jpegz.internal.wrapperDecode(allocator, c.data);
		defer wrap.deinit(allocator);
		std.testing.expectEqualSlices(u8, wrap.pixels, clean.pixels) catch |err| {
			std.debug.print("byte-exact mismatch on {s}\n", .{c.name});
			return err;
		};
	}
}

test "progressive coefficient arithmetic outside i16 returns typed errors" {
	const allocator = std.testing.allocator;
	for (progressive_range_cases) |case| {
		const data = try buildProgressiveGray(allocator, case.precision, case.width, case.scans);
		defer allocator.free(data);
		if (jpegz.decode(allocator, data)) |image_const| {
			var image = image_const;
			defer image.deinit(allocator);
			if (case.expected) |expected| {
				std.debug.print("{s}: decoded, expected {s}\n", .{ case.name, @errorName(expected) });
				return error.TestUnexpectedResult;
			}
			try std.testing.expectEqual(@as(u32, case.width), image.width);
		} else |err| {
			const actual: anyerror = err;
			const expected = case.expected orelse {
				std.debug.print("{s}: control rejected with {s}\n", .{ case.name, @errorName(actual) });
				return error.TestUnexpectedResult;
			};
			if (expected != actual) {
				std.debug.print("{s}: got {s}, expected {s}\n", .{ case.name, @errorName(actual), @errorName(expected) });
				return error.TestUnexpectedResult;
			}
		}
	}
}

test "fuzz-found progressive refinement with Al=15 returns a typed error" {
	try std.testing.expectError(error.InvalidMarker, jpegz.decode(std.testing.allocator, fixture_fuzz_progressive_ac_refine_al15));
	var report = try jpegz.validate(std.testing.allocator, fixture_fuzz_progressive_ac_refine_al15);
	defer report.deinit(std.testing.allocator);
	try std.testing.expectEqual(jpegz.Severity.fail, report.overall);
}

test "frameHeader reports fixture geometry and sampling factors" {
	const allocator = std.testing.allocator;
	for (frame_fixtures) |fixture| {
		errdefer std.debug.print("fixture: {s}\n", .{fixture.name});
		const header = try jpegz.frameHeader(fixture.data);
		try std.testing.expectEqual(@as(u8, 0xFF), fixture.data[header.sof_offset]);
		try std.testing.expectEqual(@as(u8, 0xC0) + fixture.sof_type, fixture.data[header.sof_offset + 1]);
		try std.testing.expectEqual(fixture.sof_type, header.sof_type);
		try std.testing.expectEqual(@as(?usize, null), header.dhp_offset);
		try std.testing.expectEqual(jpegz.frameKind(fixture.sof_type).?, header.kind);
		try std.testing.expectEqual(fixture.width, header.width);
		try std.testing.expectEqual(fixture.height, header.height);
		try std.testing.expectEqual(fixture.count, header.component_count);
		for (header.components(), 0..) |component, index| {
			const h: u4 = if (index == 0) fixture.h0 else 1;
			const v: u4 = if (index == 0) fixture.v0 else 1;
			try std.testing.expectEqual(h, component.h);
			try std.testing.expectEqual(v, component.v);
		}
		var image = try jpegz.decode(allocator, fixture.data);
		defer image.deinit(allocator);
		try std.testing.expectEqual(@as(u32, header.width), image.width);
		try std.testing.expectEqual(@as(u32, header.height), image.height);
	}
}

test "frameHeader reports a DHP inserted before a real lossless frame" {
	// Splice a DHP segment (B.3.2, Tq = 0) mirroring the frame just before
	// the SOF3 of a real lossless stream; the frame fields must not change.
	const original = @embedFile("fixtures/lossless_4x4_gray8.jpg");
	const plain = try jpegz.frameHeader(original);
	const sof = plain.sof_offset;
	const dhp = [_]u8{ 0xFF, 0xDE, 0x00, 0x0B, 0x08, 0x00, 0x04, 0x00, 0x04, 0x01, 0x01, 0x11, 0x00 };
	var spliced: [original.len + dhp.len]u8 = undefined;
	@memcpy(spliced[0..sof], original[0..sof]);
	@memcpy(spliced[sof..][0..dhp.len], &dhp);
	@memcpy(spliced[sof + dhp.len ..], original[sof..]);
	const header = try jpegz.frameHeader(&spliced);
	try std.testing.expectEqual(@as(?usize, sof), header.dhp_offset);
	try std.testing.expectEqual(sof + dhp.len, header.sof_offset);
	try std.testing.expectEqual(@as(u4, 3), header.sof_type);
	try std.testing.expectEqual(plain.kind, header.kind);
	try std.testing.expectEqual(plain.width, header.width);
	try std.testing.expectEqual(plain.height, header.height);
	try std.testing.expectEqualSlices(jpegz.FrameComponent, plain.components(), header.components());
}

test "frameHeader rejects non-frame family inputs without decoding" {
	try std.testing.expectError(error.UnsupportedFrameType, jpegz.frameHeader(@embedFile("fixtures/jpegls_4x4_gray8.jls")));
	try std.testing.expectError(error.MissingSoi, jpegz.frameHeader(@embedFile("fixtures/jp2_8x8_rgb.jp2")));
}

test "two- and four-component lossless frames decode every sample exactly (DNG CFA layout)" {
	// Fixtures from tools/gen-lossless-components.c (libjpeg-turbo encoder);
	// sample (x, y, c) = (37x + 101y + 53c + 7xy) mod 2^P, so the samples
	// themselves are the oracle. See LOSSLESS_COMPONENTS_PROVENANCE.md.
	const Case = struct { bytes: []const u8, nc: u8, precision: u8, width: u32, height: u32 };
	const cases = [_]Case{
		.{ .bytes = @embedFile("fixtures/lossless_6x5_2comp_p8_pred1.jpg"), .nc = 2, .precision = 8, .width = 6, .height = 5 },
		.{ .bytes = @embedFile("fixtures/lossless_8x6_2comp_p14_pred4.jpg"), .nc = 2, .precision = 14, .width = 8, .height = 6 },
		.{ .bytes = @embedFile("fixtures/lossless_9x7_2comp_p16_pred6_dri9.jpg"), .nc = 2, .precision = 16, .width = 9, .height = 7 },
		.{ .bytes = @embedFile("fixtures/lossless_5x4_4comp_p12_pred7.jpg"), .nc = 4, .precision = 12, .width = 5, .height = 4 },
	};
	for (cases) |case| {
		var image = try jpegz.decode(std.testing.allocator, case.bytes);
		defer image.deinit(std.testing.allocator);
		try std.testing.expectEqual(case.width, image.width);
		try std.testing.expectEqual(case.height, image.height);
		try std.testing.expectEqual(case.nc, image.channels);
		try std.testing.expectEqual(case.precision, image.bits_per_sample);
		try std.testing.expectEqual(jpegz.PixelLayout.components, image.layout);
		const mask = (@as(u32, 1) << @intCast(case.precision)) - 1;
		var y: u32 = 0;
		while (y < case.height) : (y += 1) {
			var x: u32 = 0;
			while (x < case.width) : (x += 1) {
				var c: u32 = 0;
				while (c < case.nc) : (c += 1) {
					const want = (37 * x + 101 * y + 53 * c + 7 * x * y) & mask;
					const index = (y * case.width + x) * case.nc + c;
					const got: u32 = if (case.precision <= 8) image.pixels[index] else image.pixelsU16()[index];
					if (got != want) {
						std.debug.print("P{d} Nf={d} ({d},{d},{d}): got {d}, want {d}\n", .{ case.precision, case.nc, x, y, c, got, want });
						return error.TestUnexpectedResult;
					}
				}
			}
		}
	}

	// tiffz's minimal stream: 2x4, two components, one 1-bit code for
	// difference 0, so every sample is the predictor's 2^(P-1) = 128.
	const minimal = [_]u8{ 0xff, 0xd8, 0xff, 0xc3, 0x00, 0x0e, 0x08, 0x00, 0x04, 0x00, 0x02, 0x02, 0x01, 0x11, 0x00, 0x02, 0x11, 0x00,
		0xff, 0xc4, 0x00, 0x14, 0x00, 0x01 } ++ ([_]u8{0} ** 15) ++ [_]u8{ 0x00,
		0xff, 0xda, 0x00, 0x0a, 0x02, 0x01, 0x00, 0x02, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0xff, 0xd9 };
	var tiny = try jpegz.decode(std.testing.allocator, &minimal);
	defer tiny.deinit(std.testing.allocator);
	try std.testing.expectEqual(@as(u8, 2), tiny.channels);
	try std.testing.expectEqual(jpegz.PixelLayout.components, tiny.layout);
	for (tiny.pixels) |sample| try std.testing.expectEqual(@as(u8, 128), sample);
	try std.testing.expectEqual(@as(usize, 2 * 4 * 2), tiny.pixels.len);

	// Control: subsampled components stay out of scope, not silently wrong.
	var subsampled = @embedFile("fixtures/lossless_6x5_2comp_p8_pred1.jpg").*;
	try std.testing.expectEqual(@as(u8, 0x11), subsampled[13]); // first component's Hi/Vi
	subsampled[13] = 0x21;
	try std.testing.expectError(error.NotImplemented, jpegz.decode(std.testing.allocator, &subsampled));
}

test "RGB-signaled three-component frames pass through at 12-bit and in progressive scans" {
	// cjpeg -rgb -quality 100 (libjpeg-turbo 3.2.1) writes Adobe transform 0
	// and component IDs R,G,B; djpeg returns every source sample exactly, so
	// the source formula is the oracle. tiffz bug report, 2026-11-06.
	const Case = struct { name: []const u8, bytes: []const u8, precision: u8 };
	const cases = [_]Case{
		.{ .name = "baseline P12", .bytes = @embedFile("fixtures/rgb_8x8_p12_baseline.jpg"), .precision = 12 },
		.{ .name = "progressive P12", .bytes = @embedFile("fixtures/rgb_8x8_p12_progressive.jpg"), .precision = 12 },
		.{ .name = "progressive P8", .bytes = @embedFile("fixtures/rgb_8x8_p8_progressive.jpg"), .precision = 8 },
		.{ .name = "arithmetic progressive P8", .bytes = @embedFile("fixtures/rgb_8x8_p8_arith_progressive.jpg"), .precision = 8 },
		.{ .name = "baseline P8 control", .bytes = @embedFile("fixtures/rgb_8x8_p8_baseline.jpg"), .precision = 8 },
	};
	const allocator = std.testing.allocator;
	const jfif = [_]u8{ 0xff, 0xe0, 0x00, 0x10, 'J', 'F', 'I', 'F', 0x00, 0x01, 0x02, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00 };
	for (cases) |case| {
		// APP14 Adobe is bytes 2..18 in every fixture.
		try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xee, 0x00, 0x0e }, case.bytes[2..6]);
		const ids_only = try std.mem.concat(allocator, u8, &.{ case.bytes[0..2], case.bytes[18..] });
		defer allocator.free(ids_only);
		const with_jfif = try std.mem.concat(allocator, u8, &.{ case.bytes[0..2], &jfif, case.bytes[18..] });
		defer allocator.free(with_jfif);
		const variants = [_]struct { label: []const u8, bytes: []const u8, rgb: bool }{
			.{ .label = "Adobe transform 0", .bytes = case.bytes, .rgb = true },
			.{ .label = "component IDs R,G,B only", .bytes = ids_only, .rgb = true },
			.{ .label = "JFIF wins over the IDs", .bytes = with_jfif, .rgb = false },
		};
		for (variants) |variant| {
			var image = try jpegz.decode(allocator, variant.bytes);
			defer image.deinit(allocator);
			try std.testing.expectEqual(@as(u8, 3), image.channels);
			try std.testing.expectEqual(case.precision, image.bits_per_sample);
			var mismatches: usize = 0;
			for (0..8) |y| for (0..8) |x| for (0..3) |c| {
				const want: u32 = if (case.precision > 8)
					@intCast(256 * x + 128 * y + 512 * c + 100)
				else
					@intCast((16 * x + 8 * y + 32 * c + 10) % 256);
				const index = (y * 8 + x) * 3 + c;
				const got: u32 = if (case.precision > 8) image.pixelsU16()[index] else image.pixels[index];
				if (got != want) mismatches += 1;
			};
			const want_space: jpegz.ColorSpace = if (variant.rgb) .rgb else .ycbcr;
			if ((variant.rgb and mismatches != 0) or (!variant.rgb and mismatches == 0) or image.source_color_space != want_space) {
				std.debug.print("{s}, {s}: {d} mismatched samples, color space {t}\n", .{ case.name, variant.label, mismatches, image.source_color_space });
				return error.TestUnexpectedResult;
			}
		}
	}
}

test "JPEG-LS SOF55 Y = 0 takes its height from a DNL after the first scan (T.87 C.2.2)" {
    if (!jpegls_conformance.available) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    // One scan (t8nde0), and ILV 0 with three scans (t8c0e0): the DNL goes
    // after the first scan only.
    for ([_][]const u8{ jpegls_conformance.t8nde0, jpegls_conformance.t8c0e0 }) |src| {
        var want = try jpegz.jpegls_cleanroom_decode(allocator, src);
        defer want.deinit(allocator);
        const data = try jlsWithDnl(allocator, src, 0, @intCast(want.height));
        defer allocator.free(data);
        var got = try jpegz.jpegls_cleanroom_decode(allocator, data);
        defer got.deinit(allocator);
        try std.testing.expectEqual(want.height, got.height);
        try std.testing.expectEqualSlices(u8, want.pixels, got.pixels);
        var report = try jpegz.validate(allocator, data);
        defer report.deinit(allocator);
        try std.testing.expectEqual(.decoded, report.codec_check);
        try std.testing.expectEqual(want.height, report.height);
        for (report.findings.items) |f| {
            if (f.severity != .info) {
                dumpFindings("Y=0 + DNL", report);
                return error.TestUnexpectedResult;
            }
        }
    }
}

