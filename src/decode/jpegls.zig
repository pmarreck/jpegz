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
const builtin = @import("builtin");
const errors = @import("../core/errors.zig");
const types = @import("../core/types.zig");
const codec = @import("jpegls_codec.zig");
const bitstream = @import("jpegls_bitstream");
const findings_mod = @import("findings.zig");

const Error = errors.DecodeError;
const native_endian = builtin.cpu.arch.endian();

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

/// Caller-supplied knobs. Mirrors `baseline.DecodeOptions` shape so the
/// dispatcher can pass through a `FindingsSink` uniformly. The only
/// emit site in v1 JPEG-LS is the marker walker's extraneous-bytes
/// tolerance; entropy decode itself never early-returns on
/// `marker_seen` (the codec consumes a fixed pixel count and gets
/// zero-padded bits past the end, T.87 §A.5.3).
pub const DecodeOptions = struct {
    findings_sink: ?*findings_mod.FindingsSink = null,
};

/// Default-options entry — null sink, silent tolerance.
pub fn decode(allocator: Allocator, data: []const u8) Error!types.Image {
    return decodeWithOptions(allocator, data, .{});
}

/// Same as `decode` but accepts a `DecodeOptions`. Currently the only
/// honored knob is `findings_sink`: when non-null, the cleanroom emits
/// a `Finding(.warn, .extraneous_bytes_before_marker)` for each gap of
/// non-0xFF bytes the marker walker silently skips.
pub fn decodeWithOptions(
    allocator: Allocator,
    data: []const u8,
    options: DecodeOptions,
) Error!types.Image {
    if (data.len < 4) return error.TruncatedStream;
    if (data[0] != 0xFF or data[1] != M_SOI) return error.InvalidMarker;

    var pos: usize = 2;
    var frame: ?FrameInfo = null;
    // LSE preset-parameter overrides — applied during scan init in §2.
    var preset: PresetParams = .{};

    while (pos + 1 < data.len) {
        const skip_start = pos;
        while (pos < data.len and data[pos] != 0xFF) pos += 1;
        if (pos > skip_start) {
            if (options.findings_sink) |sink| {
                var buf: [96]u8 = undefined;
                const next_marker: u8 = if (pos + 1 < data.len) data[pos + 1] else 0;
                const detail = std.fmt.bufPrint(&buf,
                    "Corrupt JPEG data: {d} extraneous bytes before marker 0x{x:0>2}",
                    .{ pos - skip_start, next_marker }) catch buf[0..0];
                sink.emit(.warn, .extraneous_bytes_before_marker,
                    @intCast(skip_start), detail) catch return error.OutOfMemory;
            }
        }
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
                if (scan.ILV > 2) return error.NotImplemented;
                if (frame.?.num_components == 1) {
                    // ILV is irrelevant for single-component scans
                    // (T.87 §A.2 — line/sample/none all degenerate
                    // to the same bitstream); route through mono.
                    return try decodeScanMono(allocator, data[pos..], &frame.?, &scan, &preset);
                }
                if (frame.?.num_components == 3 and scan.ILV == 2) {
                    return try decodeScanRgb(allocator, data[pos..], &frame.?, &scan, &preset);
                }
                if (frame.?.num_components >= 2 and scan.ILV == 1) {
                    return try decodeScanLine(allocator, data[pos..], &frame.?, &scan, &preset);
                }
                return error.NotImplemented;
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
// Scan body — 1-component, 8 or 16-bit precision (Sessions 2 + 4).
// ─────────────────────────────────────────────────────────────────

/// Decode a 1-component JPEG-LS scan (8 or 16-bit precision).
/// Entropy-decodes every sample via regular or run mode and emits a
/// raster-order pixel buffer. T.87 §A; mirrors charls'
/// `jls_codec::do_line` / `do_run_mode` for the single-component path.
///
/// Output convention matches the rest of jpegz: P ≤ 8 → `[]u8`,
/// otherwise `[]u8` aliasing host-endian `[]u16` (caller reinterprets
/// via `image.pixelsU16()`).
fn decodeScanMono(
    allocator: Allocator,
    data: []const u8,
    frame: *const FrameInfo,
    scan: *const ScanInfo,
    preset: *const PresetParams,
) Error!types.Image {
    const W: u32 = frame.width;
    const H: u32 = frame.height;
    const P: u8 = frame.P;
    const bytes_per_sample: usize = if (P <= 8) 1 else 2;

    var state: codec.ScanState = undefined;
    state.reset(P, scan.NEAR);
    // Apply LSE preset overrides if present.
    if (preset.MAXVAL != 0) state.MAXVAL = preset.MAXVAL;
    if (preset.T1 != 0) state.T1 = preset.T1;
    if (preset.T2 != 0) state.T2 = preset.T2;
    if (preset.T3 != 0) state.T3 = preset.T3;
    if (preset.RESET != 0) state.RESET = preset.RESET;

    var br = bitstream.BitReader.init(data);
    const pixels = try allocator.alloc(u8, @as(usize, W) * @as(usize, H) * bytes_per_sample);
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
            const rd: i32 = if (x + 1 < W) prev_line[x + 2] else rb;

            const t1: i32 = @intCast(state.T1);
            const t2: i32 = @intCast(state.T2);
            const t3: i32 = @intCast(state.T3);
            const near_i: i32 = @intCast(state.NEAR);
            const q1 = codec.quantize(rd - rb, t1, t2, t3, near_i);
            const q2 = codec.quantize(rb - rc, t1, t2, t3, near_i);
            const q3 = codec.quantize(rc - ra, t1, t2, t3, near_i);

            const ctx = codec.computeContextIndex(q1, q2, q3);
            if (ctx.q == 0) {
                const consumed = try decodeRun(&state, &br, 0, ra, cur_line, prev_line, x, W);
                x += consumed;
            } else {
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
                    const b = state.contexts[0][ctx.q].B;
                    const n_i: i32 = @intCast(state.contexts[0][ctx.q].N);
                    if (2 * b + n_i - 1 < 0) errval = ~errval;
                }
                codec.updateState(&state, 0, ctx.q, errval);
                const signed_err = codec.applySign(errval, ctx.sign);
                const sample = codec.computeReconstructed(px, signed_err, state.MAXVAL, state.NEAR, state.RANGE);
                cur_line[x + 1] = sample;
                x += 1;
            }
        }
        // Drain cur_line → pixels (run mode wrote to cur_line; finalize).
        var xc: u32 = 0;
        while (xc < W) : (xc += 1) {
            const sample: i32 = cur_line[xc + 1];
            const out_idx: usize = (@as(usize, y) * @as(usize, W) + @as(usize, xc)) * bytes_per_sample;
            if (P <= 8) {
                pixels[out_idx] = @intCast(sample);
            } else {
                // Host-endian u16 — same convention as the lossless /
                // SOF2 12-bit cleanroom paths (`pixelsU16()` aliases).
                const v: u16 = @intCast(sample);
                std.mem.writeInt(u16, pixels[out_idx..][0..2], v, native_endian);
            }
        }
        @memcpy(prev_line, cur_line);
    }

    return types.Image{
        .pixels = pixels,
        .width = W,
        .height = H,
        .channels = 1,
        .bits_per_sample = P,
        .source_color_space = .grayscale,
        .layout = .grayscale,
    };
}

