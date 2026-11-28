//! Helpers shared by the decode test files (part 1 of 2).

const std = @import("std");
const jpegz = @import("jpegz");
const h2 = @import("decode_helpers_2.zig");
const fixture_baseline_16x16_rgb12_444 = h2.fixture_baseline_16x16_rgb12_444;
const fixture_baseline_16x16_rgb12_420 = h2.fixture_baseline_16x16_rgb12_420;
const fixture_baseline_16x16_rgb12_422 = h2.fixture_baseline_16x16_rgb12_422;
const fixture_baseline_16x16_rgb12_440 = h2.fixture_baseline_16x16_rgb12_440;
const fixture_jpegls_4x4_rgb8_ilv1 = h2.fixture_jpegls_4x4_rgb8_ilv1;
const fixture_baseline_16x16_rgb_marked = h2.fixture_baseline_16x16_rgb_marked;
const fixture_overflow_ac_8x8 = h2.fixture_overflow_ac_8x8;
const fixture_seq_16x16_3scan = h2.fixture_seq_16x16_3scan;
const fixture_seq_17x13_420_y_cbcr_rst = h2.fixture_seq_17x13_420_y_cbcr_rst;
const fixture_seq_23x19_422_rev_rst = h2.fixture_seq_23x19_422_rev_rst;
const fixture_seq_23x19_rgb12_420_3scan = h2.fixture_seq_23x19_rgb12_420_3scan;
const fixture_fuzz_progressive_ac_refine_al15 = h2.fixture_fuzz_progressive_ac_refine_al15;
const ProgScan = h2.ProgScan;
const appendSegment = h2.appendSegment;
const buildProgressiveGray = h2.buildProgressiveGray;
const dc_zero = h2.dc_zero;
const ProgCase = h2.ProgCase;
const progressive_range_cases = h2.progressive_range_cases;
const FrameFixture = h2.FrameFixture;
const frameFixture = h2.frameFixture;
const frame_fixtures = h2.frame_fixtures;
const jlsFirstScanEnd = h2.jlsFirstScanEnd;
const jlsWithDnl = h2.jlsWithDnl;
const jlsWithPt = h2.jlsWithPt;
const ptSample = h2.ptSample;

/// 2×2 RGB baseline JPEG (Y'CbCr internally, decoded to RGB by libjpeg-turbo).
/// Generated via `cjpeg -quality 90 -baseline` from a 2×2 PPM with
/// red/green/blue/white pixels. Roughly 690 bytes.
pub const fixture_baseline_2x2_rgb = @embedFile("fixtures/baseline_2x2_rgb.jpg");

pub fn decodeAllocationControl(allocator: std.mem.Allocator, data: []const u8, channels: u8) !void {
	var image = try jpegz.internal.cleanroomDecode(allocator, data);
	defer image.deinit(allocator);
	try std.testing.expectEqual(channels, image.channels);
}

/// 8×8 RGB progressive JPEG (SOF2). libjpeg-turbo decodes both
/// baseline and progressive through the same `decode` entry point —
/// this test confirms our wrapper doesn't accidentally restrict by SOF.
pub const fixture_progressive_8x8 = @embedFile("fixtures/progressive_8x8_rgb.jpg");

/// 4×4 8-bit grayscale lossless (SOF3) JPEG (predictor=1, all 0x80).
/// libjpeg-turbo 3.1+ supports lossless decoding via the same
/// `jpeg_read_scanlines` API used for SOF0/SOF1/SOF2 — for 8-bit
/// precision. 12/16-bit lossless requires `jpeg12_/jpeg16_` APIs and
/// is the M1.4b follow-up.
pub const fixture_lossless_4x4_gray8 = @embedFile("fixtures/lossless_4x4_gray8.jpg");

/// 4×4 12-bit grayscale lossless. precision 12, all 0x800.
pub const fixture_lossless_4x4_gray12 = @embedFile("fixtures/lossless_4x4_gray12.jpg");

