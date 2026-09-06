# jpegz specification

Reconciled with this repository on 2026-09-06. This document describes the
implemented interface and its intended guarantees. Measured gaps and priorities
live in [PLAN.md](PLAN.md); standing constraints live in [RULES.md](RULES.md).
The original May design is available in Git history and
[the public API design](docs/superpowers/specs/2026-05-04-jpegz-public-api-design.md).

## 1. Scope

jpegz owns the outward JPEG-family validation interface. Classic JPEG and
JPEG-LS use jpegz's Zig code; JP2/J2K and JPEG XL validation use pinned jp2z
and libjxlz modules. Pixel decoding supports a growing subset of T.81/T.87
and uses OpenJPEG for T.800. JPEG XL pixel decoding is outside the current
jpegz API.

Spec completeness is the goal. Unsupported variants, incomplete checks, and
corruption must remain distinguishable. No fallback may turn an unchecked
stream into a valid result.

## 2. API and ownership

The published declarations are authoritative:
[src/jpegz.zig](src/jpegz.zig) for Zig and
[include/jpegz_core.h](include/jpegz_core.h) for C.

| Operation | Zig | C |
|---|---|---|
| Family validation | `validateAny(allocator, data)` | `jpegz_validate_any(data, len, out)` |
| Classic decode | `decode(allocator, data)` | `jpegz_decode(data, len, out)` |
| Decode options | `decodeWithOptions(allocator, data, options)` | `jpegz_decode_ex(data, len, options, out)` |
| JP2 pixels | `jpeg2000.decode(allocator, data)` | `jpegz_jp2_decode(data, len, out)` |
| Row callbacks | `decodeStreamingRows` | `jpegz_decode_streaming_rows` |

Input is a borrowed `[]const u8` buffer in Zig or a pointer plus length in C.
There is no public source-vtable input. Core code performs no file I/O.

Zig images and reports own allocations and must be deinitialized with the
allocator used to create them. C callers use the matching free functions,
including `jpegz_image_free` and `jpegz_strict_result_free`.
Row callbacks receive borrowed bytes, valid only during the callback.
Callback failure aborts delivery and preserves the diagnostic through the
last-error API. Higher-precision samples occupy host-endian 16-bit storage.

Row callbacks currently materialize the full image first. Both Huffman and
arithmetic progressive frames return `NotRowStreamable`; supported sequential
modes follow the normal decoder's capability limits.

`DecodeOptions.threads` defaults to 1, meaning the calling thread. Zero
explicitly requests automatic selection; larger values are budgets. Actual
parallelism depends on the decoder. JP2's current wrapper ignores this option.
`lenient` defaults to false. Opt-in recovery can return partial pixels;
attach a `FindingsSink` to retain the recovery diagnostics.
The public dispatcher forwards recovery and findings options to sequential
Huffman, progressive, and lossless decoders. Rejected format probes discard
their own findings; caller findings and genuine decode-error diagnostics stay.
Progressive truncation requires opt-in recovery, with one warning per damaged
restart interval (or scan without restarts). Completed progressive intervals
must exhaust their EOB runs and end with only all-one byte padding. Refinement
scans must supply correction bits for coefficients with nonzero history.

## 3. Validation contract

`validateAny` sniffs the family and returns a `StrictValidationResult` with
a four-way verdict: valid, corrupt, unsupported, or indeterminate.
Unrecognized input is indeterminate. Findings preserve source, mapped code,
raw leaf code, and available location information.

The older severity report remains available through `validate` and
`jpeg2000.validate`. Its `isValid()` accepts warnings. The facade supplies
the four-way vocabulary and classifies recovered entropy truncation and
missing/misordered restart markers as corrupt, even when their findings have
warning severity. Legal fill and metadata warnings remain valid. A codec check
that returns `NotImplemented` maps to unsupported; a skipped check maps to
indeterminate. Known corruption takes precedence. The Zig legacy report's
`codec_check` records whether decoding ran; its `isValid()` stays severity-based.
This does not establish complete codec coverage for every decoded variant.

Registry values are append-only and shared with sibling validators.
Use `jpegz_finding_code_name()` for display; do not duplicate the name table.
Code-number changes require the coordination recorded in PLAN.md.

Strict validation must account for decoded entropy and surface recovery.
The implementation still has accounting gaps; the active work order requires
both corruption-detection gains and zero new rejects on the known-good corpus.
Sequential and lossless Huffman scans check padding and exact entropy
consumption at scan ends and restart intervals. Supported lossless scans also
enforce whole-row restart intervals and reset prediction for each interval's
first row. Progressive boundary checks remain pending.
Do not advertise complete corruption detection from pixel-oracle equality.

## 4. Artifacts and dependencies

Link exactly one C archive. Each carries its own thread-local last-error state.

| Artifact | Purpose | Dependencies |
|---|---|---|
| `libjpegz-validate.a` | Validation API | Brotli for enabled JXL |
| `libjpegz.a` | Validation and pixel API | Brotli; OpenJPEG for JP2 decode; optional test oracles |
| `jpegz` | C validation CLI | Validation archive |

Static archive consumers supply the enabled dependency libraries at final link;
system archives are not bundled as nested members.

- `-Dwith-libjpeg-oracle=false` drops the libjpeg-turbo test oracle.
- `-Dwith-charls=false` drops the CharLS test oracle; JPEG-LS stays in Zig.
- `-Dwith-jp2-decode=false` drops OpenJPEG. JP2 validation stays available;
  requesting JP2 pixels returns `NotImplemented`.
- `-Dwith-jxl=false` disables JXL validation. Sniffing still recognizes JXL,
  with an indeterminate verdict and `jxl_validator_unavailable`.
  The Windows cross check currently uses this until Brotli is vendored.

Exact leaf versions belong in [build.zig.zon](build.zig.zon).
Historical classifier and closure measurements are dated in
[docs/VALIDATION_FACADE_EVIDENCE.md](docs/VALIDATION_FACADE_EVIDENCE.md).

## 5. Development and acceptance

Use `./test` for all unit, CLI, package, and consumer checks, and `./build`
for the production build. Tests default to ReleaseSafe; production builds
default to ReleaseFast. `./bm` and `./fuzz` are separate entry points.

Nix supplies dependencies and sandboxed build outputs. Mechatron Prime uses
[.mechatron-prime/targets](.mechatron-prime/targets); exact-commit CI evidence
is required before reporting a shipped gate as green.

Each behavior change starts with a failing regression. Codec tests compare
pixels against independent oracles; validation tests classify sets of good,
bad, unsupported, and inconclusive inputs. New entropy checks require mutation
measurements over scan interiors, alongside known-good specificity controls.

## 6. Provenance and design references

[LICENSING_NOTES.md](LICENSING_NOTES.md) owns the distinction between
spec-derived code and ports. Keep IJG attribution for ported DSP kernels even
if the libjpeg-turbo binary dependency is removed.

The design records under `docs/superpowers/specs/` explain individual
implementations. [NEXT_STEPS.md](NEXT_STEPS.md) retains cited decisions from
the retired May handoff; it is not a second work queue.
