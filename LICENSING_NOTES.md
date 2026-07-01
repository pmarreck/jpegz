# Licensing notes (jpegz)

**Date:** 2026-05-04
**Project license:** MIT (see `LICENSE`)

## Short answer

JPEG (the format family covered by ISO/IEC 10918, 14495, and 15444) is
freely implementable. Patents on the core DCT-based codec expired
years ago; arithmetic coding patents (IBM) expired in the early 2000s;
JPEG-LS (HP LOCO-I) expired in 2018; JPEG 2000 has a complex history
but is widely-implemented in open source today. Specs are freely
downloadable from ITU-T.

Phase 1 transitively pulls in two C deps (libjpeg-turbo, openjpeg).
Both are MIT-compatible. Phase 2 retires them in favor of pure-Zig
implementations.

## Provenance: cleanroom vs. port (CANONICAL — source of truth)

This section is the single source of truth for how jpegz may describe its
codecs. Other docs (README, PROJECT_OVERVIEW, PLAN, SPEC, design notes) must
be consistent with it. "Cleanroom" is a legal/marketing term of art — claim it
ONLY where the code was written from the ITU-T spec, never where an algorithm
shape was adapted from libjpeg-turbo/openjpeg source.

**Universal claim (always true, use where one line is needed):**
> jpegz has **no libjpeg / openjpeg / charls runtime dependency — pure Zig.**
(Those libraries are build-time test oracles only, gated off in shipping builds.)

**Cleanroom — written from ITU-T T.81 / T.87 (claim "cleanroom" freely, scoped):**
- Marker / segment parsing (T.81 Annex B)
- Huffman decode + canonical table generation (T.81 Annex C, Fig C.2)
- Bitstream reader / byte-destuffing (T.81 §F.1.2.3)
- Dequantization
- Lossless predictive decode (T.81 §H, SOF3)
- Arithmetic Q-coder (T.81 Annex D / Table D.3, §F.1.4) — spec-primary
- JPEG-LS / LOCO-I (T.87) — see `docs/.../2026-05-16-jpegls-cleanroom-design.md`
- `idct8x8_fpd` — reference IDCT from T.81 Annex A (**test oracle only**, not
  the production path)

**Port — pure-Zig reimplementations of libjpeg-turbo (BSD-3) source, kept
byte-identical for oracle testing (describe as "port", NOT "cleanroom";
BSD-3 attribution required — see `THIRD_PARTY_NOTICES.md`):**
- Production integer IDCT `idct8x8` / `idct8x8_12` / `idct8x8Generic` — islow,
  from `jidctint.c` / `jidct12.c` (constants, CONST_BITS, PASS1_BITS copied)
- YCbCr→RGB color conversion `ycbcrRowToRgb` — from `jdcolor.c` (SCALEBITS,
  FIX_* fixed-point)
- Fancy chroma upsampling `fancyUpsample` — IJG fancy upsampling
- CMYK / YCCK assembly — mirrors libjpeg-turbo

**Port — pure-Zig port of openjpeg (BSD-2), via the sibling `jp2z`:**
- JPEG 2000 (T.800), the `jpegz.jpeg2000` re-export. (Today still delegates to
  the openjpeg C wrapper at runtime; jp2z's Zig port is not yet its production
  path — see the cutover plan.)

**Approved phrasings:**
- ✅ "pure-Zig JPEG-family decoder; no libjpeg/openjpeg runtime dependency"
- ✅ "cleanroom entropy, lossless, JPEG-LS and arithmetic layers (ITU-T T.81/T.87)"
- ✅ "DCT DSP kernels are pure-Zig ports of libjpeg-turbo (BSD-3, attributed)"
- ❌ "100% cleanroom JPEG" / "cleanroom across all formats" (the DCT DSP kernels
     and the JP2 path are ports)

**Reclaim path (tracked, future):** switching production to `idct8x8_fpd` +
spec-derived color/upsampling would make the DCT path genuinely cleanroom, at
the cost of byte-divergence from libjpeg (breaks byte-exact oracle tests;
downstream tiffz/validate impact). Evaluate separately — see PLAN.md.

## License compatibility

- **libjpeg-turbo** — BSD-3-Clause. MIT-compatible. Phase 1 vendored
  via `chearon/libjpeg-turbo` Zig-build fork (same license). Phase 2:
  used as ambiguity-resolution reference and binary oracle ONLY; if
  any algorithm shape is adapted from libjpeg-turbo source, include
  the BSD-3 attribution in a source comment + entry in
  `THIRD_PARTY_NOTICES.md`.
