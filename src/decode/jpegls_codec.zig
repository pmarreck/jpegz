//! LOCO-I codec helpers for JPEG-LS (T.87 Annex A).
//!
//! Pure functions over a `ScanState` — no I/O, no allocation. The
//! integration loop lives in `jpegls.zig`; this file owns the
//! per-sample math:
//!
//!   - MED predictor (`predictMed`)
//!   - Gradient quantization + sign-canonicalized context index
//!     (`quantize`, `computeContextIndex`)
//!   - Golomb-Rice parameter selection + decode
//!     (`computeK`, `decodeGolombRice`, `mapMErrvalToErrval`)
//!   - Per-context state update (`updateState`, `updateBiasCorrection`)
//!
//! v1 scope: NEAR = 0 (lossless), 8 and 16-bit precision, 1- and
//! 3-component. NEAR > 0 paths are stubbed in the appropriate
//! functions and would be the natural follow-on for B2.2-v2.

const std = @import("std");
const bitstream = @import("jpegls_bitstream");

/// Number of regular-mode contexts (T.87 §A.3.5). 9 × 9 × 9 = 729
/// raw tuples, sign-canonicalized down to (729 - 1) / 2 + 1 = 365.
/// Indices 0..364. Plus two run-interruption contexts at 365/366.
pub const NUM_CONTEXTS: usize = 367;

/// Per-context state — T.87 §A.3.4. One row per context.
pub const ContextState = struct {
    /// Accumulated absolute prediction errors (Σ |Errval|).
    /// 32-bit headroom against 16-bit MAXVAL × RESET sums.
    A: u32 = 4,
    /// Signed running bias (Σ Errval). Capped via the decimation
    /// rule when N halves.
    B: i32 = 0,
    /// Bias correction (integer added to predicted value before
    /// the error is decoded). Clamped to [-128, 127] per §A.6.
    C: i8 = 0,
    /// Occurrence count. Starts at 1 so the initial `computeK`
    /// doesn't divide by zero.
    N: u32 = 1,
};

