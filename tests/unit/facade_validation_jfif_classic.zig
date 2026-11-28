//! facade_validation tests, part 2 (split from facade_validation.zig to keep files small).

const std = @import("std");
const jpegz = @import("jpegz");
const h1 = @import("facade_validation_helpers.zig");
const sof3_pair = h1.sof3_pair;
const hierarchicalStream = h1.hierarchicalStream;

test "future JFIF notices require the recognized complete header" {
	const allocator = std.testing.allocator;
	const pristine = @embedFile("fixtures/baseline_2x2_rgb.jpg");
	for (0..5) |field| {
		const data = try allocator.dupe(u8, pristine);
		defer allocator.free(data);
		data[6 + field] ^= 0xff;
		data[11] = 2;
		var result = try jpegz.validateAny(allocator, data);
		defer result.deinit(allocator);
		try std.testing.expectEqual(jpegz.StrictVerdict.valid, result.verdict);
		for (result.findings.items) |finding|
			try std.testing.expect(finding.code != .jfif_version_unchecked);
	}
	const body = [_]u8{ 'J', 'F', 'I', 'F', 0, 2, 0, 255, 0, 1, 0, 1, 0, 0 };
	for (0..body.len + 1) |length| {
		const header = [_]u8{ 0xff, 0xd8, 0xff, 0xe0, 0, @intCast(length + 2) };
		const data = try std.mem.concat(allocator, u8, &.{ &header, body[0..length], pristine[20..] });
		defer allocator.free(data);
		var result = try jpegz.validateAny(allocator, data);
		defer result.deinit(allocator);
		var notices: usize = 0;
		for (result.findings.items) |finding| {
			if (finding.code == .jfif_version_unchecked) notices += 1;
		}
		try std.testing.expectEqual(@as(usize, @intFromBool(length == body.len)), notices);
	}
	const complete = [_]u8{ 0xff, 0xd8, 0xff, 0xe0, 0, 16 } ++ body;
	for (0..complete.len) |length| {
		var result = try jpegz.validateAny(allocator, complete[0..length]);
		defer result.deinit(allocator);
		for (result.findings.items) |finding|
			try std.testing.expect(finding.code != .jfif_version_unchecked);
	}
}

test "future JFIF preserves known padding and independently corrupt metadata in either order" {
	const allocator = std.testing.allocator;
	const padded = @embedFile("fixtures/zero_pad_16x16_420.jpg");
	var future_padding = padded.*;
	future_padding[11] = 2;
	var padding = try jpegz.validateAny(allocator, &future_padding);
	defer padding.deinit(allocator);
	try std.testing.expectEqual(jpegz.StrictVerdict.known_defect, padding.verdict);
	var causes: u8 = 0;
	for (padding.findings.items) |finding| {
		if (finding.code == .jfif_version_unchecked) causes |= 1;
		if (finding.code == .entropy_padding_zero_bits) causes |= 2;
		try std.testing.expect(finding.severity != .fail);
	}
	try std.testing.expectEqual(@as(u8, 3), causes);

	const pristine = @embedFile("fixtures/baseline_2x2_rgb.jpg");
	// A second, known-version APP0 has a separately proven invalid units byte.
	// Swapping the two APP0 segments reverses the actual finding order.
	const invalid_units = [_]u8{ 0xff, 0xe0, 0, 16, 'J', 'F', 'I', 'F', 0, 1, 2, 255, 0, 1, 0, 1, 0, 0 };
	var future_header = pristine[2..20].*;
	future_header[9] = 2;
	for ([_]bool{ false, true }) |reverse| {
		const first: []const u8 = if (reverse) &invalid_units else &future_header;
		const second: []const u8 = if (reverse) &future_header else &invalid_units;
		const data = try std.mem.concat(allocator, u8, &.{ pristine[0..2], first, second, pristine[20..] });
		defer allocator.free(data);
		var result = try jpegz.validateAny(allocator, data);
		defer result.deinit(allocator);
		try std.testing.expectEqual(jpegz.StrictVerdict.corrupt, result.verdict);
		var ordered: [2]jpegz.FindingCode = undefined;
		var count: usize = 0;
		for (result.findings.items) |finding| {
			if (finding.code != .jfif_version_unchecked and finding.code != .jfif_metadata_invalid) continue;
			try std.testing.expect(count < ordered.len);
			ordered[count] = finding.code.?;
			count += 1;
		}
		try std.testing.expectEqual(@as(usize, 2), count);
		try std.testing.expectEqual(if (reverse) jpegz.FindingCode.jfif_metadata_invalid else .jfif_version_unchecked, ordered[0]);
		try std.testing.expectEqual(if (reverse) jpegz.FindingCode.jfif_version_unchecked else .jfif_metadata_invalid, ordered[1]);
	}
}

