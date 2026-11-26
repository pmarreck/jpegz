//! validate tests, part 4 (split from validate.zig to keep files small).

const std = @import("std");
const jpegz = @import("jpegz");
const h1 = @import("validate_helpers_1.zig");
const h2 = @import("validate_helpers_2.zig");
const fixture_baseline_2x2_rgb = h1.fixture_baseline_2x2_rgb;
const fixture_progressive_8x8 = h1.fixture_progressive_8x8;
const fixture_lossless_4x4_gray8 = h1.fixture_lossless_4x4_gray8;
const fixture_arith_8x8_gray = h1.fixture_arith_8x8_gray;
const expectOnlyTypedFail = h1.expectOnlyTypedFail;
const expectExactTypedFailures = h1.expectExactTypedFailures;
const expectMixedPadFailures = h1.expectMixedPadFailures;
const expectOnlyTyped = h1.expectOnlyTyped;
const expectZeroPadWarnings = h1.expectZeroPadWarnings;
const fixture_baseline_4x4_bogus_dht = h1.fixture_baseline_4x4_bogus_dht;
const fixture_baseline_4x4_with_exif = h1.fixture_baseline_4x4_with_exif;
const fixture_baseline_4x4_with_trailing = h1.fixture_baseline_4x4_with_trailing;
const findMarker = h1.findMarker;
const reportHasCode = h1.reportHasCode;
const countCode = h1.countCode;
const expectDhtSymbolPastBound = h1.expectDhtSymbolPastBound;
const expectOneExact = h1.expectOneExact;
const decodeFindings = h1.decodeFindings;
const segmentEndMarker = h1.segmentEndMarker;
const entropyStart = h1.entropyStart;
const losslessHead = h1.losslessHead;
const patchU16BE = h1.patchU16BE;
const findSof0Body = h1.findSof0Body;
const fixture_jp2_rgb = h1.fixture_jp2_rgb;
const fixture_jp2_lossless = h1.fixture_jp2_lossless;
const fixture_jp2_lossy97 = h1.fixture_jp2_lossy97;
const fixture_jp2_subsampled = h1.fixture_jp2_subsampled;
const fixture_jp2_yuv420 = h1.fixture_jp2_yuv420;
const fixture_jp2_yuv420_matching_depth = h1.fixture_jp2_yuv420_matching_depth;
const jp2_specificity_corpus = h1.jp2_specificity_corpus;
const findSoc = h1.findSoc;
const fixture_seq_16x16_3scan = h1.fixture_seq_16x16_3scan;
const fixture_seq_17x13_420_y_cbcr_rst = h1.fixture_seq_17x13_420_y_cbcr_rst;
const fixture_seq_23x19_422_rev_rst = h1.fixture_seq_23x19_422_rev_rst;
const fixture_seq_23x19_rgb12_420_3scan = h1.fixture_seq_23x19_rgb12_420_3scan;
const sof1TableFixture = h1.sof1TableFixture;
const losslessWithTable = h1.losslessWithTable;
const withoutDht = h1.withoutDht;
const mpfFile = h2.mpfFile;
const TrailingSeen = h2.TrailingSeen;
const trailingFindings = h2.trailingFindings;
const DnlRewrite = h2.DnlRewrite;
const dnlVariant = h2.dnlVariant;
const dnl_fixtures = h2.dnl_fixtures;
const scanEnd = h2.scanEnd;
const firstSos = h2.firstSos;
const DnlPlacement = h2.DnlPlacement;
const withDnls = h2.withDnls;
const sofHeightOffset = h2.sofHeightOffset;

