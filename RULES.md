# jpegz — standing rules

Things that should always hold. Violating one needs an excellent reason and an
explicit note saying why.

## Internationalization

- **Status:** `enabled` — prepare phase
- **Decision owner:** Peter Marreck
- **Date:** 2026-08-10 EDT
- **Scope:** the `jpegz` C CLI's user-facing output (help, verdicts, findings,
  errors). The Zig core and C ABI stay locale-neutral: they return typed codes,
  and rendering those codes into a human language is the CLI's job.
- **Rationale:** recorded per Peter's U5b directive, which names
  "i18n groundwork (`--lang` + `JPEGZ_LANG`)" as in-scope work. jpegz is a
  distributed cross-platform tool, not a personal utility, so the i18n skill's
  economics apply.

Prepare phase means the infrastructure must accept any of the canonical 50
locales and resolve them correctly, but a missing catalog is a loud non-fatal
warning rather than a build failure. Flipping to enforce phase — where a
missing translation breaks the build — waits until the CLI's string surface
stops churning. See `docs/I18N.md`.

## C FFI dogfooding

- The `jpegz` CLI is written in C so that bypassing the published ABI is
  *inexpressible* rather than merely discouraged: C cannot `@import` a Zig
  module. Do not rewrite it in Zig.
- Sibling Zig libraries (jp2z, libjxlz) are consumed as Zig modules, not
  through their C ABIs. Per Peter's 2026-07-31 ruling, the FFI-dogfooding
  requirement exists so an FFI is *exercised*; forcing Zig→C→Zig between
  siblings sacrifices type safety for ceremony. jpegz's own C ABI still must
  be dogfooded, and the CLI is what does it.

## Validation closure

- The validation-only artifacts (`libjpegz-validate.a`, the `jpegz` CLI,
  `jpegz-validator-proof`) must contain no external JPEG-family decoder:
  no OpenJPEG, no libjpeg, no CharLS, no upstream libjxl or djxl. Brotli is
  the one permitted C dependency, because libjxlz reads Brotli-compressed JXL
  container metadata.
- `checks.<system>.validator-closure` enforces this mechanically. Do not
  weaken it to make a link succeed.

## Finding-code registry

- `src/core/errors.zig`'s `FindingCode` is **append-only wire format**, shared
  numerically with jp2z and libjxlz. Never renumber or reuse a value.
- Consumers must use `jpegz_finding_code_name()` rather than maintaining their
  own code→name table, which would silently drift as codes are appended.