test "classic strict findings retain bounded positions and declared segment extents" {
	const allocator = std.testing.allocator;
	const pristine = @embedFile("fixtures/baseline_2x2_rgb.jpg");
	for ([_]usize{ 4, 5 }) |field| {
		for (0..256) |value| {
			const data = try allocator.dupe(u8, pristine);
			defer allocator.free(data);
			data[field] = @intCast(value);
			const declared_end = 4 + @as(u64, data[4]) * 256 + data[5];
			var result = try jpegz.validateAny(allocator, data);
			defer result.deinit(allocator);
			var extended = false;
			for (result.findings.items) |finding| {
				if (finding.offset) |offset| {
					try std.testing.expect(offset <= data.len);
					try std.testing.expectEqual(finding.offset, finding.host_offset);
					if (offset == data.len) try std.testing.expect(!finding.offset_is_exact);
				} else {
					try std.testing.expectEqual(@as(?u64, null), finding.host_offset);
					try std.testing.expect(!finding.offset_is_exact);
				}
				if (declared_end > data.len and finding.code == .truncated_stream) {
					extended = true;
					try std.testing.expectEqual(@as(?u64, null), finding.offset);
					var position: [32]u8 = undefined;
					const expected = try std.fmt.bufPrint(&position, "{d}", .{declared_end});
					try std.testing.expect(std.mem.indexOf(u8, finding.detail.?, expected) != null);
				}
			}
			if (declared_end > data.len) {
				try std.testing.expectEqual(jpegz.StrictVerdict.corrupt, result.verdict);
				try std.testing.expect(extended);
			}
		}
	}

	// A real EOF cursor remains available without becoming an exact byte.
	const eof = pristine[0 .. pristine.len - 1];
	var terminal = try jpegz.validateAny(allocator, eof);
	defer terminal.deinit(allocator);
	var found_eof = false;
	for (terminal.findings.items) |finding| {
		if (finding.code == .truncated_stream and finding.offset == eof.len) {
			found_eof = true;
			try std.testing.expectEqual(finding.offset, finding.host_offset);
			try std.testing.expect(!finding.offset_is_exact);
		}
	}
	try std.testing.expect(found_eof);
}

