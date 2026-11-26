//! validate tests, part 7 (split from validate.zig to keep files small).

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

test "jpeg2000.validate: structural corruption set is detected (sensitivity)" {
    const allocator = std.testing.allocator;
    const src = fixture_jp2_rgb;
    const soc = findSoc(src).?;

    const Mutation = struct { name: []const u8, apply: *const fn ([]u8, usize) void };
    const mutations = [_]Mutation{
        .{
            .name = "JP2 signature box magic smashed ('jP  ' → 'XXXX')",
            .apply = struct {
                fn f(buf: []u8, _: usize) void {
                    @memset(buf[4..8], 'X');
                }
            }.f,
        },
        .{
            .name = "SOC marker smashed (codestream start destroyed)",
            .apply = struct {
                fn f(buf: []u8, soc_off: usize) void {
                    buf[soc_off] = 0x00;
                    buf[soc_off + 1] = 0x00;
                }
            }.f,
        },
        .{
            .name = "SIZ marker smashed (frame geometry unreadable)",
            .apply = struct {
                fn f(buf: []u8, soc_off: usize) void {
                    buf[soc_off + 2] = 0x00;
                    buf[soc_off + 3] = 0x00;
                }
            }.f,
        },
    };

    for (mutations) |m| {
        const buf = try allocator.dupe(u8, src);
        defer allocator.free(buf);
        m.apply(buf, soc);

        var report = try jpegz.jpeg2000.validate(allocator, buf);
        defer report.deinit(allocator);

        std.testing.expectEqual(jpegz.Severity.fail, report.overall) catch |e| {
            std.debug.print("jp2 mutation not detected: {s}\n", .{m.name});
            return e;
        };
    }

    // Truncation is its own shape (shorter buffer, not an in-place edit).
    // Cut to the first third — signature + ftyp survive, the codestream
    // does not.
    var report = try jpegz.jpeg2000.validate(allocator, src[0 .. src.len / 3]);
    defer report.deinit(allocator);
    try std.testing.expectEqual(jpegz.Severity.fail, report.overall);
}

test "jpeg2000.validate: every known-good JP2 fixture does not fail (specificity)" {
    const allocator = std.testing.allocator;
    for (jp2_specificity_corpus, 0..) |fixture, idx| {
        var report = try jpegz.jpeg2000.validate(allocator, fixture);
        defer report.deinit(allocator);
        std.testing.expect(report.overall != .fail) catch |e| {
            std.debug.print("false positive on known-good JP2 fixture #{d}\n", .{idx});
            return e;
        };
    }
}

test "jpeg2000.validate: reports a JP2-specific finding code, not a bare severity" {
    const allocator = std.testing.allocator;
    const src = fixture_jp2_rgb;
    const buf = try allocator.dupe(u8, src);
    defer allocator.free(buf);
    @memset(buf[4..8], 'X'); // smash the signature box magic

    var report = try jpegz.jpeg2000.validate(allocator, buf);
    defer report.deinit(allocator);

    // The whole point of the facade is ONE error vocabulary: consumers
    // must get an actionable jpegz FindingCode, not just `.fail`.
    try std.testing.expect(report.findings.items.len > 0);
    try std.testing.expect(reportHasCode(report, .jp2_invalid_signature) or
        reportHasCode(report, .jp2_invalid_codestream));
}

// A finding code that jpegz does not declare must not be renamed into an
// ALARMING one. Delegation translates jp2z's registry into jpegz's, and any
// code jpegz lacks previously degraded to `jp2_invalid_codestream` — so a
// perfectly healthy JP2 reported "invalid codestream" purely because
// `jp2_packets_walked_to_end` (254, a success signal meaning the walker
// consumed every tile-part byte) had no jpegz equivalent. A false alarm on a
// clean file is worse than a missing detail: it trains consumers to ignore
// the code.
test "jpeg2000.validate: clean JP2 reports no failure-flavored code" {
    const allocator = std.testing.allocator;
    for (jp2_specificity_corpus, 0..) |fixture, idx| {
        var report = try jpegz.jpeg2000.validate(allocator, fixture);
        defer report.deinit(allocator);

        std.testing.expect(!reportHasCode(report, .jp2_invalid_codestream)) catch |e| {
            std.debug.print("clean JP2 fixture #{d} reported jp2_invalid_codestream\n", .{idx});
            return e;
        };
        std.testing.expect(!reportHasCode(report, .jp2_invalid_signature)) catch |e| {
            std.debug.print("clean JP2 fixture #{d} reported jp2_invalid_signature\n", .{idx});
            return e;
        };
    }
}

