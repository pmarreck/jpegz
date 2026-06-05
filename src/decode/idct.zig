//! Inverse 8×8 DCT — three flavors:
//!
//!   1. `idct8x8_fpd` — direct T.81 Annex A IDCT in fixed-point decimal
//!      Integer constants × 10^6, i128 math; no runtime float. Test oracle.
//!
//!   2. `idct8x8` — 8-bit thin wrapper over `idct8x8Generic(8, ...)`.
//!      Public stable API used by SOF0/SOF1 8-bit cleanroom. Output
//!      is byte-identical to libjpeg-turbo's `jpeg_idct_islow`.
//!
//!   3. `idct8x8_12` — 12-bit thin wrapper over `idct8x8Generic(12, ...)`.
//!      Used by SOF1 12-bit cleanroom (A1 milestone). Output is
//!      u16 host-endian, range [0, 4095] per T.81 §A.3.1.
//!
//! The generic core is libjpeg-turbo "islow" integer IDCT
//! (Loeffler/Ligtenberg/Moschytz with 13-bit fixed-point constants).
//! Accumulator widens from i32 → i64 at P=12 because dequantized
//! 12-bit DC × 16-bit quant entries can reach ~2^31, which the
//! column-pass `<< PASS1_BITS` shift would otherwise overflow.
//! Source-of-truth: jidctint.c (8-bit) and jidct12.c (12-bit).
//!
//! Output ordering for all flavors:
//!   - Input: 8×8 block in zig-zag-unsorted natural order, signed
//!     coefficients (DCT post-dequantization). Indexed [v][u]
//!     where v = vertical freq, u = horizontal freq.
//!   - Output: 8×8 spatial block, level-shifted to [0, 2^P-1],
//!     indexed [y][x]. The level shift +2^(P-1) is added before
//!     clamping per T.81 §A.3.1 (samples are unsigned in T.81).
//!
//! Reference: ITU-T T.81 §A.3.3 (IDCT), §A.3.1 (level shift);
//! libjpeg-turbo jidctint.c / jidct12.c (islow algorithm).

const std = @import("std");

const N: usize = 8;

// ─────── islow integer IDCT (libjpeg-turbo's jpeg_idct_islow) ────────

/// Number of fractional bits in fixed-point IDCT constants. Matches
/// libjpeg-turbo's CONST_BITS in jidctint.c.
const CONST_BITS: u5 = 13;

/// Bits added to column-pass output that the row pass then absorbs.
/// libjpeg-turbo (jidctint.c lines 102-108) defines PASS1_BITS per
/// the BITS_IN_JSAMPLE compile flag:
///   - BITS_IN_JSAMPLE == 8  → PASS1_BITS = 2
///   - BITS_IN_JSAMPLE  > 8  → PASS1_BITS = 1 ("lose a little precision
///                                              to avoid overflow")
/// Per the same comment block (lines 97-99), the constraint is
/// `BITS_IN_JSAMPLE + CONST_BITS + PASS1_BITS <= 26` for 32-bit
/// intermediate safety in pass 2. The 12-bit cleanroom widens its
/// accumulator to i64 anyway, but we mirror libjpeg's PASS1_BITS=1
/// at P=12 to keep byte-identical rounding output.
fn pass1Bits(comptime P: u8) comptime_int {
    return if (P == 8) 2 else 1;
}

// Fixed-point multiplier constants from libjpeg-turbo:
// FIX(x) = round(x * 2^CONST_BITS).
const FIX_0_298631336: i32 = 2446;
const FIX_0_390180644: i32 = 3196;
const FIX_0_541196100: i32 = 4433;
const FIX_0_765366865: i32 = 6270;
const FIX_0_899976223: i32 = 7373;
const FIX_1_175875602: i32 = 9633;
const FIX_1_501321110: i32 = 12299;
const FIX_1_847759065: i32 = 15137;
const FIX_1_961570560: i32 = 16069;
const FIX_2_053119869: i32 = 16819;
const FIX_2_562915447: i32 = 20995;
const FIX_3_072711026: i32 = 25172;

inline fn descale(comptime T: type, x: T, comptime n: comptime_int) T {
    // Symmetric rounding right-shift: add 0.5 ULP before shifting.
    return (x + (@as(T, 1) << (n - 1))) >> n;
}

