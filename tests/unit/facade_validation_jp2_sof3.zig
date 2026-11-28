//! facade_validation tests, part 1 (split from facade_validation.zig to keep files small).

const std = @import("std");
const jpegz = @import("jpegz");
const h1 = @import("facade_validation_helpers.zig");
const sof3_pair = h1.sof3_pair;
const hierarchicalStream = h1.hierarchicalStream;

test "JP2 declared ends beyond input retain corruption without a byte location" {
	const allocator = std.testing.allocator;
	var bytes = @embedFile("fixtures/jp2_8x8_rgb.jp2").*;
	bytes[215] ^= 1;
	var result = try jpegz.jpeg2000.strictValidate(allocator, &bytes);
	defer result.deinit(allocator);
	try std.testing.expectEqual(jpegz.StrictVerdict.corrupt, result.verdict);
	var found = false;
	var retained_anchor = false;
	for (result.findings.items) |finding| {
		// The original leaf report also has this in-buffer detection anchor.
		if (finding.offset == 147) {
			try std.testing.expectEqual(@as(?u64, 147), finding.host_offset);
			retained_anchor = true;
		}
		if (finding.leaf_code != 3) continue;
		found = true;
		try std.testing.expectEqual(jpegz.FindingCode.truncated_stream, finding.code.?);
		try std.testing.expectEqual(jpegz.Severity.fail, finding.severity);
		try std.testing.expectEqual(@as(?u64, null), finding.offset);
		try std.testing.expectEqual(@as(?u64, null), finding.host_offset);
		try std.testing.expect(!finding.offset_is_exact);
		try std.testing.expect(std.mem.indexOf(u8, finding.detail orelse "", "242") != null);
	}
	try std.testing.expect(found);
	try std.testing.expect(retained_anchor);
}

test "JP2 packet corruption never exposes an offset beyond the input" {
	const allocator = std.testing.allocator;
	const pristine = @embedFile("fixtures/jp2_8x8_rgb.jp2");
	const sod = std.mem.indexOf(u8, pristine, &.{ 0xff, 0x93 }) orelse return error.MissingSod;
	// Keep container/geometry headers fixed. Sweep every one-bit mutation of
	// the packet region, including its length declarations, with a clean control.
	for (sod + 2..pristine.len - 2) |offset| {
		for (0..8) |bit| {
			var bytes = pristine.*;
			bytes[offset] ^= @as(u8, 1) << @intCast(bit);
			var result = try jpegz.jpeg2000.strictValidate(allocator, &bytes);
			defer result.deinit(allocator);
			for (result.findings.items) |finding| {
				if (finding.offset) |location| {
					if (location > bytes.len) {
						std.debug.print("JP2 bit mutation at {d}:{d} reports leaf {d} at {d}, input length {d}\n",
							.{ offset, bit, finding.leaf_code, location, bytes.len });
						return error.OffsetBeyondInput;
					}
					if (location == bytes.len) try std.testing.expect(!finding.offset_is_exact);
					try std.testing.expectEqual(@as(?u64, location), finding.host_offset);
				}
				if (finding.host_offset) |location| try std.testing.expect(location <= bytes.len);
			}
		}
	}
	var clean = try jpegz.jpeg2000.strictValidate(allocator, pristine);
	defer clean.deinit(allocator);
	try std.testing.expectEqual(jpegz.StrictVerdict.valid, clean.verdict);
}