test "reserved JPEG markers are FAIL class and still let the codec check run" {
	// validate, 2026-11-05: FF02..FFBF have no specified decode, damage produces
	// them and no writer is known. Detection is unchanged: the codec still runs.
	const allocator = std.testing.allocator;
	const pristine = @embedFile("fixtures/baseline_2x2_rgb.jpg");
	try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xe0 }, pristine[2..4]);
	for (2..0xc0) |marker| {
		const data = try allocator.dupe(u8, pristine);
		defer allocator.free(data);
		data[3] = @intCast(marker);
		var result = try jpegz.validateAny(allocator, data);
		defer result.deinit(allocator);
		try std.testing.expectEqual(jpegz.StrictVerdict.corrupt, result.verdict);
		var notices: usize = 0;
		for (result.findings.items) |finding| {
			if (finding.code != .unknown_marker) continue;
			notices += 1;
			try std.testing.expectEqual(jpegz.Severity.fail, finding.severity);
			try std.testing.expectEqual(@as(?u64, 3), finding.offset);
			try std.testing.expectEqual(finding.offset, finding.host_offset);
			try std.testing.expect(finding.offset_is_exact);
		}
		try std.testing.expectEqual(@as(usize, 1), notices);
	}
	// T.81 application/comment payloads remain opaque, with assigned markers.
	for ([_]u8{ 0xe0, 0xe1, 0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7,
		0xe8, 0xe9, 0xea, 0xeb, 0xec, 0xed, 0xee, 0xef, 0xfe }) |marker|
	{
		const data = try allocator.dupe(u8, pristine);
		defer allocator.free(data);
		data[3] = marker;
		var result = try jpegz.validateAny(allocator, data);
		defer result.deinit(allocator);
		try std.testing.expectEqual(jpegz.StrictVerdict.valid, result.verdict);
	}
	const padded = @embedFile("fixtures/zero_pad_16x16_420.jpg");
	for ([_]bool{ false, true }) |truncate| {
		const data = try allocator.dupe(u8, if (truncate) padded[0 .. padded.len - 2] else padded);
		defer allocator.free(data);
		data[3] = 0x1f;
		var result = try jpegz.validateAny(allocator, data);
		defer result.deinit(allocator);
		try std.testing.expectEqual(jpegz.StrictVerdict.corrupt, result.verdict);
		if (!truncate) {
			var known_cause = false;
			for (result.findings.items) |finding| {
				if (finding.code == .entropy_padding_zero_bits) known_cause = true;
			}
			try std.testing.expect(known_cause);
		}
	}
}

test "a repeated SOF is FAIL class except in a hierarchical stream" {
	const allocator = std.testing.allocator;
	// validate, 2026-11-05: libjpeg refuses two SOF markers and damage produces
	// them, so a second frame outside hierarchical mode is FAIL at its marker.
	const pristine = @embedFile("fixtures/baseline_2x2_rgb.jpg");
	const header = try jpegz.frameHeader(pristine);
	const sof_len = (@as(usize, pristine[header.sof_offset + 2]) << 8) | pristine[header.sof_offset + 3];
	const sof = pristine[header.sof_offset .. header.sof_offset + 2 + sof_len];
	const sos = std.mem.indexOf(u8, pristine, &.{ 0xff, 0xda }) orelse return error.MissingSos;
	const repeated = try std.mem.concat(allocator, u8, &.{ pristine[0..sos], sof, pristine[sos..] });
	defer allocator.free(repeated);
	var result = try jpegz.validateAny(allocator, repeated);
	defer result.deinit(allocator);
	try std.testing.expectEqual(jpegz.StrictVerdict.corrupt, result.verdict);
	var repeats: usize = 0;
	for (result.findings.items) |finding| {
		if (finding.code != .duplicate_sof) continue;
		repeats += 1;
		try std.testing.expectEqual(jpegz.Severity.fail, finding.severity);
		try std.testing.expectEqual(@as(?u64, sos), finding.offset);
	}
	try std.testing.expectEqual(@as(usize, 1), repeats);

	// The legal hierarchical stream stays clean: no WARN or FAIL finding. Its
	// codec is not checked, so the verdict is unsupported, never valid.
	const legal = comptime hierarchicalStream(true, false);
	try std.testing.expect((try jpegz.frameHeader(legal)).dhp_offset != null);
	var clean = try jpegz.validateAny(allocator, legal);
	defer clean.deinit(allocator);
	try std.testing.expectEqual(jpegz.StrictVerdict.unsupported, clean.verdict);
	for (clean.findings.items) |finding| {
		errdefer std.debug.print("unexpected {s} {s}\n", .{ @tagName(finding.severity), @tagName(finding.code.?) });
		try std.testing.expect(finding.severity != .warn and finding.severity != .fail);
	}

	// Controls: without a DHP before the first frame the same frames repeat.
	for ([_][]const u8{ comptime hierarchicalStream(false, false), comptime hierarchicalStream(true, true) }) |stream| {
		var flagged = try jpegz.validateAny(allocator, stream);
		defer flagged.deinit(allocator);
		try std.testing.expectEqual(jpegz.StrictVerdict.corrupt, flagged.verdict);
		var found = false;
		for (flagged.findings.items) |finding| {
			if (finding.code == .duplicate_sof and finding.severity == .fail) found = true;
		}
		try std.testing.expect(found);
	}
}

