const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // ReleaseFast default — see CLAUDE.md "Zig-Specific Notes"
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimization mode (default: ReleaseFast)",
    ) orelse .ReleaseFast;

    // ============================================================
    // Core Zig library: src/jpegz.zig
    // No I/O — pure decode logic. The C FFI (Phase 1 milestone 6)
    // and any consumer (validate, tiffz) will sit on top of this.
    // ============================================================
    const jpegz_mod = b.addModule("jpegz", .{
        .root_source_file = b.path("src/jpegz.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link C deps (system; provided by Nix flake's buildInputs):
    //   - libjpeg-turbo (jpeglib.h, used by src/ffi/libjpeg_wrapper.zig)
    //   - openjpeg     (openjpeg.h, used by src/ffi/openjpeg_wrapper.zig)
    jpegz_mod.linkSystemLibrary("jpeg", .{});
    jpegz_mod.linkSystemLibrary("openjp2", .{});
    jpegz_mod.link_libc = true;

    // Optional explicit include / library paths from the flake. When
    // cross-targeting (musl on Linux), Zig's host NIX_CFLAGS / NIX_LDFLAGS
    // don't apply; the flake passes the right pkgsStatic paths via these
    // -D options. On native builds these are unset and Zig finds the
    // libraries via the host wrapper-cc as usual.
    if (b.option([]const u8, "libjpeg-include", "Path to libjpeg headers")) |p|
        jpegz_mod.addIncludePath(.{ .cwd_relative = p });
    if (b.option([]const u8, "libjpeg-lib", "Path to libjpeg library directory")) |p|
        jpegz_mod.addLibraryPath(.{ .cwd_relative = p });
    if (b.option([]const u8, "openjpeg-include", "Path to openjpeg headers (incl. version subdir)")) |p|
        jpegz_mod.addIncludePath(.{ .cwd_relative = p });
    if (b.option([]const u8, "openjpeg-lib", "Path to openjpeg library directory")) |p|
        jpegz_mod.addLibraryPath(.{ .cwd_relative = p });

    const lib = b.addLibrary(.{
        .name = "jpegz",
        .linkage = .static,
        .root_module = jpegz_mod,
    });
    b.installArtifact(lib);

    // ============================================================
    // Test runner — three sources of tests:
    //   1. tests/unit/smoke.zig   — public-API wiring
    //   2. src/jpegz.zig          — inline tests (helpers, types)
    //   3. src/core/errors.zig    — inline tests (numeric stability)
    // The `test` step depends on all three; failure of any propagates.
    // ============================================================
    const test_step = b.step("test", "Run unit tests");

    // (1) Public smoke suite — imports `jpegz` like any consumer.
    const smoke_mod = b.createModule(.{
        .root_source_file = b.path("tests/unit/smoke.zig"),
        .target = target,
        .optimize = optimize,
    });
    smoke_mod.addImport("jpegz", jpegz_mod);
    const smoke_tests = b.addTest(.{
        .name = "smoke",
        .root_module = smoke_mod,
    });
    test_step.dependOn(&b.addRunArtifact(smoke_tests).step);

    // (2) Inline tests in the core module itself.
    const jpegz_inline_tests = b.addTest(.{
        .name = "jpegz_inline",
        .root_module = jpegz_mod,
    });
    test_step.dependOn(&b.addRunArtifact(jpegz_inline_tests).step);

    // (3) Decode test suite (M1.3 — baseline + progressive wrap).
    const decode_mod = b.createModule(.{
        .root_source_file = b.path("tests/unit/decode.zig"),
        .target = target,
        .optimize = optimize,
    });
    decode_mod.addImport("jpegz", jpegz_mod);
    const decode_tests = b.addTest(.{
        .name = "decode",
        .root_module = decode_mod,
    });
    test_step.dependOn(&b.addRunArtifact(decode_tests).step);

    // (4) Validate test suite (M1.5 — hand-written marker walker).
    const validate_mod = b.createModule(.{
        .root_source_file = b.path("tests/unit/validate.zig"),
        .target = target,
        .optimize = optimize,
    });
    validate_mod.addImport("jpegz", jpegz_mod);
    const validate_tests = b.addTest(.{
        .name = "validate",
        .root_module = validate_mod,
    });
    test_step.dependOn(&b.addRunArtifact(validate_tests).step);

    // (5) JPEG 2000 decode test suite (M1.6 — openjpeg wrap).
    const decode_jp2_mod = b.createModule(.{
        .root_source_file = b.path("tests/unit/decode_jp2.zig"),
        .target = target,
        .optimize = optimize,
    });
    decode_jp2_mod.addImport("jpegz", jpegz_mod);
    const decode_jp2_tests = b.addTest(.{
        .name = "decode_jp2",
        .root_module = decode_jp2_mod,
    });
    test_step.dependOn(&b.addRunArtifact(decode_jp2_tests).step);
}
