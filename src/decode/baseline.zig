//! Cleanroom 8-bit baseline JPEG decoder (T.81 SOF0).
//!
//! v1 scope:
//!   - 8-bit precision (T.81 §A.4)
//!   - Sequential DCT with Huffman entropy coding (SOF0)
//!   - 1 component (grayscale) or 3 components (RGB / YCbCr)
//!   - Sampling factors: all components 1×1 (no chroma subsampling)
//!   - No restart markers (DRI=0)
//!   - All segments present and well-formed
//!
//! Out of scope for this iteration (handled by libjpeg_wrapper fallback):
//!   - SOF1 (extended sequential), SOF2 (progressive), SOF3 (lossless)
//!   - Arithmetic-coded variants (SOF9/10/11)
//!   - Chroma subsampling (4:2:0, 4:2:2 — see Tier 1 fixtures)
//!   - Restart markers
//!   - 12-bit precision
//!   - CMYK / YCCK
//!
//! Reference: ITU-T T.81 (1992), Annex F (sequential DCT).

const std = @import("std");
const Allocator = std.mem.Allocator;
const errors = @import("../core/errors.zig");
const types = @import("../core/types.zig");
const bitstream = @import("bitstream.zig");
const huffman = @import("huffman.zig");
const idct = @import("idct.zig");

/// JPEG zig-zag scan order (T.81 Figure A.6). Maps zig-zag index
/// (the order in which AC coefficients arrive in the entropy stream)
/// to natural (row-major) order in the 8×8 block.
const ZIGZAG: [64]u8 = .{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

const ComponentInfo = struct {
    /// Component selector (Ci in T.81 SOF — usually 1 for Y, 2 for Cb, 3 for Cr).
    id: u8,
    /// Sampling factors. We only support 1×1 in v1.
    h_factor: u4,
    v_factor: u4,
    /// Quantization table selector (0..3).
    qt_index: u8,
    /// DC + AC Huffman table selectors (set when SOS parsed).
    dc_table: u8 = 0,
    ac_table: u8 = 0,
};

const FrameInfo = struct {
    precision: u8,
    height: u16,
    width: u16,
    num_components: u8,
    components: [4]ComponentInfo,
};

pub const Error = errors.DecodeError;

/// Decode an 8-bit baseline JPEG.
///
/// Returns `error.NotImplemented` for any feature the v1 cleanroom
/// doesn't yet support (subsampling != 1×1, restart markers, etc.) —
/// the caller (`src/jpegz.zig`) is expected to fall back to the
/// libjpeg-turbo wrapper in that case.
pub fn decode(allocator: Allocator, data: []const u8) Error!types.Image {
    if (data.len < 4) return error.TruncatedStream;
    if (data[0] != 0xFF or data[1] != 0xD8) return error.InvalidMarker;

    var pos: usize = 2;
    var frame: ?FrameInfo = null;
    var quant_tables: [4]?[64]u16 = .{ null, null, null, null };
    var dc_tables: [4]?huffman.HuffmanTable = .{ null, null, null, null };
    var ac_tables: [4]?huffman.HuffmanTable = .{ null, null, null, null };
    // Restart interval (DRI marker) — number of MCUs between RSTm
    // resync markers. 0 disables restart handling.
    var restart_interval: u32 = 0;

    // ── Marker walk until we reach SOS ─────────────────────────
    while (pos + 1 < data.len) {
        if (data[pos] != 0xFF) return error.InvalidMarker;
        // Skip 0xFF padding.
        while (pos + 1 < data.len and data[pos + 1] == 0xFF) pos += 1;
        if (pos + 1 >= data.len) return error.TruncatedStream;
        const marker = data[pos + 1];
        pos += 2;

        switch (marker) {
            0xD9 => return error.TruncatedStream, // EOI before SOS
            0xC0 => { // SOF0 — baseline DCT
                frame = try parseSof(data, pos);
                if (frame.?.precision != 8) return error.UnsupportedPrecision;
                if (frame.?.num_components != 1 and frame.?.num_components != 3)
                    return error.NotImplemented;
                // Sampling factors: v2 supports any h/v_factor in 1..4
                // (the spec maximum) including the common 4:2:0 and 4:2:2 layouts.
                var i: usize = 0;
                while (i < frame.?.num_components) : (i += 1) {
                    const c = &frame.?.components[i];
                    if (c.h_factor < 1 or c.h_factor > 4 or c.v_factor < 1 or c.v_factor > 4)
                        return error.NotImplemented;
                }
                pos += parseSegmentLength(data, pos);
            },
            0xC1, 0xC2, 0xC3 => return error.NotImplemented, // SOF1/2/3
            0xC9, 0xCA, 0xCB => return error.NotImplemented, // SOF9/10/11
            0xC4 => { // DHT
                try parseDht(data, pos, &dc_tables, &ac_tables);
                pos += parseSegmentLength(data, pos);
            },
            0xDB => { // DQT
                try parseDqt(data, pos, &quant_tables);
                pos += parseSegmentLength(data, pos);
            },
            0xDD => { // DRI — Define Restart Interval (T.81 §B.2.4.4)
                const seg_len = parseSegmentLength(data, pos);
                if (seg_len < 4 or pos + seg_len > data.len) return error.TruncatedStream;
                restart_interval = (@as(u32, data[pos + 2]) << 8) | data[pos + 3];
                pos += seg_len;
            },
            0xDA => { // SOS — entropy data follows
                if (frame == null) return error.InvalidMarker;
                try parseSos(data, pos, &frame.?);
                pos += parseSegmentLength(data, pos);
                // Decode the entropy stream, get pixels.
                return try decodeScan(
                    allocator,
                    data[pos..],
                    &frame.?,
                    &quant_tables,
                    &dc_tables,
                    &ac_tables,
                    restart_interval,
                );
            },
            // Standalone markers we can skip safely:
            0x01, 0xD0...0xD7 => continue, // TEM, RST0..RST7
            // Length-prefixed markers we can skip (APPn, COM, etc.):
            else => pos += parseSegmentLength(data, pos),
        }
    }

    return error.TruncatedStream;
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
            .qt_index = data[off + 2],
        };
    }
    return fi;
}

