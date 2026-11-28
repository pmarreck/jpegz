//! decode tests, part 5 (split from decode.zig to keep files small).

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

test "arithmetic restart intervals resume at each RSTn: coefficients and pixels match libjpeg" {
	// T.81 F.2.4.2 / D.2.6: after each RSTn the arithmetic decoder restarts
	// on the bytes that follow that marker. With one MCU per interval, a
	// decoder that resumes anywhere else loses the next marker or decodes
	// the wrong bytes.
	const allocator = std.testing.allocator;
	for ([_][]const u8{ fixture_arith_restart_gray, fixture_arith_restart_rgb420, fixture_arith_restart_rgb420_progressive }) |data| {
		var cleanroom = try jpegz.internal.arithDecode(allocator, data);
		defer cleanroom.deinit(allocator);
		var wrapper = try jpegz.internal.wrapperDecode(allocator, data);
		defer wrapper.deinit(allocator);
		try std.testing.expectEqual(@as(u32, 32), cleanroom.width);
		try std.testing.expectEqualSlices(u8, wrapper.pixels, cleanroom.pixels);
		var report = try jpegz.validate(allocator, data);
		defer report.deinit(allocator);
		try std.testing.expect(report.isValid());
	}
	// Builds without the libjpeg oracle (cross targets) have an empty dump type.
	if (comptime !@hasField(jpegz.internal.WrapperCoefDump, "coefs")) return;
	for ([_][]const u8{ fixture_arith_restart_gray, fixture_arith_restart_rgb420 }) |data| {
		var cleanroom = try jpegz.internal.arithDumpCoefsSof9(allocator, data);
		defer cleanroom.deinit(allocator);
		var wrapper = try jpegz.internal.wrapperDumpCoefs(allocator, data);
		defer wrapper.deinit(allocator);
		try std.testing.expectEqual(wrapper.num_components, cleanroom.num_components);
		for (0..wrapper.num_components) |c| {
			try std.testing.expectEqualSlices(i16, wrapper.coefs[c], cleanroom.coefs[c]);
		}
	}
}

test "lossless point transform: the decoder rescales every sample by 2^Pt (T.81 A.4)" {
	// Encoded from known sources with Pt = 2, 3 and 4
	// (fixtures/LOSSLESS_POINT_TRANSFORM_PROVENANCE.md), so each decoded
	// sample must equal (source >> Pt) << Pt.
	const allocator = std.testing.allocator;
	{
		var img = try jpegz.decode(allocator, @embedFile("fixtures/lossless_16x16_rgb_p8_pt2_sel7_rst1.jpg"));
		defer img.deinit(allocator);
		try std.testing.expectEqual(@as(usize, 16 * 16 * 3), img.pixels.len);
		for (img.pixels, 0..) |got, i| {
			const x = (i / 3) % 16;
			const y = i / 48;
			const c = i % 3;
			const source = (16 * x + 8 * y + 32 * c + 10) % 256;
			try std.testing.expectEqual(source >> 2 << 2, got);
		}
	}
	const Wide = struct { data: []const u8, pt: u4, x_step: usize, y_step: usize, base: usize, modulus: usize };
	for ([_]Wide{
		.{ .data = @embedFile("fixtures/lossless_16x16_gray_p12_pt3_sel1.jpg"), .pt = 3, .x_step = 256, .y_step = 16, .base = 7, .modulus = 4096 },
		.{ .data = @embedFile("fixtures/lossless_16x16_gray_p16_pt4_sel4.jpg"), .pt = 4, .x_step = 4096, .y_step = 256, .base = 1234, .modulus = 65536 },
	}) |case| {
		var img = try jpegz.decode(allocator, case.data);
		defer img.deinit(allocator);
		const px = img.pixelsU16();
		try std.testing.expectEqual(@as(usize, 256), px.len);
		for (px, 0..) |got, i| {
			const source = (case.x_step * (i % 16) + case.y_step * (i / 16) + case.base) % case.modulus;
			try std.testing.expectEqual(source >> case.pt << case.pt, got);
		}
	}
}

