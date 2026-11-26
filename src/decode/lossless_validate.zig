//! Lossless JPEG syntax validation: walks the frame, scan and entropy data
//! without producing pixels (the codec check for SOF3).

const std = @import("std");
const Allocator = std.mem.Allocator;
const errors = @import("../core/errors.zig");
const types = @import("../core/types.zig");
const bitstream = @import("bitstream.zig");
const huffman = @import("huffman.zig");
const findings_mod = @import("findings.zig");

pub const Error = errors.DecodeError;
const parseSegmentLength = @import("segment.zig").parseSegmentLength;

const lframe = @import("lossless_frame.zig");
const RestartCtx = lframe.RestartCtx;
const ComponentInfo = lframe.ComponentInfo;
const FrameInfo = lframe.FrameInfo;
const ScanInfo = lframe.ScanInfo;
const parseSof = lframe.parseSof;
const parseDht = lframe.parseDht;
const parseSos = lframe.parseSos;
const sampleAt = lframe.sampleAt;
const writeSample = lframe.writeSample;
const computePredictorAt = lframe.computePredictorAt;

/// Validate lossless Huffman syntax without allocating or upsampling pixels.
/// Supports a single full-component scan (1..4 components), including unequal
/// sampling. DNL and separated component scans remain explicitly unsupported.
/// Offsets identify the payload-relative detection cursor, not the byte whose
/// mutation caused desynchronization. No sample-domain or image-content claim.
pub fn validate(data: []const u8, sink: *findings_mod.FindingsSink) Error!void {
    var offset: usize = 0;
    const findings_start = sink.items().len;
    validateSyntax(data, &offset, sink) catch |err| {
        const typed = for (sink.items()[findings_start..]) |finding| {
            if (finding.severity == .fail) break true;
        } else false;
        if (err != error.NotImplemented and !typed) {
            try sink.emit(.fail, if (err == error.TruncatedStream) .truncated_stream else .huffman_table_corrupt, @intCast(@min(offset, data.len)), @errorName(err));
        }
        return err;
    };
}

pub fn validateSyntax(data: []const u8, offset: *usize, sink: *findings_mod.FindingsSink) Error!void {
    if (data.len < 2) return error.TruncatedStream;
    if (data[0] != 0xff or data[1] != 0xd8) return error.InvalidMarker;
    var pos: usize = 2;
    var frame: ?FrameInfo = null;
    var tables: [4]?huffman.HuffmanTable = .{ null, null, null, null };
    var restart: u16 = 0;
    var scanned = false;
    while (true) {
        offset.* = pos;
        if (pos + 1 >= data.len) return error.TruncatedStream;
        if (data[pos] != 0xff) return error.InvalidMarker;
        while (pos + 1 < data.len and data[pos + 1] == 0xff) pos += 1;
        if (pos + 1 >= data.len) return error.TruncatedStream;
        const marker = data[pos + 1];
        pos += 2;
        if (marker == 0xd9) {
            if (!scanned) return error.TruncatedStream;
            // The public marker walker separately reports bytes after EOI.
            return;
        }
        if (marker == 0xdc) return error.NotImplemented; // DNL may redefine Y.
        // These have no length field; none is legal here in a SOF3 frame.
        if (marker == 0x00 or marker == 0x01 or marker == 0xd8 or
            (marker >= 0xd0 and marker <= 0xd7)) return error.InvalidMarker;
        const len = parseSegmentLength(data, pos);
        if (len < 2 or pos + len > data.len) return error.TruncatedStream;
        switch (marker) {
            0xc3 => {
                if (frame != null) return error.InvalidMarker;
                if (len >= 8 and data[pos + 7] > 4) return error.NotImplemented;
                frame = try parseSof(data, pos);
                if (frame.?.precision < 2 or frame.?.precision > 16 or frame.?.width == 0)
                    return error.InvalidMarker;
                if (frame.?.height == 0) return error.NotImplemented;
            },
            0xc4 => try parseDht(data, pos, &tables),
            0xdd => {
                if (len != 4) return error.InvalidMarker;
                restart = (@as(u16, data[pos + 2]) << 8) | data[pos + 3];
            },
            0xda => {
                if (frame == null or scanned) return error.InvalidMarker;
                const scan = try parseSos(data, pos, &frame.?);
                if (scan.num_components != frame.?.num_components) return error.NotImplemented;
                if (scan.predictor < 1 or scan.predictor > 7) return error.InvalidMarker;
                if (scan.point_transform >= frame.?.precision) return error.NotImplemented;
                pos += len;
                pos = try validateEntropy(data, pos, &frame.?, &scan, &tables, restart, offset, sink);
                scanned = true;
                continue;
            },
            0xdb, 0xe0...0xef, 0xfe => {}, // Unused DQT, application data, comments.
            else => return error.NotImplemented,
        }
        pos += len;
    }
}

