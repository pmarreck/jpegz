//! Shared T.81 marker-segment parsers + frame types for the Huffman
//! DCT decoders (baseline SOF0 + progressive SOF2), whose SOF/DQT/DHT
//! parsing and frame-header layout are byte-identical.
//!
//! Scope (deliberately narrow — verified, not assumed):
//!   - SHARED here: ComponentInfo, FrameInfo, parseSof, parseDqt,
//!     parseDht. baseline and progressive carry identical versions of
//!     these (modulo the now-unified `fail` tracer).
//!   - NOT shared: `parseSos` — progressive's SOS carries spectral-
//!     selection / successive-approximation params (Ss/Se/Ah/Al) that
//!     baseline's omits; each keeps its own.
//!   - NOT shared with lossless (SOF3) — its ComponentInfo is a subset
//!     (no qt_index/ac_table) and its DHT is DC-tables-only.
//!   - NOT shared with JPEG-LS (SOF55) — different codec, different SOF
//!     layout (`P` precision field, etc.).

const errors = @import("../core/errors.zig");
const huffman = @import("huffman.zig");
const segment = @import("segment.zig");
const diag = @import("diag.zig");

pub const Error = errors.DecodeError;

const parseSegmentLength = segment.parseSegmentLength;

inline fn fail(comptime tag: []const u8, err: Error) Error {
    return diag.fail("markers:" ++ tag, err);
}

pub const ComponentInfo = struct {
    /// Component selector (Ci in T.81 SOF — usually 1 for Y, 2 for Cb, 3 for Cr).
    id: u8,
    /// Sampling factors.
    h_factor: u4,
    v_factor: u4,
    /// Quantization table selector (0..3).
    qt_index: u8,
    /// DC + AC Huffman table selectors (set when SOS parsed).
    dc_table: u8 = 0,
    ac_table: u8 = 0,
};

pub const FrameInfo = struct {
    precision: u8,
    height: u16,
    width: u16,
    num_components: u8,
    components: [4]ComponentInfo,
};

/// Parse a SOFn frame header (T.81 §B.2.2). Shared by SOF0 (baseline)
/// and SOF2 (progressive) — identical layout.
pub fn parseSof(data: []const u8, pos: usize) Error!FrameInfo {
    const seg_len = parseSegmentLength(data, pos);
    if (seg_len < 8 or pos + seg_len > data.len) return error.TruncatedStream;
    var fi: FrameInfo = undefined;
    fi.precision = data[pos + 2];
    fi.height = (@as(u16, data[pos + 3]) << 8) | data[pos + 4];
    fi.width = (@as(u16, data[pos + 5]) << 8) | data[pos + 6];
    fi.num_components = data[pos + 7];
    if (fi.num_components == 0 or fi.num_components > 4) return fail("sof_bad_ncomp", error.InvalidMarker);
    // T.81 §B.2.2: X (width) must be > 0; Y (height) = 0 is defined only
    // alongside a DNL segment, which this decoder (like libjpeg without
    // DNL support) does not accept. Reject zero dimensions here so no
    // downstream allocation / MCU assembly / chroma upsampling ever runs
    // over an empty component plane (was an OOB crash in color.fancyUpsample).
    if (fi.width == 0 or fi.height == 0) return fail("sof_zero_dimension", error.InvalidMarker);
    if (seg_len < 8 + @as(usize, fi.num_components) * 3) return error.TruncatedStream;
    var i: usize = 0;
    while (i < fi.num_components) : (i += 1) {
        const off = pos + 8 + i * 3;
        // T.81 §B.2.2 Table B.2: Tq selects one of FOUR quantization-table
        // destinations, but it is a whole byte on disk, so it can name table
        // 255. The scan decoder indexes `quant_tables[comp.qt_index]` on a
        // [4] array, so an unchecked value reads out of bounds — same defect
        // class as `sof_zero_dimension` above.
        const tq = data[off + 2];
        if (tq > 3) return fail("sof_bad_quant_selector", error.InvalidMarker);
        fi.components[i] = .{
            .id = data[off],
            .h_factor = @intCast(data[off + 1] >> 4),
            .v_factor = @intCast(data[off + 1] & 0x0F),
            .qt_index = tq,
        };
    }
    return fi;
}

/// Parse a DQT segment (T.81 §B.2.4.1) — one or more 8- or 16-bit
/// quantization tables into the `quant_tables` slots.
pub fn parseDqt(
    data: []const u8,
    pos: usize,
    quant_tables: *[4]?[64]u16,
) Error!void {
    const seg_len = parseSegmentLength(data, pos);
    if (seg_len < 2 or pos + seg_len > data.len) return error.TruncatedStream;
    var off: usize = pos + 2;
    const seg_end = pos + seg_len;
    while (off < seg_end) {
        if (off >= data.len) return error.TruncatedStream;
        const pq_tq = data[off];
        const precision_id: u8 = pq_tq >> 4; // 0 = 8-bit, 1 = 16-bit
        const tq: u8 = pq_tq & 0x0F;
        if (tq > 3) return fail("dqt_bad_tq", error.InvalidMarker);
        off += 1;
        var table: [64]u16 = undefined;
        if (precision_id == 0) {
            if (off + 64 > seg_end) return error.TruncatedStream;
            var i: usize = 0;
            while (i < 64) : (i += 1) table[i] = data[off + i];
            off += 64;
        } else if (precision_id == 1) {
            if (off + 128 > seg_end) return error.TruncatedStream;
            var i: usize = 0;
            while (i < 64) : (i += 1) {
                table[i] = (@as(u16, data[off + i * 2]) << 8) | data[off + i * 2 + 1];
            }
            off += 128;
        } else return fail("dqt_bad_precision_id", error.InvalidMarker);
        quant_tables[tq] = table;
    }
}

/// Parse a DHT segment (T.81 §B.2.4.2) — Huffman tables into the DC /
/// AC slots per the Tc class bit.
pub fn parseDht(
    data: []const u8,
    pos: usize,
    dc_tables: *[4]?huffman.HuffmanTable,
    ac_tables: *[4]?huffman.HuffmanTable,
) Error!void {
    const seg_len = parseSegmentLength(data, pos);
    if (seg_len < 2 or pos + seg_len > data.len) return error.TruncatedStream;
    var off: usize = pos + 2;
    const seg_end = pos + seg_len;
    while (off < seg_end) {
        if (off + 17 > seg_end) return error.TruncatedStream;
        const tc_th = data[off];
        const tc: u8 = tc_th >> 4; // 0 = DC, 1 = AC
        const th: u8 = tc_th & 0x0F;
        if (tc > 1 or th > 3) return fail("dht_bad_tc_th", error.InvalidMarker);
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
            return fail("dht_build_failed", error.InvalidMarker);
        if (tc == 0) dc_tables[th] = t else ac_tables[th] = t;
        off += total;
    }
}
