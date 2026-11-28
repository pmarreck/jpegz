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
const reportEntropyBoundary = @import("baseline.zig").reportEntropyBoundary;
const handleRstResync = @import("baseline.zig").handleRstResync;
const FrameInfo = @import("baseline.zig").FrameInfo;
const Error = @import("baseline.zig").Error;
const DecodeOptions = @import("baseline.zig").DecodeOptions;
const ScanSelection = @import("baseline_markers.zig").ScanSelection;
const LenientState = @import("baseline_block.zig").LenientState;
const decodeBlockCoefficients = @import("baseline_block.zig").decodeBlockCoefficients;

/// Decoder tables that segments between scans may redefine (T.81 §B.2.4).
pub const ScanTables = struct {
    quant: *[4]?[64]u16,
    dc: *[4]?huffman.HuffmanTable,
    ac: *[4]?huffman.HuffmanTable,
    restart_interval: *u32,
};

/// Frame-wide MCU geometry and the coefficient grid every scan writes into.
pub const CoefGrid = struct {
    channels: u8,
    max_h: u32,
    max_v: u32,
    mcu_cols: u32,
    mcu_rows: u32,
    blocks_w: [4]u32,
    coef_buf: [4][]i32,
};

const ScanEnd = struct {
    /// Bytes from the scan's entropy start to the 0xFF of the marker after it.
    consumed: usize,
    truncated: bool,
};

/// Phase 1 for one sequential scan: Huffman-decode and dequantize each data
/// unit it codes into the frame-wide grid. T.81 §A.2.3: an interleaved scan
/// (Ns > 1) walks frame MCUs of Hi×Vi blocks per selected component. §A.2.2:
/// a non-interleaved scan walks only its component's ceil(X·Hi/(8·Hmax)) ×
/// ceil(Y·Vi/(8·Vmax)) blocks, one block per MCU, so restart intervals count
/// blocks. A single-component frame is always the non-interleaved case.
pub fn decodeScanEntropy(
    data: []const u8,
    base: usize,
    frame: *const FrameInfo,
    scan: ScanSelection,
    grid: CoefGrid,
    tables: ScanTables,
    options: DecodeOptions,
) Error!ScanEnd {
    var br = bitstream.BitReader.init(data[base..]);
    var prev_dc: [4]i32 = .{ 0, 0, 0, 0 };
    var mcus_since_rst: u32 = 0;
    var expected_rst: u8 = 0xD0;
    var lenient_state: LenientState = .{
        .lenient = options.lenient,
        .sink = options.findings_sink,
        .base = base,
    };
    const restart_interval = tables.restart_interval.*;

    if (scan.count > 1) {
        var mcu_y: u32 = 0;
        while (mcu_y < grid.mcu_rows) : (mcu_y += 1) {
            var mcu_x: u32 = 0;
            while (mcu_x < grid.mcu_cols) : (mcu_x += 1) {
                if (restart_interval > 0 and mcus_since_rst == restart_interval) {
                    try handleRstResync(&br, base, &expected_rst, &prev_dc, &mcus_since_rst, options, &lenient_state.truncation_seen);
                }
                for (scan.comp[0..scan.count]) |ci| {
                    const comp = &frame.components[ci];
                    const blocks_v_per_mcu: u32 = @intCast(comp.v_factor);
                    const blocks_h_per_mcu: u32 = @intCast(comp.h_factor);
                    var block_v: u32 = 0;
                    while (block_v < blocks_v_per_mcu) : (block_v += 1) {
                        var block_h: u32 = 0;
                        while (block_h < blocks_h_per_mcu) : (block_h += 1) {
                            const block_idx_x: u32 = mcu_x * blocks_h_per_mcu + block_h;
                            const block_idx_y: u32 = mcu_y * blocks_v_per_mcu + block_v;
                            const linear: usize = (@as(usize, block_idx_y) * @as(usize, grid.blocks_w[ci]) + @as(usize, block_idx_x)) * 64;
                            try decodeBlockCoefficients(&br, ci, comp, tables.dc, tables.ac, tables.quant,
                                &prev_dc, grid.coef_buf[ci][linear..][0..64], frame.precision, &lenient_state);
                        }
                    }
                }
                mcus_since_rst += 1;
            }
        }
    } else {
        const ci = scan.comp[0];
        const comp = &frame.components[ci];
        // A single-component frame ignores its declared factors (max_h = max_v = 1).
        const hc: u32 = if (grid.channels == 1) 1 else @intCast(comp.h_factor);
        const vc: u32 = if (grid.channels == 1) 1 else @intCast(comp.v_factor);
        const xi: u32 = (frame.width * hc + 8 * grid.max_h - 1) / (8 * grid.max_h);
        const yi: u32 = (frame.height * vc + 8 * grid.max_v - 1) / (8 * grid.max_v);
        var by: u32 = 0;
        while (by < yi) : (by += 1) {
            var bx: u32 = 0;
            while (bx < xi) : (bx += 1) {
                if (restart_interval > 0 and mcus_since_rst == restart_interval) {
                    try handleRstResync(&br, base, &expected_rst, &prev_dc, &mcus_since_rst, options, &lenient_state.truncation_seen);
                }
                const linear: usize = (@as(usize, by) * @as(usize, grid.blocks_w[ci]) + @as(usize, bx)) * 64;
                try decodeBlockCoefficients(&br, ci, comp, tables.dc, tables.ac, tables.quant,
                    &prev_dc, grid.coef_buf[ci][linear..][0..64], frame.precision, &lenient_state);
                mcus_since_rst += 1;
            }
        }
    }

    // Account for every entropy bit before handing the marker back. Recovered
    // truncation already has an insufficient_data finding in the legacy API.
    if (!lenient_state.truncation_seen) {
        const marker = br.finishHuffmanSegment() catch |err| recovered: {
            // Whole bytes after valid padding are FAIL 8 (reportEntropyBoundary).
            try reportEntropyBoundary(&br, err, base, options, "invalid Huffman entropy or padding at end of scan");
            // Pad bits carry no image data: lenient decoding keeps going when a
            // marker follows them, as it does at restart boundaries. Every
            // decode accepts the known all-zero pattern.
            if (err == error.PaddingZeroBits or (options.lenient and err == error.PaddingNotOnes)) {
                br.seekToMarker();
                if (br.marker_seen) break :recovered br.marker_byte;
            }
            return fail("scan_entropy_boundary", error.BackendError);
        };
        // T.81 §B.2.1: a restart marker follows every entropy-coded segment except the last.
        if (marker >= 0xD0 and marker <= 0xD7) {
            try emitFinding(options, .fail, .restart_marker_unexpected, base + br.byte_pos,
                "restart marker after the final MCU of the scan");
            return fail("rst_after_final_mcu", error.BackendError);
        }
    }
    return .{ .consumed = br.byte_pos, .truncated = lenient_state.truncation_seen };
}