test "zero marker byte outside entropy is malformed rather than opaque APP data" {
	const allocator = std.testing.allocator;
	const pristine = @embedFile("fixtures/baseline_2x2_rgb.jpg");
	const data = try allocator.dupe(u8, pristine);
	defer allocator.free(data);
	data[3] = 0;
	var result = try jpegz.validateAny(allocator, data);
	defer result.deinit(allocator);
	try std.testing.expectEqual(jpegz.StrictVerdict.corrupt, result.verdict);
	var failures: usize = 0;
	for (result.findings.items) |finding| {
		if (finding.severity != .fail) continue;
		failures += 1;
		try std.testing.expectEqual(jpegz.FindingCode.unknown_marker, finding.code.?);
		try std.testing.expectEqual(@as(?u64, 3), finding.offset);
		try std.testing.expectEqual(finding.offset, finding.host_offset);
		try std.testing.expect(finding.offset_is_exact);
	}
	try std.testing.expectEqual(@as(usize, 1), failures);
}

test "JP2 mapping recognizes only declared JP2 findings" {
	for (0..512) |value| {
		const raw: u32 = @intCast(value);
		const declared = switch (raw) {
			1...5, 140...146, 207, 208, 250...261 => true,
			else => false,
		};
		for (std.meta.tags(jpegz.Severity)) |severity| {
			for ([_]bool{ false, true }) |container_ok| {
				const mapped = jpegz.facade.mapJp2Finding(raw, severity, container_ok);
				try std.testing.expectEqual(declared, mapped.code != null);
				if (!declared) {
					try std.testing.expectEqual(jpegz.StrictVerdict.indeterminate, mapped.verdict);
					try std.testing.expectEqual(jpegz.Severity.warn, mapped.severity);
				}
			}
		}
	}
}