test "known encoder defects have their own verdict without hiding corruption" {
	const allocator = std.testing.allocator;
	const zero = @embedFile("fixtures/zero_pad_16x16_420.jpg");
	const dc_table = [_]u8{ 0xff, 0xc4, 0, 20, 0, 1 } ++ ([_]u8{0} ** 15) ++ [_]u8{0};
	const lossless_header = [_]u8{ 0xff, 0xd8, 0xff, 0xc3, 0, 11, 8, 0, 1, 0, 1, 1, 1, 0x11, 0 } ++
		dc_table ++ [_]u8{ 0xff, 0xda, 0, 8, 1, 1, 0, 1, 0, 0 };
	const lossless_zero = lossless_header ++ [_]u8{ 0, 0xff, 0xd9 };
	const progressive_header = [_]u8{ 0xff, 0xd8, 0xff, 0xdb, 0, 67, 0 } ++ ([_]u8{16} ** 64) ++
		[_]u8{ 0xff, 0xc2, 0, 11, 8, 0, 8, 0, 16, 1, 1, 0x11, 0 } ++ dc_table ++
		[_]u8{ 0xff, 0xc4, 0, 20, 0x10 } ++ ([_]u8{0} ** 6) ++ [_]u8{1} ++ ([_]u8{0} ** 9) ++ [_]u8{0x10} ++
		[_]u8{ 0xff, 0xda, 0, 8, 1, 1, 0, 0, 0, 0 };
	const progressive_zero = progressive_header ++ [_]u8{ 0, 0xff, 0xda, 0, 8, 1, 1, 0, 1, 63, 0, 0, 0xff, 0xd9 };
	const cases = [_]struct { bytes: []const u8, verdict: u8, pad_offset: u64 = 293 }{
		.{ .bytes = zero, .verdict = 4 }, // Appended KNOWN_DEFECT wire value.
		.{ .bytes = &lossless_zero, .verdict = 4, .pad_offset = lossless_header.len },
		.{ .bytes = &progressive_zero, .verdict = 4, .pad_offset = progressive_header.len },
		.{ .bytes = zero[0 .. zero.len - 2], .verdict = 1 }, // Missing EOI wins.
		.{ .bytes = @embedFile("fixtures/baseline_2x2_rgb.jpg"), .verdict = 0 },
	};
	for (cases) |case| {
		var result = try jpegz.validateAny(allocator, case.bytes);
		defer result.deinit(allocator);
		try std.testing.expectEqual(case.verdict, @intFromEnum(result.verdict));
		try std.testing.expectEqual(case.verdict == 0, result.isValid());
		if (case.verdict != 4) continue;
		var found = false;
		for (result.findings.items) |finding| {
			if (finding.code != .entropy_padding_zero_bits) continue;
			found = true;
			try std.testing.expectEqual(jpegz.Severity.known_defect, finding.severity);
			try std.testing.expect(finding.offset_is_exact);
			try std.testing.expectEqual(@as(?u64, case.pad_offset), finding.offset);
		}
		try std.testing.expect(found);
	}
}

test "JPEG 2000 facade identifies the SIZ tile-origin invariant at its marker" {
	// T.800 B.3: XTOsiz <= XOsiz < XTOsiz + XTsiz, and likewise in Y.
	// These SIZ-only controls assess this finding, not full-stream validity.
	const base = [_]u8{
		0xff, 0x4f, 0xff, 0x51, 0, 41, 0, 0,
		0, 0, 0, 6, 0, 0, 0, 6, 0, 0, 0, 2, 0, 0, 0, 2,
		0, 0, 0, 3, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 1, 7, 1, 1, 0xff, 0xd9,
	};
	const Case = struct {
		x_tile: u32,
		y_tile: u32,
		x_origin: u32 = 2,
		x_tile_origin: u32 = 0,
		x_extent: u32 = 6,
		illegal: bool,
	};
	const cases = [_]Case{
		.{ .x_tile = 3, .y_tile = 3, .illegal = false },
		.{ .x_tile = 2, .y_tile = 3, .illegal = true },
		.{ .x_tile = 3, .y_tile = 2, .illegal = true },
		.{ .x_tile = 1, .y_tile = 1, .illegal = true },
		.{ .x_tile = 6, .y_tile = 6, .illegal = false },
		.{ .x_tile = 4, .y_tile = 6, .x_origin = 0xfffffffe,
			.x_tile_origin = 0xfffffffd, .x_extent = 0xffffffff, .illegal = false },
	};
	for (cases) |case| {
		var bytes = base;
		std.mem.writeInt(u32, bytes[8..12], case.x_extent, .big);
		std.mem.writeInt(u32, bytes[16..20], case.x_origin, .big);
		std.mem.writeInt(u32, bytes[24..28], case.x_tile, .big);
		std.mem.writeInt(u32, bytes[28..32], case.y_tile, .big);
		std.mem.writeInt(u32, bytes[32..36], case.x_tile_origin, .big);
		var result = try jpegz.jpeg2000.strictValidate(std.testing.allocator, &bytes);
		defer result.deinit(std.testing.allocator);
		var found = false;
		for (result.findings.items) |finding| {
			if (finding.code != .jp2_invalid_siz) continue;
			found = true;
			try std.testing.expectEqual(jpegz.ValidatorSource.jp2z, finding.source);
			try std.testing.expectEqual(@as(u32, 146), finding.leaf_code);
			try std.testing.expectEqual(jpegz.Severity.fail, finding.severity);
			try std.testing.expectEqual(@as(?u64, 2), finding.offset);
			try std.testing.expect(std.mem.indexOf(u8, finding.detail.?, "B.3") != null);
		}
		try std.testing.expectEqual(case.illegal, found);
		if (case.illegal) try std.testing.expectEqual(jpegz.StrictVerdict.corrupt, result.verdict);
	}
	var pristine = try jpegz.jpeg2000.strictValidate(std.testing.allocator, @embedFile("fixtures/jp2_8x8_rgb.jp2"));
	defer pristine.deinit(std.testing.allocator);
	try std.testing.expectEqual(jpegz.StrictVerdict.valid, pristine.verdict);
}

