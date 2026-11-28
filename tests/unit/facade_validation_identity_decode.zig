//! facade_validation tests, part 4 (split from facade_validation.zig to keep files small).

const std = @import("std");
const jpegz = @import("jpegz");
const h1 = @import("facade_validation_helpers.zig");
const sof3_pair = h1.sof3_pair;
const hierarchicalStream = h1.hierarchicalStream;

test "a damaged SOI keeps JPEG identity only on a chain of complete marker segments" {
	// Validate, 2026-11-05: when the rest of the stream is unmistakably JPEG,
	// damaged SOI bytes are corruption, not an unrecognized container. The
	// bound is two or more complete T.81 marker segments chained from offset 2,
	// where an intact SOI would hand off.
	const allocator = std.testing.allocator;
	const fixtures = [_][]const u8{
		@embedFile("fixtures/baseline_2x2_rgb.jpg"),
		@embedFile("fixtures/progressive_8x8_rgb.jpg"),
		@embedFile("fixtures/lossless_4x4_gray8.jpg"),
	};
	// Each pair leaves the sniffer with no signature (0xFF 0x4F and 0xFF 0x0A
	// would claim JPEG 2000 and JPEG XL instead).
	const damaged = [_][2]u8{ .{ 0, 0 }, .{ 0xff, 0xd9 }, .{ 0x7f, 0xd8 }, .{ 0xff, 0x58 }, .{ 0xfe, 0xd8 } };
	for (fixtures) |fixture| {
		for (damaged) |soi| {
			const data = try allocator.dupe(u8, fixture);
			defer allocator.free(data);
			data[0] = soi[0];
			data[1] = soi[1];
			try std.testing.expectEqual(jpegz.ValidationFormat.unknown, jpegz.sniff(data));
			var result = try jpegz.validateAny(allocator, data);
			defer result.deinit(allocator);
			try std.testing.expectEqual(jpegz.ValidationFormat.jpeg, result.format);
			try std.testing.expectEqual(jpegz.StrictVerdict.corrupt, result.verdict);
			var found = false;
			for (result.findings.items) |finding| {
				try std.testing.expect(finding.code != .unrecognized_container);
				if (finding.code == .missing_soi and finding.severity == .fail and finding.offset == 0) {
					found = true;
					try std.testing.expect(std.mem.indexOf(u8, finding.detail.?, "marker segments") != null);
				}
			}
			try std.testing.expect(found);
		}
	}
	// Controls stay unrecognized: one complete segment, a chain broken by a
	// non-marker byte or an overlong length, foreign signatures and noise.
	const one_segment = [_]u8{ 0, 0, 0xff, 0xe0, 0, 4, 'J', 'F', 0x00, 0x00, 0x00, 0x00 };
	const broken = [_]u8{ 0, 0, 0xff, 0xe0, 0, 4, 'J', 'F', 0x00, 0xdb, 0, 4, 1, 2 };
	const overlong = [_]u8{ 0, 0, 0xff, 0xe0, 0, 4, 'J', 'F', 0xff, 0xdb, 0, 9, 1, 2 };
	const reserved = [_]u8{ 0, 0, 0xff, 0xe0, 0, 4, 'J', 'F', 0xff, 0x30, 0, 4, 1, 2 };
	const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0DIHDR\x00\x00\x00\x01";
	var noise: [4096]u8 = undefined;
	var prng = std.Random.DefaultPrng.init(0x6a706567);
	prng.random().bytes(&noise);
	noise[0] = 0;
	for ([_][]const u8{ &one_segment, &broken, &overlong, &reserved, png, &noise }) |data| {
		var result = try jpegz.validateAny(allocator, data);
		defer result.deinit(allocator);
		try std.testing.expectEqual(jpegz.ValidationFormat.unknown, result.format);
		try std.testing.expectEqual(jpegz.StrictVerdict.indeterminate, result.verdict);
	}
}

test "a JP2 with a destroyed signature box is not misdiagnosed as a JPEG missing SOI" {
	// The C CLI's ad-hoc sniffer fell through to the JPEG path here and
	// reported `missing_soi — JPEG must start with SOI marker`, naming a
	// T.81 marker that does not exist anywhere in T.800. Routing must never
	// invent a format the bytes never claimed.
	const good = @embedFile("fixtures/jp2_8x8_rgb.jp2");
	var smashed = good.*;
	@memset(smashed[0..12], 0);
	var result = try jpegz.validateAny(std.testing.allocator, &smashed);
	defer result.deinit(std.testing.allocator);
	try std.testing.expect(result.format != .jpeg);
	try std.testing.expect(!result.isValid());
	for (result.findings.items) |finding| {
		if (finding.code) |code| try std.testing.expect(code != .missing_soi);
	}
}

