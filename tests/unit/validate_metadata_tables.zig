//! validate tests, part 3 (split from validate.zig to keep files small).

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

test "validate surfaces EXIF presence (APP1 'Exif\\0\\0') as INFO" {
    const allocator = std.testing.allocator;
    var report = try jpegz.validate(allocator, fixture_baseline_4x4_with_exif);
    defer report.deinit(allocator);

    try std.testing.expect(report.isValid());
    var found_jfif = false;
    var found_exif = false;
    for (report.findings.items) |f| {
        if (f.code == .jfif_metadata_present) found_jfif = true;
        if (f.code == .exif_metadata_present) found_exif = true;
    }
    try std.testing.expect(found_jfif);
    try std.testing.expect(found_exif);
}

test "validate surfaces trailing-data-after-EOI as WARN other" {
    const allocator = std.testing.allocator;
    var report = try jpegz.validate(allocator, fixture_baseline_4x4_with_trailing);
    defer report.deinit(allocator);

    // A trailer that is neither MPF nor PAR2 is a writer's violation: WARN
    // (owner ruling 2026-11-06), still a valid verdict.
    try std.testing.expect(report.isValid());
    try std.testing.expectEqual(jpegz.Severity.warn, report.overall);
    var found = false;
    var offset_seen: ?u64 = null;
    for (report.findings.items) |f| {
        if (f.code == .trailing_data_after_eoi) {
            found = true;
            offset_seen = f.offset;
        }
    }
    try std.testing.expect(found);
    // Offset should point at the byte immediately after EOI.
    try std.testing.expect(offset_seen != null);
}

test "validate reports libjpeg-style insufficient_data recovery as FAIL class" {
    // The decoder still tolerates the truncation libjpeg-turbo would WARNMS
    // about, but under validate's 2026-11-05 rule recovered damage is FAIL
    // class: readers fill the missing blocks gray and hide the loss.
    //
    // Setup: take a clean baseline JPEG, truncate bytes from the END
    // of its entropy stream, then re-attach the FFD9 EOI marker.
    // libjpeg sees a structurally-complete file (jpeg_read_header
    // succeeds), but `jpeg_read_scanlines` hits the EOI marker before
    // every block is decoded → emits JWRN_HIT_MARKER. The validator
    // surface should map that into Finding(.warn, .insufficient_data).
    const allocator = std.testing.allocator;
    const full = fixture_baseline_2x2_rgb;
    // Sanity: existing fixture ends with the EOI marker.
    try std.testing.expectEqual(@as(u8, 0xFF), full[full.len - 2]);
    try std.testing.expectEqual(@as(u8, 0xD9), full[full.len - 1]);

    // Strip the last 24 bytes of entropy (well inside the scan), then
    // re-attach the 2-byte EOI so the structural walker is satisfied.
    const cut: usize = 24;
    var corrupted = try allocator.alloc(u8, full.len - cut);
    defer allocator.free(corrupted);
    @memcpy(corrupted[0 .. full.len - cut - 2], full[0 .. full.len - cut - 2]);
    corrupted[full.len - cut - 2] = 0xFF;
    corrupted[full.len - cut - 1] = 0xD9;

    var report = try jpegz.validate(allocator, corrupted);
    defer report.deinit(allocator);

    var found = false;
    for (report.findings.items) |f| {
        if (f.severity == .fail and f.code == .insufficient_data) found = true;
    }
    try std.testing.expect(found);
    try std.testing.expectEqual(jpegz.Severity.fail, report.overall);
}

test "validate non-JPEG bytes → FAIL, missing_soi finding" {
    const allocator = std.testing.allocator;
    const garbage = "this is not a JPEG file at all";

    var report = try jpegz.validate(allocator, garbage);
    defer report.deinit(allocator);

    try std.testing.expectEqual(jpegz.Severity.fail, report.overall);
    var found_missing_soi = false;
    for (report.findings.items) |f| {
        if (f.code == .missing_soi) found_missing_soi = true;
    }
    try std.testing.expect(found_missing_soi);
}