inline fn rangeLimit(comptime SampleT: type, comptime max: comptime_int, v: anytype) SampleT {
    if (v < 0) return 0;
    if (v > max) return @intCast(max);
    return @intCast(v);
}

/// Return the host integer type used for a P-bit DCT IDCT output sample.
/// P=8 → u8, P=12 → u16.
pub fn Sample(comptime P: u8) type {
    return switch (P) {
        8 => u8,
        12 => u16,
        else => @compileError("idct: unsupported precision (only 8 or 12)"),
    };
}

/// Return the host integer type used for intermediate accumulators at
/// precision P. P=8 keeps i32 (preserves libjpeg-turbo byte-identical
/// output). P=12 widens to i64 to absorb dequantized 12-bit DC × 16-bit
/// quant table entries that can reach ~2^31 before the column-pass shift.
fn Accumulator(comptime P: u8) type {
    return switch (P) {
        8 => i32,
        12 => i64,
        else => @compileError("idct: unsupported precision (only 8 or 12)"),
    };
}

/// 8-bit thin wrapper around the comptime-generic IDCT. Public stable
/// API; cleanroom 8-bit callers use this. Byte-identical to
/// libjpeg-turbo's `jpeg_idct_islow`.
pub fn idct8x8(coeffs: *const [64]i32, out: *[64]u8) void {
    idct8x8Generic(8, coeffs, out);
}

/// 12-bit thin wrapper. Cleanroom SOF1@P=12 (A1) calls this. Output is
/// u16 host-endian, range [0, 4095].
pub fn idct8x8_12(coeffs: *const [64]i32, out: *[64]u16) void {
    idct8x8Generic(12, coeffs, out);
}