pub fn validateEntropy(data: []const u8, start: usize, frame: *const FrameInfo, scan: *const ScanInfo, tables: *const [4]?huffman.HuffmanTable, restart: u16, offset: *usize, sink: *findings_mod.FindingsSink) Error!usize {
    var max_h: usize = 1;
    var max_v: usize = 1;
    var samples_per_mcu: usize = 0;
    for (frame.components[0..frame.num_components]) |comp| {
        max_h = @max(max_h, comp.h_factor);
        max_v = @max(max_v, comp.v_factor);
        samples_per_mcu += @as(usize, comp.h_factor) * comp.v_factor;
    }
    const interleaved = scan.num_components > 1;
    if (interleaved and samples_per_mcu > 10) return error.InvalidMarker;
    const columns = if (interleaved) std.math.divCeil(usize, frame.width, max_h) catch unreachable else frame.width;
    const rows = if (interleaved) std.math.divCeil(usize, frame.height, max_v) catch unreachable else frame.height;
    if (restart % columns != 0) return error.InvalidMarker;
    for (scan.comp_indices[0..scan.num_components]) |ci| {
        if (tables[frame.components[ci].dc_table] == null) return error.InvalidMarker;
    }
    var br = bitstream.BitReader.init(data[start..]);
    // Update the cursor even when lookahead encountered an early marker.
    errdefer offset.* = start + br.byte_pos;
    var expected_rst: u8 = 0xd0;
    for (0..columns * rows) |mcu| {
        if (restart != 0 and mcu != 0 and mcu % restart == 0) {
            const marker = br.finishHuffmanSegment() catch |err| try zeroPadMarker(&br, err, start, sink);
            if (marker == 0xdc) return error.NotImplemented;
            // As on the sequential path: a wrong RSTm is 57, another marker 56.
            if (marker != expected_rst) {
                var buf: [64]u8 = undefined;
                const at = start + br.byte_pos;
                if (marker >= 0xd0 and marker <= 0xd7) {
                    try sink.emitExact(.fail, .restart_marker_unexpected, at, std.fmt.bufPrint(&buf, "expected RST{d} (0x{x:0>2}) but got RST{d} (0x{x:0>2})", .{ expected_rst - 0xd0, expected_rst, marker - 0xd0, marker }) catch buf[0..0]);
                } else {
                    try sink.emitExact(.fail, .restart_marker_missing, at, std.fmt.bufPrint(&buf, "marker 0x{x:0>2} where RST{d} belongs", .{ marker, expected_rst - 0xd0 }) catch buf[0..0]);
                }
                return error.InvalidMarker;
            }
            br.skipPastMarker();
            expected_rst = 0xd0 + ((expected_rst - 0xd0 + 1) & 7);
        }
        for (scan.comp_indices[0..scan.num_components]) |ci| {
            const comp = frame.components[ci];
            const count = if (interleaved) @as(usize, comp.h_factor) * comp.v_factor else 1;
            for (0..count) |_| {
                const code_mark = br.mark();
                const category = tables[comp.dc_table].?.decode(&br) catch return dataFault(&br, start, sink, code_mark);
                if (category > 16) {
                    // Validate 2026-11-22: 58, exact at the code.
                    var buf: [80]u8 = undefined;
                    try sink.emitExact(.fail, .dct_coefficient_overflow, start + br.markOffset(code_mark), std.fmt.bufPrint(&buf, "difference category {d} exceeds 16 (T.81 H.1.2.2)", .{category}) catch buf[0..0]);
                    return error.BackendError;
                }
                // H.1.2.2: category16 carries no amplitude; other nonzero
                // categories carry that many bits. Predictor4 can exceed P.
                if (category > 0 and category < 16)
                    _ = br.readBits(@intCast(category)) catch return dataFault(&br, start, sink, null);
            }
        }
    }
    const marker = br.finishHuffmanSegment() catch |err| try zeroPadMarker(&br, err, start, sink);
    if (marker == 0xdc) return error.NotImplemented;
    if (marker >= 0xd0 and marker <= 0xd7) {
        try sink.emitExact(.fail, .restart_marker_unexpected, start + br.byte_pos, "restart marker after the final MCU of the scan");
        return error.InvalidMarker;
    }
    return start + br.byte_pos;
}

