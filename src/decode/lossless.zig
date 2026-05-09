//! Cleanroom 8-bit lossless JPEG decoder (T.81 SOF3).
//!
//! T.81 §H — predictive lossless coding. No DCT, no quantization, no
//! IDCT rounding: each sample is reconstructed exactly as
//! `(predictor + diff) mod 2^precision`, where `diff` is the
//! Huffman-coded difference between the actual sample and the
//! predictor. The decoder uses one of seven predictor formulas
//! (selected via Ss in the SOS) computed from neighbors a (left),
//! b (above), and c (above-left).
//!
//! v1 scope:
//!   - 8-bit precision (T.81 §H, Pt=0).
//!   - 1 component (grayscale) only — most lossless JPEGs in the wild
//!     are single-component (DICOM, DNG, Lossless JPEG2000-substitute).
//!   - All 7 predictors (Ss = 1..7).
//!   - No restart markers (DRI=0) — the wrapper backstops if needed.
//!
//! Out of scope here, falls back to libjpeg_wrapper:
//!   - 12/16-bit precision (precision 9..16; the wrapper has a separate
//!     `jpeg12_/jpeg16_` API path).
//!   - Multi-component lossless (rare; tiff-with-jpeg-compression uses
//!     it occasionally).
//!   - DRI / restart markers in lossless scans.
//!   - Point transform Al > 0 (sample is shifted up by Al; trivial to
//!     add when needed).
//!
//! Reference: ITU-T T.81 §H.1 (Lossless mode, Annex H).

const std = @import("std");
const Allocator = std.mem.Allocator;
const errors = @import("../core/errors.zig");
const types = @import("../core/types.zig");
const bitstream = @import("bitstream.zig");
const huffman = @import("huffman.zig");

pub const Error = errors.DecodeError;

const ComponentInfo = struct {
    id: u8,
    h_factor: u4,
    v_factor: u4,
    dc_table: u8 = 0,
};

const FrameInfo = struct {
    precision: u8,
    height: u16,
    width: u16,
    num_components: u8,
    components: [4]ComponentInfo,
};

const ScanInfo = struct {
    num_components: u8,
    comp_indices: [4]usize,
    predictor: u8, // Ss; 1..7
    point_transform: u4, // Al
};

/// Decode an 8-bit lossless JPEG (T.81 SOF3). Returns
/// `error.NotImplemented` for any feature this v1 doesn't support
/// (12-bit precision, multi-component, restart markers) so the
/// dispatcher in `src/jpegz.zig` falls back to the wrapper.
pub fn decode(allocator: Allocator, data: []const u8) Error!types.Image {
    if (data.len < 4) return error.TruncatedStream;
    if (data[0] != 0xFF or data[1] != 0xD8) return error.InvalidMarker;

    var pos: usize = 2;
    var frame: ?FrameInfo = null;
    var dc_tables: [4]?huffman.HuffmanTable = .{ null, null, null, null };
    var saw_eoi = false;
    var seen_sof = false;
    var pixels: ?[]u8 = null;
    errdefer if (pixels) |p| allocator.free(p);

    while (pos + 1 < data.len and !saw_eoi) {
        if (data[pos] != 0xFF) return error.InvalidMarker;
        while (pos + 1 < data.len and data[pos + 1] == 0xFF) pos += 1;
        if (pos + 1 >= data.len) return error.TruncatedStream;
        const marker = data[pos + 1];
        pos += 2;
        switch (marker) {
            0xD9 => { saw_eoi = true; break; },
            0xC3 => { // SOF3 — lossless predictive
                frame = try parseSof(data, pos);
                if (frame.?.precision != 8) return error.NotImplemented;
                if (frame.?.num_components != 1) return error.NotImplemented;
                seen_sof = true;
                // For lossless, sampling factors are usually 1×1; reject otherwise.
                const c = &frame.?.components[0];
                if (c.h_factor != 1 or c.v_factor != 1) return error.NotImplemented;
                pos += parseSegmentLength(data, pos);
            },
            0xC0, 0xC1, 0xC2 => return error.NotImplemented, // not lossless
            0xC9, 0xCA, 0xCB => return error.NotImplemented, // arithmetic
            0xC4 => { // DHT — only DC tables matter for lossless
                try parseDht(data, pos, &dc_tables);
                pos += parseSegmentLength(data, pos);
            },
            0xDB => { // DQT — irrelevant for lossless; skip body
                pos += parseSegmentLength(data, pos);
            },
            0xDD => return error.NotImplemented, // DRI in lossless — v1.x follow-up
            0xDA => { // SOS
                if (!seen_sof) return error.InvalidMarker;
                const scan = try parseSos(data, pos, &frame.?);
                if (scan.num_components != 1) return error.NotImplemented;
                if (scan.predictor < 1 or scan.predictor > 7) return error.NotImplemented;
                pos += parseSegmentLength(data, pos);
                pixels = try decodeScan(allocator, data, pos, &frame.?, &dc_tables, &scan);
                // Lossless decode is single-pass; assume EOI follows.
                break;
            },
            0x01, 0xD0...0xD7 => continue, // standalone markers
            else => pos += parseSegmentLength(data, pos), // skip APPn/COM/etc.
        }
    }

    if (!seen_sof) return error.InvalidMarker;
    if (pixels == null) return error.TruncatedStream;

    return types.Image{
        .pixels = pixels.?,
        .width = frame.?.width,
        .height = frame.?.height,
        .channels = 1,
        .bits_per_sample = 8,
        .source_color_space = .grayscale,
        .layout = .grayscale,
    };
}

