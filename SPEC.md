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

Classic decoding currently includes baseline/extended sequential, progressive,
predictive lossless and arithmetic DCT modes. JPEG-LS decoding is also in Zig.
Consumers import jp2z and libjxlz through the facade, preserving one instance
of each Zig module. Project purpose lives in [INTENT.md](INTENT.md).

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

JP2 pixel output represents one, three or four components. Other counts return
`BackendError` (`JPEGZ_ERR_BACKEND_ERROR` in C) before narrowing the component
count. A valid codestream with an unsupported pixel layout can still validate
as valid; this decode limitation does not establish corruption.

The public dispatcher forwards recovery and findings options to sequential
Huffman, progressive, and lossless decoders. Rejected format probes discard
their own findings; caller findings and genuine decode-error diagnostics stay.
Progressive truncation requires opt-in recovery, with one warning per damaged
restart interval (or scan without restarts). Completed progressive intervals
must exhaust their EOB runs and end with only all-one byte padding. Refinement
scans must supply correction bits for coefficients with nonzero history.
AC-first zero runs and nonzero placements must stay within the scan's selected
coefficient band; a decoded run overflow is an error even in recovery mode.

## 3. Validation contract

`validateAny` sniffs the family and returns a `StrictValidationResult` with
a classified verdict: valid, known_defect, corrupt, unsupported, or indeterminate.
Unrecognized input is indeterminate, with one exception: when the first two
bytes are not an intact SOI and carry no other signature, but at least two
complete T.81 marker segments chain from offset 2, the input keeps its JPEG
identity and is corrupt with FAIL `missing_soi` at offset 0. On 29,181
non-JPEG files this rule identified none as JPEG. Findings preserve source, mapped code,
raw leaf code, and available location information.

The older severity report remains available through `validate` and
`jpeg2000.validate`. Its `isValid()` accepts warnings. The facade supplies
the classified vocabulary and classifies missing EOI, recovered entropy truncation and
missing/misordered restart markers as corrupt. Under validate's 2026-11-05 rule
(FAIL is likely damage, WARN a writer's spec violation; see
`docs/plan_context/severity-audit-2026-11-05.md`) the report gives recovered
truncation and restart findings FAIL severity, so the legacy `isValid()` rejects
them too; the decoders still report them as recovered. Legal 0xFF fill is an
INFO observation, and metadata warnings remain valid. A codec check
that returns `NotImplemented` maps to unsupported; a skipped check maps to
indeterminate. Known corruption takes precedence. The Zig legacy report's
`codec_check` records whether decoding ran; its `isValid()` stays severity-based.
This does not establish complete codec coverage for every decoded variant.
Consumers of the legacy report that label individual findings should call
`classicFindingVerdict(code, severity)` rather than copying this table. It
covers every finding code, and the report-level verdict applies the precedence
above rather than taking the worst label.

`frameHeader(data)` (Zig only) walks markers from SOI to the first T.81 SOFn
without entropy decoding and returns the marker offset, SOFn number, precision,
dimensions and each component's Ci, Hi, Vi and Tqi as stored, for up to 255
components and with no allocation. It also returns the offset of the first DHP
marker before that frame, or null, so a hierarchical stream (T.81 Annex J)
whose first frame is a non-differential SOF0..3 is distinguishable from a plain
one; the DHP segment's contents are not judged. It does not judge sampling factors, zero
height or selectors; `validate` reports those. Its errors separate a stream with
no frame (`NoFrameHeader`, SOS or EOI first, as in TIFF JPEGTables) from
missing SOI, truncation, a malformed marker sequence, an Lf/Nf mismatch and a
JPEG-LS SOF55. `frameKind(n)` classifies every SOFn as sequential, progressive
or lossless, Huffman or arithmetic, differential or not, and baseline (SOF0
only); 4, 8 and 12 are not frames.

jpegz owns recognition of known JPEG encoder defects. All-zero Huffman padding
is `known_defect` (appended verdict value 4), with typed finding 63 at its own
severity, `known_defect` (appended severity value 4). A known defect is
independent of WARN and FAIL and never reads as either (validate, 2026-11-06).
A report's overall severity ranks FAIL > KNOWN_DEFECT > WARN > INFO > PASS, so
any FAIL still wins. Ordinary warnings remain distinct. Corruption retains precedence;
a known defect outranks an unsupported or inconclusive check, which describes
the tool's reach rather than the file (validate, 2026-11-05). Decoding still
accepts the recognized padding defect. The CLI reports `known_defect` in
text/JSON and exits 4.