/// libjpeg-turbo's `jpeg_idct_islow` reproduced bit-for-bit, generic
/// over precision P ∈ {8, 12}. Operates on natural-row-major
/// coefficients (post-dequant) and produces level-shifted P-bit samples.
/// Same algorithm topology, fixed-point constants, and rounding ties as
/// libjpeg — at P=8 the output matches `jpeg_idct_islow` byte-for-byte;
/// at P=12 it matches `jpeg_idct_12_islow`.
pub fn idct8x8Generic(comptime P: u8, coeffs: *const [64]i32, out: *[64]Sample(P)) void {
    const Acc = Accumulator(P);
    const SampleT = Sample(P);
    const level_shift: comptime_int = 1 << (P - 1); // 128 for P=8, 2048 for P=12
    const sample_max: comptime_int = (1 << P) - 1; // 255 for P=8, 4095 for P=12
    const PASS1_BITS: comptime_int = pass1Bits(P);
    var workspace: [64]Acc = undefined;

    // ── Column pass: process 8 columns of the 8×8 input ──────────
    var ctr: usize = 0;
    while (ctr < 8) : (ctr += 1) {
        const c0: Acc = @as(Acc, coeffs[0 * 8 + ctr]);
        const c1: Acc = @as(Acc, coeffs[1 * 8 + ctr]);
        const c2: Acc = @as(Acc, coeffs[2 * 8 + ctr]);
        const c3: Acc = @as(Acc, coeffs[3 * 8 + ctr]);
        const c4: Acc = @as(Acc, coeffs[4 * 8 + ctr]);
        const c5: Acc = @as(Acc, coeffs[5 * 8 + ctr]);
        const c6: Acc = @as(Acc, coeffs[6 * 8 + ctr]);
        const c7: Acc = @as(Acc, coeffs[7 * 8 + ctr]);

        // Shortcut: if AC terms are all zero, the column is just the DC
        // smeared up by PASS1_BITS. libjpeg uses this to make all-DC
        // blocks (very common in flat areas) much faster.
        if (c1 == 0 and c2 == 0 and c3 == 0 and c4 == 0 and c5 == 0 and c6 == 0 and c7 == 0) {
            const dcval: Acc = c0 << PASS1_BITS;
            workspace[0 * 8 + ctr] = dcval;
            workspace[1 * 8 + ctr] = dcval;
            workspace[2 * 8 + ctr] = dcval;
            workspace[3 * 8 + ctr] = dcval;
            workspace[4 * 8 + ctr] = dcval;
            workspace[5 * 8 + ctr] = dcval;
            workspace[6 * 8 + ctr] = dcval;
            workspace[7 * 8 + ctr] = dcval;
            continue;
        }

        // Even part: rotation by π/4 followed by butterflies.
        var z2: Acc = c2;
        var z3: Acc = c6;
        var z1: Acc = (z2 + z3) * FIX_0_541196100;
        const tmp2: Acc = z1 + z3 * -FIX_1_847759065;
        const tmp3: Acc = z1 + z2 * FIX_0_765366865;

        z2 = c0;
        z3 = c4;
        const tmp0: Acc = (z2 + z3) << CONST_BITS;
        const tmp1: Acc = (z2 - z3) << CONST_BITS;

        const tmp10: Acc = tmp0 + tmp3;
        const tmp13: Acc = tmp0 - tmp3;
        const tmp11: Acc = tmp1 + tmp2;
        const tmp12: Acc = tmp1 - tmp2;

        // Odd part: butterflies + rotations to extract odd terms.
        var ot0: Acc = c7;
        var ot1: Acc = c5;
        var ot2: Acc = c3;
        var ot3: Acc = c1;

        z1 = ot0 + ot3;
        z2 = ot1 + ot2;
        z3 = ot0 + ot2;
        var z4: Acc = ot1 + ot3;
        const z5: Acc = (z3 + z4) * FIX_1_175875602;

        ot0 = ot0 * FIX_0_298631336;
        ot1 = ot1 * FIX_2_053119869;
        ot2 = ot2 * FIX_3_072711026;
        ot3 = ot3 * FIX_1_501321110;
        z1 = z1 * -FIX_0_899976223;
        z2 = z2 * -FIX_2_562915447;
        z3 = z3 * -FIX_1_961570560;
        z4 = z4 * -FIX_0_390180644;

        z3 += z5;
        z4 += z5;

        ot0 += z1 + z3;
        ot1 += z2 + z4;
        ot2 += z2 + z3;
        ot3 += z1 + z4;

        // Final butterflies + rounding right-shift.
        const shift: comptime_int = CONST_BITS - PASS1_BITS;
        workspace[0 * 8 + ctr] = descale(Acc, tmp10 + ot3, shift);
        workspace[7 * 8 + ctr] = descale(Acc, tmp10 - ot3, shift);
        workspace[1 * 8 + ctr] = descale(Acc, tmp11 + ot2, shift);
        workspace[6 * 8 + ctr] = descale(Acc, tmp11 - ot2, shift);
        workspace[2 * 8 + ctr] = descale(Acc, tmp12 + ot1, shift);
        workspace[5 * 8 + ctr] = descale(Acc, tmp12 - ot1, shift);
        workspace[3 * 8 + ctr] = descale(Acc, tmp13 + ot0, shift);
        workspace[4 * 8 + ctr] = descale(Acc, tmp13 - ot0, shift);
    }

    // ── Row pass: process 8 rows of the workspace ────────────────
    // Final shift is CONST_BITS + PASS1_BITS + 3 to absorb the 8× row
    // scale; level-shift +2^(P-1) is added before rounding so the same
    // descale handles it (libjpeg's identical trick).
    var row: usize = 0;
    while (row < 8) : (row += 1) {
        const base: usize = row * 8;
        const c0: Acc = workspace[base + 0];
        const c1: Acc = workspace[base + 1];
        const c2: Acc = workspace[base + 2];
        const c3: Acc = workspace[base + 3];
        const c4: Acc = workspace[base + 4];
        const c5: Acc = workspace[base + 5];
        const c6: Acc = workspace[base + 6];
        const c7: Acc = workspace[base + 7];

        if (c1 == 0 and c2 == 0 and c3 == 0 and c4 == 0 and c5 == 0 and c6 == 0 and c7 == 0) {
            // Flat row: DC only. Result = (DC + level-shift round) >> shift.
            const dcval: Acc = descale(Acc, c0, PASS1_BITS + 3) + level_shift;
            const v: SampleT = rangeLimit(SampleT, sample_max, dcval);
            out[base + 0] = v;
            out[base + 1] = v;
            out[base + 2] = v;
            out[base + 3] = v;
            out[base + 4] = v;
            out[base + 5] = v;
            out[base + 6] = v;
            out[base + 7] = v;
            continue;
        }

        var z2: Acc = c2;
        var z3: Acc = c6;
        var z1: Acc = (z2 + z3) * FIX_0_541196100;
        const tmp2: Acc = z1 + z3 * -FIX_1_847759065;
        const tmp3: Acc = z1 + z2 * FIX_0_765366865;

        z2 = c0;
        z3 = c4;
        const tmp0: Acc = (z2 + z3) << CONST_BITS;
        const tmp1: Acc = (z2 - z3) << CONST_BITS;

        const tmp10: Acc = tmp0 + tmp3;
        const tmp13: Acc = tmp0 - tmp3;
        const tmp11: Acc = tmp1 + tmp2;
        const tmp12: Acc = tmp1 - tmp2;

        var ot0: Acc = c7;
        var ot1: Acc = c5;
        var ot2: Acc = c3;
        var ot3: Acc = c1;

        z1 = ot0 + ot3;
        z2 = ot1 + ot2;
        z3 = ot0 + ot2;
        var z4: Acc = ot1 + ot3;
        const z5: Acc = (z3 + z4) * FIX_1_175875602;

        ot0 = ot0 * FIX_0_298631336;
        ot1 = ot1 * FIX_2_053119869;
        ot2 = ot2 * FIX_3_072711026;
        ot3 = ot3 * FIX_1_501321110;
        z1 = z1 * -FIX_0_899976223;
        z2 = z2 * -FIX_2_562915447;
        z3 = z3 * -FIX_1_961570560;
        z4 = z4 * -FIX_0_390180644;

        z3 += z5;
        z4 += z5;

        ot0 += z1 + z3;
        ot1 += z2 + z4;
        ot2 += z2 + z3;
        ot3 += z1 + z4;

        const shift: comptime_int = CONST_BITS + PASS1_BITS + 3;
        out[base + 0] = rangeLimit(SampleT, sample_max, descale(Acc, tmp10 + ot3, shift) + level_shift);
        out[base + 7] = rangeLimit(SampleT, sample_max, descale(Acc, tmp10 - ot3, shift) + level_shift);
        out[base + 1] = rangeLimit(SampleT, sample_max, descale(Acc, tmp11 + ot2, shift) + level_shift);
        out[base + 6] = rangeLimit(SampleT, sample_max, descale(Acc, tmp11 - ot2, shift) + level_shift);
        out[base + 2] = rangeLimit(SampleT, sample_max, descale(Acc, tmp12 + ot1, shift) + level_shift);
        out[base + 5] = rangeLimit(SampleT, sample_max, descale(Acc, tmp12 - ot1, shift) + level_shift);
        out[base + 3] = rangeLimit(SampleT, sample_max, descale(Acc, tmp13 + ot0, shift) + level_shift);
        out[base + 4] = rangeLimit(SampleT, sample_max, descale(Acc, tmp13 - ot0, shift) + level_shift);
    }
}