test "lossless point-transform decode is total over every single-bit flip" {
	// A damaged stream can reconstruct a reduced sample wider than P - Pt
	// bits; the 2^Pt rescale must still return a P-bit sample or an error,
	// never trap.
	const allocator = std.testing.allocator;
	const pristine = @embedFile("fixtures/lossless_16x16_gray_p16_pt4_sel4.jpg");
	var data = pristine.*;
	for (0..data.len) |i| {
		for (0..8) |bit| {
			data[i] ^= @as(u8, 1) << @intCast(bit);
			defer data[i] = pristine[i];
			if (jpegz.decode(allocator, &data)) |img0| {
				var img = img0;
				img.deinit(allocator);
			} else |_| {}
		}
	}
}

test "arithmetic restart and scan ends are typed: 8, 56, 57 and truncated_stream (validate 2026-11-22)" {
	// One-MCU restart intervals: RST0 ends the first interval at `r0`.
	const allocator = std.testing.allocator;
	const gray = fixture_arith_restart_gray;
	var r0: usize = 0;
	while (!(gray[r0] == 0xff and gray[r0 + 1] == 0xd0)) r0 += 1;
	const eoi = gray.len - 2;
	try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xd9 }, gray[eoi..]);
	const filler = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0x10 };

	{ // A wrong RSTm is 57 at it; lenient decodes resynchronize, strict ones fail.
		const data = try allocator.dupe(u8, gray);
		defer allocator.free(data);
		data[r0 + 1] = 0xd3;
		var sink = jpegz.FindingsSink.init(allocator);
		defer sink.deinit();
		const end = arithEnd(allocator, &sink, data, true);
		try std.testing.expectEqual(@as(?anyerror, null), end.err);
		const f = end.first(.restart_marker_unexpected).?;
		try std.testing.expect(f.offset_is_exact and f.offset.? == r0 and f.severity == .fail);
		try std.testing.expectEqualStrings("expected RST0 (0xd0) but got RST3 (0xd3)", f.detail.?);
		// Resynchronized to RST4, the file's RST1 is out of order too.
		try std.testing.expectEqual(@as(usize, 2), end.count(.restart_marker_unexpected));
		var strict_sink = jpegz.FindingsSink.init(allocator);
		defer strict_sink.deinit();
		const strict = arithEnd(allocator, &strict_sink, data, false);
		try std.testing.expectEqual(@as(?anyerror, error.InvalidMarker), strict.err);
		try std.testing.expectEqual(@as(usize, 1), strict.count(.restart_marker_unexpected));
	}
	{ // Another marker where an RSTm belongs is 56 at it.
		const data = try allocator.dupe(u8, gray);
		defer allocator.free(data);
		data[r0 + 1] = 0xc4;
		var sink = jpegz.FindingsSink.init(allocator);
		defer sink.deinit();
		const end = arithEnd(allocator, &sink, data, true);
		try std.testing.expectEqual(@as(?anyerror, error.InvalidMarker), end.err);
		const f = end.first(.restart_marker_missing).?;
		try std.testing.expect(f.offset_is_exact and f.offset.? == r0);
		try std.testing.expectEqualStrings("marker 0xc4 where RST0 belongs", f.detail.?);
	}
	{ // EOI where an RSTm belongs, or data that ends there, is truncated_stream.
		const with_eoi = try std.mem.concat(allocator, u8, &.{ gray[0..r0], &.{ 0xff, 0xd9 } });
		defer allocator.free(with_eoi);
		for ([_][]const u8{ with_eoi, gray[0..r0] }) |data| {
			var sink = jpegz.FindingsSink.init(allocator);
			defer sink.deinit();
			const end = arithEnd(allocator, &sink, data, true);
			try std.testing.expectEqual(@as(?anyerror, error.TruncatedStream), end.err);
			const f = end.first(.truncated_stream).?;
			try std.testing.expect(f.offset_is_exact and f.offset.? == r0);
		}
	}
	{ // Whole bytes the coder never fetches before an RSTm are FAIL 8.
		const data = try std.mem.concat(allocator, u8, &.{ gray[0..r0], &filler, gray[r0..] });
		defer allocator.free(data);
		var sink = jpegz.FindingsSink.init(allocator);
		defer sink.deinit();
		const end = arithEnd(allocator, &sink, data, true);
		try std.testing.expectEqual(@as(?anyerror, null), end.err);
		try std.testing.expectEqual(@as(usize, 1), end.count(.extraneous_bytes_before_marker));
		const f = end.first(.extraneous_bytes_before_marker).?;
		try std.testing.expect(f.severity == .fail and f.offset_is_exact);
		try std.testing.expect(f.offset.? >= r0 and f.offset.? < r0 + filler.len);
		try std.testing.expectEqualStrings("arithmetic_interval", f.detail.?);
		var strict_sink = jpegz.FindingsSink.init(allocator);
		defer strict_sink.deinit();
		try std.testing.expectEqual(@as(?anyerror, error.InvalidMarker), arithEnd(allocator, &strict_sink, data, false).err);
	}
	{ // ...and before the marker that ends the scan, without failing the decode.
		const data = try std.mem.concat(allocator, u8, &.{ gray[0..eoi], &filler, gray[eoi..] });
		defer allocator.free(data);
		for ([_]bool{ true, false }) |lenient| {
			var sink = jpegz.FindingsSink.init(allocator);
			defer sink.deinit();
			const end = arithEnd(allocator, &sink, data, lenient);
			try std.testing.expectEqual(@as(?anyerror, null), end.err);
			const f = end.first(.extraneous_bytes_before_marker).?;
			try std.testing.expect(f.offset.? >= eoi and f.offset.? < eoi + filler.len);
			try std.testing.expectEqualStrings("arithmetic_scan_end", f.detail.?);
		}
	}
	{ // An RSTm after the final MCU is 57.
		const data = try std.mem.concat(allocator, u8, &.{ gray[0..eoi], &.{ 0xff, 0xd7 }, gray[eoi..] });
		defer allocator.free(data);
		var sink = jpegz.FindingsSink.init(allocator);
		defer sink.deinit();
		const end = arithEnd(allocator, &sink, data, true);
		try std.testing.expectEqual(@as(?anyerror, error.BackendError), end.err);
		const f = end.first(.restart_marker_unexpected).?;
		try std.testing.expect(f.offset_is_exact and f.offset.? == eoi);
		try std.testing.expectEqualStrings("restart marker after the final MCU of the scan", f.detail.?);
	}
	{ // The clean file has none of these.
		var sink = jpegz.FindingsSink.init(allocator);
		defer sink.deinit();
		const end = arithEnd(allocator, &sink, gray, true);
		try std.testing.expectEqual(@as(?anyerror, null), end.err);
		try std.testing.expectEqual(@as(usize, 0), end.len);
	}
}