// The success signal itself must survive translation intact, not merely
// avoid being renamed to something scary. jp2z emits
// `jp2_packets_walked_to_end` when the walker consumed every tile-part body
// byte; that is exactly the kind of positive evidence `validate` wants.
test "jpeg2000.validate: preserves jp2z's informational codes verbatim" {
    const allocator = std.testing.allocator;
    var report = try jpegz.jpeg2000.validate(allocator, fixture_jp2_rgb);
    defer report.deinit(allocator);

    try std.testing.expect(reportHasCode(report, .jp2_uses_5x3_wavelet));
    try std.testing.expect(reportHasCode(report, .jp2_packets_walked_to_end));
}

// ── Totality: validate must never panic, whatever the bytes say ──────
//
// `validate` is the function every consumer reaches for when it does NOT
// trust its input. A panic is therefore the one failure mode it cannot have:
// it is uncatchable in Zig, so a single crafted file takes down the whole
// host process (it took down tiffz's validateAllStripsAndTiles).
//
// The defect class: T.81 table-destination selectors are wider than the
// tables they select. SOF's Tq is a full byte (0..255) and SOS's Td/Ta are
// 4 bits each (0..15), but all three index 4-element arrays. Any value above
// 3 indexed straight out of bounds. Same family as `sof_zero_dimension`,
// which was an OOB crash in color.fancyUpsample.

test "validate reports, never panics, on an out-of-range SOS table selector" {
	// SOS layout (T.81 §B.2.3): FF DA, Ls(2), Ns(1), then Ns x (Cs, Td|Ta).
	// Td/Ta is one byte of two 4-bit destination selectors, so 0xFF asks for
	// DC table 15 and AC table 15 out of the four that exist.
	const allocator = std.testing.allocator;
	var data = fixture_baseline_2x2_rgb.*;
	const sos = findMarker(&data, 0xDA) orelse return error.SkipZigTest;
	data[sos + 6] = 0xFF; // Td|Ta of the first scan component

	var report = try jpegz.validate(allocator, &data);
	defer report.deinit(allocator);
	// Reaching this line at all is the assertion that matters; a panic would
	// abort the test binary rather than fail this test.
	try std.testing.expectEqual(jpegz.Severity.fail, report.overall);
	try std.testing.expect(report.findings.items.len > 0);
}

test "validate reports, never panics, on an out-of-range SOF quant selector" {
	// SOF0 layout (T.81 §B.2.2): FF C0, Lf(2), P, Y(2), X(2), Nf, then
	// Nf x (C, H|V, Tq). Tq is a whole byte, so it can name table 255 of 4.
	const allocator = std.testing.allocator;
	var data = fixture_baseline_2x2_rgb.*;
	const sof = findMarker(&data, 0xC0) orelse return error.SkipZigTest;
	data[sof + 12] = 0xFF; // Tq of the first frame component

	var report = try jpegz.validate(allocator, &data);
	defer report.deinit(allocator);
	try std.testing.expectEqual(jpegz.Severity.fail, report.overall);
	try std.testing.expect(report.findings.items.len > 0);
}

test "validate is total over every single-byte mutation of a real JPEG" {
	// The two cases above were found by reading the code after tiffz hit a
	// panic in the wild. This sweeps the whole file so the NEXT unchecked
	// index is found by the suite rather than by a downstream consumer's
	// crash: a classifier over a set, not two hand-picked examples.
	const allocator = std.testing.allocator;
	for (0..fixture_baseline_2x2_rgb.len) |off| {
		for ([_]u8{ 0x00, 0x0F, 0x3F, 0xF0, 0xFF }) |val| {
			var data = fixture_baseline_2x2_rgb.*;
			if (data[off] == val) continue;
			data[off] = val;
			var report = jpegz.validate(allocator, &data) catch |err| {
				// An error return is a legitimate outcome; a panic is not.
				try std.testing.expectEqual(error.OutOfMemory, err);
				continue;
			};
			report.deinit(allocator);
		}
	}
}

