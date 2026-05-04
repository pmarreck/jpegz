# jpegz code minimap

Index of every source file plus a one-liner on what each defines. Update
on every file change. Goal: future agents skim this instead of grepping.

## Top-level

- `flake.nix` — Nix flake; pins `pkgs.zig` (0.15.2), `pkgs.libjpeg`
  (libjpeg-turbo 3.1.3), `pkgs.openjpeg` (2.5.4), `pkgs.hyperfine`. Exposes
  `packages.default`, `packages.jpegz`, `checks.{build,test}`,
  `devShells.default`. Garnix CI auto-evaluates these — no YAML.
- `build.zig` — Zig build script. ReleaseFast default; debug via
  `-Doptimize=Debug`. Exposes `addModule("jpegz")`, a static library
  target, and a `test` step that runs `tests/unit/smoke.zig`.
- `build` — Bash wrapper: `nix build .#default` (release), or
  `--debug` to drop into devShell with Debug optimize.
- `test` — Bash wrapper: runs `nix build .#checks.<system>.{test,build}`,
  accumulates failures across sub-checks. Per CLAUDE.md, intentionally
  does NOT use `set -e`.
- `bm` — Bash wrapper: benchmark suite stub. No benchmarks until Phase 2.
- `LICENSE` — MIT.
- `LICENSING_NOTES.md` — full dep license matrix (libjpeg-turbo BSD-3,
  openjpeg BSD-2, JPEG patent landscape).
- `README.md` — public-facing project description + Phase 1/2 sketch.
- `SPEC.md` — full project specification; the source of truth for
  milestones, ABI shape, design questions.
- `PLAN.md` — milestone checklist mirroring `SPEC.md` §6.
- `PROJECT_OVERVIEW.md` — short distillation of mission + key terms.
- `AGENTS.md` / `CLAUDE.md` — symlinks to Peter's global agent briefing.
- `ZIG_RECENT_API_CHANGES.md` / `ZIG_0.15_TO_0.16_MIGRATION.md` — vault
  references on Zig API churn (we target 0.15.2; 0.16 is reference only).

## Specs — `docs/superpowers/specs/`

- `2026-05-04-jpegz-public-api-design.md` — frozen v1 public API
  design (Zig + C ABI + error model + ValidationReport). Source of
  truth for all M1.3+ implementation work. Supersedes the SPEC.md §2
  inline sketch.

## Source — `src/`

- `src/jpegz.zig` — public Zig core API stub. Defines:
  - `version` (string, "0.0.1")
  - `ColorSpace` enum (unknown/grayscale/rgb/ycbcr/cmyk/ycck/srgb/greyscale_jp2)
  - `Image` struct (`pixels`, `width`, `height`, `channels`,
    `bits_per_sample`, `color_space`, `deinit`)
  - `DecodeError` error set (NotImplemented, InvalidMarker,
    UnsupportedPrecision, TruncatedStream, OutOfMemory)
  - `decode(allocator, src) → DecodeError!Image` — stub returns
    `error.NotImplemented`
  - `jpeg2000` namespace with its own `decode(...)` stub
  - inline `test "version is non-empty"`

## Tests — `tests/`

- `tests/unit/smoke.zig` — three tests: version exposed; `decode` stub
  returns `NotImplemented`; `jpeg2000.decode` stub returns
  `NotImplemented`. Imports `jpegz` via the build module.

## Headers / FFI — `include/`

_Not yet created. Phase 1 milestone 7 will add `jpegz_core.h` once the
Zig API is locked._

## Deps — `deps/`

_Not yet vendored. Phase 1 milestone 3 will move `chearon/libjpeg-turbo`
Zig-build fork here from validate, or wire to `pkgs.libjpeg` via system
linkage — TBD during M1.2 brainstorm._