test "DQT entries reject zero at every position and accept legal boundaries" {
	// T.81 Table B.4 requires 8-bit Qk in 1..255. Zero DC/EOB entropy
	// keeps the pixel control constant while each quantizer value changes.
	const pristine = [_]u8{ 0xff, 0xd8, 0xff, 0xdb, 0, 67, 0 } ++ ([_]u8{1} ** 64) ++
		[_]u8{ 0xff, 0xc0, 0, 11, 8, 0, 8, 0, 8, 1, 1, 0x11, 0 } ++
		[_]u8{ 0xff, 0xc4, 0, 20, 0, 1 } ++ ([_]u8{0} ** 15) ++ [_]u8{0} ++
		[_]u8{ 0xff, 0xc4, 0, 20, 0x10, 1 } ++ ([_]u8{0} ** 15) ++ [_]u8{0} ++
		[_]u8{ 0xff, 0xda, 0, 8, 1, 1, 0, 0, 63, 0, 0x3f, 0xff, 0xd9 };
	const allocator = std.testing.allocator;
	for (0..64) |index| {
		for ([_]u8{ 1, 255, 0 }) |value| {
			const data = try allocator.dupe(u8, &pristine);
			defer allocator.free(data);
			const offset = 7 + index;
			data[offset] = value;
			var report = try jpegz.validate(allocator, data);
			defer report.deinit(allocator);
			if (value == 0) {
				try expectExactTypedFailures(report, .quantization_table_corrupt, offset, 1);
			} else {
				try std.testing.expect(report.isValid());
				try std.testing.expect(!reportHasCode(report, .quantization_table_corrupt));
				var decoded = try jpegz.decode(allocator, data);
				defer decoded.deinit(allocator);
				var oracle = try jpegz.internal.wrapperDecode(allocator, data);
				defer oracle.deinit(allocator);
				try std.testing.expectEqualSlices(u8, oracle.pixels, decoded.pixels);
			}
		}
	}
}

test "16-bit DQT entries distinguish zero words from zero bytes" {
	// T.81 permits Pq=1 with a 12-bit SOF1 process; either byte may be zero.
	const pristine = [_]u8{ 0xff, 0xd8, 0xff, 0xdb, 0, 131, 0x10 } ++ ([_]u8{ 0, 1 } ** 64) ++
		[_]u8{ 0xff, 0xc1, 0, 11, 12, 0, 8, 0, 8, 1, 1, 0x11, 0 } ++
		[_]u8{ 0xff, 0xc4, 0, 20, 0, 1 } ++ ([_]u8{0} ** 15) ++ [_]u8{0} ++
		[_]u8{ 0xff, 0xc4, 0, 20, 0x10, 1 } ++ ([_]u8{0} ** 15) ++ [_]u8{0} ++
		[_]u8{ 0xff, 0xda, 0, 8, 1, 1, 0, 0, 63, 0, 0x3f, 0xff, 0xd9 };
	const allocator = std.testing.allocator;
	for (0..64) |index| {
		for ([_]u16{ 1, 256, 65535, 0 }) |value| {
			const data = try allocator.dupe(u8, &pristine);
			defer allocator.free(data);
			const offset = 7 + 2 * index;
			std.mem.writeInt(u16, data[offset..][0..2], value, .big);
			var report = try jpegz.validate(allocator, data);
			defer report.deinit(allocator);
			if (value == 0) {
				try expectExactTypedFailures(report, .quantization_table_corrupt, offset, 1);
			} else {
				try std.testing.expect(report.isValid());
				var decoded = try jpegz.decode(allocator, data);
				defer decoded.deinit(allocator);
				var oracle = try jpegz.internal.wrapperDecode(allocator, data);
				defer oracle.deinit(allocator);
				try std.testing.expectEqualSlices(u8, oracle.pixels, decoded.pixels);
			}
		}
	}
}

test "incomplete DQT tables stay inside the declared segment" {
	const allocator = std.testing.allocator;
	const entries = [_]u8{1} ** 128;
	for ([_]u8{ 0, 1 }) |pq| {
		const complete_bytes = 64 * (@as(usize, pq) + 1);
		for (0..complete_bytes) |available| {
			const header = [_]u8{ 0xff, 0xd8, 0xff, 0xdb, 0, @intCast(3 + available), pq << 4 };
			const data = try std.mem.concat(allocator, u8, &.{ &header, entries[0..available] });
			defer allocator.free(data);
			var report = try jpegz.validate(allocator, data);
			defer report.deinit(allocator);
			try std.testing.expectEqual(jpegz.Severity.fail, report.overall);
		}
	}
}

