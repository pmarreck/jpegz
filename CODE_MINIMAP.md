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

- `src/jpegz.zig` — public Zig core API. Re-exports
  `DecodeError` / `Severity` / `Variant` / `FindingCode` from
  `core/errors.zig`. Defines public types:
  - `version` (string, "0.1.0")
  - `ColorSpace` (8-variant enum: source-encoded color space)
  - `PixelLayout` (grayscale | rgb | cmyk — what the buffer contains
    after conversion)
  - `Image` struct (`pixels`, `width`, `height`, `channels`,
    `bits_per_sample`, `source_color_space`, `layout`,
    `rowStride()`, `pixelsU16()`, `deinit(allocator)`)
  - `ImageMetadata` (the same minus `pixels` — returned by
    streaming-rows path)
  - `RowCallback` (struct of `on_row: anyerror!void` + `ctx`)
  - `Finding` (severity + code + offset + detail)
  - `ValidationReport` (overall + variant + dimensions + findings;
    `isValid()`, `deinit(allocator)`)
  - Public functions: `decode`, `decodeStreamingRows`, `validate`,
    `jpeg2000.decode`, `jpeg2000.validate`. `decode` delegates to
    `ffi/libjpeg_wrapper.decode` (M1.3); the streaming and validate
    paths are stubbed pending M1.5+.

- `src/core/errors.zig` — single source of truth for error
  vocabulary. Numeric values stable forever (wire format). Defines
  `DecodeError`, `Severity`, `Variant`, `FindingCode`. Header
  generator (M1.7) reads this at comptime; FFI mapper (M1.7) is an
  exhaustive switch — drift is impossible.

- `src/core/validator.zig` — hand-written marker-chain walker (M1.5).
  Pure Zig, no FFI. Public `validate(allocator, data)` walks
  SOI/segments/SOS/entropy/EOI, classifies the variant from SOFn,
  emits findings (missing markers, truncation, bad lengths, precision
  issues, arithmetic-coding info, etc.). Designed to be the seed for
  Phase-2 cleanroom parsing — its marker-parse machinery will be
  shared once the cleanroom decoder lands codec by codec.

- `src/ffi/libjpeg_wrapper.zig` — Phase 1 wrapper around
  libjpeg-turbo (BSD-3) for SOF0/1/2 (baseline / extended sequential
  / progressive). cImport `jpeglib.h`. setjmp/longjmp error bridge
  via `ErrorBridge` (extends `jpeg_error_mgr` with a `jmp_buf`).
  `mapColorSpace` / `mapSourceColorSpace` translate libjpeg's
  `J_COLOR_SPACE` to public `ColorSpace` + `PixelLayout`.
  `classifyLibjpegError` maps libjpeg `msg_code` into `DecodeError`.

## Tests — `tests/`

- `tests/unit/smoke.zig` — public-API wiring smoke tests. Confirms
  version, `decode` rejects empty input, `jpeg2000.decode` is still
  stubbed, validate stub returns empty PASS report,
  `decodeStreamingRows` is stubbed, `FindingCode` numeric values
  stable.
- `tests/unit/decode.zig` — M1.3 decode tests. Imports baseline +
  progressive fixtures via `@embedFile`. Asserts dimensions,
  channels, layout, source color space, and rough pixel-quality
  sanity (white pixel stays white).
- `tests/unit/fixtures/baseline_2x2_rgb.jpg` — 2×2 RGB baseline JPEG
  generated via `cjpeg -quality 90 -baseline` (690 B).
- `tests/unit/fixtures/progressive_8x8_rgb.jpg` — 8×8 RGB progressive
  JPEG generated via `cjpeg -progressive -quality 85` (520 B).
- `tests/unit/validate.zig` — M1.5 validate suite. Six tests covering
  clean PASS for baseline/progressive/lossless plus FAIL for
  truncation, empty input, and non-JPEG bytes.
- `tests/unit/fixtures/lossless_4x4_gray8.jpg` — 4×4 8-bit grayscale
  lossless (SOF3) JPEG generated via `cjpeg -lossless 1` (69 B).
  All input pixels are 0x80; round-trip-exact decode confirms the
  lossless property.

## Headers / FFI — `include/`

_Not yet created. Phase 1 milestone 7 will add `jpegz_core.h` once the
Zig API is locked._

## Deps — `deps/`

_Not yet vendored. Phase 1 milestone 3 will move `chearon/libjpeg-turbo`
Zig-build fork here from validate, or wire to `pkgs.libjpeg` via system
linkage — TBD during M1.2 brainstorm._
