//! Checks run after the marker walk, including the codec check.

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
const checkSequentialScanField = @import("validator_sos.zig").checkSequentialScanField;

pub fn checkCodec(allocator: Allocator, data: []const u8, variant: Variant, sink: *types.FindingsSink) errors.DecodeError!void {
    if (variant == .lossless_huffman) return @import("../decode/lossless.zig").validate(data, sink);
    // Straight to the JPEG-LS decoder: the general dispatcher would fall
    // through an unsupported JPEG-LS scan into the T.81 decoders.
    if (variant == .jpegls) {
        // Subsampled planes are decoded and checked, then discarded.
        var planes: [4]?types.Image = .{ null, null, null, null };
        defer for (&planes) |*plane| if (plane.*) |*image| image.deinit(allocator);
        var image = try @import("../decode/jpegls.zig").decodeWithOptions(allocator, data, .{ .findings_sink = sink, .map_samples = false, .planes = &planes });
        image.deinit(allocator);
        return;
    }
    var image = try types.decodeWithOptions(allocator, data, .{ .lenient = true, .findings_sink = sink });
    image.deinit(allocator);
}

/// Map a public `DecodeError` from the codec-integrity decode-through
/// to the closest `FindingCode` for validator output.
///
/// Bucketing rationale: the marker walker (validator step 1-3)
/// already catches genuine `bad_marker_length` / `missing_soi` /
/// real `truncated_stream` (data ends mid-segment) BEFORE the codec
/// check runs. Any decoder error that surfaces here means structural
/// scaffolding was sound but coefficient-level / table-level decode
/// failed — bucket everything as `huffman_table_corrupt` (the most
/// common cause) unless we have a more specific signal.
pub fn mapDecodeErrorToFindingCode(err: errors.DecodeError) FindingCode {
    return switch (err) {
        // DHT/DQT/DAC malformed internal data, bitstream desync from
        // corrupt tables, etc. — all bucket as huffman_table_corrupt.
        error.InvalidMarker => .huffman_table_corrupt,
        error.BackendError => .huffman_table_corrupt,
        error.TruncatedStream => .huffman_table_corrupt,

        error.UnsupportedPrecision => .invalid_sof_precision,
        error.InvalidJp2Codestream => .jp2_invalid_codestream,

        // NotRowStreamable / CallbackAborted shouldn't surface in
        // validate's path (we don't stream rows); bucket them as
        // unknown_marker if they ever do.
        error.NotRowStreamable, error.CallbackAborted => .unknown_marker,
        error.NotImplemented, error.OutOfMemory => unreachable,
    };
}

/// JPEG-LS and arithmetic-coded decode errors with no typed finding (validate,
/// 2026-11-21 and 2026-11-22: never `huffman_table_corrupt`). Entropy faults
/// arrive typed (JPEG-LS: 120, 122, 56, 57 and 121 for LSE values;
/// arithmetic: 8, 56, 57, 58 and 74), so the remaining errors come from
/// segment content the marker walk does not parse. Exhaustive: a new
/// DecodeError does not compile until it is classified here.
pub fn mapTypedCodecError(err: errors.DecodeError) FindingCode {
    return switch (err) {
        error.TruncatedStream => .truncated_stream,
        error.InvalidMarker => .bad_marker_length,
        error.UnsupportedPrecision => .invalid_sof_precision,
        // Only reachable if a fault skipped its typed finding: flag it as
        // unclassified rather than guess a codec code.
        error.BackendError, error.InvalidJp2Codestream, error.NotRowStreamable, error.CallbackAborted => .unknown_marker,
        error.NotImplemented, error.OutOfMemory => unreachable,
    };
}

/// libjpeg-turbo handles SOF0/1/2/3/9/10/11. JPEG-LS, differential
/// variants, and JPEG 2000 don't reach this validator (JP2 has its
/// own path); skip the decode-through if the marker walker thinks the
/// variant is something else, otherwise libjpeg would just emit
/// "Unsupported JPEG process" and we'd add a redundant finding.
pub fn shouldRunCodecCheck(variant: Variant) bool {
    return switch (variant) {
        .baseline_huffman,
        .extended_huffman,
        .progressive_huffman,
        .lossless_huffman,
        .baseline_arithmetic,
        .progressive_arithmetic,
        .lossless_arithmetic,
        // The Zig JPEG-LS decoder reports its faults (validate, 2026-11-21).
        .jpegls,
        => true,
        // jpeg_xl never reaches this walker either — `validateAny` routes it
        // to libjxlz before any T.81 marker parsing happens.
        .unknown, .jpeg2000, .jpeg_xl => false,
    };
}