/// Frame-scope scan state. One instance per scan; reset on RST in
/// the rare cases JPEG-LS uses them.
pub const ScanState = struct {
    /// Per-component context tables. JPEG-LS replicates state per
    /// component for multi-component scans (T.87 §A.3.5).
    contexts: [4][NUM_CONTEXTS]ContextState,
    /// Two run-interruption contexts per component (T.87 §A.7.2):
    ///   [0] = RItype 0 (|Ra - Rb| ≤ NEAR — flat region)
    ///   [1] = RItype 1 (anything else)
    run_contexts: [4][2]RunContextState,
    /// One run_index per component (T.87 §A.7.1). Caps at 31.
    /// Advances on each run continuation; decrements after a run
    /// interruption sample.
    run_index: [4]u8,
    /// Frame parameters.
    MAXVAL: u32,
    NEAR: u32,
    T1: u32,
    T2: u32,
    T3: u32,
    RESET: u32,
    /// Bits per pixel (e.g. 8 or 16). Drives RANGE and LIMIT.
    bpp: u8,
    /// Quantized bpp: ceil(log2(RANGE / (2*NEAR + 1))) per T.87
    /// §A.2.1. For NEAR=0 this equals bpp.
    qbpp: u8,
    /// LIMIT for unary Golomb-Rice (T.87 §A.5.3, Eq. A.18):
    /// `2 * (bpp + max(8, bpp)) - qbpp - 1`. At bpp=8: 23.
    LIMIT: u8,

    /// Initialize all contexts to (A=max(2, (RANGE+32) >> 6), B=0,
    /// C=0, N=1) per T.87 §A.8. T1/T2/T3 default to spec values
    /// when MAXVAL/NEAR are at the standard 8-bit defaults; for
    /// other configurations they're recomputed per Eq. A.8.
    pub fn reset(self: *ScanState, bpp: u8, near: u32) void {
        const MAXVAL: u32 = (@as(u32, 1) << @intCast(bpp)) - 1;
        const RANGE: u32 = (MAXVAL + 2 * near) / (2 * near + 1) + 1;
        const initial_A: u32 = @max(2, (RANGE + 32) >> 6);
        const qbpp: u8 = @intCast(@max(2, std.math.log2_int_ceil(u32, RANGE)));
        self.MAXVAL = MAXVAL;
        self.NEAR = near;
        self.RESET = 64; // T.87 default
        self.bpp = bpp;
        self.qbpp = qbpp;
        self.LIMIT = computeLimit(bpp, qbpp);
        self.run_index = .{ 0, 0, 0, 0 };
        // Per-context init — direct fill to keep Zig's type inference
        // simple (nested struct literals through 3 array dimensions
        // confuse it as of 0.16).
        var ci: usize = 0;
        while (ci < 4) : (ci += 1) {
            var q: usize = 0;
            while (q < NUM_CONTEXTS) : (q += 1) {
                self.contexts[ci][q] = .{ .A = initial_A, .B = 0, .C = 0, .N = 1 };
            }
            // Run-interruption contexts also use initial A per
            // T.87 §A.8 step 1.f.
            self.run_contexts[ci][0] = .{ .A = initial_A, .Nn = 0, .N = 1 };
            self.run_contexts[ci][1] = .{ .A = initial_A, .Nn = 0, .N = 1 };
        }
        self.setDefaultThresholds();
    }

    /// Compute default T1/T2/T3 per T.87 §C.2.4.1.1. The spec splits
    /// on MAXVAL ≥ 128 vs < 128; both branches reduce to T1=3, T2=7,
    /// T3=21 for the 8-bit NEAR=0 case (worked example).
    pub fn setDefaultThresholds(self: *ScanState) void {
        const near_i: i32 = @intCast(self.NEAR);
        const maxv_i: i32 = @intCast(self.MAXVAL);
        if (self.MAXVAL >= 128) {
            // FACTOR ∈ [1, 16] for MAXVAL ∈ [128, 4095].
            const factor: i32 = @intCast(((@min(self.MAXVAL, 4095)) + 128) >> 8);
            const t1_basic: i32 = factor * (3 - 2) + 2 + 3 * near_i;
            const t2_basic: i32 = factor * (7 - 2) + 2 + 5 * near_i;
            const t3_basic: i32 = factor * (21 - 2) + 2 + 7 * near_i;
            self.T1 = @intCast(clampI32(t1_basic, near_i + 1, maxv_i));
            self.T2 = @intCast(clampI32(t2_basic, @as(i32, @intCast(self.T1)), maxv_i));
            self.T3 = @intCast(clampI32(t3_basic, @as(i32, @intCast(self.T2)), maxv_i));
        } else {
            // MAXVAL < 128. Inverse FACTOR rescales the canonical
            // {3, 7, 21} downward for narrow-range images.
            const factor_in: i32 = @divFloor(256, maxv_i + 1);
            const t1_basic: i32 = @max(2, @divFloor(3, factor_in)) + 3 * near_i;
            const t2_basic: i32 = @max(3, @divFloor(7, factor_in)) + 5 * near_i;
            const t3_basic: i32 = @max(4, @divFloor(21, factor_in)) + 7 * near_i;
            self.T1 = @intCast(clampI32(t1_basic, near_i + 1, maxv_i));
            self.T2 = @intCast(clampI32(t2_basic, @as(i32, @intCast(self.T1)), maxv_i));
            self.T3 = @intCast(clampI32(t3_basic, @as(i32, @intCast(self.T2)), maxv_i));
        }
    }
};

inline fn clampI32(v: i32, lo: i32, hi: i32) i32 {
    return @max(lo, @min(hi, v));
}

