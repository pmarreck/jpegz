# jpegz work plan

Reconciled 2026-09-06 against the local code and the August 27 handoff.
This is the active queue. Earlier measurements, decisions, and commit narratives
are retained in [the historical plan](docs/history/PLAN-2026-08-27.md).
An unchecked historical box does not create a second work order.

## Current baseline

- Branch `yolo`; September 6 documentation and entropy checkpoints passed
  `./test` and `./build`, including unit tests, package build, 71 FFI
  assertions, 49 CLI cases, and three consumer controls. Latest verification:
  2026-09-06 12:54 EDT. Mechatron passed restart-row checkpoint `8b3e7ed`
  at 12:19 EDT (361 seconds); no consumer remeasurement is claimed.
- `validateAny`, JP2/JXL delegation, split C archives, the C validation CLI,
  and prepare-phase locale resolution are implemented.
- JPEG/JPEG-LS pixel dispatch stays in Zig. CharLS and libjpeg-turbo are
  optional oracles; JP2 pixel decode still uses OpenJPEG. JXL validation
  requires Brotli; Windows JXL remains disabled pending vendoring.
- Current leaf pins are in `build.zig.zon`: jp2z `1b29e0c`, libjxlz
  `5e8f9d6`. Both trail upstream and sibling HEADs as checked September 6;
  exact observations are recorded under Dependency freshness.
- Tests default to ReleaseSafe in both build.zig and Nix; builds and
  benchmarks default to ReleaseFast.

## Active order

- [ ] Continue Peter's 12:32 EDT request: unchecked-variant classification,
  public decoder-option forwarding, then progressive entropy boundaries.
  Keep corruption distinct from unsupported or unexamined codec data.
- [ ] Continue the ordered queue per Peter's September 6 request; record
  completed sub-items and their test evidence without marking the whole
  entropy milestone complete before its corpus and mutation checks pass.
- [x] Finish the September documentation reconciliation; `./test` passed
  unit tests, 49 CLI cases, 71 FFI assertions, package build, and three
  consumer controls. _(2026-09-06 11:07 EDT)_
- [ ] JPEG entropy accounting, per Peter's August 27 work order.
- [ ] Dependency-freshness hard gate using the tiffz/validate pattern.
- [ ] Vendor Brotli and restore Windows JXL validation.
- [ ] U5b progress indication.
- [ ] Close the facade promotion with exact-commit CI and consumer pin notes.

Curiosity poke: decoding pixels and passing a structural walk do not establish
that all entropy bytes, blocks, and restart boundaries were checked.

## JPEG entropy accounting

Consumer baseline, reported 2026-08-27: 37/154 single-byte mutations detected
(24.0%, reported interval [18.0, 31.4]); shotgun 146/146. The input was a scanned
baseline JFIF from object 22 of Peter's 49 MB paperwork PDF. The JPEG and seeds
are available from validate; extraction used
`qpdf --show-object=22 --raw-stream-data`. These are historical measurements
on one input, not measured performance of a later revision.

- [x] Prove AC run-overflow behavior with a regression first. A run cannot
  extend beyond the block's 64 coefficients; preserve valid boundary cases.
  September 6 red run: the seven-case classifier failed because four ZRLs
  were accepted (64 zeros in 63 AC slots). All five valid boundary cases
  passed libjpeg-turbo pixel comparisons. The one-line bounds fix passed
  `./test`, including package build and consumer controls.
  _(2026-09-06 EDT)_
- [x] Correct classic-JPEG facade classification of recovered entropy damage.
  The nine-case regression went red on recovered truncation (valid instead of
  corrupt); the adapter fix passed `./test` and `./build`. All three damaged
  cases are corrupt; all six valid controls pass. Legal fill warnings and
  the legacy report API are preserved. _(2026-09-06 11:23 EDT)_
- [x] Classify unchecked classic-JPEG codec variants separately from validity.
  Seven-case regression reproduced unsupported-as-valid. Explicit codec-check
  state now distinguishes unsupported and skipped checks, with corruption
  precedence. Legacy severity semantics and C layout are unchanged. Independent
  review, `./test`, and `./build` pass. _(2026-09-06 12:43 EDT)_
- [x] Forward public `DecodeOptions` to progressive/lossless decoders.
  Public RST-recovery regressions failed before forwarding, then passed with
  identical recovered pixels, with or without a sink. Further red tests found
  duplicate probe warnings (3 instead of 2) and leaked unsupported-probe
  warnings (4 instead of 1). Rejected probes now free only their own findings;
  caller prefixes and real-error diagnostics survive. Independent review,
  native tests, `./test`, and `./build` pass. _(2026-09-06 12:54 EDT)_