test "validate accepts conforming multi-scan sequential JPEGs" {
	const allocator = std.testing.allocator;
	for ([_][]const u8{
		fixture_seq_16x16_3scan,
		fixture_seq_17x13_420_y_cbcr_rst,
		fixture_seq_23x19_422_rev_rst,
		fixture_seq_23x19_rgb12_420_3scan,
	}) |data| {
		var report = try jpegz.validate(allocator, data);
		defer report.deinit(allocator);
		for (report.findings.items) |f| {
			if (f.severity == .fail or f.severity == .warn) {
				std.debug.print("unexpected {s} {s}\n", .{ @tagName(f.severity), @tagName(f.code) });
				return error.TestUnexpectedResult;
			}
		}
		try std.testing.expect(report.codec_check == .decoded);
	}
}

test "validate rejects multi-scan sequential frames that break component coverage" {
	// Malformed counterparts built from seq_16x16_3scan (SOS at 648 selects
	// component 2, SOS at 661 selects component 3; Cs is at +5, Td/Ta at +6).
	// T.81 §3.1.116: sequential coding encodes each component within a single
	// scan (§B.2.3 also forbids a repeated Csj), and Td/Ta must name a table
	// defined before the scan. libjpeg-turbo 3.2.1 `djpeg -strict` reports only
	// the undefined table; reader tolerance does not lower the other three.
	const allocator = std.testing.allocator;
	const good = fixture_seq_16x16_3scan;
	var repeated = good.*;
	repeated[661 + 5] = 2; // component 2 twice, component 3 never
	var undefined_table = good.*;
	undefined_table[648 + 6] = 0x22; // DC/AC destination 2 was never defined
	const early_eoi = good[0..661].* ++ [_]u8{ 0xff, 0xd9 }; // component 3 never coded
	// Scan 1 (SOS at 393, entropy through 431) repeated before the DHT at 432:
	// every component still ends up coded, so only the repeat guard can object.
	const repeated_scan = good[0..432].* ++ good[393..432].* ++ good[432..].*;
	for ([_][]const u8{ &repeated, &undefined_table, &early_eoi, &repeated_scan }) |data| {
		var report = try jpegz.validate(allocator, data);
		defer report.deinit(allocator);
		try std.testing.expectEqual(jpegz.Severity.fail, report.overall);
	}
	// Coverage violations name the SOS whose selector repeats a component
	// (the Cs byte) or the EOI that ends the frame early.
	const Typed = struct { data: []const u8, code: jpegz.FindingCode, offset: u64 };
	for ([_]Typed{
		.{ .data = &repeated, .code = .sos_component_mismatch, .offset = 661 + 5 },
		.{ .data = &repeated_scan, .code = .sos_component_mismatch, .offset = 432 + 5 },
		.{ .data = &early_eoi, .code = .truncated_stream, .offset = 661 },
	}) |c| {
		var report = try jpegz.validate(allocator, c.data);
		defer report.deinit(allocator);
		try expectOnlyTypedFail(report, c.code, c.offset);
	}
}

