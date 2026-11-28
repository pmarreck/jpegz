//! Part of baseline.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;
const errors = @import("../core/errors.zig");
const types = @import("../core/types.zig");
const bitstream = @import("bitstream.zig");
const huffman = @import("huffman.zig");
const idct = @import("idct.zig");
const color = @import("color.zig");
const cmyk_mod = @import("cmyk.zig");
const findings_mod = @import("findings.zig");
const thread_pool = @import("thread_pool.zig");
const jpeg_markers = @import("jpeg_markers.zig");
const builtin = @import("builtin");
const fail = @import("baseline.zig").fail;
const emitFinding = @import("baseline.zig").emitFinding;
const FrameInfo = @import("baseline.zig").FrameInfo;
const Error = @import("baseline.zig").Error;
const DecodeOptions = @import("baseline.zig").DecodeOptions;

/// Find the next marker code the way libjpeg's next_marker does (T.81
/// §B.1.1.2, markers are self-synchronizing): report and skip extraneous
/// non-FF bytes, report and collapse FF fill bytes, and return the code with
/// `pos` just past it. A stray FF 00 (entropy stuffing outside a scan) is
/// garbage: `pos` steps one byte and the result is null so the caller rechecks
/// its loop bound.
pub fn nextMarker(data: []const u8, pos: *usize, options: DecodeOptions) Error!?u8 {
    // Tolerate "extraneous bytes before marker" — djpeg/libjpeg-turbo
    // recover from this and so do we. Scan forward to the next 0xFF byte.
    const skip_start = pos.*;
    while (pos.* < data.len and data[pos.*] != 0xFF) pos.* += 1;
    if (pos.* > skip_start) {
        if (options.findings_sink) |sink| {
            // Mirror libjpeg's "Corrupt JPEG data: N extraneous bytes
            // before marker 0xXX" warning text so consumers can grep
            // across cleanroom and wrapper paths uniformly.
            var buf: [96]u8 = undefined;
            const next_marker: u8 = if (pos.* + 1 < data.len) data[pos.* + 1] else 0;
            const detail = std.fmt.bufPrint(&buf,
                "Corrupt JPEG data: {d} extraneous bytes before marker 0x{x:0>2}",
                .{ pos.* - skip_start, next_marker }) catch buf[0..0];
            sink.emit(.warn, .extraneous_bytes_before_marker,
                @intCast(skip_start), detail) catch return error.OutOfMemory;
        }
    }
    if (pos.* + 1 >= data.len) return fail("walker_eof_after_ff", error.TruncatedStream);
    // Skip 0xFF padding bytes (T.81 §B.1.1.2: legal "fill" but
    // non-canonical). Emit a warn finding so strict validators
    // see the spec deviation.
    const fill_start = pos.*;
    while (pos.* + 1 < data.len and data[pos.* + 1] == 0xFF) pos.* += 1;
    if (pos.* > fill_start) {
        if (options.findings_sink) |sink| {
            var buf: [80]u8 = undefined;
            const next_marker: u8 = if (pos.* + 1 < data.len) data[pos.* + 1] else 0;
            const detail = std.fmt.bufPrint(&buf,
                "{d} extra 0xFF fill byte(s) before marker 0x{x:0>2}",
                .{ pos.* - fill_start, next_marker }) catch buf[0..0];
            sink.emit(.warn, .entropy_fill_bytes,
                @intCast(fill_start), detail) catch return error.OutOfMemory;
        }
    }
    if (pos.* + 1 >= data.len) return fail("walker_eof_after_ff", error.TruncatedStream);
    const marker = data[pos.* + 1];
    if (marker == 0x00) {
        pos.* += 1;
        return null;
    }
    pos.* += 2;
    return marker;
}