test "JFIF units checking requires a complete declared and available header" {
	const allocator = std.testing.allocator;
	const template = [_]u8{ 0xff, 0xd8, 0xff, 0xe0, 0, 16,
		'J', 'F', 'I', 'F', 0, 1, 2, 255, 0, 1, 0, 1, 0, 0 };
	for ([_]u8{ 1, 2 }) |minor| {
		const complete = try allocator.dupe(u8, &template);
		defer allocator.free(complete);
		complete[12] = minor;
		const body = complete[6..];
		for (0..body.len + 1) |length| {
			const header = [_]u8{ 0xff, 0xd8, 0xff, 0xe0, 0, @intCast(length + 2) };
			const data = try std.mem.concat(allocator, u8, &.{ &header, body[0..length], fixture_baseline_2x2_rgb[20..] });
			defer allocator.free(data);
			var report = try jpegz.validate(allocator, data);
			defer report.deinit(allocator);
			try std.testing.expectEqual(length == body.len, reportHasCode(report, .jfif_metadata_invalid));
		}
		for (0..complete.len) |length| {
			var report = try jpegz.validate(allocator, complete[0..length]);
			defer report.deinit(allocator);
			try std.testing.expect(!reportHasCode(report, .jfif_metadata_invalid));
		}
	}
}

test "JFIF units rejection is gated by the complete evidenced version set" {
	const allocator = std.testing.allocator;
	const body = findMarker(fixture_baseline_2x2_rgb, 0xe0).? + 4;
	for ([_]usize{ 5, 6 }) |field| {
		for (0..256) |version_byte| {
			const data = try allocator.dupe(u8, fixture_baseline_2x2_rgb);
			defer allocator.free(data);
			data[body + 5] = 1;
			data[body + 6] = 2;
			data[body + field] = @intCast(version_byte);
			data[body + 7] = 255;
			var report = try jpegz.validate(allocator, data);
			defer report.deinit(allocator);
			const evidenced = data[body + 5] == 1 and (data[body + 6] == 1 or data[body + 6] == 2);
			try std.testing.expectEqual(evidenced, reportHasCode(report, .jfif_metadata_invalid));
		}
	}
}

test "sequential SOF sampling nibbles classify the complete byte set" {
	// T.81 Table B.2: Hi and Vi each lie in 1..4. A one-component
	// scan is noninterleaved, so the interleaved MCU sum limit does not apply.
	const pristine = [_]u8{ 0xff, 0xd8, 0xff, 0xdb, 0, 67, 0 } ++ ([_]u8{1} ** 64) ++
		[_]u8{ 0xff, 0xc0, 0, 11, 8, 0, 8, 0, 8, 1, 1, 0x11, 0 } ++
		[_]u8{ 0xff, 0xc4, 0, 20, 0, 1 } ++ ([_]u8{0} ** 15) ++ [_]u8{0} ++
		[_]u8{ 0xff, 0xc4, 0, 20, 0x10, 1 } ++ ([_]u8{0} ** 15) ++ [_]u8{0} ++
		[_]u8{ 0xff, 0xda, 0, 8, 1, 1, 0, 0, 63, 0, 0x3f, 0xff, 0xd9 };
	const allocator = std.testing.allocator;
	for ([_]u8{ 0xc0, 0xc1 }) |sof| {
		for (0..256) |value| {
			const data = try allocator.dupe(u8, &pristine);
			defer allocator.free(data);
			const frame = findMarker(data, 0xc0).?;
			data[frame + 1] = sof;
			data[frame + 11] = @intCast(value);
			const h = value >> 4;
			const v = value & 15;
			const legal = h >= 1 and h <= 4 and v >= 1 and v <= 4;
			var result = try jpegz.validate(allocator, data);
			defer result.deinit(allocator);
			try std.testing.expectEqual(legal, result.isValid());
			if (!legal) {
				const failures = @as(usize, @intFromBool(h < 1 or h > 4)) + @intFromBool(v < 1 or v > 4);
				// One record per SOF (validate ruling 2026-11-22), with the count.
				try expectExactTypedFailures(result, .sof_sampling_invalid, frame + 11, 1);
				var buf: [48]u8 = undefined;
				const tail = try std.fmt.bufPrint(&buf, "; {d} invalid factor{s} in 1 component", .{ failures, if (failures == 1) "" else "s" });
				for (result.findings.items) |f| if (f.code == .sof_sampling_invalid) {
					try std.testing.expect(std.mem.endsWith(u8, f.detail.?, tail));
				};
			}
			if (legal) {
				var decoded = try jpegz.decode(allocator, data);
				defer decoded.deinit(allocator);
				var oracle = try jpegz.internal.wrapperDecode(allocator, data);
				defer oracle.deinit(allocator);
				try std.testing.expectEqualSlices(u8, oracle.pixels, decoded.pixels);
			}
		}
	}
}

