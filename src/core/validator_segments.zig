//! Marker-walk handlers for APPn, DHT, DQT, DAC and DNL segments.

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
const walk = @import("validator_walk.zig");
const Marker = walk.Marker;
const classifyVariant = walk.classifyVariant;
const isStandaloneMarker = walk.isStandaloneMarker;
const readU16BE = walk.readU16BE;
const addFinding = walk.addFinding;
const addExactFinding = walk.addExactFinding;
const reportSeverity = walk.reportSeverity;
const MpfTiff = walk.MpfTiff;
const startsWith = walk.startsWith;
const skipEntropyData = walk.skipEntropyData;
const blockingFail = walk.blockingFail;
const Walk = walk.Walk;
const Seg = walk.Seg;

/// Bytes after the first EOI (finding 212; owner ruling 2026-11-06 and
/// validate rules 2026-11-07). Images the MPF Index IFD places there are
/// consumed in order, as long as each starts where the previous ended: INFO
/// `mpf`. A remainder starting `PAR2\0PKT` is the owner's PAR2 trailer: INFO
/// `par2` at its start, for validate to verify. Anything else is a writer's
/// trailer, junk or fill: WARN `other` at the first uncovered byte.
pub fn reportTrailingData(report: *ValidationReport, allocator: Allocator, data: []const u8, start: usize, mpf: ?MpfTiff) Allocator.Error!void {
    var cur = start;
    if (mpf) |m| {
        var ranges: [16][2]usize = undefined;
        const n = mpfImageRanges(data, m, &ranges);
        std.mem.sortUnstable([2]usize, ranges[0..n], {}, struct {
            fn lessThan(_: void, a: [2]usize, b: [2]usize) bool {
                return a[0] < b[0];
            }
        }.lessThan);
        for (ranges[0..n]) |r| {
            if (r[0] == cur and r[1] > cur and r[1] <= data.len) cur = r[1];
        }
    }
    if (cur > start) {
        try addFinding(report, allocator, .info, .trailing_data_after_eoi, start, "mpf");
        report.findings.items[report.findings.items.len - 1].offset_is_exact = true;
    }
    if (cur == data.len) return;
    const par2 = std.mem.startsWith(u8, data[cur..], "PAR2\x00PKT");
    try addFinding(report, allocator, if (par2) .info else .warn, .trailing_data_after_eoi, cur, if (par2) "par2" else "other");
    report.findings.items[report.findings.items.len - 1].offset_is_exact = true;
}

/// The file ranges of the images an MPF Index IFD lists after the first
/// (CIPA DC-007 5.2.3: MP Entry tag 0xB002, 16 bytes per image, offsets from
/// the TIFF header; offset 0 is the file's own first image). Malformed or
/// out-of-range structures yield fewer ranges, never a read past `data`.
pub fn mpfImageRanges(data: []const u8, m: MpfTiff, out: *[16][2]usize) usize {
    const base = m.start;
    if (m.end < base + 8 or m.end > data.len) return 0;
    const tiff = data[base..m.end];
    const little = std.mem.eql(u8, tiff[0..2], "II");
    if (!little and !std.mem.eql(u8, tiff[0..2], "MM")) return 0;
    const endian: std.builtin.Endian = if (little) .little else .big;
    const ifd = std.mem.readInt(u32, tiff[4..8], endian);
    if (ifd > tiff.len or tiff.len - ifd < 2) return 0;
    const count = std.mem.readInt(u16, tiff[ifd..][0..2], endian);
    var entries_at: ?usize = null;
    var entries_len: usize = 0;
    for (0..count) |k| {
        const e = ifd + 2 + 12 * k;
        if (e + 12 > tiff.len) break;
        if (std.mem.readInt(u16, tiff[e..][0..2], endian) != 0xB002) continue;
        entries_len = std.mem.readInt(u32, tiff[e + 4 ..][0..4], endian);
        entries_at = std.mem.readInt(u32, tiff[e + 8 ..][0..4], endian);
    }
    const at = entries_at orelse return 0;
    var n: usize = 0;
    var k: usize = 0;
    while (n < out.len and k < entries_len / 16) : (k += 1) {
        const q = at + 16 * k;
        if (q > tiff.len or tiff.len - q < 16) break;
        const size = std.mem.readInt(u32, tiff[q + 4 ..][0..4], endian);
        const offset = std.mem.readInt(u32, tiff[q + 8 ..][0..4], endian);
        if (offset == 0) continue;
        const first = std.math.add(usize, base, offset) catch continue;
        const last = std.math.add(usize, first, size) catch continue;
        out[n] = .{ first, last };
        n += 1;
    }
    return n;
}