CLI exit codes follow validate's table where the meaning is shared
(2026-11-06): 0 valid with no WARN, 1 corrupt, 2 usage only, 3 valid with a
WARN deviation, 4 known defect, 5 inconclusive (unsupported, indeterminate or
over the input limit; jpegz only), 66 no such file, 70 internal error, 71 out
of memory, 74 read error, 77 permission denied or no access, 130 interrupted.
Numbers are identifiers, not ranks. Batch precedence is 1, 71, 70, 74, 77, 66,
4, 5, 3, then 0: damage first, then inputs jpegz could not check, and
inconclusive above WARN so unverified bytes never look like a passing warning.

JPEG XL findings keep validity, severity and completion separate. Nonzero
padding and incomplete trailing box headers are corrupt with FAIL severity
even when libjxlz reports warning severity and completes decoding: libjxlz's
severity is a recoverability axis, and the owner's 2026-11-05 rule classes
these likely-damage findings as FAIL. Callback findings retain
their order and offsets; later resource limits cannot erase proven invalidity.

Registry values are append-only and shared with sibling validators.
Use `jpegz_finding_code_name()` for display; do not duplicate the name table.
Code-number changes require the coordination recorded in PLAN.md.

Sequential SOF0/SOF1 SOS fields require Ss=0, Se=63 and Ah=Al=0. Invalid
values report finding 64 at the exact field byte, naming the observed and
required values and the Ah/Al nibble. Zero quantization entries report
finding 52 at the start of the 8-bit entry or 16-bit word. Legal quantizer
values remain accepted, including 16-bit words with one zero byte.

Single-component SOF0/SOF1 headers require each Hi/Vi nibble in 1..4.
Finding 66 identifies an invalid factor at the packed byte and names the
component, offending nibble and allowed range. The initial check covers no
other processes or component layouts. A single-component scan is
noninterleaved; the interleaved sum-of-products limit does not apply to it.

A complete recognized JFIF 1.01 or 1.02 APP0 header with units outside 0..2
reports FAIL/corrupt with finding 65 at the exact units byte. This identifies a
metadata/profile violation. The 1.01 extension uses the independently reviewed
historical IJG 6a units contract, not an original 1.01 normative document.
It does not establish rules for other versions, density, thumbnail lengths
or precision.
Generic application payloads retain their independent interpretation.

A complete recognized JFIF APP0 header declaring major greater than 1, or
major 1/minor greater than 2, reports WARN 67 `jfif_version_unchecked`.
It is a WARN-class deviation, typed "not in the claimed spec version" in its
detail: the strict verdict stays valid (CLI exit 3, WARN) unless corruption,
inconclusive checks or a known defect apply. The exact location names the major byte for a future major,
otherwise the minor byte; detail retains the full observed version and the
unchecked metadata semantics. Historical units rules do not apply to these
future versions. An incomplete header or generic application payload does not
establish this notice. Major zero and 1.00 remain outside its initial scope,
without a claim of complete conformance. A known-padding cause is retained and
gives the known-defect verdict.

Every component of a T.81 frame reports FAIL 66 (`sof_sampling_invalid`) at its
sampling byte when Hi or Vi lies outside 1..4 (Table B.2). An interleaved scan
(Ns > 1) whose otherwise legal factors add up to more than 10 data units per
MCU (B.2.3) reports FAIL 66 at the scan's Ns byte, as libjpeg also refuses it.
JPEG-LS frames are left to the T.87 validator.

Reserved FF02..FFBF markers report FAIL 5 with a corrupt strict verdict: they
have no specified decode, damage produces them and no writer is known. The
codec check still runs, so its findings are kept. A zero marker byte outside
entropy is forbidden and also reports FAIL 5. Both retain their original and
host marker-byte locations.

A second SOF reports FAIL 6 (`duplicate_sof`) at its marker, as libjpeg
refuses it, unless a DHP precedes the first frame. Such a hierarchical stream
(T.81 Annex J) may hold several frames; scans of its differential lossless
frames may use predictor 0 (Table H.1). Its codec check is reported as
unsupported with an INFO finding, never valid.

