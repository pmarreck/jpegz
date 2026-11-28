//! Tests for idct.zig (kept apart to keep that file small).

const std = @import("std");
const idct = @import("idct.zig");
const idct8x8 = idct.idct8x8;
const idct8x8Generic = idct.idct8x8Generic;
const idct8x8_fpd = idct.idct8x8_fpd;
const Sample = idct.Sample;

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

test "out-of-range IDCT output is the exact value, clamped, at every precision" {
    // Owner ruling (2026-11-28): no wraparound, then a clamp to 0..2^P-1.
    // DC-only blocks: the exact sample is DC/8 plus the level shift.
    const Case = struct { dc: i32, p8: u8, p12: u16 };
    const cases = [_]Case{
        .{ .dc = 24000, .p8 = 255, .p12 = 4095 }, // 3000 + shift
        .{ .dc = -24000, .p8 = 0, .p12 = 0 },
        // libjpeg-turbo's C table wraps these onto the center (2048 at 12
        // bits) or onto 0; the exact value is far above or below the range.
        .{ .dc = 1 << 18, .p8 = 255, .p12 = 4095 },
        .{ .dc = -(1 << 18), .p8 = 0, .p12 = 0 },
        .{ .dc = 72000, .p8 = 255, .p12 = 4095 },
        .{ .dc = 2_000_000_000, .p8 = 255, .p12 = 4095 },
        .{ .dc = -2_000_000_000, .p8 = 0, .p12 = 0 },
    };
    for (cases) |c| {
        var coeffs = [_]i32{0} ** 64;
        coeffs[0] = c.dc;
        var out8: [64]u8 = undefined;
        idct8x8Generic(8, &coeffs, &out8);
        for (out8) |s| try std.testing.expectEqual(c.p8, s);
        var out12: [64]u16 = undefined;
        idct8x8Generic(12, &coeffs, &out12);
        for (out12) |s| try std.testing.expectEqual(c.p12, s);
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

/// T.81 A.3.3 in double precision, level-shifted, not clamped.
fn referenceIdct(coeffs: *const [64]i32, level_shift: f64) [64]f64 {
    var out: [64]f64 = undefined;
    for (0..8) |y| for (0..8) |x| {
        var sum: f64 = 0;
        for (0..8) |v| for (0..8) |u| {
            const cu: f64 = if (u == 0) std.math.sqrt1_2 else 1;
            const cv: f64 = if (v == 0) std.math.sqrt1_2 else 1;
            const fx = @as(f64, @floatFromInt(2 * x + 1)) * @as(f64, @floatFromInt(u)) * std.math.pi / 16.0;
            const fy = @as(f64, @floatFromInt(2 * y + 1)) * @as(f64, @floatFromInt(v)) * std.math.pi / 16.0;
            sum += cu * cv * @as(f64, @floatFromInt(coeffs[v * 8 + u])) * @cos(fx) * @cos(fy);
        };
        out[y * 8 + x] = sum / 4.0 + level_shift;
    };
    return out;
}

test "idct computes absurd coefficients without wrapping, then clamps" {
    // Malformed streams in lenient decode can feed dequantized coefficients
    // near the i32 limits (fuzz crasher #9 hit this). With i32 intermediates
    // the 8-bit IDCT wrapped; it must compute the exact islow value and clamp,
    // with no overflow. Where the exact value lies beyond the range by more
    // than islow's fixed-point error (which grows with coefficient mass), the
    // sample must be the clamp bound.
    var coeffs = [_]i32{0} ** 64;
    coeffs[0] = 2_000_000_000;
    coeffs[1] = -1_500_000_000;
    coeffs[9] = 1_000_000_000;
    var mass: f64 = 0;
    for (coeffs) |c| mass += @abs(@as(f64, @floatFromInt(c)));
    const err = 2 + mass / 1024;
    inline for (.{ 8, 12 }) |P| {
        const max: f64 = (1 << P) - 1;
        var out: [64]Sample(P) = undefined;
        idct8x8Generic(P, &coeffs, &out);
        const ref = referenceIdct(&coeffs, (max + 1) / 2);
        var clamped: usize = 0;
        for (out, ref) |s, r| {
            const got: f64 = @floatFromInt(s);
            if (r > max + err) {
                try std.testing.expectEqual(max, got);
                clamped += 1;
            } else if (r < -err) {
                try std.testing.expectEqual(@as(f64, 0), got);
                clamped += 1;
            }
        }
        // Nearly every sample of this block is far outside the range.
        try std.testing.expect(clamped >= 48);
    }
}

test "no IDCT intermediate overflows at the extremes of i32 input" {
    // `Accumulator` bounds every intermediate below 2^57 for |c| <= 2^31.
    // The arithmetic is checked, so in this safety-checked build a wrong
    // bound panics. Drive the bound with full-scale blocks: one constant
    // sign, alternating signs, the sign pattern that maximizes each output
    // sample, and seeded random signs, at both extreme magnitudes. Samples
    // the double-precision T.81 value puts beyond the range by more than
    // islow's fixed-point error must sit on the clamp bound.
    var patterns: [64 + 4 + 256][64]i8 = undefined;
    var n: usize = 0;
    for (0..64) |p| { // the basis-product signs at output sample p
        const x: f64 = @floatFromInt(p % 8);
        const y: f64 = @floatFromInt(p / 8);
        for (0..64) |k| {
            const u: f64 = @floatFromInt(k % 8);
            const v: f64 = @floatFromInt(k / 8);
            const w = @cos((2 * x + 1) * u * std.math.pi / 16.0) * @cos((2 * y + 1) * v * std.math.pi / 16.0);
            patterns[n][k] = if (w < 0) -1 else 1;
        }
        n += 1;
    }
    for ([_]i8{ 1, -1 }) |sgn| {
        patterns[n] = [_]i8{sgn} ** 64;
        n += 1;
        for (0..64) |k| patterns[n][k] = if ((k % 8 + k / 8) % 2 == 0) sgn else -sgn;
        n += 1;
    }
    var prng = std.Random.DefaultPrng.init(0x1dc7);
    const random = prng.random();
    while (n < patterns.len) : (n += 1) {
        for (&patterns[n]) |*s| s.* = if (random.boolean()) 1 else -1;
    }
    var clamped: usize = 0;
    for (patterns) |pattern| {
        for ([_]i64{ std.math.maxInt(i32), -@as(i64, std.math.minInt(i32)) }) |mag| {
            var coeffs: [64]i32 = undefined;
            for (&coeffs, pattern) |*c, s| c.* = @intCast(std.math.clamp(@as(i64, s) * mag, std.math.minInt(i32), std.math.maxInt(i32)));
            const err = 2 + 64.0 * @as(f64, @floatFromInt(mag)) / 1024.0;
            inline for (.{ 8, 12 }) |P| {
                const max: f64 = (1 << P) - 1;
                var out: [64]Sample(P) = undefined;
                idct8x8Generic(P, &coeffs, &out);
                const ref = referenceIdct(&coeffs, (max + 1) / 2);
                for (out, ref) |s, r| {
                    const got: f64 = @floatFromInt(s);
                    if (r > max + err) {
                        try std.testing.expectEqual(max, got);
                        clamped += 1;
                    } else if (r < -err) {
                        try std.testing.expectEqual(@as(f64, 0), got);
                        clamped += 1;
                    }
                }
            }
        }
    }
    // The blocks must reach the clamp, or the comparison checked nothing.
    try std.testing.expect(clamped > 1000);
}