/// Known defect A2 (owner admission 2026-11-06, documented-producer path):
/// FFmpeg/Libav mjpegenc before commit b19313218c, and rtpdec_jpeg, wrote the
/// JFIF 1.02 version as the bytes 02 01. The match is exact: a JFIF APP0 with
/// those version bytes and nothing else wrong in it, meaning units 0..2,
/// nonzero densities (T.871) and a thumbnail that fills the segment exactly.
/// Any near match stays the ordinary WARN 67.
pub fn isFfmpegJfifVersion(body: []const u8) bool {
    const header_bytes: usize = 14;
    if (body.len < header_bytes or !std.mem.eql(u8, body[0..5], "JFIF\x00")) return false;
    if (body[5] != 2 or body[6] != 1 or body[7] > 2) return false;
    if (std.mem.readInt(u16, body[8..10], .big) == 0 or std.mem.readInt(u16, body[10..12], .big) == 0) return false;
    const rgb_bytes: usize = 3;
    return body.len == header_bytes + rgb_bytes * @as(usize, body[12]) * body[13];
}

/// Walk past entropy-coded scan data to the next marker. Inside an SOS,
/// any literal 0xFF in the entropy stream is escaped as 0xFF 0x00; a
/// real marker is 0xFF followed by a non-zero, non-RST byte. RST markers
/// (0xFF D0..D7) are intra-scan resets and DO continue the scan.
///
/// Map an APPn marker (0xE0..0xEF) + its segment body to a known
/// producer signature, returning the corresponding INFO `FindingCode`
/// or null if the signature is unrecognized.
///
/// Signatures are NUL-terminated identifiers at the start of the body
/// (T.81 doesn't standardize this; it's de-facto industry convention).
/// We match prefix bytes only — values inside the segment are not
/// parsed. validate's metadata pipeline handles deeper inspection.
pub fn classifyAppSignature(marker: u8, body: []const u8) ?FindingCode {
    return switch (marker) {
        // APP0 — JFIF / JFXX
        0xE0 => if (startsWith(body, "JFIF\x00") or startsWith(body, "JFXX\x00"))
            FindingCode.jfif_metadata_present
        else
            null,

        // APP1 — Exif or XMP (most common; Adobe also uses APP1)
        0xE1 => blk: {
            if (startsWith(body, "Exif\x00\x00")) break :blk FindingCode.exif_metadata_present;
            if (startsWith(body, "http://ns.adobe.com/xap/1.0/\x00"))
                break :blk FindingCode.xmp_metadata_present;
            break :blk null;
        },

        // APP2 — ICC profile
        0xE2 => if (startsWith(body, "ICC_PROFILE\x00"))
            FindingCode.icc_profile_present
        else
            null,

        // APP13 — Photoshop IRB
        0xED => if (startsWith(body, "Photoshop 3.0\x00"))
            FindingCode.photoshop_irb_present
        else
            null,

        else => null,
    };
}