test "progressive arithmetic restart and scan ends are typed the same way" {
	const allocator = std.testing.allocator;
	const prog = fixture_arith_restart_rgb420_progressive;
	var r0: usize = 0;
	while (!(prog[r0] == 0xff and prog[r0 + 1] == 0xd0)) r0 += 1;
	// The first scan ends at the first marker after RST0 that is not an RSTm
	// (here the DAC before the second scan).
	var scan1_end: usize = r0 + 2;
	while (!(prog[scan1_end] == 0xff and prog[scan1_end + 1] != 0 and (prog[scan1_end + 1] < 0xd0 or prog[scan1_end + 1] > 0xd7))) scan1_end += 1;
	try std.testing.expectEqual(@as(u8, 0xcc), prog[scan1_end + 1]);
	{
		const data = try allocator.dupe(u8, prog);
		defer allocator.free(data);
		data[r0 + 1] = 0xd5;
		var sink = jpegz.FindingsSink.init(allocator);
		defer sink.deinit();
		const end = arithEnd(allocator, &sink, data, true);
		const f = end.first(.restart_marker_unexpected).?;
		try std.testing.expect(f.offset_is_exact and f.offset.? == r0);
		try std.testing.expectEqualStrings("expected RST0 (0xd0) but got RST5 (0xd5)", f.detail.?);
	}
	{
		const filler = [_]u8{ 0x21, 0x43, 0x65, 0x87, 0xa9, 0xcb, 0xed, 0x0f };
		const data = try std.mem.concat(allocator, u8, &.{ prog[0..scan1_end], &filler, prog[scan1_end..] });
		defer allocator.free(data);
		var sink = jpegz.FindingsSink.init(allocator);
		defer sink.deinit();
		const end = arithEnd(allocator, &sink, data, true);
		try std.testing.expectEqual(@as(?anyerror, null), end.err);
		const f = end.first(.extraneous_bytes_before_marker).?;
		try std.testing.expect(f.severity == .fail and f.offset_is_exact);
		try std.testing.expect(f.offset.? >= scan1_end and f.offset.? < scan1_end + filler.len);
		try std.testing.expectEqualStrings("arithmetic_scan_end", f.detail.?);
	}
	{
		var sink = jpegz.FindingsSink.init(allocator);
		defer sink.deinit();
		const end = arithEnd(allocator, &sink, prog, true);
		try std.testing.expectEqual(@as(?anyerror, null), end.err);
		try std.testing.expectEqual(@as(usize, 0), end.len);
	}
}