JP2 strict reports retain positions within the supplied buffer, including
nonexact EOF cursors, and copy them to the standalone host offset. A leaf
position beyond the buffer has null byte/host offsets, with its reported
number preserved in the detail. Bounds alone do not establish exactness;
the pinned leaf does not yet provide exactness metadata. The older JP2
severity-only report retains its existing location behavior pending review.

Classic strict reports likewise retain only positions within the supplied
buffer, preserving nonexact EOF cursors. A declared segment extent beyond
the input has null original/host locations and retains its raw position in
detail. Existing exact header-field findings keep their flags. The older
severity report retains its existing cursor behavior.

JP2 finding 261 (`cblk_contribution_ends_ff`) classifies as corrupt even when
the leaf uses warning treatment. The facade preserves that supplied severity.
Finding 252 (`entropy_under_read`) remains conditional: a heuristic warning
alone does not establish corruption, while a leaf-reported failure remains
corrupt. Other JP2 warning classes still require review.

The JXL adapter recognizes raw ICC-symbol finding 17 as facade code 197
`jxl_invalid_icc_symbol`. Its expected corrupt verdict uses facade FAIL
treatment while preserving the provider's unresolved severity assessment.
Inconsistent pairs remain indeterminate/WARN while retaining whether the
provider assessed severity, and an incomplete callback finding
cannot be erased by a clean final scalar result. Proven corruption wins in
either finding order. Truncation remains its own cause. This adapter contract
does not qualify a provider update; the pinned older leaf cannot emit 17.

JXL stream locations are bounded by the input, preserving leaf-reported exact
EOF positions for required missing data as well as approximate anchors.
Host locations must equal the caller's host base plus the stream position
without overflow; the host base may refer to a larger enclosing file.
Out-of-range stream positions have unknown stream and host locations.
Inconsistent or overflowing host positions become unknown without discarding
an independently bounded stream position. Provider approximate anchors remain
nonexact even when bounded.

Strict validation must account for decoded entropy and surface recovery.
DHT construction rejects oversubscribed code counts and reserved all-ones
codes before code narrowing or lookup-table writes (T.81 Annex C). Legal
near-full tables and tables containing 256 symbols remain accepted.
The implementation still has accounting gaps; the active work order requires
both corruption-detection gains and zero new rejects on the known-good corpus.
Sequential and lossless Huffman scans check padding and exact entropy
consumption at scan ends and restart intervals. Supported lossless scans also
enforce whole-row restart intervals and reset prediction for each interval's
first row. Progressive scans also check padding and EOB-run exhaustion;
remaining coefficient and scan-history constraints are tracked in PLAN.md.
Do not advertise complete corruption detection from pixel-oracle equality.

Sequential Huffman frames reject an additional SOS after all components have
been coded, with exact finding 55 at its first selector. The post-coverage
walk skips length-delimited metadata and stops at the first EOI. It commits
the finding only when EOI is reached, preserving existing missing-EOI decode
behavior and the treatment of bytes after EOI as trailing data.

SOF3 validation also accepts single full-component scans with two or four
components and non-1x1 sampling. It consumes differences, MCU edge padding,
restart intervals and the marker chain through EOI without constructing
pixels. DNL, separated component scans and frames with more than four
components remain unsupported. Pixel decoding retains its narrower layouts.
Entropy finding offsets are payload-relative detection cursors, not exact
mutation locations. Trailing bytes after EOI remain an informational finding.
See [Canon evidence and limits](docs/measurements/canon-sof3-2026-09-24.md).

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
default to ReleaseFast. Fixed fuzz-seed replay is required by `./test`.
`./fuzz --fuzz` selects an optional ReleaseSafe campaign requesting 10000
iterations per harness with a fresh random 32-bit seed per run. The wrapper
prints the seed before the run and again on failure; the failed derivation
also prints the seed and the base64 crash input. `./fuzz --fuzz --seed 0xHEX`
reruns a reported seed, and `packages.fuzz-campaign` keeps the historical seed
0x6a706567. The pinned Zig runner can overshoot the iteration request within a
batch, so it is not an exact count. Both fuzz modes build and execute
inside Nix derivations; `--rebuild` requests fresh execution of a prepared
check. `./bm` runs the separate benchmark suite.

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