fn parseDqt(
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
        if (tq > 3) return error.InvalidMarker;
        off += 1;
        var table: [64]u16 = undefined;
        if (precision_id == 0) {
            // 8-bit values
            if (off + 64 > seg_end) return error.TruncatedStream;
            var i: usize = 0;
            while (i < 64) : (i += 1) {
                table[i] = data[off + i];
            }
            off += 64;
        } else if (precision_id == 1) {
            if (off + 128 > seg_end) return error.TruncatedStream;
            var i: usize = 0;
            while (i < 64) : (i += 1) {
                table[i] = (@as(u16, data[off + i * 2]) << 8) | data[off + i * 2 + 1];
            }
            off += 128;
        } else return error.InvalidMarker;
        quant_tables[tq] = table;
    }
}

fn parseDht(
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
        if (tc > 1 or th > 3) return error.InvalidMarker;
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
        if (tc == 0) dc_tables[th] = t else ac_tables[th] = t;
        off += total;
    }
}

fn parseSos(data: []const u8, pos: usize, frame: *FrameInfo) Error!void {
    const seg_len = parseSegmentLength(data, pos);
    if (seg_len < 6 or pos + seg_len > data.len) return error.TruncatedStream;
    const ns = data[pos + 2];
    if (ns != frame.num_components) return error.InvalidMarker;
    var i: usize = 0;
    while (i < ns) : (i += 1) {
        const off = pos + 3 + i * 2;
        const cs = data[off];
        const td_ta = data[off + 1];
        // Find the matching component in frame.components by ID.
        var j: usize = 0;
        while (j < frame.num_components) : (j += 1) {
            if (frame.components[j].id == cs) {
                frame.components[j].dc_table = td_ta >> 4;
                frame.components[j].ac_table = td_ta & 0x0F;
                break;
            }
        }
    }
    // Ss/Se/Ah/Al in the last 3 bytes — for baseline they're 0/63/0/0.
}