- **openjpeg** — BSD-2-Clause. MIT-compatible. Same rule.
- **libjpeg (the original IJG)** — BSD-3-style with attribution-required
  clause. Older; superseded by libjpeg-turbo. If consulted, include
  the IJG attribution.
- **charls** — BSD-3-Clause (per upstream `SPDX-License-Identifier`).
  MIT-compatible. Added 2026-05-15 for JPEG-LS (T.87) support;
  libjpeg-turbo does not implement JPEG-LS, so charls is currently
  the only runtime path. Used as the runtime decoder via
  `src/ffi/charls_wrapper.zig` and (later) as the oracle for the
  cleanroom B2 milestone. C++ implementation with a C ABI; linked
  via `link_libcpp = true` in `build.zig`.
- **zigimg's `src/formats/jpeg.zig`** — MIT. Reference reading allowed
  (322 lines, baseline-only). Phase 2 reference reading expressly
  permitted.
- **Pillow's JpegImagePlugin** — MIT-style. Compatible. Same rule.
- **Go x/image/jpeg** — BSD-3. Compatible. Reference if needed.

## Avoid (GPL contamination)

- **ffmpeg's JPEG codecs** — LGPL/GPL depending on build config. Do
  not read for Phase 2 cleanroom work.
- **Any GPL'd JPEG implementation** — same rule. GPL contamination
  is unrecoverable for an MIT project.

## Patent landscape (snapshot, 2026)

### Baseline JPEG / DCT

- DCT core: patent-free since the 1980s.
- Forgent Networks' claim on `5,253,341` (so-called "JPEG patent"):
  rejected by USPTO 2007. Also expired in 2007. Free.

### JPEG arithmetic coding (T.81 §F)

- IBM held patents on arithmetic coding generally and the JPEG-specific
  Q-coder. All key patents expired in early 2000s.
- This is the historical reason most JPEG files in the wild use
  Huffman coding rather than arithmetic — by the time the patents
  expired, baseline JPEG was entrenched.
- Free to implement.

### JPEG-LS (T.87)

- HP held the LOCO-I predictor patent (`5,680,129`, expired 2018) and
  related continuations (also expired). Free since 2018.
- ISO requires patent disclosures from contributors; no current
  outstanding patents.

### JPEG 2000 (T.800)

More complex but ultimately green-light:

- The original JPEG 2000 patent pool was managed via the JPEG
  Committee's RAND-Z (Reasonable And Non-Discriminatory, Zero-cost)
  licensing program.
- Most contributors disclosed patents under royalty-free terms.
- Two specific patents on visual masking (Quintessence Inc. /
  Pegasus Imaging) were declared but never enforced as of 2020.
- Open-source implementations (openjpeg, GraphicsMagick, libvips,
  Pillow) ship JPEG 2000 support without legal incident, indicating
  the practical risk is minimal.

If you're shipping JPEG 2000 commercially in a high-stakes
jurisdiction, get legal sign-off on Quintessence's claims. For an
open-source library matching openjpeg's surface area, the precedent
is clear.

## Implementation approach (style discipline, not legal posture)

**Phase 1:** wrap libjpeg-turbo and openjpeg via FFI. The Zig core
is thin — input validation, error mapping, ABI marshalling — most
work happens in C.

**Phase 2:** rewrite each codec in pure Zig.

- Primary source: ITU-T specs (T.81, T.87, T.800).
- Secondary source: libjpeg-turbo source (BSD-3) for ambiguity
  resolution. Cite in source comments when an algorithm shape is
  clarified by libjpeg-turbo.
- Verification: libjpeg-turbo + openjpeg binaries (`djpeg`,
  `cjpeg`, `tjbench`, `opj_decompress`, `opj_compress`) as oracles.
  Compare decoded pixels byte-for-byte for each fixture.

If the spec is ambiguous and libjpeg-turbo resolves differently than
zigimg or Pillow, libjpeg-turbo wins (it's the longest-standing
reference and the de-facto interoperability standard). Document the
choice in a source comment.

## Distribution

`jpegz` ships under MIT.

**Phase 1:** when libjpeg-turbo and openjpeg are linked, distribution
must include their license texts (BSD-3 and BSD-2 respectively).
Create `THIRD_PARTY_NOTICES.md` with full text.

**Phase 2:** as each C dep is retired, drop its entry from
`THIRD_PARTY_NOTICES.md`.

## Questions

Escalate to Peter. Don't guess at licensing edge cases — especially
for JPEG 2000.
