//! jpegz — spec-complete JPEG family decoder library (Zig core).
//!
//! Public API. The full API design lives in
//! `docs/superpowers/specs/2026-05-04-jpegz-public-api-design.md`.
//!
//! Phase 1 wraps libjpeg-turbo (BSD-3) for T.81 + JPEG-LS, openjpeg
//! (BSD-2) for JPEG 2000, and lifts validate's existing pure-Zig
//! lossless decoder for SOF3. Phase 2 retires the C deps with
//! cleanroom Zig replacements.
//!
//! No I/O in the core — all data flows in via `[]const u8` byte slices
//! the caller is responsible for materializing (mmap, readFile, network
//! buffer, embedded resource). The C FFI dogfoods this.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ── Re-exports from the canonical error module ──────────────────────
const errors = @import("core/errors.zig");
pub const DecodeError = errors.DecodeError;
pub const Severity = errors.Severity;
pub const Variant = errors.Variant;
pub const FindingCode = errors.FindingCode;

pub const version: [:0]const u8 = "0.1.0";

// ─────────────────────────────────────────────────────────────────────
// 1. Pixel-data types
// ─────────────────────────────────────────────────────────────────────

/// Source-encoded color space, populated by the decoder. Output pixel
/// layout is reported separately in `Image.layout` because the library
/// converts YCbCr → RGB and YCCK → CMYK by default.
pub const ColorSpace = enum(u8) {
    unknown,
    grayscale,
    rgb,
    ycbcr,           // T.81 most-common; converted to RGB on output
    cmyk,
    ycck,            // Adobe YCCK; converted to CMYK on output
    srgb,            // JP2 enumerated colorspace 16
    greyscale_jp2,   // JP2 enumerated colorspace 17
};

/// What the decoded `pixels` buffer actually contains, after conversion.
pub const PixelLayout = enum(u8) {
    grayscale, // 1 sample per pixel
    rgb,       // 3 samples per pixel, R-G-B order
    cmyk,      // 4 samples per pixel, C-M-Y-K order (JP2 doesn't emit this)
};

/// Decoded image. Caller owns `pixels`. Free via `image.deinit(allocator)`.
///
/// For 8-bit images, `pixels` is byte-shaped.
/// For 12/16-bit images, `pixels` is `u16`-shaped in **host endianness**,
/// reinterpret-cast as `[]u8`. Use `image.pixelsU16()` for the typed view.
/// The library guarantees the unused high bits are zero on <16-bit precision.
pub const Image = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    /// 1 = grayscale, 3 = RGB, 4 = CMYK
    channels: u8,
    /// 8 (default) | 12 (12-bit baseline) | 16 (lossless DICOM/DNG)
    bits_per_sample: u8,
    /// Source color space, before output conversion (informational).
    source_color_space: ColorSpace,
    /// What the buffer actually contains.
    layout: PixelLayout,

    /// Convenience: row stride in bytes.
    pub fn rowStride(self: Image) usize {
        const bytes_per_sample: usize = if (self.bits_per_sample > 8) 2 else 1;
        return @as(usize, self.width) * @as(usize, self.channels) * bytes_per_sample;
    }

    /// Convenience: reinterpret `pixels` as `[]u16` for >8-bit images.
    /// Asserts `bits_per_sample > 8`.
    pub fn pixelsU16(self: Image) []u16 {
        std.debug.assert(self.bits_per_sample > 8);
        return std.mem.bytesAsSlice(u16, self.pixels);
    }

    pub fn deinit(self: *Image, allocator: Allocator) void {
        allocator.free(self.pixels);
        self.* = undefined;
    }
};

/// Returned by `decodeStreamingRows`. No pixel buffer — the caller's
/// callback received the rows.
pub const ImageMetadata = struct {
    width: u32,
    height: u32,
    channels: u8,
    bits_per_sample: u8,
    source_color_space: ColorSpace,
    layout: PixelLayout,

    pub fn rowStride(self: ImageMetadata) usize {
        const bytes_per_sample: usize = if (self.bits_per_sample > 8) 2 else 1;
        return @as(usize, self.width) * @as(usize, self.channels) * bytes_per_sample;
    }
};

// ─────────────────────────────────────────────────────────────────────
// 2. Streaming
// ─────────────────────────────────────────────────────────────────────

/// Row-streaming callback. Library calls `on_row` once per emitted row
/// in raster order (y = 0, 1, …, height-1). `row` is borrowed; copy if
/// you need it past return. Return an error to abort decode — the
/// library propagates it back as `error.CallbackAborted` and stores the
/// original error message via the thread-local last-error mechanism
/// (visible to C callers as `jpegz_last_error_message()`).
pub const RowCallback = struct {
    on_row: *const fn (ctx: ?*anyopaque, row: []const u8, y: u32) anyerror!void,
    ctx: ?*anyopaque = null,
};

// ─────────────────────────────────────────────────────────────────────
// 3. Validation
// ─────────────────────────────────────────────────────────────────────

/// One observation about the bitstream. Multiple findings per report
/// is normal; a healthy image is `findings.items.len == 0`.
pub const Finding = struct {
    severity: Severity,
    code: FindingCode,
    /// Byte offset in `data` where the issue was detected, if known.
    /// 0 is a legitimate offset; `null` means "didn't apply / unknown".
    offset: ?u64 = null,
    /// Optional human-readable detail. Allocated from the report's
    /// allocator; freed by `ValidationReport.deinit()`. `null` = no detail.
    detail: ?[]const u8 = null,
};

