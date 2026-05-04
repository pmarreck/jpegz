//! jpegz — spec-complete JPEG family decoder library (Zig core).
//!
//! Phase 1 (current): scaffold only. Decode paths return `error.NotImplemented`.
//! Phase 1 wraps libjpeg-turbo (BSD-3) for baseline/progressive/arithmetic and
//! openjpeg (BSD-2) for JPEG 2000; lossless lifts validate's existing 698-line
//! pure-Zig decoder. Phase 2 retires C deps with cleanroom Zig replacements.
//!
//! The Zig core does NO I/O. All data flows in via `Source`-shaped buffers/
//! callbacks; consumers (the C FFI, the C CLI dogfooding it, validate, tiffz)
//! handle file/network/PDF-stream I/O on the outside. This is the project's
//! hexagonal boundary.
//!
//! Public API surface and the four open design questions (allocation strategy,
//! color-space conversion, DCT precision, JP2 streaming) are still being
//! brainstormed (see SPEC.md §9). Treat the shapes below as placeholders.

const std = @import("std");

pub const version = "0.0.1";

/// Color space of decoded pixels. Set by the codec when it reads the file's
/// JFIF/Exif/Adobe markers (or JP2 colorspace box). Caller may request
/// conversion to RGB at decode time once the API is locked.
pub const ColorSpace = enum(u8) {
    unknown,
    grayscale,
    rgb,
    ycbcr,
    cmyk,
    ycck,
    /// JPEG 2000: sRGB (enumerated colorspace 16)
    srgb,
    /// JPEG 2000: greyscale (enumerated colorspace 17)
    greyscale_jp2,
};

/// Decoded image. Caller owns `pixels` (allocated with the allocator passed to
/// `decode`). Free via `image.deinit(allocator)`.
pub const Image = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    /// 1 = grayscale, 3 = RGB/YCbCr, 4 = CMYK/YCCK
    channels: u8,
    /// 8 (baseline/progressive/lossless), 12 (12-bit baseline), or 16
    /// (lossless 16-bit, used by DICOM).
    bits_per_sample: u8,
    color_space: ColorSpace,

    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.* = undefined;
    }
};

/// Decode error set. Phase 1 only emits `NotImplemented`; Phase 2 expands
/// these to spec-grounded categories.
pub const DecodeError = error{
    NotImplemented,
    InvalidMarker,
    UnsupportedPrecision,
    TruncatedStream,
    OutOfMemory,
};

/// Decode a JPEG (baseline / progressive / lossless / arithmetic / JPEG-LS)
/// from a byte buffer. Stub.
pub fn decode(allocator: std.mem.Allocator, src: []const u8) DecodeError!Image {
    _ = allocator;
    _ = src;
    return error.NotImplemented;
}

/// JPEG 2000 lives in its own namespace because the codec internals share
/// nothing with T.81 (wavelet + EBCOT vs. DCT + Huffman/arithmetic).
pub const jpeg2000 = struct {
    pub fn decode(allocator: std.mem.Allocator, src: []const u8) DecodeError!Image {
        _ = allocator;
        _ = src;
        return error.NotImplemented;
    }
};

test "version is non-empty" {
    try std.testing.expect(version.len > 0);
}
