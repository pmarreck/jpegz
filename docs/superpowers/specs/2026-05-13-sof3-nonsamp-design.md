# SOF3 lossless non-1×1 chroma sampling (A2) — Design

**Status:** Approved 2026-05-13. Implements A2 from `NEXT_STEPS.md`.
**Scope:** SOF3 (lossless) JPEGs with at least one component having
`(h_factor, v_factor) ≠ (1, 1)` — i.e. chroma subsampling in lossless
mode (4:2:0, 4:2:2, 4:4:0, 4:1:1, etc.).
**Out of scope:** Differential lossless (SOF5–7) and arithmetic lossless
(SOF11) — separate milestones each.

---

## Goal

Close the matrix row "SOF3 lossless w/ non-1×1 sampling". After this
milestone:

- A lossless JPEG with `h_factor` or `v_factor` ≠ 1 on any component
  decodes through the cleanroom path (instead of falling through to
  the wrapper).
- The default chroma reconstruction is **nearest-neighbor** —
  byte-equal to libjpeg-turbo's `jpeg_read_scanlines` output, and
  philosophically correct for lossless (no sample synthesis without
  explicit caller opt-in).
- New `DecodeOptions.chroma_upsample` enum scaffolds opt-in for
  fancier reconstruction algorithms (deferred implementations).

## Why this matters (and why it's tricky)

**The variant is extinct in the wild but spec-legal.** Empirical check:

- `cjpeg -lossless 1 -sample 2x2,1x1,1x1` silently rewrites to 1×1.
  Confirmed via byte-identical SOF3 markers in test runs.
- DICOM lossless: always 1×1.
- DNG raw lossless: always 1×1.
- No common encoder emits non-1×1 lossless.

But T.81 §H.1 explicitly permits it, and libjpeg-turbo's **decoder**
(`jdlhuff.c` line 103 — walks `cinfo->blocks_in_MCU` × per-component
`MCU_width`/`MCU_height`) handles it. So the test path is:

1. Bypass cjpeg's CLI gate by calling libjpeg-turbo's compress API
   directly from a small custom C generator.
2. Decode the generated fixture via `internal.wrapperDecode` (which
   uses libjpeg's decoder) to get ground truth.
3. Assert cleanroom byte-equals wrapper.

## The synthesis question (lossless integrity)

A lossless JPEG at non-1×1 sampling stores per-component planes at
**different resolutions** — that information was lost (downsampled) at
encode time, BEFORE the JPEG was created. Decoding can never recover
the original full-resolution chroma; it can only **synthesize**
samples at upsampled positions.

Implications:

- **Any upsampling is invention.** A 1×1 lossless JPEG round-trips
  byte-perfectly through encode → decode. A 2×2 lossless JPEG cannot.
- **Different upsamplers produce different byte outputs**, hence
  different hashes — a problem for validation/integrity use cases.
- **Nearest-neighbor** is the only upsampler that replicates rather
  than synthesizes. It's deterministic, libjpeg-matched, and the
  philosophically-correct lossless default.

This library's primary downstream is `validate` (file integrity
checking) and `tiffz` (TIFF parser with JPEG payloads). Both consume
JPEG decode output to compute hashes or compare bit-exact bytes.
**Synthesized samples in default output would silently corrupt those
flows.** Hence: default `.nearest`; everything else is opt-in.

## Architecture

### DecodeOptions extension

```zig
pub const ChromaUpsample = enum {
    /// Codec-dependent default. For DCT JPEGs (baseline / progressive
    /// / extended sequential) → IJG fancy 9-3-3-1. For lossless JPEGs
    /// → nearest-neighbor. Recommended for most consumers.
    auto,
    /// Nearest-neighbor: each output pixel takes its value from the
    /// closest source sample. No synthesis. Deterministic. Required
    /// for hash-integrity / validation flows over chroma-subsampled
    /// lossless JPEGs.
    nearest,
    /// IJG fancy cosited-center filter (9-3-3-1 for H2V2, +1/+2 for
    /// 1D upsamples). Same algorithm as the lossy DCT path.
    /// Currently NOT implemented for the lossless path; returns
    /// error.NotImplemented when explicitly requested via lossless.
    ijg_fancy,
    /// Bicubic Catmull-Rom (4×4 kernel, fixed-point). NOT implemented
    /// in this milestone; reserved for future opt-in.
    bicubic_catmullrom,
};

pub const DecodeOptions = struct {
    threads: u8 = 1,
    chroma_upsample: ChromaUpsample = .auto, // NEW
};
```

This milestone honors `chroma_upsample` only in the lossless non-1×1
path. The existing DCT paths (`baseline.zig`, `progressive.zig`) keep
their current hardcoded IJG-fancy behavior — extending the enum to
those paths is a separate follow-on milestone. Documented in code
comments so the extension point is obvious.

### lossless.zig refactor

Current code (line 311+) walks the **interleaved output buffer**
directly because at 1×1 each pixel = 1 MCU = N samples (one per
component). Predictor neighbors are read from the output buffer
in canvas coordinates.

This won't work at non-1×1 because:

- Each component's predictor uses neighbors **within its own plane**
  at the component's native resolution (not interleaved canvas).
- An MCU contains `H_c × V_c` samples per component, walked in
  T.81 §A.2.4 raster order within each component.

New shape:

1. **Allocate per-component planes** at native resolution
   `(mcu_cols × H_c × 1) × (mcu_rows × V_c × 1)` (lossless samples
   are 1× per H/V unit, not 8× like DCT blocks).
