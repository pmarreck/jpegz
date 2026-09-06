# jpegz work plan

Reconciled 2026-09-06 against the local code and the August 27 handoff.
This is the active queue. Earlier measurements, decisions, and commit narratives
are retained in [the historical plan](docs/history/PLAN-2026-08-27.md).
An unchecked historical box does not create a second work order.

## Current baseline

- Branch `yolo`; September 6 documentation and entropy checkpoints passed
  `./test` and `./build`, including unit tests, package build, 71 FFI
  assertions, 49 CLI cases, and three consumer controls. Latest verification:
  2026-09-06 13:40 EDT, plus Windows cross-build and validator closure.
  Mechatron passed progressive-boundary checkpoint `7df6ba3`
  at 13:45 EDT (383 seconds), then AC-band checkpoint `e8f9982`
  at 13:56 EDT (401 seconds), each on all four manifest targets.
  Controlled consumer remeasurement at earlier checkpoint `8b3e7ed` is below.
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

- [x] Complete the next three scoped units from Peter's 12:32 EDT request:
  unchecked-variant classification, public decoder-option forwarding, and
  progressive entropy boundaries. Individual evidence is below; broader
  entropy coverage remains open. _(2026-09-06 13:06 EDT)_
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
  - [x] Apply checked boundaries to progressive scans and restart intervals.
    The red set accepted a zero DC padding bit after 12 valid controls passed
    libjpeg pixel comparisons. All 29 cases now pass: EOB exhaustion, marker
    lookahead, padding/stuffing, edge blocks, final RST rejection, required
    refinement bits, per-interval recovery warnings, and nonzero output after
    recovery. Public truncation now requires lenient mode; the legacy recovery
    helper remains explicit. The facade rejects recovered 12-bit progressive
    damage. Independent review, native/full tests, build, Windows cross-build,
    and validator closure pass. _(2026-09-06 13:06 EDT)_
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
  - [x] Bound progressive AC zero runs and nonzero placement to the selected
    band. Red tests reproduced four accepted ZRLs in 63 slots, then a legacy
    valid verdict for a nonzero placed beyond Se. A 15-case complete-band set
    now passes, with exact-fit/narrow-band controls and observable nonzero
    libjpeg pixel comparisons. Independent review, native/full tests, build,
    Windows cross-build, and validator closure pass. _(2026-09-06 13:40 EDT)_
  Legacy DC-category and AC-refinement-symbol guards still label illegal decoded
  symbols as insufficient data when lookahead has seen a marker. Strict decode
  rejects these, but their legacy recovery classification needs separate tests.
- [ ] Classify the known-good corpus as a set, with zero new rejects.
- [ ] Run reproducible entropy-interior mutation sweeps before and after;
  distinguish must-detect malformed streams from mutations that remain legal.
  The old work order suggested 60–85% as a target, but supplied no source;
  report actual counts without treating that band as a proven ceiling or floor.
- [x] Obtain the original consumer JPEG and mutation recipe. Validate supplied
  seed `1787878261`, 300 rounds, sniper+shotgun, shotgun span4096, auto jobs,
  default early-stop radius0.025. Independently verified 698,412 bytes and
  SHA-256 `4a2e013e63ff9674ebce3f19cde91491e827ca1fb8202a2f0c22da7ef44154fa`.
  Validate reports reproducing 183/300 overall, including the historical
  37/154 sniper and 146/146 shotgun counts, using consumer `c582e410c`.
  This is private, local-only paperwork: never commit or upload the original
  or mutated derivatives. Paths and extraction recipe are kept privately in
  `.git/jpegz-private-entropy-reproducer.md`. _(2026-09-06 13:33 EDT)_
  The current ReleaseFast jpegz CLI independently accepts the original as valid
  baseline Huffman, 2538x3296, with only JFIF metadata information (13:40 EDT).
- [x] Run the controlled extracted-JPEG comparison through tiffz and validate.
  Independently reran validate's signed before/after binaries: `89d74e3` to
  CI-green `8b3e7ed` improved single-byte detection from 37/154 to 47/154
  (24.0% to 30.5%); shotgun stayed 146/146, and both clean-input controls pass.
  Validate's build record reports fixed consumer, toolchain, and other sources;
  jpegz checked the manifest change, binary/input hashes, and result replays.
  This measures one input and seed, not later progressive checkpoints or a
  general rate. See [provenance and results](docs/measurements/jpeg-entropy-2026-09-06.md).
  No consumer pin was promoted. _(2026-09-06 13:49 EDT)_
- [ ] Promote an immutable CI-green final revision through tiffz → validate
  and remeasure full-PDF acceptance (seed 1787878036, 400 rounds; historical
  baseline 303/400, sniper 52.5%). Keep originals and mutants local-only.
  Requested consumer-owned promotion of CI-green source checkpoint `e8f9982`
  from validate by durable inbox note at 14:00 EDT on September 6; receipt,
  promoted pins, and full-PDF results remain pending.

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
