//! Coefficient dump of a progressive decode (diagnostics: the quantized coefficients after every scan, before dequantization).

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
const jpeg_markers = @import("jpeg_markers.zig");
const decodeOneScan = @import("progressive_scan.zig").decodeOneScan;
const ZIGZAG = @import("progressive.zig").ZIGZAG;
const FrameInfo = @import("progressive.zig").FrameInfo;
const Error = @import("progressive.zig").Error;
const parseSegmentLength = @import("progressive.zig").parseSegmentLength;
const parseSof = @import("progressive.zig").parseSof;
const parseDqt = @import("progressive.zig").parseDqt;
const parseDht = @import("progressive.zig").parseDht;
const parseSos = @import("progressive.zig").parseSos;

/// Diagnostic-only: progressive decode result with natural-order quantized
/// coefficients per component (post-entropy, pre-IDCT). For byte-level diff
/// against libjpeg-turbo's `jpeg_read_coefficients()` output (which is also
/// natural-order). Caller must `freeCoefDump(allocator, dump)` after use.
pub const CoefDump = struct {
    num_components: u8,
    blocks_w: [3]u32,
    blocks_h: [3]u32,
    coefs: [3][]i16, // natural-order, length blocks_w[i]*blocks_h[i]*64

    pub fn deinit(self: *CoefDump, allocator: Allocator) void {
        var i: usize = 0;
        while (i < self.num_components) : (i += 1) {
            if (self.coefs[i].len > 0) allocator.free(self.coefs[i]);
        }
        self.* = undefined;
    }
};