// ─────── Reference fixed-point-decimal IDCT (kept for tests / oracle) ──────

/// IDCT cosine basis cos((2x+1)·u·π/16), written as fixed-point **decimal**
/// scalars: each entry is the true value × 10^6, rounded to an integer (the
/// decimal point is "6 places", tracked in the arithmetic below). No floats —
/// these are the ITU-T T.81 Annex A basis values authored directly as
/// integers. Rows are frequency u (0..7), columns spatial x (0..7).
const FPD_SCALE: i128 = 1_000_000; // 10^6 — six tracked decimal places

const COS_Q: [N][N]i64 = .{
    .{ 1000000, 1000000, 1000000, 1000000, 1000000, 1000000, 1000000, 1000000 },
    .{ 980785, 831470, 555570, 195090, -195090, -555570, -831470, -980785 },
    .{ 923880, 382683, -382683, -923880, -923880, -382683, 382683, 923880 },
    .{ 831470, -195090, -980785, -555570, 555570, 980785, 195090, -831470 },
    .{ 707107, -707107, -707107, 707107, 707107, -707107, -707107, 707107 },
    .{ 555570, -980785, 195090, 831470, -831470, -195090, 980785, -555570 },
    .{ 382683, -923880, 923880, -382683, -382683, 923880, -923880, 382683 },
    .{ 195090, -555570, 831470, -980785, 980785, -831470, 555570, -195090 },
};

