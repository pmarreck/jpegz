# jpegz

[![Mechatron Prime CI](https://img.shields.io/endpoint?url=https%3A%2F%2Fthelio-nixos.tail66c90.ts.net%2Fbadges%2Fjpegz.json&style=for-the-badge)](https://thelio-nixos.tail66c90.ts.net/mechatron-prime/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Spec-complete JPEG family decoder library in Zig. One project, one ABI surface,
covering:

- **Baseline JPEG** (ISO/IEC 10918-1, T.81) — DCT, sequential
- **Progressive JPEG** (ISO/IEC 10918-1)
- **Lossless JPEG** (ISO/IEC 10918-1, T.81 §13) — used by DICOM, some early DNG
- **Arithmetic coding** (ISO/IEC 10918-1, T.81 §F)
- **JPEG-LS** (ISO/IEC 14495-1, T.87) — eventually
- **JPEG 2000** (ISO/IEC 15444, T.800) — wavelet codec, separate ABI namespace
  in the same project (different math, but same problem domain)

This is a sibling project to [`validate`](../validate),
[`tiffz`](../tiffz), [`bzip2z`](../bzip2z), [`rarz`](../rarz),
[`par2z`](../par2z), [`uchardetz`](../uchardetz), and
[`zstdz`](../zstdz).

## Why jpegz exists

`validate` has been carrying three things:
- A C-FFI dep on `libjpeg-turbo` (BSD-3) for baseline + progressive
- A pure-Zig 698-line lossless JPEG decoder (`jpeg_lossless_decoder.zig`)
- A C-FFI dep on `openjpeg` (BSD-2) for JPEG 2000

`tiffz` (greenfield) needs JPEG-in-TIFF (compression=7). Both projects need
a unified, focused JPEG home.

## Architecture

```
Any consumer (validate / tiffz / image tools) ──► C FFI ──► jpegz Zig core
```

The Zig core is the single source of truth. The C FFI is the public API.
External consumers — including any C CLI on top — go through the C FFI.

## Phasing

**Phase 1 (MVP, libjpeg-turbo wrapper).** Wrap `libjpeg-turbo` for baseline +
progressive. Lift validate's `jpeg_lossless_decoder.zig` directly. Add an
`openjpeg` wrapper for JPEG 2000. One unified Zig API + C ABI; the
implementation is mostly FFI-into-C-libs in this phase. Both validate and
tiffz can depend on jpegz the day it's stood up.

**Phase 2 (self-contained Zig decoders).** Reimplement each codec in Zig,
keeping the C deps as test oracles only. The **entropy, structural, lossless
(T.81 §H), JPEG-LS (T.87) and arithmetic (T.81 Annex D) layers are cleanroom**
Zig, written from the ITU-T specs. The DCT **DSP kernels** — islow IDCT,
YCbCr→RGB color conversion, chroma upsampling — are pure-Zig **ports of
libjpeg-turbo** (IJG License — inherited libjpeg code, attributed in
`THIRD_PARTY_NOTICES.md`), kept
byte-identical for oracle testing, **not** cleanroom. **JPEG 2000 (T.800)** is
a pure-Zig **port of openjpeg** (BSD-2) via the sibling `jp2z` (openjpeg is
still the JP2 runtime path until jp2z's port is feature-complete). JPEG /
JPEG-LS decode needs **no required libjpeg / CharLS runtime dependency** (both
droppable); the **JP2 path links a vendored openjpeg (BSD-2) at runtime** until
the jp2z cutover. Canonical provenance: `LICENSING_NOTES.md`. See `SPEC.md` §6 for the order (baseline first, then
progressive, then lossless rewrite, then arithmetic, then JPEG-LS, then
JPEG 2000 wavelet pipeline).

## Goals

1. **Spec-complete.** Every variant the published JPEG specs define,
   including arithmetic coding (rare but spec-mandatory), 12-bit
   precision, multi-component subsampling, and the lossless mode.
2. **JPEG 2000 in the same project.** Shares packaging, build, ABI
   conventions; separate ABI namespace because the codec internals are
   completely different (wavelet, EBCOT, T2/T1 packets).
3. **No I/O in the core.** Pure Zig core operates on `[]const u8`
   buffers and `std.io.Reader`-shaped interfaces.
4. **Hexagonal architecture.** Zig core + C FFI + (optional) C CLI, per
   project convention.
5. **Cleanroom replacement targeted by Phase 2.** Until then, libjpeg-
   turbo / openjpeg do the heavy lifting and are honest about it (see
   `LICENSING_NOTES.md`).

## Status

🚧 **Greenfield.** No code yet beyond this scaffold. See `SPEC.md`.

## License

MIT (see `LICENSE`). Phase 1 transitively pulls in libjpeg-turbo (BSD-3)
and openjpeg (BSD-2) — both MIT-compatible. Phase 2 retires those deps.
