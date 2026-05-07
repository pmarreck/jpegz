# jpegz — work plan

**Mission recap.** jpegz is the spec-complete JPEG family decoder for
the Zig ecosystem. Zig stdlib has no native JPEG support; zigimg's
`src/formats/jpeg.zig` is 322 lines, baseline-only, not spec-complete.
jpegz fills that gap. **End state: pure Zig, zero C deps in the
shipped binary**, full T.81 / T.87 / T.800 coverage including the
arithmetic-coded and lossless modes the wider ecosystem skips.

Phase 1 (wrapper) was scaffolding to unblock validate + tiffz in days
instead of weeks. The wrapper milestones are DONE; the actual product
is the cleanroom Zig implementation, with libjpeg-turbo and openjpeg
demoted to `tests/oracles/` for byte-equal verification.

Date format: tick boxes with `_(YYYY-MM-DD EST)_`. Keep the last few
completed items for continuity; prune older ones when context is no
longer load-bearing.

## Phase 1 — wrapper MVP (DONE — scaffolding)

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
- [x] **M1.4 — Lossless lift (8-bit).** _Discovery: validate's
      `jpeg_lossless_decoder.zig` is a validator, not a pixel-emitting
      decoder. It has primitives (BitReader / HuffmanTable /
      decodePixelDifference) but no full raster reconstruction loop._
      Pivoted: libjpeg-turbo 3.1.4 transparently handles SOF3 lossless
      via the same `jpeg_read_scanlines` API used for SOF0/1/2 — no code
      change beyond fixture + test. 4×4 8-bit grayscale lossless fixture
      decodes round-trip-exact. _(2026-05-05 EST)_

- [x] **M1.4b — Lossless 9..16-bit (DICOM/DNG path).** libjpeg-turbo
      3.x's `jpeg_read_header` always populates `cinfo.data_precision`;
      branch on that AFTER the standard read_header / start_decompress
      to call `jpeg12_read_scanlines` (J12SAMPLE = signed short) or
      `jpeg16_read_scanlines` (J16SAMPLE = unsigned short). Output is
      `[]u8`-aliased `[]u16` host-endian as the design specified.
      Per tiffz handoff: precision range now accepts any 1..16
      (routes 1..8/9..12/13..16 to the matching scanline API), not
      strict 8/12/16 — DNG raw is commonly 14-bit which would have
      been rejected. Fixtures: 4×4 12/14/16-bit gray lossless, all
      round-trip byte-exact. _(2026-05-06 EST)_
- [x] **M1.5 — `validate`-only API.** Hand-written marker walker in
      `src/core/validator.zig` (pure Zig, no FFI). Walks SOI → segments
      → SOS → entropy → EOI, classifies variant from SOFn, accumulates
      findings (does NOT fail-fast). Six green tests covering clean
      baseline / progressive / lossless and three failure modes
      (truncation, missing SOI, garbage input). _(2026-05-05 EST)_
      _Codec-level integrity (run libjpeg-turbo decode and capture
      failures as findings) deferred to M1.5b once we have a real
      consumer scenario asking for it; current walker catches all
      structural issues without it._
- [x] **M1.6 — JPEG 2000 wrap (openjpeg).** TDD-red→green. Custom
      memory stream (read/skip/seek callbacks over `MemSource`),
      auto-detect JP2 box vs raw J2K codestream, OPJ_INT32 → packed
      `[]u8` (or `[]u16` for >8-bit). 8×8 RGB lossy fixture decodes
      with all components within 16 of input values. _(2026-05-05 EST)_

- [x] **M1.5c — APPn presence + trailing-data findings.** Per
      validate handoff (2026-05-06): added 4 new `FindingCode`
      entries (`jfif_metadata_present`, `xmp_metadata_present`,
      `photoshop_irb_present`, `trailing_data_after_eoi`) and wired
      `classifyAppSignature` into the marker walker (matches APP0
      JFIF/JFXX, APP1 Exif/XMP, APP2 ICC, APP13 Photoshop IRB).
      Trailing data after EOI emits `.info` with the offset of the
      first stray byte. validate's metadata pipeline gets these for
      free without a parallel marker walk. _(2026-05-06 EST)_

- [x] **M1.6b — JP2 lossless 5/3 + lossy 9/7 fixtures.** Both wavelet
      modes round-trip cleanly through the openjpeg wrapper without
      any code changes — lossless 5/3 byte-exact, lossy 9/7 within
      16/255 tolerance. _(2026-05-06 EST)_