test "JP2 dependency findings retain wire identities and severities" {
	const cases = [_]struct { raw: u32, name: []const u8, severity: jpegz.Severity, verdict: jpegz.StrictVerdict }{
		.{ .raw = 255, .name = "zero_bitplane_overflow", .severity = .fail, .verdict = .corrupt },
		.{ .raw = 256, .name = "packed_headers_mismatch", .severity = .fail, .verdict = .corrupt },
		.{ .raw = 257, .name = "jp2_trailing_bytes", .severity = .fail, .verdict = .corrupt },
		.{ .raw = 258, .name = "segmentation_symbol_mismatch", .severity = .fail, .verdict = .corrupt },
		.{ .raw = 259, .name = "profile_violation", .severity = .fail, .verdict = .corrupt },
		// E.2's encoder formula is informative, not a normative constraint.
		.{ .raw = 260, .name = "reversible_exponent_mismatch", .severity = .warn, .verdict = .valid },
		// No-PTERM under-read is a heuristic warning; proven termination
		// violations retain the leaf's FAIL rather than sharing one treatment.
		.{ .raw = 252, .name = "entropy_under_read", .severity = .warn, .verdict = .valid },
		.{ .raw = 252, .name = "entropy_under_read", .severity = .fail, .verdict = .corrupt },
		// The contribution ending is proven invalid even with WARN treatment.
		.{ .raw = 261, .name = "cblk_contribution_ends_ff", .severity = .fail, .verdict = .corrupt },
		.{ .raw = 261, .name = "cblk_contribution_ends_ff", .severity = .warn, .verdict = .corrupt },
	};
	for (cases) |case| {
		const mapped = jpegz.facade.mapJp2Finding(case.raw, case.severity, true);
		try std.testing.expectEqual(case.verdict, mapped.verdict);
		try std.testing.expectEqual(case.severity, mapped.severity);
		const code = mapped.code orelse return error.MissingJp2Finding;
		try std.testing.expectEqual(case.raw, @intFromEnum(code));
		try std.testing.expectEqualStrings(case.name, @tagName(code));
	}
	for (std.meta.tags(jpegz.Severity)) |severity| {
		const proven = jpegz.facade.mapJp2Finding(261, severity, true);
		try std.testing.expectEqual(jpegz.StrictVerdict.corrupt, proven.verdict);
		try std.testing.expectEqual(severity, proven.severity);
		const conditional = jpegz.facade.mapJp2Finding(252, severity, true);
		try std.testing.expectEqual(if (severity == .fail) jpegz.StrictVerdict.corrupt else .valid, conditional.verdict);
		try std.testing.expectEqual(severity, conditional.severity);
	}
	for ([_]u32{ 262, 299, 999 }) |raw| {
		const mapped = jpegz.facade.mapJp2Finding(raw, .fail, true);
		try std.testing.expectEqual(jpegz.StrictVerdict.indeterminate, mapped.verdict);
		try std.testing.expectEqual(@as(?jpegz.FindingCode, null), mapped.code);
	}
}

test "classic facade requires EOI even after a complete progressive scan" {
	const allocator = std.testing.allocator;
	const progressive = @embedFile("fixtures/progressive_8x8_rgb.jpg");
	const baseline = @embedFile("fixtures/baseline_2x2_rgb.jpg");
	const lossless = @embedFile("fixtures/lossless_4x4_gray8.jpg");
	// corruption-probe seed0x1234, truncation round46: 520 bytes cut to441.
	// The next SOS starts at441. Earlier completed scans plus EOI remain legal.
	try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xda }, progressive[441..443]);
	const early_complete = progressive[0..441].* ++ [_]u8{ 0xff, 0xd9 };
	const embedded_eoi = progressive[0..441].* ++ [_]u8{ 0xff, 0xfe, 0, 4, 0xff, 0xd9 };
	const dangling_ff = progressive[0..441].* ++ [_]u8{0xff};
	const cases = [_]struct { bytes: []const u8, valid: bool }{
		.{ .bytes = progressive, .valid = true },
		.{ .bytes = baseline, .valid = true },
		.{ .bytes = lossless, .valid = true },
		.{ .bytes = &early_complete, .valid = true },
		.{ .bytes = progressive[0..441], .valid = false },
		.{ .bytes = progressive[0 .. progressive.len - 2], .valid = false },
		.{ .bytes = baseline[0 .. baseline.len - 2], .valid = false },
		.{ .bytes = lossless[0 .. lossless.len - 2], .valid = false },
		.{ .bytes = &embedded_eoi, .valid = false },
		.{ .bytes = &dangling_ff, .valid = false },
	};
	for (cases) |case| {
		var result = try jpegz.validateAny(allocator, case.bytes);
		defer result.deinit(allocator);
		if (result.verdict != (if (case.valid) jpegz.StrictVerdict.valid else .corrupt)) {
			std.debug.print("EOI case len{d} valid{} got{s}\n", .{ case.bytes.len, case.valid, @tagName(result.verdict) });
		}
		try std.testing.expectEqual(if (case.valid) jpegz.StrictVerdict.valid else .corrupt, result.verdict);
	}
	// A missing EOI is FAIL class (owner 2026-11-06: severity never rests on
	// readers decoding the pixels anyway). It does not block the codec check,
	// so the decoder still reports whatever else it finds. (The other cut
	// streams above end inside entropy data, an earlier blocking FAIL.)
	for ([_][]const u8{progressive[0..441]}) |truncated| {
		var legacy = try jpegz.validate(allocator, truncated);
		defer legacy.deinit(allocator);
		try std.testing.expect(!legacy.isValid());
		try std.testing.expectEqual(.decoded, legacy.codec_check);
		var strict = try jpegz.validateAny(allocator, truncated);
		defer strict.deinit(allocator);
		var found: usize = 0;
		for (strict.findings.items) |finding| {
			if (finding.code != .missing_eoi) continue;
			found += 1;
			try std.testing.expectEqual(jpegz.Severity.fail, finding.severity);
			try std.testing.expectEqual(@as(?u64, truncated.len), finding.offset);
		}
		try std.testing.expectEqual(@as(usize, 1), found);
	}
}