/// `LIMIT = 2 * (bpp + max(8, bpp))`. This matches charls's
/// `compute_limit_parameter`; the `- qbpp - 1` from the T.87 text
/// formula is applied at the *comparison* site inside
/// `decodeGolombRice` (the standard/escape branch threshold is
/// `LIMIT - qbpp - 1`), not in the LIMIT constant itself.
/// For 8-bit: LIMIT = 32. For 16-bit: LIMIT = 64.
fn computeLimit(bpp: u8, qbpp: u8) u8 {
    _ = qbpp;
    const high: u32 = @as(u32, bpp) + @max(@as(u32, 8), @as(u32, bpp));
    return @intCast(2 * high);
}

// ─────────────────────────────────────────────────────────────────
// Predictor (T.87 §A.4.1 — Median Edge Detection)
// ─────────────────────────────────────────────────────────────────

/// `Px = MED(Ra, Rb, Rc)`:
///   if Rc ≥ max(Ra, Rb) → min(Ra, Rb)  (likely vertical edge)
///   else if Rc ≤ min(Ra, Rb) → max(Ra, Rb)  (likely horizontal edge)
///   else → Ra + Rb - Rc  (smooth region; planar interpolation)
pub inline fn predictMed(ra: i32, rb: i32, rc: i32) i32 {
    const mn = @min(ra, rb);
    const mx = @max(ra, rb);
    if (rc >= mx) return mn;
    if (rc <= mn) return mx;
    return ra + rb - rc;
}

// ─────────────────────────────────────────────────────────────────
// Context quantization (T.87 §A.3.3 — Eq. A.10)
// ─────────────────────────────────────────────────────────────────

/// Quantize a signed gradient `d` into one of {-4..4} via thresholds
/// T1/T2/T3 and the near-lossless tolerance NEAR.
pub inline fn quantize(d: i32, t1: i32, t2: i32, t3: i32, near: i32) i32 {
    if (d <= -t3) return -4;
    if (d <= -t2) return -3;
    if (d <= -t1) return -2;
    if (d <  -near) return -1;
    if (d <=  near) return 0;
    if (d <   t1) return 1;
    if (d <   t2) return 2;
    if (d <   t3) return 3;
    return 4;
}

/// Result of context lookup: the canonical index and the sign that
/// must be applied to the prediction error to fold the negative
/// twin onto the same context.
pub const ContextLookup = struct {
    /// Canonical context index in [0, 364]. 0 reserved for (0,0,0)
    /// which triggers run mode; caller checks `q == 0` before
    /// invoking regular-mode helpers.
    q: usize,
    /// +1 or -1. Multiply the decoded error by `sign` to undo
    /// the canonicalization on the way out.
    sign: i8,
};

/// Map (Q1, Q2, Q3) → canonical context index, with sign
/// canonicalization. Matches charls's `compute_context_id` +
/// `bit_wise_sign` / `apply_sign` pair:
///
///   qs = (q1 * 9 + q2) * 9 + q3        // signed, in [-364, 364]
///   sign = qs < 0 ? -1 : +1
///   q = |qs|                            // in [0, 364]
///
/// `q == 0` iff (q1, q2, q3) == (0, 0, 0) iff run mode.
pub inline fn computeContextIndex(q1: i32, q2: i32, q3: i32) ContextLookup {
    const qs: i32 = (q1 * 9 + q2) * 9 + q3;
    if (qs >= 0) return .{ .q = @intCast(qs), .sign = 1 };
    return .{ .q = @intCast(-qs), .sign = -1 };
}

/// `applySign(value, sign)`: return `value` if sign=+1, `-value` if
/// sign=-1. Used to undo the sign canonicalization on decoded errors.
pub inline fn applySign(value: i32, sign: i8) i32 {
    return if (sign < 0) -value else value;
}