- [ ] **M1.6c — JP2 component subsampling.** Currently the wrapper
      errors out (BackendError) when components have differing
      dx/dy. Real-world JP2 in the wild rarely subsamples (MCT is the
      common path). Add nearest-neighbor upsample if a real consumer
      hits this.
- [x] **M1.7 — C FFI.** Hand-curated `include/jpegz_core.h` plus
      auto-generated `include/jpegz_errno.h` (from
      `tools/gen_c_header.zig` walking `src/core/errors.zig` at
      comptime). All 8 `jpegz_*` exports visible in libjpegz.a;
      `tests/cli/smoke.c` (using C23 `#embed`) decodes the baseline
      fixture, validates it, exercises the empty-input error path —
      8 assertions, 4 FFI calls, all pass. _(2026-05-05 EST)_
- [~] **M1.8 — `validate` integration — handoff complete.** Concrete
      patch dropped at `~/Documents-CloudManaged/validate/inbox/2026-05-06-jpegz-integration-recipe.md`:
      flake.nix patch, build.zig patch, full `jpegz_shim.zig` shim
      file, step-by-step call-site flip plan
      (`image_validators.zig` → `pdf_image_validator.zig` →
      `video_validator.zig` → `scientific_validators.zig`), and
      retire-`jpeg_validator.zig` plan per SPEC §7. Cross-project
      execution belongs in a validate session. _(2026-05-06 EST)_

- [~] **M1.9 — `tiffz` integration — handoff complete.** Concrete
      patch dropped at `~/Documents-CloudManaged/tiffz/inbox/2026-05-06-jpegz-integration-recipe.md`:
      flake.nix patch, build.zig patch, sketch of `decodeJpegStrip`
      with `spliceJpegTables` helper for TIFF tag 347 (abbreviated
      tables), error mapping. tiffz's M4 (JPEG-in-TIFF) hasn't shipped
      yet so there's nothing to flip — recipe is greenfield. DNG raw
      compatibility (16-bit lossless via M1.4b) called out
      explicitly. _(2026-05-06 EST)_

## Tier 1 — wrapper coverage verification (oracle prep for Phase 2)

