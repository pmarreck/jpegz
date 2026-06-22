//! M1.5 — `jpegz.validate` tests. Walks the bitstream, accumulates
//! Findings, returns a structured ValidationReport. Never fails-fast
//! on structural errors (per the design doc — validate-mode wants the
//! complete picture, not the first failure).

const std = @import("std");
const jpegz = @import("jpegz");

const fixture_baseline_2x2_rgb = @embedFile("fixtures/baseline_2x2_rgb.jpg");
const fixture_progressive_8x8 = @embedFile("fixtures/progressive_8x8_rgb.jpg");
const fixture_lossless_4x4_gray8 = @embedFile("fixtures/lossless_4x4_gray8.jpg");
const fixture_arith_8x8_gray = @embedFile("fixtures/arith_baseline_8x8_gray.jpg");

test "validate clean baseline JPEG → valid, baseline_huffman" {
    const allocator = std.testing.allocator;

    var report = try jpegz.validate(allocator, fixture_baseline_2x2_rgb);
    defer report.deinit(allocator);

    // .info is fine — cjpeg-emitted JFIF marker triggers an INFO finding.
    try std.testing.expect(report.isValid());
    try std.testing.expect(report.overall != .fail);
    try std.testing.expectEqual(jpegz.Variant.baseline_huffman, report.variant);
    try std.testing.expectEqual(@as(?u32, 2), report.width);
    try std.testing.expectEqual(@as(?u32, 2), report.height);
    // No fail findings.
    for (report.findings.items) |f| {
        try std.testing.expect(f.severity != .fail);
    }
}

test "validate clean progressive JPEG → valid, progressive_huffman" {
    const allocator = std.testing.allocator;

    var report = try jpegz.validate(allocator, fixture_progressive_8x8);
    defer report.deinit(allocator);

    try std.testing.expect(report.isValid());
    try std.testing.expect(report.overall != .fail);
    try std.testing.expectEqual(jpegz.Variant.progressive_huffman, report.variant);
    try std.testing.expectEqual(@as(?u32, 8), report.width);
    try std.testing.expectEqual(@as(?u32, 8), report.height);
}

test "validate clean lossless JPEG → valid, lossless_huffman" {
    const allocator = std.testing.allocator;

    var report = try jpegz.validate(allocator, fixture_lossless_4x4_gray8);
    defer report.deinit(allocator);

    try std.testing.expect(report.isValid());
    try std.testing.expect(report.overall != .fail);
    try std.testing.expectEqual(jpegz.Variant.lossless_huffman, report.variant);
    try std.testing.expectEqual(@as(?u32, 4), report.width);
    try std.testing.expectEqual(@as(?u32, 4), report.height);
}

test "validate truncated JPEG → FAIL, truncated_stream finding" {
    const allocator = std.testing.allocator;

    // Slice off the trailing 30 bytes (drops EOI + tail of entropy data).
    const truncated = fixture_baseline_2x2_rgb[0 .. fixture_baseline_2x2_rgb.len - 30];

    var report = try jpegz.validate(allocator, truncated);
    defer report.deinit(allocator);

    try std.testing.expectEqual(jpegz.Severity.fail, report.overall);
    // At least one finding must indicate truncation.
    var found_truncation = false;
    for (report.findings.items) |f| {
        if (f.code == .truncated_stream and f.severity == .fail) {
            found_truncation = true;
        }
    }
    try std.testing.expect(found_truncation);
}

test "validate empty input → FAIL, missing_soi finding" {
    const allocator = std.testing.allocator;
    const empty: []const u8 = &[_]u8{};

    var report = try jpegz.validate(allocator, empty);
    defer report.deinit(allocator);

    try std.testing.expectEqual(jpegz.Severity.fail, report.overall);
    try std.testing.expectEqual(jpegz.Variant.unknown, report.variant);

    var found_missing_soi = false;
    for (report.findings.items) |f| {
        if (f.code == .missing_soi and f.severity == .fail) {
            found_missing_soi = true;
        }
    }
    try std.testing.expect(found_missing_soi);
}

/// 4×4 baseline RGB JPEG whose DHT (Huffman table definition) was
/// corrupted by setting all 16 code-length counts to 0xFF — an
/// impossible declaration that fails libjpeg's Huffman validation
/// with "Bogus Huffman table definition". The structural marker walker
/// passes (DHT length and bracket are intact); only codec-level
/// integrity catches it.
const fixture_baseline_4x4_bogus_dht = @embedFile("fixtures/baseline_4x4_bogus_dht.jpg");

test "validate corrupted DHT → FAIL with codec-level finding" {
    const allocator = std.testing.allocator;

    var report = try jpegz.validate(allocator, fixture_baseline_4x4_bogus_dht);
    defer report.deinit(allocator);

    try std.testing.expectEqual(jpegz.Severity.fail, report.overall);
    // Marker walker still classifies the variant from the SOF marker.
    try std.testing.expectEqual(jpegz.Variant.baseline_huffman, report.variant);

    // At least one finding must be the codec-level Huffman fail.
    var found_codec_fail = false;
    for (report.findings.items) |f| {
        if (f.severity == .fail and f.code == .huffman_table_corrupt) {
            found_codec_fail = true;
        }
    }
    try std.testing.expect(found_codec_fail);
}

