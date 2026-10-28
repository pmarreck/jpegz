# PLAN

Evidence and earlier request details: [queue context](docs/plan_context/pre-canon-2026-09-24.md).
Completed history: [plan log](docs/PLAN_LOG.md).

## Priority: dependency freshness

- [ ] Determine which terminal layer owns copy mode on a remote SSH session and document client-side clipboard routing; do not change settings unasked.
- [ ] Re-lock tools/coverage after corruption_reader repins performance_profiling 01ae85b (published 2026-10-20 21:50 EDT; our lock reaches it only through corruption_reader 3ea60b7, which still pins a04d62a and printable_binary 3f697d5). Bump root nixpkgs to the current head in the same re-lock.
- [ ] Reconcile the October 14 inbox with published f1a255a and later yolo c8937a7. The provider hold is released for pin adoption and the sampling packet stays held. Advance one unblocked milestone and send the coordinator a receipt with any genuine owner decisions.
- [ ] Keep the non-luma-dominant sampling packet held; do not retry that research or edit the decoder for it without new direction.
- [ ] Keep the published JP2 pin and its real Nix closure hash; do not restore draft pin 54531e26 or any placeholder hash.
- [ ] Mirror approved JP2 finding 261 with a red mapping/ABI regression and conditional-severity controls for 252; do not retry the held sampling research.

## Priority: Validate false FAILs and labels (context: docs/plan_context/validate-findings-2026-09-27-to-10-14.md)

- [x] Expose KNOWN_DEFECT from jpegz as appended Zig/C verdict 4 and CLI exit 4; zero entropy padding keeps WARN treatment, ordinary warnings exit 0, and stronger batch outcomes retain precedence; full ./test passes (done 2026-10-28 15:52 EDT; delivered by this change).
- [x] Should INTENT.md record the known-defect exception? Answer: yes; jpegz identifies known JPEG defects and reports KNOWN_DEFECT separately from WARN treatment, validate consumes that classification, and corrupt/unopenable output or reader rejection can still require FAIL (done 2026-10-28 15:52 EDT; delivered by this change).
- [x] Fix the false FAIL on a valid three-scan non-interleaved sequential JPEG (cjpeg -scans 0;1;2) with a red legal test and a malformed undefined-table counterpart. Baseline now decodes split-component sequential frames (T.81 §3.1.116, §A.2, §B.2.3); four cjpeg fixtures match libjpeg-turbo byte for byte; repeated components, early EOI and undefined tables FAIL. (2026-10-20 12:15 EDT)
- [x] Complete the padding KNOWN_DEFECT contract: jpegz identifies the defect and returns its classification; WARN is treatment, mixed padding stays FAIL, and consumers apply application policy (context: docs/plan_context/validate-findings-2026-09-27-to-10-14.md; done 2026-10-28 15:52 EDT; delivered by this change).
  - [x] Lenient decoding continues past end-of-scan padding faults when a marker follows, so every instance is reported and recovery matches libjpeg-turbo pixels (done 2026-10-23 10:40 EDT).
  - [x] Code 63 `entropy_padding_zero_bits` for all-zero pad bits (WARN, exact pad byte, bit count in the detail); 62 narrows to mixed bits. Validate verified 63 unused and endorsed it; registry coordinator sign-off 2026-10-23 ~1:55 PM EDT. Conditions: append-only (62 keeps number and name), tests over the set of pad widths 1..7 (all 0 -> 63, mixed -> 62, all 1 -> none; width 1 has no mixed pattern), non-boundary cases unchanged, consumer mapping coordinated with validate. Not a KNOWN_DEFECT admission. (done 2026-10-23 6:30 PM EDT)
  - [x] The same all-zero WARN for progressive and lossless scans (strict decode accepts; lenient and validation report 63 at the exact pad byte). (done 2026-10-23 6:30 PM EDT)
- [x] Reject additional sequential Huffman SOS after complete component coverage with exact FAIL 55; skip opaque metadata, stop at first EOI and preserve missing-EOI decode outcomes; full ./test passes (done 2026-10-28 17:21 EDT; delivered by this change).
- [x] Report baseline restart and padding findings at absolute file offsets (done with the distinct-codes item, 2026-10-20).
- [x] Apply FAIL 62 to mixed padding in progressive and lossless Huffman scans at exact absolute pad-byte offsets, including strict decode and lenient restart recovery, without generic 51 duplication; arithmetic stays excluded (done 2026-10-28 15:52 EDT; delivered by this change).
- [x] Give repeated T.81 SOS selectors and invalid sequential Ns exact finding 55, and bad sequential Ls exact finding 4, before entropy decoding; reserve the scan tail when Ns is excessive; full ./test and valid four-component controls pass (done 2026-10-28 16:51 EDT; delivered by this change).
- [x] Give restart-after-final-MCU, interval-boundary truncation and non-1 padding their own registry-numbered finding codes with exact offsets, keeping FAIL severity. Baseline/extended sequential Huffman now emits 62, 57, 3 and 55 at absolute offsets with `offset_is_exact`; the generic 51 is no longer added beside a typed FAIL. (2026-10-20 13:30 EDT)

