//! Walker state and shared helpers for `validator.zig` (the JPEG marker
//! walk behind `jpegz.validate`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const errors = @import("errors.zig");
const huffman = @import("../decode/huffman.zig");
const baseline = @import("../decode/baseline.zig");
const jpeg_markers = @import("../decode/jpeg_markers.zig");
const jpegls = @import("../decode/jpegls.zig");
const types = @import("../jpegz.zig");

const Severity = errors.Severity;
const Variant = errors.Variant;
const FindingCode = errors.FindingCode;
const Finding = types.Finding;
const ValidationReport = types.ValidationReport;

/// Marker constants we care about (T.81 Table B.1 + JPEG-LS).
pub const Marker = struct {
    pub const SOI: u8 = 0xD8;
    pub const EOI: u8 = 0xD9;
    pub const SOS: u8 = 0xDA;
    pub const DHT: u8 = 0xC4;
    pub const DAC: u8 = 0xCC; // arithmetic conditioning
    pub const DQT: u8 = 0xDB;
    // SOF markers — see classifyVariant.
    pub const RST0: u8 = 0xD0;
    pub const RST7: u8 = 0xD7;
    pub const TEM: u8 = 0x01;
};

/// Map a SOFn marker byte to the corresponding Variant.
/// Returns null for non-SOF markers.
pub fn classifyVariant(byte: u8) ?Variant {
    return switch (byte) {
        0xC0 => .baseline_huffman, // SOF0
        0xC1 => .extended_huffman, // SOF1
        0xC2 => .progressive_huffman, // SOF2
        0xC3 => .lossless_huffman, // SOF3
        0xC5, 0xC6, 0xC7 => .unknown, // SOF5/6/7 — differential huffman, treat as unknown
        // SOF8 (0xC8) is JPG (reserved); skip.
        0xC9 => .baseline_arithmetic, // SOF9
        0xCA => .progressive_arithmetic, // SOF10
        0xCB => .lossless_arithmetic, // SOF11
        0xCD, 0xCE, 0xCF => .unknown, // SOF13/14/15 — differential arithmetic
        0xF7 => .jpegls, // SOF55 (T.87)
        else => null,
    };
}

/// True if a marker byte has NO length field (standalone). T.81 B.1.1.3.
pub fn isStandaloneMarker(byte: u8) bool {
    return byte == Marker.SOI or byte == Marker.EOI or byte == Marker.TEM or (byte >= Marker.RST0 and byte <= Marker.RST7);
}

/// Big-endian u16 read; assumes data has at least 2 bytes from `at`.
pub fn readU16BE(data: []const u8, at: usize) u16 {
    return (@as(u16, data[at]) << 8) | @as(u16, data[at + 1]);
}

/// Add a finding to the report, allocating the optional detail string
/// from the report's allocator. Detail lifetime is tied to the report.
pub fn addFinding(
    report: *ValidationReport,
    allocator: Allocator,
    severity: Severity,
    code: FindingCode,
    offset: ?u64,
    detail: ?[]const u8,
) Allocator.Error!void {
    const stored_detail: ?[]const u8 = if (detail) |d|
        try allocator.dupe(u8, d)
    else
        null;
    errdefer if (stored_detail) |s| allocator.free(s);

    try report.findings.append(allocator, .{
        .severity = severity,
        .code = code,
        .offset = offset,
        .detail = stored_detail,
    });

    // Promote `overall` if this finding is more severe.
    if (severity.rank() > report.overall.rank()) {
        report.overall = severity;
    }
}

/// Mark a structurally identified header byte without claiming an EOF cursor
/// or an entropy decoder's later detection position is the damaged byte.
pub fn addExactFinding(report: *ValidationReport, allocator: Allocator, code: FindingCode, offset: usize, detail: []const u8) Allocator.Error!void {
    try addFinding(report, allocator, .fail, code, @intCast(offset), detail);
    report.findings.items[report.findings.items.len - 1].offset_is_exact = true;
}

/// Validation class of a codec finding, assigned when the report takes it from
/// the decoder (validate TERMINOLOGY A2 as rewritten 2026-11-05; approved rows
/// in docs/plan_context/severity-audit-2026-11-05.md). The decoder still
/// reports what it recovered from at its own severity; only the class in the
/// report changes, so detection and decoder control flow are untouched.
pub fn reportSeverity(code: FindingCode, emitted: Severity) Severity {
    return switch (code) {
        // Recovered damage: readers fill or resync, which hides the loss.
        .insufficient_data, .restart_marker_missing, .restart_marker_unexpected => .fail,
        // T.81 B.1.1.2 permits 0xFF fill before any marker: an observation.
        .entropy_fill_bytes => .info,
        else => emitted,
    };
}

pub const MpfTiff = struct { start: usize, end: usize };

pub fn startsWith(haystack: []const u8, prefix: []const u8) bool {
    return haystack.len >= prefix.len and std.mem.eql(u8, haystack[0..prefix.len], prefix);
}

