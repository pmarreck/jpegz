//! Marker-walk handler for frame headers (SOFn).

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

/// The first out-of-range Hi or Vi of a SOF (T.81 Table B.2: 1..4).
pub const BadSamplingFactor = struct { offset: usize, component: u8, name: []const u8, value: u8 };

/// Finding 66, one record per SOF (validate ruling 2026-11-22): the first
/// invalid factor, exact, with the frame's counts of invalid factors and of
/// the components that carry them.
pub fn reportSamplingFactors(report: *ValidationReport, allocator: Allocator, first: BadSamplingFactor, factors: usize, components: usize) Allocator.Error!void {
    const detail = try std.fmt.allocPrint(allocator, "SOF component ID {d} {s}={d}; allowed 1..4; {d} invalid factor{s} in {d} component{s}", .{
        first.component,                  first.name,                    first.value,
        factors,                          if (factors == 1) "" else "s", components,
        if (components == 1) "" else "s",
    });
    defer allocator.free(detail);
    try addExactFinding(report, allocator, .sof_sampling_invalid, first.offset, detail);
}

pub fn onSof(w: *Walk, s: Seg, variant: Variant) Allocator.Error!void {
    const marker_byte = s.marker_byte;
    const marker_offset = s.marker_offset;
    const seg_len = s.seg_len;
    const seg_body_start = s.seg_body_start;
    w.frame_differential = switch (marker_byte) {
        0xc5, 0xc6, 0xc7, 0xcd, 0xce, 0xcf => true,
        else => false,
    };
    if (w.frame_differential and !w.hierarchical) {
        // FAIL (validate, 2026-11-21): nothing to difference against.
        try addExactFinding(&w.report, w.allocator, .differential_frame_without_dhp, marker_offset, "differential SOF with no DHP before it; T.81 J.1 allows differential frames only in hierarchical mode");
        w.nonblocking_fails += 1;
    }
    if (w.seen_sof and !w.hierarchical) {
        // FAIL class (validate, 2026-11-05): libjpeg refuses two SOF
        // markers and damage produces them.
        try addFinding(&w.report, w.allocator, .fail, .duplicate_sof, marker_offset, "more than one SOF marker outside a hierarchical (DHP) stream (using first)");
        w.nonblocking_fails += 1;
    } else if (!w.seen_sof) {
        w.report.variant = variant;
        w.sof_offset = marker_offset;
        w.seen_sof = true;

        // SOF body layout (T.81 §B.2.2):
        //   0: precision (u8)
        //   1-2: height (u16 BE)
        //   3-4: width (u16 BE)
        //   5: number of components (u8)
        //   6+: per-component data (3 bytes each)
        if (seg_len < 8) {
            try addFinding(&w.report, w.allocator, .fail, .bad_marker_length, seg_body_start, "SOF segment too short for header fields");
        } else {
            const precision = w.data[seg_body_start];
            if (w.frame_precision == null) w.frame_precision = precision;
            const declared_height = readU16BE(w.data, seg_body_start + 1);
            const declared_width = readU16BE(w.data, seg_body_start + 3);
            // T.81 B.2.5 and T.87 C.2.2: Y = 0 defers the line count
            // to a DNL right after the first scan, as the decoders
            // resolve it; JPEG-LS entropy data has its own stuffing.
            const dnl_height: ?u16 = if (declared_height != 0)
                null
            else if (variant == .jpegls)
                jpegls.dnlLines(w.data, seg_body_start - 2 + seg_len)
            else
                jpeg_markers.dnlLines(w.data, seg_body_start - 2 + seg_len);
            // T.87 C.2.4.1.4: an LSE ID 4 fills a JPEG-LS dimension the
            // SOF55 leaves at 0 (sizes above 65535).
            const oversize: ?jpegls.Oversize = if (variant == .jpegls and (declared_height == 0 or declared_width == 0))
                jpegls.oversizeDimensions(w.data)
            else
                null;
            const width: u32 = if (declared_width != 0) declared_width else if (oversize) |o| o.width else 0;
            const height: u32 = if (declared_height != 0) declared_height else if (dnl_height) |lines| lines else if (oversize) |o| o.height else 0;
            w.frame_declared_y = declared_height;
            w.frame_lines = if (declared_height != 0) declared_height else dnl_height;
            w.report.width = width;
            w.report.height = height;

            // SOF3 Y=0 needs DNL and remains unsupported by its entropy
            // validator. Other pixel decoders still require both sizes
            // to prevent indexing empty planes.
            if (width == 0 or (height == 0 and variant != .lossless_huffman)) {
                try addFinding(&w.report, w.allocator, .fail, .invalid_dimensions, seg_body_start + 1, "SOF declares zero width, or zero height with no DNL after the first scan");
            }

            // Nf (component count) must be >= 1 and the segment length
            // must equal 8 + 3*Nf (T.81 §B.2.2: 1 prec + 2 H + 2 W + 1
            // Nf + 3 bytes per component, plus the 2 length bytes). A
            // mismatch means the declared count is inconsistent with
            // the marker — flag rather than silently mis-parse.
            const nf = w.data[seg_body_start + 5];
            if (nf == 0 or @as(usize, seg_len) != 8 + 3 * @as(usize, nf)) {
                try addFinding(&w.report, w.allocator, .fail, .sof_component_count_invalid, seg_body_start + 5, "SOF Nf must be >= 1 and segment length must equal 8 + 3*Nf");
            } else {
                w.sof_component_count = nf;
                const k_id_one = [_]u8{ 1, 2, 3, 1 };
                w.sof_k_id_one = nf == 4 and variant != .jpegls and for (k_id_one, 0..) |id, k| {
                    if (w.data[seg_body_start + 6 + 3 * k] != id) break false;
                } else true;
                // Record each declared component ID (Ci) for the SOS cross-check.
                var bad_factors: usize = 0;
                var bad_components: usize = 0;
                var first_bad: ?BadSamplingFactor = null;
                var ci: usize = 0;
                while (ci < nf) : (ci += 1) {
                    const component = w.data[seg_body_start + 6 + 3 * ci];
                    const offset = seg_body_start + 7 + 3 * ci;
                    // T.81 B.2.2: component IDs within a frame are distinct.
                    if (w.sof_comp_ids[component] and variant != .jpegls) {
                        const id_offset = seg_body_start + 6 + 3 * ci;
                        if (w.sof_k_id_one) {
                            try addFinding(&w.report, w.allocator, .warn, .sof_component_id_duplicate, id_offset, "SOF gives the fourth component the ID 1 already used by the first: the CMYK/YCCK writer pattern (1, 2, 3, 1)");
                            w.report.findings.items[w.report.findings.items.len - 1].offset_is_exact = true;
                        } else {
                            const detail = try std.fmt.allocPrint(w.allocator, "SOF repeats component ID {d}", .{component});
                            defer w.allocator.free(detail);
                            try addExactFinding(&w.report, w.allocator, .sof_component_id_duplicate, id_offset, detail);
                        }
                    }
                    w.sof_comp_ids[component] = true;
                    w.sof_comp_hv[component] = w.data[offset];
                    // T.81 Table B.2: every T.81 frame's Hi and Vi are 1..4.
                    // The JPEG-LS frame stays with the T.87 validator.
                    if (variant == .jpegls) continue;
                    var bad_here = false;
                    for ([_]struct { name: []const u8, value: u8 }{
                        .{ .name = "Hi (high nibble)", .value = w.data[offset] >> 4 },
                        .{ .name = "Vi (low nibble)", .value = w.data[offset] & 15 },
                    }) |factor| {
                        if (factor.value >= 1 and factor.value <= 4) continue;
                        bad_factors += 1;
                        bad_here = true;
                        if (first_bad == null) first_bad = .{ .offset = offset, .component = component, .name = factor.name, .value = factor.value };
                    }
                    if (bad_here) bad_components += 1;
                }
                if (first_bad) |bad| try reportSamplingFactors(&w.report, w.allocator, bad, bad_factors, bad_components);
            }

            const lossless_precision = variant == .lossless_huffman or variant == .lossless_arithmetic;
            if (if (lossless_precision) precision < 2 or precision > 16 else precision != 8 and precision != 12 and precision != 16) {
                try addFinding(&w.report, w.allocator, .fail, .invalid_sof_precision, seg_body_start, if (lossless_precision) "lossless SOF precision must be 2..16" else "SOF precision must be 8, 12, or 16");
            } else if (precision == 12) {
                try addFinding(&w.report, w.allocator, .info, .twelve_bit_precision, seg_body_start, null);
            } else if (precision == 16 and (variant == .lossless_huffman or
                variant == .lossless_arithmetic))
            {
                try addFinding(&w.report, w.allocator, .info, .sixteen_bit_lossless, seg_body_start, null);
            }

            // Surface .info hint for arithmetic-coded variants.
            switch (variant) {
                .baseline_arithmetic, .progressive_arithmetic, .lossless_arithmetic => try addFinding(&w.report, w.allocator, .info, .arithmetic_coding_used, marker_offset, null),
                else => {},
            }
        }
    }
}