test "sampling finding scope and complete component guards classify every frame count" {
	// Leak-checked like std.testing.allocator, without its 10-frame stack
	// capture per allocation: a frame of 255 bad components yields 510
	// findings, and across 2,048 validations the unwinding took about 3 s
	// of this test's 8 (perf, 2026-11-22).
	var leak_checked: std.heap.DebugAllocator(.{ .stack_trace_frames = 0 }) = .init;
	defer if (leak_checked.deinit() == .leak) @panic("sampling sweep leaked");
	const allocator = leak_checked.allocator();
	for ([_]u8{ 0xc0, 0xc1, 0xc2, 0xc3, 0xc9, 0xca, 0xcb, 0xf7 }) |marker| {
		for (0..256) |count| {
			const length = 8 + 3 * count;
			const data = try allocator.alloc(u8, 4 + length + 2);
			defer allocator.free(data);
			@memcpy(data[0..4], &[_]u8{ 0xff, 0xd8, 0xff, marker });
			std.mem.writeInt(u16, data[4..6], @intCast(length), .big);
			@memcpy(data[6..12], &[_]u8{ 8, 0, 8, 0, 8, @intCast(count) });
			for (0..count) |component| {
				@memcpy(data[12 + 3 * component ..][0..3], &[_]u8{ @intCast(component), 0xee, 0 });
			}
			@memcpy(data[data.len - 2 ..], &[_]u8{ 0xff, 0xd9 });
			var report = try jpegz.validate(allocator, data);
			defer report.deinit(allocator);
			// Table B.2 bounds every component of every T.81 frame; the
			// JPEG-LS frame (0xf7) stays with the T.87 validator.
			try std.testing.expectEqual(count >= 1 and marker != 0xf7,
				reportHasCode(report, .sof_sampling_invalid));
			// One record per SOF (validate ruling 2026-11-22), at the first
			// component's factor byte, with the counts.
			var records: usize = 0;
			for (report.findings.items) |f| if (f.code == .sof_sampling_invalid) {
				records += 1;
				if (count == 255) {
					try std.testing.expect(f.offset_is_exact and f.offset.? == 13);
					try std.testing.expectEqualStrings(
						"SOF component ID 0 Hi (high nibble)=14; allowed 1..4; 510 invalid factors in 255 components", f.detail.?);
				}
			};
			try std.testing.expectEqual(@as(usize, @intFromBool(count >= 1 and marker != 0xf7)), records);
		}
	}
	const complete = [_]u8{ 0xff, 0xd8, 0xff, 0xc0, 0, 11, 8, 0, 8, 0, 8, 1, 1, 0xee, 0 };
	for (0..12) |declared| {
		var header = complete;
		header[5] = @intCast(declared);
		var report = try jpegz.validate(allocator, &header);
		defer report.deinit(allocator);
		try std.testing.expectEqual(declared == 11, reportHasCode(report, .sof_sampling_invalid));
	}
	for (0..complete.len) |length| {
		var report = try jpegz.validate(allocator, complete[0..length]);
		defer report.deinit(allocator);
		try std.testing.expect(!reportHasCode(report, .sof_sampling_invalid));
	}
}

