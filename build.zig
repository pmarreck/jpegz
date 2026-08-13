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

    const brotli_include_dir = b.graph.environ_map.get("BROTLI_INCLUDE_DIR");
    const brotli_lib_dir = b.graph.environ_map.get("BROTLI_LIB_DIR");

    const addBrotliIncludes = struct {
        fn apply(mod: *std.Build.Module, include_dir: ?[]const u8) void {
            if (include_dir) |path| mod.addIncludePath(.{ .cwd_relative = path });
        }
    }.apply;
    const linkBrotli = struct {
        fn apply(mod: *std.Build.Module, lib_dir: ?[]const u8) void {
            if (lib_dir) |path| mod.addLibraryPath(.{ .cwd_relative = path });
            mod.linkSystemLibrary("brotlienc", .{});
            mod.linkSystemLibrary("brotlidec", .{});
            mod.linkSystemLibrary("brotlicommon", .{});
        }
    }.apply;

    // -Dwith-charls=false lets consumers that don't need JPEG-LS
    // (e.g. tiffz, which only needs baseline/progressive/lossless
    // for Compression=7 and DNG raw) skip the charls compile + link
    // entirely. Default true so jpegz's own CI keeps full coverage.
    const with_charls = b.option(
        bool,
        "with-charls",
        "Compile + link vendored charls (JPEG-LS support). Default true.",
    ) orelse true;

    // -Dwith-libjpeg-oracle=false drops libjpeg-turbo from the build. It is
    // ONLY used as the byte-perfect test oracle (jpegz.internal.wrapperDecode /
    // wrapperDumpCoefs); the runtime decode() path is cleanroom-only and never
    // calls it. Default true so jpegz CI + oracle comparisons keep working;
    // prod / consumer builds pass false to shed the libjpeg-turbo dependency.
    const with_libjpeg_oracle = b.option(
        bool,
        "with-libjpeg-oracle",
        "Compile + link libjpeg-turbo as the dev/test oracle. Default true; false drops it from prod.",
    ) orelse true;

    // -Dwith-jxl=false drops the JPEG XL leg of the validation facade.
    //
    // It exists for one reason: libjxlz reads Brotli-compressed JXL container
    // metadata through `@cImport(<brotli/decode.h>)`, and nixpkgs has no
    // working Brotli for the mingw-w64 target — the dynamic build ships only
    // `.dll.a` import libraries (Zig looks for `libbrotli*.a`) and the static
    // build fails to compile. Windows therefore cannot link the JXL leg today.
    //
    // This is NOT a capability regression: before the facade existed, Windows
    // compiled no JXL path at all (see the facade test's Windows exclusion
    // below). The difference is that jpegz now SAYS so — a JXL file on a
    // build without this leg validates as `indeterminate` with
    // `jxl_validator_unavailable`, which is exactly what that verdict is for.
    // Sniffing still identifies the format, since that is pure byte matching.
    //
    // Removing this option means vendoring Brotli's source and compiling it
    // with Zig, the same way charls is handled — the honest fix, and the one
    // that would let a single static Windows binary validate JXL.
    const with_jxl = b.option(
        bool,
        "with-jxl",
        "Compile + link the JPEG XL validation leg (needs Brotli). Default true.",
    ) orelse true;

    // -Dwith-jp2-decode=false drops OpenJPEG entirely: the wrapper's @cImport
    // never runs and no openjp2 link edge is created.
    //
    // Requested by validate (2026-08-11) for their v1 production closure,
    // whose rule is no non-first-party codecs. `jpeg2000.decode` is the ONLY
    // path that touches OpenJPEG; strict JP2 validation is jp2z and stays
    // fully functional with this off, which is the point — a consumer that
    // validates but never decodes JP2 should not carry a JPEG 2000 codec.
    //
    // With it off, `jpeg2000.decode` returns error.NotImplemented rather than
    // failing to compile, so the shape of the API does not change per build.
    const with_jp2_decode = b.option(
        bool,
        "with-jp2-decode",
        "Compile + link OpenJPEG for jpeg2000.decode. Default true; false leaves strict JP2 validation intact.",
    ) orelse true;

    // Expose options to Zig source via @import("jpegz_build_options").
    // charls_wrapper.zig branches its @cImport on with_charls, and src/jpegz.zig
    // gates its libjpeg-oracle internals on with_libjpeg_oracle, so neither C
    // header needs to resolve when its gate is off.
    //
    // Name is intentionally namespaced (NOT the conventional `build_options`)
    // to avoid Zig 0.16's package-graph dedup collision when a downstream
    // consumer pulls in two jpegz versions transitively (e.g. validate pins
    // jpegz directly AND through tiffz). Both copies would otherwise register a
    // module called `build_options` and Zig surfaces "file exists in modules
    // build_options1 and build_options3" errors. The jpegz-prefixed name keeps
    // each copy's options module distinct.
    const build_options = b.addOptions();
    build_options.addOption(bool, "with_charls", with_charls);
    build_options.addOption(bool, "with_libjpeg_oracle", with_libjpeg_oracle);
    build_options.addOption(bool, "with_jxl", with_jxl);
    build_options.addOption(bool, "with_jp2_decode", with_jp2_decode);
    const build_options_mod = build_options.createModule();
    jpegz_mod.addImport("jpegz_build_options", build_options_mod);

    // jp2z supplies the cleanroom T.800 codestream walker behind
    // `jpegz.jpeg2000.validate`. Consumed as a plain Zig module, never
    // through jp2z's C ABI, per Peter's 2026-07-31 facade ruling: routing
    // sibling-Zig calls through a C round-trip sacrifices type safety and
    // comptime for ceremony, and jpegz is the outward-facing C surface for
    // the whole family.
    //
    // Eager (`dependency`, not `lazyDependency`) because jpeg2000.validate
    // always needs it — a lazy dep would force every call site to handle a
    // missing module. Safe in the sandboxed Nix build because the zigDeps
    // fixed-output derivation pre-fetches the entire tree with
    // `zig build --fetch=all`, and all three build phases seed
    // ZIG_GLOBAL_CACHE_DIR from it.
    //
    // We reference ONLY jp2z's public validate/deepValidate functions. Its
    // decode path still routes to OpenJPEG, and Zig's lazy analysis keeps
    // that C dependency off the validation graph. The Nix validator-closure
    // check fails if it ever creeps back on.
    const jp2z_dep = b.dependency("jp2z", .{ .target = target, .optimize = optimize });
    jpegz_mod.addImport("jp2z", jp2z_dep.module("jp2z"));
    const libjxlz_dep = b.dependency("libjxlz", .{ .target = target, .optimize = optimize });
    const libjxlz_mod = b.createModule(.{
        .root_source_file = libjxlz_dep.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addBrotliIncludes(libjxlz_mod, brotli_include_dir);
    jpegz_mod.addImport("libjxlz", libjxlz_mod);

    // A separately rooted facade module makes the production validation graph
    // mechanically incapable of inheriting jpegz's libjpeg/OpenJPEG/CharLS
    // decode links. Brotli remains because libjxlz reads Brotli-compressed JXL
    // container metadata; it is not an external JPEG-family validator.
    const validation_build_options = b.addOptions();
    validation_build_options.addOption(bool, "with_charls", false);
    validation_build_options.addOption(bool, "with_libjpeg_oracle", false);
    validation_build_options.addOption(bool, "with_jxl", with_jxl);
    // The validation graph never decodes JP2 — jp2z does the strict walk — so
    // this is false regardless of the flag, making the exclusion explicit
    // rather than relying on lazy analysis to keep OpenJPEG out.
    validation_build_options.addOption(bool, "with_jp2_decode", false);
    const jpegz_validation_mod = b.createModule(.{
        .root_source_file = b.path("src/jpegz.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    jpegz_validation_mod.addImport("jpegz_build_options", validation_build_options.createModule());
    jpegz_validation_mod.addImport("jp2z", jp2z_dep.module("jp2z"));
    jpegz_validation_mod.addImport("libjxlz", libjxlz_mod);
    // Link C deps (system; provided by Nix flake's buildInputs):
    //   - libjpeg-turbo (jpeglib.h, used by src/ffi/libjpeg_wrapper.zig)
    //                   — DEV/TEST ORACLE ONLY, gated on -Dwith-libjpeg-oracle.
    //   - openjpeg     (openjpeg.h, used by src/ffi/openjpeg_wrapper.zig)
    //   - charls       (charls/charls.h, used by src/ffi/charls_wrapper.zig)
    //                   — VENDORED: compiled from source via -Dcharls-src
    //                   or CHARLS_SRC env, see the charls block below.
    // NOTE: libjpeg and openjpeg are deliberately NOT linked onto `jpegz_mod`.
    // See `linkJpegSystemDeps` below — the shared module supplies HEADERS, and
    // each consuming artifact does its own linking.
    if (with_charls) jpegz_mod.link_libcpp = true;
    jpegz_mod.link_libc = true;

    // Optional explicit include / library paths from the flake. When
    // cross-targeting (musl on Linux), Zig's host NIX_CFLAGS / NIX_LDFLAGS
    // don't apply; the flake passes the right pkgsStatic paths via these
    // -D options. On native builds these are unset and Zig finds the
    // libraries via the host wrapper-cc as usual.
    const opt_libjpeg_inc = b.option([]const u8, "libjpeg-include", "Path to libjpeg headers");
    const opt_libjpeg_lib = b.option([]const u8, "libjpeg-lib", "Path to libjpeg library directory");
    const opt_openjpeg_inc = b.option([]const u8, "openjpeg-include", "Path to openjpeg headers (incl. version subdir)");
    const opt_openjpeg_lib = b.option([]const u8, "openjpeg-lib", "Path to openjpeg library directory");
    if (opt_libjpeg_inc) |p| jpegz_mod.addIncludePath(.{ .cwd_relative = p });
    if (opt_libjpeg_lib) |p| jpegz_mod.addLibraryPath(.{ .cwd_relative = p });
    if (opt_openjpeg_inc) |p| jpegz_mod.addIncludePath(.{ .cwd_relative = p });
    if (opt_openjpeg_lib) |p| jpegz_mod.addLibraryPath(.{ .cwd_relative = p });

    // openjpeg linkage: link the system lib when a path is provided (native
    // nix build — the flake passes -Dopenjpeg-lib); otherwise Zig-vendor it
    // from deps/openjpeg (a self-contained no-SIMD libopenjp2) so jpegz
    // cross-compiles to every target including windows-{x86_64,aarch64}.
    // Attach libjpeg / openjpeg to a CONSUMING ARTIFACT rather than to the
    // shared `jpegz_mod`.
    //
    // Linking a system STATIC library onto a module whose graph produces a
    // static library makes Zig bundle that `.a` as a member of the output
    // `.a`. LLD cannot use an archive nested inside an archive — it warns
    // ("neither ET_REL nor LLVM bitcode") and Zig escalates that warning to a
    // hard error the moment a link needs a symbol that makes it try to load
    // the member. The result is a `libjpegz.a` that grows more unlinkable the
    // more of it a consumer actually uses: adding the JPEG XL leg tripped it,
    // and merely adding the locale exports tripped it again after a green
    // build. Every consumer already links these libraries itself, so the
    // bundled copies were never load-bearing — only hazardous.
    //
    // Headers stay on `jpegz_mod` (the @cImports need them to COMPILE); only
    // the link step moves.
    const linkJpegSystemDeps = struct {
        fn apply(
            mod: *std.Build.Module,
            oracle: bool,
            jp2_decode: bool,
            jpeg_lib: ?[]const u8,
            openjpeg_lib: ?[]const u8,
        ) void {
            if (jpeg_lib) |p| mod.addLibraryPath(.{ .cwd_relative = p });
            if (oracle) mod.linkSystemLibrary("jpeg", .{});
            if (!jp2_decode) return; // -Dwith-jp2-decode=false: no openjp2 edge
            if (openjpeg_lib) |p| mod.addLibraryPath(.{ .cwd_relative = p });
            if (openjpeg_lib != null) mod.linkSystemLibrary("openjp2", .{});
        }
    }.apply;

    if (!with_jp2_decode) {
        // -Dwith-jp2-decode=false: no OpenJPEG edge of any kind. The wrapper's
        // @cImport is pruned too, so neither the header nor the library is
        // needed. Strict JP2 validation (jp2z) is unaffected.
    } else if (opt_openjpeg_lib != null) {
        // Linked per-artifact by linkJpegSystemDeps, not here.
    } else if (b.lazyDependency("openjpeg", .{ .target = target, .optimize = optimize })) |openjpeg_dep| {
        // lazyDependency (not dependency): the vendored openjp2 source is
        // fetched ONLY when this branch runs (cross-compile, no system lib).
        // The native system-openjpeg path above never calls this, so the
        // sandboxed Linux build never needs network for openjpeg_src.
        jpegz_mod.linkLibrary(openjpeg_dep.artifact("openjp2"));
    }

    // ── charls — vendored, compiled by Zig (gated on -Dwith-charls) ──
    //
    // We tried two paths through nixpkgs binaries first; both broke
    // (gcc/libstdc++ vs Zig's libc++ symbol mismatch on Linux musl,
    // then libcxxStdenv-on-musl missing libgcc_eh). Vendoring the
    // source and compiling via Zig's own clang+libc++ keeps the C++
    // stdlib consistent end-to-end. The 8 .cpp files take a few
    // seconds to compile; the resulting `libcharls.a` ships with us.
    //
    // Source path comes from `-Dcharls-src=...` (set by flake) or
    // `CHARLS_SRC` env var (set by dev shell).
    const charls_src_path: ?[]const u8 = b.option(
        []const u8,
        "charls-src",
        "Path to vendored charls source tree (with src/ + include/charls/)",
    ) orelse b.graph.environ_map.get("CHARLS_SRC");

    if (with_charls) {
        const path = charls_src_path orelse @panic(
            "charls source path required: pass -Dcharls-src=PATH or set CHARLS_SRC env. " ++
                "Inside the nix devShell or nix build, both are configured automatically. " ++
                "Consumers that don't need JPEG-LS can pass -Dwith-charls=false.",
        );
        const charls_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        charls_mod.link_libcpp = true;
        charls_mod.addCSourceFiles(.{
            .root = .{ .cwd_relative = path },
            .files = &.{
                "src/charls_jpegls_decoder.cpp",
                "src/charls_jpegls_encoder.cpp",
                "src/jpeg_stream_reader.cpp",
                "src/jpeg_stream_writer.cpp",
                "src/jpegls_error.cpp",
                "src/jpegls.cpp",
                "src/validate_spiff_header.cpp",
                "src/version.cpp",
            },
            .flags = &.{
                "-std=c++17",
                "-fexceptions",
                "-Wno-unused-parameter",
            },
        });
        charls_mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{path}) });
        charls_mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/src", .{path}) });
        const charls_lib = b.addLibrary(.{
            .name = "charls",
            .linkage = .static,
            .root_module = charls_mod,
        });
        jpegz_mod.linkLibrary(charls_lib);
        jpegz_mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{path}) });
    }

    // The static library is rooted at src/lib_root.zig, NOT src/jpegz.zig.
    // lib_root's only job is to reference `jpegz.c_abi_force_link`, which
    // pulls the C ABI's `export fn`s past dead-code elimination. Keeping that
    // reference out of the importable module root is what lets a pure-Zig
    // consumer (tiffz / validate) import `jpegz` and call `validate()` without
    // openjpeg headers in scope — see src/lib_root.zig for the full rationale,
    // and tests/cli/no_c_consumer.bash for the gate that keeps it true.
    const lib_root_mod = b.createModule(.{
        .root_source_file = b.path("src/lib_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_root_mod.addImport("jpegz", jpegz_mod);

    const lib = b.addLibrary(.{
        .name = "jpegz",
        .linkage = .static,
        .root_module = lib_root_mod,
    });
    b.installArtifact(lib);

    // Validation-only archive: same header, same validation symbols, but its
    // module graph links NO external JPEG-family decoder — so it bundles no
    // nested system `.a` members. That is what makes it linkable at all once
    // the ABI reaches the JXL leg (LLD cannot use nested archive members and
    // Zig escalates its warning to an error), and it gives any validation-only
    // consumer the closure guarantee `checks.validator-closure` already
    // enforces for the probe. Rationale: src/ffi/c_common.zig.
    const validation_lib_root_mod = b.createModule(.{
        .root_source_file = b.path("src/validation_lib_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    validation_lib_root_mod.addImport("jpegz", jpegz_validation_mod);
    const validation_lib = b.addLibrary(.{
        .name = "jpegz-validate",
        .linkage = .static,
        .root_module = validation_lib_root_mod,
    });
    b.installArtifact(validation_lib);

    // ============================================================
    // C ABI: install include/jpegz_core.h (curated) and generate
    // include/jpegz_errno.h (auto from src/core/errors.zig).
    // ============================================================
    const errors_mod = b.createModule(.{
        .root_source_file = b.path("src/core/errors.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    });
    const gen_header_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen_c_header.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    });
    gen_header_mod.addImport("errors", errors_mod);
    const gen_header_exe = b.addExecutable(.{
        .name = "jpegz-gen-header",
        .root_module = gen_header_mod,
    });
    const run_gen = b.addRunArtifact(gen_header_exe);
    const generated_errno_h = run_gen.addOutputFileArg("jpegz_errno.h");
    lib.step.dependOn(&run_gen.step);

    b.installFile("include/jpegz_core.h", "include/jpegz_core.h");
    const installed_errno = b.addInstallFileWithDir(
        generated_errno_h,
        .header,
        "jpegz_errno.h",
    );
    b.getInstallStep().dependOn(&installed_errno.step);

    // ============================================================
    // Test runner — three sources of tests:
    //   1. tests/unit/smoke.zig   — public-API wiring
    //   2. src/jpegz.zig          — inline tests (helpers, types)
    //   3. src/core/errors.zig    — inline tests (numeric stability)
    // The `test` step depends on all three; failure of any propagates.
    // ============================================================
    // FLEET FLOOR — tests run ReleaseSafe (fleet finding 2026-07-01, Pattern 3):
    // ReleaseFast masks UB (integer overflow, bounds) so a green ./test can hide
    // real crashers — e.g. jpegls setDefaultThresholds overflowed on valid 16-bit
    // input, invisible in ReleaseFast. Enforcement lives in flake.nix
    // (jpegzTestCheck passes -Doptimize=ReleaseSafe), which flips the ENTIRE test
    // compilation — the shared `jpegz` module + every test module — to ReleaseSafe
    // in one shot. (A per-module `.optimize = .ReleaseSafe` here, rarz-style,
    // would leave import-based tests' jpegz code at ReleaseFast, since Zig honors
    // per-module optimize; jpegz's `jpegz` module is shared with the shipped lib,
    // which must stay ReleaseFast.) `./test` runs the flake check, so it is safe;
    // benchmarks + the packaged lib stay ReleaseFast.
    const test_step = b.step("test", "Run unit tests (ReleaseSafe via flake; see note above)");
    const test_build_step = b.step("test-build", "Compile all tests without running, for cross-target link verification");

    // (1) Public smoke suite — imports `jpegz` like any consumer.
    const smoke_mod = b.createModule(.{
        .root_source_file = b.path("tests/unit/smoke.zig"),
        .target = target,
        .optimize = optimize,
    });
    smoke_mod.addImport("jpegz", jpegz_mod);
    linkJpegSystemDeps(smoke_mod, with_libjpeg_oracle, with_jp2_decode, opt_libjpeg_lib, opt_openjpeg_lib);
    const smoke_tests = b.addTest(.{
        .name = "smoke",
        .root_module = smoke_mod,
    });
    test_step.dependOn(&b.addRunArtifact(smoke_tests).step);
    test_build_step.dependOn(&smoke_tests.step);

    // (2) Inline tests in the core module itself.
    const jpegz_inline_tests = b.addTest(.{
        .name = "jpegz_inline",
        .root_module = jpegz_mod,
    });
    test_step.dependOn(&b.addRunArtifact(jpegz_inline_tests).step);
    test_build_step.dependOn(&jpegz_inline_tests.step);

    // (2b) Cleanroom decode unit tests (each module owns its own tests).
    const bitstream_mod = b.createModule(.{
        .root_source_file = b.path("src/decode/bitstream.zig"),
        .target = target,
        .optimize = optimize,
    });
    const bitstream_tests = b.addTest(.{
        .name = "decode_bitstream",
        .root_module = bitstream_mod,
    });
    test_step.dependOn(&b.addRunArtifact(bitstream_tests).step);
    test_build_step.dependOn(&bitstream_tests.step);

    const huffman_mod = b.createModule(.{
        .root_source_file = b.path("src/decode/huffman.zig"),
        .target = target,
        .optimize = optimize,
    });
    const huffman_tests = b.addTest(.{
        .name = "decode_huffman",
        .root_module = huffman_mod,
    });
    test_step.dependOn(&b.addRunArtifact(huffman_tests).step);
    test_build_step.dependOn(&huffman_tests.step);

    const idct_mod = b.createModule(.{
        .root_source_file = b.path("src/decode/idct.zig"),
        .target = target,
        .optimize = optimize,
    });
    const idct_tests = b.addTest(.{
        .name = "decode_idct",
        .root_module = idct_mod,
    });
    test_step.dependOn(&b.addRunArtifact(idct_tests).step);
    test_build_step.dependOn(&idct_tests.step);

    const last_error_mod = b.createModule(.{
        .root_source_file = b.path("src/core/last_error.zig"),
        .target = target,
        .optimize = optimize,
    });
    const last_error_tests = b.addTest(.{
        .name = "core_last_error",
        .root_module = last_error_mod,
    });
    test_step.dependOn(&b.addRunArtifact(last_error_tests).step);
    test_build_step.dependOn(&last_error_tests.step);

    const arith_coder_mod = b.createModule(.{
        .root_source_file = b.path("src/decode/arith_coder.zig"),
        .target = target,
        .optimize = optimize,
    });
    const arith_coder_tests = b.addTest(.{
        .name = "decode_arith_coder",
        .root_module = arith_coder_mod,
    });
    test_step.dependOn(&b.addRunArtifact(arith_coder_tests).step);
    test_build_step.dependOn(&arith_coder_tests.step);

    const jpegls_bitstream_mod = b.createModule(.{
        .root_source_file = b.path("src/decode/jpegls_bitstream.zig"),
        .target = target,
        .optimize = optimize,
    });
    const jpegls_bitstream_tests = b.addTest(.{
        .name = "decode_jpegls_bitstream",
        .root_module = jpegls_bitstream_mod,
    });
    test_step.dependOn(&b.addRunArtifact(jpegls_bitstream_tests).step);
    test_build_step.dependOn(&jpegls_bitstream_tests.step);

    // The jpegls cleanroom (`src/decode/jpegls.zig`) and its codec
    // helpers (`jpegls_codec.zig`) belong to jpegz_mod via relative
    // @imports from `src/jpegz.zig`'s dispatch. The codec module
    // pulls in the bit reader via the named import `"jpegls_bitstream"`,
    // which we wire on jpegz_mod here so it resolves transitively.
    // Their inline tests run via `jpegz_inline_tests` (no separate
    // test target — that would put their files in two modules and
    // Zig 0.16 rejects it).
    jpegz_mod.addImport("jpegls_bitstream", jpegls_bitstream_mod);
    // The validation-only module needs it too: `validateAny`'s T.81/T.87 leg
    // runs the same cleanroom walker, and the JPEG family is the largest thing
    // the facade covers. Pure Zig, so the no-external-validator closure gate
    // is unaffected — `tests/cli/no_c_consumer.bash` proves that mechanically.
    jpegz_validation_mod.addImport("jpegls_bitstream", jpegls_bitstream_mod);

    // Cleanroom decoder modules (baseline.zig etc.) are tested
    // implicitly via the dispatch in src/jpegz.zig — when a fixture
    // matches the cleanroom's supported shape (8-bit, no subsampling,
    // no DRI), the dispatcher routes to it; otherwise falls back to
    // libjpeg_wrapper. Tier 1 fixture coverage is the indirect test
    // surface. (Direct tests would need a separate baseline_mod which
    // creates a module-cycle through jpegz.zig.)

    // (3) Decode test suite (M1.3 — baseline + progressive wrap).
    const decode_mod = b.createModule(.{
        .root_source_file = b.path("tests/unit/decode.zig"),
        .target = target,
        .optimize = optimize,
    });
    decode_mod.addImport("jpegz", jpegz_mod);
    linkJpegSystemDeps(decode_mod, with_libjpeg_oracle, with_jp2_decode, opt_libjpeg_lib, opt_openjpeg_lib);
    const decode_tests = b.addTest(.{
        .name = "decode",
        .root_module = decode_mod,
    });
    test_step.dependOn(&b.addRunArtifact(decode_tests).step);
    test_build_step.dependOn(&decode_tests.step);

    // (4) Validate test suite (M1.5 — hand-written marker walker).
    const validate_mod = b.createModule(.{
        .root_source_file = b.path("tests/unit/validate.zig"),
        .target = target,
        .optimize = optimize,
    });
    validate_mod.addImport("jpegz", jpegz_mod);
    linkJpegSystemDeps(validate_mod, with_libjpeg_oracle, with_jp2_decode, opt_libjpeg_lib, opt_openjpeg_lib);
    const validate_tests = b.addTest(.{
        .name = "validate",
        .root_module = validate_mod,
    });
    test_step.dependOn(&b.addRunArtifact(validate_tests).step);
    test_build_step.dependOn(&validate_tests.step);

    // Honest four-way JPEG 2000 / JPEG XL validation facade. This suite uses
    // the validation-only module above, so its link graph cannot inherit the
    // decode/oracle libraries attached to `jpegz_mod`.
    const facade_validation_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/unit/facade_validation.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (with_jxl) linkBrotli(facade_validation_test_mod, brotli_lib_dir);
    facade_validation_test_mod.addImport("jpegz", jpegz_validation_mod);
    const facade_validation_tests = b.addTest(.{
        .name = "facade_validation",
        .root_module = facade_validation_test_mod,
    });
    test_step.dependOn(&b.addRunArtifact(facade_validation_tests).step);
    const facade_validation_step = b.step("test-facade", "Run the JPEG-family facade validation tests");
    facade_validation_step.dependOn(&b.addRunArtifact(facade_validation_tests).step);
    // Native Brotli is intentionally not smuggled into a Windows artifact.
    // A dedicated cross-Brotli facade target can be added once the flake owns
    // the corresponding mingw library; the existing all-tests cross gate must
    // remain honest and green in the meantime.
    if (target.result.os.tag != .windows) {
        test_build_step.dependOn(&facade_validation_tests.step);
    }

    // Locale parsing / resolution. Uses the validation-only module because
    // i18n is pure Zig and must never be a reason to link a C library; it also
    // keeps this suite runnable on the Windows cross target, unlike the facade
    // suite below.
    const i18n_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/unit/i18n.zig"),
        .target = target,
        .optimize = optimize,
    });
    i18n_test_mod.addImport("jpegz", jpegz_validation_mod);
    const i18n_tests = b.addTest(.{
        .name = "i18n",
        .root_module = i18n_test_mod,
    });
    test_step.dependOn(&b.addRunArtifact(i18n_tests).step);
    if (target.result.os.tag != .windows) test_build_step.dependOn(&i18n_tests.step);

    // A runnable production-shaped proof artifact. Its root imports only the
    // validation module, which has no decode/oracle library edges. Nix checks
    // its symbols and complete store closure for forbidden JPEG validators.
    const validation_probe_mod = b.createModule(.{
        .root_source_file = b.path("tools/facade_validator_probe.zig"),
        .target = target,
        .optimize = optimize,
    });
    validation_probe_mod.addImport("jpegz", jpegz_validation_mod);
    validation_probe_mod.addAnonymousImport("jp2_fixture", .{
        .root_source_file = b.path("tests/unit/fixtures/jp2_8x8_rgb.jp2"),
    });
    validation_probe_mod.addAnonymousImport("jxl_fixture", .{
        .root_source_file = b.path("tests/unit/fixtures/jxl_delta_palette_valid.jxl"),
    });
    if (with_jxl) linkBrotli(validation_probe_mod, brotli_lib_dir);
    const validation_probe = b.addExecutable(.{
        .name = "jpegz-validator-proof",
        .root_module = validation_probe_mod,
    });
    const install_validation_probe = b.addInstallArtifact(validation_probe, .{});
    const install_validation_step = b.step("install-validator", "Install the validation-only closure proof executable");
    install_validation_step.dependOn(&install_validation_probe.step);

    // (5) JPEG 2000 decode test suite (M1.6 — openjpeg wrap).
    const decode_jp2_mod = b.createModule(.{
        .root_source_file = b.path("tests/unit/decode_jp2.zig"),
        .target = target,
        .optimize = optimize,
    });
    decode_jp2_mod.addImport("jpegz", jpegz_mod);
    linkJpegSystemDeps(decode_jp2_mod, with_libjpeg_oracle, with_jp2_decode, opt_libjpeg_lib, opt_openjpeg_lib);
    const decode_jp2_tests = b.addTest(.{
        .name = "decode_jp2",
        .root_module = decode_jp2_mod,
    });
    test_step.dependOn(&b.addRunArtifact(decode_jp2_tests).step);
    test_build_step.dependOn(&decode_jp2_tests.step);

    // ============================================================
    // `zig build fuzz` — fuzz harnesses for jpegz.decode and
    // jpegz.validate. Wrapped by `./fuzz` Bash script. Distinct from
    // the `test` step so the long-running fuzz mode (`zig build fuzz
    // --fuzz`) doesn't bloat regular CI.
    //
    // Without `--fuzz` each test replays its seed corpus once — acts
    // as a smoke check that the harness compiles and the corpus is
    // wired correctly. With `--fuzz`, Zig's in-tree libfuzzer drives
    // coverage-guided mutation.
    // ============================================================
    const fuzz_step = b.step("fuzz", "Run fuzz harnesses (use --fuzz for coverage-guided mutation)");

    // Shared seed-corpus module lives next to tests/unit/fixtures/ so
    // its `@embedFile` calls resolve inside its own package. The fuzz
    // harnesses pull it in as `@import("seed")`.
    const seed_corpus_mod = b.createModule(.{
        .root_source_file = b.path("tests/unit/seed_corpus.zig"),
        .target = target,
        .optimize = optimize,
    });

    const decode_fuzz_mod = b.createModule(.{
        .root_source_file = b.path("tests/fuzz/decode_fuzz.zig"),
        .target = target,
        .optimize = optimize,
    });
    decode_fuzz_mod.addImport("jpegz", jpegz_mod);
    linkJpegSystemDeps(decode_fuzz_mod, with_libjpeg_oracle, with_jp2_decode, opt_libjpeg_lib, opt_openjpeg_lib);
    decode_fuzz_mod.addImport("seed", seed_corpus_mod);
    const decode_fuzz_tests = b.addTest(.{
        .name = "decode_fuzz",
        .root_module = decode_fuzz_mod,
    });
    fuzz_step.dependOn(&b.addRunArtifact(decode_fuzz_tests).step);

    const validate_fuzz_mod = b.createModule(.{
        .root_source_file = b.path("tests/fuzz/validate_fuzz.zig"),
        .target = target,
        .optimize = optimize,
    });
    validate_fuzz_mod.addImport("jpegz", jpegz_mod);
    linkJpegSystemDeps(validate_fuzz_mod, with_libjpeg_oracle, with_jp2_decode, opt_libjpeg_lib, opt_openjpeg_lib);
    validate_fuzz_mod.addImport("seed", seed_corpus_mod);
    const validate_fuzz_tests = b.addTest(.{
        .name = "validate_fuzz",
        .root_module = validate_fuzz_mod,
    });
    fuzz_step.dependOn(&b.addRunArtifact(validate_fuzz_tests).step);

    // ============================================================
    // C FFI smoke test (M1.7 — exercises include/jpegz_core.h via a
    // tiny C program that links against libjpegz.a). Same exec
    // dogfoods the public ABI the way validate / tiffz will.
    // ============================================================
    const c_smoke_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // The c_smoke executable transitively pulls in libjpeg + openjp2
    // because libjpegz.a uses them. When cross-targeting (musl on
    // Linux), Zig's host NIX_LDFLAGS doesn't apply — we have to point
    // c_smoke at the same -Dlibjpeg-lib / -Dopenjpeg-lib paths the
    // library itself was given. Native builds: these options are
    // unset and Zig finds the libs via the host wrapper-cc.
    if (with_libjpeg_oracle) c_smoke_mod.linkSystemLibrary("jpeg", .{});
    if (with_jp2_decode and opt_openjpeg_lib != null) c_smoke_mod.linkSystemLibrary("openjp2", .{});
    c_smoke_mod.link_libcpp = true; // libjpegz.a pulls in vendored charls (C++)
    // The full archive now also carries the validation half, whose JXL leg
    // reaches libjxlz's Brotli calls for container metadata. This suite is the
    // one place that exercises BOTH ABI halves against one library, so it is
    // the gate that would catch the two archives' symbol sets diverging.
    if (with_jxl) linkBrotli(c_smoke_mod, brotli_lib_dir);
    if (opt_libjpeg_lib) |p| c_smoke_mod.addLibraryPath(.{ .cwd_relative = p });
    if (opt_openjpeg_lib) |p| c_smoke_mod.addLibraryPath(.{ .cwd_relative = p });
    const c_smoke = b.addExecutable(.{
        .name = "c_smoke",
        .root_module = c_smoke_mod,
    });
    c_smoke_mod.addCSourceFile(.{
        .file = b.path("tests/cli/smoke.c"),
        .flags = &.{ "-std=c23", "-Wall", "-Wextra", "-Wpedantic" },
    });
    c_smoke_mod.addIncludePath(b.path("include"));
    c_smoke_mod.addIncludePath(generated_errno_h.dirname());
    // C23 #embed needs to reach ../unit/fixtures/ relative to the .c file.
    c_smoke_mod.addIncludePath(b.path("tests"));
    // The FULL archive only — it is the superset, and the two archives are
    // alternatives rather than companions (see src/lib_root.zig: each carries
    // its own last-error slot). This suite exercising both ABI halves against
    // one library is what proves that superset relationship holds.
    c_smoke_mod.linkLibrary(lib);
    test_step.dependOn(&b.addRunArtifact(c_smoke).step);
    test_build_step.dependOn(&c_smoke.step);

    // ============================================================
    // `jpegz` C CLI — the dogfooding consumer of include/jpegz_core.h.
    //
    // Written in C on purpose: C cannot `@import` the Zig module, so
    // bypassing the FFI is inexpressible here rather than merely
    // forbidden. Scope is validation only (U5).
    // ============================================================
    const cli_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // The CLI is validation-only by design, so it links the validation-only
    // archive: no libjpeg, no openjpeg, no CharLS, no libc++. Brotli is the
    // one C dependency it keeps, because libjxlz reads Brotli-compressed JXL
    // container metadata. Linking the full `lib` here instead would drag in
    // the nested system archives that LLD refuses and Zig then fails on.
    if (with_jxl) linkBrotli(cli_mod, brotli_lib_dir);
    cli_mod.addCSourceFile(.{
        .file = b.path("src/cli/jpegz.c"),
        .flags = &.{ "-std=c23", "-Wall", "-Wextra", "-Wpedantic" },
    });
    cli_mod.addIncludePath(b.path("include"));
    cli_mod.addIncludePath(generated_errno_h.dirname());
    cli_mod.linkLibrary(validation_lib);

    const cli_exe = b.addExecutable(.{
        .name = "jpegz",
        .root_module = cli_mod,
    });
    b.installArtifact(cli_exe);
    test_build_step.dependOn(&cli_exe.step);

    // The CLI surface suite is Bash-driven (argument discipline, exit codes,
    // stdin, spaced paths, ANSI suppression) — things only reachable by
    // running the built binary as a black box.
    const cli_tests = b.addSystemCommand(&.{ "bash", "tests/cli/validate_cli.bash" });
    cli_tests.addFileArg(cli_exe.getEmittedBin());
    cli_tests.step.dependOn(&cli_exe.step);
    test_step.dependOn(&cli_tests.step);
    // ============================================================
    // `zig build cleanroom-diff` — non-committed analysis tool that
    // walks a directory of JPEGs and diffs cleanroom vs. wrapper
    // output per-file. Source lives in scratch/ (gitignored). Skip
    // if the file isn't present (so a fresh checkout doesn't fail).
    // ============================================================
    if (std.Io.Dir.cwd().access(b.graph.io, "scratch/cleanroom_diff.zig", .{})) {
        // The diff binary lives in scratch/ (gitignored) and consumes
        // jpegz's public test surface (jpegz.internal.cleanroomDecode +
        // jpegz.internal.wrapperDecode) so it doesn't need to load
        // baseline / libjpeg_wrapper as separate modules — the existing
        // jpegz module covers everything.
        const diff_mod = b.createModule(.{
            .root_source_file = b.path("scratch/cleanroom_diff.zig"),
            .target = target,
            .optimize = optimize,
        });
        diff_mod.addImport("jpegz", jpegz_mod);
        linkJpegSystemDeps(diff_mod, with_libjpeg_oracle, with_jp2_decode, opt_libjpeg_lib, opt_openjpeg_lib);
        const diff_exe = b.addExecutable(.{
            .name = "cleanroom-diff",
            .root_module = diff_mod,
        });
        const diff_step = b.step("cleanroom-diff", "Build the scratch/ cleanroom-diff harness");
        diff_step.dependOn(&b.addInstallArtifact(diff_exe, .{}).step);
    } else |_| {}

    if (std.Io.Dir.cwd().access(b.graph.io, "scratch/diag_one.zig", .{})) {
        const diag_mod = b.createModule(.{
            .root_source_file = b.path("scratch/diag_one.zig"),
            .target = target,
            .optimize = optimize,
        });
        diag_mod.addImport("jpegz", jpegz_mod);
        linkJpegSystemDeps(diag_mod, with_libjpeg_oracle, with_jp2_decode, opt_libjpeg_lib, opt_openjpeg_lib);
        const diag_exe = b.addExecutable(.{
            .name = "diag-one",
            .root_module = diag_mod,
        });
        const diag_step = b.step("diag-one", "Single-file decoder diagnostic (scratch/diag_one.zig)");
        diag_step.dependOn(&b.addInstallArtifact(diag_exe, .{}).step);
    } else |_| {}

    if (std.Io.Dir.cwd().access(b.graph.io, "scratch/pixel_diff.zig", .{})) {
        const pd_mod = b.createModule(.{
            .root_source_file = b.path("scratch/pixel_diff.zig"),
            .target = target,
            .optimize = optimize,
        });
        pd_mod.addImport("jpegz", jpegz_mod);
        linkJpegSystemDeps(pd_mod, with_libjpeg_oracle, with_jp2_decode, opt_libjpeg_lib, opt_openjpeg_lib);
        const pd_exe = b.addExecutable(.{
            .name = "pixel-diff",
            .root_module = pd_mod,
        });
        const pd_step = b.step("pixel-diff", "Per-pixel cleanroom-vs-wrapper diff (scratch/pixel_diff.zig)");
        pd_step.dependOn(&b.addInstallArtifact(pd_exe, .{}).step);
    } else |_| {}

    if (std.Io.Dir.cwd().access(b.graph.io, "scratch/dump_coefs_jpegz.zig", .{})) {
        const dc_mod = b.createModule(.{
            .root_source_file = b.path("scratch/dump_coefs_jpegz.zig"),
            .target = target,
            .optimize = optimize,
        });
        dc_mod.addImport("jpegz", jpegz_mod);
        linkJpegSystemDeps(dc_mod, with_libjpeg_oracle, with_jp2_decode, opt_libjpeg_lib, opt_openjpeg_lib);
        const dc_exe = b.addExecutable(.{
            .name = "dump-coefs-jpegz",
            .root_module = dc_mod,
        });
        const dc_step = b.step("dump-coefs-jpegz", "Dump progressive cleanroom natural-order coefs (scratch/dump_coefs_jpegz.zig)");
        dc_step.dependOn(&b.addInstallArtifact(dc_exe, .{}).step);
    } else |_| {}

    if (std.Io.Dir.cwd().access(b.graph.io, "scratch/bench_one.zig", .{})) {
        const b1_mod = b.createModule(.{
            .root_source_file = b.path("scratch/bench_one.zig"),
            .target = target,
            .optimize = optimize,
        });
        b1_mod.addImport("jpegz", jpegz_mod);
        linkJpegSystemDeps(b1_mod, with_libjpeg_oracle, with_jp2_decode, opt_libjpeg_lib, opt_openjpeg_lib);
        const b1_exe = b.addExecutable(.{
            .name = "bench-one",
            .root_module = b1_mod,
        });
        const b1_step = b.step("bench-one", "Single-file decode timing harness (scratch/bench_one.zig)");
        b1_step.dependOn(&b.addInstallArtifact(b1_exe, .{}).step);
    } else |_| {}
}