/// `computeReconstructed(predicted, error)`: `(predicted + error)
/// mod RANGE`, with RANGE = MAXVAL + 1. T.87 §A.5.
pub inline fn computeReconstructed(predicted: i32, errval: i32, MAXVAL: u32) i32 {
    var v: i32 = predicted + errval;
    const range: i32 = @intCast(MAXVAL + 1);
    if (v < 0) v += range;
    if (v > @as(i32, @intCast(MAXVAL))) v -= range;
    return v;
}

// ─────────────────────────────────────────────────────────────────
// Golomb-Rice parameter selection + decode (T.87 §A.5)
// ─────────────────────────────────────────────────────────────────

/// Compute k: the smallest k ≥ 0 such that `N << k ≥ A`. Equivalent
/// to `ceil(log2(A / N))` when both are positive. T.87 Eq. A.16.
pub inline fn computeK(N: u32, A: u32) u5 {
    var k: u5 = 0;
    while ((@as(u64, N) << k) < @as(u64, A)) : (k += 1) {
        if (k >= 31) return 31; // safety; should never happen for valid streams
    }
    return k;
}

/// Decode one Golomb-Rice code from `br` with parameter `k`. T.87
/// §A.5.3: read a unary part `high`; if it's < LIMIT - qbpp - 1,
/// read `k` low bits and combine. Otherwise we hit the escape: read
/// `qbpp` bits directly and add 1.
pub inline fn decodeGolombRice(br: *bitstream.BitReader, k: u5, limit: u8, qbpp: u8) u32 {
    const high = br.readUnary(limit);
    if (high < @as(u32, limit) - @as(u32, qbpp) - 1) {
        const low: u32 = if (k > 0) br.readBits(@intCast(k)) else 0;
        return (high << k) | low;
    }
    // Escape: large value coded directly. T.87 Eq. A.20.
    const escape: u32 = br.readBits(@intCast(qbpp));
    return escape + 1;
}

/// Map the unsigned `MErrval` (received over the wire) back to the
/// signed `Errval`. T.87 Eq. A.13 / §A.5.2 inverse:
///   Even MErrval → +MErrval/2
///   Odd MErrval  → -(MErrval+1)/2
pub inline fn mapMErrvalToErrval(merrval: u32) i32 {
    const m: i32 = @intCast(merrval);
    if (m & 1 == 0) return @divFloor(m, 2);
    return -@divFloor(m + 1, 2);
}

// ─────────────────────────────────────────────────────────────────
// State update (T.87 §A.6)
// ─────────────────────────────────────────────────────────────────

/// Apply the post-sample state update at the given context. Order
/// follows T.87 §A.6 / charls' `update_variables_and_bias`:
///
///   1. A += |errval|; B += errval * (2*NEAR+1).
///   2. If N == RESET, halve A, B, N (arithmetic shift on B so
///      negative values round toward -∞).
///   3. ++N.
///   4. Bias-correction adjustment of C[Q] based on the new B/N.
pub inline fn updateState(state: *ScanState, ci: usize, q: usize, errval: i32) void {
    const ctx = &state.contexts[ci][q];
    const near_factor: i32 = @intCast(2 * state.NEAR + 1);
    ctx.A +%= @intCast(@abs(errval));
    ctx.B +%= errval * near_factor;
    if (ctx.N == state.RESET) {
        ctx.A >>= 1;
        ctx.B = ctx.B >> 1; // arithmetic shift — preserves sign
        ctx.N >>= 1;
    }
    ctx.N +%= 1;
    biasCorrectAfterUpdate(ctx);
}

/// T.87 §A.6.1 — applied AFTER A/B accumulation and the N++ step.
/// Walks C[Q] toward zero so the bias-corrected prediction trends
/// toward the true sample value.
inline fn biasCorrectAfterUpdate(ctx: *ContextState) void {
    const n_i: i32 = @intCast(ctx.N);
    if (ctx.B + n_i <= 0) {
        ctx.B +%= n_i;
        if (ctx.B <= -n_i) ctx.B = -n_i + 1;
        if (ctx.C > -128) ctx.C -= 1;
    } else if (ctx.B > 0) {
        ctx.B -%= n_i;
        if (ctx.B > 0) ctx.B = 0;
        if (ctx.C < 127) ctx.C += 1;
    }
}