test "sequential scans after complete coverage fail before EOI only" {
	const allocator = std.testing.allocator;
	// Marker-like bytes inside an opaque APP payload are not scan boundaries.
	const app = [_]u8{ 0xff, 0xe1, 0, 8, 0xff, 0xda, 0xff, 0xd9, 1, 2 };
	const cases = [_]struct { pristine: []const u8, extra: []const u8 }{
		.{ .pristine = fixture_baseline_2x2_rgb, .extra = fixture_baseline_2x2_rgb[findMarker(fixture_baseline_2x2_rgb, 0xda).? .. fixture_baseline_2x2_rgb.len - 2] },
		.{ .pristine = fixture_seq_16x16_3scan, .extra = fixture_seq_16x16_3scan[393..432] },
	};
	for (cases) |case| {
		try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xd9 }, case.pristine[case.pristine.len - 2 ..]);
		const prefix = case.pristine[0 .. case.pristine.len - 2];
		for ([_][]const u8{ &.{}, &app }) |between| {
			const good = try std.mem.concat(allocator, u8, &.{ prefix, between, &.{ 0xff, 0xd9 } });
			defer allocator.free(good);
			var decoded = try jpegz.decode(allocator, good);
			defer decoded.deinit(allocator);
			var oracle = try jpegz.internal.wrapperDecode(allocator, good);
			defer oracle.deinit(allocator);
			try std.testing.expectEqualSlices(u8, oracle.pixels, decoded.pixels);
			const bad = try std.mem.concat(allocator, u8, &.{ prefix, between, case.extra, &.{ 0xff, 0xd9 } });
			defer allocator.free(bad);
			const repeated_cs = prefix.len + between.len + 5;
			var report = try jpegz.validate(allocator, bad);
			defer report.deinit(allocator);
			try expectOnlyTypedFail(report, .sos_component_mismatch, repeated_cs);
			for ([_]bool{ false, true }) |lenient| {
				var sink = jpegz.FindingsSink.init(allocator);
				defer sink.deinit();
				if (jpegz.decodeWithOptions(allocator, bad, .{ .lenient = lenient, .findings_sink = &sink })) |image| {
					var unexpected = image;
					unexpected.deinit(allocator);
					return error.ExpectedDecodeFailure;
				} else |err| try std.testing.expectEqual(error.InvalidMarker, err);
				var found = false;
				for (sink.items()) |finding| {
					if (finding.code == .sos_component_mismatch and finding.offset == repeated_cs) {
						try std.testing.expectEqual(jpegz.Severity.fail, finding.severity);
						try std.testing.expect(finding.offset_is_exact);
						found = true;
					}
				}
				try std.testing.expect(found);
			}
		}
		const trailing = try std.mem.concat(allocator, u8, &.{ case.pristine, case.extra });
		defer allocator.free(trailing);
		var report = try jpegz.validate(allocator, trailing);
		defer report.deinit(allocator);
		try std.testing.expect(report.isValid());
		try std.testing.expect(!reportHasCode(report, .sos_component_mismatch));
	}
}

test "post-coverage inspection preserves missing-EOI decode outcomes" {
	const allocator = std.testing.allocator;
	const pristine = fixture_seq_16x16_3scan;
	const prefix = pristine[0 .. pristine.len - 2];
	const app = [_]u8{ 0xff, 0xe1, 0, 8, 0xff, 0xda, 0xff, 0xd9, 1, 2 };
	var complete = try jpegz.decode(allocator, pristine);
	defer complete.deinit(allocator);
	try std.testing.expectError(error.BackendError, jpegz.decode(allocator, prefix));
	// The old decoder finishes at the APP marker after full scan coverage,
	// even when the following metadata is incomplete. Preserve that behavior.
	for (2..app.len + 1) |end| {
		const data = try std.mem.concat(allocator, u8, &.{ prefix, app[0..end] });
		defer allocator.free(data);
		var sink = jpegz.FindingsSink.init(allocator);
		defer sink.deinit();
		var decoded = try jpegz.decodeWithOptions(allocator, data, .{ .findings_sink = &sink });
		defer decoded.deinit(allocator);
		try std.testing.expectEqualSlices(u8, complete.pixels, decoded.pixels);
		try std.testing.expectEqual(@as(usize, 0), sink.items().len);
	}
	const open_tail = try std.mem.concat(allocator, u8, &.{ prefix, &app, pristine[393..432] });
	defer allocator.free(open_tail);
	var sink = jpegz.FindingsSink.init(allocator);
	defer sink.deinit();
	var decoded = try jpegz.decodeWithOptions(allocator, open_tail, .{ .findings_sink = &sink });
	defer decoded.deinit(allocator);
	try std.testing.expectEqualSlices(u8, complete.pixels, decoded.pixels);
	try std.testing.expectEqual(@as(usize, 0), sink.items().len);
}