/// Run mode for a single component's pixel strip. T.87 §A.7; mirrors
/// charls' `decode_run_pixels` + `decode_run_interruption_pixel`.
///
/// `ci` selects the per-component **run_index** only. The regular-mode
/// and run-interruption *contexts* (`contexts_[]`,
/// `context_run_mode_[0..1]`) are SHARED across components in
/// line-interleaved mode (charls `scan.h::decode_lines`: only
/// `run_index` is loaded/saved per component; `contexts_` and
/// `context_run_mode_` are scan-wide). ILV=0 (planar) and ILV=2
/// (sample-interleaved) also pass `ci = 0` here.
///
/// Returns the number of pixels consumed (run length + 1 if a run-
/// interruption sample followed; or just run length at EOL).
fn decodeRun(
    state: *codec.ScanState,
    br: *bitstream.BitReader,
    ci: usize,
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
        const step: u32 = @as(u32, 1) << @intCast(codec.J_TABLE[state.run_index[ci]]);
        const count: u32 = @min(step, pixel_count - index);
        index += count;
        if (count == step and state.run_index[ci] < 31) state.run_index[ci] += 1;
        if (index == pixel_count) break;
    }
    if (index != pixel_count) {
        // Incomplete run — read residual bits.
        const j = codec.J_TABLE[state.run_index[ci]];
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
    // Run-interruption context is shared across components (see fn doc).
    const rc = &state.run_contexts[0][ri_type];
    const k = codec.runModeGetK(rc, ri_type);
    const e_mapped = codec.decodeGolombRice(
        br, k,
        @as(u8, @intCast(@as(i32, state.LIMIT) - codec.J_TABLE[state.run_index[ci]] - 1)),
        state.qbpp,
    );
    const errval = codec.runModeComputeError(rc, e_mapped, k, ri_type);
    codec.runModeUpdate(rc, errval, e_mapped, ri_type, state.RESET);

    const sample: i32 = if (ri_type == 0) blk: {
        // Edge case: predict from Rb, sign-flip error by sign(Rb - Ra).
        const s: i32 = if (rb_v > ra) 1 else if (rb_v < ra) -1 else 0;
        break :blk codec.computeReconstructed(rb_v, errval * s, state.MAXVAL, state.NEAR, state.RANGE);
    } else codec.computeReconstructed(ra, errval, state.MAXVAL, state.NEAR, state.RANGE);
    cur_line[start_x + index + 1] = sample;

    if (state.run_index[ci] > 0) state.run_index[ci] -= 1;
    return index + 1;
}