fn decodeScan(
    allocator: Allocator,
    data: []const u8,
    frame: *const FrameInfo,
    quant_tables: *const [4]?[64]u16,
    dc_tables: *const [4]?huffman.HuffmanTable,
    ac_tables: *const [4]?huffman.HuffmanTable,
    restart_interval: u32,
) Error!types.Image {
    const channels: u8 = frame.num_components;
    const width: u32 = frame.width;
    const height: u32 = frame.height;

    // Compute max h/v sampling factors across all components. These
    // define the MCU size in pixels: max_h*8 wide × max_v*8 tall.
    // Per-component plane is sized at the component's natural
    // resolution: mcu_cols * comp.h_factor * 8 wide, etc.
    var max_h: u32 = 1;
    var max_v: u32 = 1;
    {
        var i: usize = 0;
        while (i < channels) : (i += 1) {
            const c = &frame.components[i];
            if (@as(u32, c.h_factor) > max_h) max_h = @intCast(c.h_factor);
            if (@as(u32, c.v_factor) > max_v) max_v = @intCast(c.v_factor);
        }
    }
    const mcu_pixel_w: u32 = max_h * 8;
    const mcu_pixel_h: u32 = max_v * 8;
    const mcu_cols: u32 = (width + mcu_pixel_w - 1) / mcu_pixel_w;
    const mcu_rows: u32 = (height + mcu_pixel_h - 1) / mcu_pixel_h;

    // Per-component plane dimensions (at component's natural resolution).
    var plane_w: [3]u32 = .{ 0, 0, 0 };
    var plane_h: [3]u32 = .{ 0, 0, 0 };
    {
        var i: usize = 0;
        while (i < channels) : (i += 1) {
            plane_w[i] = mcu_cols * @as(u32, frame.components[i].h_factor) * 8;
            plane_h[i] = mcu_rows * @as(u32, frame.components[i].v_factor) * 8;
        }
    }

    var planes: [3][]u8 = .{ &.{}, &.{}, &.{} };
    {
        var i: usize = 0;
        while (i < channels) : (i += 1) {
            planes[i] = try allocator.alloc(u8, plane_w[i] * plane_h[i]);
        }
    }
    errdefer {
        var j: usize = 0;
        while (j < channels) : (j += 1) {
            if (planes[j].len > 0) allocator.free(planes[j]);
        }
    }

    var br = bitstream.BitReader.init(data);
    var prev_dc: [3]i16 = .{ 0, 0, 0 };
    // Counts MCUs since the last RST. Reset to zero on every RST
    // (and at scan start). Used only when restart_interval > 0.
    var mcus_since_rst: u32 = 0;
    // Expected next RST marker byte (cycles 0xD0..0xD7). T.81 §F.2.1.3.
    var expected_rst: u8 = 0xD0;

    var mcu_y: u32 = 0;
    while (mcu_y < mcu_rows) : (mcu_y += 1) {
        var mcu_x: u32 = 0;
        while (mcu_x < mcu_cols) : (mcu_x += 1) {
            // ── Restart-interval handling (T.81 §F.2.1.3.2) ────
            // After `restart_interval` MCUs, the entropy stream is
            // realigned: bit buffer flushed to next byte boundary,
            // an RSTm marker (FF D0..D7) consumed, prev_dc reset
            // to zero. Markers cycle through 0..7 across the scan.
            if (restart_interval > 0 and mcus_since_rst == restart_interval) {
                // skipEntropyData-style helper: byte-align the reader.
                // Our BitReader's marker_seen state already triggers
                // on encountering the RST in the stream during the
                // previous block decode. After the marker is reached,
                // the bit buffer is empty and marker_byte is set.
                if (!br.marker_seen) return error.InvalidMarker;
                if (br.marker_byte != expected_rst) return error.InvalidMarker;
                // Reset for the next interval.
                prev_dc = .{ 0, 0, 0 };
                mcus_since_rst = 0;
                expected_rst = 0xD0 + ((expected_rst - 0xD0 + 1) & 0x07);
                // Re-init the BitReader from the byte position just
                // PAST the RST marker — the BitReader stops *before*
                // the FF byte of the marker, so we advance by 2.
                const consumed_pos: usize = br.byte_pos + 2;
                if (consumed_pos > data.len) return error.TruncatedStream;
                br = bitstream.BitReader.init(data[consumed_pos..]);
            }
            // Per T.81 §A.2.3 / F.1.5: when the scan has multiple
            // components, the MCU contains, for each component in
            // SOS order, (h_factor × v_factor) blocks. Within a
            // component's blocks: row-major (top-to-bottom, then
            // left-to-right). E.g. 4:2:0 RGB MCU: Y[0,0] Y[0,1]
            // Y[1,0] Y[1,1] Cb[0,0] Cr[0,0].
            var ci: usize = 0;
            while (ci < channels) : (ci += 1) {
                const comp = &frame.components[ci];
                const blocks_v: u32 = @intCast(comp.v_factor);
                const blocks_h: u32 = @intCast(comp.h_factor);
                var block_v: u32 = 0;
                while (block_v < blocks_v) : (block_v += 1) {
                    var block_h: u32 = 0;
                    while (block_h < blocks_h) : (block_h += 1) {
                        try decodeBlock(
                            &br,
                            ci,
                            comp,
                            dc_tables,
                            ac_tables,
                            quant_tables,
                            &prev_dc,
                            planes[ci],
                            plane_w[ci],
                            mcu_x * blocks_h * 8 + block_h * 8,
                            mcu_y * blocks_v * 8 + block_v * 8,
                        );
                    }
                }
            }
            mcus_since_rst += 1;
        }
    }

    // After block decoding, fall through to the assembly section
    // below. The original per-block decode-inline code is now in
    // decodeBlock(); the rest of this function is the assembly path.
    return assembleOutput(allocator, frame, channels, width, height, max_h, max_v, plane_w, plane_h, &planes);
}