test "whole bytes after valid padding at the end of a scan have their own reason" {
	// Validate, 2026-11-05 (audit row 51b): libjpeg's "N extraneous bytes
	// before marker 0xd9" writer pattern must be told apart from invalid
	// entropy. Since 2026-11-22 (validate) whole bytes after valid padding are
	// FAIL 8, exact at the first of them; invalid entropy stays 51. One 8x8
	// gray block: DC code 0 then AC EOB 000, so 0x0f ends with four 1 pad bits.
	const header = [_]u8{ 0xff, 0xd8, 0xff, 0xdb, 0, 67, 0 } ++
		([_]u8{1} ** 64) ++
		[_]u8{ 0xff, 0xc0, 0, 11, 8, 0, 8, 0, 8, 1, 1, 0x11, 0 } ++
		[_]u8{ 0xff, 0xc4, 0, 20, 0, 1 } ++ ([_]u8{0} ** 15) ++ [_]u8{0} ++
		[_]u8{ 0xff, 0xc4, 0, 23, 0x10, 0, 0, 4 } ++ ([_]u8{0} ** 13) ++
		[_]u8{ 0, 0xf0, 0xe1, 0xf1 } ++
		[_]u8{ 0xff, 0xda, 0, 8, 1, 1, 0, 0, 63, 0 };
	const cases = [_]struct { entropy: []const u8, trailing: ?[]const u8 }{
		.{ .entropy = &.{ 0x0f, 0x00, 0x00 }, .trailing = "2 whole bytes after valid padding before marker 0xD9" },
		.{ .entropy = &.{ 0x0f, 0x12, 0x34, 0x56, 0x78, 0x9a }, .trailing = "5 whole bytes after valid padding before marker 0xD9" },
		.{ .entropy = &.{ 0x0f, 0xff, 0x00 }, .trailing = "1 whole byte after valid padding before marker 0xD9" }, // a stuffed FF is one byte
		.{ .entropy = &.{ 0x0e, 0x00 }, .trailing = null }, // pad bits 1110: invalid, not a trailer
		.{ .entropy = &.{ 0x0e, 0x00, 0x00, 0x00, 0x00, 0x00 }, .trailing = null },
	};
	const allocator = std.testing.allocator;
	for (cases) |case| {
		const data = try std.mem.concat(allocator, u8, &.{ &header, case.entropy, &.{ 0xff, 0xd9 } });
		defer allocator.free(data);
		var report = try jpegz.validate(allocator, data);
		defer report.deinit(allocator);
		try std.testing.expect(!report.isValid());
		var huffman: usize = 0;
		for (report.findings.items) |finding| {
			if (finding.severity != .fail) continue;
			if (case.trailing != null) {
				try std.testing.expectEqual(jpegz.FindingCode.extraneous_bytes_before_marker, finding.code);
				try std.testing.expect(finding.offset_is_exact);
				try std.testing.expectEqual(@as(?u64, header.len + 1), finding.offset);
			} else try std.testing.expectEqual(jpegz.FindingCode.huffman_table_corrupt, finding.code);
			huffman += 1;
			const expected = case.trailing orelse "invalid Huffman entropy or padding at end of scan";
			errdefer std.debug.print("expected {s}, got {s}\n", .{ expected, finding.detail.? });
			try std.testing.expectEqualStrings(expected, finding.detail.?);
		}
		try std.testing.expectEqual(@as(usize, 1), huffman);
	}
	// Control: the same stream without trailing bytes is clean.
	const clean = try std.mem.concat(allocator, u8, &.{ &header, &.{ 0x0f, 0xff, 0xd9 } });
	defer allocator.free(clean);
	var report = try jpegz.validate(allocator, clean);
	defer report.deinit(allocator);
	try std.testing.expect(report.isValid());
}