// ─────────────────────────────────────────────────────────────────
// Scan body — N-component line-interleaved (ILV=1), 8 or 16-bit.
// ─────────────────────────────────────────────────────────────────

/// Decode `W` pixels of one component's strip into `cur_line` (which
/// is `(W+2)`-wide, with index 0 reserved for the left sentinel and
/// indices 1..W holding the actual decoded samples). Uses the
/// per-component context state in `state.contexts[ci]` /
/// `state.run_index[ci]` / `state.run_contexts[ci]`.
///
/// This is the shared inner loop of `decodeScanMono` (ci = 0) and
/// `decodeScanLine` (ci = scan-component index, ILV=1). Algorithm
/// per T.87 §A.4–A.7; mirrors charls' `do_line<sample_type>`.
fn decodeLineForComponent(
    state: *codec.ScanState,
    br: *bitstream.BitReader,
    ci: usize,
    cur_line: []i32,
    prev_line: []const i32,
    W: u32,
) Error!void {
    // T.87 §A.1.2: at start of line, Ra ← Rb. Store at index 1 (index
    // 0 is the left-of-image sentinel, kept 0).
    cur_line[0] = prev_line[1];

    var x: u32 = 0;
    while (x < W) {
        const ra: i32 = cur_line[x];
        const rb: i32 = prev_line[x + 1];
        const rc: i32 = prev_line[x];
        const rd: i32 = if (x + 1 < W) prev_line[x + 2] else rb;

        const t1: i32 = @intCast(state.T1);
        const t2: i32 = @intCast(state.T2);
        const t3: i32 = @intCast(state.T3);
        const near_i: i32 = @intCast(state.NEAR);
        const q1 = codec.quantize(rd - rb, t1, t2, t3, near_i);
        const q2 = codec.quantize(rb - rc, t1, t2, t3, near_i);
        const q3 = codec.quantize(rc - ra, t1, t2, t3, near_i);
        const ctx = codec.computeContextIndex(q1, q2, q3);

        if (ctx.q == 0) {
            const consumed = try decodeRun(state, br, ci, ra, cur_line, prev_line, x, W);
            x += consumed;
        } else {
            // Regular-mode contexts are shared across components in
            // ILV=1 — only `run_index` is per-component (per charls
            // reference impl). Index `[0]` is the single canonical
            // table; `ci` is intentionally not used here.
            const c_correction: i32 = @as(i32, state.contexts[0][ctx.q].C);
            var px = codec.predictMed(ra, rb, rc);
            px += codec.applySign(c_correction, ctx.sign);
            if (px < 0) px = 0 else if (px > @as(i32, @intCast(state.MAXVAL))) px = @intCast(state.MAXVAL);

            const k = codec.computeK(
                state.contexts[0][ctx.q].N,
                state.contexts[0][ctx.q].A,
            );
            const merrval = codec.decodeGolombRice(br, k, state.LIMIT, state.qbpp);
            var errval = codec.mapMErrvalToErrval(merrval);
            if (k == 0) {
                const b = state.contexts[0][ctx.q].B;
                const n_i: i32 = @intCast(state.contexts[0][ctx.q].N);
                if (2 * b + n_i - 1 < 0) errval = ~errval;
            }
            codec.updateState(state, 0, ctx.q, errval);
            const signed_err = codec.applySign(errval, ctx.sign);
            const sample = codec.computeReconstructed(px, signed_err, state.MAXVAL, state.NEAR, state.RANGE);
            cur_line[x + 1] = sample;
            x += 1;
        }
    }
}