These are claims Phase 1 makes ("we support arithmetic / restart
markers / CMYK / grayscale / subsampled YCbCr") that aren't actually
covered by fixtures yet. TDD-red first: write the test, see whether
libjpeg-turbo + our wrapper handle the case. Each fixture becomes
a Phase 2 oracle test (the cleanroom decoder must produce byte-equal
output to libjpeg-turbo for these inputs).

- [x] **T1.1 — Arithmetic-coded baseline JPEG fixture** (SOF9). All
      green; libjpeg-turbo decodes via the same scanline path. _(2026-05-06 EST)_
- [x] **T1.2 — JPEG with restart markers fixture.** DRI=2 every 2
      MCUs; `skipEntropyData`'s RST handling exercised end-to-end. _(2026-05-06 EST)_
- [x] **T1.3 — CMYK JPEG fixture.** ImageMagick-generated; 4-channel
      layout + APP14 Adobe colorspace handled. _(2026-05-06 EST)_
- [x] **T1.4 — Grayscale baseline JPEG fixture.** 1-channel layout +
      `JCS_GRAYSCALE` source mapping verified. _(2026-05-06 EST)_
- [x] **T1.5 — Subsampled YCbCr JPEGs** (4:2:0, 4:2:2). libjpeg-turbo
      upsamples on output; consumer sees uniform RGB. _(2026-05-06 EST)_
- [x] **T1.6 — JP2 component subsampling.** Real fix shipped in
      openjpeg_wrapper.zig: image dim = `ceil(canvas_extent / min_dx)`,
      per-component sampling at `cx = (x * min_dx) / comp.dx`. Two
      fixtures: isotropic dx=2 (IM `-sampling-factor 4:2:0`) AND true
      asymmetric 4:2:0 (ffmpeg `-pix_fmt yuv420p`, Y=1×1 / Cb,Cr=2×2).
      Both round-trip cleanly. _(2026-05-06 EST)_

## Phase 2 — cleanroom pure-Zig replacement (the actual goal)

**This is what jpegz exists to be.** Phase 1 wrappers were scaffolding;
Phase 2 retires every C dep, leaving a single static library with no
runtime C dependency. libjpeg-turbo and openjpeg move from
`buildInputs` to `tests/oracles/` — used to verify our cleanroom output
byte-for-byte, never linked into the shipped binary.

Each Phase 2 milestone retires a chunk of the C dep. TDD throughout:
the Tier 1 fixtures (above) provide the oracle expectations; the
cleanroom impl must produce byte-equal output for every fixture. Order
chosen to maximize impact per milestone (most-used codec first; share
machinery where possible).

- [~] **M2.1 — Baseline cleanroom (sequential DCT, 8-bit).** Started
      2026-05-06: bitstream reader (FF-stuffed, MSB-first), DHT-driven
      Huffman decoder (8-bit fast lookup + slow path for codes 9..16),
      direct-formula 8×8 IDCT (T.81 §A.3.3 inverse formula), and
      top-level decoder integrating DQT/DHT/SOF0/SOS marker parse +
      MCU loop with zig-zag dequant + IDCT + grayscale/YCbCr-to-RGB
      output. Dispatcher in src/jpegz.zig routes matching SOF0 inputs
      to cleanroom; falls back to libjpeg wrapper for unsupported
      features (subsampling != 1×1, restart markers, multi-component
      with non-uniform sampling). Verified end-to-end on the 4×4 8-bit
      grayscale baseline fixture (proof-of-life via debug print
      confirmed cleanroom path was entered). 76/76 tests green via
      nix flake check.

      **2026-05-07 update — second working slice landed:**
      - [x] **3-component RGB 4:4:4 (no subsampling)** via cleanroom.
            Generated fixture `baseline_4x4_rgb_444.jpg` with
            `cjpeg -sample 1x1`; multi-component MCU iteration +
            JFIF YCbCr→RGB conversion verified (all pixels within
            ±20 of input).
      - [x] **Chroma subsampling 4:2:0 / 4:2:2** via cleanroom.
            Rewrote MCU loop for variable per-component sampling
            factors; `decodeBlock` now takes plane / plane_w /
            block_x / block_y so the same routine handles every
            component layout. `assembleOutput` does nearest-neighbor
            chroma upsampling via `sampleComponent(plane, h_factor,
            v_factor, max_h, max_v)`. Both 4:2:0 and 4:2:2 fixtures
            now decode through cleanroom with ±25 tolerance per
            channel.
      - [x] **Restart markers (DRI / RSTm)** via cleanroom. DRI
            (0xDD) parsed to `restart_interval`; MCU loop resyncs
            every N MCUs by validating the next RSTm marker (cycles
            0..7), resetting `prev_dc`, and re-initializing the
            BitReader past the marker. 16×16 fixture with DRI=2
            (8 MCUs total → 4 RSTs interspersed) decodes correctly.

      **12-bit DCT (SOF1, T.81 §A.4.1):**
      - [x] **Wrapper-level support shipped** today: cjpeg
            `-baseline -precision 12` emits SOF1 (NOT SOF0); the
            existing libjpeg_wrapper's M1.4b precision range
            (1..16 → jpeg/jpeg12/jpeg16 routing) handles it for any
            SOF including SOF1. New fixture
            `baseline_4x4_gray12_dct.jpg` decodes to a 12-bit
            `[]u16`-aliased Image with values within 200/4095 of
            input. _(cleanroom SOF1 12-bit DCT decode is a separate
            future milestone — needs 12-bit IDCT and `[]u16` plane
            storage; not in M2.1 scope.)_

      **What still falls back to libjpeg-turbo for SOF0 cleanroom:**
      - SOF1 (extended sequential — including 12-bit DCT)
      - SOF2 (progressive) → M2.2
      - SOF3 (lossless) → M2.3 (uses `jpeg{,12,16}_read_scanlines`)
      - SOF9/10/11 (arithmetic) → M2.5
      - 4-component CMYK input → unaddressed (rare)
- [ ] **M2.1c — Cleanroom robustness against real-world corpus.**
      Discovery 2026-05-07: ran `cleanroom-diff` (new analysis tool
      under `scratch/`, gitignored) over Peter's 4,125-JPEG corpus
      at `/Volumes/Fileserver/clips-image/`. Result with ±4 LSB
      tolerance:
        - CLEAN-OK         63   (1.5%)
        - CLEAN-DIV       962  (23.3%) — pixels diverge >4 LSB
        - WRAP-ONLY       277   (6.7%) — cleanroom NotImplemented (correct)
        - CLEAN-ERR     2,823  (68.4%) — cleanroom raised an error
        - WRAP-ERR          0   (0.0%) — wrapper handled every file
      Synthetic fixtures (cjpeg-generated uniform-color test inputs)
      pass cleanly through cleanroom; real-world JPEGs reveal systematic
      bugs the synthetic tests don't exercise (likely interaction with
      large APPn segments / DRI placement / less-trivial Huffman tables
      / image dims not multiples of MCU). Fixing requires a targeted
      debug session on individual error cases. Most common error is
      `BackendError` (entropy-decode); some `InvalidMarker`,
      `TruncatedStream`. NEXT SESSION: pick 5–10 representative
      CLEAN-ERR files, attach error-source context, fix root causes one
      at a time.