test "strict facade rejects Validate's oversubscribed DHT crasher" {
	// Public synthetic 178-byte reproduction supplied September 26, 2026.
	const hex = "ffd8ffe000104a46494600010100000100010000ffdb00430003020203020203" ++
		"03030304030304050805050404050a070706080c0a0c0c0b0a0b0b0d0e12100d" ++
		"0e110e0b0b1016101113141515150c0f171816141812141514ffc0000b080010" ++
		"001001011100ffc400160001010100000000000000000000000000000809ffc4" ++
		"00171003000100000000000000000000000000001864a2ffda0008010100003f" ++
		"00921639321639326b5ac72642c7264fffd9";
	var bytes: [178]u8 = undefined;
	const data = try std.fmt.hexToBytes(&bytes, hex);
	try std.testing.expectEqual(@as(usize, 178), data.len);
	var result = try jpegz.validateAny(std.testing.allocator, data);
	defer result.deinit(std.testing.allocator);
	try std.testing.expectEqual(jpegz.StrictVerdict.corrupt, result.verdict);
	var found = false;
	for (result.findings.items) |finding| {
		if (finding.code == .huffman_table_corrupt and finding.severity == .fail) found = true;
	}
	try std.testing.expect(found);
}

test "SOF3 DHT bodies: a full table is known defect 71, oversubscribed is corrupt" {
	const allocator = std.testing.allocator;
	for ([_]u8{ 1, 2, 3 }) |count| {
		var header = sof3_pair[0..40].*;
		header[21] = 19 + count;
		header[23] = count;
		const values = [_]u8{ 0, 0 };
		const data = try std.mem.concat(allocator, u8, &.{ &header, values[0 .. count - 1], sof3_pair[40..] });
		defer allocator.free(data);
		var result = try jpegz.validateAny(allocator, data);
		defer result.deinit(allocator);
		// Two one-bit codes fill the space: the second is the all-ones code.
		const expected: jpegz.StrictVerdict = switch (count) {
			1 => .valid,
			2 => .known_defect,
			else => .corrupt,
		};
		try std.testing.expectEqual(expected, result.verdict);
		var full: usize = 0;
		for (result.findings.items) |finding| {
			if (finding.code != .huffman_table_full_all_ones) continue;
			full += 1;
			try std.testing.expectEqual(jpegz.Severity.known_defect, finding.severity);
			try std.testing.expectEqual(@as(?u64, 23), finding.offset);
			try std.testing.expect(finding.offset_is_exact);
		}
		try std.testing.expectEqual(@as(usize, @intFromBool(count == 2)), full);
	}
}