## Priority: Validate September 30 work order

- [ ] Reproduce and fix the non-luma-dominant sampling panic with synthetic inputs and valid sampling controls; return typed failure or support the layout without out-of-bounds access.
- [ ] Reproduce SOF1 with component ids 0/1/2 and Huffman table pairs 0/1/2; accept legal table ids 0-3 and distinguish any remaining private-stream failure.
- [ ] Verify JP2 leaf offset semantics; preserve exact in-buffer offsets and represent EOF or declared extents without claiming nonexistent byte locations.
- [x] Reproduce zero-bit entropy padding with its own typed finding and exact byte offset (T.81 F.1.2.3). Superseded on severity by the BDFN rulings of 2026-10-23 and 2026-10-27: all-zero padding is WARN 63 and decodes, mixed padding is FAIL 62. Landed in 8fd246d (done 2026-10-23 6:30 PM EDT).
- [ ] Publish green bounded fixes and send Validate/tiffz exact SHA, package hash, scope and remaining blockers; preserve 5c5191a and 6ef766c.

## Priority: DHT memory safety

- [ ] Investigate Validate's full-stream false rejection; all four September 27 Huffman count vectors pass synthetic controls, but their acceptance does not establish validity of the private original.

## Priority: Canon CR2 sensor validation

- [ ] Confirm Validate's private full-container NRW/AVI replays after the tiffz re-pin without publishing originals or mutants.

## Existing ordered follow-ups

- [ ] Finish libjxlz benchmark-history publication coordination and the separate arithmetic scaling sweep; September 28 inspection finds local baseline 923d3c4c committed but the September 20 release-of-hold note still pending and the sibling PLAN still waiting for that baseline (context: docs/plan_context/pre-canon-2026-09-24.md).
- [ ] Adjudicate validate's 170-byte XOR sweep and proposed marker/JFIF/DQT/SOS checks against normative clauses and valid controls (context: docs/plan_context/pre-canon-2026-09-24.md).
- [ ] Evaluate validate's coverage-range API without exempting whole constrained segments or changing denominators to improve scores.
- [ ] Review newly published jp2z/libjxlz work before future pin changes; verify private-source access and preserve strict corruption precedence.
- [ ] Verify jp2z pixel APIs and component-resolution oracles before replacing OpenJPEG; retain the T.800 edition limit and unresolved warning-class review.

## JPEG entropy and comparison coverage

- [ ] Measure the zero-padding treatment change over identical seeded corruption-coverage inputs, reporting known defects separately while preserving the judged-case denominator.
- [ ] Complete scan consumption, MCU counts, sampling edges, noninterleaved scans, restart cadence and predictor-reset coverage across supported modes.
- [ ] Complete progressive scan-history and coefficient-range constraints with independent normative review and valid boundary controls.
- [ ] Classify the known-good corpus as a set and expand reproducible corruption-probe sweeps across JPEG-LS, JPEG 2000 and JPEG XL.
- [ ] Align local mutation usage with corruption_probe a43f2cf algorithm v2: sparse shotgun flips 8-16 distinct bits in a contained 32-byte window; dense overwrite is nuke; preserve v1 history and never compare unlike definitions.
- [ ] Compare proven malformed fixtures and false rejects against prior art; report demonstrated detection, hypothetical detectability and valid changes separately.
- [ ] Confirm consumer promotion through tiffz.jpegz and rerun the private full-PDF experiment without publishing originals or mutants (context: docs/plan_context/pre-canon-2026-09-24.md).

## Build and CLI

- [ ] Investigate gate feedback latency, whole-tree Nix source inputs and artifact reuse; measure compilation, queue/setup and test execution separately while preserving complete coverage (context: docs/plan_context/validate-findings-2026-09-27-to-10-14.md).
- [ ] Port the requested upstream-first dependency-freshness gate with sibling fallback and set tests for current, stale, missing, offline and ahead-of-sibling cases.
- [ ] Vendor Brotli, preserve compressed-metadata validation, enable Windows JXL and run cross checks; coordinate the unnecessary encoder linkage with libjxlz.
- [ ] Add U5b progress controls and pure timestamp-injected rendering; verify rendered output with Peter and test terminal/width degradation.
- [ ] Confirm consumer dependency deduplication and send remaining append-only finding-registry notices (context: docs/plan_context/pre-canon-2026-09-24.md).

## Deferred

- [ ] Implement JPEG-LS restart validation and test dormant run-mode/context findings.
- [ ] Inventory remaining T.81/T.87 gaps including DNL, multiscan lossless, differential/hierarchical modes and uncommon component layouts.
- [ ] Consider DRI parallelism and SIMD after correctness coverage; measure pixel divergence before proposing spec-derived IDCT/color replacement.
- [ ] The C CLI prints "DEBUG BUILD" in ReleaseSafe because it keys on NDEBUG, which Zig leaves undefined there. Gate the banner on the real optimize mode (a build-time define) and cover ReleaseSafe in tests/cli.