- [~] **M2.2 — Progressive cleanroom.** Started 2026-05-07. Module
      `src/decode/progressive.zig` written end-to-end:
      - Persistent per-component coefficient buffers
        (mcu_cols × h_factor × mcu_rows × v_factor blocks × 64 i16)
      - Multi-scan marker walker (loops SOS until EOI)
      - All 4 scan-type variants implemented per T.81 §G.1.2:
        DC first-pass (Ah=0), DC refinement (Ah>0),
        AC first-pass (Ah=0, with EOB-run extension),
        AC refinement (Ah>0, with sign-preserving 1-bit refinement
        and EOB-run carry-over)
      - Final pass: dequantize zig-zag → un-zig-zag → IDCT → YCbCr→RGB
      Currently NOT wired into dispatch in src/jpegz.zig — output
      doesn't match the wrapper byte-for-byte on the simplest 8×8
      grayscale fixture (6-scan progressive). Likely culprits in
      AC-refinement walk-forward logic (ZRL semantics) or the
      multi-scan byte-position handoff. Iteration to pixel-equality
      is the M2.2-complete checkpoint; current commit is WIP.
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

- 2026-05-06 EST — M1.8 + M1.9 handoff recipes — concrete integration
  patches dropped in validate/inbox/ and tiffz/inbox/. Each contains
  the exact flake.nix + build.zig changes, the shim file in full,
  and step-by-step call-site flip plan (validate) or greenfield
  decodeJpegStrip sketch with JPEGTables splice helper (tiffz). Both
  acknowledge cross-project boundary; execution lives in the consumer
  project's session.
- 2026-05-06 EST — M1.4b 12/16-bit lossless + M1.5b codec-integrity +
  M1.6b JP2 lossless 5/3 + lossy 9/7 fixtures (one combined commit) —
  cinfo.data_precision branch in libjpeg_wrapper for jpeg12_/jpeg16_
  read paths; validateCodecIntegrity decodes-through with no pixel
  materialization and maps libjpeg msg_code → FindingCode; both JP2
  wavelet modes round-trip without code change. 28/28 tests green.
- 2026-05-05 EST — M1.7 C FFI — include/jpegz_core.h (curated) +
  include/jpegz_errno.h (auto-generated from src/core/errors.zig at
  build time via tools/gen_c_header.zig). src/ffi/c_api.zig has
  exhaustive toCStatus mapper (compile-time error if a Zig variant
  goes un-mapped). 8 jpegz_* exports verified via nm. C smoke test
  uses C23 #embed to inline the fixture; 8 assertions pass.
- 2026-05-05 EST — M1.6 JPEG 2000 wrap (openjpeg) — custom memory
  stream over MemSource (read/skip/seek callbacks), JP2-vs-J2K
  magic-byte autodetect, OPJ_INT32 → []u8 (or host-endian []u16)
  packing. 8×8 lossy RGB fixture round-trips within 16/255 of input.
  23/23 tests green.
- 2026-05-05 EST — M1.5 validate-only API — hand-written marker walker
  in src/core/validator.zig (pure Zig, no FFI). Walks SOI/segments/SOS/
  entropy/EOI, accumulates findings, never fails-fast. 6 green tests:
  baseline/progressive/lossless clean PASS plus truncation/missing-SOI/
  garbage FAIL paths. 20/20 tests across the whole suite.
- 2026-05-05 EST — M1.4 lossless lift (8-bit) — libjpeg-turbo 3.1.4
  handles SOF3 transparently via the same scanline API. 4×4 8-bit gray
  fixture round-trips byte-exact. Investigation revealed validate's
  decoder is a validator (no full raster loop); 12/16-bit lossless
  punted to M1.4b (libjpeg's jpeg16_* API).
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