pub fn onApp(w: *Walk, s: Seg) Allocator.Error!void {
    const marker_byte = s.marker_byte;
    const marker_offset = s.marker_offset;
    const seg_body_start = s.seg_body_start;
    const seg_end = s.seg_end;
    // CIPA DC-007 Multi-Picture Format: remember the first MPF APP2's TIFF
    // header, whose Index IFD locates images stored after the first EOI.
    if (marker_byte == 0xE2 and w.mpf_tiff == null and seg_end >= seg_body_start + 4 and
        std.mem.eql(u8, w.data[seg_body_start .. seg_body_start + 4], "MPF\x00"))
    {
        w.mpf_tiff = .{ .start = seg_body_start + 4, .end = seg_end };
    }
    if (marker_byte >= 0xE0 and marker_byte <= 0xEF) {
        if (classifyAppSignature(marker_byte, w.data[seg_body_start..seg_end])) |code| {
            try addFinding(&w.report, w.allocator, .info, code, marker_offset, null);
        }
        // Embedded thumbnail (T.81 JFIF Annex B / JFXX extension). A JFIF
        // APP0 with nonzero Xthumbnail×Ythumbnail carries an inline RGB
        // thumbnail; a JFXX APP0 extension is a thumbnail by definition.
        if (marker_byte == 0xE0) {
            const body = w.data[seg_body_start..seg_end];
            const jfif_header_bytes: usize = 14;
            // The approved metadata rule is edition-specific. Generic APP0,
            // incomplete headers and other versions do not establish it.
            if (body.len >= jfif_header_bytes and std.mem.eql(u8, body[0..5], "JFIF\x00") and
                body[5] == 1 and (body[6] == 1 or body[6] == 2) and body[7] > 2)
            {
                const detail = try std.fmt.allocPrint(w.allocator, "JFIF 1.{d:0>2} metadata/profile violation: units={d}; expected 0, 1 or 2", .{ body[6], body[7] });
                defer w.allocator.free(detail);
                try addExactFinding(&w.report, w.allocator, .jfif_metadata_invalid, seg_body_start + 7, detail);
            }
            if (body.len >= jfif_header_bytes and std.mem.eql(u8, body[0..5], "JFIF\x00") and
                (body[5] > 1 or (body[5] == 1 and body[6] > 2)))
            {
                // WARN class (validate, 2026-11-05): a deviation with no
                // proven violation; JFIF 1.02 is the latest version. The
                // exact FFmpeg/Libav pattern is an admitted known defect.
                const known = isFfmpegJfifVersion(body);
                const detail = if (known)
                    try w.allocator.dupe(u8, "JFIF version bytes 02 01: the byte-swapped 1.02 that FFmpeg/Libav mjpegenc (before b19313218c) and rtpdec_jpeg write; admitted known defect")
                else
                    try std.fmt.allocPrint(w.allocator, "JFIF version {d}.{d:0>2}: not in the claimed spec version (latest is 1.02); metadata semantics are unchecked", .{ body[5], body[6] });
                defer w.allocator.free(detail);
                try addFinding(&w.report, w.allocator, if (known) .known_defect else .warn, .jfif_version_unchecked, seg_body_start + (if (body[5] > 1) @as(usize, 5) else 6), detail);
                w.report.findings.items[w.report.findings.items.len - 1].offset_is_exact = true;
            }
            if (body.len >= 14 and std.mem.eql(u8, body[0..5], "JFIF\x00")) {
                if (body[12] != 0 and body[13] != 0)
                    try addFinding(&w.report, w.allocator, .info, .embedded_thumbnail_present, marker_offset, "JFIF APP0 carries an embedded thumbnail");
            } else if (body.len >= 5 and std.mem.eql(u8, body[0..5], "JFXX\x00")) {
                try addFinding(&w.report, w.allocator, .info, .embedded_thumbnail_present, marker_offset, "JFXX APP0 extension thumbnail present");
            }
        }
    }
}

pub fn onDht(w: *Walk, s: Seg) Allocator.Error!void {
    const seg_body_start = s.seg_body_start;
    const seg_end = s.seg_end;
    w.seen_dht = true;
    try w.dht_segments.append(w.allocator, .{ seg_body_start, seg_end });
    const bits_bytes: usize = 16;
    var hp: usize = seg_body_start;
    while (hp + 1 + bits_bytes <= seg_end) {
        const bits = w.data[hp + 1 ..][0..bits_bytes].*;
        var total: usize = 0;
        for (bits) |count| total += count;
        // Validate 2026-11-22: BITS counts that overrun the segment are 51,
        // exact at the count byte where the symbols stop fitting.
        const room = seg_end - (hp + 1 + bits_bytes);
        if (total > room) {
            var running: usize = 0;
            const at = for (bits, 0..) |count, i| {
                running += count;
                if (running > room) break hp + 1 + i;
            } else unreachable;
            const detail = try std.fmt.allocPrint(w.allocator, "DHT Tc={d} Th={d}: BITS counts {d} symbols but only {d} bytes remain in the segment", .{ w.data[hp] >> 4, w.data[hp] & 0x0F, total, room });
            defer w.allocator.free(detail);
            try addExactFinding(&w.report, w.allocator, .huffman_table_corrupt, at, detail);
            // Declared, though corrupt: not also a missing table (69).
            if (w.data[hp] >> 4 <= 1 and w.data[hp] & 0x0F <= 3) w.dht_defined[w.data[hp] >> 4][w.data[hp] & 0x0F] = true;
            break;
        }
        if (w.data[hp] >> 4 <= 1 and w.data[hp] & 0x0F <= 3) w.dht_defined[w.data[hp] >> 4][w.data[hp] & 0x0F] = true;
        switch (huffman.codeSpace(bits)) {
            .full_all_ones => |length| {
                const detail = try std.fmt.allocPrint(w.allocator, "DHT Tc={d} Th={d}: code space exactly full at length {d}, so its last code is the reserved all-ones codeword (Pentax, Ricoh and DJI DNG encoders); admitted known defect", .{ w.data[hp] >> 4, w.data[hp] & 0x0F, length });
                defer w.allocator.free(detail);
                // Exact: the BITS count for the length that fills the space.
                try addFinding(&w.report, w.allocator, .known_defect, .huffman_table_full_all_ones, hp + length, detail);
                w.report.findings.items[w.report.findings.items.len - 1].offset_is_exact = true;
            },
            .valid, .invalid => {},
        }
        hp += 1 + bits_bytes + total;
    } else if (hp < seg_end) {
        try addExactFinding(&w.report, w.allocator, .huffman_table_corrupt, hp, "DHT segment ends inside a table's Tc/Th and BITS header");
    }
}