/// Decode a single 8×8 block from the entropy stream and place its
/// spatial samples into `plane` at (block_x_pixels, block_y_pixels).
/// Updates `prev_dc[ci]` (DC differential per component, T.81 §F.2.2.1).
fn decodeBlock(
    br: *bitstream.BitReader,
    ci: usize,
    comp: *const ComponentInfo,
    dc_tables: *const [4]?huffman.HuffmanTable,
    ac_tables: *const [4]?huffman.HuffmanTable,
    quant_tables: *const [4]?[64]u16,
    prev_dc: *[3]i16,
    plane: []u8,
    plane_w: u32,
    block_x: u32,
    block_y: u32,
) Error!void {
    const dc_t = dc_tables[comp.dc_table] orelse return error.InvalidMarker;
    const ac_t = ac_tables[comp.ac_table] orelse return error.InvalidMarker;
    const qt = quant_tables[comp.qt_index] orelse return error.InvalidMarker;

    // Coefficients stored in zig-zag order during entropy decode;
    // dequantized in zig-zag (matches DQT layout per T.81 §B.2.4.1);
    // un-zig-zagged for IDCT input (which expects natural row-major).
    var zz: [64]i16 = .{0} ** 64;

    // ── DC coefficient (T.81 §F.2.2.1) ─────────────────────────
    const dc_size: u8 = dc_t.decode(br) catch return error.BackendError;
    if (dc_size > 11) return error.BackendError;
    var dc_diff: i16 = 0;
    if (dc_size > 0) {
        const bits = br.readBits(@intCast(dc_size)) catch return error.TruncatedStream;
        dc_diff = huffman.extendSign(bits, @intCast(dc_size));
    }
    prev_dc[ci] += dc_diff;
    zz[0] = prev_dc[ci];

    // ── 63 AC coefficients (T.81 §F.2.2.2) ─────────────────────
    var k: usize = 1;
    while (k < 64) {
        const rs: u8 = ac_t.decode(br) catch return error.BackendError;
        if (rs == 0x00) break; // EOB — rest of block is zero
        if (rs == 0xF0) {
            k += 16; // ZRL — 16 zeros (already zeroed; just advance)
            continue;
        }
        const run: u8 = rs >> 4;
        const size: u8 = rs & 0x0F;
        if (size == 0 or size > 10) return error.BackendError;
        k += run;
        if (k >= 64) return error.BackendError;
        const bits = br.readBits(@intCast(size)) catch return error.TruncatedStream;
        const val = huffman.extendSign(bits, @intCast(size));
        zz[k] = val;
        k += 1;
    }

    // ── Dequantize in zig-zag space ────────────────────────────
    var n: usize = 0;
    while (n < 64) : (n += 1) {
        zz[n] = @as(i16, @intCast(@as(i32, zz[n]) * @as(i32, qt[n])));
    }

    // ── Un-zig-zag into natural row-major order ────────────────
    var coeffs: [64]i16 = undefined;
    n = 0;
    while (n < 64) : (n += 1) {
        coeffs[ZIGZAG[n]] = zz[n];
    }

    // ── IDCT to spatial samples ───────────────────────────────
    var block: [64]u8 = undefined;
    idct.idct8x8(&coeffs, &block);

    // ── Copy 8×8 block into plane at (block_x, block_y) ───────
    var by: u32 = 0;
    while (by < 8) : (by += 1) {
        var bx: u32 = 0;
        while (bx < 8) : (bx += 1) {
            const px: u32 = block_x + bx;
            const py: u32 = block_y + by;
            plane[py * plane_w + px] = block[by * 8 + bx];
        }
    }
}