/// Returns the byte offset of the 0xFF that begins the next "real"
/// marker (so the outer parser can re-enter its 0xFF-handling loop).
/// Returns null if the stream ends without a terminating marker.
/// `bit_stuffed` (JPEG-LS): T.87 A.1.3 bit-stuffs instead of byte-stuffing, so an FF
/// followed by a byte below 0x80 is entropy data, not a marker.
pub fn skipEntropyData(data: []const u8, start: usize, bit_stuffed: bool) ?usize {
    var i = start;
    while (i < data.len) {
        if (data[i] != 0xFF) {
            i += 1;
            continue;
        }
        // 0xFF: peek next byte (skipping fill 0xFFs).
        var j = i + 1;
        while (j < data.len and data[j] == 0xFF) j += 1;
        if (j >= data.len) return null;
        const next = data[j];
        if (bit_stuffed and j == i + 1 and next < 0x80) {
            i = j + 1;
            continue;
        }
        if (next == 0x00) {
            // 0xFF 0x00 = stuffed literal, continues entropy data.
            i = j + 1;
            continue;
        }
        if (next >= Marker.RST0 and next <= Marker.RST7) {
            // Restart marker, scan continues.
            i = j + 1;
            continue;
        }
        // Real marker — return position of the 0xFF (so outer loop
        // re-enters at the marker prefix).
        return i;
    }
    return null;
}

/// True when a FAIL finding other than the reclassified non-blocking ones is
/// present: the codec check would only rediscover a structural fault.
pub fn blockingFail(report: *const ValidationReport, nonblocking_fails: usize) bool {
    return failCount(report) > nonblocking_fails;
}

/// Number of FAIL findings in the report.
pub fn failCount(report: *const ValidationReport) usize {
    var fails: usize = 0;
    for (report.findings.items) |finding| {
        if (finding.severity == .fail) fails += 1;
    }
    return fails;
}

/// State of one marker walk, shared by the segment handlers.
pub const Walk = struct {
    data: []const u8,
    allocator: Allocator,
    report: ValidationReport,
    seen_sof: bool = false,
    sof_offset: ?u64 = null,
    seen_sos: bool = false,
    seen_eoi: bool = false,
    // Membership bitmap of component IDs (Ci) declared by the SOF, used
    // to validate SOS component selectors (Cs) cross-segment.
    sof_comp_ids: [256]bool = [_]bool{false} ** 256,
    // Packed Hi/Vi sampling byte per declared component ID, for the MCU check.
    sof_comp_hv: [256]u8 = [_]u8{0} ** 256,
    sof_component_count: u8 = 0,
    // Finding 70's WARN frame: four components with IDs exactly (1, 2, 3, 1).
    sof_k_id_one: bool = false,
    // Se byte of a sequential scan matching finding 68's Go signature; judged
    // after the walk, when the number of scans is known.
    go_zero_se: ?usize = null,
    // The first MPF APP2's TIFF header and segment end (finding 212).
    mpf_tiff: ?MpfTiff = null,
    // Finding 69: Huffman table destinations defined so far ([Tc][Th]), the
    // first scan, and the first Td/Ta byte naming a table not yet defined.
    dht_defined: [2][4]bool = [2][4]bool{ .{ false, false, false, false }, .{ false, false, false, false } },
    seen_dht: bool = false,
    // DHT bodies, judged after the walk against the frame precision (a DHT
    // may precede the SOF).
    dht_segments: std.ArrayList([2]usize) = .empty,
    frame_precision: ?u8 = null,
    // Progressive scan history (validate rulings I, 2026-11-23): per component
    // selector and coefficient, the Al of the last scan that coded it (-1: none).
    coef_al: [256][64]i8 = [_][64]i8{[_]i8{-1} ** 64} ** 256,
    // One root cause, one record (as rulings H): history is not judged after
    // a scan whose parameters are not established, or after the first
    // history fault, since later scans would only repeat the consequence.
    history_known: bool = true,
    first_sos_offset: ?usize = null,
    first_missing_table: ?usize = null,
    /// Number of SOS (scan) markers seen.
    sos_count: u32 = 0,
    // T.81 Annex J: a DHP before the first frame makes the stream hierarchical,
    // where several frames are legal and later ones are differential.
    hierarchical: bool = false,
    frame_differential: bool = false,
    // Finding 72 (T.81 B.2.5): DNL placement, judged against the first frame.
    // frame_lines is Y when nonzero, else the NL of the DNL right after the
    // first scan; null while no count is declared.
    frame_declared_y: ?u16 = null,
    frame_lines: ?u16 = null,
    frame_scans: u32 = 0,
    frame_dnls: u32 = 0,
    at_first_scan_end: bool = false,
    // FAIL findings that do not stop the codec check or the EOI check. They
    // were WARN before 2026-11-05; reclassifying them must not drop findings.
    nonblocking_fails: usize = 0,
    // SOS marker offsets of progressive scans whose headers drew a FAIL. The
    // codec check decodes past them (owner, 2026-11-28: record the error and
    // parse past it), so their FAILs do not block it.
    skip_scans: std.ArrayList(u64) = .empty,
};

/// The segment being handled: its marker and body bounds.
pub const Seg = struct {
    marker_byte: u8,
    marker_offset: usize,
    seg_len: u16,
    seg_body_start: usize,
    seg_end: usize,
    pos: usize,
    right_after_first_scan: bool,
};
