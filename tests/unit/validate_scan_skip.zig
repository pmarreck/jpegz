//! Progressive scans with invalid headers (owner, 2026-11-28: "If it is
//! possible to record an error and try to parse past it, I think we should.
//! The more information about a file, the better."). The marker walk records
//! the header fault; the codec check skips that scan and judges the rest. A
//! later AC refinement of coefficients the skipped scan sets cannot be
//! decoded in step (its bit count depends on them), so it is skipped too and
//! reported as not judged (INFO). Plain decodes keep failing at the scan.

const std = @import("std");
const jpegz = @import("jpegz");

const not_judged = "scan not judged: it refines coefficients that a skipped invalid scan sets";

/// SOS marker offsets in file order. A stuffed entropy byte is never
/// followed by 0xDA, so a plain search finds exactly the markers.
fn sosOffsets(data: []const u8, out: []usize) usize {
    var n: usize = 0;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, data, from, &.{ 0xff, 0xda })) |at| : (from = at + 2) {
        out[n] = at;
        n += 1;
    }
    return n;
}

fn countSeverity(report: jpegz.ValidationReport, severity: jpegz.Severity) usize {
    var n: usize = 0;
    for (report.findings.items) |f| n += @intFromBool(f.severity == severity);
    return n;
}

/// One INFO not-judged finding, exact at each of `at`, and no other.
fn expectNotJudged(report: jpegz.ValidationReport, at: []const usize) !void {
    var seen: usize = 0;
    for (report.findings.items) |f| {
        if (f.code != .unknown_marker) continue;
        try std.testing.expectEqual(jpegz.Severity.info, f.severity);
        try std.testing.expect(f.offset_is_exact);
        try std.testing.expectEqualStrings(not_judged, f.detail.?);
        try std.testing.expect(std.mem.indexOfScalar(usize, at, @intCast(f.offset.?)) != null);
        seen += 1;
    }
    try std.testing.expectEqual(at.len, seen);
}

fn expectFinding(report: jpegz.ValidationReport, code: jpegz.FindingCode, severity: jpegz.Severity, at: usize) !void {
    for (report.findings.items) |f| {
        if (f.code == code and f.severity == severity and f.offset == at and f.offset_is_exact) return;
    }
    for (report.findings.items) |f| std.debug.print("  got {t} {t} @{?d}\n", .{ f.severity, f.code, f.offset });
    std.debug.print("expected {t} {t} @{d}\n", .{ severity, code, at });
    return error.TestExpectedFinding;
}

/// A fixture and one single-byte entropy fault in a scan after scan 4 that
/// refines nothing scan 4 sets (found by mutation; see the commit).
const Fixture = struct { name: []const u8, data: []const u8, pin_scan: usize, entropy_pin: usize, pin_xor: u8, pin_code: jpegz.FindingCode, pin_at: usize };