/// Sample a component plane at canvas pixel (x, y) by mapping
/// canvas coords → component coords using the sampling factors.
/// Nearest-neighbor; no fancy chroma reconstruction filter.
inline fn sampleComponent(
    plane: []const u8,
    plane_w: u32,
    plane_h: u32,
    canvas_x: u32,
    canvas_y: u32,
    h_factor: u32,
    v_factor: u32,
    max_h: u32,
    max_v: u32,
) u8 {
    var cx: u32 = (canvas_x * h_factor) / max_h;
    var cy: u32 = (canvas_y * v_factor) / max_v;
    if (cx >= plane_w) cx = plane_w - 1;
    if (cy >= plane_h) cy = plane_h - 1;
    return plane[cy * plane_w + cx];
}

/// After all blocks are decoded into per-component planes, convert
/// to interleaved output (grayscale or RGB) at canvas resolution.
/// Subsampled chroma is upsampled nearest-neighbor (good enough for
/// v2; proper cosited / midpoint reconstruction is a future
/// refinement when image-quality consumers ask).
fn assembleOutput(
    allocator: Allocator,
    frame: *const FrameInfo,
    channels: u8,
    width: u32,
    height: u32,
    max_h: u32,
    max_v: u32,
    plane_w: [3]u32,
    plane_h: [3]u32,
    planes: *const [3][]u8,
) Error!types.Image {
    const out_len: usize = @as(usize, width) * @as(usize, height) * @as(usize, channels);
    const pixels = try allocator.alloc(u8, out_len);
    errdefer allocator.free(pixels);

    if (channels == 1) {
        var y: u32 = 0;
        while (y < height) : (y += 1) {
            var x: u32 = 0;
            while (x < width) : (x += 1) {
                pixels[y * width + x] = planes[0][y * plane_w[0] + x];
            }
        }
    } else {
        const c0 = &frame.components[0];
        const c1 = &frame.components[1];
        const c2 = &frame.components[2];
        var y: u32 = 0;
        while (y < height) : (y += 1) {
            var x: u32 = 0;
            while (x < width) : (x += 1) {
                const Ys = sampleComponent(planes[0], plane_w[0], plane_h[0], x, y,
                    @intCast(c0.h_factor), @intCast(c0.v_factor), max_h, max_v);
                const Cbs = sampleComponent(planes[1], plane_w[1], plane_h[1], x, y,
                    @intCast(c1.h_factor), @intCast(c1.v_factor), max_h, max_v);
                const Crs = sampleComponent(planes[2], plane_w[2], plane_h[2], x, y,
                    @intCast(c2.h_factor), @intCast(c2.v_factor), max_h, max_v);
                const Y: f32 = @floatFromInt(Ys);
                const Cb: f32 = @floatFromInt(Cbs);
                const Cr: f32 = @floatFromInt(Crs);
                const r = Y + 1.402 * (Cr - 128.0);
                const g = Y - 0.344136 * (Cb - 128.0) - 0.714136 * (Cr - 128.0);
                const b = Y + 1.772 * (Cb - 128.0);
                const out_off: usize = (y * width + x) * 3;
                pixels[out_off + 0] = clampU8(r);
                pixels[out_off + 1] = clampU8(g);
                pixels[out_off + 2] = clampU8(b);
            }
        }
    }

    // Free intermediate planes.
    var p: usize = 0;
    while (p < channels) : (p += 1) allocator.free(planes[p]);

    return types.Image{
        .pixels = pixels,
        .width = width,
        .height = height,
        .channels = channels,
        .bits_per_sample = 8,
        .source_color_space = if (channels == 1) .grayscale else .ycbcr,
        .layout = if (channels == 1) .grayscale else .rgb,
    };
}

fn clampU8(v: f32) u8 {
    const r = @round(v);
    if (r < 0) return 0;
    if (r > 255) return 255;
    return @intFromFloat(r);
}