test "validate: quantization_table_corrupt classifies bad Pq/Tq, silent on clean" {
    const allocator = std.testing.allocator;

    // Negative: the clean fixture's DQTs are well-formed — no quant finding.
    {
        var report = try jpegz.validate(allocator, fixture_baseline_2x2_rgb);
        defer report.deinit(allocator);
        try std.testing.expect(!reportHasCode(report, .quantization_table_corrupt));
    }

    // Positive: corrupt the first DQT's PqTq byte (FF DB Lhi Llo, then PqTq)
    // two distinct illegal ways (T.81 §B.2.4: Pq∈{0,1}, Tq∈{0..3}).
    const bad_pqtq = [_]u8{ 0x50, 0x07 }; // Pq=5 ; Tq=7
    for (bad_pqtq) |pqtq| {
        const buf = try allocator.dupe(u8, fixture_baseline_2x2_rgb);
        defer allocator.free(buf);
        const dqt = findMarker(buf, 0xDB).?;
        buf[dqt + 4] = pqtq;

        var report = try jpegz.validate(allocator, buf);
        defer report.deinit(allocator);
        try std.testing.expect(reportHasCode(report, .quantization_table_corrupt));
    }
}

test "validate: sof_component_count_invalid classifies Nf=0 and length-inconsistent Nf" {
    const allocator = std.testing.allocator;

    // Negative: clean fixture (SOF0 Nf=3, length 17 = 8 + 3*3) is consistent.
    {
        var report = try jpegz.validate(allocator, fixture_baseline_2x2_rgb);
        defer report.deinit(allocator);
        try std.testing.expect(!reportHasCode(report, .sof_component_count_invalid));
    }

    // Positive: corrupt the SOF0 Nf byte (body offset 5: prec,H,H,W,W,Nf).
    // Nf=0 is invalid; Nf=5 makes seg_len(17) != 8 + 3*Nf(23) — inconsistent.
    const bad_nf = [_]u8{ 0x00, 0x05 };
    for (bad_nf) |nf| {
        const buf = try allocator.dupe(u8, fixture_baseline_2x2_rgb);
        defer allocator.free(buf);
        const sof = findMarker(buf, 0xC0).?; // FF C0 (SOF0)
        buf[sof + 2 + 2 + 5] = nf; // FF C0 Lhi Llo, then body[5] = Nf

        var report = try jpegz.validate(allocator, buf);
        defer report.deinit(allocator);
        try std.testing.expect(reportHasCode(report, .sof_component_count_invalid));
    }
}

test "validate: sos_component_mismatch classifies Cs not declared in SOF, silent on clean" {
    const allocator = std.testing.allocator;

    // Negative: clean fixture's SOS selectors (1,2,3) all match the SOF.
    {
        var report = try jpegz.validate(allocator, fixture_baseline_2x2_rgb);
        defer report.deinit(allocator);
        try std.testing.expect(!reportHasCode(report, .sos_component_mismatch));
    }

    // Positive: corrupt the first SOS component selector (Cs0) to an ID not
    // present in the SOF component list. Body: FF DA Lhi Llo Ns Cs0 ... so
    // Cs0 is at sos+5. 0x63 = 99 (not a declared component).
    const buf = try allocator.dupe(u8, fixture_baseline_2x2_rgb);
    defer allocator.free(buf);
    const sos = findMarker(buf, 0xDA).?;
    buf[sos + 5] = 0x63;

    var report = try jpegz.validate(allocator, buf);
    defer report.deinit(allocator);
    try std.testing.expect(reportHasCode(report, .sos_component_mismatch));
}

test "SOS duplicate selectors are typed at the repeated byte across Huffman modes" {
	const allocator = std.testing.allocator;
	for ([_][]const u8{
		fixture_baseline_2x2_rgb,
		fixture_progressive_8x8,
		@embedFile("fixtures/lossless_4x4_rgb_pred1.jpg"),
		@embedFile("fixtures/baseline_4x4_cmyk.jpg"),
	}) |pristine| {
		var clean = try jpegz.validate(allocator, pristine);
		defer clean.deinit(allocator);
		try std.testing.expect(clean.isValid());
		try std.testing.expect(!reportHasCode(clean, .sos_component_mismatch));
		const sos = findMarker(pristine, 0xda).?;
		const ns = pristine[sos + 4];
		try std.testing.expect(ns == 3 or ns == 4);
		for (1..ns) |selector| {
			const data = try allocator.dupe(u8, pristine);
			defer allocator.free(data);
			const offset = sos + 5 + selector * 2;
			data[offset] = data[sos + 5];
			var report = try jpegz.validate(allocator, data);
			defer report.deinit(allocator);
			try expectOnlyTypedFail(report, .sos_component_mismatch, offset);
			for (report.findings.items) |finding| {
				if (finding.code == .sos_component_mismatch) try std.testing.expect(finding.offset_is_exact);
			}
		}
	}
}

