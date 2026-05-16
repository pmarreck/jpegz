//! JPEG-LS (T.87) cleanroom decoder — entry point + marker walker.
//!
//! v1 scope per `docs/superpowers/specs/2026-05-16-jpegls-cleanroom-design.md`:
//! NEAR=0 lossless, 8 and 16-bit precision, 1- and 3-component,
//! sample-interleaved (mode 2) and none-interleaved (mode 0).
//!
//! This file (§1c) lays the marker walker and `decode()` skeleton.
//! The actual scan body — regular mode + run mode entropy decode —
//! lands in §2. Until then `decode()` returns `error.NotImplemented`
//! after parsing the headers, and the public dispatcher in
//! `src/jpegz.zig` falls through to the charls wrapper.

const std = @import("std");
const Allocator = std.mem.Allocator;
const errors = @import("../core/errors.zig");
const types = @import("../core/types.zig");
const codec = @import("jpegls_codec.zig");
const bitstream = @import("jpegls_bitstream");

const Error = errors.DecodeError;

// T.87 marker bytes (those that differ from T.81 are noted).
const M_SOI: u8 = 0xD8;
const M_SOF55: u8 = 0xF7; // T.87 §C.2.2 — the only SOF used by JPEG-LS
const M_LSE: u8 = 0xF2; // T.87 §C.2.4 — JPEG-LS-specific preset parameters
const M_SOS: u8 = 0xDA;
const M_EOI: u8 = 0xD9;
const M_DRI: u8 = 0xDD; // optional, T.81-compatible
const M_COM: u8 = 0xFE;
const M_DNL: u8 = 0xDC; // Define Number of Lines (rare)

/// Frame info parsed from SOF55.
pub const FrameInfo = struct {
    /// Precision in bits per sample (1..16, typically 8/12/16).
    P: u8,
    height: u16,
    width: u16,
    /// Number of components (1 or 3 in v1 scope).
    num_components: u8,
    components: [4]ComponentInfo,
};

pub const ComponentInfo = struct {
    id: u8,
    h_factor: u4,
    v_factor: u4,
    /// `Tqi` byte from SOF55 — reserved, must be 0.
    qt_index: u8,
};

/// Scan-specific parameters from SOS.
pub const ScanInfo = struct {
    num_components: u8,
    comp_indices: [4]usize,
    /// Near-lossless tolerance from SOS (T.87 §C.2.3 byte). 0 = lossless.
    NEAR: u8,
    /// Interleave mode (0 = none/planar, 1 = line, 2 = sample). v1
    /// supports 0 and 2 once §2 ships.
    ILV: u8,
};

/// Public decode entry. Returns `error.NotImplemented` for every
/// JPEG-LS bitstream right now — §2 fills in the body. The marker
/// walker still parses headers so any structural issue surfaces
/// before falling through to the wrapper.
pub fn decode(allocator: Allocator, data: []const u8) Error!types.Image {
    if (data.len < 4) return error.TruncatedStream;
    if (data[0] != 0xFF or data[1] != M_SOI) return error.InvalidMarker;

    var pos: usize = 2;
    var frame: ?FrameInfo = null;
    // LSE preset-parameter overrides — applied during scan init in §2.
    var preset: PresetParams = .{};

    while (pos + 1 < data.len) {
        while (pos < data.len and data[pos] != 0xFF) pos += 1;
        if (pos + 1 >= data.len) return error.TruncatedStream;
        while (pos + 1 < data.len and data[pos + 1] == 0xFF) pos += 1;
        if (pos + 1 >= data.len) return error.TruncatedStream;
        const marker = data[pos + 1];
        pos += 2;
        switch (marker) {
            M_EOI => return error.TruncatedStream, // EOI before SOS — malformed
            // T.81 SOFn markers — this isn't a JPEG-LS bitstream.
            // Bail out so the dispatcher tries the next path.
            0xC0...0xC3, 0xC5...0xCB, 0xCD...0xCF => return error.NotImplemented,
            M_SOF55 => {
                frame = try parseSof55(data, pos);
                if (frame.?.P < 2 or frame.?.P > 16) return error.UnsupportedPrecision;
                if (frame.?.num_components != 1 and frame.?.num_components != 3)
                    return error.NotImplemented;
                pos += parseSegmentLength(data, pos);
            },
            M_LSE => {
                try parseLse(data, pos, &preset);
                pos += parseSegmentLength(data, pos);
            },
            M_DRI => {
                // Optional. JPEG-LS uses restart markers analogously to
                // T.81; v1 doesn't see any in our fixtures so we skip.
                pos += parseSegmentLength(data, pos);
            },
            M_DNL => {
                // Define Number of Lines (T.87 §B.2.5). Rarely used.
                pos += parseSegmentLength(data, pos);
            },
            M_SOS => {
                if (frame == null) return error.InvalidMarker;
                const scan = try parseSos(data, pos, &frame.?);
                pos += parseSegmentLength(data, pos);
                if (scan.NEAR != 0) return error.NotImplemented; // NEAR > 0 deferred
                if (scan.ILV != 0 and scan.ILV != 2) return error.NotImplemented;
                if (frame.?.P > 8) return error.NotImplemented; // §4 covers 16-bit
                if (frame.?.num_components != 1) return error.NotImplemented; // §3 covers RGB
                return try decodeScan8Mono(allocator, data[pos..], &frame.?, &scan, &preset);
            },
            // Standalone markers we can skip safely (RST, TEM, SOI/EOI
            // shouldn't appear here; treat as no-op).
            0x01, 0xD0...0xD7, M_SOI => continue,
            // Length-prefixed (APPn, COM, etc.) — skip payload.
            else => pos += parseSegmentLength(data, pos),
        }
    }
    return error.TruncatedStream;
}