test "JPEG facade marks typed sequential-DCT failures with exact offsets" {
	// Two coverage violations of a split-scan frame.
	const seq = @embedFile("fixtures/seq_16x16_3scan.jpg");
	var repeated = seq.*;
	repeated[661 + 5] = 2; // component 2 coded twice
	const early_eoi = seq[0..661].* ++ [_]u8{ 0xff, 0xd9 };
	const Case = struct { data: []const u8, code: jpegz.FindingCode, offset: u64 };
	for ([_]Case{
		.{ .data = &repeated, .code = .sos_component_mismatch, .offset = 666 },
		.{ .data = &early_eoi, .code = .truncated_stream, .offset = 661 },
	}) |c| {
		var result = try jpegz.validateAny(std.testing.allocator, c.data);
		defer result.deinit(std.testing.allocator);
		try std.testing.expectEqual(jpegz.StrictVerdict.corrupt, result.verdict);
		var exact = false;
		for (result.findings.items) |finding| {
			if (finding.code == c.code and finding.severity == .fail and finding.offset == c.offset and finding.offset_is_exact) exact = true;
			try std.testing.expect(finding.code != .huffman_table_corrupt);
		}
		if (!exact) {
			std.debug.print("no exact {s} @{d}\n", .{ @tagName(c.code), c.offset });
			return error.TestUnexpectedResult;
		}
	}
}

test "JPEG facade warns on zero padding from a known encoder and still decodes" {
	// Validate's 2026-09-30 synthetic repro of the Intel JPEG Library 1.51
	// pattern: an ImageMagick 16x16 4:2:0 JPEG whose final entropy byte (offset
	// 293, before EOI) was changed from 0x4F to 0x40, so its pad bits are 0
	// (T.81 F.1.2.3). libjpeg-turbo opens it; this known encoder defect is
	// reported as WARN and never refuses decoding.
	const padded = @embedFile("fixtures/zero_pad_16x16_420.jpg");
	var result = try jpegz.validateAny(std.testing.allocator, padded);
	defer result.deinit(std.testing.allocator);
	try std.testing.expectEqual(jpegz.StrictVerdict.known_defect, result.verdict);
	var warned: usize = 0;
	for (result.findings.items) |finding| {
		try std.testing.expect(finding.severity != .fail);
		if (finding.code == .entropy_padding_zero_bits and finding.severity == .known_defect and
			finding.offset == 293 and finding.offset_is_exact) warned += 1;
	}
	try std.testing.expectEqual(@as(usize, 1), warned);
	var image = try jpegz.decode(std.testing.allocator, padded);
	defer image.deinit(std.testing.allocator);
	try std.testing.expectEqual(@as(u32, 16), image.width);
}