test "sequential SOS length and component count have distinct typed locations" {
	// T.81 B.2.3: Ls = 6 + 2*Ns, with distinct frame selectors and
	// 1 <= Ns <= min(4, Nf). Hand-packed entropy codes one gray block.
	const header = [_]u8{ 0xff, 0xd8, 0xff, 0xdb, 0, 67, 0 } ++ ([_]u8{1} ** 64) ++
		[_]u8{ 0xff, 0xc0, 0, 11, 8, 0, 8, 0, 8, 1, 1, 0x11, 0 } ++
		[_]u8{ 0xff, 0xc4, 0, 20, 0, 1 } ++ ([_]u8{0} ** 15) ++ [_]u8{0} ++
		[_]u8{ 0xff, 0xc4, 0, 20, 0x10, 1 } ++ ([_]u8{0} ** 15) ++ [_]u8{0};
	const cases = [_]struct { sos: []const u8, code: ?jpegz.FindingCode = null, field: usize = 0, failures: usize = 1 }{
		.{ .sos = &.{ 0xff, 0xda, 0, 8, 1, 1, 0, 0, 63, 0 } },
		.{ .sos = &.{ 0xff, 0xda, 0, 6, 0, 0, 63, 0 }, .code = .sos_component_mismatch, .field = 4 },
		.{ .sos = &.{ 0xff, 0xda, 0, 10, 2, 1, 0, 1, 0, 0, 63, 0 }, .code = .sos_component_mismatch, .field = 4, .failures = 2 },
		.{ .sos = &.{ 0xff, 0xda, 0, 16, 5, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 0, 63, 0 }, .code = .sos_component_mismatch, .field = 4, .failures = 5 },
		.{ .sos = &.{ 0xff, 0xda, 0, 8, 255, 1, 0, 0, 63, 0 }, .code = .sos_component_mismatch, .field = 4, .failures = 2 },
		.{ .sos = &.{ 0xff, 0xda, 0, 2 }, .code = .bad_marker_length, .field = 2 },
		.{ .sos = &.{ 0xff, 0xda, 0, 5, 1, 1, 0 }, .code = .bad_marker_length, .field = 2 },
		.{ .sos = &.{ 0xff, 0xda, 0, 7, 1, 1, 0, 0, 63 }, .code = .bad_marker_length, .field = 2 },
		.{ .sos = &.{ 0xff, 0xda, 0, 9, 1, 1, 0, 0, 63, 0, 0 }, .code = .bad_marker_length, .field = 2 },
	};
	const allocator = std.testing.allocator;
	for ([_]u8{ 0xc0, 0xc1 }) |sof| {
		for (cases) |case| {
			const data = try std.mem.concat(allocator, u8, &.{ &header, case.sos, &.{ 0x3f, 0xff, 0xd9 } });
			defer allocator.free(data);
			data[findMarker(data, 0xc0).? + 1] = sof;
			var report = try jpegz.validate(allocator, data);
			defer report.deinit(allocator);
			if (case.code) |code| {
				try expectOnlyTypedFail(report, code, header.len + case.field);
				var failures: usize = 0;
				for (report.findings.items) |finding| {
					if (finding.severity != .fail) continue;
					failures += 1;
					try std.testing.expect(finding.offset_is_exact);
				}
				try std.testing.expectEqual(case.failures, failures);
			} else {
				try std.testing.expect(report.isValid());
				try std.testing.expectEqual(.decoded, report.codec_check);
				var decoded = try jpegz.decode(allocator, data);
				defer decoded.deinit(allocator);
				var oracle = try jpegz.internal.wrapperDecode(allocator, data);
				defer oracle.deinit(allocator);
				try std.testing.expectEqualSlices(u8, oracle.pixels, decoded.pixels);
			}
		}
	}
}