/// Decode a multi-component line-interleaved (ILV=1) JPEG-LS scan,
/// 8 or 16-bit precision. T.87 §A.2 line-interleaved decode: per scan
/// line, run a separate single-component pass for each component in
/// scan order, each using its own context state
/// (`state.contexts[c]`, `state.run_index[c]`, `state.run_contexts[c]`).
/// Output is pixel-interleaved in raster order to match the
/// `decodeScanRgb` (ILV=2) and library convention.
///
/// `scan.num_components` must be ≥ 2; ILV=1 with 1 component
/// degenerates to ILV=0 by the standard, and the dispatcher routes
/// that through `decodeScanMono`.
fn decodeScanLine(
    allocator: Allocator,
    data: []const u8,
    frame: *const FrameInfo,
    scan: *const ScanInfo,
    preset: *const PresetParams,
) Error!types.Image {
    const W: u32 = frame.width;
    const H: u32 = frame.height;
    const P: u8 = frame.P;
    const nc: usize = scan.num_components;
    const bytes_per_sample: usize = if (P <= 8) 1 else 2;

    var state: codec.ScanState = undefined;
    state.reset(P, scan.NEAR);
    if (preset.MAXVAL != 0) state.MAXVAL = preset.MAXVAL;
    if (preset.T1 != 0) state.T1 = preset.T1;
    if (preset.T2 != 0) state.T2 = preset.T2;
    if (preset.T3 != 0) state.T3 = preset.T3;
    if (preset.RESET != 0) state.RESET = preset.RESET;

    var br = bitstream.BitReader.init(data);
    const pixels = try allocator.alloc(u8, @as(usize, W) * @as(usize, H) * nc * bytes_per_sample);
    errdefer allocator.free(pixels);

    // Per-component scan-line buffers. Each (W+2) i32s wide — index 0
    // is the left-sentinel, indices 1..W hold the decoded samples.
    // Capped at 4 per ScanState's component-state arrays.
    const line_len: usize = @as(usize, W) + 2;
    var cur_lines: [4][]i32 = .{ &.{}, &.{}, &.{}, &.{} };
    var prev_lines: [4][]i32 = .{ &.{}, &.{}, &.{}, &.{} };
    defer {
        for (cur_lines) |buf| if (buf.len > 0) allocator.free(buf);
        for (prev_lines) |buf| if (buf.len > 0) allocator.free(buf);
    }
    var c: usize = 0;
    while (c < nc) : (c += 1) {
        cur_lines[c] = try allocator.alloc(i32, line_len);
        prev_lines[c] = try allocator.alloc(i32, line_len);
        @memset(prev_lines[c], 0);
    }

    var y: u32 = 0;
    while (y < H) : (y += 1) {
        // Decode each component's strip for this line.
        var ci: usize = 0;
        while (ci < nc) : (ci += 1) {
            @memset(cur_lines[ci], 0);
            try decodeLineForComponent(&state, &br, ci, cur_lines[ci], prev_lines[ci], W);
        }
        // Drain into interleaved raster pixels.
        var x: u32 = 0;
        while (x < W) : (x += 1) {
            var cc: usize = 0;
            while (cc < nc) : (cc += 1) {
                const sample: i32 = cur_lines[cc][x + 1];
                const out_idx: usize =
                    (@as(usize, y) * @as(usize, W) * nc +
                     @as(usize, x) * nc + cc) * bytes_per_sample;
                if (P <= 8) {
                    pixels[out_idx] = @intCast(sample);
                } else {
                    const v: u16 = @intCast(sample);
                    std.mem.writeInt(u16, pixels[out_idx..][0..2], v, native_endian);
                }
            }
        }
        // Promote cur → prev for each component's next line.
        var swp: usize = 0;
        while (swp < nc) : (swp += 1) {
            @memcpy(prev_lines[swp], cur_lines[swp]);
        }
    }

    return types.Image{
        .pixels = pixels,
        .width = W,
        .height = H,
        .channels = @intCast(nc),
        .bits_per_sample = P,
        .source_color_space = .rgb,
        .layout = .rgb,
    };
}