test "an invalid progressive scan header is recorded, the scan skipped, and the rest of the file judged" {
    const allocator = std.testing.allocator;
    // Both fixtures code ten scans in the same order: DC first; Y 1..5;
    // Cr 1..63; Cb 1..63; Y 6..63; Y 1..63 refining; DC refining; Cr, Cb and
    // Y 1..63 refining.
    for ([_]Fixture{
        .{ .name = "Huffman", .data = @embedFile("fixtures/huffman_restart_32x32_rgb420_progressive_1b.jpg"), .pin_scan = 7, .entropy_pin = 726, .pin_xor = 0x01, .pin_code = .entropy_padding_not_ones, .pin_at = 726 },
        .{ .name = "arithmetic", .data = @embedFile("fixtures/arith_restart_32x32_rgb420_progressive_1b.jpg"), .pin_scan = 8, .entropy_pin = 611, .pin_xor = 0x01, .pin_code = .extraneous_bytes_before_marker, .pin_at = 614 },
    }) |fx| {
        errdefer std.debug.print("fixture {s}\n", .{fx.name});
        var sos: [16]usize = undefined;
        try std.testing.expectEqual(@as(usize, 10), sosOffsets(fx.data, &sos));
        // Scan 4 (Y 6..63) names AC table 5, which T.81 Table B.3 does not
        // define: FAIL 75 at its Td/Ta byte.
        const tdta = sos[4] + 6;
        try std.testing.expectEqual(@as(u8, 0x00), fx.data[tdta]);
        const bad_header = try allocator.dupe(u8, fx.data);
        defer allocator.free(bad_header);
        bad_header[tdta] = 0x05;

        var report = try jpegz.validate(allocator, bad_header);
        defer report.deinit(allocator);
        try expectFinding(report, .sos_table_selector_invalid, .fail, tdta);
        try std.testing.expectEqual(@as(usize, 1), countSeverity(report, .fail));
        // The two Y refinements over 1..63 (scans 5 and 9) refine what scan 4
        // sets; the DC, Cr and Cb refinements are judged.
        try expectNotJudged(report, &.{ sos[5], sos[9] });
        try std.testing.expect(report.codec_check == .decoded);

        // Entropy damage in a later scan (the Cr or Cb refinement) is found
        // exactly where it is found without the header fault.
        const both = try allocator.dupe(u8, bad_header);
        defer allocator.free(both);
        // Entropy starts after the 10-byte one-component SOS segment.
        try std.testing.expect(fx.entropy_pin >= sos[fx.pin_scan] + 10 and fx.entropy_pin < sos[fx.pin_scan + 1]);
        both[fx.entropy_pin] ^= fx.pin_xor;
        const pin_only = try allocator.dupe(u8, fx.data);
        defer allocator.free(pin_only);
        pin_only[fx.entropy_pin] ^= fx.pin_xor;
        var pin_report = try jpegz.validate(allocator, pin_only);
        defer pin_report.deinit(allocator);
        try expectFinding(pin_report, fx.pin_code, .fail, fx.pin_at);
        var both_report = try jpegz.validate(allocator, both);
        defer both_report.deinit(allocator);
        try expectFinding(both_report, .sos_table_selector_invalid, .fail, tdta);
        try expectFinding(both_report, fx.pin_code, .fail, fx.pin_at);
        try expectNotJudged(both_report, &.{ sos[5], sos[9] });

        // A plain decode still stops at the invalid scan.
        try std.testing.expectError(error.InvalidMarker, jpegz.decode(allocator, bad_header));
        try std.testing.expectError(error.InvalidMarker, jpegz.decodeWithOptions(allocator, bad_header, .{ .lenient = true }));
    }
}

test "a progressive SOS length other than 6 + 2*Ns leaves every later AC refinement unjudged" {
    // A length past the real header makes the marker walk, and the codec
    // check after it, resume beyond the next scans, which are never seen.
    // Whatever they set is unknown, so no later AC refinement is decoded:
    // decoding one in step with coefficients it cannot see reported a false
    // entropy fault. (Single-byte mutant from the 5,000-file sweep.)
    const allocator = std.testing.allocator;
    const fixture = @embedFile("fixtures/progressive_16x16_rgb12_440.jpg");
    var sos: [16]usize = undefined;
    try std.testing.expectEqual(@as(usize, 10), sosOffsets(fixture, &sos));
    // Scan 5 (Y 1..63 refining) declares Ls = 121 instead of 8: the walk
    // resumes at scan 8, past the DC and Cr refinements.
    try std.testing.expectEqual(@as(u8, 8), fixture[sos[5] + 3]);
    const data = try allocator.dupe(u8, fixture);
    defer allocator.free(data);
    data[sos[5] + 3] = 0x79;
    var report = try jpegz.validate(allocator, data);
    defer report.deinit(allocator);
    try expectFinding(report, .bad_marker_length, .fail, sos[5] + 2);
    try std.testing.expectEqual(@as(usize, 1), countSeverity(report, .fail));
    try expectNotJudged(report, &.{ sos[8], sos[9] });
}