pub fn onDqt(w: *Walk, s: Seg) Allocator.Error!void {
    const seg_body_start = s.seg_body_start;
    const seg_end = s.seg_end;
    var qp: usize = seg_body_start;
    while (qp < seg_end) {
        const pqtq = w.data[qp];
        const pq = pqtq >> 4;
        const tq = pqtq & 0x0F;
        if (pq > 1 or tq > 3) {
            try addFinding(&w.report, w.allocator, .fail, .quantization_table_corrupt, qp, "DQT Pq must be 0 or 1 and Tq must be 0..3");
            break; // table size is ambiguous once Pq is invalid
        }
        const elements_per_table: usize = 64;
        const element_bytes = @as(usize, pq) + 1;
        const table_bytes = 1 + elements_per_table * element_bytes;
        // A partial table cannot borrow coefficient bytes from the next segment.
        if (table_bytes > seg_end - qp) break;
        for (0..elements_per_table) |index| {
            const offset = qp + 1 + index * element_bytes;
            const zero = w.data[offset] == 0 and (pq == 0 or w.data[offset + 1] == 0);
            if (zero) try addExactFinding(&w.report, w.allocator, .quantization_table_corrupt, offset, "DQT quantization element Qk must be nonzero");
        }
        qp += table_bytes;
    }
}

pub fn onDac(w: *Walk, s: Seg) Allocator.Error!void {
    const seg_body_start = s.seg_body_start;
    const seg_end = s.seg_end;
    var dp: usize = seg_body_start;
    while (dp + 1 < seg_end) : (dp += 2) {
        const tctb = w.data[dp];
        const cs = w.data[dp + 1];
        if ((tctb >> 4) > 1 or (tctb & 0x0F) > 3) {
            try addExactFinding(&w.report, w.allocator, .arithmetic_table_corrupt, dp, "DAC Tc must be 0 or 1 and Tb must be 0..3");
            break;
        }
        if (tctb >> 4 == 0 and cs & 0x0F > cs >> 4) {
            var dbuf: [80]u8 = undefined;
            try addExactFinding(&w.report, w.allocator, .arithmetic_table_corrupt, dp + 1, std.fmt.bufPrint(&dbuf, "DAC DC conditioning needs L <= U; got L={d} U={d}", .{ cs & 0x0F, cs >> 4 }) catch "DAC DC conditioning needs L <= U");
            break;
        }
        if (tctb >> 4 == 1 and (cs < 1 or cs > 63)) {
            var dbuf: [64]u8 = undefined;
            try addExactFinding(&w.report, w.allocator, .arithmetic_table_corrupt, dp + 1, std.fmt.bufPrint(&dbuf, "DAC AC Kx must be 1..63; got {d}", .{cs}) catch "DAC AC Kx must be 1..63");
            break;
        }
    }
}

pub fn onDnl(w: *Walk, s: Seg) Allocator.Error!void {
    const marker_offset = s.marker_offset;
    const seg_len = s.seg_len;
    const seg_body_start = s.seg_body_start;
    const pos = s.pos;
    const right_after_first_scan = s.right_after_first_scan;
    if (seg_len != 4) {
        try addFinding(&w.report, w.allocator, .fail, .bad_marker_length, pos, "DNL segment length must be 4");
    } else {
        const lines = readU16BE(w.data, seg_body_start);
        const proper = w.frame_declared_y == @as(u16, 0) and right_after_first_scan and w.frame_dnls == 0;
        if (!proper) {
            const token: []const u8 = if ((w.frame_declared_y orelse 0) != 0)
                "with_nonzero_y"
            else if (w.frame_dnls > 0)
                "repeated"
            else if (w.frame_scans == 0)
                "before_first_scan"
            else
                "after_later_scan";
            // FAIL only when two declared line counts conflict.
            const severity: Severity = if (w.frame_lines) |declared| (if (declared == lines) .warn else .fail) else .warn;
            const detail = try std.fmt.allocPrint(w.allocator, "{s}: DNL NL={d} outside the slot T.81 B.2.5 allows (right after the first scan of a Y=0 frame)", .{ token, lines });
            defer w.allocator.free(detail);
            try addFinding(&w.report, w.allocator, severity, .dnl_misplaced, marker_offset, detail);
            w.report.findings.items[w.report.findings.items.len - 1].offset_is_exact = true;
            if (severity == .fail) w.nonblocking_fails += 1;
        }
        w.frame_dnls += 1;
    }
}