/// Preset coding parameters from LSE subtype 4. Defaults are the
/// T.87 §C.2.4.1.1 baselines, applied lazily by `ScanState.reset`
/// when none are explicitly set.
pub const PresetParams = struct {
    /// 0 means "use the spec default for the bpp" — handled inside
    /// ScanState. Otherwise the encoder-supplied override.
    MAXVAL: u32 = 0,
    T1: u32 = 0,
    T2: u32 = 0,
    T3: u32 = 0,
    RESET: u32 = 0,
};

fn parseSegmentLength(data: []const u8, pos: usize) usize {
    if (pos + 1 >= data.len) return 0;
    return (@as(usize, data[pos]) << 8) | data[pos + 1];
}

/// SOF55 layout (T.87 §C.2.2):
///   FF F7 [Lf:2] [P:1] [Y:2] [X:2] [Nf:1] { [Ci:1] [Hi:1:Vi:1] [Tqi:1] }*Nf
fn parseSof55(data: []const u8, pos: usize) Error!FrameInfo {
    const seg_len = parseSegmentLength(data, pos);
    if (seg_len < 8 or pos + seg_len > data.len) return error.TruncatedStream;
    var fi: FrameInfo = undefined;
    fi.P = data[pos + 2];
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

/// LSE layout (T.87 §C.2.4). First byte after the length is the
/// subtype `ID`. We only act on subtype 1 (preset coding parameters);
/// subtypes 2-4 are mapping tables only used by transcoder apps —
/// safe to ignore for decode.
fn parseLse(data: []const u8, pos: usize, out: *PresetParams) Error!void {
    const seg_len = parseSegmentLength(data, pos);
    if (seg_len < 3 or pos + seg_len > data.len) return error.TruncatedStream;
    const id = data[pos + 2];
    if (id != 1) return; // mapping tables — silently skip
    if (seg_len < 13) return error.InvalidMarker;
    out.MAXVAL = (@as(u32, data[pos + 3]) << 8) | data[pos + 4];
    out.T1 = (@as(u32, data[pos + 5]) << 8) | data[pos + 6];
    out.T2 = (@as(u32, data[pos + 7]) << 8) | data[pos + 8];
    out.T3 = (@as(u32, data[pos + 9]) << 8) | data[pos + 10];
    out.RESET = (@as(u32, data[pos + 11]) << 8) | data[pos + 12];
}

/// SOS layout (T.87 §C.2.3):
///   FF DA [Ls:2] [Ns:1] { [Csi:1] [Tdi:1] }*Ns [NEAR:1] [ILV:1] [Al:Ah:1]
fn parseSos(data: []const u8, pos: usize, frame: *FrameInfo) Error!ScanInfo {
    const seg_len = parseSegmentLength(data, pos);
    if (seg_len < 6 or pos + seg_len > data.len) return error.TruncatedStream;
    var info: ScanInfo = undefined;
    info.num_components = data[pos + 2];
    if (info.num_components == 0 or info.num_components > 4) return error.InvalidMarker;
    var i: usize = 0;
    while (i < info.num_components) : (i += 1) {
        const off = pos + 3 + i * 2;
        const cs = data[off];
        // T.87 doesn't use Tdj/Taj fields — the second byte is reserved.
        // Just locate the matching frame component by ID.
        var found: bool = false;
        var j: usize = 0;
        while (j < frame.num_components) : (j += 1) {
            if (frame.components[j].id == cs) {
                info.comp_indices[i] = j;
                found = true;
                break;
            }
        }
        if (!found) return error.InvalidMarker;
    }
    const tail = pos + 3 + info.num_components * 2;
    info.NEAR = data[tail];
    info.ILV = data[tail + 1];
    // Al:Ah byte exists but is unused for JPEG-LS (T.81-compat field).
    return info;
}

// ── Inline tests ─────────────────────────────────────────────────

test "parseSof55: minimal grayscale 8-bit header" {
    // Construct a minimal SOF55 in-place: 0xFF 0xF7 0x00 0x0B (Lf=11)
    // P=8 Y=0x0004 X=0x0004 Nf=1 Ci=1 Hi:Vi=0x11 Tqi=0
    const data = [_]u8{
        0xFF, 0xF7, 0x00, 0x0B, // marker + length
        8, 0x00, 0x04, 0x00, 0x04, 1, // P, Y, X, Nf
        1, 0x11, 0, // C1, H:V, Tq
    };
    // parseSof55 expects pos pointing to the length byte (just after FFF7).
    const fi = try parseSof55(&data, 2);
    try std.testing.expectEqual(@as(u8, 8), fi.P);
    try std.testing.expectEqual(@as(u16, 4), fi.width);
    try std.testing.expectEqual(@as(u16, 4), fi.height);
    try std.testing.expectEqual(@as(u8, 1), fi.num_components);
    try std.testing.expectEqual(@as(u8, 1), fi.components[0].id);
    try std.testing.expectEqual(@as(u4, 1), fi.components[0].h_factor);
    try std.testing.expectEqual(@as(u4, 1), fi.components[0].v_factor);
}

test "parseLse: subtype 1 preset coding parameters" {
    // LSE: 0xFF 0xF2 [length=13] id=1 [MAXVAL] [T1] [T2] [T3] [RESET]
    const data = [_]u8{
        0xFF, 0xF2, 0x00, 0x0D, // marker + length=13
        1, // id = 1 (preset)
        0x00, 0xFF, // MAXVAL = 255
        0x00, 0x03, // T1 = 3
        0x00, 0x07, // T2 = 7
        0x00, 0x15, // T3 = 21
        0x00, 0x40, // RESET = 64
    };
    var preset: PresetParams = .{};
    try parseLse(&data, 2, &preset);
    try std.testing.expectEqual(@as(u32, 255), preset.MAXVAL);
    try std.testing.expectEqual(@as(u32, 3), preset.T1);
    try std.testing.expectEqual(@as(u32, 7), preset.T2);
    try std.testing.expectEqual(@as(u32, 21), preset.T3);
    try std.testing.expectEqual(@as(u32, 64), preset.RESET);
}

test "parseLse: subtype 4 (mapping table) silently skipped" {
    const data = [_]u8{
        0xFF, 0xF2, 0x00, 0x05, // marker + length=5
        4, // id = 4 (mapping table — ignore)
        0x42, 0x42, // arbitrary payload
    };
    var preset: PresetParams = .{};
    try parseLse(&data, 2, &preset);
    // No overrides applied.
    try std.testing.expectEqual(@as(u32, 0), preset.MAXVAL);
}

// (§1c stub test was here — superseded by the B2 fixture test in
// tests/unit/decode.zig now that §2 actually decodes the scan body.)

// ─────────────────────────────────────────────────────────────────
// Scan body — 8-bit, 1-component (Session 2 scope).
// ─────────────────────────────────────────────────────────────────

/// Decode a 1-component 8-bit JPEG-LS scan. Entropy-decodes every
/// sample via regular or run mode and emits a raster-order pixel
/// buffer. T.87 §A; mirrors charls' `jls_codec::do_line` /
/// `do_run_mode` for the single-component path.
fn decodeScan8Mono(
    allocator: Allocator,
    data: []const u8,
    frame: *const FrameInfo,
    scan: *const ScanInfo,
    preset: *const PresetParams,
) Error!types.Image {
    _ = scan;
    const W: u32 = frame.width;
    const H: u32 = frame.height;

    var state: codec.ScanState = undefined;
    state.reset(8, 0); // 8-bit, NEAR=0 (lossless)
    // Apply LSE preset overrides if present.
    if (preset.MAXVAL != 0) state.MAXVAL = preset.MAXVAL;
    if (preset.T1 != 0) state.T1 = preset.T1;
    if (preset.T2 != 0) state.T2 = preset.T2;
    if (preset.T3 != 0) state.T3 = preset.T3;
    if (preset.RESET != 0) state.RESET = preset.RESET;

    var br = bitstream.BitReader.init(data);
    const pixels = try allocator.alloc(u8, @as(usize, W) * @as(usize, H));
    errdefer allocator.free(pixels);

    // Two scan-lines buffered so we can access Rb/Rc/Rd from the
    // previous line. T.87 §A.1.2 boundary rule: samples outside the
    // image are 0; at start-of-line, Ra ← Rb.
    const cur_line = try allocator.alloc(i32, @as(usize, W) + 2);
    defer allocator.free(cur_line);
    const prev_line = try allocator.alloc(i32, @as(usize, W) + 2);
    defer allocator.free(prev_line);
    @memset(prev_line, 0);

    var y: u32 = 0;
    while (y < H) : (y += 1) {
        @memset(cur_line, 0);
        // T.87 §A.1.2: at start of line, Ra is set to the prior
        // line's value at column 0. We store at index 1 (index 0
        // is the left-of-image sentinel, kept 0).
        cur_line[0] = prev_line[1];

        var x: u32 = 0;
        while (x < W) {
            // Neighbors in our 1-indexed line buffer:
            //   Ra = cur_line[x]      (just-decoded; at x=0 = Rb)
            //   Rb = prev_line[x+1]
            //   Rc = prev_line[x]
            //   Rd = prev_line[x+2]   (replicates Rb at right edge)
            const ra: i32 = cur_line[x];
            const rb: i32 = prev_line[x + 1];
            const rc: i32 = prev_line[x];
            const rd_raw: i32 = if (x + 1 < W) prev_line[x + 2] else rb;
            const rd: i32 = rd_raw;

            const t1: i32 = @intCast(state.T1);
            const t2: i32 = @intCast(state.T2);
            const t3: i32 = @intCast(state.T3);
            const near_i: i32 = @intCast(state.NEAR);
            const q1 = codec.quantize(rd - rb, t1, t2, t3, near_i);
            const q2 = codec.quantize(rb - rc, t1, t2, t3, near_i);
            const q3 = codec.quantize(rc - ra, t1, t2, t3, near_i);

            const ctx = codec.computeContextIndex(q1, q2, q3);
            if (ctx.q == 0) {
                // Run mode.
                const consumed = try decodeRun(&state, &br, ra, cur_line, prev_line, x, W);
                x += consumed;
            } else {
                // Regular mode.
                const c_correction: i32 = @as(i32, state.contexts[0][ctx.q].C);
                var px = codec.predictMed(ra, rb, rc);
                px += codec.applySign(c_correction, ctx.sign);
                if (px < 0) px = 0 else if (px > @as(i32, @intCast(state.MAXVAL))) px = @intCast(state.MAXVAL);

                const k = codec.computeK(
                    state.contexts[0][ctx.q].N,
                    state.contexts[0][ctx.q].A,
                );
                const merrval = codec.decodeGolombRice(&br, k, state.LIMIT, state.qbpp);
                var errval = codec.mapMErrvalToErrval(merrval);
                if (k == 0) {
                    // T.87 §A.6.2 — k=0 sign-correction trick.
                    const b = state.contexts[0][ctx.q].B;
                    const n_i: i32 = @intCast(state.contexts[0][ctx.q].N);
                    if (2 * b + n_i - 1 < 0) errval = ~errval;
                }
                codec.updateState(&state, 0, ctx.q, errval);
                const signed_err = codec.applySign(errval, ctx.sign);
                const sample = codec.computeReconstructed(px, signed_err, state.MAXVAL);
                cur_line[x + 1] = sample;
                pixels[@as(usize, y) * @as(usize, W) + @as(usize, x)] = @intCast(sample);
                x += 1;
            }
        }
        // Mirror cur_line → pixels (run mode wrote to cur_line; finalize).
        var xc: u32 = 0;
        while (xc < W) : (xc += 1) {
            pixels[@as(usize, y) * @as(usize, W) + @as(usize, xc)] = @intCast(cur_line[xc + 1]);
        }
        // Swap buffers (would copy or swap; for simplicity, copy).
        @memcpy(prev_line, cur_line);
    }

    return types.Image{
        .pixels = pixels,
        .width = W,
        .height = H,
        .channels = 1,
        .bits_per_sample = 8,
        .source_color_space = .grayscale,
        .layout = .grayscale,
    };
}

/// Run mode for a single sample-component pixel. T.87 §A.7; mirrors
/// charls' `decode_run_pixels` + `decode_run_interruption_pixel`.
/// Returns the number of pixels consumed (run length + 1 if a run-
/// interruption sample followed; or just run length at EOL).
fn decodeRun(
    state: *codec.ScanState,
    br: *bitstream.BitReader,
    ra: i32,
    cur_line: []i32,
    prev_line: []const i32,
    start_x: u32,
    W: u32,
) Error!u32 {
    const pixel_count: u32 = W - start_x;
    var index: u32 = 0;
    // Run-length: emit 1 << J[run_index] pixels per 1-bit, cap at
    // pixel_count; bump run_index up to 31 each time we emit a full
    // step. Stop on a 0 bit OR when we reach end-of-line.
    while (br.readBits(1) == 1) {
        const step: u32 = @as(u32, 1) << @intCast(codec.J_TABLE[state.run_index[0]]);
        const count: u32 = @min(step, pixel_count - index);
        index += count;
        if (count == step and state.run_index[0] < 31) state.run_index[0] += 1;
        if (index == pixel_count) break;
    }
    if (index != pixel_count) {
        // Incomplete run — read residual bits.
        const j = codec.J_TABLE[state.run_index[0]];
        if (j > 0) {
            const residual: u32 = br.readBits(@intCast(j));
            index += residual;
        }
    }
    if (index > pixel_count) return error.BackendError;

    // Fill run with Ra.
    var i: u32 = 0;
    while (i < index) : (i += 1) {
        cur_line[start_x + 1 + i] = ra;
    }

    if (start_x + index == W) return index; // EOL — no interruption

    // Run interruption sample at (start_x + index). T.87 §A.7.4 /
    // charls `decode_run_interruption_pixel`:
    //   - |Ra - Rb| <= NEAR → RItype 1 (flat region), predict from Ra.
    //   - otherwise         → RItype 0 (edge), predict from Rb with
    //                          sign(Rb - Ra) applied to the error.
    const rb_v: i32 = prev_line[start_x + index + 1];
    const ri_type: u8 = if (@abs(ra - rb_v) <= @as(i32, @intCast(state.NEAR))) 1 else 0;
    const rc = &state.run_contexts[0][ri_type];
    const k = codec.runModeGetK(rc, ri_type);
    const e_mapped = codec.decodeGolombRice(
        br, k,
        @as(u8, @intCast(@as(i32, state.LIMIT) - codec.J_TABLE[state.run_index[0]] - 1)),
        state.qbpp,
    );
    const errval = codec.runModeComputeError(rc, e_mapped, k, ri_type);
    codec.runModeUpdate(rc, errval, e_mapped, ri_type, state.RESET);

    const sample: i32 = if (ri_type == 0) blk: {
        // Edge case: predict from Rb, sign-flip error by sign(Rb - Ra).
        const s: i32 = if (rb_v > ra) 1 else if (rb_v < ra) -1 else 0;
        break :blk codec.computeReconstructed(rb_v, errval * s, state.MAXVAL);
    } else codec.computeReconstructed(ra, errval, state.MAXVAL);
    cur_line[start_x + index + 1] = sample;

    if (state.run_index[0] > 0) state.run_index[0] -= 1;
    return index + 1;
}

// Force-import the codec module so its inline tests run if this is the
// test root (not necessary for the jpegls module's own tests; harmless).
comptime {
    _ = codec;
}
