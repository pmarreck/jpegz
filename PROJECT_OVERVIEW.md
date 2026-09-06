# jpegz project overview

## Mission

jpegz provides one JPEG-family validation API for validate, tiffz, and other
consumers, alongside pixel decoding. The goal is full coverage of classic JPEG
(T.81), JPEG-LS (T.87), JPEG 2000 (T.800), and JPEG XL (ISO/IEC 18181).
Coverage is still incomplete; a successful decode alone does not establish
complete corruption detection.

The current code implements baseline and extended sequential JPEG, progressive
JPEG, predictive lossless JPEG, arithmetic DCT modes, and JPEG-LS decoding in
Zig. JPEG 2000 pixel decoding uses OpenJPEG. Strict JP2 and JXL validation
delegates to pinned Zig modules from jp2z and libjxlz. jpegz does not expose
JPEG XL pixel decoding.

## Architecture

Zig consumers import jpegz directly. jpegz imports jp2z and libjxlz as Zig
modules, preserving one instance of each module in a consumer build graph.
The C CLI calls the published C ABI in `include/jpegz_core.h`.

The core accepts byte buffers and an allocator; callers own I/O. Pixel images
and validation results must be freed through their matching API. The row
callback API currently decodes a whole image before delivering its rows, so it
does not reduce peak pixel memory.

C consumers link exactly one archive: `libjpegz-validate.a` for validation,
or `libjpegz.a` for validation plus pixel decoding. The validation archive
excludes external JPEG-family decoders. Brotli remains required for JXL
container metadata. See [SPEC.md](SPEC.md) for build options and ownership.

## Provenance

JPEG entropy, marker parsing, lossless, arithmetic, and JPEG-LS layers were
written from the ITU-T specifications. Production integer IDCT, color
conversion, and upsampling are Zig ports of IJG/libjpeg-turbo code and retain
IJG attribution. OpenJPEG remains the JP2 pixel decoder in this repository;
the JP2 validator is the pinned jp2z Zig implementation.

[LICENSING_NOTES.md](LICENSING_NOTES.md) owns provenance descriptions;
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) retains attribution texts.

## Key terminology

- MCU: minimum coded unit. In an interleaved DCT scan it groups component
  blocks according to sampling factors; in a non-interleaved DCT scan it is
  one block. It is not a whole row of blocks.
- DCT: discrete cosine transform used by classic lossy JPEG.
- Spectral selection: the coefficient band carried by a progressive scan.
- Successive approximation: progressive refinement of coefficient precision.
- EBCOT: JPEG 2000's embedded block coding with optimized truncation.
- LOCO-I: the predictive coding algorithm used by JPEG-LS.
- Q-coder: the binary arithmetic coder used by arithmetic JPEG.
- Strict verdict: valid, corrupt, unsupported, or indeterminate. Unsupported
  features and inconclusive checks must remain distinguishable from validity.

## Current work

[PLAN.md](PLAN.md) owns priorities and measurements. The immediate correctness
work is entropy accounting: scan termination, MCU counts, restart cadence,
AC run bounds, and progressive constraints. The August 27 consumer experiment
reported only 37/154 detected single-byte mutations on one scanned JPEG;
that result is a fixture-specific baseline, not a universal detection rate.

Dependency freshness, Brotli vendoring for Windows JXL, and CLI progress
follow. Internationalization is in prepare phase; its decision and scope live
in [RULES.md](RULES.md) and [docs/I18N.md](docs/I18N.md).
