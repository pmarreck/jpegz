# jpegz — work plan

**Mission recap.** jpegz is the spec-complete JPEG family decoder for
the Zig ecosystem. Zig stdlib has no native JPEG support; zigimg's
`src/formats/jpeg.zig` is 322 lines, baseline-only, not spec-complete.
jpegz fills that gap. **End state: self-contained Zig decoders, zero
*system* C deps in the shipped binary**, full T.81 / T.87 / T.800
coverage including the arithmetic-coded and lossless modes the wider
ecosystem skips. **Provenance (canonical: `LICENSING_NOTES.md`):** the
entropy/structural, lossless (§H), JPEG-LS (T.87) and arithmetic (Annex D)
layers are cleanroom Zig; the DCT DSP kernels (islow IDCT, color conversion,
upsampling) are pure-Zig **ports** of libjpeg-turbo (IJG License — inherited
libjpeg code); T.800 (JPEG 2000) is a pure-Zig **port** of openjpeg (BSD-2) via
jp2z. JPEG/JPEG-LS need no required libjpeg/CharLS runtime dep; the JP2 path
links a vendored openjpeg at runtime until the jp2z cutover.

Phase 1 (wrapper) was scaffolding to unblock validate + tiffz in days
instead of weeks. The wrapper milestones are DONE; the actual product
is the self-contained Zig implementation (cleanroom entropy/lossless/
JPEG-LS/arithmetic core; BSD-attributed libjpeg-turbo ports for the DCT DSP
kernels; a BSD-attributed openjpeg port, via jp2z, for T.800), with
libjpeg-turbo and openjpeg demoted to `tests/oracles/` for byte-equal
verification.

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
- [x] **M2.1c — Cleanroom robustness against real-world corpus** —
      *completed 2026-05-07 5pm EST*. Started 1.5% pixel-perfect; ended
      99.7% pixel-perfect with max delta ≤ 2 LSB across the entire
      4,125-JPEG corpus. Final state:

        - CLEAN-OK     3,837  (93.0%) — within ≤2 LSB of libjpeg-turbo
        - CLEAN-DIV        0  (0.0%)  — eliminated entirely
        - WRAP-ONLY      277  (6.7%)  — progressive routes to wrapper
        - CLEAN-ERR       11  (0.3%)  — 2 non-JPEG mislabels + 9 truncated files
        - WRAP-ERR         0

      Of the 3,848 baseline JPEGs the cleanroom handles directly:
      **3837/3848 = 99.7% match libjpeg-turbo to within ≤2 LSB**.

      Six commits this session on yolo:
        1. `b08794b` — `BitReader.seekToMarker()`/`skipPastMarker()` for
           in-place RST handling.
        2. `5269b07` — i32 coefficient pipeline + Huffman short-buffer
           path (Debug-mode panics → clean errors).
        3. `557569b` — **THE BUG**: canonical Huffman slow-path table
           builder skipped `<<= 1` on zero-count lengths. `max_code[15]`
           was off by 4× for the standard luma AC table. Single-line
           fix; collapsed CLEAN-ERR 2257 → 13.
        4. `17e70d3` — IJG fancy chroma upsampling (H2V2/H2V1/V2H1)
           with active-frame boundary clamping. CLEAN-DIV 3127 → 7.
        5. `644ad58` — extraneous-bytes-before-marker tolerance
           (djpeg parity); non-interleaved scans use 1-block MCUs per
           T.81 §A.2.2.
        6. `54463e4` — libjpeg-turbo "islow" integer IDCT (jidctint.c)
           and jdcolor.c fixed-point YCbCr→RGB. CLEAN-DIV 7 → 0.

      Remaining 11 CLEAN-ERR are out-of-scope:
        - `consumerwhore.jpg` is a PNG with .jpg extension.
        - `Pakistan International ...jpg` is a GIF with .jpg extension.
        - 9 PlayBoy files are truncated downloads (all exactly 35,688
          bytes). libjpeg-turbo recovers with "Premature end of JPEG"
          warning; we error out (strict-validator behavior is correct
          here). Tolerance can be added behind a flag if a future
          consumer wants it.