/// Decode the bitstream as far as `decode()` does, but instead of running
/// IDCT + color conversion, return the per-block dequantized coefficients
/// in NATURAL order (un-zig-zagged). The dequantization step IS applied
/// (matching libjpeg's `jpeg_read_coefficients` output, which is also
/// post-entropy but PRE-dequant — so the caller of this function should
/// know which one they want; here we dequant for parity with our own
/// `assembleProgressive` intermediate state).
///
/// Actually: libjpeg's `jpeg_read_coefficients` returns RAW (post-entropy,
/// PRE-dequant) coefficients in natural order. To match, we skip the
/// dequant step here and return the raw zig-zag-then-natural-permuted
/// coefficients.
pub fn decodeAndDumpCoefs(allocator: Allocator, data: []const u8) Error!CoefDump {
    // Same body as decode() up through the SOS scan-loop, but skip the
    // assembleProgressive step. Then un-zig-zag the per-block coefficients
    // into natural order to match libjpeg's `jpeg_read_coefficients`.
    if (data.len < 4) return error.TruncatedStream;
    if (data[0] != 0xFF or data[1] != 0xD8) return error.InvalidMarker;

    var pos: usize = 2;
    var frame: ?FrameInfo = null;
    var quant_tables: [4]?[64]u16 = .{ null, null, null, null };
    var dc_tables: [4]?huffman.HuffmanTable = .{ null, null, null, null };
    var ac_tables: [4]?huffman.HuffmanTable = .{ null, null, null, null };
    var coefs: [3][]i16 = .{ &.{}, &.{}, &.{} };
    var blocks_w: [3]u32 = .{ 0, 0, 0 };
    var blocks_h: [3]u32 = .{ 0, 0, 0 };
    var max_h: u32 = 1;
    var max_v: u32 = 1;
    var saw_eoi = false;
    var seen_sof = false;
    var restart_interval: u16 = 0;

    errdefer {
        var i: usize = 0;
        while (i < 3) : (i += 1) if (coefs[i].len > 0) allocator.free(coefs[i]);
    }

    while (pos + 1 < data.len and !saw_eoi) {
        if (data[pos] != 0xFF) return error.InvalidMarker;
        while (pos + 1 < data.len and data[pos + 1] == 0xFF) pos += 1;
        if (pos + 1 >= data.len) return error.TruncatedStream;
        const marker = data[pos + 1];
        pos += 2;
        switch (marker) {
            0xD9 => {
                saw_eoi = true;
                break;
            },
            0xC2 => {
                frame = try parseSof(data, pos);
                // T.81 §G.1 progressive: 8-bit and 12-bit are both spec
                // and both produced by libjpeg-turbo (12-bit via
                // -progressive -precision 12). A3 (2026-05-13) closes
                // the 12-bit row via assembleProgressiveGeneric(12).
                if (frame.?.precision != 8 and frame.?.precision != 12)
                    return error.UnsupportedPrecision;
                if (frame.?.num_components != 1 and frame.?.num_components != 3) return error.NotImplemented;
                seen_sof = true;
                var i: usize = 0;
                while (i < frame.?.num_components) : (i += 1) {
                    const c = &frame.?.components[i];
                    if (c.h_factor < 1 or c.h_factor > 4 or c.v_factor < 1 or c.v_factor > 4)
                        return error.NotImplemented;
                    if (@as(u32, c.h_factor) > max_h) max_h = @intCast(c.h_factor);
                    if (@as(u32, c.v_factor) > max_v) max_v = @intCast(c.v_factor);
                }
                const mcu_pixel_w: u32 = max_h * 8;
                const mcu_pixel_h: u32 = max_v * 8;
                const mcu_cols: u32 = (frame.?.width + mcu_pixel_w - 1) / mcu_pixel_w;
                const mcu_rows: u32 = (frame.?.height + mcu_pixel_h - 1) / mcu_pixel_h;
                i = 0;
                while (i < frame.?.num_components) : (i += 1) {
                    const c = &frame.?.components[i];
                    blocks_w[i] = mcu_cols * @as(u32, c.h_factor);
                    blocks_h[i] = mcu_rows * @as(u32, c.v_factor);
                    const total: usize = @as(usize, blocks_w[i]) * @as(usize, blocks_h[i]) * 64;
                    coefs[i] = try allocator.alloc(i16, total);
                    @memset(coefs[i], 0);
                }
                pos += parseSegmentLength(data, pos);
            },
            0xC0, 0xC1, 0xC3 => return error.NotImplemented,
            0xC9, 0xCA, 0xCB => return error.NotImplemented,
            0xC4 => {
                try parseDht(data, pos, &dc_tables, &ac_tables);
                pos += parseSegmentLength(data, pos);
            },
            0xDB => {
                try parseDqt(data, pos, &quant_tables);
                pos += parseSegmentLength(data, pos);
            },
            0xDD => { // DRI — restart interval
                const seg_len = parseSegmentLength(data, pos);
                if (seg_len != 4 or pos + seg_len > data.len) return error.TruncatedStream;
                restart_interval = (@as(u16, data[pos + 2]) << 8) | data[pos + 3];
                pos += seg_len;
            },
            0xDA => {
                if (!seen_sof) return error.InvalidMarker;
                const scan = try parseSos(data, pos, &frame.?);
                pos += parseSegmentLength(data, pos);
                pos = try decodeOneScan(data, pos, &frame.?, &dc_tables, &ac_tables, &coefs, &blocks_w, &blocks_h, max_h, max_v, &scan, restart_interval, .{});
            },
            0x01, 0xD0...0xD7 => continue,
            else => pos += parseSegmentLength(data, pos),
        }
    }
    if (!seen_sof) return error.InvalidMarker;

    // Un-zig-zag each block in place: coefs[ci][block_off..+64] is in
    // zig-zag order; rewrite as natural order so it matches libjpeg's
    // `jpeg_read_coefficients` output (which IS in natural order).
    var ci: u8 = 0;
    while (ci < frame.?.num_components) : (ci += 1) {
        const total_blocks: usize = @as(usize, blocks_w[ci]) * @as(usize, blocks_h[ci]);
        var bi: usize = 0;
        while (bi < total_blocks) : (bi += 1) {
            const off = bi * 64;
            var zz: [64]i16 = undefined;
            @memcpy(&zz, coefs[ci][off..][0..64]);
            var n: usize = 0;
            while (n < 64) : (n += 1) {
                coefs[ci][off + ZIGZAG[n]] = zz[n];
            }
        }
    }

    return CoefDump{
        .num_components = frame.?.num_components,
        .blocks_w = blocks_w,
        .blocks_h = blocks_h,
        .coefs = coefs,
    };
}
