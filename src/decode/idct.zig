//! Inverse 8×8 DCT — direct mathematical implementation per T.81
//! Annex A (the inverse of Equation A.3.3). Slow (~4096 multiplies
//! per block) but obviously correct, useful as the v1 cleanroom IDCT
//! and as an oracle for later-day fast IDCTs (Loeffler / AAN).
//!
//! Output ordering:
//!   - Input: 8×8 block in zig-zag-unsorted natural order, signed
//!     coefficients (DCT post-dequantization). Indexed [v][u]
//!     where v = vertical freq, u = horizontal freq.
//!   - Output: 8×8 spatial block, level-shifted to 0..255, indexed
//!     [y][x]. Per T.81 §A.3.1, baseline JPEG samples are unsigned
//!     8-bit so we add 128 (the "level shift") before clamping.
//!
//! Reference: ITU-T T.81 §A.3.3 (IDCT), §A.3.1 (level shift).

const std = @import("std");

const N: usize = 8;
const PI: f64 = 3.141592653589793;

/// IDCT cosine basis: cos((2x+1) * u * π / 16). Precomputed at
/// comptime so the hot path is just multiply-accumulate.
const COS_TABLE: [N][N]f64 = blk: {
    @setEvalBranchQuota(10000);
    var t: [N][N]f64 = undefined;
    var u: usize = 0;
    while (u < N) : (u += 1) {
        var x: usize = 0;
        while (x < N) : (x += 1) {
            t[u][x] = @cos(@as(f64, @floatFromInt(2 * x + 1)) *
                @as(f64, @floatFromInt(u)) * PI / 16.0);
        }
    }
    break :blk t;
};

/// Per-axis normalization factor: 1/√2 for u==0, 1 otherwise.
const NORM: [N]f64 = blk: {
    @setEvalBranchQuota(10000);
    var n: [N]f64 = undefined;
    n[0] = 1.0 / @sqrt(2.0);
    var i: usize = 1;
    while (i < N) : (i += 1) n[i] = 1.0;
    break :blk n;
};

/// Run the inverse 8×8 DCT on `coeffs` and write the spatial samples
/// into `out`. Output is level-shifted by +128 and clamped to 0..255.
///
/// `coeffs[v * 8 + u]` = the (u, v) frequency coefficient.
/// `out[y * 8 + x]` = the (x, y) spatial sample.
pub fn idct8x8(coeffs: *const [64]i16, out: *[64]u8) void {
    var y: usize = 0;
    while (y < N) : (y += 1) {
        var x: usize = 0;
        while (x < N) : (x += 1) {
            var sum: f64 = 0;
            var v: usize = 0;
            while (v < N) : (v += 1) {
                var u: usize = 0;
                while (u < N) : (u += 1) {
                    sum += NORM[u] * NORM[v] *
                        @as(f64, @floatFromInt(coeffs[v * N + u])) *
                        COS_TABLE[u][x] * COS_TABLE[v][y];
                }
            }
            // T.81 §A.3.3: full inverse-DCT formula has a 1/4 factor
            // (combines 2/N from each axis). Then level-shift +128
            // and clamp.
            const sample = sum * 0.25 + 128.0;
            const rounded: i32 = @intFromFloat(@round(sample));
            const clamped: u8 = if (rounded < 0) 0
                else if (rounded > 255) 255
                else @intCast(rounded);
            out[y * N + x] = clamped;
        }
    }
}

// ── Tests ────────────────────────────────────────────────────

test "idct8x8 of all-zero coefficients yields uniform 128" {
    const coeffs = [_]i16{0} ** 64;
    var out: [64]u8 = undefined;
    idct8x8(&coeffs, &out);
    for (out) |s| try std.testing.expectEqual(@as(u8, 128), s);
}

test "idct8x8 of DC-only with positive amplitude yields uniform brighter" {
    var coeffs = [_]i16{0} ** 64;
    coeffs[0] = 256; // DC coefficient: shifts the mean up
    var out: [64]u8 = undefined;
    idct8x8(&coeffs, &out);
    // Per the formula: output = NORM[0]*NORM[0] * coeff * 1 * 1 * 0.25 + 128
    //                = (1/√2)² * 256 * 0.25 + 128 = 0.5 * 64 + 128 = 160
    for (out) |s| try std.testing.expectEqual(@as(u8, 160), s);
}

test "idct8x8 of DC-only with negative amplitude yields uniform darker" {
    var coeffs = [_]i16{0} ** 64;
    coeffs[0] = -256;
    var out: [64]u8 = undefined;
    idct8x8(&coeffs, &out);
    // -256 → 128 - 32 = 96
    for (out) |s| try std.testing.expectEqual(@as(u8, 96), s);
}

test "idct8x8 clamps to 0..255" {
    var coeffs = [_]i16{0} ** 64;
    coeffs[0] = 4096; // way too large; output would overflow without clamp
    var out: [64]u8 = undefined;
    idct8x8(&coeffs, &out);
    for (out) |s| try std.testing.expectEqual(@as(u8, 255), s);

    coeffs[0] = -4096;
    idct8x8(&coeffs, &out);
    for (out) |s| try std.testing.expectEqual(@as(u8, 0), s);
}