- [ ] Enforce exact scan consumption and all-one final padding bits, with
  correct accounting for lookahead and stuffed bytes.
  - [x] Sequential Huffman final-scan boundary: added `finishHuffmanSegment`
    to check all buffered and unread entropy before the next marker. Reject
    bad padding, whole extra bytes, stuffed surplus, and a final RST; retain
    legal marker fill. The 13-case JPEG classifier and 88 bit-reader boundary
    outcomes pass. Independent T.81 review approved this scoped change;
    `./test` and `./build` pass. _(2026-09-06 11:39 EDT)_
  - [x] Sequential Huffman restart boundaries: check padding and surplus
    entropy before resynchronization; opt-in pixel recovery emits a fail
    finding. The 24-case set includes exact-byte endings, partial-edge MCUs,
    short streams, legal fill, and bad interval padding. Independent review,
    `./test`, and `./build` pass. _(2026-09-06 11:51 EDT)_
  - [x] Lossless Huffman scan and restart boundaries: the 20-case classifier
    first failed on accepted zero padding, then passed with checked boundaries.
    Valid samples match libjpeg-turbo; internal lenient recovery retains a
    failure finding. Independent static review and the full `./test` pass.
    _(2026-09-06 12:01 EDT)_
  - [ ] Apply checked boundaries to progressive scans and restart intervals.
    `seekToMarker` still discards unchecked bits there.
    Progressive EOB runs must be exhausted at each boundary without rejecting
    valid byte-aligned runs that span subsequent zero blocks.
- [ ] Enforce MCU counts implied by frame dimensions and sampling, including
  non-interleaved scans and partial edge MCUs.
- [ ] Enforce DRI restart cadence, modulo-eight marker order, and predictor
  reset at the exact MCU boundaries.
  - [x] Lossless DRI must be a whole number of MCU rows (T.81 H.1.1).
    Red classifier reproduced acceptance of non-row intervals. The guard
    passes the 24-case lossless set and two zero-width regressions, plus
    `./test` and `./build`. _(2026-09-06 12:12 EDT)_
  - [x] Reproduce and fix lossless post-restart first-row prediction for
    Ss=2–7 with nonconstant samples. Reproduced pixel 136 instead of 133;
    the first-row counter fix passes 21 cases against hand-calculated pixels
    and libjpeg-turbo, with independent review, `./test`, and `./build`.
    _(2026-09-06 12:12 EDT)_
- [ ] Verify progressive spectral-selection and successive-approximation
  constraints, including the checks already in the structural walker.
- [ ] Classify the known-good corpus as a set, with zero new rejects.
- [ ] Run reproducible entropy-interior mutation sweeps before and after;
  distinguish must-detect malformed streams from mutations that remain legal.
  The old work order suggested 60–85% as a target, but supplied no source;
  report actual counts without treating that band as a proven ceiling or floor.
- [ ] Obtain the consumer JPEG/seeds and arrange end-to-end remeasurement
  through the jpegz → tiffz → validate pin chain when the change is ready.
  Requested the exact path, SHA-256, seeds, and command in validate's inbox
  on September 6 (`2026-09-06-from-jpegz@thelio-nixos-request-original-jpeg-entropy-mutation-fixture-and-seeds.frontmatter.md`).
  Awaiting acknowledgement; no consumer pin update requested yet.
  A read-only check of validate's current PLAN found full-PDF seed
  `1787878036` (historical 303/400 overall, sniper 52.5%). That is not the
  missing extracted-JPEG seed or a new measurement of this revision.

Start in `src/decode/baseline.zig`, `bitstream.zig`, `huffman.zig`, and
`progressive.zig`. Existing restart seeds include
`baseline_128x128_dri4.jpg` and `baseline_16x16_restart.jpg`.
`tests/unit/seed_corpus.zig` and `tests/unit/validate.zig` contain the
existing corpus and mutation patterns.

## Dependency freshness

- [x] Read the implemented gates in tiffz and validate before choosing code.
  Peter explicitly requested their working mechanism, not a new one.
  Read both scripts, classifier tests, and build entrypoints.
  _(2026-09-06 12:12 EDT)_
- [ ] Fail when a pinned dependency trails upstream; when offline, compare
  against the sibling checkout under `~/Code/`.
- [ ] Test stale, current, missing, and offline cases with an independent
  reference and explicit diagnostics. Record which reference was checked.

Curiosity poke: a sandboxed reproducible build cannot silently equate an
unreachable network with proof that a pin is current.

The existing mechanisms differ. `tiffz/tools/check_dependency_freshness` is
upstream-first, falls back to the adjacent sibling, and fails when both are
unavailable. `validate/scripts/check-dep-freshness` defaults to sibling-first,
resolves local mainline and ancestry, and treats unresolvable dependencies as
advisory. Both run before Nix and have explicit stale-pin overrides. Preserve
the requested source order and fail-closed policy when porting; also test
feature-branch checkouts and pins ahead of a sibling to avoid false alarms.