/// Checks judged after the walk: scan-count findings, Huffman table bounds,
/// the codec check and the missing-table findings.
pub fn finish(w: *Walk) Allocator.Error!void {
    // ── Step 3: After-loop sanity ──────────────────────────────
    // Known defect 68 only when that scan was the frame's only scan; in a
    // multi-scan file the same bytes are an ordinary FAIL 64.
    if (w.go_zero_se) |se_offset| {
        if (w.sos_count == 1) {
            try addFinding(&w.report, w.allocator, .known_defect, .sequential_scan_zero_se, se_offset, "sequential SOS Ss=0 Se=0 Ah=Al=0 in the only scan: Go image/jpeg before 5f7bec69; admitted known defect");
            w.report.findings.items[w.report.findings.items.len - 1].offset_is_exact = true;
        } else {
            try checkSequentialScanField(&w.report, w.allocator, se_offset, "Se", 0, 63);
        }
    }

    if (!w.seen_sof) {
        try addFinding(&w.report, w.allocator, .fail, .duplicate_sof, null, "no SOF marker found");
    }
    if (!w.seen_sos) {
        try addFinding(&w.report, w.allocator, .fail, .truncated_stream, null, "no SOS marker found before stream end");
    }
    if (!w.seen_eoi and !blockingFail(&w.report, w.nonblocking_fails)) {
        // FAIL class: an interrupted transfer, with no known writer. It was
        // WARN because readers decode the pixels anyway, which no longer
        // counts (owner, 2026-11-06). The codec check still runs.
        try addFinding(&w.report, w.allocator, .fail, .missing_eoi, w.data.len, "stream lacks EOI marker (0xFF 0xD9)");
        w.nonblocking_fails += 1;
    }

    // Progressive frames decode in multiple scans; surface the count as an
    // observation (consumers may use it for quality / progressive-render hints).
    switch (w.report.variant) {
        .progressive_huffman, .progressive_arithmetic => {
            if (w.sos_count > 0) {
                var nbuf: [48]u8 = undefined;
                const detail = std.fmt.bufPrint(&nbuf, "{d} progressive scans", .{w.sos_count}) catch "progressive scans";
                try addFinding(&w.report, w.allocator, .info, .progressive_scan_count, null, detail);
            }
        },
        else => {},
    }

    // Validate rulings G (2026-11-23): a DHT symbol past T.81's bound for the
    // frame precision is FAIL 51, exact at the symbol byte. No producer in
    // either project's corpora writes one. DC categories are at most P+3
    // (lossless 16); AC sizes at most P+2; and outside progressive scans,
    // where G.1.2.2 makes them EOBRUN symbols, no size-0 symbol has a run of
    // 1 to 14. Before the codec check, so its decode-through 58 does not
    // repeat the same table fault.
    if (w.frame_precision) |p| if (w.report.variant != .jpegls) {
        const lossless = w.report.variant == .lossless_huffman or w.report.variant == .lossless_arithmetic;
        const progressive = w.report.variant == .progressive_huffman or w.report.variant == .progressive_arithmetic;
        segments: for (w.dht_segments.items) |segment| {
            var hp = segment[0];
            while (hp + 17 <= segment[1]) {
                const tc = w.data[hp] >> 4;
                var total: usize = 0;
                for (w.data[hp + 1 ..][0..16]) |count| total += count;
                if (hp + 17 + total > segment[1]) break;
                // T.81 Table B.5 allows only Tc=0 tables in lossless frames.
                // Such a table is never selected, so decoding continues and
                // the rest of the file is still judged (nonblocking).
                if (lossless and tc != 0) {
                    const detail = try std.fmt.allocPrint(w.allocator, "DHT Tc={d} Th={d}: a lossless frame allows only Tc=0 tables (T.81 Table B.5)", .{ tc, w.data[hp] & 0x0F });
                    defer w.allocator.free(detail);
                    try addExactFinding(&w.report, w.allocator, .huffman_table_corrupt, hp, detail);
                    w.nonblocking_fails += 1;
                    break :segments;
                }
                for (w.data[hp + 17 ..][0..total], 0..) |value, k| {
                    const size = value & 0x0F;
                    const run = value >> 4;
                    const bad = if (tc == 0)
                        value > (if (lossless) 16 else @as(usize, p) + 3)
                    else
                        size > @as(usize, p) + 2 or (!progressive and size == 0 and run >= 1 and run <= 14);
                    if (!bad) continue;
                    const detail = try std.fmt.allocPrint(w.allocator, "DHT Tc={d} Th={d}: symbol 0x{X:0>2} is past the T.81 bound for {d}-bit samples", .{ tc, w.data[hp] & 0x0F, value, p });
                    defer w.allocator.free(detail);
                    try addExactFinding(&w.report, w.allocator, .huffman_table_corrupt, hp + 17 + k, detail);
                    break :segments;
                }
                hp += 17 + total;
            }
        }
    };

    // ── Step 4: Codec-level integrity ──────────────────────────
    // SOF3 consumes Huffman syntax without pixels or recovery. Other supported
    // variants run the cleanroom decoder with `lenient = true` + FindingsSink.
    // The marker walker catches
    // structural problems (missing markers, bad segment lengths,
    // truncation); decoding-through is the ground truth for
    // coefficient-level corruption — corrupt Huffman tables, bad
    // DCT coefficients, mismatched quantization tables.
    //
    // Cleanroom-only at runtime (per project architecture: libjpeg /
    // charls / openjpeg are build-time oracles only, used by tests
    // via `jpegz.internal.*`). Variants the cleanroom doesn't
    // recognize yield an INFO finding rather than FAIL — validator
    // doesn't have ground truth for those, so it stays silent on
    // codec correctness rather than slandering files libjpeg-turbo
    // would have accepted. CMYK and other un-cleanroomed variants
    // surface this way until their cleanroom paths land.
    //
    // We skip when:
    //   - The walker already found a fail-rated structural problem
    //     (the cleanroom would just rediscover it; saves cycles).
    //   - The variant is JPEG 2000 (separate `jpegz.jpeg2000`
    //     entry point with its own validation path).
    if (w.hierarchical and !blockingFail(&w.report, w.nonblocking_fails)) {
        // The cleanroom decoders do not implement Annex J. Say so, as for any
        // other unchecked variant, rather than decode only the first frame.
        w.report.codec_check = .unsupported;
        try addFinding(&w.report, w.allocator, .info, .unknown_marker, null, "hierarchical (DHP) process beyond cleanroom scope — codec integrity not checked");
    } else if (!blockingFail(&w.report, w.nonblocking_fails) and shouldRunCodecCheck(w.report.variant)) {
        var sink = types.FindingsSink.init(w.allocator);
        defer sink.deinit();

        const result = checkCodec(w.allocator, w.data, w.report.variant, &sink);

        // Drain sink → report findings (extraneous_bytes,
        // insufficient_data, etc.). Same severity/code/offset/detail
        // shape used by the marker walker, so the report is uniform.
        for (sink.items()) |f| {
            try addFinding(&w.report, w.allocator, reportSeverity(f.code, f.severity), f.code, f.offset, f.detail);
            w.report.findings.items[w.report.findings.items.len - 1].offset_is_exact = f.offset_is_exact;
        }

        if (result) |_| {
            // Codec traversal completed; decoder findings may report recovery.
            w.report.codec_check = .decoded;
        } else |err| switch (err) {
            error.NotImplemented => {
                w.report.codec_check = .unsupported;
                // Cleanroom doesn't own this variant yet — don't slander
                // the file with FAIL. Surface as INFO so strict
                // consumers know we didn't run codec check.
                try addFinding(&w.report, w.allocator, .info, .unknown_marker, null, "codec variant beyond cleanroom v1 scope — codec integrity not checked");
            },
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                w.report.codec_check = .failed;
                // A decoder that already named the defect with an exact
                // offset needs no second, generic bucket for the same stop.
                const typed = for (sink.items()) |f| {
                    if (f.severity == .fail) break true;
                } else false;
                if (!typed) try addFinding(&w.report, w.allocator, .fail, switch (w.report.variant) {
                    .jpegls, .baseline_arithmetic, .progressive_arithmetic, .lossless_arithmetic => mapTypedCodecError(err),
                    else => mapDecodeErrorToFindingCode(err),
                }, null, @errorName(err));
            },
        }
    }

    // Finding 69 (A3, validate approved 2026-11-06). A sequential Huffman
    // frame with no DHT anywhere is the Motion-JPEG pattern: known defect
    // when every scan decodes completely with the T.81 K.3 tables (the
    // decoders install them), FAIL otherwise. With some DHT present, a scan
    // naming an undefined table is FAIL at that Td/Ta byte.
    const sequential_huffman_frame = w.report.variant == .baseline_huffman or w.report.variant == .extended_huffman;
    if (sequential_huffman_frame and w.first_sos_offset != null) {
        if (!w.seen_dht) {
            const complete = w.report.codec_check == .decoded and w.report.overall.rank() < Severity.fail.rank();
            if (complete) {
                try addFinding(&w.report, w.allocator, .known_defect, .huffman_tables_missing, w.first_sos_offset, "no DHT segment; every scan decodes completely with the T.81 Annex K.3 tables (Motion-JPEG); admitted known defect");
            } else {
                try addFinding(&w.report, w.allocator, .fail, .huffman_tables_missing, w.first_sos_offset, "no DHT segment, and the scans do not decode completely with the T.81 Annex K.3 tables");
            }
        } else if (w.first_missing_table) |offset| {
            try addExactFinding(&w.report, w.allocator, .huffman_tables_missing, offset, "scan names a Huffman table that no DHT segment defines");
        }
    }
}
