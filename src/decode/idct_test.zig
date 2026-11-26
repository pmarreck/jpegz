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
    _ = idct8x8(&coeffs, &out);
    for (out) |s| try std.testing.expectEqual(@as(u8, 128), s);
}

test "idct8x8 of DC-only with positive amplitude yields uniform brighter" {
    var coeffs = [_]i32{0} ** 64;
    coeffs[0] = 256; // DC coefficient: shifts the mean up
    var out: [64]u8 = undefined;
    _ = idct8x8(&coeffs, &out);
    // Per the formula: output = NORM[0]*NORM[0] * coeff * 1 * 1 * 0.25 + 128
    //                = (1/√2)² * 256 * 0.25 + 128 = 0.5 * 64 + 128 = 160
    for (out) |s| try std.testing.expectEqual(@as(u8, 160), s);
}

test "idct8x8 of DC-only with negative amplitude yields uniform darker" {
    var coeffs = [_]i32{0} ** 64;
    coeffs[0] = -256;
    var out: [64]u8 = undefined;
    _ = idct8x8(&coeffs, &out);
    // -256 → 128 - 32 = 96
    for (out) |s| try std.testing.expectEqual(@as(u8, 96), s);
}

test "idct8x8 clamps to 0..255" {
    var coeffs = [_]i32{0} ** 64;
    coeffs[0] = 4096; // way too large; output would overflow without clamp
    var out: [64]u8 = undefined;
    _ = idct8x8(&coeffs, &out);
    for (out) |s| try std.testing.expectEqual(@as(u8, 255), s);

    coeffs[0] = -4096;
    _ = idct8x8(&coeffs, &out);
    for (out) |s| try std.testing.expectEqual(@as(u8, 0), s);
}

// ── Precision-parametric tests (P ∈ {8, 12}) ────────────────────────

test "idct8x8Generic all-zero coefficients yield uniform level-shift at every P" {
    inline for (.{ 8, 12 }) |P| {
        const coeffs = [_]i32{0} ** 64;
        var out: [64]Sample(P) = undefined;
        _ = idct8x8Generic(P, &coeffs, &out);
        const expected: Sample(P) = 1 << (P - 1);
        for (out) |s| try std.testing.expectEqual(expected, s);
    }
}

test "idct8x8Generic DC-only positive amplitude yields uniform brighter at every P" {
    inline for (.{ 8, 12 }) |P| {
        var coeffs = [_]i32{0} ** 64;
        coeffs[0] = 256; // DC coefficient
        var out: [64]Sample(P) = undefined;
        _ = idct8x8Generic(P, &coeffs, &out);
        // Formula at every P: NORM[0]² × DC × 0.25 + level_shift
        //   = (1/√2)² × 256 × 0.25 + 2^(P-1)
        //   = 0.5 × 64 + 2^(P-1) = 32 + 2^(P-1)
        const expected: Sample(P) = (1 << (P - 1)) + 32;
        for (out) |s| try std.testing.expectEqual(expected, s);
    }
}

test "idct8x8Generic range-limits like libjpeg-turbo: a clamp at P=8, the masked table at P=12" {
    // DC-only blocks: d = DESCALE(DC << PASS1_BITS, PASS1_BITS + 3), and the
    // output is the level-shifted d range-limited.
    const Case = struct { dc: i32, p8: u8, p12: u16 };
    const cases = [_]Case{
        // Moderately out of range: both precisions saturate.
        .{ .dc = 24000, .p8 = 255, .p12 = 4095 }, // P=12: d = 3000
        .{ .dc = -24000, .p8 = 0, .p12 = 0 }, // P=12: d = -3000
        // Far out of range: libjpeg-turbo's C islow (P=12) indexes
        // range_limit[d & 16383], so d = 32768 wraps to the center value.
        .{ .dc = 1 << 18, .p8 = 255, .p12 = 2048 },
        .{ .dc = -(1 << 18), .p8 = 0, .p12 = 2048 },
        // d = 9000 lands in the table's undershoot zone: 0, not 4095.
        .{ .dc = 72000, .p8 = 255, .p12 = 0 },
    };
    for (cases) |c| {
        var coeffs = [_]i32{0} ** 64;
        coeffs[0] = c.dc;
        var out8: [64]u8 = undefined;
        _ = idct8x8Generic(8, &coeffs, &out8);
        for (out8) |s| try std.testing.expectEqual(c.p8, s);
        var out12: [64]u16 = undefined;
        _ = idct8x8Generic(12, &coeffs, &out12);
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
        _ = idct8x8(&coeffs, &a);
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

test "idct8x8 wraps (no panic) and reports overflow on out-of-range coefficients" {
    // Malformed streams (esp. lenient decode) can feed the islow IDCT
    // dequantized coefficients far outside the valid 8-bit range, overflowing
    // i32 intermediates. The C islow wraps silently; the Zig port must too
    // (no panic) and must report it so the decoder can emit
    // dct_coefficient_overflow. Fuzz crasher #9 (validate DNG) hit this.
    var coeffs = [_]i32{0} ** 64;
    coeffs[0] = 2_000_000_000; // absurd DC — overflows (c0+c4)<<13
    coeffs[1] = -1_500_000_000;
    coeffs[9] = 1_000_000_000;
    var out: [64]u8 = undefined;
    const overflowed = idct8x8(&coeffs, &out); // must NOT panic
    try std.testing.expect(overflowed);
}

test "idct8x8 reports NO overflow on valid in-range coefficients" {
    // Realistic small block must not false-positive the overflow flag.
    var coeffs = [_]i32{0} ** 64;
    coeffs[0] = 320;
    coeffs[1] = -48;
    coeffs[8] = 24;
    var out: [64]u8 = undefined;
    const overflowed = idct8x8(&coeffs, &out);
    try std.testing.expect(!overflowed);
}