test "multi-component sampling factors and interleaved MCU size are typed" {
	// Validate, 2026-11-05: a bogus multi-component factor yielded only
	// "unsupported". T.81 Table B.2 bounds each Hi and Vi to 1..4, and B.2.3
	// bounds an interleaved scan (Ns > 1) to 10 data units per MCU, which
	// libjpeg enforces ("Sampling factors too large for interleaved scan").
	const allocator = std.testing.allocator;
	const Case = struct { y: u8, cb: u8 = 0x11, ns: u8 = 3, factor_faults: usize = 0, mcu_fault: bool = false };
	const cases = [_]Case{
		.{ .y = 0x22 }, // 4+1+1 = 6
		.{ .y = 0x42 }, // 8+1+1 = 10, the largest legal MCU
		.{ .y = 0x33, .mcu_fault = true }, // 9+1+1 = 11
		.{ .y = 0x44, .mcu_fault = true }, // 16+1+1 = 18
		.{ .y = 0x44, .ns = 1 }, // noninterleaved: no MCU limit
		.{ .y = 0x33, .ns = 2 }, // 9+1 = 10
		.{ .y = 0x22, .cb = 0x01, .factor_faults = 1 }, // Cb Hi = 0
		.{ .y = 0x22, .cb = 0x50, .factor_faults = 2 }, // Cb Hi = 5, Vi = 0
		.{ .y = 0x55, .factor_faults = 2 }, // out of range: no second MCU fault
	};
	for (cases) |case| {
		const frame = [_]u8{ 0xff, 0xc0, 0, 17, 8, 0, 16, 0, 16, 3, 1, case.y, 0, 2, case.cb, 0, 3, 0x11, 0 };
		const selectors = [_]u8{ 1, 0, 2, 0, 3, 0 };
		const sos = [_]u8{ 0xff, 0xda, 0, 6 + 2 * case.ns, case.ns };
		const data = try std.mem.concat(allocator, u8, &.{
			&.{ 0xff, 0xd8 }, &frame, &sos, selectors[0 .. 2 * @as(usize, case.ns)], &.{ 0, 63, 0, 0x3f, 0xff, 0xd9 },
		});
		defer allocator.free(data);
		var report = try jpegz.validate(allocator, data);
		defer report.deinit(allocator);
		const ns_offset: u64 = 2 + frame.len + 4;
		var factor_faults: usize = 0;
		var factor_records: usize = 0;
		var mcu_faults: usize = 0;
		for (report.findings.items) |finding| {
			if (finding.code != .sof_sampling_invalid) continue;
			try std.testing.expectEqual(jpegz.Severity.fail, finding.severity);
			try std.testing.expect(finding.offset_is_exact);
			if (finding.offset == ns_offset) {
				mcu_faults += 1;
				try std.testing.expect(std.mem.indexOf(u8, finding.detail.?, "at most 10") != null);
			} else {
				// One record per SOF, at the first invalid factor; its detail
				// counts every invalid factor (validate ruling 2026-11-22).
				factor_records += 1;
				try std.testing.expect(finding.offset.? == 2 + 11 or finding.offset.? == 2 + 14);
				const detail = finding.detail.?;
				const at = std.mem.indexOf(u8, detail, "; ").?;
				const rest = detail[std.mem.indexOfPos(u8, detail, at + 2, "; ").? + 2 ..];
				factor_faults = try std.fmt.parseInt(usize, rest[0..std.mem.indexOfScalar(u8, rest, ' ').?], 10);
				// Each faulty case damages exactly one component.
				try std.testing.expect(std.mem.endsWith(u8, detail, " in 1 component"));
			}
		}
		try std.testing.expectEqual(@as(usize, @intFromBool(case.factor_faults > 0)), factor_records);
		errdefer std.debug.print("case y=0x{x} cb=0x{x} ns={d}: factor {d} mcu {d}\n", .{ case.y, case.cb, case.ns, factor_faults, mcu_faults });
		try std.testing.expectEqual(case.factor_faults, factor_faults);
		try std.testing.expectEqual(@as(usize, @intFromBool(case.mcu_fault)), mcu_faults);
	}
}