/// A difference that cannot be decoded (validate rulings 2026-11-22). Data
/// that runs into a marker is `insufficient_data` at the marker; a code that
/// matches no table entry (`mark` is where it began) is 74, exact. A DNL
/// stays unsupported, and data that simply ends is left to the marker walk.
pub fn dataFault(br: *const bitstream.BitReader, start: usize, sink: *findings_mod.FindingsSink, mark: ?bitstream.BitReader.Mark) Error {
    var boundary = br.*;
    if (boundary.marker_seen) {
        boundary.seekToMarker();
        if (boundary.marker_seen and boundary.marker_byte == 0xdc) return error.NotImplemented;
        // This path stops here rather than recovering, so the report's FAIL is
        // emitted directly.
        sink.emit(.fail, .insufficient_data, @intCast(start + br.byte_pos), "Corrupt JPEG data: premature end of data segment") catch return error.OutOfMemory;
        return error.BackendError;
    }
    if (br.byte_pos >= br.data.len) return error.TruncatedStream;
    if (mark) |m| sink.emitExact(.fail, .entropy_decode_invalid, start + br.markOffset(m), "difference Huffman code matches no table entry") catch return error.OutOfMemory;
    return error.BackendError;
}

/// All-zero pad bits are a known encoder defect (finding 63, T.81 §F.1.2.3):
/// report the WARN and return the marker that follows them. Every other
/// segment-boundary fault keeps its error; mixed padding emits FAIL 62.
/// `base` is the file offset of
/// `br.data[0]`.
pub fn zeroPadMarker(br: *bitstream.BitReader, err: anyerror, base: usize, sink: *findings_mod.FindingsSink) Error!u8 {
    if (err == error.PaddingNotOnes) {
        try sink.emitExact(.fail, .entropy_padding_not_ones, base + br.padByteOffset(), "mixed Huffman pad bits before marker (T.81 F.1.2.3)");
    }
    if (err == error.InvalidEntropyBoundary) {
        // Whole bytes after valid padding (libjpeg's "extraneous bytes
        // before marker"): FAIL 8 at the first (validate, 2026-11-22).
        if (br.trailingBytesAfterPadding()) |trailing| {
            var buf: [96]u8 = undefined;
            const detail = std.fmt.bufPrint(&buf, "{d} whole {s} after valid padding before marker 0x{X:0>2}", .{
                trailing.count, if (trailing.count == 1) "byte" else "bytes", trailing.marker,
            }) catch unreachable;
            try sink.emitExact(.fail, .extraneous_bytes_before_marker, base + trailing.first, detail);
            return error.BackendError;
        }
    }
    if (err != error.PaddingZeroBits) return entropyError(br);
    try sink.emitZeroPadding(base + br.padByteOffset(), br.padBitCount());
    br.seekToMarker();
    if (!br.marker_seen) return entropyError(br);
    return br.marker_byte;
}

pub fn entropyError(br: *const bitstream.BitReader) Error {
    var boundary = br.*;
    if (boundary.marker_seen) boundary.seekToMarker();
    if (boundary.marker_seen and boundary.marker_byte == 0xdc) return error.NotImplemented;
    return if (br.byte_pos >= br.data.len) error.TruncatedStream else error.BackendError;
}