test "B1: SOF9 arithmetic baseline cleanroom (gray + RGB at all sampling factors)" {
    // Real cleanroom-vs-wrapper gate. Same tolerance shape as A3:
    // ≤4 LSB for RGB (chroma upsampling amplifies sub-pixel rounding),
    // ≤2 LSB for grayscale.
    const allocator = std.testing.allocator;
    const RgbCase = struct { data: []const u8 };
    const rgb_cases = [_]RgbCase{
        .{ .data = fixture_arith_baseline_16x16_rgb_444 },
        .{ .data = fixture_arith_baseline_16x16_rgb_420 },
        .{ .data = fixture_arith_baseline_16x16_rgb_422 },
        .{ .data = fixture_arith_baseline_16x16_rgb_440 },
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
        // 2026-05-16: asymmetric-bias fancy upsample fix — byte-perfect.
        try std.testing.expectEqualSlices(u8, wrapper.pixels, cleanroom.pixels);
    }
    {
        var cleanroom = try jpegz.internal.arithDecode(allocator, fixture_arith_baseline_8x8_gray);
        defer cleanroom.deinit(allocator);
        var wrapper = try jpegz.internal.wrapperDecode(allocator, fixture_arith_baseline_8x8_gray);
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

test "A3: SOF2 12-bit progressive cleanroom (gray + RGB at all sampling factors)" {
    const allocator = std.testing.allocator;
    const RgbCase = struct { data: []const u8 };
    const rgb_cases = [_]RgbCase{
        .{ .data = fixture_progressive_16x16_rgb12_444 },
        .{ .data = fixture_progressive_16x16_rgb12_420 },
        .{ .data = fixture_progressive_16x16_rgb12_422 },
        .{ .data = fixture_progressive_16x16_rgb12_440 },
    };
    inline for (rgb_cases) |c| {
        var cleanroom = try jpegz.internal.progressiveDecode(allocator, c.data);
        defer cleanroom.deinit(allocator);
        var wrapper = try jpegz.internal.wrapperDecode(allocator, c.data);
        defer wrapper.deinit(allocator);
        try std.testing.expectEqual(@as(u8, 12), cleanroom.bits_per_sample);
        try std.testing.expectEqual(@as(u8, 3), cleanroom.channels);
        try std.testing.expectEqual(@as(u32, 16), cleanroom.width);
        try std.testing.expectEqual(@as(u32, 16), cleanroom.height);
        try std.testing.expectEqual(jpegz.PixelLayout.rgb, cleanroom.layout);
        const c_u16 = cleanroom.pixelsU16();
        const w_u16 = wrapper.pixelsU16();
        try std.testing.expectEqual(w_u16.len, c_u16.len);
        // 2026-05-16: PASS1_BITS=1 fix at P=12 brought the cleanroom
        // into byte-identical alignment with libjpeg-turbo across the
        // entire 12-bit DCT path. Tightened from ≤4 LSB to == 0.
        try std.testing.expectEqual(w_u16.len, c_u16.len);
        for (c_u16, w_u16) |a, b| try std.testing.expectEqual(b, a);
    }
    // Grayscale case — no chroma upsample, no color conversion.
    {
        var cleanroom = try jpegz.internal.progressiveDecode(allocator, fixture_progressive_8x8_gray12);
        defer cleanroom.deinit(allocator);
        var wrapper = try jpegz.internal.wrapperDecode(allocator, fixture_progressive_8x8_gray12);
        defer wrapper.deinit(allocator);
        try std.testing.expectEqual(@as(u8, 12), cleanroom.bits_per_sample);
        try std.testing.expectEqual(@as(u8, 1), cleanroom.channels);
        try std.testing.expectEqual(jpegz.PixelLayout.grayscale, cleanroom.layout);
        const cw = wrapper.pixelsU16();
        const cc = cleanroom.pixelsU16();
        try std.testing.expectEqual(cw.len, cc.len);
        for (cc, cw) |a, b| try std.testing.expectEqual(b, a);
    }
}

test "A1 Part B: SOF1 12-bit RGB cleanroom decodes vs wrapper, all sampling factors" {
    const allocator = std.testing.allocator;
    const cases = [_][]const u8{
        fixture_baseline_16x16_rgb12_444,
        fixture_baseline_16x16_rgb12_420,
        fixture_baseline_16x16_rgb12_422,
        fixture_baseline_16x16_rgb12_440,
    };
    inline for (cases) |data| {
        var cleanroom = try jpegz.internal.cleanroomDecode(allocator, data);
        defer cleanroom.deinit(allocator);
        var wrapper = try jpegz.internal.wrapperDecode(allocator, data);
        defer wrapper.deinit(allocator);
        try std.testing.expectEqual(@as(u8, 12), cleanroom.bits_per_sample);
        try std.testing.expectEqual(@as(u8, 3), cleanroom.channels);
        try std.testing.expectEqual(@as(u32, 16), cleanroom.width);
        try std.testing.expectEqual(@as(u32, 16), cleanroom.height);
        try std.testing.expectEqual(jpegz.PixelLayout.rgb, cleanroom.layout);
        const c_u16 = cleanroom.pixelsU16();
        const w_u16 = wrapper.pixelsU16();
        try std.testing.expectEqual(w_u16.len, c_u16.len);
        // 2026-05-16: PASS1_BITS=1 fix at P=12 (libjpeg-turbo parity)
        // collapsed the rounding mismatch — tightened from ≤4 LSB to == 0.
        try std.testing.expectEqual(w_u16.len, c_u16.len);
        for (c_u16, w_u16) |a, b| try std.testing.expectEqual(b, a);
    }
}

test "A1: SOF1 12-bit grayscale cleanroom decodes byte-for-byte vs wrapper" {
    const allocator = std.testing.allocator;
    var cleanroom = try jpegz.internal.cleanroomDecode(allocator, fixture_baseline_4x4_gray12_dct);
    defer cleanroom.deinit(allocator);
    var wrapper = try jpegz.internal.wrapperDecode(allocator, fixture_baseline_4x4_gray12_dct);
    defer wrapper.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 12), cleanroom.bits_per_sample);
    try std.testing.expectEqual(wrapper.bits_per_sample, cleanroom.bits_per_sample);
    try std.testing.expectEqual(@as(u32, 4), cleanroom.width);
    try std.testing.expectEqual(@as(u32, 4), cleanroom.height);
    try std.testing.expectEqual(@as(u8, 1), cleanroom.channels);
    try std.testing.expectEqual(jpegz.PixelLayout.grayscale, cleanroom.layout);
    const cleanroom_u16 = cleanroom.pixelsU16();
    const wrapper_u16 = wrapper.pixelsU16();
    try std.testing.expectEqual(@as(usize, 16), cleanroom_u16.len);
    try std.testing.expectEqual(wrapper_u16.len, cleanroom_u16.len);
    // 2026-05-16: PASS1_BITS=1 fix at P=12 — tightened from ≤2 LSB to ==0.
    for (cleanroom_u16, wrapper_u16) |c, w| try std.testing.expectEqual(w, c);
}