// ── M1.5c (per validate handoff 2026-05-06) — APPn presence + trailing data ──

const fixture_baseline_4x4_with_exif     = @embedFile("fixtures/baseline_4x4_with_exif.jpg");
const fixture_baseline_4x4_with_trailing = @embedFile("fixtures/baseline_4x4_with_trailing.jpg");

test "validate surfaces JFIF presence as INFO finding" {
    const allocator = std.testing.allocator;
    var report = try jpegz.validate(allocator, fixture_baseline_2x2_rgb);
    defer report.deinit(allocator);

    try std.testing.expect(report.isValid());
    var found = false;
    for (report.findings.items) |f| {
        if (f.code == .jfif_metadata_present and f.severity == .info) found = true;
    }
    try std.testing.expect(found);
}

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

test "validate surfaces trailing-data-after-EOI as INFO" {
    const allocator = std.testing.allocator;
    var report = try jpegz.validate(allocator, fixture_baseline_4x4_with_trailing);
    defer report.deinit(allocator);

    // Trailing data is INFO (the file is decodable; this is just a
    // notable observation), so overall stays at .info or .pass-derived.
    try std.testing.expect(report.isValid());
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

test "validate surfaces libjpeg-style insufficient_data tolerance as Finding(warn)" {
    // Architecture decision (NEXT_STEPS.md §"Validation-strictness"):
    // when the decoder tolerates a spec deviation that libjpeg-turbo
    // would WARNMS about, validate(...) must surface a Finding(.warn).
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

    // Must surface at least one .warn finding tagged insufficient_data.
    var found_warn = false;
    for (report.findings.items) |f| {
        if (f.severity == .warn and f.code == .insufficient_data) {
            found_warn = true;
        }
    }
    try std.testing.expect(found_warn);
    // Overall must not regress to .fail — libjpeg recovers, so should we.
    try std.testing.expect(report.overall != .fail);
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

// ── Dormant T.81 code wiring (validation strictness for upstream Validate) ──
// A strict validator must surface table/structure-level spec violations that
// permissive libraries silently tolerate. Each new code is tested as a
// classifier over sets: it fires on the malformed set, stays silent on the
// well-formed one.

/// Offset of the first occurrence of marker byte `m` (the byte after a
/// 0xFF prefix) in `data`, or null. Helper for in-test corruption.
fn findMarker(data: []const u8, m: u8) ?usize {
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 1) {
        if (data[i] == 0xFF and data[i + 1] == m) return i;
    }
    return null;
}

fn reportHasCode(report: jpegz.ValidationReport, code: jpegz.FindingCode) bool {
    for (report.findings.items) |f| {
        if (f.code == code) return true;
    }
    return false;
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

test "validate: progressive_scan_count is INFO on progressive, absent on baseline" {
    const allocator = std.testing.allocator;

    // Positive: a progressive frame decodes in multiple scans.
    {
        var report = try jpegz.validate(allocator, fixture_progressive_8x8);
        defer report.deinit(allocator);
        try std.testing.expect(reportHasCode(report, .progressive_scan_count));
    }
    // Negative: a single-scan baseline must not carry the observation.
    {
        var report = try jpegz.validate(allocator, fixture_baseline_2x2_rgb);
        defer report.deinit(allocator);
        try std.testing.expect(!reportHasCode(report, .progressive_scan_count));
    }
}

test "validate: embedded_thumbnail_present detects JFIF APP0 thumbnail, silent when absent" {
    const allocator = std.testing.allocator;

    // Negative: the clean fixture's JFIF declares a 0×0 (absent) thumbnail.
    {
        var report = try jpegz.validate(allocator, fixture_baseline_2x2_rgb);
        defer report.deinit(allocator);
        try std.testing.expect(!reportHasCode(report, .embedded_thumbnail_present));
    }

    // Positive: splice a 1×1 thumbnail into the JFIF APP0 — set Xthumb=Ythumb=1,
    // insert 3 RGB bytes after Ythumb, bump the APP0 segment length 16 → 19.
    const orig = fixture_baseline_2x2_rgb;
    const app0 = findMarker(orig, 0xE0).?;
    const ins_at = app0 + 18; // first byte past the 16-byte APP0 segment
    const buf = try allocator.alloc(u8, orig.len + 3);
    defer allocator.free(buf);
    @memcpy(buf[0..ins_at], orig[0..ins_at]);
    buf[ins_at] = 0;
    buf[ins_at + 1] = 0;
    buf[ins_at + 2] = 0;
    @memcpy(buf[ins_at + 3 ..], orig[ins_at..]);
    buf[app0 + 2] = 0x00;
    buf[app0 + 3] = 0x13; // length 16 -> 19
    buf[app0 + 16] = 1; // Xthumbnail
    buf[app0 + 17] = 1; // Ythumbnail

    var report = try jpegz.validate(allocator, buf);
    defer report.deinit(allocator);
    try std.testing.expect(reportHasCode(report, .embedded_thumbnail_present));
}