2. **MCU walk** mirroring `decodeScan` (baseline.zig): for each MCU,
   iterate components in scan order, then `(V_c, H_c)` samples per
   component, each with its own predictor state.
3. **Predictor state** lives per-component, walking that component's
   own plane.
4. **After all MCUs decoded**: assemble the output buffer at canvas
   resolution. Luma copies directly. Chroma planes (smaller) upsample
   per `options.chroma_upsample` to canvas resolution before
   interleaving.
5. **For `.nearest`**: simple integer math, `chroma_x = canvas_x *
   chroma_factor / max_factor` (clamped).
6. **For `.ijg_fancy` / `.bicubic_catmullrom`**: return
   `error.NotImplemented` from this milestone's lossless path.

### Backward compatibility

The 1×1 case **must continue to work byte-exact**. Approach: a single
generalized `decodeScan` that handles both 1×1 and non-1×1 with no
special-casing. The 1×1 case is just "every loop iterates once".
Validated by re-running existing M2.4/M2.6/M2.7/M2.8 lossless tests.

## Fixture generation

Custom C program `scratch/gen_lossless_nonsamp_fixtures.c` calls
libjpeg-turbo's compress API:

```c
jpeg_create_compress(&cinfo);
jpeg_simple_lossless(&cinfo, predictor, 0);
// ... set image_width, image_height, input_components, in_color_space ...
jpeg_set_defaults(&cinfo);
// THE KEY: override sampling factors after defaults
cinfo.comp_info[0].h_samp_factor = h_y;
cinfo.comp_info[0].v_samp_factor = v_y;
// ... etc for Cb, Cr ...
jpeg_start_compress(&cinfo, TRUE);
// ... write scanlines, finish ...
```

Output 4 fixtures (one per sampling layout):

| File | Sampling | Notes |
|------|----------|-------|
| `lossless_16x16_rgb_sub420.jpg` | Y:2×2, C:1×1 | most common |
| `lossless_16x16_rgb_sub422.jpg` | Y:2×1, C:1×1 | 4:2:2 |
| `lossless_16x16_rgb_sub440.jpg` | Y:1×2, C:1×1 | 4:4:0 (uncommon) |
| `lossless_16x16_rgb_sub411.jpg` | Y:4×1, C:1×1 | unusual but spec-legal |

The C generator script is build-once-then-run, not part of `./test`.
Built fixtures are committed under `tests/unit/fixtures/`.

## Testing

Parametric test in `tests/unit/decode.zig` over the 4 fixtures.
Cleanroom default decode (with `.auto` → `.nearest` for lossless)
must produce output **byte-identical** to libjpeg wrapper. Lossless
nearest gives byte-exact match (no rounding involved).

Also test:
- `.nearest` explicitly set: same byte-exact match.
- `.ijg_fancy` and `.bicubic_catmullrom` on a non-1×1 fixture:
  returns `error.NotImplemented`.
- `.nearest` on a 1×1 fixture: same output as default (no upsampling
  needed).

## Implementation order (TDD)

1. **Fixture generator** — write the C program, build, generate the 4
   fixtures, commit.
2. **RED — failing parametric test**: assert cleanroom byte-equals
   wrapper for each fixture. Fails today (line 111 rejection).
3. **GREEN1 — DecodeOptions.chroma_upsample**: add enum + field +
   docstring. Wire it through `decodeWithOptions` to the lossless
   internal `decode` entry point.
4. **GREEN2 — non-1×1 lossless MCU walk**: lift the rejection,
   refactor `decodeScan` to use per-component planes, implement
   nearest-neighbor upsample. Existing 1×1 tests must stay green.
5. **REFACTOR**: tidy comments, update NEXT_STEPS.md, full suite
   green, commit.

Each its own commit on `yolo`.

## Risks / unknowns

- **Generator portability**: the C generator uses libjpeg-turbo's
  `jpeg_simple_lossless` extension API. Confirmed present in 3.1.4
  per the vendored source. If a different libjpeg version is in the
  flake, generator may not compile — fix in `flake.nix` or pin
  libjpeg-turbo version.
- **Edge clamping for nearest upsample**: when `width % max_h ≠ 0`,
  the per-component plane has trailing MCU-padded samples not
  contributing to the output. Use the same `(width * factor + max_h - 1)
  / max_h` formula as the DCT baseline to compute active extent.
- **i16 vs u8 sample storage at P≤8**: keep the existing lossless
  output-byte conventions (u8 packed for P≤8, u16 host-endian
  otherwise).
- **Predictor lookback across plane boundaries**: each component's
  predictor state is independent. Verify no cross-component
  contamination from the refactor.

## Open questions resolved

- **Default upsampler**: nearest. (Peter, 2026-05-13)
- **Other algorithms in this milestone**: stubbed only — return
  `NotImplemented`. (Peter, 2026-05-13)
- **API surface**: generic `chroma_upsample` enum on `DecodeOptions`,
  applies to ALL chroma upsampling in future; this milestone
  honors it only in the lossless path. DCT paths keep current
  hardcoded behavior pending a follow-on milestone. (Peter, 2026-05-13)
- **Fixture strategy**: custom C generator that bypasses cjpeg's CLI
  restriction by calling libjpeg-turbo's compress API directly.
  (Peter approved (β) approach, 2026-05-13)
- **Lossless integrity rationale**: documented in code comments per
  Peter's directive — synthesis would corrupt downstream
  validation/hash-integrity flows. (Peter, 2026-05-13)