test "SOF1 accepts every component ID and all four Huffman destinations" {
	const allocator = std.testing.allocator;
	var original = try jpegz.internal.wrapperDecode(allocator, fixture_baseline_2x2_rgb);
	defer original.deinit(allocator);
	for (0..256) |raw_id| {
		const data = try sof1TableFixture(allocator, 0, 0, @intCast(raw_id));
		defer allocator.free(data);
		var report = try jpegz.validate(allocator, data);
		defer report.deinit(allocator);
		try std.testing.expect(report.isValid());
		try std.testing.expectEqual(.decoded, report.codec_check);
		var decoded = try jpegz.internal.cleanroomDecode(allocator, data);
		defer decoded.deinit(allocator);
		var oracle = try jpegz.internal.wrapperDecode(allocator, data);
		defer oracle.deinit(allocator);
		try std.testing.expectEqualSlices(u8, original.pixels, oracle.pixels);
		try std.testing.expectEqualSlices(u8, oracle.pixels, decoded.pixels);
	}
	// Classify all 256 Td/Ta bytes. For legal selectors, relocate matching
	// definitions too; changing selectors alone would also change the codebook.
	for (0..256) |raw| {
		const selector: u8 = @intCast(raw);
		const dc = selector >> 4;
		const ac = selector & 15;
		const valid = dc < 4 and ac < 4;
		const data = try sof1TableFixture(allocator, if (valid) dc else 0, if (valid) ac else 0, 0);
		defer allocator.free(data);
		data[787 + 6] = selector;
		var report = try jpegz.validate(allocator, data);
		defer report.deinit(allocator);
		try std.testing.expectEqual(valid, report.isValid());
		if (!valid) continue;
		try std.testing.expectEqual(.decoded, report.codec_check);
		var decoded = try jpegz.internal.cleanroomDecode(allocator, data);
		defer decoded.deinit(allocator);
		var oracle = try jpegz.internal.wrapperDecode(allocator, data);
		defer oracle.deinit(allocator);
		try std.testing.expectEqualSlices(u8, original.pixels, oracle.pixels);
		try std.testing.expectEqualSlices(u8, oracle.pixels, decoded.pixels);
	}
	for (0..4) |shift| {
		const defined: u8 = @intCast(shift);
		const missing = (defined + 3) % 4;
		for ([_]u8{ (missing << 4) | defined, (defined << 4) | missing }) |selector| {
			const data = try sof1TableFixture(allocator, defined, defined, 0);
			defer allocator.free(data);
			data[787 + 6] = selector;
			var report = try jpegz.validate(allocator, data);
			defer report.deinit(allocator);
			try std.testing.expectEqual(jpegz.Severity.fail, report.overall);
		}
	}
}

test "lossless scans name whole bytes after valid padding instead of a generic decoder error" {
	// tiffz observation 2026-11-06: one stray byte before EOI read as
	// huffman_table_corrupt "BackendError". Since 2026-11-22 (validate) whole
	// bytes after valid padding are FAIL 8, exact at the first, as on the
	// sequential path.
	const allocator = std.testing.allocator;
	const good = @embedFile("fixtures/lossless_4x4_gray8.jpg");
	const body = good[0 .. good.len - 2];
	const Case = struct { extra: []const u8, detail: []const u8 };
	const cases = [_]Case{
		.{ .extra = &.{0x00}, .detail = "1 whole byte after valid padding before marker 0xD9" },
		.{ .extra = &.{ 0x00, 0x5a }, .detail = "2 whole bytes after valid padding before marker 0xD9" },
		.{ .extra = &.{ 0xff, 0x00 }, .detail = "1 whole byte after valid padding before marker 0xD9" },
	};
	for (cases) |case| {
		const data = try std.mem.concat(allocator, u8, &.{ body, case.extra, &.{ 0xff, 0xd9 } });
		defer allocator.free(data);
		var result = try jpegz.validate(allocator, data);
		defer result.deinit(allocator);
		try std.testing.expect(!result.isValid());
		var named: usize = 0;
		for (result.findings.items) |finding| {
			try std.testing.expect(finding.code != .huffman_table_corrupt);
			if (finding.code != .extraneous_bytes_before_marker) continue;
			try std.testing.expectEqual(jpegz.Severity.fail, finding.severity);
			try std.testing.expect(finding.offset_is_exact and finding.offset.? == body.len);
			const detail = finding.detail orelse return error.TestExpectedDetail;
			if (!std.mem.eql(u8, detail, case.detail)) {
				std.debug.print("extra {x}: got detail '{s}', want '{s}'\n", .{ case.extra, detail, case.detail });
				return error.TestUnexpectedResult;
			}
			named += 1;
		}
		try std.testing.expectEqual(@as(usize, 1), named);
	}
	// Control: the unmodified file stays valid.
	var clean = try jpegz.validate(allocator, good);
	defer clean.deinit(allocator);
	try std.testing.expect(clean.isValid());
}