test "SOF3 checks EOI and every byte of a truncated pair" {
	const allocator = std.testing.allocator;
	for (2..sof3_pair.len) |end| {
		var result = try jpegz.validateAny(allocator, sof3_pair[0..end]);
		defer result.deinit(allocator);
		try std.testing.expectEqual(jpegz.StrictVerdict.corrupt, result.verdict);
	}
	const surplus = sof3_pair[0..53].* ++ [_]u8{ 0x00, 0xff, 0xd9 };
	var result = try jpegz.validateAny(allocator, &surplus);
	defer result.deinit(allocator);
	try std.testing.expectEqual(jpegz.StrictVerdict.corrupt, result.verdict);
}

test "SOF3 preserves unused DQT and category16 controls" {
	const allocator = std.testing.allocator;
	const dqt = [_]u8{ 0xff, 0xdb, 0, 67, 0 } ++ ([_]u8{1} ** 64);
	const with_dqt = sof3_pair[0..2].* ++ dqt ++ sof3_pair[2..].*;
	var category16 = sof3_pair;
	category16[6] = 16;
	category16[39] = 16; // Two code0 symbols, no amplitude bits (H.1.2.2).
	var point_transform = sof3_pair;
	point_transform[51] = 1;
	for ([_][]const u8{ &with_dqt, &category16, &point_transform }) |data| {
		var result = try jpegz.validateAny(allocator, data);
		defer result.deinit(allocator);
		try std.testing.expectEqual(jpegz.StrictVerdict.valid, result.verdict);
	}
}

test "SOF3 keeps DNL unsupported and rejects reversed scan order" {
	const allocator = std.testing.allocator;
	var reversed = sof3_pair;
	reversed[45] = 2;
	reversed[47] = 1;
	var reversed_result = try jpegz.validateAny(allocator, &reversed);
	defer reversed_result.deinit(allocator);
	try std.testing.expectEqual(jpegz.StrictVerdict.corrupt, reversed_result.verdict);
	for ([_]u8{ 0, 1, 2 }) |height| {
		for ([_][]const u8{ &.{}, &.{0xff} }) |fill| {
			var prefix = sof3_pair[0..53].*;
			prefix[8] = height;
			const data = try std.mem.concat(allocator, u8, &.{ &prefix, fill, &.{ 0xff, 0xdc, 0, 4, 0, 1, 0xff, 0xd9 } });
			defer allocator.free(data);
			var result = try jpegz.validateAny(allocator, data);
			defer result.deinit(allocator);
			// Y=2 against NL=1 is two conflicting line counts: FAIL 72
			// (validate, 2026-11-21). Y=1 agrees: WARN 72, codec unsupported.
			const want: jpegz.StrictVerdict = if (height == 2) .corrupt else .unsupported;
			try std.testing.expectEqual(want, result.verdict);
			const misplaced = for (result.findings.items) |f| {
				if (f.code == .dnl_misplaced) break true;
			} else false;
			try std.testing.expectEqual(height != 0, misplaced);
		}
	}
}

