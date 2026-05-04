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

    const lib = b.addLibrary(.{
        .name = "jpegz",
        .linkage = .static,
        .root_module = jpegz_mod,
    });
    b.installArtifact(lib);

    // ============================================================
    // Unit tests: tests/unit/smoke.zig
    // The runner imports the core via `@import("jpegz")`.
    // ============================================================
    const smoke_mod = b.createModule(.{
        .root_source_file = b.path("tests/unit/smoke.zig"),
        .target = target,
        .optimize = optimize,
    });
    smoke_mod.addImport("jpegz", jpegz_mod);

    const unit_tests = b.addTest(.{
        .name = "smoke",
        .root_module = smoke_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