fn parseSegmentLength(data: []const u8, pos: usize) usize {
    if (pos + 1 >= data.len) return 0;
    return (@as(usize, data[pos]) << 8) | data[pos + 1];
}

fn parseSof(data: []const u8, pos: usize) Error!FrameInfo {
    const seg_len = parseSegmentLength(data, pos);
    if (seg_len < 8 or pos + seg_len > data.len) return error.TruncatedStream;
    var fi: FrameInfo = undefined;
    fi.precision = data[pos + 2];
    fi.height = (@as(u16, data[pos + 3]) << 8) | data[pos + 4];
    fi.width = (@as(u16, data[pos + 5]) << 8) | data[pos + 6];
    fi.num_components = data[pos + 7];
    if (fi.num_components == 0 or fi.num_components > 4) return error.InvalidMarker;
    if (seg_len < 8 + @as(usize, fi.num_components) * 3) return error.TruncatedStream;
    var i: usize = 0;
    while (i < fi.num_components) : (i += 1) {
        const off = pos + 8 + i * 3;
        fi.components[i] = .{
            .id = data[off],
            .h_factor = @intCast(data[off + 1] >> 4),
            .v_factor = @intCast(data[off + 1] & 0x0F),
            // qt_index byte is at off+2 but is unused for lossless.
        };
    }
    return fi;
}

fn parseDht(
    data: []const u8,
    pos: usize,
    dc_tables: *[4]?huffman.HuffmanTable,
) Error!void {
    const seg_len = parseSegmentLength(data, pos);
    if (seg_len < 2 or pos + seg_len > data.len) return error.TruncatedStream;
    var off: usize = pos + 2;
    const seg_end = pos + seg_len;
    while (off < seg_end) {
        if (off + 17 > seg_end) return error.TruncatedStream;
        const tc_th = data[off];
        const tc: u8 = tc_th >> 4;
        const th: u8 = tc_th & 0x0F;
        if (tc != 0 or th > 3) return error.InvalidMarker; // lossless uses DC tables only
        off += 1;
        var bits: [16]u8 = undefined;
        var total: u16 = 0;
        for (0..16) |i| {
            bits[i] = data[off + i];
            total += bits[i];
        }
        off += 16;
        if (off + total > seg_end) return error.TruncatedStream;
        const values = data[off .. off + total];
        const t = huffman.HuffmanTable.buildFromDht(bits, values) catch
            return error.InvalidMarker;
        dc_tables[th] = t;
        off += total;
    }
}