test "SOF3 two-component sampling validates complete MCU groups and rejects boundary damage" {
	// T.81 A.2.3: each lossless data unit is one sample, including edge
	// padding. A one-bit code 0 represents difference zero (H.2).
	const cases = [_]struct {
		sampling: [2]u8,
		width: u8,
		height: u8 = 1,
		entropy: []const u8,
		restart: u8 = 0,
		valid: bool = true,
	}{
		.{ .sampling = .{ 0x11, 0x11 }, .width = 1, .entropy = &.{0x3f} },
		.{ .sampling = .{ 0x21, 0x21 }, .width = 2, .entropy = &.{0x0f} },
		.{ .sampling = .{ 0x21, 0x21 }, .width = 3, .entropy = &.{0x00} },
		.{ .sampling = .{ 0x21, 0x11 }, .width = 3, .entropy = &.{0x03} },
		.{ .sampling = .{ 0x22, 0x11 }, .width = 1, .entropy = &.{0x07} },
		.{ .sampling = .{ 0x21, 0x21 }, .width = 2, .height = 2, .restart = 1, .entropy = &.{ 0x0f, 0xff, 0xd0, 0x0f } },
		.{ .sampling = .{ 0x21, 0x21 }, .width = 2, .height = 2, .restart = 1, .entropy = &.{ 0x0f, 0xff, 0xff, 0xd0, 0x0f } },
		.{ .sampling = .{ 0x21, 0x21 }, .width = 2, .height = 10, .restart = 1, .entropy = &.{ 0x0f, 0xff, 0xd0, 0x0f, 0xff, 0xd1, 0x0f, 0xff, 0xd2, 0x0f, 0xff, 0xd3, 0x0f, 0xff, 0xd4, 0x0f, 0xff, 0xd5, 0x0f, 0xff, 0xd6, 0x0f, 0xff, 0xd7, 0x0f, 0xff, 0xd0, 0x0f } },
		.{ .sampling = .{ 0x21, 0x21 }, .width = 2, .entropy = &.{0x1f}, .valid = false }, // Missing sample.
		.{ .sampling = .{ 0x21, 0x21 }, .width = 2, .entropy = &.{0x07}, .valid = false }, // Extra sample.
		.{ .sampling = .{ 0x21, 0x21 }, .width = 2, .entropy = &.{0x0e}, .valid = false }, // Zero pad bit.
		.{ .sampling = .{ 0x21, 0x21 }, .width = 2, .entropy = &.{ 0x0f, 0x00 }, .valid = false },
		.{ .sampling = .{ 0x21, 0x21 }, .width = 2, .height = 2, .restart = 1, .entropy = &.{ 0x0f, 0xff, 0xd1, 0x0f }, .valid = false },
		.{ .sampling = .{ 0x21, 0x21 }, .width = 3, .restart = 1, .entropy = &.{0x00}, .valid = false }, // Ri not whole rows.
	};
	const allocator = std.testing.allocator;
	for (cases) |case| {
		const header = [_]u8{ 0xff, 0xd8, 0xff, 0xc3, 0, 14, 12, 0, case.height, 0, case.width, 2, 1, case.sampling[0], 0, 2, case.sampling[1], 0 } ++
			[_]u8{ 0xff, 0xc4, 0, 20, 0, 1 } ++ ([_]u8{0} ** 15) ++ [_]u8{0} ++
			[_]u8{ 0xff, 0xdd, 0, 4, 0, case.restart, 0xff, 0xda, 0, 10, 2, 1, 0, 2, 0, 1, 0, 0 };
		const data = try std.mem.concat(allocator, u8, &.{ &header, case.entropy, &.{ 0xff, 0xd9 } });
		defer allocator.free(data);
		var result = try jpegz.validateAny(allocator, data);
		defer result.deinit(allocator);
		try std.testing.expectEqual(if (case.valid) jpegz.StrictVerdict.valid else .corrupt, result.verdict);
		if (!case.valid) {
			var located_failure = false;
			for (result.findings.items) |finding| {
				if (finding.severity == .fail and finding.offset != null and finding.offset.? < data.len)
					located_failure = true;
			}
			try std.testing.expect(located_failure);
		}
	}
}

test "SOF3 accepts different legal amplitudes and reports trailing data separately" {
	const allocator = std.testing.allocator;
	var header = sof3_pair[0..52].*;
	header[6] = 8;
	header[39] = 7; // code0, seven amplitude bits: 128+127=255 or 128+126=254.
	for ([_]u8{ 0x7f, 0x7e }) |amplitude| {
		const data = header ++ [_]u8{ amplitude, amplitude, 0xff, 0xd9 };
		var result = try jpegz.validateAny(allocator, &data);
		defer result.deinit(allocator);
		try std.testing.expectEqual(jpegz.StrictVerdict.valid, result.verdict);
	}
	const trailing = sof3_pair ++ [_]u8{0};
	var result = try jpegz.validateAny(allocator, &trailing);
	defer result.deinit(allocator);
	try std.testing.expectEqual(jpegz.StrictVerdict.valid, result.verdict);
	var found = false;
	for (result.findings.items) |finding| {
		if (finding.code == .trailing_data_after_eoi) {
			try std.testing.expectEqual(@as(?u64, sof3_pair.len), finding.offset);
			found = true;
		}
	}
	try std.testing.expect(found);
}

