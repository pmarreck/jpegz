//! Lossless JPEG (T.81 Annex H) frame and scan headers, table parsing
//! and sample access, shared by decoding and validation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const errors = @import("../core/errors.zig");
const types = @import("../core/types.zig");
const bitstream = @import("bitstream.zig");
const huffman = @import("huffman.zig");
const findings_mod = @import("findings.zig");

pub const Error = errors.DecodeError;
const parseSegmentLength = @import("segment.zig").parseSegmentLength;

/// State threaded into decodeScan for restart-marker handling.
pub const RestartCtx = struct {
    interval: u16, // 0 = no restarts
    samples_since: u32 = 0,
    expected_rst: u8 = 0xD0,
    /// True when the next sample(s) — one per scan-component for the
    /// MCU after RST — must use the initial predictor 2^(P-Pt-1) per
    /// T.81 §H.1.2.2. Cleared after each component's first sample of
    /// the next restart interval is emitted.
    force_initial: bool = false,
};

pub const ComponentInfo = struct {
    id: u8,
    h_factor: u4,
    v_factor: u4,
    dc_table: u8 = 0,
};

pub const FrameInfo = struct {
    precision: u8,
    height: u16,
    width: u16,
    num_components: u8,
    components: [4]ComponentInfo,
};

pub const ScanInfo = struct {
    num_components: u8,
    comp_indices: [4]usize,
    predictor: u8, // Ss; 1..7
    point_transform: u4, // Al
};

pub fn parseSof(data: []const u8, pos: usize) Error!FrameInfo {
    const seg_len = parseSegmentLength(data, pos);
    if (seg_len < 8 or pos + seg_len > data.len) return error.TruncatedStream;
    var fi: FrameInfo = undefined;
    fi.precision = data[pos + 2];
    fi.height = (@as(u16, data[pos + 3]) << 8) | data[pos + 4];
    fi.width = (@as(u16, data[pos + 5]) << 8) | data[pos + 6];
    fi.num_components = data[pos + 7];
    if (fi.num_components == 0 or fi.num_components > 4) return error.InvalidMarker;
    if (seg_len != 8 + @as(usize, fi.num_components) * 3) return error.InvalidMarker;
    var i: usize = 0;
    while (i < fi.num_components) : (i += 1) {
        const off = pos + 8 + i * 3;
        fi.components[i] = .{
            .id = data[off],
            .h_factor = @intCast(data[off + 1] >> 4),
            .v_factor = @intCast(data[off + 1] & 0x0F),
            // qt_index byte is at off+2 but is unused for lossless.
        };
        if (fi.components[i].h_factor < 1 or fi.components[i].h_factor > 4 or
            fi.components[i].v_factor < 1 or fi.components[i].v_factor > 4) return error.InvalidMarker;
        for (fi.components[0..i]) |previous| {
            if (previous.id == fi.components[i].id) return error.InvalidMarker;
        }
    }
    return fi;
}

pub fn parseDht(
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
        // T.81 C.2: canonical codes may not overflow their width, and the
        // all-ones code is reserved; an exactly full table (finding 71, which
        // the validator reports) still decodes. Check before indexing.
        if (huffman.codeSpace(bits) == .invalid) return error.InvalidMarker;
        const t = huffman.HuffmanTable.buildFromDht(bits, values) catch
            return error.InvalidMarker;
        dc_tables[th] = t;
        off += total;
    }
}

pub fn parseSos(data: []const u8, pos: usize, frame: *FrameInfo) Error!ScanInfo {
    const seg_len = parseSegmentLength(data, pos);
    if (seg_len < 6 or pos + seg_len > data.len) return error.TruncatedStream;
    var info: ScanInfo = undefined;
    info.num_components = data[pos + 2];
    if (info.num_components == 0 or info.num_components > 4)
        return error.InvalidMarker;
    if (seg_len != 6 + @as(usize, info.num_components) * 2) return error.InvalidMarker;
    var i: usize = 0;
    while (i < info.num_components) : (i += 1) {
        const off = pos + 3 + i * 2;
        const cs = data[off];
        const td_ta = data[off + 1];
        if (td_ta >> 4 > 3 or td_ta & 0x0f != 0) return error.InvalidMarker;
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
        for (info.comp_indices[0..i]) |previous| {
            if (previous >= info.comp_indices[i]) return error.InvalidMarker;
        }
    }
    const tail_off = pos + 3 + @as(usize, info.num_components) * 2;
    info.predictor = data[tail_off];
    if (data[tail_off + 1] != 0) return error.InvalidMarker;
    const ah_al = data[tail_off + 2];
    if (ah_al >> 4 != 0) return error.InvalidMarker;
    info.point_transform = @intCast(ah_al & 0x0F);
    return info;
}

/// Read a single sample from the interleaved output buffer at (y, x, ci).
/// Sample is u8 for sample_bytes==1, u16 host-endian for sample_bytes==2.
pub inline fn sampleAt(
    out: []const u8,
    sample_bytes: usize,
    y: usize,
    x: usize,
    w: usize,
    nc: usize,
    ci: usize,
) i32 {
    const off = ((y * w + x) * nc + ci) * sample_bytes;
    if (sample_bytes == 1) return @intCast(out[off]);
    // Host-endian u16 read
    const lo: u16 = out[off];
    const hi: u16 = out[off + 1];
    const v: u16 = lo | (hi << 8);
    _ = .{}; // silence
    return @intCast(v);
}

pub inline fn writeSample(
    out: []u8,
    sample_bytes: usize,
    y: usize,
    x: usize,
    w: usize,
    nc: usize,
    ci: usize,
    value: u16,
) void {
    const off = ((y * w + x) * nc + ci) * sample_bytes;
    if (sample_bytes == 1) {
        out[off] = @intCast(value & 0xFF);
    } else {
        out[off] = @intCast(value & 0xFF);
        out[off + 1] = @intCast(value >> 8);
    }
}

pub inline fn computePredictorAt(
    selector: u8,
    out: []const u8,
    sample_bytes: usize,
    x: usize,
    y: usize,
    w: usize,
    nc: usize,
    ci: usize,
) i32 {
    const a: i32 = sampleAt(out, sample_bytes, y, x - 1, w, nc, ci);
    const b: i32 = sampleAt(out, sample_bytes, y - 1, x, w, nc, ci);
    const c: i32 = sampleAt(out, sample_bytes, y - 1, x - 1, w, nc, ci);
    return switch (selector) {
        1 => a,
        2 => b,
        3 => c,
        4 => a + b - c,
        5 => a + ((b - c) >> 1),
        6 => b + ((a - c) >> 1),
        7 => (a + b) >> 1,
        else => unreachable,
    };
}