/// Continue the marker walk after a scan whose frame still has uncoded
/// components (T.81 §B.2.1: tables and miscellaneous segments may precede
/// every scan). Applies DHT/DQT/DRI updates in place and returns the next
/// scan's component selection with `pos` at its entropy data. EOI here means
/// some frame component was never coded; a new SOF means a second frame.
pub fn walkToNextScan(
    data: []const u8,
    pos: *usize,
    frame: *FrameInfo,
    quant_tables: *[4]?[64]u16,
    dc_tables: *[4]?huffman.HuffmanTable,
    ac_tables: *[4]?huffman.HuffmanTable,
    restart_interval: *u32,
    options: DecodeOptions,
) Error!ScanSelection {
    while (pos.* + 1 < data.len) {
        const marker = (try nextMarker(data, pos, options)) orelse continue;
        switch (marker) {
            0xD9 => {
                try emitFinding(options, .fail, .truncated_stream, pos.* - 2,
                    "EOI before every component of the sequential frame was scanned");
                return fail("eoi_before_all_components_scanned", error.TruncatedStream);
            },
            0xC0...0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF => return fail("sof_between_scans", error.InvalidMarker),
            0xC4 => {
                try parseDht(data, pos.*, dc_tables, ac_tables);
                pos.* += parseSegmentLength(data, pos.*);
            },
            0xDB => {
                try parseDqt(data, pos.*, quant_tables);
                pos.* += parseSegmentLength(data, pos.*);
            },
            0xDD => {
                const seg_len = parseSegmentLength(data, pos.*);
                if (seg_len < 4 or pos.* + seg_len > data.len) return error.TruncatedStream;
                restart_interval.* = (@as(u32, data[pos.* + 2]) << 8) | data[pos.* + 3];
                pos.* += seg_len;
            },
            0xDA => {
                const scan = try parseSos(data, pos.*, frame);
                pos.* += parseSegmentLength(data, pos.*);
                return scan;
            },
            0x01, 0xD0...0xD7 => continue,
            else => pos.* += parseSegmentLength(data, pos.*),
        }
    }
    // data.len is not a byte of the input, so this offset is not exact.
    if (options.findings_sink) |sink| try sink.emit(.fail, .truncated_stream, data.len,
        "data ended before every component of the sequential frame was scanned");
    return fail("eof_before_all_components_scanned", error.TruncatedStream);
}

/// Detect another sequential scan after every component was already coded
/// (T.81 3.1.116). Probe complete marker chains without decoding extra entropy;
/// defer the finding until EOI so missing-EOI decode behavior stays unchanged.
pub fn rejectPostCoverageScans(data: []const u8, start: usize, options: DecodeOptions) Error!void {
	var pos = start;
	var repeated_cs: ?usize = null;
	while (pos + 1 < data.len) {
		// Inspection is provisional: incomplete tails must not add findings.
		const marker = (nextMarker(data, &pos, .{}) catch return) orelse continue;
		switch (marker) {
			0xd9 => {
				if (repeated_cs) |offset| {
					try emitFinding(options, .fail, .sos_component_mismatch, offset,
						"SOS follows complete component coverage of a sequential frame");
					return fail("scan_after_complete_coverage", error.InvalidMarker);
				}
				return;
			},
			0x01, 0xd0...0xd8 => continue,
			else => {
				const len = parseSegmentLength(data, pos);
				if (len < 2 or pos + len > data.len) return;
				if (marker == 0xda and repeated_cs == null) {
					// A complete selector field gives the repeated component's
					// exact byte; a shorter extra header names its SOS marker.
					repeated_cs = if (len >= 8 and data[pos + 2] != 0) pos + 3 else pos - 2;
				}
				// Length-delimited payloads may contain arbitrary marker bytes.
				pos += len;
			},
		}
	}
}

pub const parseSegmentLength = @import("segment.zig").parseSegmentLength;

pub const parseSof = jpeg_markers.parseSof;

pub const parseDqt = jpeg_markers.parseDqt;

pub const parseDht = jpeg_markers.parseDht;

/// Frame-component indices coded by one scan, in scan order (T.81 §B.2.3).
pub const ScanSelection = struct {
    count: u8,
    comp: [4]u8,
    /// File offset of each Csj byte, for findings that name a selector.
    cs_pos: [4]usize,
};