/// 4×4 12-bit grayscale baseline DCT (SOF1 extended sequential, NOT
/// SOF0 baseline — T.81 SOF0 is 8-bit-only). cjpeg `-baseline
/// -precision 12` emits this. Goes through libjpeg-turbo's
/// `jpeg12_read_scanlines` path via M1.4b's precision-range
/// dispatch in the wrapper. Cleanroom (SOF0-only) returns
/// NotImplemented and falls back.
pub const fixture_baseline_4x4_gray12_dct = @embedFile("fixtures/baseline_4x4_gray12_dct.jpg");

/// 4×4 14-bit grayscale lossless (precision 14, all 0x2000). DNG raw
/// commonly uses 14-bit precision (Sony/Nikon/Fuji sensors); jpegz's
/// libjpeg-turbo path routes precision 13..16 through jpeg16_*. M1.4b
/// originally checked precision == exactly 16; tiffz's DNG handoff
/// flagged 14-bit as in-scope, so the precision check now accepts
/// any 1..16 and routes by range.
pub const fixture_lossless_4x4_gray14 = @embedFile("fixtures/lossless_4x4_gray14.jpg");

// ─────────────────────────────────────────────────────────────────────
// Tier 1 — wrapper coverage verification (per Peter, 2026-05-06).
// Each of these fixtures is a real-world JPEG variant our wrapper
// claims to handle but never had explicit test coverage. They
// double as Phase 2 oracle test cases (cleanroom impl must produce
// byte-equal output to libjpeg-turbo for these inputs).
// ─────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────
// M2.1 cleanroom — 3-component RGB without subsampling (4:4:4).
// First fixture exercising the multi-component MCU loop in cleanroom.
// ─────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────
// M2.1c — real-world failure-mode reproducers. Each fixture below
// reproduces a class of CLEAN-ERR seen in the cleanroom-diff run
// against Peter's 4,125-JPEG corpus. Synthetic stand-ins generated
// via cjpeg with the matching encoder flags (per CLAUDE.md: do not
// commit Peter's actual corpus files; reproduce shape with cjpeg).
// ─────────────────────────────────────────────────────────────────────

/// 128×128 RGB baseline 4:4:4 with restart markers every 4 MCUs.
/// 256 MCUs total → 63 RSTm markers cycling 0..7. Reproduces the
/// `InvalidMarker` failure mode hit by petethumb128x128.jpg in the
/// real corpus. cjpeg `-sample 1x1 -restart 4B`.
pub const fixture_baseline_128x128_dri4 = @embedFile("fixtures/baseline_128x128_dri4.jpg");

/// 4×4 RGB baseline with all components at 1×1 sampling (no subsampling).
/// cjpeg's default produces 4:2:0; this fixture used `-sample 1x1`.
pub const fixture_baseline_4x4_rgb_444 = @embedFile("fixtures/baseline_4x4_rgb_444.jpg");

/// T1.1: arithmetic-coded baseline (SOF9). Patents expired in early
/// 2000s; libjpeg-turbo decodes it via the same scanline path.
pub const fixture_baseline_4x4_arithmetic = @embedFile("fixtures/baseline_4x4_arithmetic.jpg");

/// T1.2: baseline JPEG with restart markers (DRI=2 every 2 MCUs).
/// Tests entropy-stream RST handling.
pub const fixture_baseline_16x16_restart = @embedFile("fixtures/baseline_16x16_restart.jpg");

/// T1.3: 4×4 CMYK JPEG (4 components, Adobe APP14 colorspace = CMYK).
pub const fixture_baseline_4x4_cmyk = @embedFile("fixtures/baseline_4x4_cmyk.jpg");

// 16×16 YCCK (Adobe APP14 ColorTransform=2) with SUBSAMPLED chroma:
// comp0/comp3 (Y, K) = 2h2v, comp1/comp2 (Cb, Cr) = 1h1v. Quarter-size
// chroma planes are what the 4-component assembler over-read before the
// 2026-05-31 fix (validate_gui heap-overrun report). Generated with:
//   magick -size 16x16 radial-gradient:yellow-magenta \
//     -colorspace CMYK -sampling-factor 2x2 -quality 85 <file>
pub const fixture_cmyk_16x16_ycck_sub = @embedFile("fixtures/cmyk_16x16_ycck_subsampled.jpg");