test "sequential SOS fields classify every byte by the declared scan process" {
	// T.81 B.2.3/Table B.3: sequential DCT uses Ss=0, Se=63, Ah=Al=0.
	// Two one-bit zero codes encode DC zero and EOB, followed by six pad ones.
	const pristine = [_]u8{ 0xff, 0xd8, 0xff, 0xdb, 0, 67, 0 } ++ ([_]u8{1} ** 64) ++
		[_]u8{ 0xff, 0xc0, 0, 11, 8, 0, 8, 0, 8, 1, 1, 0x11, 0 } ++
		[_]u8{ 0xff, 0xc4, 0, 20, 0, 1 } ++ ([_]u8{0} ** 15) ++ [_]u8{0} ++
		[_]u8{ 0xff, 0xc4, 0, 20, 0x10, 1 } ++ ([_]u8{0} ** 15) ++ [_]u8{0} ++
		[_]u8{ 0xff, 0xda, 0, 8, 1, 1, 0, 0, 63, 0, 0x3f, 0xff, 0xd9 };
	const fields = [_]struct { offset: usize, legal: u8 }{
		.{ .offset = 7, .legal = 0 },
		.{ .offset = 8, .legal = 63 },
		.{ .offset = 9, .legal = 0 },
	};
	const allocator = std.testing.allocator;
	for ([_]u8{ 0xc0, 0xc1 }) |sof| {
		for (fields) |field| {
			for (0..256) |raw| {
				const data = try allocator.dupe(u8, &pristine);
				defer allocator.free(data);
				data[findMarker(data, 0xc0).? + 1] = sof;
				const offset = findMarker(data, 0xda).? + field.offset;
				data[offset] = @intCast(raw);
				var report = try jpegz.validate(allocator, data);
				defer report.deinit(allocator);
				if (raw == field.legal) {
					try std.testing.expect(report.isValid());
					try std.testing.expectEqual(.decoded, report.codec_check);
					var decoded = try jpegz.decode(allocator, data);
					defer decoded.deinit(allocator);
					var oracle = try jpegz.internal.wrapperDecode(allocator, data);
					defer oracle.deinit(allocator);
					try std.testing.expectEqualSlices(u8, oracle.pixels, decoded.pixels);
				} else if (field.offset == 8 and raw == 0) {
					// The only scan, covering every component: Go's known defect 68.
					try expectOnlyTyped(report, .known_defect, .sequential_scan_zero_se, offset);
					try std.testing.expectEqual(jpegz.Severity.known_defect, report.overall);
				} else {
					const expected: usize = if (field.offset == 9)
						@as(usize, @intFromBool(raw >> 4 != 0)) + @intFromBool(raw & 15 != 0)
					else 1;
					try expectExactTypedFailures(report, .sequential_scan_invalid, offset, expected);
				}
			}
		}
	}
	for ([_][]const u8{ fixture_progressive_8x8, fixture_lossless_4x4_gray8, fixture_arith_8x8_gray }) |data| {
		var report = try jpegz.validate(allocator, data);
		defer report.deinit(allocator);
		try std.testing.expect(report.isValid());
	}
}

test "validate: progressive_scan_invalid classifies bad spectral selection, silent on clean" {
    const allocator = std.testing.allocator;

    // Negative: every scan in the clean progressive fixture is well-formed.
    {
        var report = try jpegz.validate(allocator, fixture_progressive_8x8);
        defer report.deinit(allocator);
        try std.testing.expect(!reportHasCode(report, .progressive_scan_invalid));
    }

    // Positive: force the first SOS to Ss=0, Se=5 — a DC scan (Ss=0) must
    // have Se=0 (T.81 §G.1.1.1.1). SOS body: Ns, Ns×(Cs,Td/Ta), Ss, Se, AhAl.
    const buf = try allocator.dupe(u8, fixture_progressive_8x8);
    defer allocator.free(buf);
    const sos = findMarker(buf, 0xDA).?;
    const body = sos + 4;
    const ns = buf[body];
    const ss_off = body + 1 + 2 * @as(usize, ns);
    buf[ss_off] = 0;
    buf[ss_off + 1] = 5;

    var report = try jpegz.validate(allocator, buf);
    defer report.deinit(allocator);
    try std.testing.expect(reportHasCode(report, .progressive_scan_invalid));
}