// ─────────────────────────────────────────────────────────────────
// Scan body — 3-component sample-interleaved, 8 or 16-bit precision.
// ─────────────────────────────────────────────────────────────────

/// Decode a 3-component sample-interleaved (ILV=2) JPEG-LS scan,
/// 8 or 16-bit precision. Mirrors charls' `do_line<triplet<sample_type>>`.
/// Contexts are SHARED across components in sample-interleaved mode
/// (T.87 §A.3.5 + charls' single `contexts_[]` array per codec
/// instance); the run-interruption sample always uses
/// `context_run_mode_[0]` (edge) for all three components — the run
/// only initiates over identical triplets, so its termination implies
/// an edge.
fn decodeScanRgb(
    allocator: Allocator,
    data: []const u8,
    frame: *const FrameInfo,
    scan: *const ScanInfo,
    preset: *const PresetParams,
) Error!types.Image {
    const W: u32 = frame.width;
    const H: u32 = frame.height;
    const P: u8 = frame.P;
    const bytes_per_sample: usize = if (P <= 8) 1 else 2;

    var state: codec.ScanState = undefined;
    state.reset(P, scan.NEAR);
    if (preset.MAXVAL != 0) state.MAXVAL = preset.MAXVAL;
    if (preset.T1 != 0) state.T1 = preset.T1;
    if (preset.T2 != 0) state.T2 = preset.T2;
    if (preset.T3 != 0) state.T3 = preset.T3;
    if (preset.RESET != 0) state.RESET = preset.RESET;

    var br = bitstream.BitReader.init(data);
    const pixels = try allocator.alloc(u8, @as(usize, W) * @as(usize, H) * 3 * bytes_per_sample);
    errdefer allocator.free(pixels);

    // (W+2) triplets per line × 3 components = (W+2)*3 i32 entries.
    //   indices 0..2    = left sentinel (col -1)
    //   indices 3..5    = pixel x=0
    //   ...
    //   indices 3*W..3*W+2 = pixel x=W-1
    //   indices 3*(W+1)..3*(W+1)+2 = right sentinel (unused; Rd replicates Rb at x=W-1)
    const line_len: usize = (@as(usize, W) + 2) * 3;
    const cur_line = try allocator.alloc(i32, line_len);
    defer allocator.free(cur_line);
    const prev_line = try allocator.alloc(i32, line_len);
    defer allocator.free(prev_line);
    @memset(prev_line, 0);

    var y: u32 = 0;
    while (y < H) : (y += 1) {
        @memset(cur_line, 0);
        // T.87 §A.1.2: at start of line, Ra(comp) ← Rb(comp). The left
        // sentinel (col -1) of cur_line takes prev_line's col 0 values.
        cur_line[0] = prev_line[3];
        cur_line[1] = prev_line[4];
        cur_line[2] = prev_line[5];

        var x: u32 = 0;
        while (x < W) {
            // Gather per-component neighbors and quantized contexts.
            const t1_i: i32 = @intCast(state.T1);
            const t2_i: i32 = @intCast(state.T2);
            const t3_i: i32 = @intCast(state.T3);
            const near_i: i32 = @intCast(state.NEAR);

            var ra: [3]i32 = undefined;
            var rb: [3]i32 = undefined;
            var rc: [3]i32 = undefined;
            var rd: [3]i32 = undefined;
            var ctx: [3]codec.ContextLookup = undefined;
            var all_zero_q: bool = true;

            const cur_idx: usize = (@as(usize, x) + 1) * 3;
            const left_idx: usize = @as(usize, x) * 3;
            const right_idx: usize = (@as(usize, x) + 2) * 3;

            var ci: usize = 0;
            while (ci < 3) : (ci += 1) {
                ra[ci] = cur_line[left_idx + ci];
                rb[ci] = prev_line[cur_idx + ci];
                rc[ci] = prev_line[left_idx + ci];
                rd[ci] = if (x + 1 < W) prev_line[right_idx + ci] else rb[ci];
                const q1 = codec.quantize(rd[ci] - rb[ci], t1_i, t2_i, t3_i, near_i);
                const q2 = codec.quantize(rb[ci] - rc[ci], t1_i, t2_i, t3_i, near_i);
                const q3 = codec.quantize(rc[ci] - ra[ci], t1_i, t2_i, t3_i, near_i);
                ctx[ci] = codec.computeContextIndex(q1, q2, q3);
                if (ctx[ci].q != 0) all_zero_q = false;
            }

            if (all_zero_q) {
                const consumed = try decodeRunRgb(&state, &br, ra, cur_line, prev_line, x, W);
                x += consumed;
            } else {
                ci = 0;
                while (ci < 3) : (ci += 1) {
                    const cstate = &state.contexts[0][ctx[ci].q];
                    var px = codec.predictMed(ra[ci], rb[ci], rc[ci]);
                    px += codec.applySign(@as(i32, cstate.C), ctx[ci].sign);
                    if (px < 0) px = 0 else if (px > @as(i32, @intCast(state.MAXVAL))) px = @intCast(state.MAXVAL);

                    const k = codec.computeK(cstate.N, cstate.A);
                    const merrval = codec.decodeGolombRice(&br, k, state.LIMIT, state.qbpp);
                    var errval = codec.mapMErrvalToErrval(merrval);
                    if (k == 0) {
                        const b = cstate.B;
                        const n_i: i32 = @intCast(cstate.N);
                        if (2 * b + n_i - 1 < 0) errval = ~errval;
                    }
                    codec.updateState(&state, 0, ctx[ci].q, errval);
                    const signed_err = codec.applySign(errval, ctx[ci].sign);
                    const sample = codec.computeReconstructed(px, signed_err, state.MAXVAL, state.NEAR, state.RANGE);
                    cur_line[cur_idx + ci] = sample;
                }
                x += 1;
            }
        }
        // Drain decoded line → RGB-interleaved raster pixels.
        var xc: u32 = 0;
        while (xc < W) : (xc += 1) {
            const cidx: usize = (@as(usize, xc) + 1) * 3;
            const oidx: usize = (@as(usize, y) * @as(usize, W) + @as(usize, xc)) * 3 * bytes_per_sample;
            if (P <= 8) {
                pixels[oidx]     = @intCast(cur_line[cidx]);
                pixels[oidx + 1] = @intCast(cur_line[cidx + 1]);
                pixels[oidx + 2] = @intCast(cur_line[cidx + 2]);
            } else {
                const v0: u16 = @intCast(cur_line[cidx]);
                const v1: u16 = @intCast(cur_line[cidx + 1]);
                const v2: u16 = @intCast(cur_line[cidx + 2]);
                std.mem.writeInt(u16, pixels[oidx..][0..2], v0, native_endian);
                std.mem.writeInt(u16, pixels[oidx + 2 ..][0..2], v1, native_endian);
                std.mem.writeInt(u16, pixels[oidx + 4 ..][0..2], v2, native_endian);
            }
        }
        @memcpy(prev_line, cur_line);
    }

    return types.Image{
        .pixels = pixels,
        .width = W,
        .height = H,
        .channels = 3,
        .bits_per_sample = P,
        .source_color_space = .rgb,
        .layout = .rgb,
    };
}