/// T1.4: 4×4 grayscale baseline JPEG (1 component).
pub const fixture_baseline_4x4_grayscale = @embedFile("fixtures/baseline_4x4_grayscale.jpg");

/// T1.5a: 8×8 RGB JPEG with 4:2:0 chroma subsampling. libjpeg-turbo
/// upsamples to full-res RGB on output, so the consumer sees
/// `width=8 height=8 channels=3` regardless of internal subsampling.
pub const fixture_baseline_8x8_yuv420 = @embedFile("fixtures/baseline_8x8_yuv420.jpg");

/// T1.5b: 8×8 RGB JPEG with 4:2:2 chroma subsampling.
pub const fixture_baseline_8x8_yuv422 = @embedFile("fixtures/baseline_8x8_yuv422.jpg");

/// Mode-2 (JPEGTables-spliced / abbreviated) JPEG-in-TIFF stream. Built
/// from tiffz's `rgb-jpeg.tif` (Compression=7, 157×151 RGB, JPEGTables
/// Mode 2) by the TN2 splice: JPEGTables (SOI…DQT…DHT…EOI) minus trailing
/// EOI ++ strip (SOI…SOF SOS scan…EOI) minus leading SOI → one complete
/// `SOI tables SOF SOS scan EOI` baseline stream. libjpeg decodes it fine;
/// the cleanroom was producing a uniform color shift from byte 0 — a
/// table-inheritance gap where DQT/DHT carried in the spliced prefix
/// weren't applied. Differential gate vs the libjpeg oracle.
pub const fixture_mode2_spliced = @embedFile("fixtures/rgb-mode2-spliced.jpg");

/// 4×4 16-bit grayscale lossless. precision 16, all 0x8000.
pub const fixture_lossless_4x4_gray16 = @embedFile("fixtures/lossless_4x4_gray16.jpg");

pub const fixture_lossless_16x16_gray_dri = @embedFile("fixtures/lossless_16x16_gray_dri.jpg");

/// 8×8 grayscale progressive — simplest progressive case (1 component,
/// 6 scans: DC first + AC[1..5] + AC[6..63] + AC refine + DC refine + AC refine).
pub const fixture_progressive_8x8_gray = @embedFile("fixtures/progressive_8x8_gray.jpg");

/// 2×2 RGB SOF1 (extended sequential, 8-bit precision) — generated by
/// patching `baseline_2x2_rgb.jpg`'s SOF0 (0xFF 0xC0) marker to SOF1
/// (0xFF 0xC1). For 8-bit precision the bitstream is identical to
/// SOF0; only the marker differs. T.81 §A.4.2 / F.1.1 requires the
/// decoder to accept SOF1 the same as SOF0 at 8-bit precision.
pub const fixture_extended_2x2_rgb_sof1 = @embedFile("fixtures/extended_2x2_rgb_sof1.jpg");

/// 4×4 gradient (0x00,0x10,…,0xF0) encoded with `cjpeg -lossless 1`
/// (predictor 1 = Pa, left neighbor). Exercises the actual predictor +
/// difference math, not just the all-zero-diff trivial case.
pub const fixture_lossless_gradient_pred1 = @embedFile("fixtures/lossless_4x4_gradient_pred1.jpg");

/// All 7 predictors (T.81 §H.1.2.1) on the same 4×4 gradient. Each
/// fixture: `cjpeg -lossless <psv> /tmp/gradient.pgm`. Tests that
/// every predictor selector produces byte-identical pixels to the
/// wrapper's libjpeg-turbo decode of the same input. Lossless is
/// exact reconstruction by definition — any rounding mismatch is
/// a real bug in our predictor formula.
pub const fixture_lossless_gradient_pred2 = @embedFile("fixtures/lossless_4x4_gradient_pred2.jpg");

