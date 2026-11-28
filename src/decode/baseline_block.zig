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
const ZIGZAG = @import("baseline.zig").ZIGZAG;
const ComponentInfo = @import("baseline.zig").ComponentInfo;
const Error = @import("baseline.zig").Error;
const transformBlockToPlane = @import("baseline_output.zig").transformBlockToPlane;

/// Per-row worker: IDCT every block in row `by_idx` and write into the
/// plane. Pure compute over disjoint memory ranges (own slice of
/// `coef_buf` for input, own 8-pixel-tall stripe of `plane` for output)
/// so concurrent invocations on different rows don't race.
pub fn transformBlockRow(
    coef_buf: []const i32,
    plane: []u8,
    plane_w: u32,
    blocks_w_for_comp: u32,
    by_idx: u32,
) void {
    var bx_idx: u32 = 0;
    while (bx_idx < blocks_w_for_comp) : (bx_idx += 1) {
        const linear: usize = (@as(usize, by_idx) * @as(usize, blocks_w_for_comp) + @as(usize, bx_idx)) * 64;
        const slot: *const [64]i32 = coef_buf[linear..][0..64];
        transformBlockToPlane(slot, plane, plane_w, bx_idx * 8, by_idx * 8);
    }
}

/// Phase 1: decode a single 8×8 block from the entropy stream into the
/// natural-order coefficient buffer at `out`. Performs Huffman decode
/// (DC + 63 AC), dequantization in zig-zag space, and un-zig-zag into
/// natural order — but does NOT IDCT or write spatial samples. Splitting
/// this from the IDCT pass lets the second pass run in parallel later.
/// Updates `prev_dc[ci]` (DC differential per component, T.81 §F.2.2.1).
/// Per-scan recovery state for `lenient = true` mode. The scan
/// allocates one on the stack and threads `*LenientState` into every
/// block decode. The flag flips on the FIRST truncation in any block
/// of the scan; from that point on, every remaining block decode
/// short-circuits to zero coefficients (no extra findings, no
/// re-reading of an exhausted bitstream).
pub const LenientState = struct {
    lenient: bool,
    sink: ?*findings_mod.FindingsSink,
    /// File offset of the scan's `br.data[0]`.
    base: usize = 0,
    truncation_seen: bool = false,

    /// An exact FAIL at `byte_pos` within the scan data (validate rulings
    /// 2026-11-22: 74 for a code with no valid decode, 58 for a category past
    /// the precision bound, both at the code's first byte).
    fn fault(self: *const LenientState, code: errors.FindingCode, byte_pos: usize, comptime fmt: []const u8, args: anytype) Error!void {
        const s = self.sink orelse return;
        var buf: [128]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..0];
        s.emitExact(.fail, code, @intCast(self.base + byte_pos), detail) catch return error.OutOfMemory;
    }

    inline fn emitOnce(self: *LenientState, byte_pos: usize) Error!void {
        if (self.truncation_seen) return;
        self.truncation_seen = true;
        if (self.sink) |s| {
            s.emit(.warn, .insufficient_data, @intCast(self.base + byte_pos),
                "Corrupt JPEG data: premature end of data segment") catch
                return error.OutOfMemory;
        }
    }
};