test "validate: lossless_predictor_invalid classifies predictor outside 1..7" {
    const allocator = std.testing.allocator;

    {
        var report = try jpegz.validate(allocator, fixture_lossless_4x4_gray8);
        defer report.deinit(allocator);
        try std.testing.expect(!reportHasCode(report, .lossless_predictor_invalid));
    }

    // SOS Ss = predictor selector; valid 1..7 (T.81 §H.1). Try 0 and 8.
    const bad_pred = [_]u8{ 0, 8 };
    for (bad_pred) |p| {
        const buf = try allocator.dupe(u8, fixture_lossless_4x4_gray8);
        defer allocator.free(buf);
        const sos = findMarker(buf, 0xDA).?;
        const body = sos + 4;
        const ns = buf[body];
        const ss_off = body + 1 + 2 * @as(usize, ns);
        buf[ss_off] = p;

        var report = try jpegz.validate(allocator, buf);
        defer report.deinit(allocator);
        try std.testing.expect(reportHasCode(report, .lossless_predictor_invalid));
    }
}

test "validate: lossless_pointtransform_invalid classifies nonzero Ah in lossless scan" {
    const allocator = std.testing.allocator;

    {
        var report = try jpegz.validate(allocator, fixture_lossless_4x4_gray8);
        defer report.deinit(allocator);
        try std.testing.expect(!reportHasCode(report, .lossless_pointtransform_invalid));
    }

    // Lossless has no successive approximation: the AhAl byte must have
    // Ah=0 (it carries only the point transform Al). Set Ah=1.
    const buf = try allocator.dupe(u8, fixture_lossless_4x4_gray8);
    defer allocator.free(buf);
    const sos = findMarker(buf, 0xDA).?;
    const body = sos + 4;
    const ns = buf[body];
    const ahal_off = body + 1 + 2 * @as(usize, ns) + 2;
    buf[ahal_off] = 0x10; // Ah=1, Al=0

    var report = try jpegz.validate(allocator, buf);
    defer report.deinit(allocator);
    try std.testing.expect(reportHasCode(report, .lossless_pointtransform_invalid));
}

test "validate: arithmetic_table_corrupt classifies bad Tc/Tb in DAC, silent on clean" {
    const allocator = std.testing.allocator;

    // Negative: clean arithmetic fixture's DAC is well-formed.
    {
        var report = try jpegz.validate(allocator, fixture_arith_8x8_gray);
        defer report.deinit(allocator);
        try std.testing.expect(!reportHasCode(report, .arithmetic_table_corrupt));
    }

    // Positive: a DAC entry is (Tc/Tb, Cs). Tc (high nibble) must be 0 or 1;
    // Tb (low nibble) must be 0..3 (T.81 §B.2.4.3). Corrupt the first entry.
    const bad_tctb = [_]u8{ 0x20, 0x05 }; // Tc=2 ; Tb=5
    for (bad_tctb) |tctb| {
        const buf = try allocator.dupe(u8, fixture_arith_8x8_gray);
        defer allocator.free(buf);
        const dac = findMarker(buf, 0xCC).?;
        buf[dac + 4] = tctb; // FF CC Lhi Llo, then TcTb

        var report = try jpegz.validate(allocator, buf);
        defer report.deinit(allocator);
        try std.testing.expect(reportHasCode(report, .arithmetic_table_corrupt));
    }
}

