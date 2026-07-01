# jpegz — project overview

## Mission

Spec-complete JPEG family decoder library in Zig, with a single ABI
surface covering every variant the published JPEG standards define:

- **Baseline JPEG** (T.81 sequential DCT, 8-bit and 12-bit)
- **Progressive JPEG** (T.81 progressive DCT)
- **Lossless JPEG** (T.81 §13 — DICOM, early DNG)
- **Arithmetic coding** (T.81 §F — rare but spec-mandatory)
- **JPEG-LS** (T.87 — eventually)
- **JPEG 2000** (T.800 — separate ABI namespace, same project)

## Architecture

```
Any consumer (validate / tiffz / image tools) ──► C FFI ──► jpegz Zig core
```

- **Zig core** does NO I/O. Pure decode logic over `[]const u8` and
  reader-shaped interfaces.
- **C FFI (`include/jpegz_core.h`)** is the real public API. Even the
  C CLI dogfoods it.
- Two consumers: `validate` (file-integrity tool) and `tiffz`
  (TIFF library; needs JPEG-in-TIFF compression=7).

## Two-phase plan

**Phase 1 (weeks):** wrap libjpeg-turbo (BSD-3) + openjpeg (BSD-2);
lift validate's pure-Zig lossless decoder. Ship a working ABI day one
so validate + tiffz unblock immediately.

**Phase 2 (months):** reimplement each codec in Zig. Cleanroom (from ITU-T
spec): entropy/structural parsing, lossless (T.81 §H), JPEG-LS (T.87),
arithmetic (T.81 Annex D). PORTS (pure-Zig, BSD-attributed, byte-identical for
oracle testing): the DCT DSP kernels — islow IDCT, YCbCr→RGB color conversion,
chroma upsampling — from libjpeg-turbo (BSD-3); and JPEG 2000 (T.800) from
openjpeg (BSD-2) via the sibling `jp2z`. Keep libjpeg-turbo + openjpeg as test
oracles. End state: **zero system C deps in the shipped binary** (no
libjpeg/openjpeg runtime dependency). NOTE: jp2z's production decode is still
openjpeg today; dropping it is jp2z Phases 2-3 (unstarted), so the JP2 cutover
is a ways out. Canonical provenance: `LICENSING_NOTES.md`.

## Key terminology

- **MCU** — Minimum Coded Unit. A row of 8×8 (sometimes 16×16)
  blocks across all components, the natural decode granularity for
  baseline JPEG.
- **DCT** — Discrete Cosine Transform, the lossy compression step at
  the heart of T.81 baseline/progressive.
- **Spectral selection / successive approximation** — the two
  axes along which progressive JPEG splits its scans.
- **EBCOT** — Embedded Block Coding with Optimized Truncation, the
  bitplane coder used inside JPEG 2000's tier-1.
- **LOCO-I** — JPEG-LS's predictor + context model (HP, expired 2018).
- **Q-coder** — IBM's binary arithmetic coder used by T.81 §F.

## Rules of engagement

1. **No silent skip.** If a file is JPEG, jpegz decodes it. If decode
   fails, jpegz reports the specific failure. Never degrade silently.
   `validate` will fail any consumer that violates this.
2. **No I/O in core.** Caller-allocates pixel buffer when size is
   known; streaming variant uses callbacks.
3. **Cleanroom Phase 2.** ITU-T specs are primary; libjpeg-turbo source
   is a secondary reference only (cite in source comments where used).
   Avoid GPL-contaminated implementations entirely (no ffmpeg).
4. **TDD throughout.** Failing test before each wrap-impl step.
   Oracle-equality (`djpeg`/`opj_decompress` byte-for-byte) is the
   gold-standard assertion.

## Status

Phase 1 milestone 1 complete (scaffold). Phase 1 milestone 2
(brainstorm SPEC §9 design questions) is the next entry point.