/// Per-axis normalization C(u): 1/√2 for u==0 (707107 = round(0.7071068×10^6)),
/// else 1 (1000000). Same ×10^6 fixed-point decimal scale as COS_Q.
const NORM_Q: [N]i64 = .{ 707107, 1000000, 1000000, 1000000, 1000000, 1000000, 1000000, 1000000 };

/// Reference IDCT — the direct T.81 Annex A double-sum done entirely in
/// **fixed-point decimal** (integers with the decimal point tracked), so it is
/// float-free at runtime. Kept as an oracle for tests; the production path is
/// the integer `idct8x8` above. Slow (~4096 i128 multiply-accumulates per
/// block) but obviously correct.
///
/// Each term = coeff × NORM_Q[u] × NORM_Q[v] × COS_Q[u][x] × COS_Q[v][y],
/// carrying four ×10^6 constant scales (10^24 total); the spec's 1/4 factor is
/// the extra ÷4. The block accumulates in i128, then a single
/// round-half-away-from-zero divide by 4·10^24 recovers the integer sample,
/// + 128 level shift (T.81 §A.3.1), clamped to [0, 255]. i128 has ample
/// headroom: worst-case |term| ≈ i32_max × 10^24 ≈ 2·10^33, ×64 ≪ i128_max.
pub fn idct8x8_fpd(coeffs: *const [64]i32, out: *[64]u8) void {
    const denom: i128 = 4 * FPD_SCALE * FPD_SCALE * FPD_SCALE * FPD_SCALE; // 4·10^24
    const half: i128 = @divTrunc(denom, 2);
    var y: usize = 0;
    while (y < N) : (y += 1) {
        var x: usize = 0;
        while (x < N) : (x += 1) {
            var sum: i128 = 0;
            var v: usize = 0;
            while (v < N) : (v += 1) {
                var u: usize = 0;
                while (u < N) : (u += 1) {
                    sum += @as(i128, coeffs[v * N + u]) *
                        @as(i128, NORM_Q[u]) * @as(i128, NORM_Q[v]) *
                        @as(i128, COS_Q[u][x]) * @as(i128, COS_Q[v][y]);
                }
            }
            // Round-half-away-from-zero divide by denom (folds the 1/4 and the
            // 10^24 constant scale), then level-shift and clamp.
            const sample_int: i128 = if (sum >= 0)
                @divTrunc(sum + half, denom)
            else
                @divTrunc(sum - half, denom);
            const shifted: i128 = sample_int + 128;
            out[y * N + x] = if (shifted < 0) 0 else if (shifted > 255) 255 else @intCast(shifted);
        }
    }
}

// ── Tests ────────────────────────────────────────────────────

test "idct8x8 of all-zero coefficients yields uniform 128" {
    const coeffs = [_]i32{0} ** 64;
    var out: [64]u8 = undefined;
    idct8x8(&coeffs, &out);
    for (out) |s| try std.testing.expectEqual(@as(u8, 128), s);
}

test "idct8x8 of DC-only with positive amplitude yields uniform brighter" {
    var coeffs = [_]i32{0} ** 64;
    coeffs[0] = 256; // DC coefficient: shifts the mean up
    var out: [64]u8 = undefined;
    idct8x8(&coeffs, &out);
    // Per the formula: output = NORM[0]*NORM[0] * coeff * 1 * 1 * 0.25 + 128
    //                = (1/√2)² * 256 * 0.25 + 128 = 0.5 * 64 + 128 = 160
    for (out) |s| try std.testing.expectEqual(@as(u8, 160), s);
}

test "idct8x8 of DC-only with negative amplitude yields uniform darker" {
    var coeffs = [_]i32{0} ** 64;
    coeffs[0] = -256;
    var out: [64]u8 = undefined;
    idct8x8(&coeffs, &out);
    // -256 → 128 - 32 = 96
    for (out) |s| try std.testing.expectEqual(@as(u8, 96), s);
}