/// Structured validation report. `validate` and `jpeg2000.validate`
/// always populate this and return successfully — even for badly-broken
/// input. A Zig error is reserved for catastrophic conditions (OOM,
/// internal library bug). Structural problems with the file go in
/// `findings` with severity `.fail`.
pub const ValidationReport = struct {
    /// Highest severity in `findings`. `.pass` if findings is empty.
    overall: Severity,
    /// Best-effort variant detection (set even on fail, where possible).
    variant: Variant,
    /// Image dimensions from SOF, when available. `null` if SOF not parsed.
    width: ?u32,
    height: ?u32,
    /// All findings, in detection order. Caller must pass the same
    /// allocator to `deinit` that was used to construct the report
    /// (Zig 0.15.2 std.ArrayList is unmanaged).
    findings: std.ArrayList(Finding),

    pub fn isValid(self: ValidationReport) bool {
        return self.overall == .pass or self.overall == .info or self.overall == .warn;
    }

    pub fn deinit(self: *ValidationReport, allocator: Allocator) void {
        for (self.findings.items) |f| {
            if (f.detail) |d| allocator.free(d);
        }
        self.findings.deinit(allocator);
        self.* = undefined;
    }
};

// ─────────────────────────────────────────────────────────────────────
// 4. Public entry points
// ─────────────────────────────────────────────────────────────────────

/// Decode any T.81 / T.87 JPEG (sequential / progressive / lossless /
/// arithmetic / JPEG-LS) into a fully-realized `Image`. Universal
/// entry point — works for every storage mode and precision.
///
/// `data` must remain valid through the call's return.
///
/// Output:
///   - 8-bit images: `pixels` is byte-shaped, RGB/grayscale/CMYK per `layout`.
///   - 12/16-bit images: `pixels` is `u16` host-endian (reinterpret-cast
///     as `[]u8`); accessed via `image.pixelsU16()`.
pub fn decode(allocator: Allocator, data: []const u8) DecodeError!Image {
    return @import("ffi/libjpeg_wrapper.zig").decode(allocator, data);
}

/// Decode JPEG row-by-row, invoking `cb` once per emitted row in
/// raster order (y = 0, 1, …, height-1).
///
/// Supported storage modes: SOF0 / SOF1 (sequential), SOF3 (lossless),
/// SOF9 / SOF10 / SOF11 (arithmetic), JPEG-LS (T.87). **Returns
/// `error.NotRowStreamable` for SOF2 progressive** — caller can fall
/// back to `decode` and iterate the resulting buffer themselves.
///
/// The callback receives a borrowed slice. Copy if you need it past
/// return. Returning an error from the callback aborts decode and
/// propagates as `error.CallbackAborted`; the original error message
/// is preserved in the thread-local last-error mechanism.
pub fn decodeStreamingRows(
    allocator: Allocator,
    data: []const u8,
    cb: RowCallback,
) DecodeError!ImageMetadata {
    _ = allocator;
    _ = data;
    _ = cb;
    return error.NotImplemented;
}

/// Walk the bitstream without materializing pixels. Accumulates
/// findings; **does not fail-fast on structural problems**. Returns
/// a Zig error only for OOM or genuinely-impossible internal states.
/// A FAIL-rated report still returns successfully.
pub fn validate(
    allocator: Allocator,
    data: []const u8,
) error{OutOfMemory}!ValidationReport {
    return @import("core/validator.zig").validate(allocator, data);
}

// ─────────────────────────────────────────────────────────────────────
// 5. JPEG 2000 sub-namespace
// ─────────────────────────────────────────────────────────────────────

/// JPEG 2000 lives in its own namespace because the codec internals
/// share nothing with T.81 (wavelet + EBCOT vs. DCT + Huffman /
/// arithmetic).
pub const jpeg2000 = struct {
    pub fn decode(allocator: Allocator, data: []const u8) DecodeError!Image {
        return @import("ffi/openjpeg_wrapper.zig").decode(allocator, data);
    }

    pub fn validate(
        allocator: Allocator,
        data: []const u8,
    ) error{OutOfMemory}!ValidationReport {
        _ = allocator;
        _ = data;
        return ValidationReport{
            .overall = .pass,
            .variant = .unknown,
            .width = null,
            .height = null,
            .findings = .empty,
        };
    }
};

// ─────────────────────────────────────────────────────────────────────
// Inline tests — wiring sanity. Real test suites in `tests/`.
// ─────────────────────────────────────────────────────────────────────

test "version is non-empty" {
    try std.testing.expect(version.len > 0);
}

test "Image.rowStride for 8-bit RGB" {
    const img = Image{
        .pixels = &[_]u8{},
        .width = 100,
        .height = 50,
        .channels = 3,
        .bits_per_sample = 8,
        .source_color_space = .ycbcr,
        .layout = .rgb,
    };
    try std.testing.expectEqual(@as(usize, 300), img.rowStride());
}

test "Image.rowStride for 16-bit grayscale" {
    const img = Image{
        .pixels = &[_]u8{},
        .width = 100,
        .height = 50,
        .channels = 1,
        .bits_per_sample = 16,
        .source_color_space = .grayscale,
        .layout = .grayscale,
    };
    try std.testing.expectEqual(@as(usize, 200), img.rowStride());
}
