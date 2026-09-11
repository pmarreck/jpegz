# jpegz

[![Mechatron Prime CI](https://img.shields.io/endpoint?url=https%3A%2F%2Fthelio-nixos.tail66c90.ts.net%2Fbadges%2Fjpegz.json&style=for-the-badge)](https://thelio-nixos.tail66c90.ts.net/mechatron-prime/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

JPEG-family decoding and validation in Zig, working toward full specification
coverage. One facade covers:

- **Baseline JPEG** (ISO/IEC 10918-1, T.81) — DCT, sequential
- **Progressive JPEG** (ISO/IEC 10918-1)
- **Lossless JPEG** (ISO/IEC 10918-1, T.81 §13) — used by DICOM, some early DNG
- **Arithmetic coding** (ISO/IEC 10918-1, T.81 §F)
- **JPEG-LS** (ISO/IEC 14495-1, T.87) — Zig decoding, including line-interleaved RGB
- **JPEG 2000** (ISO/IEC 15444, T.800) — wavelet codec, separate ABI namespace
  in the same project (different math, but same problem domain)
- **JPEG XL** (ISO/IEC 18181) — strict validation delegated to exact-pinned
  `libjxlz`, with valid/corrupt/unsupported/indeterminate kept distinct

This is a sibling project to [`validate`](../validate),
[`tiffz`](../tiffz), [`bzip2z`](../bzip2z), [`rarz`](../rarz),
[`par2z`](../par2z), [`uchardetz`](../uchardetz), and
[`zstdz`](../zstdz).

## Why jpegz exists

Project purpose and success criteria live in [INTENT.md](INTENT.md).

validate and tiffz need a shared implementation for standalone JPEGs,
PDF-embedded images, and JPEG-in-TIFF. jpegz provides their JPEG-family
interface and translates the sibling validators' findings into one vocabulary.

## Architecture

```
Zig consumers (validate / tiffz) ──► jpegz Zig facade ──► jp2z / libjxlz
External consumers                 ──► C FFI ───────────► jpegz Zig core
```

Sibling Zig libraries are consumed as Zig modules, preserving type safety and
avoiding a Zig-to-C-to-Zig round trip. jpegz remains the outward-facing C ABI.

### One call for the whole family

`validateAny` sniffs the container and routes to the validator that owns it, so
a consumer gets JPEG, JPEG-LS, JPEG 2000 and JPEG XL coverage without linking
three libraries or reconciling three finding registries:

```zig
var result = try jpegz.validateAny(allocator, bytes);
defer result.deinit(allocator);
switch (result.verdict) { .valid, .corrupt, .unsupported, .indeterminate => ... }
```

```c
jpegz_strict_result_t r = {0};
if (jpegz_validate_any(data, len, &r) == JPEGZ_OK) { /* r.verdict, r.findings */ }
jpegz_strict_result_free(&r);
```

The verdict is deliberately four-way. `unsupported` (well-formed, uses a feature
the validator does not cover) and `indeterminate` (no conclusion reached) are
real answers — collapsing either into pass/fail turns a feature jpegz cannot
check into either a false clean bill of health or a false accusation of damage.
Unrecognized input is `indeterminate`, never `corrupt`: bytes that match no
JPEG-family signature are not evidence of damage.

Each finding keeps the originating validator's own code in `leaf_code`
alongside jpegz's mapped `code`, so a code jpegz has no name for is still
reportable verbatim against jp2z or libjxlz.

### Two archives, one header

C consumers link exactly one. `libjpegz.a` is a strict superset, so a decoding
consumer needs only that. They are alternatives rather than companions: each
carries its own thread-local last-error slot, so linking both would let an
error set through one be read as empty through the other.

| Archive | Provides | C dependencies |
|---|---|---|
| `libjpegz-validate.a` | validation + the strict facade | Brotli only |
| `libjpegz.a` | the above plus decode (pixels) | Brotli; OpenJPEG for JP2 pixels; optional libjpeg-turbo/CharLS oracles |

A validator, integrity checker, or triage tool wants the small one; only
something that needs actual pixels needs the large one. The `jpegz` CLI links
the small one, so it carries no external JPEG-family decoder at all — the same
guarantee `checks.validator-closure` enforces for the closure proof binary.
The validation-only production target is closure-tested to exclude libjpeg,
OpenJPEG, CharLS, upstream libjxl, and djxl; libjxlz uses Brotli only for JXL
container metadata. See `docs/VALIDATION_FACADE_EVIDENCE.md` for the exact pins,
classifier matrix, and closure gate.

## Implementation and build

Classic JPEG and JPEG-LS decoding use Zig code. Entropy, structural, lossless,
JPEG-LS, and arithmetic layers are spec-derived; IDCT, color conversion, and
upsampling are IJG-attributed ports. See [LICENSING_NOTES.md](LICENSING_NOTES.md).
JP2 pixel decoding uses OpenJPEG, supplied by Nix or compiled from source;
JP2 validation uses jp2z independently of that decoder.

Run `./build` for the production build and `./test` for the full suite.
Builds default to ReleaseFast; tests default to ReleaseSafe. Nix supplies the
dependencies. `./bm` and `./fuzz` run the separate benchmark and fuzz suites.
Build options and memory ownership are documented in [SPEC.md](SPEC.md).

The libjpeg-turbo and CharLS oracles are optional. Disabling JP2 pixel decoding
with `-Dwith-jp2-decode=false` removes OpenJPEG while retaining JP2 validation.
Windows JXL validation remains disabled in the cross check pending Brotli
vendoring; unavailable JXL validation returns indeterminate.

## Goals

1. **Spec-complete.** Every variant the published JPEG specs define,
   including arithmetic coding (rare but spec-mandatory), 12-bit
   precision, multi-component subsampling, and the lossless mode.
2. **JPEG 2000 in the same project.** Shares packaging, build, ABI
   conventions; separate ABI namespace because the codec internals are
   completely different (wavelet, EBCOT, T2/T1 packets).
3. **No I/O in the core.** Pure Zig core operates on `[]const u8`
   buffers. The row callback API currently materializes the full image.
4. **Hexagonal architecture.** Zig core + C FFI + C validation CLI, per
   project convention.
5. **Self-contained decoding.** Finish the Zig implementations while retaining
   attribution for ported code and independent oracles for verification.

## Status

The JPEG-family validators and C CLI are implemented. Decoder coverage and
entropy validation remain incomplete. JPEG-LS restart handling, uncommon T.81
variants, and exact entropy accounting need further work. See [PLAN.md](PLAN.md)
for measurements and acceptance criteria; pixel parity is not evidence of
complete corruption detection.

## License

MIT (see `LICENSE`), with third-party attribution retained in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Removing a C binary dependency
does not remove the attribution required by code ported into Zig.