test "idct8x8 clamps to 0..255" {
    var coeffs = [_]i32{0} ** 64;
    coeffs[0] = 4096; // way too large; output would overflow without clamp
    var out: [64]u8 = undefined;
    idct8x8(&coeffs, &out);
    for (out) |s| try std.testing.expectEqual(@as(u8, 255), s);

    coeffs[0] = -4096;
    idct8x8(&coeffs, &out);
    for (out) |s| try std.testing.expectEqual(@as(u8, 0), s);
}

// ── Precision-parametric tests (P ∈ {8, 12}) ────────────────────────

test "idct8x8Generic all-zero coefficients yield uniform level-shift at every P" {
    inline for (.{ 8, 12 }) |P| {
        const coeffs = [_]i32{0} ** 64;
        var out: [64]Sample(P) = undefined;
        idct8x8Generic(P, &coeffs, &out);
        const expected: Sample(P) = 1 << (P - 1);
        for (out) |s| try std.testing.expectEqual(expected, s);
    }
}

test "idct8x8Generic DC-only positive amplitude yields uniform brighter at every P" {
    inline for (.{ 8, 12 }) |P| {
        var coeffs = [_]i32{0} ** 64;
        coeffs[0] = 256; // DC coefficient
        var out: [64]Sample(P) = undefined;
        idct8x8Generic(P, &coeffs, &out);
        // Formula at every P: NORM[0]² × DC × 0.25 + level_shift
        //   = (1/√2)² × 256 × 0.25 + 2^(P-1)
        //   = 0.5 × 64 + 2^(P-1) = 32 + 2^(P-1)
        const expected: Sample(P) = (1 << (P - 1)) + 32;
        for (out) |s| try std.testing.expectEqual(expected, s);
    }
}

test "idct8x8Generic clamps to [0, 2^P-1] at every P" {
    inline for (.{ 8, 12 }) |P| {
        var coeffs = [_]i32{0} ** 64;
        // Saturate high: DC large enough to overflow even at P=12
        coeffs[0] = 1 << 18;
        var out: [64]Sample(P) = undefined;
        idct8x8Generic(P, &coeffs, &out);
        const max_sample: Sample(P) = (1 << P) - 1;
        for (out) |s| try std.testing.expectEqual(max_sample, s);
        // Saturate low.
        coeffs[0] = -(@as(i32, 1) << 18);
        idct8x8Generic(P, &coeffs, &out);
        for (out) |s| try std.testing.expectEqual(@as(Sample(P), 0), s);
    }
}

test "idct8x8_fpd (fixed-point-decimal oracle) matches production islow idct8x8 within tolerance" {
    // Cross-validate the spec-derived Annex-A fixed-point-decimal reference
    // against the production islow integer IDCT over pseudo-random blocks.
    // Both approximate the true IDCT (T.81 §A.3.3); the project's IDCT
    // tolerance is ≤2 LSB, which bounds their difference. A deterministic LCG
    // keeps the test reproducible without depending on std.Random's API.
    var seed: u32 = 0xC0FFEE;
    var trial: usize = 0;
    while (trial < 200) : (trial += 1) {
        var coeffs: [64]i32 = undefined;
        for (&coeffs) |*c| {
            seed = seed *% 1103515245 +% 12345;
            c.* = @as(i32, @intCast((seed >> 16) & 0x7FF)) - 1024; // [-1024, 1023]
        }
        var a: [64]u8 = undefined;
        var b: [64]u8 = undefined;
        idct8x8(&coeffs, &a);
        idct8x8_fpd(&coeffs, &b);
        for (a, b) |va, vb| {
            const d = if (va > vb) va - vb else vb - va;
            try std.testing.expect(d <= 2);
        }
    }
}

test "idct8x8_fpd all-zero coefficients yield uniform 128" {
    const coeffs = [_]i32{0} ** 64;
    var out: [64]u8 = undefined;
    idct8x8_fpd(&coeffs, &out);
    for (out) |s| try std.testing.expectEqual(@as(u8, 128), s);
}