test "APP0 identifiers are classified without requiring every JPEG to be JFIF" {
	// JFIF 1.02 identifies its APP0 by all five bytes and permits other uses.
	const allocator = std.testing.allocator;
	const identifier = findMarker(fixture_baseline_2x2_rgb, 0xe0).? + 4;
	try std.testing.expectEqualSlices(u8, "JFIF\x00", fixture_baseline_2x2_rgb[identifier..][0..5]);
	for (0..5) |field| {
		for (0..256) |raw| {
			const data = try allocator.dupe(u8, fixture_baseline_2x2_rgb);
			defer allocator.free(data);
			data[identifier + field] = @intCast(raw);
			var report = try jpegz.validate(allocator, data);
			defer report.deinit(allocator);
			try std.testing.expect(report.isValid());
			try std.testing.expectEqual(raw == fixture_baseline_2x2_rgb[identifier + field],
				reportHasCode(report, .jfif_metadata_present));
			var decoded = try jpegz.decode(allocator, data);
			defer decoded.deinit(allocator);
			var oracle = try jpegz.internal.wrapperDecode(allocator, data);
			defer oracle.deinit(allocator);
			try std.testing.expectEqualSlices(u8, oracle.pixels, decoded.pixels);
		}
	}
}

test "JFIF nonzero density boundaries and zero-product thumbnails remain legal" {
	const allocator = std.testing.allocator;
	const body = findMarker(fixture_baseline_2x2_rgb, 0xe0).? + 4;
	for ([_]usize{ 8, 10 }) |field| {
		for ([_]u16{ 1, 254, 255, 256, 65281, 65535 }) |density| {
			const data = try allocator.dupe(u8, fixture_baseline_2x2_rgb);
			defer allocator.free(data);
			std.mem.writeInt(u16, data[body + field..][0..2], density, .big);
			data[body + 6] = 2;
			var report = try jpegz.validate(allocator, data);
			defer report.deinit(allocator);
			try std.testing.expect(report.isValid());
			var decoded = try jpegz.decode(allocator, data);
			defer decoded.deinit(allocator);
			var oracle = try jpegz.internal.wrapperDecode(allocator, data);
			defer oracle.deinit(allocator);
			try std.testing.expectEqualSlices(u8, oracle.pixels, decoded.pixels);
		}
	}
	// T.871 10.1 permits either base-thumbnail dimension to be zero.
	// Every independent change keeps their product zero and Lp=16 correct.
	for ([_]usize{ 12, 13 }) |field| {
		for (0..256) |value| {
			const data = try allocator.dupe(u8, fixture_baseline_2x2_rgb);
			defer allocator.free(data);
			data[body + field] = @intCast(value);
			data[body + 6] = 2;
			var report = try jpegz.validate(allocator, data);
			defer report.deinit(allocator);
			try std.testing.expect(report.isValid());
			try std.testing.expect(!reportHasCode(report, .embedded_thumbnail_present));
			var decoded = try jpegz.decode(allocator, data);
			defer decoded.deinit(allocator);
			var oracle = try jpegz.internal.wrapperDecode(allocator, data);
			defer oracle.deinit(allocator);
			try std.testing.expectEqualSlices(u8, oracle.pixels, decoded.pixels);
		}
	}
}

test "JFIF density units classify every byte only for the declared profile" {
	const allocator = std.testing.allocator;
	const body = findMarker(fixture_baseline_2x2_rgb, 0xe0).? + 4;
	// A generic APP0 payload does not acquire JFIF field constraints.
	for (0..5) |field| {
		for ([_]u8{ 1, 2 }) |minor| {
			const data = try allocator.dupe(u8, fixture_baseline_2x2_rgb);
			defer allocator.free(data);
			data[body + field] ^= 0xff;
			data[body + 6] = minor;
			data[body + 7] = 255;
			var report = try jpegz.validate(allocator, data);
			defer report.deinit(allocator);
			try std.testing.expect(report.isValid());
		}
	}
	// Historical IJG 6a evidence independently confirms the shared units
	// contract for its deliberate 1.01 emission; the extension is approved.
	for ([_]u8{ 2, 1 }) |minor| {
		for (0..256) |units| {
			const data = try allocator.dupe(u8, fixture_baseline_2x2_rgb);
			defer allocator.free(data);
			data[body + 6] = minor;
			data[body + 7] = @intCast(units);
			var report = try jpegz.validate(allocator, data);
			defer report.deinit(allocator);
			if (units > 2) {
				try expectExactTypedFailures(report, .jfif_metadata_invalid, body + 7, 1);
			} else {
				try std.testing.expect(report.isValid());
				var decoded = try jpegz.decode(allocator, data);
				defer decoded.deinit(allocator);
				var oracle = try jpegz.internal.wrapperDecode(allocator, data);
				defer oracle.deinit(allocator);
				try std.testing.expectEqualSlices(u8, oracle.pixels, decoded.pixels);
			}
		}
	}
}