pub const fixture_lossless_gradient_pred3 = @embedFile("fixtures/lossless_4x4_gradient_pred3.jpg");

pub const fixture_lossless_gradient_pred4 = @embedFile("fixtures/lossless_4x4_gradient_pred4.jpg");

pub const fixture_lossless_gradient_pred5 = @embedFile("fixtures/lossless_4x4_gradient_pred5.jpg");

pub const fixture_lossless_gradient_pred6 = @embedFile("fixtures/lossless_4x4_gradient_pred6.jpg");

pub const fixture_lossless_gradient_pred7 = @embedFile("fixtures/lossless_4x4_gradient_pred7.jpg");

/// 32×32 grayscale progressive JPEG with DRI=8 (restart every 8 MCUs).
/// Generated via `cjpeg -progressive -restart 2 grad32.pgm`. Exercises
/// progressive cleanroom's DRI handling, which previously returned
/// NotImplemented for any 0xFF DD marker.
pub const fixture_progressive_32x32_dri = @embedFile("fixtures/progressive_32x32_gray_dri.jpg");

/// SOF9 arithmetic-coded baseline fixtures across all 4 chroma
/// sampling factors + grayscale. Generated by
/// `scratch/gen_arith_fixtures.sh` (cjpeg -arithmetic). Held here
/// as B1 ground-truth inputs; the parametric "cleanroom == wrapper"
/// test is added in the follow-on commit that ships DC/AC
/// binarization + DAC parser + SOF9 dispatch.
pub const fixture_arith_baseline_16x16_rgb_444 = @embedFile("fixtures/arith_baseline_16x16_rgb_444.jpg");

pub const fixture_arith_baseline_16x16_rgb_420 = @embedFile("fixtures/arith_baseline_16x16_rgb_420.jpg");

pub const fixture_arith_baseline_16x16_rgb_422 = @embedFile("fixtures/arith_baseline_16x16_rgb_422.jpg");

pub const fixture_arith_baseline_16x16_rgb_440 = @embedFile("fixtures/arith_baseline_16x16_rgb_440.jpg");

pub const fixture_arith_baseline_8x8_gray = @embedFile("fixtures/arith_baseline_8x8_gray.jpg");

/// One-MCU restart intervals, libjpeg-turbo 3.2.1 (fixtures/ARITH_RESTART_PROVENANCE.md).
pub const fixture_arith_restart_gray = @embedFile("fixtures/arith_restart_32x32_gray_1b.jpg");

pub const fixture_arith_restart_rgb420 = @embedFile("fixtures/arith_restart_32x32_rgb420_1b.jpg");

pub const fixture_arith_restart_rgb420_progressive = @embedFile("fixtures/arith_restart_32x32_rgb420_progressive_1b.jpg");

// ─────────────────────────────────────────────────────────────────────
// B2 — JPEG-LS (T.87) via charls wrapper. Cleanroom to follow.
// ─────────────────────────────────────────────────────────────────────

/// 4×4 8-bit grayscale JPEG-LS, gradient 0x00, 0x10, …, 0xF0. Encoded
/// by `scratch/gen_jpegls_fixtures.c` (one-shot, charls encoder).
pub const fixture_jpegls_4x4_gray8 = @embedFile("fixtures/jpegls_4x4_gray8.jls");

/// 4×4 16-bit grayscale JPEG-LS, gradient 0x0000, 0x1111, …, 0xFFFF.
pub const fixture_jpegls_4x4_gray16 = @embedFile("fixtures/jpegls_4x4_gray16.jls");

/// 4×4 RGB 8-bit JPEG-LS, sample-interleaved. R = x*0x40, G = y*0x40,
/// B = (x+y)*0x20.
pub const fixture_jpegls_4x4_rgb8 = @embedFile("fixtures/jpegls_4x4_rgb8.jls");

