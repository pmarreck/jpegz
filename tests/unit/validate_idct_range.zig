//! IDCT range (owner ruling 2026-11-28): exact arithmetic, then a clamp to
//! 0..2^P-1 (T.81 A.3.1). A legal file can dequantize to coefficients whose
//! IDCT lies far outside the sample range. jpegz must neither wrap there
//! (libjpeg-turbo's C islow does, through its masked range table) nor call
//! the file damaged.
//!
//! The oracle is independent of jpegz's decode: libjpeg-turbo's entropy
//! decode supplies the coefficients only, the test dequantizes them with the
//! file's own DQT, and a double-precision T.81 A.3.3 IDCT gives the exact
//! samples.

const std = @import("std");
const jpegz = @import("jpegz");

/// The libjpeg-turbo oracle is linked into native test builds only; cross
/// builds compile these tests without it and skip them.
const oracle = @hasField(jpegz.internal.WrapperCoefDump, "coefs");

const zigzag = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10, 17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
};

/// T.81 A.3.3 in double precision, level-shifted, not clamped.
fn referenceIdct(coef: [64]f64, level_shift: f64) [64]f64 {
    var out: [64]f64 = undefined;
    for (0..8) |y| for (0..8) |x| {
        var sum: f64 = 0;
        for (0..8) |v| for (0..8) |u| {
            const cu: f64 = if (u == 0) std.math.sqrt1_2 else 1;
            const cv: f64 = if (v == 0) std.math.sqrt1_2 else 1;
            const fx = @as(f64, @floatFromInt(2 * x + 1)) * @as(f64, @floatFromInt(u)) * std.math.pi / 16.0;
            const fy = @as(f64, @floatFromInt(2 * y + 1)) * @as(f64, @floatFromInt(v)) * std.math.pi / 16.0;
            sum += cu * cv * coef[v * 8 + u] * @cos(fx) * @cos(fy);
        };
        out[y * 8 + x] = sum / 4.0 + level_shift;
    };
    return out;
}

/// The one quantization table of a single-component test file, in natural
/// order (the DQT stores it in zig-zag order).
fn naturalQuant(data: []const u8) [64]u32 {
    const at = std.mem.indexOf(u8, data, &.{ 0xFF, 0xDB }).?;
    const wide = data[at + 4] >> 4 != 0;
    var q: [64]u32 = undefined;
    for (0..64) |k| {
        const v: u32 = if (wide) (@as(u32, data[at + 5 + 2 * k]) << 8) | data[at + 6 + 2 * k] else data[at + 5 + k];
        q[zigzag[k]] = v;
    }
    return q;
}

/// Decode a one-block, one-component file with jpegz and check every sample
/// against the oracle. Where the exact value lies beyond the range by more
/// than islow's fixed-point error (which grows with coefficient magnitude),
/// the sample must equal the clamp bound; elsewhere it must be within that
/// error. Returns how many samples were checked at a clamp bound.
fn expectExactThenClamped(data: []const u8, precision: u8) !usize {
    const allocator = std.testing.allocator;
    var dump = try jpegz.internal.wrapperDumpCoefs(allocator, data);
    defer dump.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 1), dump.num_components);
    try std.testing.expectEqual(@as(usize, 64), dump.coefs[0].len);
    const q = naturalQuant(data);
    var coef: [64]f64 = undefined;
    var magnitude: f64 = 0;
    for (0..64) |i| {
        coef[i] = @as(f64, @floatFromInt(dump.coefs[0][i])) * @as(f64, @floatFromInt(q[i]));
        magnitude += @abs(coef[i]);
    }
    const max: f64 = @floatFromInt((@as(u32, 1) << @intCast(precision)) - 1);
    const ref = referenceIdct(coef, (max + 1) / 2);
    // 13-bit fixed-point constants: well under 2^-10 of the coefficient mass,
    // plus rounding.
    const err = 2 + magnitude / 1024;

    var image = try jpegz.decode(allocator, data);
    defer image.deinit(allocator);
    try std.testing.expectEqual(@as(u8, precision), image.bits_per_sample);
    var clamped: usize = 0;
    for (0..64) |i| {
        const y = i / 8;
        const x = i % 8;
        if (x >= image.width or y >= image.height) continue;
        const idx = y * image.width + x;
        const got: f64 = @floatFromInt(if (precision > 8) image.pixelsU16()[idx] else image.pixels[idx]);
        if (ref[i] > max + err) {
            try std.testing.expectEqual(max, got);
            clamped += 1;
        } else if (ref[i] < -err) {
            try std.testing.expectEqual(@as(f64, 0), got);
            clamped += 1;
        } else {
            try std.testing.expect(@abs(got - std.math.clamp(ref[i], 0, max)) <= err);
        }
    }
    return clamped;
}

fn expectNoFail(data: []const u8) !void {
    var report = try jpegz.validate(std.testing.allocator, data);
    defer report.deinit(std.testing.allocator);
    for (report.findings.items) |f| {
        try std.testing.expect(f.code != .dct_coefficient_overflow);
        try std.testing.expect(f.severity != .fail);
    }
}

test "a legal 8-bit file whose IDCT leaves the range decodes exactly, then clamped, with no finding" {
    // Validate's DNG crasher: a category-10 amplitude of 1023 (legal at 8
    // bits) times a quantizer of 255 (legal). jpegz's 32-bit IDCT wrapped
    // here and reported dct_coefficient_overflow on a well-formed file.
    if (comptime !oracle) return error.SkipZigTest else {
        const data = @embedFile("fixtures/overflow_ac_8x8.jpg");
        try expectNoFail(data);
        try std.testing.expect(try expectExactThenClamped(data, 8) > 0);
    }
}

test "legal 12-bit quantizers that scale coefficients past i16 decode exactly, then clamped" {
    if (comptime !oracle) return error.SkipZigTest else {
        const gray12 = @embedFile("fixtures/progressive_8x8_gray12.jpg");
        const dqt_values = 0x19; // the 8-bit DQT body (Pq=0, Tq=0)
        try std.testing.expectEqual(@as(u8, 0x00), gray12[0x18]);
        var clamped: usize = 0;
        // Single quantizer entries raised after encoding (found by mutation;
        // both panicked before fa289eb), then every entry at the 8-bit maximum.
        for ([_][2]u8{ .{ 0x21 - dqt_values, 0xED }, .{ 0x1B - dqt_values, 0xAD } }) |edit| {
            var data = gray12.*;
            data[dqt_values + edit[0]] = edit[1];
            try expectNoFail(&data);
            clamped += try expectExactThenClamped(&data, 12);
        }
        var data = gray12.*;
        @memset(data[dqt_values..][0..64], 0xFF);
        try expectNoFail(&data);
        clamped += try expectExactThenClamped(&data, 12);
        // The cases must reach the clamp, or they would not test it.
        try std.testing.expect(clamped > 0);
    }
}