/// Legacy name kept for the §1b test that calls `updateBiasCorrection`
/// directly. The new code path (`updateState`) doesn't use it.
pub inline fn updateBiasCorrection(ctx: *ContextState, errval: i32) void {
    ctx.B +%= errval;
    biasCorrectAfterUpdate(ctx);
}

// ─────────────────────────────────────────────────────────────────
// Run mode (T.87 §A.7)
// ─────────────────────────────────────────────────────────────────

/// Run-length code table (T.87 §A.2.1, Table A.16 / charls's `J`).
/// Indexed by `run_index` ∈ [0, 31]. Each entry is the number of
/// bits in the residual run-length code at that index, which also
/// equals log2 of the run-step.
pub const J_TABLE = [_]u8{
    0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3,
    4, 4, 5, 5, 6, 6, 7, 7, 8, 9, 10, 11, 12, 13, 14, 15,
};

/// Run-interruption context (T.87 §A.7.2). Two per component
/// (RItype 0 and 1), stored in `ScanState.run_contexts[ci][0..2]`.
pub const RunContextState = struct {
    A: u32 = 4,
    /// Negative-error count, for the k=0 sign-correction trick.
    Nn: u32 = 0,
    N: u32 = 1,
};

/// k for a run-mode interruption context (T.87 §A.7.4 / charls's
/// `context_run_mode::get_golomb_code`).
pub inline fn runModeGetK(rc: *const RunContextState, ri_type: u8) u5 {
    const temp: u32 = rc.A + (rc.N >> 1) * @as(u32, ri_type);
    var n_test: u32 = rc.N;
    var k: u5 = 0;
    while (n_test < temp and k < 31) : (k += 1) n_test <<= 1;
    return k;
}

/// Recover the signed Errval from the wire-format `e_mapped` value
/// for a run-interruption sample (charls's
/// `context_run_mode::compute_error_value`).
pub inline fn runModeComputeError(
    rc: *const RunContextState,
    e_mapped: u32,
    k: u5,
    ri_type: u8,
) i32 {
    const temp: u32 = e_mapped + ri_type;
    const map_bit: u1 = @intCast(temp & 1);
    const abs_err: i32 = @intCast(@divFloor(temp + map_bit, 2));
    // `(k != 0 || (2*Nn >= N)) == map` → return -abs_err else abs_err.
    const condition: bool = (k != 0) or (2 * rc.Nn >= rc.N);
    if (condition == (map_bit == 1)) return -abs_err;
    return abs_err;
}

/// Update run-interruption context after a sample (T.87 §A.7.5).
pub inline fn runModeUpdate(
    rc: *RunContextState,
    errval: i32,
    e_mapped: u32,
    ri_type: u8,
    reset_threshold: u32,
) void {
    if (errval < 0) rc.Nn +%= 1;
    rc.A +%= @intCast(@divFloor(@as(i32, @intCast(e_mapped)) + 1 - @as(i32, ri_type), 2));
    if (rc.N == reset_threshold) {
        rc.A >>= 1;
        rc.N >>= 1;
        rc.Nn >>= 1;
    }
    rc.N +%= 1;
}

// ── Inline tests ─────────────────────────────────────────────────

test "predictMed: vertical edge (Rc >= max → min)" {
    try std.testing.expectEqual(@as(i32, 5), predictMed(5, 10, 10));
    try std.testing.expectEqual(@as(i32, 5), predictMed(5, 10, 20));
}

test "predictMed: horizontal edge (Rc <= min → max)" {
    try std.testing.expectEqual(@as(i32, 10), predictMed(5, 10, 5));
    try std.testing.expectEqual(@as(i32, 10), predictMed(5, 10, 0));
}