/// 4×4 RGB 16-bit JPEG-LS, sample-interleaved. Same gradient shape as
/// the 8-bit fixture, scaled into the upper byte: R = x*0x4000,
/// G = y*0x4000, B = (x+y)*0x2000.
pub const fixture_jpegls_4x4_rgb16 = @embedFile("fixtures/jpegls_4x4_rgb16.jls");

/// 8×8 grayscale 8-bit JPEG-LS at NEAR=2 (near-lossless). Original
/// pattern: `(x * 17 + y * 9) & 0xFF`. Side-car .raw holds the
/// unencoded pixels so the test can assert `|decoded - original| ≤ NEAR`.
pub const fixture_jpegls_8x8_gray8_near2 = @embedFile("fixtures/jpegls_8x8_gray8_near2.jls");

pub const fixture_jpegls_8x8_gray8_near2_raw = @embedFile("fixtures/jpegls_8x8_gray8_near2.raw");

pub const jpegls_conformance = @import("jpegls_conformance");

/// Samples of a binary 8-bit PGM (P5, maxval < 256): the bytes after the
/// third header line.
pub fn pgmSamples(pgm: []const u8) []const u8 {
    var lines: usize = 0;
    var i: usize = 0;
    while (lines < 3) : (i += 1) {
        if (pgm[i] == '\n') lines += 1;
    }
    return pgm[i..];
}

/// The single FAIL finding with `code` in a validation report, or null.
pub fn onlyFail(report: jpegz.ValidationReport, code: jpegz.FindingCode) ?jpegz.Finding {
    var found: ?jpegz.Finding = null;
    for (report.findings.items) |f| {
        if (f.severity != .fail) continue;
        if (f.code != code or found != null) return null;
        found = f;
    }
    return found;
}

pub fn dumpFindings(label: []const u8, report: jpegz.ValidationReport) void {
    std.debug.print("{s}: codec check {t}\n", .{ label, report.codec_check });
    for (report.findings.items) |f| std.debug.print("  {t} {t} {?d} exact={} {?s}\n", .{ f.severity, f.code, f.offset, f.offset_is_exact, f.detail });
}

// CharLS 3.0 mapping-table fixture: LSE ID 2 at 2 (Ll at 4, ID 6, TID 7,
// Wt 8, 256 entries 255 - i from 9 to 265), SOS at 278 (Tmi at 284, Al at
// 287). Samples v = ((x*37 + y*91) ^ (x*y)) % 201, mapped to 255 - v.
pub const map_src = @embedFile("fixtures/jpegls_16x16_gray8_mapping.jls");

pub fn mapSample(x: usize, y: usize) u8 {
    return 255 - @as(u8, @intCast(((x * 37 + y * 91) ^ (x * y)) % 201));
}

pub fn expectMapped(image: jpegz.Image) !void {
    for (0..16) |y| for (0..16) |x| try std.testing.expectEqual(mapSample(x, y), image.pixels[y * 16 + x]);
}

/// The fixture with its LSE ID 2 replaced by `segments`.
pub fn withTables(allocator: std.mem.Allocator, segments: []const []const u8) ![]u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);
    try parts.append(allocator, map_src[0..2]);
    try parts.appendSlice(allocator, segments);
    try parts.append(allocator, map_src[265..]);
    return std.mem.concat(allocator, u8, parts.items);
}

/// An LSE mapping segment: FF F8, Ll, ID, TID, Wt, entries.
pub fn lseMapping(allocator: std.mem.Allocator, id: u8, tid: u8, wt: u8, entries: []const u8) ![]u8 {
    const ll: u16 = @intCast(5 + entries.len);
    return std.mem.concat(allocator, u8, &.{ &.{ 0xff, 0xf8, @intCast(ll >> 8), @truncate(ll), id, tid, wt }, entries });
}

pub fn maxvalDerivation(report: jpegz.ValidationReport) ?jpegz.Finding {
    for (report.findings.items) |f| if (f.code == .jpegls_maxval_derivation) return f;
    return null;
}