test "SOF3 standalone markers cannot masquerade as unsupported length-prefixed segments" {
	const allocator = std.testing.allocator;
	const tail = [_]u8{0} ** 65536; // FFD9 must not be misread as a plausible length.
	for ([_]u8{ 0xd8, 0xd0, 0x01, 0x00 }) |marker| {
		for ([_]usize{ 2, 53 }) |insertion| {
			const data = try std.mem.concat(allocator, u8, &.{ sof3_pair[0..insertion], &.{ 0xff, marker }, sof3_pair[insertion..], &tail });
			defer allocator.free(data);
			var result = try jpegz.validateAny(allocator, data);
			defer result.deinit(allocator);
			try std.testing.expectEqual(jpegz.StrictVerdict.corrupt, result.verdict);
		}
	}
}

test "future JFIF version bytes classify coverage without asserting corruption" {
	const allocator = std.testing.allocator;
	const pristine = @embedFile("fixtures/baseline_2x2_rgb.jpg");
	for ([_]usize{ 11, 12 }) |field| {
		for (0..256) |value| {
			const data = try allocator.dupe(u8, pristine);
			defer allocator.free(data);
			data[field] = @intCast(value);
			const future = if (field == 11) value > 1 else value > 2;
			const ffmpeg = data[11] == 2 and data[12] == 1;
			var result = try jpegz.validateAny(allocator, data);
			defer result.deinit(allocator);
			var notices: usize = 0;
			for (result.findings.items) |finding| {
				if (finding.code != .jfif_version_unchecked) continue;
				notices += 1;
				// 02 01 is admitted known defect A2, tested on its own below.
				try std.testing.expectEqual(if (ffmpeg) jpegz.Severity.known_defect else .warn, finding.severity);
				try std.testing.expectEqual(@as(?u64, field), finding.offset);
				try std.testing.expectEqual(finding.offset, finding.host_offset);
				try std.testing.expect(finding.offset_is_exact);
			}
			if (future) {
				// validate, 2026-11-05: a WARN-class deviation, not inconclusive.
				try std.testing.expectEqual(if (ffmpeg) jpegz.StrictVerdict.known_defect else .valid, result.verdict);
				try std.testing.expectEqual(@as(usize, 1), notices);
			} else {
				try std.testing.expectEqual(@as(usize, 0), notices);
				// The older exclusions do not establish conformance.
				if (data[11] == 1 and (data[12] == 1 or data[12] == 2))
					try std.testing.expectEqual(jpegz.StrictVerdict.valid, result.verdict);
			}
		}
	}
	const pairs = [_][2]u8{ .{ 1, 2 }, .{ 1, 3 }, .{ 1, 255 }, .{ 2, 0 }, .{ 255, 255 } };
	for (pairs, 0..) |version, index| {
		const data = try allocator.dupe(u8, pristine);
		defer allocator.free(data);
		data[11] = version[0];
		data[12] = version[1];
		if (index != 0) data[13] = 255; // Future units semantics are not established.
		var result = try jpegz.validateAny(allocator, data);
		defer result.deinit(allocator);
		try std.testing.expectEqual(jpegz.StrictVerdict.valid, result.verdict);
		for (result.findings.items) |finding|
			try std.testing.expect(finding.code != .jfif_metadata_invalid);
	}
}