/// Parse an SOS header and latch each selected component's Td/Ta tables.
/// T.81 §B.2.3: Ls = 6 + 2*Ns, 1 <= Ns <= 4, and every Cs names a distinct
/// frame component. Sequential frames may split components across scans,
/// so Ns may be less than Nf.
pub fn parseSos(data: []const u8, pos: usize, frame: *FrameInfo) Error!ScanSelection {
    const seg_len = parseSegmentLength(data, pos);
    if (seg_len < 6 or pos + seg_len > data.len) return error.TruncatedStream;
    const ns = data[pos + 2];
    if (ns == 0 or ns > frame.num_components) return fail("sos_bad_ns", error.InvalidMarker);
    if (seg_len != 6 + @as(usize, ns) * 2) return fail("sos_bad_length", error.InvalidMarker);
    var scan: ScanSelection = .{ .count = ns, .comp = .{ 0, 0, 0, 0 }, .cs_pos = .{ 0, 0, 0, 0 } };
    const by_position = isKIdOneFrame(frame) and isKIdOneScan(data[pos + 2 .. pos + seg_len]);
    var i: usize = 0;
    while (i < ns) : (i += 1) {
        const off = pos + 3 + i * 2;
        const cs = data[off];
        const td_ta = data[off + 1];
        // Find the matching component in frame.components by ID.
        // T.81 §B.2.3 Table B.3: Td and Ta select one of FOUR table
        // destinations, but each is a 4-bit field, so the bytes on disk can
        // name destination 15. Rejecting that here is load-bearing: the scan
        // decoder indexes `dc_tables[comp.dc_table]` on a [4] array, so an
        // unchecked selector is an out-of-bounds read — a panic under
        // ReleaseSafe (it crashed tiffz's validator on a crafted
        // JPEG-in-TIFF) and silent UB under ReleaseFast, which is worse.
        const td = td_ta >> 4;
        const ta = td_ta & 0x0F;
        if (td > 3 or ta > 3) return fail("sos_bad_table_selector", error.InvalidMarker);
        var j: usize = 0;
        while (j < frame.num_components) : (j += 1) {
            if (frame.components[j].id == cs) break;
        }
        if (by_position) j = i;
        if (j == frame.num_components) return fail("sos_unknown_component", error.InvalidMarker);
        for (scan.comp[0..i]) |prior| {
            if (prior == j) return fail("sos_duplicate_component", error.InvalidMarker);
        }
        frame.components[j].dc_table = td;
        frame.components[j].ac_table = ta;
        scan.comp[i] = @intCast(j);
        scan.cs_pos[i] = off;
    }
    // Ss/Se/Ah/Al in the last 3 bytes — for baseline they're 0/63/0/0.
    return scan;
}

pub fn noTablesDefined(dc: *const [4]?huffman.HuffmanTable, ac: *const [4]?huffman.HuffmanTable) bool {
    for (dc, ac) |d, a| if (d != null or a != null) return false;
    return true;
}

/// Load the T.81 Annex K.3 tables into destinations 0 (luminance) and 1
/// (chrominance), the Motion-JPEG convention.
pub fn installK3Tables(dc: *[4]?huffman.HuffmanTable, ac: *[4]?huffman.HuffmanTable) void {
    const k3 = @import("k3_tables.zig");
    const build = huffman.HuffmanTable.buildFromDht;
    // The K.3 tables are valid by construction (tested in k3_tables.zig).
    dc[0] = build(k3.dc_luminance.bits, k3.dc_luminance.values) catch unreachable;
    dc[1] = build(k3.dc_chrominance.bits, k3.dc_chrominance.values) catch unreachable;
    ac[0] = build(k3.ac_luminance.bits, k3.ac_luminance.values) catch unreachable;
    ac[1] = build(k3.ac_chrominance.bits, k3.ac_chrominance.values) catch unreachable;
}

/// Finding 70's WARN signature (validate 2026-11-06): a four-component frame
/// with IDs exactly (1, 2, 3, 1), as CMYK/YCCK writers produced by giving K
/// the ID 1. libjpeg-turbo 1.2.0 and later decode these files correctly.
pub fn isKIdOneFrame(frame: *const FrameInfo) bool {
    if (frame.num_components != 4) return false;
    const ids = [_]u8{ 1, 2, 3, 1 };
    for (frame.components, ids) |component, id| if (component.id != id) return false;
    return true;
}

/// The one scan such a frame can name unambiguously: Ns = 4 selecting
/// (1, 2, 3, 1) in order, resolved by position. `body` starts at Ns.
pub fn isKIdOneScan(body: []const u8) bool {
    if (body.len < 1 + 2 * 4 or body[0] != 4) return false;
    const ids = [_]u8{ 1, 2, 3, 1 };
    for (ids, 0..) |id, k| if (body[1 + 2 * k] != id) return false;
    return true;
}