test "classic facade distinguishes unchecked and unsupported codecs from validity" {
	const allocator = std.testing.allocator;
	const cases = [_]struct { sof: u8, sampling: u8 = 0x11, width: u8 = 1, dhp: bool = false, verdict: jpegz.StrictVerdict }{
		.{ .sof = 0xc3, .verdict = .valid },
		.{ .sof = 0xc3, .sampling = 0x21, .verdict = .valid },
		.{ .sof = 0xc3, .sampling = 0x44, .verdict = .valid },
		.{ .sof = 0xc3, .sampling = 0x21, .width = 0, .verdict = .corrupt },
		// Without a DHP a differential frame is FAIL 73 (validate, 2026-11-21).
		.{ .sof = 0xc7, .verdict = .corrupt },
		// After a DHP the stream is hierarchical, whose codec is not checked.
		.{ .sof = 0xc7, .dhp = true, .verdict = .unsupported },
		.{ .sof = 0xc7, .dhp = true, .width = 0, .verdict = .corrupt },
	};
	for (cases) |case| {
		// Minimal lossless marker chain, DC code 0 => difference zero.
		// Differential SOF7 after a DHP exercises a skipped codec, not a claim
		// that this synthetic chain proves a complete, valid hierarchical JPEG.
		const dhp = [_]u8{ 0xff, 0xde, 0, 11, 8, 0, 1, 0, 1, 1, 1, 0x11, 0 };
		const data = try std.mem.concat(allocator, u8, &.{
			&.{ 0xff, 0xd8 },
			if (case.dhp) &dhp else &.{},
			&.{ 0xff, case.sof, 0, 11, 8, 0, 1, 0, case.width, 1, 1, case.sampling, 0 },
			&([_]u8{ 0xff, 0xc4, 0, 20, 0, 1 } ++ ([_]u8{0} ** 15) ++ [_]u8{0}),
			&.{ 0xff, 0xda, 0, 8, 1, 1, 0, 1, 0, 0, 0x7f, 0xff, 0xd9 },
		});
		defer allocator.free(data);
		var legacy = try jpegz.validate(allocator, data);
		defer legacy.deinit(allocator);
		try std.testing.expectEqual(case.verdict != .corrupt, legacy.isValid());
		var strict = try jpegz.validateAny(allocator, data);
		defer strict.deinit(allocator);
		try std.testing.expectEqual(case.verdict, strict.verdict);
	}
	const jls = @embedFile("fixtures/jpegls_4x4_gray8.jls");
	var malformed_jls = jls.*;
	const sof = std.mem.indexOf(u8, jls, &.{ 0xff, 0xf7 }) orelse return error.MissingFixtureSof;
	@memset(malformed_jls[sof + 7 .. sof + 9], 0); // Zero width; retain SOF55 identification.
	const skipped = [_]struct { data: []const u8, verdict: jpegz.StrictVerdict }{
		// The Zig JPEG-LS decoder now checks the codec (validate, 2026-11-21).
		.{ .data = jls, .verdict = .valid },
		.{ .data = &malformed_jls, .verdict = .corrupt },
	};
	for (skipped) |case| {
		var legacy = try jpegz.validate(allocator, case.data);
		defer legacy.deinit(allocator);
		try std.testing.expectEqual(jpegz.Variant.jpegls, legacy.variant);
		try std.testing.expectEqual(case.verdict != .corrupt, legacy.isValid());
		var strict = try jpegz.validateAny(allocator, case.data);
		defer strict.deinit(allocator);
		try std.testing.expectEqual(case.verdict, strict.verdict);
	}
}