/// Triplet run mode. The run-length code itself is byte-identical to
/// the mono path (one J-table-indexed state); the interruption sample
/// decodes three errors via `context_run_mode_[0]` and reconstructs
/// each component via `Rb + Errval * sign(Rb - Ra)` per charls'
/// `decode_run_interruption_pixel(triplet)`.
fn decodeRunRgb(
    state: *codec.ScanState,
    br: *bitstream.BitReader,
    ra: [3]i32,
    cur_line: []i32,
    prev_line: []const i32,
    start_x: u32,
    W: u32,
) Error!u32 {
    const pixel_count: u32 = W - start_x;
    var index: u32 = 0;
    while (br.readBits(1) == 1) {
        const step: u32 = @as(u32, 1) << @intCast(codec.J_TABLE[state.run_index[0]]);
        const count: u32 = @min(step, pixel_count - index);
        index += count;
        if (count == step and state.run_index[0] < 31) state.run_index[0] += 1;
        if (index == pixel_count) break;
    }
    if (index != pixel_count) {
        const j = codec.J_TABLE[state.run_index[0]];
        if (j > 0) {
            const residual: u32 = br.readBits(@intCast(j));
            index += residual;
        }
    }
    if (index > pixel_count) return error.BackendError;

    // Fill run with Ra triplet.
    var i: u32 = 0;
    while (i < index) : (i += 1) {
        const cidx: usize = (@as(usize, start_x) + 1 + @as(usize, i)) * 3;
        cur_line[cidx]     = ra[0];
        cur_line[cidx + 1] = ra[1];
        cur_line[cidx + 2] = ra[2];
    }

    if (start_x + index == W) return index;

    // Run interruption sample. Per charls' triplet path, all three
    // components use context_run_mode_[0] (RItype = 0, edge case)
    // since the run was over identical triplets.
    const cur_idx: usize = (@as(usize, start_x) + @as(usize, index) + 1) * 3;
    const rb: [3]i32 = .{
        prev_line[cur_idx],
        prev_line[cur_idx + 1],
        prev_line[cur_idx + 2],
    };
    const rc = &state.run_contexts[0][0];
    var ci: usize = 0;
    while (ci < 3) : (ci += 1) {
        const k = codec.runModeGetK(rc, 0);
        const e_mapped = codec.decodeGolombRice(
            br, k,
            @as(u8, @intCast(@as(i32, state.LIMIT) - codec.J_TABLE[state.run_index[0]] - 1)),
            state.qbpp,
        );
        const errval = codec.runModeComputeError(rc, e_mapped, k, 0);
        codec.runModeUpdate(rc, errval, e_mapped, 0, state.RESET);
        // charls' `sign(n) = (n >> 31) | 1` collapses to +1 / -1 (never 0)
        // unlike a standard signum. When `rb == ra` the encoder used +1
        // here, so the round-trip relies on the same convention.
        const sgn: i32 = if (rb[ci] - ra[ci] < 0) -1 else 1;
        const sample = codec.computeReconstructed(rb[ci], errval * sgn, state.MAXVAL, state.NEAR, state.RANGE);
        cur_line[cur_idx + ci] = sample;
    }

    if (state.run_index[0] > 0) state.run_index[0] -= 1;
    return index + 1;
}

// Force-import the codec module so its inline tests run if this is the
// test root (not necessary for the jpegls module's own tests; harmless).
comptime {
    _ = codec;
}