pub fn decodeBlockCoefficients(
    br: *bitstream.BitReader,
    ci: usize,
    comp: *const ComponentInfo,
    dc_tables: *const [4]?huffman.HuffmanTable,
    ac_tables: *const [4]?huffman.HuffmanTable,
    quant_tables: *const [4]?[64]u16,
    prev_dc: *[4]i32,
    out: *[64]i32,
    precision: u8,
    lenient: *LenientState,
) Error!void {
    // Lenient short-circuit: once truncation has been detected anywhere
    // in this scan, every remaining block decodes as zero. This produces
    // the same partial-recovery shape libjpeg-turbo emits: pixels up to
    // the truncation point are real, everything past is solid gray
    // (post-IDCT of an all-zero coefficient block + level shift).
    if (lenient.truncation_seen) {
        @memset(out, 0);
        return;
    }

    const dc_t = dc_tables[comp.dc_table] orelse return fail("block_dc_table_null", error.InvalidMarker);
    const ac_t = ac_tables[comp.ac_table] orelse return fail("block_ac_table_null", error.InvalidMarker);
    const qt = quant_tables[comp.qt_index] orelse return fail("block_qt_null", error.InvalidMarker);

    // T.81 §F.1.4.1 (DC), §F.1.4.2 (AC), Table F.1: at P=8 DC SSSS ≤ 11
    // and AC SSSS ≤ 10; at P=12 (extended sequential) DC SSSS ≤ 15 and
    // AC SSSS ≤ 14. Same arithmetic shape across the precisions —
    // DC max = P + 3, AC max = P + 2.
    const max_dc_size: u8 = precision + 3; // 11 for P=8, 15 for P=12
    const max_ac_size: u8 = precision + 2; // 10 for P=8, 14 for P=12

    // Coefficients accumulate in zig-zag order during entropy decode;
    // dequantized in zig-zag (matches DQT layout per T.81 §B.2.4.1);
    // un-zig-zagged for IDCT input (which expects natural row-major).
    // i32 for headroom: DC*qt can exceed i16 range on adversarial input.
    var zz: [64]i32 = .{0} ** 64;

    // ── DC coefficient (T.81 §F.2.2.1) ─────────────────────────
    const dc_mark = br.mark();
    const dc_size: u8 = dc_t.decode(br) catch {
        if (lenient.lenient and br.marker_seen) {
            try lenient.emitOnce(br.byte_pos);
            @memset(out, 0);
            return;
        }
        if (!br.marker_seen) try lenient.fault(.entropy_decode_invalid, br.markOffset(dc_mark),
            "DC Huffman code matches no table entry", .{});
        return fail("dc_huffman_decode_failed", error.BackendError);
    };
    if (dc_size > max_dc_size) {
        try lenient.fault(.dct_coefficient_overflow, br.markOffset(dc_mark),
            "DC difference category {d} exceeds {d} for {d}-bit samples (T.81 F.1.2.1)", .{ dc_size, max_dc_size, precision });
        return fail("dc_size_too_large", error.BackendError);
    }
    var dc_diff: i32 = 0;
    if (dc_size > 0) {
        const bits = br.readBits(@intCast(dc_size)) catch {
            if (lenient.lenient) {
                try lenient.emitOnce(br.byte_pos);
                @memset(out, 0);
                return;
            }
            return error.TruncatedStream;
        };
        dc_diff = huffman.extendSign(bits, @intCast(dc_size));
    }
    prev_dc[ci] += dc_diff;
    zz[0] = prev_dc[ci];

    // ── 63 AC coefficients (T.81 §F.2.2.2) ─────────────────────
    var k: usize = 1;
    while (k < 64) {
        const ac_mark = br.mark();
        const rs: u8 = ac_t.decode(br) catch {
            if (lenient.lenient and br.marker_seen) {
                try lenient.emitOnce(br.byte_pos);
                @memset(out, 0);
                return;
            }
            if (!br.marker_seen) try lenient.fault(.entropy_decode_invalid, br.markOffset(ac_mark),
                "AC Huffman code matches no table entry", .{});
            return fail("ac_huffman_decode_failed", error.BackendError);
        };
        if (rs == 0x00) break; // EOB — rest of block is zero
        if (rs == 0xF0) {
            k += 16; // ZRL — 16 zeros (already zeroed; just advance)
            if (k > 64) {
                try lenient.fault(.entropy_decode_invalid, br.markOffset(ac_mark), "AC zero run past Se=63", .{});
                return fail("ac_k_overflow", error.BackendError);
            }
            continue;
        }
        const run: u8 = rs >> 4;
        const size: u8 = rs & 0x0F;
        // Size 0 with a run other than 0 or 15 is a symbol T.81 leaves
        // undefined: table content, which stays 51.
        if (size == 0) return fail("ac_bad_size", error.BackendError);
        if (size > max_ac_size) {
            try lenient.fault(.dct_coefficient_overflow, br.markOffset(ac_mark),
                "AC coefficient category {d} exceeds {d} for {d}-bit samples (T.81 F.1.2.2)", .{ size, max_ac_size, precision });
            return fail("ac_bad_size", error.BackendError);
        }
        k += run;
        if (k >= 64) {
            try lenient.fault(.entropy_decode_invalid, br.markOffset(ac_mark), "AC zero run past Se=63", .{});
            return fail("ac_k_overflow", error.BackendError);
        }
        const bits = br.readBits(@intCast(size)) catch {
            if (lenient.lenient) {
                try lenient.emitOnce(br.byte_pos);
                @memset(out, 0);
                return;
            }
            return error.TruncatedStream;
        };
        const val = huffman.extendSign(bits, @intCast(size));
        zz[k] = val;
        k += 1;
    }

    // ── Dequantize in zig-zag space, then un-zig-zag into natural order ──
    var n: usize = 0;
    while (n < 64) : (n += 1) {
        out[ZIGZAG[n]] = zz[n] * @as(i32, qt[n]);
    }
}
