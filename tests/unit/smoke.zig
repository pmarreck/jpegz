//! Phase-1 scaffold smoke tests.
//!
//! `version is exposed` proves the build wiring (build.zig → addModule →
//! addTest → addImport) actually links the core into the test binary.
//!
//! `decode stub returns NotImplemented` is the TDD-red marker for Phase 1
//! milestone 2 — once we wrap libjpeg-turbo and feed it a real fixture, we
//! flip this to expect an `Image`.

const std = @import("std");
const jpegz = @import("jpegz");

test "version is exposed" {
    try std.testing.expect(jpegz.version.len > 0);
    try std.testing.expectEqualStrings("0.0.1", jpegz.version);
}

test "decode stub returns NotImplemented" {
    const empty: []const u8 = &[_]u8{};
    try std.testing.expectError(
        error.NotImplemented,
        jpegz.decode(std.testing.allocator, empty),
    );
}

test "jpeg2000.decode stub returns NotImplemented" {
    const empty: []const u8 = &[_]u8{};
    try std.testing.expectError(
        error.NotImplemented,
        jpegz.jpeg2000.decode(std.testing.allocator, empty),
    );
}