test "predictMed: smooth region → Ra + Rb - Rc" {
    // Ra=10, Rb=20, Rc=15 → min=10, max=20. Rc=15 strictly between
    // → 10 + 20 - 15 = 15.
    try std.testing.expectEqual(@as(i32, 15), predictMed(10, 20, 15));
}

test "quantize: standard 8-bit thresholds {3,7,21}" {
    // T1=3, T2=7, T3=21, NEAR=0.
    try std.testing.expectEqual(@as(i32, 0), quantize(0, 3, 7, 21, 0));
    try std.testing.expectEqual(@as(i32, 1), quantize(1, 3, 7, 21, 0));
    try std.testing.expectEqual(@as(i32, 1), quantize(2, 3, 7, 21, 0));
    try std.testing.expectEqual(@as(i32, 2), quantize(3, 3, 7, 21, 0));
    try std.testing.expectEqual(@as(i32, 2), quantize(6, 3, 7, 21, 0));
    try std.testing.expectEqual(@as(i32, 3), quantize(7, 3, 7, 21, 0));
    try std.testing.expectEqual(@as(i32, 3), quantize(20, 3, 7, 21, 0));
    try std.testing.expectEqual(@as(i32, 4), quantize(21, 3, 7, 21, 0));
    // Negative side.
    try std.testing.expectEqual(@as(i32, -1), quantize(-1, 3, 7, 21, 0));
    try std.testing.expectEqual(@as(i32, -2), quantize(-3, 3, 7, 21, 0));
    try std.testing.expectEqual(@as(i32, -3), quantize(-7, 3, 7, 21, 0));
    try std.testing.expectEqual(@as(i32, -4), quantize(-21, 3, 7, 21, 0));
}

test "computeContextIndex: canonical positive tuple" {
    // qs = (1*9 + 0)*9 + 0 = 81. Positive → sign=+1, q=81.
    const r = computeContextIndex(1, 0, 0);
    try std.testing.expectEqual(@as(i8, 1), r.sign);
    try std.testing.expectEqual(@as(usize, 81), r.q);
}

test "computeContextIndex: negative tuple folds to positive index" {
    // qs = -81. q=|qs|=81, sign=-1.
    const r = computeContextIndex(-1, 0, 0);
    try std.testing.expectEqual(@as(i8, -1), r.sign);
    try std.testing.expectEqual(@as(usize, 81), r.q);
}

test "computeContextIndex: run-mode trigger (0,0,0) returns q=0" {
    const r = computeContextIndex(0, 0, 0);
    try std.testing.expectEqual(@as(i8, 1), r.sign);
    try std.testing.expectEqual(@as(usize, 0), r.q);
}

test "applySign: passthrough vs negate" {
    try std.testing.expectEqual(@as(i32, 5), applySign(5, 1));
    try std.testing.expectEqual(@as(i32, -5), applySign(5, -1));
    try std.testing.expectEqual(@as(i32, 5), applySign(-5, -1));
}

test "computeReconstructed: in-range / wrap-low / wrap-high" {
    // RANGE = 256.
    try std.testing.expectEqual(@as(i32, 100), computeReconstructed(80, 20, 255));
    // -1 wraps to 255.
    try std.testing.expectEqual(@as(i32, 255), computeReconstructed(0, -1, 255));
    // 256 wraps to 0.
    try std.testing.expectEqual(@as(i32, 0), computeReconstructed(255, 1, 255));
}

test "computeK: simple cases" {
    // N=1, A=1 → 1 << 0 = 1 >= 1 → k=0.
    try std.testing.expectEqual(@as(u5, 0), computeK(1, 1));
    // N=1, A=2 → k=1 (1<<1=2>=2).
    try std.testing.expectEqual(@as(u5, 1), computeK(1, 2));
    // N=1, A=8 → k=3.
    try std.testing.expectEqual(@as(u5, 3), computeK(1, 8));
    // N=4, A=16 → k=2 (4<<2=16>=16).
    try std.testing.expectEqual(@as(u5, 2), computeK(4, 16));
}