/// One stream of a `tools/jpegls-maxval-corpus` pack: P, MAXVAL, NEAR and
/// content come from the name `p{P}_m{MAXVAL}_n{NEAR}_{content}`.
pub const MaxvalStream = struct {
    name: []const u8,
    data: []const u8,
    P: u8,
    maxval: u32,
    near: u32,
    content: enum { formula, gradient, noise, blocks },

    /// Sample (x, y) of the 32x32 source, as maxval_corpus.c computes it.
    /// `rng` carries the noise generator in raster order.
    pub fn sample(self: MaxvalStream, x: u32, y: u32, rng: *u32) u32 {
        return switch (self.content) {
            .formula => ((x * 37 + y * 91) ^ (x * y)) % (self.maxval + 1),
            .gradient => (x + y) * self.maxval / 62,
            .noise => blk: {
                rng.* = rng.* *% 1103515245 +% 12345;
                break :blk (rng.* >> 8) % (self.maxval + 1);
            },
            .blocks => if ((x / 8 + y / 8) % 2 == 1) self.maxval / 2 else self.maxval / 3,
        };
    }

    /// Every decoded sample is within NEAR of the source (equal at NEAR 0).
    pub fn matches(self: MaxvalStream, image: jpegz.Image) bool {
        var rng: u32 = 0x6a7065 ^ self.maxval ^ (self.near << 20);
        var i: usize = 0;
        for (0..32) |y| for (0..32) |x| {
            const want = self.sample(@intCast(x), @intCast(y), &rng);
            const got: u32 = if (self.P <= 8) image.pixels[i] else std.mem.readInt(u16, image.pixels[2 * i ..][0..2], @import("builtin").cpu.arch.endian());
            if (@max(want, got) - @min(want, got) > self.near) return false;
            i += 1;
        };
        return true;
    }
};

pub fn maxvalPack(comptime path: []const u8) []const MaxvalStream {
    @setEvalBranchQuota(1_000_000);
    const pack = @embedFile(path);
    comptime var list: []const MaxvalStream = &.{};
    comptime var pos: usize = 8;
    if (!std.mem.eql(u8, pack[0..8], "JLSCORP1")) @compileError("bad pack " ++ path);
    inline while (pos < pack.len) {
        const name_len = pack[pos];
        const name = pack[pos + 1 ..][0..name_len];
        pos += 1 + name_len;
        const len = std.mem.readInt(u32, pack[pos..][0..4], .little);
        pos += 4;
        var it = std.mem.tokenizeScalar(u8, name, '_');
        const p = std.fmt.parseInt(u8, it.next().?[1..], 10) catch unreachable;
        const m = std.fmt.parseInt(u32, it.next().?[1..], 10) catch unreachable;
        const n = std.fmt.parseInt(u32, it.next().?[1..], 10) catch unreachable;
        const content = std.meta.stringToEnum(@FieldType(MaxvalStream, "content"), it.next().?).?;
        list = list ++ [_]MaxvalStream{.{ .name = name, .data = pack[pos..][0..len], .P = p, .maxval = m, .near = n, .content = content }};
        pos += len;
    }
    return list;
}

/// The 12 streams both codings decode cleanly: smooth content at P = 8,
/// MAXVAL 2^k - 1, NEAR > 0, where stock and spec-mode CharLS write the
/// same bytes.
pub fn bothCodings(s: MaxvalStream) bool {
    return s.P == 8 and s.near > 0 and (s.maxval == 15 or s.maxval == 63 or s.maxval == 127) and
        (s.content == .gradient or s.content == .blocks);
}

/// SOF10 arithmetic progressive fixtures across all 4 chroma sampling
/// factors + grayscale. Generated by scratch/gen_arith_fixtures.sh
/// (cjpeg -arithmetic -progressive). Cleanroom must match libjpeg-turbo
/// within the same DCT-cleanroom tolerance as SOF9 / progressive Huffman.
pub const fixture_arith_progressive_16x16_rgb_444 = @embedFile("fixtures/arith_progressive_16x16_rgb_444.jpg");

pub const fixture_arith_progressive_16x16_rgb_420 = @embedFile("fixtures/arith_progressive_16x16_rgb_420.jpg");