Read-only tiffz-gate runs against this manifest, with no stale override, failed
in both upstream-first and local-first modes at 12:11–12:12 EDT. Both sources
agreed on these heads; pins were not changed:

- jp2z: pinned `1b29e0cdbe43da145294a05fc263bce56c1d5a88`,
  observed `5ae6bcd5a0741080744f47d380ffb527a34f60a9`.
- libjxlz: pinned `5e8f9d68152ae8a70cb823061f4b6c733eb09166`,
  observed `d3ebb07c779283b5524d2f643d152bab830292c5`.

## Brotli and Windows

- [ ] Vendor Brotli source and compile it with Zig, then enable the JXL leg
  for Windows and run the cross checks.
- [ ] Preserve compressed-metadata validation. libjxlz reads JXL `brob`
  payloads; dropping Brotli would skip a known corruption class.
- [ ] Track the previously sent libjxlz FYI about validator exports pulling
  encoder code and `brotlienc` into the link. Removing the encoder dependency
  would still leave decoder/common Brotli dependencies.

The August investigation found no usable nixpkgs mingw Brotli static library.
Keep unavailable validation explicit until the replacement is tested.

## CLI progress (U5b)

- [ ] Add count, elapsed time, ETA, and progress controls for multi-file runs.
- [ ] Render through a pure function receiving state, terminal width, and
  `now`; show actual rendered output to Peter before fixing visual assertions.
- [ ] Test terminal/non-terminal behavior and progressive width degradation.

Scope remains a validation CLI with findings. Decode/convert/encode subcommands
were explicitly excluded. Locale scope and phase remain in `RULES.md`.

## Promotion and consumer coordination

- [ ] Run `./test`, `./build`, and exact manifest targets for the change;
  commit/push green work and obtain terminal Mechatron evidence for that SHA.
- [ ] Send immutable pin/evidence notes to tiffz and validate, plus the global
  inbox evidence requested by the facade work order.
- [ ] Confirm U4 in the consumers: validate routes through `tiffz.jpegz` and
  can remove its separate OpenJPEG/libjxl validation dependencies. Consumer
  edits belong to their project sessions; verify their current state first.
- [ ] Include the outstanding registry FYI for mirrored jp2z codes 145, 146,
  and 250–254 when coordinating.

## Decisions that must survive cleanup

- Sibling jp2z/libjxlz calls use Zig modules. Peter waived their C-FFI
  dogfooding requirement for this facade. jpegz's own C CLI must use its C ABI.
- Preserve one module instance per dependency in a consumer graph.
- C consumers link exactly one of the full and validation archives; each owns
  its thread-local last-error state. Keep system archives out of nested members.
- FindingCode is append-only wire format. No renumbering or new number
  assignments without Einstein's registry sign-off.
- Test the validation closure separately from decoder/oracle builds.
- Provenance is mixed: spec-derived entropy/lossless/JPEG-LS/arithmetic;
  IJG-attributed DSP ports. `LICENSING_NOTES.md` owns the descriptions.
- Output `layout` differs from source color space. A native-color option is
  deferred until a consumer requests it.

## Deferred coverage and design work

- [ ] JPEG-LS restart support and dormant `jpegls_invalid_run_mode` /
  `jpegls_context_table_invalid` findings. DRI is currently skipped in the
  decoder; do not describe that as verified support.
- [ ] Inventory remaining T.81/T.87 variant gaps with fixtures, including
  uncommon lossless sampling, differential/hierarchical modes, and component
  layouts. Old comments about point transform and ILV=1 are not current evidence.
- [ ] Complete JP2 pixel cutover when the sibling implementation and consumer
  requirements permit it. Keep OpenJPEG optional for validation consumers.
- [ ] Consider DRI parallel entropy decoding and SIMD DSP after correctness.
- [ ] Evaluate a spec-derived production IDCT/color path only after measuring
  pixel divergence and coordinating with Einstein/tiffz/validate. This is a
  design option, not a commitment to replace the attributed ports.

## Recent documentation work

- [x] Consumed and trashed both old handoffs; retained restore metadata and Git
  history. Removed the orphaned dirtree note. _(2026-08-27 22:48 EDT)_
- [x] Replaced stale scaffold/ABI descriptions; removed the duplicate May work
  queue while retaining cited decisions; separated pixel decoding from
  validation dependencies and removed unsourced JXL market predictions.
  Archived the old PLAN without losing its historical evidence.
  _(2026-09-06 EDT)_

Curiosity poke: keep dated evidence dated; never revive an old blocked-state
instruction because it appears later in a long document.
