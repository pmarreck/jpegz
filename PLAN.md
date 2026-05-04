# jpegz — work plan

Mirrors `SPEC.md` §6 (Phase 1) and §1 (Phase 2). Add datetime when ticking
boxes (EST). Keep the last few completed items visible for continuity;
prune older ones once context is no longer load-bearing.

## Phase 1 — wrapper MVP

- [x] **M1.1 — Scaffold + flake.nix.** `flake.nix` with zig 0.15.2,
      libjpeg-turbo 3.1.3 (`pkgs.libjpeg`), openjpeg 2.5.4, hyperfine. Garnix
      will auto-evaluate `packages.default` and `checks.{build,test}`.
      `build.zig` (ReleaseFast default), `src/jpegz.zig` core stub,
      `tests/unit/smoke.zig` green. _(2026-05-04 EST)_
- [x] **M1.2 — Brainstorm SPEC §9 open design questions.** Locked the
      public Zig API, C ABI, error model, and validation report
      structure. Design lives in
      `docs/superpowers/specs/2026-05-04-jpegz-public-api-design.md`.
      _(2026-05-04 EST)_
- [x] **M1.3 — Baseline + progressive wrap (libjpeg-turbo).** TDD-red
      then green: 2×2 baseline RGB + 8×8 progressive RGB fixtures decode
      to correct dimensions / channels / layout. setjmp/longjmp bridge
      to libjpeg's error_exit; `mapColorSpace` translates `J_COLOR_SPACE`
      to public `ColorSpace` + `PixelLayout`. Wrapper lives at
      `src/ffi/libjpeg_wrapper.zig`. _(2026-05-04 EST)_
      _Follow-ups for later milestones: 8-bit gray + 8-bit CMYK +
      12-bit gray fixtures (M1.4 area); pixel-byte oracle equality
      against `djpeg` (will materialize when needed)._
- [ ] **M1.4 — Lossless lift.** Move
      `validate/src/core/jpeg_lossless_decoder.zig` (698 lines, pure Zig)
      into `src/lossless.zig`. Add 16-bit DICOM-style fixtures. Oracle:
      libjpeg-turbo's lossless path (or zigimg lossless, if libjpeg-turbo
      doesn't ship the lossless decoder by default in nixpkgs).
- [ ] **M1.5 — `validate`-only API.** `jpegz.validate(allocator, src) →
      ValidationReport`. Decode through, discard pixels, return report.
      This is the path `validate` actually consumes.
- [ ] **M1.6 — JPEG 2000 wrap (openjpeg).** `jpegz.jpeg2000.decode` calls
      openjpeg via FFI. Fixtures: lossy + 5/3 lossless wavelet + 9/7
      lossless wavelet, tile and codeblock variations. Oracle:
      `opj_decompress`.
- [ ] **M1.7 — C FFI.** Hand-curated `include/jpegz_core.h`. Validate via
      a C smoke test that `jpegz_decode` works end-to-end.
- [ ] **M1.8 — `validate` integration.** Replace its
      `image_validators.zig` libjpeg-turbo direct-FFI block with a jpegz
      call. Replace `jpeg2000_validator.zig` with `jpegz.jpeg2000.validate`.
      Retire `jpeg_validator.zig` (structural-only) per SPEC §7.
- [ ] **M1.9 — `tiffz` integration.** When tiffz hits its milestone 4
      (JPEG-in-TIFF), wire it through jpegz.

## Phase 2 — cleanroom pure-Zig replacement

Each step retires a chunk of the C dep. Failing-test-first throughout.

- [ ] **M2.1 — Baseline cleanroom (sequential DCT, 8-bit).** Most-used
      path; biggest impact. zigimg `src/formats/jpeg.zig` (MIT,
      baseline-only) reading allowed.
- [ ] **M2.2 — Progressive cleanroom.** Builds on baseline DCT; adds
      spectral selection + successive approximation.
- [ ] **M2.3 — Lossless audit.** Audit the lifted decoder against T.81
      §13 + libjpeg-turbo oracle.
- [ ] **M2.4 — 12-bit precision.** Rare but spec-mandatory.
- [ ] **M2.5 — Arithmetic coding (T.81 §F).** Q-coder + conditioning.
      Last among T.81 codecs.
- [ ] **M2.6 — JPEG-LS (T.87).** LOCO-I predictor + Golomb-Rice. Independent
      of T.81 work. charls (Apache-2) reading allowed.
- [ ] **M2.7 — JPEG 2000 (T.800).** Wavelet + EBCOT + tier-1/tier-2.
      Multi-month effort. Confirm patent posture with Peter before
      shipping.

## Curiosity pokes (carry forward)

- _M1.3:_ what does libjpeg-turbo do with truncated streams that have a
  valid SOI but no EOI? `validate` cares deeply about this — the wrapper
  must surface it as FAIL with location, never silently degrade.
- _M1.3:_ Windows + Zig + libjpeg-turbo's setjmp gap (SPEC §3 caveat).
  We don't ship for Windows yet, but the FFI wrapper has to surface
  unavailability as INFO, not silently fall through to a marker walk.
- _M1.6:_ openjpeg's stream-callback API has surprising lifetime rules.
  Need to mirror its `opj_stream_set_user_data_length` carefully or
  decoded images come out truncated.
- _M2.5:_ arithmetic coding fixtures barely exist in the wild — we may
  have to synthesize them via libjpeg-turbo's own arithmetic encoder.

## Recently completed

- 2026-05-04 EST — M1.3 baseline + progressive wrap (libjpeg-turbo) —
  src/ffi/libjpeg_wrapper.zig with setjmp/longjmp error bridge;
  jpeg_mem_src → jpeg_read_header → jpeg_start_decompress →
  jpeg_read_scanlines loop. Fixtures: tests/unit/fixtures/baseline_2x2_rgb.jpg
  (690 B) + progressive_8x8_rgb.jpg (520 B). flake.nix keeps
  NIX_CFLAGS_COMPILE / NIX_LDFLAGS so Zig finds libjpeg's headers.
  All 14 tests green via nix flake check.
- 2026-05-04 EST — M1.2 design lock — public Zig API + C ABI + error
  model + validation report structure. Doc:
  `docs/superpowers/specs/2026-05-04-jpegz-public-api-design.md`.
  Trichotomy: decode / decodeStreamingRows (sequential only) / validate.
  `[]const u8` parameter type (per validate inbox). Build-generated
  C errno header (tiffz pattern).
- 2026-05-04 EST — M1.1 scaffold (flake.nix, build.zig, src/jpegz.zig
  stub, tests/unit/smoke.zig, ./build, ./test, ./bm, PLAN.md,
  CODE_MINIMAP.md, PROJECT_OVERVIEW.md).