- [x] **M2.2 — Progressive cleanroom (SOF2, 8 + 12-bit).** Shipped
      2026-05-08, wired into dispatch in `src/jpegz.zig`. Module
      `src/decode/progressive.zig` covers all 4 scan-type variants
      per T.81 §G.1.2 (DC first/refine, AC first/refine with EOB-run
      and sign-preserving 1-bit refinement), DRI > 0 (restart markers
      in progressive), 1- and 3-component scans at both 8-bit and
      12-bit precision, all 4 chroma sampling factors (4:4:4, 4:2:2,
      4:2:0, 4:4:0), IJG-compatible fancy chroma upsampling.

      **2026-05-16 sweep + PASS1_BITS fix — every DCT fixture is now
      byte-perfect vs libjpeg-turbo wrapper:**
        - 8-bit progressive (3 fixtures: gray, RGB, DRI): max_delta = 0.
        - 12-bit progressive (gray + RGB at 4 sampling factors): max_delta = 0.
        - 12-bit baseline DCT (gray + RGB at 4 sampling factors): max_delta = 0.

      Root cause of the residual 12-bit deltas was a single one-bit
      shift constant: libjpeg-turbo's `jidctint.c` defines
      `PASS1_BITS = 2` at `BITS_IN_JSAMPLE == 8` and `PASS1_BITS = 1`
      at higher precisions ("lose a little precision to avoid
      overflow", lines 102-108). Our cleanroom IDCT hardcoded 2 for
      both. Parameterizing `pass1Bits(P)` (= 2 at P=8, 1 at P=12)
      brought 13 DCT fixtures from 93-98% exact up to 100% across the
      board. All previous ≤2-4 LSB tolerance gates tightened to == 0;
      one consolidated regression test sweeps all 13 fixtures.

      Validation history: against 276 real-world progressive JPEGs
      from Peter's corpus on 2026-05-08, 199 byte-perfect / 77 within
      ≤2 LSB sub-pixel rounding. Six bug fixes shipped during that
      iteration: end-of-scan marker (markerHit→seekToMarker), libjpeg
      `insufficient_data` parity, AC refinement ZRL break semantics
      (libjpeg's `--r < 0`), float→fixed-point YCbCr, single-component
      scan iteration via T.81 §A.2.4 xi/yi, IJG fancy chroma upsample.

      Remaining NotImplemented gates (intentional fall-through to
      wrapper): 4-component (CMYK) progressive — no real-world demand,
      no fixture in tree. _(2026-05-08 EST; sweep 2026-05-16 EST)_
- [x] **M2.3 — Lossless audit.** Audited 2026-05-16. The lossless
      cleanroom in `src/decode/lossless.zig` is actually a full pure-
      Zig implementation of T.81 §H predictive coding — not a "lifted"
      port. Sweep result: **all 13 lossless fixtures byte-perfect** vs
      libjpeg-turbo wrapper:
        - precision 8 / 12 / 14 / 16 grayscale,
        - 8-bit RGB 3-component,
        - 16×16 with DRI > 0 (restart markers),
        - all 7 predictors (Ss = 1..7) tested independently.
      Already covered by M2.4–M2.8 byte-equality regression tests.
      Stale docstring and dispatcher comment refreshed.
      Remaining gates fall through to wrapper for non-1×1 sampling
      factors and point transform Al > 0 — no fixtures in tree, no
      real-world demand. _(2026-05-16 EST)_
- [ ] **M2.4 — 12-bit precision.** Rare but spec-mandatory.
- [x] **M2.5 — Arithmetic coding (T.81 §F).** Q-coder + conditioning
      shipped 2026-05-13 (SOF9 sequential) and 2026-05-15 (SOF10
      progressive). All 10 arithmetic fixtures decode byte-identically
      to libjpeg-turbo:
        - SOF9 gray + RGB at 4:4:4 / 4:2:0 / 4:2:2 / 4:4:0: max_delta = 0.
        - SOF10 gray + RGB at 4:4:4 / 4:2:0 / 4:2:2 / 4:4:0: max_delta = 0.

      Root cause of the residual ≤2 LSB delta on subsampled-RGB
      (2026-05-16): NOT the arithmetic decoder (a `jpeg_read_coefficients`
      coef-diff confirmed 0 divergent coefs). The actual bug was in the
      8-bit `color.fancyUpsample` / `baseline.fancyUpsample` chroma
      upsamplers — they used SYMMETRIC rounding bias (+8/+8 for H2V2,
      +2/+2 for H2V1/H1V2). libjpeg-turbo's `jdsample.c` uses
      ASYMMETRIC bias (+8/+7 and +1/+2) so each 2-pixel output pair
      cancels its own rounding error. Porting the same convention
      (which 12-bit `fancyUpsample12` already had — why 12-bit Huffman
      subsampled was byte-perfect) collapsed the delta to 0 across:
        - All 8 arith subsampled-RGB fixtures (4:2:0/4:2:2/4:4:0).
        - The new `baseline_16x16_rgb_420.jpg` regression fixture.
        - The existing 8x8 yuv420/yuv422 Huffman fixtures (already 0
          by content coincidence; now locked in).
      Previous ≤2..4 LSB tolerance gates tightened to == 0.
      _(2026-05-16 EST)_
- [~] **M2.6 — JPEG-LS (T.87).** LOCO-I predictor + Golomb-Rice cleanroom
      shipped 2026-05-16: marker walker (SOI/SOF55/LSE/SOS/EOI), bit-stuffed
      reader (T.87 §A.1.3), context quantization + sign canonicalization
      (q1*9+q2)*9+q3 ∈ [-364, 364], MED predictor, Golomb-Rice with k=0
      sign trick and escape branch, full A/B/C/N state update with bias
      correction, run mode (J-table, RItype 0/1 interrupt for mono, ctx[0]
      always for triplet), 8-bit + 16-bit mono and RGB sample-interleaved,
      NEAR > 0 near-lossless. Direct-entry tests
      (`jpegz.jpegls_cleanroom_decode`) round-trip 5 fixtures bit-exact /
      within-NEAR. Open: ILV=1 line-interleaved, RST markers in JPEG-LS
      (rare), 4-component quad. charls (BSD-3, vendored) still wired as
      fallback for variants the cleanroom doesn't cover. _(2026-05-16 EST)_
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

## Future — reclaim a cleanroom DCT path (evaluate; not committed)

Provenance audit (2026-06-30, per Einstein) found the production DCT DSP
kernels are libjpeg-turbo PORTS, not cleanroom: islow IDCT
(`idct8x8`/`idct8x8Generic`, from jidctint.c/jidct12.c), YCbCr→RGB color
conversion (`ycbcrRowToRgb`, from jdcolor.c), fancy chroma upsampling, and
CMYK/YCCK. Docs now describe these accurately as ports (BSD-3, attributed
in THIRD_PARTY_NOTICES.md). Peter's call: **accurate now, reclaim later.**

- [ ] Evaluate swapping production to the cleanroom `idct8x8_fpd` (T.81
      Annex A) + writing color conversion / upsampling from the JFIF/T.871
      spec equations, to make the DCT path genuinely cleanroom.
- [ ] **Byte-divergence analysis FIRST:** islow ≠ ideal Annex A IDCT, so
      output would no longer byte-match libjpeg — this breaks the
      byte-exact oracle tests and may affect downstream tiffz/validate
      (which were built around byte-identity). Quantify the delta and
      coordinate with Einstein (cross-board) + tiffz/validate before any
      swap. Likely means oracle tests move to a tolerance bound.

## In progress — wire dormant T.81 finding codes (validation strictness)

Goal: a strict validator must surface table/structure-level spec
violations a permissive library swallows. ~12 declared `FindingCode`s are
dormant (never emitted). Wiring each as a classifier-over-sets test
(corrupt-fixture fires, clean-fixture silent). Batch 1 = structural codes
addable in the marker walker (`core/validator.zig`):

- [x] `quantization_table_corrupt` — DQT §B.2.4: Pq∈{0,1}, Tq∈{0..3} (2026-06-21)
- [x] `sof_component_count_invalid` — SOF §B.2.2: Nf>=1 && seg_len==8+3Nf (2026-06-21)
- [x] `sos_component_mismatch` — SOS §B.2.3: each Cs ∈ SOF component IDs (2026-06-21)
- [x] `arithmetic_table_corrupt` — DAC §B.2.4.3: Tc∈{0,1}, Tb∈{0..3} (2026-06-21)
- [x] `progressive_scan_invalid` — SOF2 SOS Ss/Se/Ah/Al (2026-06-21)
- [x] `lossless_predictor_invalid` — SOF3 SOS Ss (predictor) 1..7 (2026-06-21)
- [x] `lossless_pointtransform_invalid` — SOF3 lossless Ah must be 0 (2026-06-21)
- [x] `progressive_scan_count` (info) + `embedded_thumbnail_present` (info) (2026-06-21)

Deferred (need decode-path/JPEG-LS work, not marker walk):
`jpegls_invalid_run_mode`, `jpegls_context_table_invalid` (dct_coefficient_overflow DONE 2026-07-01 via IDCT crash #9 fix). JP2 codes are option B (un-stub
`jpeg2000.validate`) — separate.

## Recently completed

- 2026-07-01 EST — Fixed IDCT overflow PANIC on malformed input (validate fuzz
  crasher #9, paid-chain critical path). idct8x8Generic wraps via
  @{add,sub,mul,shl}WithOverflow (C-faithful, byte-exact w/ oracle) instead of
  panicking, and reports overflow -> baseline/progressive/arith emit dormant
  code 58 dct_coefficient_overflow (crash -> validator signal; zero ABI change).
  Reproduced from validate DNG artifact; 143-byte regression fixture
  (overflow_ac_8x8.jpg) committed. yolo @ 074ccb3a.
  FOLLOW-UP: a separate pre-existing Debug-only integer overflow in
  jpegls_codec.zig:118 (setDefaultThresholds) surfaced during repro; harmless
  in ReleaseFast; flagged to Einstein as a possible separate fuzz target.

- 2026-06-21 EST — Seed the zigDeps FOD into the native build/test checks
  (the actual Linux CI fix). The lazy-dep change alone did NOT green Garnix
  Linux — CI still failed with the same `openjpeg_src` `NameServerFailure`.
  Empirically (CI is ground truth; my macOS local tests were confounded by
  the darwin sandbox having network), Zig's manifest resolution still reaches
  the vendored openjpeg's `openjpeg_src` URL dep in the network-less Linux
  sandbox. Fix: copy the `zigDeps` FOD into `ZIG_GLOBAL_CACHE_DIR` in both
  `mkJpegzPackage` and `jpegzTestCheck` buildPhases (the exact pattern the
  cross-windows check uses — and that check already passes on Garnix Linux,
  which is the proof the pattern works there). The `.lazy` change stays: it
  spares module consumers (tiffz/validate building jpegz) the eager fetch.
- 2026-06-21 EST — Fix Linux CI regression from openjpeg vendoring (lazy dep).
  Garnix had been RED on x86_64-linux + aarch64-linux `build`/`test` since
  6063dac9 (the openjpeg vendoring) — missed because local `./test` on macOS
  passed (darwin nix sandbox allows network; Linux sandbox does not). Root
  cause: the vendored `.openjpeg` dep was **non-lazy** and linked via
  `b.dependency`, so Zig fetched `openjpeg_src` from GitHub at manifest
  resolution **even on the native system-openjpeg path** (which never links
  it) → `NameServerFailure` in the network-less Linux sandbox. Fix: mark the
  dep `.lazy = true` in build.zig.zon and use `b.lazyDependency` in build.zig,
  so `openjpeg_src` is fetched only on the cross path that actually links the
  vendored lib. Proven locally: native build into a fresh Zig cache →
  BUILD_EXIT=0 with an empty cache `/p` (nothing fetched), despite network
  being available; cross-windows still links (FOD `--fetch=all` still pulls
  the lazy dep; zigDepsHash unchanged). Also fixes eager fetches for module
  consumers (tiffz/validate building jpegz).
- 2026-06-18 EST — Mode-2 (JPEGTables-spliced) RGB-by-component-ID parity.
  validate found the cleanroom decoding a Mode-2 JPEG-in-TIFF strip
  (`tiffz/rgb-jpeg.tif`, spliced per TN2) to a uniform color shift while
  libjpeg decoded it fine — the last blocker on tiffz's oracle-off flip.
  Root cause: the stream signals RGB via **component IDs 'R','G','B'**
  (82,71,66) with **no JFIF and no Adobe APP14** marker; gap D only handled
  the APP14-transform=0 RGB signal, so the cleanroom defaulted to YCbCr and
  color-converted. Fix: `decodeScanT`'s `rgb_passthrough` now mirrors
  libjpeg-turbo's full `default_decompress_parms` (jdmaster.c) precedence —
  JFIF⇒YCbCr, else Adobe APP14 transform, else component-ID guess
  ('R','G','B'⇒RGB, else YCbCr) — threading `saw_jfif` into the scan
  decoder. RED→GREEN differential test vs the libjpeg oracle
  (`tests/unit/fixtures/rgb-mode2-spliced.jpg`, extracted from the TIFF);
  full suite green, gap-D test still passes. Unblocks the tiffz flip +
  validate Windows full-parity chain.
- 2026-06-18 EST — Flake Windows cross-check (persistent CI regression gate).
  `build.zig` gained a `test-build` step (compile+link every test exe + the
  `c_smoke` C CLI, no run) so a sandbox can verify the Windows link without an
  x86_64-windows runner. `flake.nix` gained a `zigDeps` fixed-output derivation
  (`zig build --fetch=all`, hash `sha256-3PE/qYD…`) pre-fetching the vendored
  openjpeg source, plus a `checks.cross-windows` derivation that copies the FOD
  cache in and runs `zig build test-build -Dtarget=x86_64-windows-gnu
  -Dwith-charls=false -Dwith-libjpeg-oracle=false`. Build-only ⇒ host-agnostic
  (runs on this Mac and on Garnix's linux builders alike; no Thelio needed).
  Verified locally: `nix build .#checks.aarch64-darwin.cross-windows` → "windows
  cross-link ok"; native `build`/`test` checks untouched (they pass
  `-Dopenjpeg-lib` and never touch the FOD). Closes the openjpeg-vendoring
  follow-up.
- 2026-06-11 EST — Vendored openjpeg for cross-compile (Mecha Validate
  Windows-launch unblock) — `linkSystemLibrary("openjp2")` was unconditional,
  breaking mingw/`-static` cross (no zig-findable static openjp2; mingw
  openjpeg won't build). build.zig now auto-picks: system openjp2 when
  `-Dopenjpeg-lib` is given (native nix, fast), else the Zig-vendored static
  libopenjp2 from `deps/openjpeg/` (uclouvain 2.5.4, 22-file no-SIMD; pattern
  stolen from validate's core). `c_smoke`'s openjp2 link gated likewise (the
  vendored static lib propagates through the jpegz lib). jpegz module API
  unchanged — pure pin bump for consumers. Verified: native ./test green;
  `x86_64-windows-gnu` test-build links clean (RED was 18 undefined `opj_*`).
  Vendored path only fetches `openjpeg_src` when used, so the native sandbox
  build needs no flake FOD. libjpeg needs NO vendoring (gated test-only via
  `-Dwith-libjpeg-oracle`; gap D lets tiffz drop `wrapperDecode`). Pin chain:
  jpegz → tiffz → validate. Follow-up: flake windows cross-check (zigDeps
  FOD) as the persistent CI regression gate.
- 2026-06-08 EST — Gap D: RGB-marked baseline cleanroom parity — an Adobe
  APP14 ColorTransform=0 3-component JPEG (e.g. `cjpeg -rgb`) carries R,G,B
  directly; the cleanroom was wrongly YCbCr→RGB converting it. `decodeScanT`
  now computes an `rgb_passthrough` flag (APP14 transform 0 for a 3-comp
  frame) and `assembleOutputT` interleaves the planes as-is, reporting
  `source_color_space = .rgb` — byte-matching libjpeg. Unblocks tiffz
  dropping its `internal.wrapperDecode` for the `rgb-jpeg.tif` case. Fixture
  `baseline_16x16_rgb_marked.jpg` + TDD cross-check vs `wrapperDecode`.
  Follow-up: the no-APP14 'R'/'G'/'B' component-ID heuristic (rarer in the
  wild; needs a hand-crafted fixture since cjpeg always writes APP14).
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
