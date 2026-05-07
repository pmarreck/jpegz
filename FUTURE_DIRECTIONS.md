# jpegz future directions (out-of-scope-by-design)

Variants and adjacent formats explicitly **not** covered by jpegz's
mission as currently scoped. Captured here so the option remains
visible and so the analysis doesn't get re-derived from scratch later.

**What IS in scope (and lives in PLAN.md, not here):**
the full T.81 family (baseline / extended / progressive / lossless /
arithmetic), T.87 JPEG-LS, and T.800 JPEG 2000 — all in pure Zig
(Phase 2). If it's an ITU-T-blessed "JPEG" by name, it belongs in
jpegz. Differential lossless (SOF5/6/7/13/14/15) and hierarchical
(DHP) are also in scope per spec, just deferred until a real consumer
needs them.

**What's out of scope (this document):** anything that's a different
codec family with no shared internals (JPEG XL is a different ISO
standard; JPEG-XR is a Microsoft transform; JPEG-XS is broadcast-only;
JPEG-XT is an HDR extension layer that *might* fold in later).

## Sibling-project candidates (most-promising)

### JPEG XL (ISO/IEC 18181)

**Status:** sibling project `libjxlz` exists / is in flight.
**Why separate:** different codec entirely (modular ANS + variable-block-size DCT), different ISO standard, different reference implementation (`libjxl`). Folding into jpegz would dilute the JPEG-family ABI.
**Profitability:** **highest of any Tier 3 candidate.** JXL is widely viewed as the eventual successor to baseline JPEG: better compression than WebP/AVIF on photographic content, the only modern lossless mode that beats PNG (~50% smaller), Apple ships native support in Safari 17+ / macOS Sonoma / iOS 17. Adobe DNG 1.7 added optional JXL compression. If/when Chrome reverses its 2022 decision, JXL becomes the default web JPEG replacement overnight.
**Backwards-compatible bridge:** JXL has lossless JPEG re-encoding ("JPEG transcoding") — given a baseline JPEG, you can losslessly re-encode into a ~20% smaller JXL container and decode back to a bit-identical baseline JPEG. Useful for archives migrating off legacy JPEG.

### JPEG-XR (HD Photo / wmphoto, ITU-T T.832 / ISO 29199-2)

**Status:** no project; would be greenfield.
**Why separate:** different spec, different codec (lapped biorthogonal transform, not DCT), Microsoft origin.
**Profitability:** **low.** Mostly dead format. Some Windows Photo Viewer and TIFF (compression=22610) usage. If a real consumer surfaces (forensic / archival imaging that mandates it), `xrz` is the obvious sibling-project name.

### JPEG-XS (low-latency, ISO/IEC 21122)

**Status:** no project.
**Why separate:** different codec design (mathematically lossless / visually lossless at very low latency), targeted at broadcast / live video / VR.
**Profitability:** **medium-niche.** Real adoption in broadcast (SMPTE 2110), professional A/V, autonomous-vehicle camera pipelines. Not consumer-facing. If a consumer needs it, `xsz`.

### JPEG-XT (HDR extensions)

**Status:** no project.
**Why separate:** extension layer over baseline JPEG that adds HDR / wide-color-gamut data in APP markers (backwards compatible — base layer decodes as ordinary 8-bit JPEG; HDR consumers parse the extension).
**Profitability:** **medium.** HDR JPEG could matter for camera workflows and HEIF replacements; growing slowly. Could fold into jpegz Phase 3 (post-cleanroom) since the base layer is already in scope.

### MPF (Multi-Picture Format) / Live Photos / multi-picture JPEG (CIPA DC-007)

**Status:** no project. Some logic exists in `validate`'s scientific validators.
**Why separate:** container format, not a codec — wraps multiple JPEGs into one file via APP2 marker chain. Apple Live Photos, 3D Realsense / iPhone stereo pairs, Panasonic 3D cameras.
**Profitability:** **medium.** Real consumers exist (validate already handles this case). Could be a `mpfz` sibling or could fold into a hypothetical `jfifz` (JFIF/Exif metadata library). Probably belongs with the metadata-parsing family, not the codec family.

## Container / metadata adjacencies

### JFIF / Exif metadata library (`jfifz` or `exifz`?)

**Status:** validate parses these inline; no dedicated project.
**Profitability:** **medium.** Consolidating Exif/IPTC/XMP/MPF parsing into a sibling library would let validate, tiffz, jpegz, libjxlz, and any future image consumer share a metadata path. tiffz already produces some IFD-walking machinery; could be the seed.

### HEIC / HEIF (ISO/IEC 23008-12)

**Status:** no project.
**Why separate:** container format; payload is usually HEVC (h.265), not JPEG. Apple's photo container.
**Profitability:** **low for jpegz directly.** Would need an HEVC decoder (massive scope; entirely separate codec family). Better as a sibling project `heifz` paired with an HEVC codec.

## JPEG-family edge cases not currently in scope

### Differential lossless (SOF5/6/7/13/14/15)

**Status:** marker walker classifies as `unknown` variant; decode returns `error.NotImplemented`.
**Why deferred:** vanishingly rare; never seen in real-world fixtures; spec-mandatory but no consumer asks. T.81 §J — hierarchical mode building blocks.
**If profitable:** would lift to jpegz Phase 2 cleanroom. Fixtures would have to be hand-constructed since cjpeg can't produce them.

### Hierarchical JPEG (DHP marker, T.81 §J)

**Status:** marker walker doesn't recognize DHP (0xDE).
**Why deferred:** even rarer than differential lossless. Designed for resolution-progressive transmission; never adopted in practice (progressive DCT won that market).
**If profitable:** would need its own milestone. Probably never profitable.

### JPEG with embedded preview pyramids (TIFF-style)

**Status:** doesn't exist as a single spec — convention varies by camera manufacturer (Canon CR2, Nikon NEF embed JPEG previews in TIFF/EP-shaped files).
**Better fit:** tiffz handles the TIFF wrapper; jpegz decodes the embedded JPEG once tiffz extracts the strip. Already aligned per existing handoff.

## Non-image JPEG-adjacent

### JBIG / JBIG2 (T.82 / T.88)

**Status:** validate handles via PDF JBIG2Decode path.
**Why not jpegz:** completely different codec family (bilevel / facsimile-grade compression). Despite both being ITU-T image standards, no shared internals. If a `jbigz` sibling makes sense, it'd be its own project.

## Decision discipline

If a Tier 3 candidate becomes "profitable" (real consumer asks; market shift; new sibling-project ROI surfaces):

1. Sketch the project shape (sibling project? fold into jpegz? new family?).
2. Compare against jpegz's hexagonal architecture — is the codec close enough to reuse the C FFI shape, or different enough to warrant its own ABI?
3. If folding into jpegz: add a sub-namespace (mirror of `jpeg2000`).
4. If sibling: stand up the new project the same way jpegz was stood up (scaffold → spec → wrap → cleanroom).

The bar for "in jpegz" is **shared codec internals or shared ABI conventions**. Containers and metadata formats fail this bar; codec extensions to baseline (XT) might pass it.

— Captured 2026-05-06 EST
