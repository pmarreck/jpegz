//! Marker-walk handler for scan headers (SOS).

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

pub fn checkSequentialScanField(report: *ValidationReport, allocator: Allocator, offset: usize, name: []const u8, observed: u8, required: u8) Allocator.Error!void {
    if (observed == required) return;
    const detail = try std.fmt.allocPrint(allocator, "sequential SOS {s}={d}; required {d}", .{ name, observed, required });
    defer allocator.free(detail);
    try addExactFinding(report, allocator, .sequential_scan_invalid, offset, detail);
}

pub fn onSos(w: *Walk, s: Seg) Allocator.Error!void {
    const marker_offset = s.marker_offset;
    const seg_len = s.seg_len;
    const seg_body_start = s.seg_body_start;
    const seg_end = s.seg_end;
    const pos = s.pos;
    w.seen_sos = true;
    w.sos_count += 1;
    w.frame_scans += 1;
    if (w.first_sos_offset == null) w.first_sos_offset = marker_offset;
    // Finding 69: a sequential scan naming a Huffman table no DHT has
    // defined yet. Judged after the walk (see below).
    if (w.seen_sof and (w.report.variant == .baseline_huffman or w.report.variant == .extended_huffman) and
        seg_body_start < seg_end and w.first_missing_table == null)
    {
        const scan_ns = w.data[seg_body_start];
        // Only a complete selector list; Ss, Se and Ah/Al are not Td/Ta.
        const complete_list = seg_len == 6 + @as(usize, scan_ns) * 2;
        var sj: usize = 0;
        while (complete_list and sj < scan_ns) : (sj += 1) {
            const tdta = w.data[seg_body_start + 2 + 2 * sj];
            const td = tdta >> 4;
            const ta = tdta & 0x0F;
            if ((td <= 3 and !w.dht_defined[0][td]) or (ta <= 3 and !w.dht_defined[1][ta])) {
                w.first_missing_table = seg_body_start + 2 + 2 * sj;
                break;
            }
        }
    }
    // Validate 2026-11-22: a progressive scan naming an undefined table
    // gets finding 69 at its Td/Ta byte, as on the sequential path. A
    // DC first scan uses Td, an AC scan Ta, a DC refinement neither.
    if (w.seen_sof and w.report.variant == .progressive_huffman and
        seg_body_start < seg_end and w.first_missing_table == null)
    {
        const scan_ns = w.data[seg_body_start];
        if (seg_len == 6 + @as(usize, scan_ns) * 2) {
            const tail = seg_body_start + 1 + 2 * @as(usize, scan_ns);
            const ss = w.data[tail];
            const ah = w.data[tail + 2] >> 4;
            for (0..scan_ns) |sj| {
                const tdta = w.data[seg_body_start + 2 + 2 * sj];
                const td = tdta >> 4;
                const ta = tdta & 0x0F;
                const missing = if (ss == 0) ah == 0 and td <= 3 and !w.dht_defined[0][td] else ta <= 3 and !w.dht_defined[1][ta];
                if (missing) {
                    // No K.3 fallback applies to progressive scans, so report
                    // now; the FAIL also spares a redundant decode-through 51.
                    w.first_missing_table = seg_body_start + 2 + 2 * sj;
                    try addExactFinding(&w.report, w.allocator, .huffman_tables_missing, w.first_missing_table.?, "scan names a Huffman table that no DHT segment defines");
                    break;
                }
            }
        }
    }
    // Validate 2026-11-22: SOS Ns outside 1..4 or above the SOF's Nf gets
    // the code the sequential check below gives it, on every T.81 path.
    const sequential_scan = w.report.variant == .baseline_huffman or w.report.variant == .extended_huffman;
    if (w.seen_sof and !sequential_scan and w.report.variant != .jpegls and seg_body_start < seg_end) {
        const ns = w.data[seg_body_start];
        if (ns == 0 or ns > 4 or (w.sof_component_count != 0 and ns > w.sof_component_count)) {
            try addExactFinding(&w.report, w.allocator, .sos_component_mismatch, seg_body_start, "SOS Ns must be 1..4 and cannot exceed SOF Nf");
        } else if (seg_len != 6 + @as(usize, ns) * 2) {
            // T.81 B.2.3 on every T.81 path, as for sequential Huffman below
            // (libjpeg get_sos: JERR_BAD_LENGTH). The decoders reject it too.
            try addExactFinding(&w.report, w.allocator, .bad_marker_length, pos, "SOS length must equal 6 + 2*Ns (T.81 B.2.3)");
        }
    }
    // Finding 75 (validate, 2026-11-22): an SOS Td/Ta outside T.81
    // Table B.3, exact at the byte. Above 3 no destination exists:
    // FAIL. In a baseline (SOF0) frame, 2 or 3 naming a defined table
    // breaks a baseline limit: WARN; an undefined table is finding 69's.
    // Lossless Ta (B.3 gives 0) is not judged; JPEG-LS has no Td/Ta.
    if (w.seen_sof and w.report.variant != .jpegls and seg_body_start < seg_end) {
        const scan_ns = w.data[seg_body_start];
        const lossless = w.report.variant == .lossless_huffman or w.report.variant == .lossless_arithmetic;
        if (seg_len == 6 + @as(usize, scan_ns) * 2) for (0..scan_ns) |sj| {
            const at = seg_body_start + 2 + 2 * sj;
            const td = w.data[at] >> 4;
            const ta = w.data[at] & 0x0F;
            const td_bad = td > 3;
            const ta_bad = !lossless and ta > 3;
            var dbuf: [112]u8 = undefined;
            if (td_bad or ta_bad) {
                const detail = (if (td_bad and ta_bad)
                    std.fmt.bufPrint(&dbuf, "SOS component {d}: td={d} and ta={d} name no table destination (T.81 Table B.3: 0..3)", .{ w.data[at - 1], td, ta })
                else
                    std.fmt.bufPrint(&dbuf, "SOS component {d}: {s}={d} names no table destination (T.81 Table B.3: 0..3)", .{ w.data[at - 1], if (td_bad) "td" else "ta", if (td_bad) td else ta })) catch "SOS Td/Ta outside T.81 Table B.3";
                try addExactFinding(&w.report, w.allocator, .sos_table_selector_invalid, at, detail);
            } else if (w.report.variant == .baseline_huffman and
                ((td >= 2 and w.dht_defined[0][td]) or (ta >= 2 and w.dht_defined[1][ta])))
            {
                const detail = std.fmt.bufPrint(&dbuf, "SOS component {d}: {s}={d} in a baseline frame (T.81 Table B.3: 0..1)", .{ w.data[at - 1], if (td >= 2) "td" else "ta", if (td >= 2) td else ta }) catch "SOS Td/Ta above the baseline limit";
                try addFinding(&w.report, w.allocator, .warn, .sos_table_selector_invalid, at, detail);
                w.report.findings.items[w.report.findings.items.len - 1].offset_is_exact = true;
            }
        };
    }
    // T.81 B.2.3: diagnose sequential SOS shape before decoding can
    // mislabel a header fault as damaged Huffman entropy.
    const sequential_huffman = w.report.variant == .baseline_huffman or w.report.variant == .extended_huffman;
    if (w.seen_sof and sequential_huffman) {
        if (seg_body_start == seg_end or seg_len < 6) {
            try addExactFinding(&w.report, w.allocator, .bad_marker_length, pos, "sequential SOS length must equal 6 + 2*Ns");
        } else {
            const ns = w.data[seg_body_start];
            if (ns == 0 or ns > 4 or (w.sof_component_count != 0 and ns > w.sof_component_count)) {
                try addExactFinding(&w.report, w.allocator, .sos_component_mismatch, seg_body_start, "sequential SOS Ns must be 1..4 and cannot exceed SOF Nf");
            }
            if (seg_len != 6 + @as(usize, ns) * 2) {
                try addExactFinding(&w.report, w.allocator, .bad_marker_length, pos, "sequential SOS length must equal 6 + 2*Ns");
            }
        }
    }
    // Validate scan component selectors (Cs) reference SOF-declared
    // components (T.81 §B.2.3). SOS body: Ns, then Ns×(Cs, Td/Ta).
    // Only meaningful once a SOF has been seen (missing SOF is
    // reported separately) — otherwise the bitmap is empty.
    if (w.seen_sof and seg_body_start < seg_end) {
        const ns = w.data[seg_body_start];
        // Only a complete T.81 selector list establishes a repeated Cs.
        // JPEG-LS scan constraints remain owned by the T.87 validator.
        const check_duplicates = w.report.variant != .jpegls and seg_len == 6 + @as(usize, ns) * 2;
        var selected = [_]bool{false} ** 256;
        var cj: usize = 0;
        // Reserve Ss, Se and Ah/Al; an excessive Ns must not turn
        // those trailing parameters into apparent component selectors.
        while (cj < ns and seg_body_start + 5 + 2 * cj < seg_end) : (cj += 1) {
            const cs = w.data[seg_body_start + 1 + 2 * cj];
            // Finding 70's frame resolves its one exact scan by position.
            const by_position = w.sof_k_id_one and baseline.isKIdOneScan(w.data[seg_body_start..seg_end]);
            if (check_duplicates and selected[cs] and !by_position) {
                try addExactFinding(&w.report, w.allocator, .sos_component_mismatch, seg_body_start + 1 + 2 * cj, "SOS repeats a component selector Cs");
            }
            selected[cs] = true;
            if (!w.sof_comp_ids[cs]) {
                try addFinding(&w.report, w.allocator, .fail, .sos_component_mismatch, seg_body_start + 1 + 2 * cj, "SOS component selector Cs not declared in SOF");
            }
        }
        // T.81 B.2.3: an interleaved scan (Ns > 1) has at most 10 data
        // units per MCU. Out-of-range or undeclared factors are already
        // reported, so only an otherwise legal combination is judged.
        if (check_duplicates and ns > 1) {
            var units: usize = 0;
            var judged = true;
            for (0..ns) |index| {
                const cs = w.data[seg_body_start + 1 + 2 * index];
                const hv = w.sof_comp_hv[cs];
                const hi = hv >> 4;
                const vi = hv & 15;
                if (!w.sof_comp_ids[cs] or hi < 1 or hi > 4 or vi < 1 or vi > 4) judged = false;
                units += @as(usize, hi) * vi;
            }
            if (judged and units > 10) {
                const detail = try std.fmt.allocPrint(w.allocator, "interleaved scan MCU has {d} data units; T.81 B.2.3 allows at most 10", .{units});
                defer w.allocator.free(detail);
                try addExactFinding(&w.report, w.allocator, .sof_sampling_invalid, seg_body_start, detail);
            }
        }
    }

    // Validate the scan's spectral / predictor parameters per frame
    // type. SOS body tail is Ss, Se, AhAl after Ns×(Cs,Td/Ta).
    if (w.seen_sof and seg_body_start < seg_end) {
        const ns2 = w.data[seg_body_start];
        const spec_off = seg_body_start + 1 + 2 * @as(usize, ns2);
        // Validate rulings H (2026-11-23): an invalid Ns (already 55)
        // leaves Ss, Se, Ah and Al unlocated, so they are not judged.
        const ns_valid = w.report.variant == .jpegls or
            !(ns2 == 0 or ns2 > 4 or (w.sof_component_count != 0 and ns2 > w.sof_component_count));
        const progressive_frame = w.report.variant == .progressive_huffman or w.report.variant == .progressive_arithmetic;
        if (progressive_frame and !(ns_valid and spec_off + 2 < seg_end)) w.history_known = false;
        if (ns_valid and spec_off + 2 < seg_end) {
            const ss = w.data[spec_off];
            const se = w.data[spec_off + 1];
            const ahal = w.data[spec_off + 2];
            const ah = ahal >> 4;
            const al = ahal & 0x0F;
            switch (w.report.variant) {
                .baseline_huffman, .extended_huffman => if (ss == 0 and se == 0 and ahal == 0 and
                    w.sos_count == 1 and ns2 == w.sof_component_count)
                {
                    w.go_zero_se = spec_off + 1;
                } else {
                    try checkSequentialScanField(&w.report, w.allocator, spec_off, "Ss", ss, 0);
                    try checkSequentialScanField(&w.report, w.allocator, spec_off + 1, "Se", se, 63);
                    try checkSequentialScanField(&w.report, w.allocator, spec_off + 2, "Ah (high nibble)", ah, 0);
                    try checkSequentialScanField(&w.report, w.allocator, spec_off + 2, "Al (low nibble)", al, 0);
                },
                .progressive_huffman, .progressive_arithmetic => {
                    // T.81 §G.1.1.1.1: Ss,Se ≤ 63 and Ah,Al ≤ 13; a DC
                    // scan (Ss=0) must have Se=0; an AC scan (Ss≠0) must
                    // have Se in Ss..63.
                    const bad = ss > 63 or se > 63 or ah > 13 or al > 13 or
                        (ss == 0 and se != 0) or (ss != 0 and se < ss);
                    if (bad) try addFinding(&w.report, w.allocator, .fail, .progressive_scan_invalid, spec_off, "progressive SOS spectral/approximation parameters violate T.81 §G");
                    // Validate rulings I: judged against earlier scans
                    // (T.81 G.1.1.1.1 and G.1.1.1.2), one record per scan
                    // at the first violation. An AC scan needs the
                    // component's DC first scan; a scan coding coefficient k
                    // needs Ah equal to the last Al for k (0 if uncoded).
                    // Validate rulings I (2026-11-23): a refinement scan
                    // (Ah > 0) needs Al = Ah - 1, and an AC scan needs
                    // Ns = 1 (T.81 G.1.1.1.1). One record per scan.
                    const refine_bad = !bad and ah != 0 and al + 1 != ah;
                    const ac_ns_bad = !bad and !refine_bad and ss != 0 and ns2 != 1;
                    if (refine_bad) {
                        const detail = try std.fmt.allocPrint(w.allocator, "refinement scan has Ah={d} and Al={d}; Al must be Ah - 1 (T.81 G.1.1.1.1)", .{ ah, al });
                        defer w.allocator.free(detail);
                        try addExactFinding(&w.report, w.allocator, .progressive_scan_invalid, spec_off + 2, detail);
                    }
                    if (ac_ns_bad) {
                        const detail = try std.fmt.allocPrint(w.allocator, "AC scan (Ss={d}) has Ns={d}; AC scans code one component (T.81 G.1.1.1.1)", .{ ss, ns2 });
                        defer w.allocator.free(detail);
                        try addExactFinding(&w.report, w.allocator, .progressive_scan_invalid, seg_body_start, detail);
                    }
                    const scan_bad = bad or refine_bad or ac_ns_bad;
                    if (scan_bad) w.history_known = false;
                    if (!scan_bad and w.history_known) {
                        for (0..ns2) |j| {
                            const cs = w.data[seg_body_start + 1 + 2 * j];
                            const coded = &w.coef_al[cs];
                            if (ss > 0 and coded[0] < 0) {
                                const detail = try std.fmt.allocPrint(w.allocator, "history: AC scan for component {d} before its DC first scan (T.81 G.1.1.1.1)", .{cs});
                                defer w.allocator.free(detail);
                                try addExactFinding(&w.report, w.allocator, .progressive_scan_invalid, spec_off, detail);
                                w.history_known = false;
                                break;
                            }
                            const mismatch: ?usize = for (ss..@as(usize, se) + 1) |k| {
                                if (ah != @max(coded[k], 0)) break k;
                            } else null;
                            if (mismatch) |k| {
                                const detail = if (coded[k] < 0)
                                    try std.fmt.allocPrint(w.allocator, "history: component {d} coefficient {d} has Ah={d}, but no scan has coded it, so Ah must be 0 (T.81 G.1.1.1.2)", .{ cs, k, ah })
                                else
                                    try std.fmt.allocPrint(w.allocator, "history: component {d} coefficient {d} has Ah={d}, but the last scan coding it had Al={d} (T.81 G.1.1.1.2)", .{ cs, k, ah, coded[k] });
                                defer w.allocator.free(detail);
                                try addExactFinding(&w.report, w.allocator, .progressive_scan_invalid, spec_off + 2, detail);
                                w.history_known = false;
                                break;
                            }
                        }
                        for (0..ns2) |j| {
                            const cs = w.data[seg_body_start + 1 + 2 * j];
                            for (ss..@as(usize, se) + 1) |k| w.coef_al[cs][k] = @intCast(al);
                        }
                    }
                },
                .lossless_huffman, .lossless_arithmetic => {
                    // T.81 §H.1: Ss is the predictor selector (1..7);
                    // Ah must be 0 (lossless has no successive
                    // approximation — the byte carries only the point
                    // transform in Al).
                    // Table H.1: selection value 0 ("no prediction") is
                    // only for differential coding in hierarchical mode.
                    if (if (w.frame_differential) ss > 7 else ss < 1 or ss > 7)
                        try addFinding(&w.report, w.allocator, .fail, .lossless_predictor_invalid, spec_off, if (w.frame_differential) "differential lossless predictor (Ss) must be 0..7" else "lossless predictor (Ss) must be 1..7");
                    if (ah != 0)
                        try addFinding(&w.report, w.allocator, .fail, .lossless_pointtransform_invalid, spec_off + 2, "lossless scan must have Ah=0 (byte carries only point transform Al)");
                    // The predictor 2^(P-Pt-1) needs Pt < P (libjpeg
                    // start_pass_lossless: JERR_BAD_PROGRESSION).
                    if (w.frame_precision) |p| if (al >= p)
                        try addFinding(&w.report, w.allocator, .fail, .lossless_pointtransform_invalid, spec_off + 2, "lossless point transform Pt (Al) must be less than the sample precision P");
                },
                else => {},
            }
        }
    }
}
