//! Hand-written JPEG marker-chain walker for `jpegz.validate`. Pure
//! Zig (no FFI). Designed to be the start of the Phase-2 cleanroom
//! parser: as the cleanroom decoder lands codec-by-codec, this module
//! will share its marker-parse machinery.
//!
//! Behavior contract (from the design doc):
//!   - Returns Zig error only on OOM; structural problems are findings.
//!   - Does NOT fail-fast — accumulates every finding it can detect
//!     before returning.
//!   - Sets `Variant` from SOF marker even when `overall == .fail` so
//!     consumers know what was being attempted.
//!
//! Layout: this file runs the walk. Its state (`Walk`) and shared helpers are
//! in validator_walk.zig. Segment handlers are in validator_segments.zig
//! (APPn, DHT, DQT, DAC, DNL), validator_sof.zig and validator_sos.zig. The
//! checks after the walk, including the codec check, are in
//! validator_post.zig.

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
const segments = @import("validator_segments.zig");
const sof = @import("validator_sof.zig");
const sos = @import("validator_sos.zig");
const post = @import("validator_post.zig");
const reportTrailingData = segments.reportTrailingData;
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

pub fn validate(allocator: Allocator, data: []const u8) Allocator.Error!ValidationReport {
    var report = ValidationReport{
        .overall = .pass,
        .variant = .unknown,
        .width = null,
        .height = null,
        .findings = .empty,
    };

    // ── Step 1: SOI check ──────────────────────────────────────
    if (data.len < 2 or data[0] != 0xFF or data[1] != 0xD8) {
        errdefer report.deinit(allocator);
        try addFinding(&report, allocator, .fail, .missing_soi, 0, "JPEG must start with SOI marker (0xFF 0xD8)");
        return report;
    }

    // The walk owns the (still empty) report from here on.
    var w = Walk{ .data = data, .allocator = allocator, .report = report };
    errdefer w.report.deinit(allocator);
    defer w.dht_segments.deinit(allocator);
    var pos: usize = 2;

    // ── Step 2: Walk markers ──────────────────────────────────
    while (pos < data.len) {
        // Each marker starts with one or more 0xFF fill bytes.
        if (data[pos] != 0xFF) {
            try addFinding(&w.report, allocator, .fail, .bad_marker_length, pos, "expected 0xFF at marker start");
            return w.report;
        }
        // Skip fill bytes (0xFF padding).
        while (pos < data.len and data[pos] == 0xFF) pos += 1;
        if (pos >= data.len) {
            try addFinding(&w.report, allocator, .fail, .truncated_stream, data.len, "stream ended at marker prefix");
            return w.report;
        }

        const marker_byte = data[pos];
        const marker_offset = pos - 1; // include the 0xFF
        pos += 1;
        const right_after_first_scan = w.at_first_scan_end;
        w.at_first_scan_end = false;
        // T.81 B.1.1.2 excludes zero as a marker byte. Entropy stuffing
        // and opaque APP payloads are consumed separately below.
        if (marker_byte == 0) {
            try addExactFinding(&w.report, allocator, .unknown_marker, marker_offset + 1, "zero marker byte outside entropy is forbidden by T.81 B.1.1.2");
            return w.report;
        }
        // Reserved semantics cannot be established by decoding around them.
        if (marker_byte >= 0x02 and marker_byte <= 0xbf) {
            // FAIL class (validate, 2026-11-05): no specified decode, damage
            // produces it and no writer is known.
            const detail = try std.fmt.allocPrint(allocator, "reserved JPEG marker FF{X:0>2}; marker semantics are not checked", .{marker_byte});
            defer allocator.free(detail);
            try addExactFinding(&w.report, allocator, .unknown_marker, marker_offset + 1, detail);
            w.nonblocking_fails += 1;
        }
        if (marker_byte == 0xde and !w.seen_sof) w.hierarchical = true;

        // ── Standalone markers (no length) ─────────────────────
        if (isStandaloneMarker(marker_byte)) {
            if (marker_byte == Marker.EOI) {
                w.seen_eoi = true;
                // pos already moved past the 0xFF and marker byte;
                // anything beyond pos is "trailing" data.
                if (pos < data.len) try reportTrailingData(&w.report, allocator, data, pos, w.mpf_tiff);
                break;
            }
            // SOI inside the stream (after position 0) is suspicious but
            // not required to fail — some embedded thumbnails carry one.
            // RST/TEM are no-op here.
            continue;
        }

        // ── Length-prefixed segment ────────────────────────────
        if (pos + 2 > data.len) {
            try addFinding(&w.report, allocator, .fail, .truncated_stream, pos, "stream ended before segment length");
            return w.report;
        }
        const seg_len = readU16BE(data, pos);
        if (seg_len < 2) {
            try addFinding(&w.report, allocator, .fail, .bad_marker_length, pos, "segment length must be >= 2");
            return w.report;
        }
        const seg_body_start = pos + 2;
        const seg_end = pos + seg_len; // length includes the 2 length bytes themselves
        if (seg_end > data.len) {
            try addFinding(&w.report, allocator, .fail, .truncated_stream, seg_end, "segment extends past end of stream");
            return w.report;
        }

        // ── APPn signature scan (M1.5c — validate handoff) ────
        // APPn markers (0xE0..0xEF) carry application-specific
        // payloads. The first few bytes of the body are a signature
        // that identifies the producer. Surface known producers as
        // INFO findings so validate / metadata pipelines don't have
        // to walk markers a second time. Body bounds are seg_body_start
        // to seg_end; the segment-length check above guarantees safety.
        const seg = Seg{ .marker_byte = marker_byte, .marker_offset = marker_offset, .seg_len = seg_len, .seg_body_start = seg_body_start, .seg_end = seg_end, .pos = pos, .right_after_first_scan = right_after_first_scan };
        try segments.onApp(&w, seg);
        if (marker_byte == Marker.DHT) try segments.onDht(&w, seg);
        if (marker_byte == Marker.DQT) try segments.onDqt(&w, seg);
        if (marker_byte == Marker.DAC) try segments.onDac(&w, seg);
        if (classifyVariant(marker_byte)) |variant| {
            try sof.onSof(&w, seg, variant);
        } else if (marker_byte == Marker.SOS) {
            try sos.onSos(&w, seg);
            // Entropy-coded data follows. Skip until we hit a non-RST,
            // non-padding marker (likely EOI, but could be another SOS
            // for progressive/multi-scan sequences).
            pos = seg_end;
            const new_pos = skipEntropyData(data, pos, w.report.variant == .jpegls);
            // If skipEntropyData reaches end without finding any marker,
            // surface as truncation. We treat "ran off the end" as the
            // entropy stream not being terminated by EOI (or a follow-on
            // marker), which is `truncated_stream`.
            if (new_pos == null) {
                try addFinding(&w.report, allocator, .fail, .truncated_stream, data.len, "SOS entropy data not terminated by a marker");
                return w.report;
            }
            pos = new_pos.?;
            w.at_first_scan_end = w.frame_scans == 1;
            continue;
        }

        if (marker_byte == 0xdc and !w.hierarchical) try segments.onDnl(&w, seg);

        pos = seg_end;
    }

    try post.finish(&w);
    return w.report;
}