test "JPEG XL decode returns every lossless sample at its stored depth" {
	if (!jpegz.facade.with_jxl) return error.SkipZigTest;
	const allocator = std.testing.allocator;
	// cjxl 0.12.0 -d 0 from formula images (37x + 101y + 53c + 7xy) mod 2^bits;
	// djxl reproduces each source exactly (tests/unit/fixtures/JXL_DECODE_PROVENANCE.md).
	const cases = [_]struct { bytes: []const u8, color: u8, alpha: bool, bits: u8 }{
		.{ .bytes = @embedFile("fixtures/jxl_lossless_9x7_gray8.jxl"), .color = 1, .alpha = false, .bits = 8 },
		.{ .bytes = @embedFile("fixtures/jxl_lossless_9x7_graya8.jxl"), .color = 1, .alpha = true, .bits = 8 },
		.{ .bytes = @embedFile("fixtures/jxl_lossless_9x7_rgb8.jxl"), .color = 3, .alpha = false, .bits = 8 },
		.{ .bytes = @embedFile("fixtures/jxl_lossless_9x7_rgba8.jxl"), .color = 3, .alpha = true, .bits = 8 },
		.{ .bytes = @embedFile("fixtures/jxl_lossless_9x7_gray12.jxl"), .color = 1, .alpha = false, .bits = 12 },
		.{ .bytes = @embedFile("fixtures/jxl_lossless_9x7_rgb16.jxl"), .color = 3, .alpha = false, .bits = 16 },
	};
	for (cases) |case| {
		var decoded = try jpegz.jpegxl.decode(allocator, case.bytes);
		defer decoded.deinit(allocator);
		const image = decoded.image;
		const channels: u8 = case.color + @intFromBool(case.alpha);
		try std.testing.expectEqual(@as(u32, 9), image.width);
		try std.testing.expectEqual(@as(u32, 7), image.height);
		try std.testing.expectEqual(channels, image.channels);
		try std.testing.expectEqual(case.bits, image.bits_per_sample);
		try std.testing.expectEqual(case.color, decoded.color_channels);
		try std.testing.expectEqual(case.alpha, decoded.has_alpha);
		try std.testing.expectEqual(@as(u32, 0), decoded.extra_channels_dropped);
		try std.testing.expectEqual(if (case.color == 1) jpegz.ColorSpace.grayscale else .rgb, image.source_color_space);
		try std.testing.expectEqual(if (case.alpha) jpegz.PixelLayout.components else if (case.color == 1) jpegz.PixelLayout.grayscale else .rgb, image.layout);
		try std.testing.expectEqual(image.rowStride() * image.height, image.pixels.len);
		const modulus: u32 = @as(u32, 1) << @intCast(case.bits);
		var mismatches: usize = 0;
		for (0..7) |y| for (0..9) |x| for (0..channels) |c| {
			const expected: u32 = @intCast((37 * x + 101 * y + 53 * c + 7 * x * y) % modulus);
			const index = (y * 9 + x) * channels + c;
			const got: u32 = if (case.bits > 8) image.pixelsU16()[index] else image.pixels[index];
			if (got != expected) mismatches += 1;
		};
		if (mismatches != 0) std.debug.print("JXL {d}-bit {d}+{} channels: {d} mismatched samples\n", .{ case.bits, case.color, case.alpha, mismatches });
		try std.testing.expectEqual(@as(usize, 0), mismatches);
	}
}

test "JPEG XL decode reports truncation and rejection as typed errors" {
	if (!jpegz.facade.with_jxl) return error.SkipZigTest;
	const allocator = std.testing.allocator;
	const whole = @embedFile("fixtures/jxl_lossless_9x7_rgb8.jxl");
	for ([_]usize{ 0, 1, 2, 12, whole.len / 2, whole.len - 1 }) |length| {
		if (jpegz.jpegxl.decode(allocator, whole[0..length])) |decoded| {
			var d = decoded;
			d.deinit(allocator);
			std.debug.print("JXL prefix {d} of {d} decoded\n", .{ length, whole.len });
			return error.TestUnexpectedResult;
		} else |err| switch (err) {
			error.TruncatedStream, error.BackendError => {},
			else => return err,
		}
	}
	try std.testing.expectError(error.BackendError, jpegz.jpegxl.decode(allocator, "not a JPEG XL codestream"));
}

test "JPEG XL trailing data is WARN 199, or INFO for a PAR2 trailer, at the first byte after the image" {
	if (!jpegz.facade.with_jxl) return error.SkipZigTest;
	const allocator = std.testing.allocator;
	const image = @embedFile("fixtures/jxl_lossless_9x7_rgb8.jxl");
	const Case = struct { tail: []const u8, severity: jpegz.Severity };
	for ([_]Case{
		.{ .tail = "PAR2\x00PKT" ++ [_]u8{0x11} ** 56, .severity = .info },
		.{ .tail = "trailing junk!", .severity = .warn },
		.{ .tail = &([_]u8{0} ** 16), .severity = .warn },
	}) |case| {
		const data = try std.mem.concat(allocator, u8, &.{ image, case.tail });
		defer allocator.free(data);
		var result = try jpegz.jpegxl.validate(allocator, data, jpegz.jpegxl.default_options);
		defer result.deinit(allocator);
		try std.testing.expectEqual(jpegz.StrictVerdict.valid, result.verdict);
		var seen = false;
		for (result.findings.items) |finding| {
			if (finding.code != .jxl_trailing_data) continue;
			seen = true;
			try std.testing.expectEqual(case.severity, finding.severity);
			try std.testing.expectEqual(@as(?u64, image.len), finding.offset);
			try std.testing.expectEqual(@as(u32, 19), finding.leaf_code);
		}
		try std.testing.expect(seen);
	}
	var clean = try jpegz.jpegxl.validate(allocator, image, jpegz.jpegxl.default_options);
	defer clean.deinit(allocator);
	for (clean.findings.items) |finding| try std.testing.expect(finding.code != .jxl_trailing_data);
}