test "mapMErrvalToErrval: round-trip via known mapping" {
    // T.87 Eq. A.13:
    //   MErrval = 2*Errval      if Errval >= 0
    //   MErrval = -2*Errval - 1 if Errval < 0
    // Inverse: even → +n/2, odd → -(n+1)/2.
    try std.testing.expectEqual(@as(i32,  0), mapMErrvalToErrval(0));
    try std.testing.expectEqual(@as(i32, -1), mapMErrvalToErrval(1));
    try std.testing.expectEqual(@as(i32,  1), mapMErrvalToErrval(2));
    try std.testing.expectEqual(@as(i32, -2), mapMErrvalToErrval(3));
    try std.testing.expectEqual(@as(i32,  2), mapMErrvalToErrval(4));
}

test "decodeGolombRice: k=0 simple unary code" {
    // JPEG-LS unary: n zeros then a 1. k=0 → result = high alone.
    // Stream 0b001_00000 → 2 zeros then a 1 → high = 2.
    const data = [_]u8{0b0010_0000};
    var br = bitstream.BitReader.init(&data);
    try std.testing.expectEqual(@as(u32, 2), decodeGolombRice(&br, 0, 16, 8));
}

test "decodeGolombRice: k=2 mixed unary+binary" {
    // Stream 0b01_11_0000 → unary = 1 (one zero then a 1), low = 0b11 = 3
    // → result = (1 << 2) | 3 = 7.
    const data = [_]u8{0b0111_0000};
    var br = bitstream.BitReader.init(&data);
    try std.testing.expectEqual(@as(u32, 7), decodeGolombRice(&br, 2, 16, 8));
}

test "ScanState.reset: 8-bit lossless defaults" {
    var s: ScanState = undefined;
    s.reset(8, 0);
    try std.testing.expectEqual(@as(u32, 255), s.MAXVAL);
    try std.testing.expectEqual(@as(u32, 0), s.NEAR);
    try std.testing.expectEqual(@as(u32, 3), s.T1);
    try std.testing.expectEqual(@as(u32, 7), s.T2);
    try std.testing.expectEqual(@as(u32, 21), s.T3);
    try std.testing.expectEqual(@as(u32, 64), s.RESET);
    try std.testing.expectEqual(@as(u8, 8), s.qbpp);
    // charls's compute_limit_parameter: 2*(8+8) = 32.
    try std.testing.expectEqual(@as(u8, 32), s.LIMIT);
    // Initial context: A=max(2, (RANGE+32)>>6) = max(2, (256+32)>>6) = max(2, 4) = 4.
    try std.testing.expectEqual(@as(u32, 4), s.contexts[0][0].A);
    try std.testing.expectEqual(@as(u32, 1), s.contexts[0][0].N);
}

test "updateBiasCorrection: positive bias decrements toward zero" {
    var ctx = ContextState{ .A = 4, .B = 0, .C = 0, .N = 1 };
    // Errval = +1, N = 1 → B becomes +1 > 0 → C += 1, B -= N = 0.
    updateBiasCorrection(&ctx, 1);
    try std.testing.expectEqual(@as(i8, 1), ctx.C);
    try std.testing.expectEqual(@as(i32, 0), ctx.B);
}

test "updateBiasCorrection: large negative bias decrements C" {
    var ctx = ContextState{ .A = 4, .B = 0, .C = 0, .N = 4 };
    // Errval = -5, N = 4 → B becomes -5 ≤ -N → C -= 1, B += N = -1.
    updateBiasCorrection(&ctx, -5);
    try std.testing.expectEqual(@as(i8, -1), ctx.C);
    try std.testing.expectEqual(@as(i32, -1), ctx.B);
}