pub const fixture_arith_progressive_16x16_rgb_422 = @embedFile("fixtures/arith_progressive_16x16_rgb_422.jpg");

pub const fixture_arith_progressive_16x16_rgb_440 = @embedFile("fixtures/arith_progressive_16x16_rgb_440.jpg");

pub const fixture_arith_progressive_8x8_gray = @embedFile("fixtures/arith_progressive_8x8_gray.jpg");

/// Decode `data` with a sink and return its interval and scan-end findings.
pub const ArithEnd = struct {
	err: ?anyerror,
	items: [16]jpegz.Finding = undefined,
	len: usize = 0,

	pub fn count(self: *const ArithEnd, code: jpegz.FindingCode) usize {
		var n: usize = 0;
		for (self.items[0..self.len]) |f| n += @intFromBool(f.code == code);
		return n;
	}

	pub fn first(self: *const ArithEnd, code: jpegz.FindingCode) ?jpegz.Finding {
		for (self.items[0..self.len]) |f| if (f.code == code) return f;
		return null;
	}
};

pub fn arithEnd(allocator: std.mem.Allocator, sink: *jpegz.FindingsSink, data: []const u8, lenient: bool) ArithEnd {
	var result: ArithEnd = .{ .err = null };
	if (jpegz.decodeWithOptions(allocator, data, .{ .lenient = lenient, .findings_sink = sink })) |image| {
		var decoded = image;
		decoded.deinit(allocator);
	} else |err| result.err = err;
	for (sink.items()) |f| switch (f.code) {
		.extraneous_bytes_before_marker, .restart_marker_missing, .restart_marker_unexpected, .truncated_stream => {
			if (result.len < result.items.len) {
				result.items[result.len] = f;
				result.len += 1;
			}
		},
		else => {},
	};
	return result;
}

/// SOF2 12-bit progressive fixtures across all 4 chroma sampling
/// factors + grayscale. Generated by `scratch/gen_prog12_fixtures.sh`
/// (cjpeg -progressive -precision 12 -sample <factors> | -grayscale).
/// Exercises A3: cleanroom 12-bit DCT in the progressive scan context,
/// reusing A1's `idct.idct8x8Generic(12, ...)` and A1 Part B's
/// `color.ycbcrRowToRgb12` / `fancyUpsample12` via Phase 2 refactor.
pub const fixture_progressive_16x16_rgb12_444 = @embedFile("fixtures/progressive_16x16_rgb12_444.jpg");

pub const fixture_progressive_16x16_rgb12_420 = @embedFile("fixtures/progressive_16x16_rgb12_420.jpg");

pub const fixture_progressive_16x16_rgb12_422 = @embedFile("fixtures/progressive_16x16_rgb12_422.jpg");

pub const fixture_progressive_16x16_rgb12_440 = @embedFile("fixtures/progressive_16x16_rgb12_440.jpg");

pub const fixture_progressive_8x8_gray12 = @embedFile("fixtures/progressive_8x8_gray12.jpg");

/// 4×4 RGB lossless (SOF3, 3 components, 1×1 sampling each, predictor 1).
/// Generated via `cjpeg -lossless 1 grad_rgb.ppm`. Component IDs are
/// the ASCII codes for R/G/B (82/71/66) rather than the more common
/// 1/2/3 — exercises ID-agnostic component lookup. v1 single-component
/// scope returned NotImplemented for 3-component SOF3.
pub const fixture_lossless_4x4_rgb = @embedFile("fixtures/lossless_4x4_rgb_pred1.jpg");

/// 16×16 grayscale lossless with restart-interval = 64 MCUs (4 rows of 16).
/// Generated via `cjpeg -lossless 1 -restart 4`. Three RSTm markers fall
/// within the entropy stream (at samples 64, 128, 192). Exercises lossless
/// cleanroom's RST handling, mirroring the M2.5 progressive+DRI fix.
pub const fixture_lossless_dri = @embedFile("fixtures/lossless_16x16_gray_dri.jpg");