fn parseSos(data: []const u8, pos: usize, frame: *FrameInfo) Error!ScanInfo {
    const seg_len = parseSegmentLength(data, pos);
    if (seg_len < 6 or pos + seg_len > data.len) return error.TruncatedStream;
    var info: ScanInfo = undefined;
    info.num_components = data[pos + 2];
    if (info.num_components == 0 or info.num_components > 4)
        return error.InvalidMarker;
    var i: usize = 0;
    while (i < info.num_components) : (i += 1) {
        const off = pos + 3 + i * 2;
        const cs = data[off];
        const td_ta = data[off + 1];
        var found: bool = false;
        var j: usize = 0;
        while (j < frame.num_components) : (j += 1) {
            if (frame.components[j].id == cs) {
                frame.components[j].dc_table = td_ta >> 4;
                info.comp_indices[i] = j;
                found = true;
                break;
            }
        }
        if (!found) return error.InvalidMarker;
    }
    const tail_off = pos + 3 + @as(usize, info.num_components) * 2;
    info.predictor = data[tail_off];
    // Se byte at tail_off+1 is unused per T.81 §H.1.
    const ah_al = data[tail_off + 2];
    info.point_transform = @intCast(ah_al & 0x0F);
    return info;
}

/// Decode the entropy-coded scan into a `width*height`-byte pixel
/// buffer. Sample reconstruction per T.81 §H.1.2:
///   sample[x,y] = (predictor(x,y) + diff[x,y]) mod 2^precision
/// with predictor selected by Ss (1..7) and special handling for the
/// first sample of the image and the first sample of each row.
fn decodeScan(
    allocator: Allocator,
    data: []const u8,
    entropy_start: usize,
    frame: *const FrameInfo,
    dc_tables: *const [4]?huffman.HuffmanTable,
    scan: *const ScanInfo,
) Error![]u8 {
    const width: usize = frame.width;
    const height: usize = frame.height;
    const out = try allocator.alloc(u8, width * height);
    errdefer allocator.free(out);
    @memset(out, 0);

    const comp_idx = scan.comp_indices[0];
    const comp = &frame.components[comp_idx];
    const dc_t = dc_tables[comp.dc_table] orelse return error.InvalidMarker;

    // Initial predictor for the very first sample: 2^(P - Pt - 1).
    // For 8-bit, Pt=0: initial = 128.
    const precision: u8 = frame.precision;
    const pt: u4 = scan.point_transform;
    const initial_pred: i32 = @as(i32, 1) << @intCast(@as(u8, precision) - @as(u8, pt) - 1);
    const sample_mask: i32 = (@as(i32, 1) << @intCast(precision)) - 1;

    var br = bitstream.BitReader.init(data[entropy_start..]);

    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const predictor: i32 = if (x == 0 and y == 0)
                initial_pred
            else if (y == 0)
                // First row, x > 0 — predictor 1 (left neighbor) regardless of selector.
                @intCast(out[x - 1])
            else if (x == 0)
                // First column, y > 0 — predictor 2 (above neighbor).
                @intCast(out[(y - 1) * width])
            else
                computePredictor(scan.predictor, out, x, y, width);

            // Decode magnitude category SSSS via DC Huffman table.
            const ssss: u8 = dc_t.decode(&br) catch return error.BackendError;
            // Per T.81 §H.1.2.1, SSSS=16 means "diff = 32768" (used only for
            // 16-bit precision; we don't support that yet).
            if (ssss > 16) return error.BackendError;
            var diff: i32 = 0;
            if (ssss == 16) {
                // Special case for 16-bit precision; not in our v1 scope.
                return error.NotImplemented;
            } else if (ssss > 0) {
                const bits = br.readBits(@intCast(ssss)) catch return error.TruncatedStream;
                diff = @intCast(huffman.extendSign(bits, @intCast(ssss)));
            }

            const sample: i32 = (predictor + diff) & sample_mask;
            out[y * width + x] = @intCast(sample);
        }
    }

    return out;
}

inline fn computePredictor(selector: u8, out: []const u8, x: usize, y: usize, w: usize) i32 {
    const a: i32 = @intCast(out[y * w + (x - 1)]);
    const b: i32 = @intCast(out[(y - 1) * w + x]);
    const c: i32 = @intCast(out[(y - 1) * w + (x - 1)]);
    return switch (selector) {
        1 => a, // T.81 §H.1.2.1.1.1: Pa = a
        2 => b, // Pb = b
        3 => c, // Pc = c
        4 => a + b - c, // a + b - c
        5 => a + ((b - c) >> 1), // a + (b - c) / 2
        6 => b + ((a - c) >> 1), // b + (a - c) / 2
        7 => (a + b) >> 1, // (a + b) / 2
        else => unreachable, // pre-validated 1..7
    };
}