test "classic facade rejects recovered entropy damage but accepts legal fill" {
	const allocator = std.testing.allocator;
	const baseline = @embedFile("fixtures/baseline_2x2_rgb.jpg");
	const restart = @embedFile("fixtures/baseline_128x128_dri4.jpg");
	const progressive = @embedFile("fixtures/progressive_16x16_rgb12_444.jpg");
	const progressive_truncated = progressive[0 .. progressive.len - 18].* ++ [_]u8{ 0xff, 0xd9 };
	const legal_fill = baseline[0..2].* ++ [_]u8{ 0xff, 0xff } ++ baseline[2..].*;
	// Keep EOI intact: only the codec check can detect the missing entropy.
	const truncated = baseline[0 .. baseline.len - 26].* ++ [_]u8{ 0xff, 0xd9 };
	var wrong_restart = restart.*;
	var missing_restart = restart.*;
	try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xd0 }, restart[652..654]);
	wrong_restart[653] = 0xd5;
	@memcpy(missing_restart[652..654], &[_]u8{ 0xaa, 0xbb });
	// validate, 2026-11-05: recovered damage is FAIL class and legal fill is an
	// INFO observation; the decoders report the same findings as before.
	const cases = [_]struct {
		bytes: []const u8,
		verdict: jpegz.StrictVerdict,
		finding: ?jpegz.FindingCode = null,
		severity: jpegz.Severity = .fail,
	}{
		.{ .bytes = baseline, .verdict = .valid },
		.{ .bytes = restart, .verdict = .valid },
		.{ .bytes = @embedFile("fixtures/progressive_8x8_rgb.jpg"), .verdict = .valid },
		.{ .bytes = @embedFile("fixtures/lossless_4x4_gray8.jpg"), .verdict = .valid },
		.{ .bytes = @embedFile("fixtures/arith_baseline_8x8_gray.jpg"), .verdict = .valid },
		.{ .bytes = &legal_fill, .verdict = .valid, .finding = .entropy_fill_bytes, .severity = .info },
		.{ .bytes = &truncated, .verdict = .corrupt, .finding = .insufficient_data },
		.{ .bytes = progressive, .verdict = .valid },
		.{ .bytes = &progressive_truncated, .verdict = .corrupt, .finding = .insufficient_data },
		.{ .bytes = &wrong_restart, .verdict = .corrupt, .finding = .restart_marker_unexpected },
		// The RST is replaced by junk: whole bytes before the next RSTm (FAIL 8).
		.{ .bytes = &missing_restart, .verdict = .corrupt, .finding = .extraneous_bytes_before_marker },
	};
	for (cases) |case| {
		var legacy = try jpegz.validate(allocator, case.bytes);
		defer legacy.deinit(allocator);
		var strict = try jpegz.validateAny(allocator, case.bytes);
		defer strict.deinit(allocator);
		if (case.finding) |code| {
			var found = false;
			for (strict.findings.items) |finding| {
				if (finding.code == code and finding.severity == case.severity) found = true;
			}
			try std.testing.expect(found);
			// The legacy report carries the same class.
			try std.testing.expectEqual(case.severity != .fail, legacy.isValid());
		}
		try std.testing.expectEqual(case.verdict, strict.verdict);
	}
}

