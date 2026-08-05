//! Production-shaped validator closure probe for Nix and symbol inspection.
//!
//! It calls both exact-pinned strict leaves through jpegz's validation-only
//! module, making accidental external decoder linkage observable in one ELF.

const std = @import("std");
const jpegz = @import("jpegz");

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var jp2 = try jpegz.jpeg2000.strictValidate(
        allocator,
        @embedFile("jp2_fixture"),
    );
    defer jp2.deinit(allocator);
    if (jp2.verdict != .valid) return error.Jpeg2000ValidationProbeFailed;

    var jxl = try jpegz.jpegxl.validate(
        allocator,
        @embedFile("jxl_fixture"),
        jpegz.jpegxl.default_options,
    );
    defer jxl.deinit(allocator);
    if (jxl.verdict != .valid) return error.JpegXlValidationProbeFailed;
}