test "JFIF version bytes 02 01 are admitted known defect A2 only as an exact match" {
	const allocator = std.testing.allocator;
	const exemplar = @embedFile("fixtures/historic_a2_ffmpeg_jfif_0201.jpg");
	const pristine = @embedFile("fixtures/baseline_2x2_rgb.jpg");
	// The exemplar is the pristine fixture with only the version bytes changed.
	try std.testing.expectEqualSlices(u8, pristine[0..11], exemplar[0..11]);
	try std.testing.expectEqualSlices(u8, pristine[13..], exemplar[13..]);
	const Case = struct { name: []const u8, data: []u8, severity: ?jpegz.Severity, verdict: jpegz.StrictVerdict };
	var cases: std.ArrayList(Case) = .empty;
	defer {
		for (cases.items) |case| allocator.free(case.data);
		cases.deinit(allocator);
	}
	// Each near match changes one byte of the exemplar's APP0 (body at 6..20).
	const Patch = struct { name: []const u8, at: ?usize, value: u8 = 0, severity: ?jpegz.Severity, verdict: jpegz.StrictVerdict };
	const patches = [_]Patch{
		.{ .name = "exemplar", .at = null, .severity = .known_defect, .verdict = .known_defect },
		.{ .name = "units 2", .at = 13, .value = 2, .severity = .known_defect, .verdict = .known_defect },
		.{ .name = "version 02 00", .at = 12, .value = 0, .severity = .warn, .verdict = .valid },
		.{ .name = "version 02 02", .at = 12, .value = 2, .severity = .warn, .verdict = .valid },
		.{ .name = "version 03 01", .at = 11, .value = 3, .severity = .warn, .verdict = .valid },
		.{ .name = "version 01 01", .at = 11, .value = 1, .severity = null, .verdict = .valid },
		.{ .name = "units 3", .at = 13, .value = 3, .severity = .warn, .verdict = .valid },
		.{ .name = "Xdensity 0", .at = 15, .value = 0, .severity = .warn, .verdict = .valid },
		.{ .name = "Ydensity 0", .at = 17, .value = 0, .severity = .warn, .verdict = .valid },
		.{ .name = "JFXX identifier", .at = 9, .value = 'X', .severity = null, .verdict = .valid },
	};
	for (patches) |patch| {
		const data = try allocator.dupe(u8, exemplar);
		errdefer allocator.free(data);
		if (patch.at) |at| data[at] = patch.value;
		try cases.append(allocator, .{ .name = patch.name, .data = data, .severity = patch.severity, .verdict = patch.verdict });
	}
	// A 1x1 thumbnail that fills the segment exactly keeps the signature;
	// a missing thumbnail or two extra bytes do not.
	for ([_]usize{ 0, 3, 5 }) |extra| {
		var header = exemplar[2..20].*;
		header[3] = @intCast(16 + extra);
		header[16] = 1;
		header[17] = 1;
		const filler = [_]u8{0} ** 5;
		const data = try std.mem.concat(allocator, u8, &.{ exemplar[0..2], &header, filler[0..extra], exemplar[20..] });
		errdefer allocator.free(data);
		try cases.append(allocator, .{
			.name = switch (extra) { 0 => "thumbnail without data", 3 => "exact thumbnail", else => "thumbnail with extra bytes" },
			.data = data,
			.severity = if (extra == 3) .known_defect else .warn,
			.verdict = if (extra == 3) .known_defect else .valid,
		});
	}
	// An incomplete APP0 does not establish JFIF at all.
	{
		var header = exemplar[2..20].*;
		header[3] = 15;
		const data = try std.mem.concat(allocator, u8, &.{ exemplar[0..2], header[0..17], exemplar[20..] });
		errdefer allocator.free(data);
		try cases.append(allocator, .{ .name = "13-byte body", .data = data, .severity = null, .verdict = .valid });
	}
	for (cases.items) |case| {
		var result = try jpegz.validateAny(allocator, case.data);
		defer result.deinit(allocator);
		var seen: ?jpegz.Severity = null;
		for (result.findings.items) |finding| {
			if (finding.code != .jfif_version_unchecked) continue;
			try std.testing.expect(seen == null);
			seen = finding.severity;
			try std.testing.expectEqual(@as(?u64, if (case.data[11] == 1) 12 else 11), finding.offset);
			try std.testing.expect(finding.offset_is_exact);
			const named = std.mem.indexOf(u8, finding.detail.?, "FFmpeg/Libav") != null;
			try std.testing.expectEqual(finding.severity == .known_defect, named);
		}
		if (seen != case.severity or result.verdict != case.verdict) {
			std.debug.print("A2 case {s}: severity {?} verdict {s}\n", .{ case.name, seen, @tagName(result.verdict) });
			return error.TestUnexpectedResult;
		}
	}
}

