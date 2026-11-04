# PLAN

Evidence and earlier request details: [queue context](docs/plan_context/pre-canon-2026-09-24.md).
Completed history: [plan log](docs/PLAN_LOG.md).

## Priority: dependency freshness

- [x] Acknowledge the recovery notice, consume superseded UPS notices and verify the preserved checkout and pinned toolchain before resuming the fuzz gate (done 2026-11-02 20:09 EST; recovery acknowledged).
- [x] Verify the crash-aware fuzz gate against the real bounded campaign and complete suite; the seed-0x6a706567 campaign now fails on the recorded progressive crash instead of passing, and all thirteen ./test checks pass (context: docs/plan_context/validate-findings-2026-09-27-to-10-14.md; done 2026-11-03 20:42 EST; commit 08e622a).
- [x] Recover and fix the progressive AC-refinement fuzz crash: an Ah=1/Al=15 refinement overflowed i16 at 1 << Al; parseSos now rejects Al > 13 and every progressive i16 coefficient conversion returns BackendError, with the fuzz input, six synthetic red witnesses and in-range controls; the same campaign then passes 11298 decode runs (context: docs/plan_context/validate-findings-2026-09-27-to-10-14.md; done 2026-11-03 20:44 EST; commit a3e5cac).
- [x] Ship 08e622a, a3e5cac and 0ba8802: combined ./test 13/13, push verified, Mechatron Prime PASS 13/13 at 37231b9 (18 s, prepared reuse), package hash jpegz-0.1.0-staw4JSgFQDuobcXQtQFVjbBqMBzzSzQMAx7v2Ak-s0G; receipts sent to tiffz, validate and coordinator (done 2026-11-03 21:12 EST; commit 37231b9).
- [ ] Determine which terminal layer owns copy mode on a remote SSH session and document client-side clipboard routing; client terminal and activation shortcut requested, settings unchanged.
- [ ] Resolve the corruption-coverage default JPEG-LS fixture mismatch; owner choice requested among three supported defaults, an audited inconclusive JPEG-LS control, or retaining the blocked campaign; preserve classifications and denominators.
- [ ] Keep the non-luma-dominant sampling packet held; do not retry that research or edit the decoder for it without new direction.
- [ ] Keep the published JP2 pin and its real Nix closure hash; do not restore draft pin 54531e26 or any placeholder hash.

## Priority: Validate September 30 work order

- [ ] Reproduce and fix the non-luma-dominant sampling panic with synthetic inputs and valid sampling controls; return typed failure or support the layout without out-of-bounds access.
- [x] Receive Validate's exact September 30 item-4 SOF1 replay on published d88957b; all three streams report only known-defect padding 63 with CLI 4 and strict djpeg acceptance, closing replay without a decoder change or consumer-adoption claim (done 2026-10-29 16:13 EDT; provider receipt).
- [ ] Finish JP2 leaf exactness metadata and audit legacy severity-report locations; the provider cursor/anchor/extent contract is pending, so bounds alone must not imply exactness (context: docs/plan_context/validate-findings-2026-09-27-to-10-14.md).

## Priority: DHT memory safety

- [ ] Investigate Validate's full-stream false rejection; all four September 27 Huffman count vectors pass synthetic controls, but their acceptance does not establish validity of the private original.

## Priority: Canon CR2 sensor validation

- [ ] Confirm Validate's private full-container NRW/AVI replays after the tiffz re-pin without publishing originals or mutants.

## Existing ordered follow-ups

- [ ] Complete the separate libjxlz arithmetic scaling sweep; published e1c521d contains baseline 923d3c4c unchanged (228 fixed-size rows, hash verified), and the provider has a request for published scaling evidence or a bounded sweep (context: docs/plan_context/pre-canon-2026-09-24.md).
- [ ] Finish provider qualification after source review of jp2z 0c2162b and libjxlz e1c521d; facade 197 is shipped and libjxlz CI is complete for five targets at 1a53d9d9 and d6cfb688 (prepared-artifact reuse); real-input integration and cold private-source access remain required before any pin change; the November 3 provider note (more raw-8 histogram cases now raw-16 corrupt, open container prefixes now NEED_MORE_INPUT, local five-target evidence only) joins the same review (context: docs/plan_context/validate-findings-2026-09-27-to-10-14.md).
- [ ] Verify jp2z pixel APIs and component-resolution oracles before replacing OpenJPEG; retain the T.800 edition limit and unresolved warning-class review.
- [x] Export classicFindingVerdict(code, severity) for tiffz with an exhaustive FindingCode switch; classifyClassicFindings folds over it with unchanged precedence, checked across all 85 codes and four severities against a literal table and the fold; acknowledgment sent, revision follows shipment (done 2026-11-03 20:38 EST; commit 0ba8802).

## JPEG entropy and comparison coverage

- [ ] Measure the zero-padding treatment change over identical seeded corruption-coverage inputs, reporting known defects separately while preserving the judged-case denominator.
- [ ] Complete scan consumption, MCU counts, sampling edges, noninterleaved scans, restart cadence and predictor-reset coverage across supported modes.
- [ ] Complete progressive scan-history and coefficient-range constraints with independent normative review and valid boundary controls.
- [ ] Classify the known-good corpus as a set and expand reproducible corruption-probe sweeps across JPEG-LS, JPEG 2000 and JPEG XL.
- [x] Publish d88957b with the mutation-profile correction; all eleven exact-commit CI targets pass in 16 seconds with prepared reuse, and scoped receipts preserve profile identities and pending pristine-control decisions (done 2026-10-29 13:49 EDT; commit d88957b).
- [x] Move ./fuzz compilation into Nix derivations with fixed seed replay in ./test and a bounded 10000-iteration-request campaign; duration flags and custom compiler arguments are refused (done 2026-11-03 20:42 EST; commit 08e622a).
- [ ] Compare proven malformed fixtures and false rejects against prior art; report demonstrated detection, hypothetical detectability and valid changes separately.
- [ ] Confirm consumer promotion through tiffz.jpegz and rerun the private full-PDF experiment without publishing originals or mutants (context: docs/plan_context/pre-canon-2026-09-24.md).

## Build and CLI

- [x] Prevent ./test from publishing the checkout result link: a disposable-project stub-nix regression found seven builds without --no-link and a replaced sentinel; all thirteen builds now pass --no-link and the check runs in the unit-test step (done 2026-11-03 21:33 EST; delivered by this change).
- [ ] Measure fresh test execution separately from admission, dependency setup, evaluation and compilation; preserve complete coverage and report the one-second target/five-second budget; cached CI artifact reuse is qualified at dedea64 (context: docs/plan_context/validate-findings-2026-09-27-to-10-14.md).
- [ ] Port the requested upstream-first dependency-freshness gate with sibling fallback and set tests for current, stale, missing, offline and ahead-of-sibling cases.
- [ ] Vendor Brotli, preserve compressed-metadata validation, enable Windows JXL and run cross checks; coordinate the unnecessary encoder linkage with libjxlz.
- [ ] Add U5b progress controls and pure timestamp-injected rendering; verify rendered output with Peter and test terminal/width degradation.
- [ ] Confirm consumer dependency deduplication and send remaining append-only finding-registry notices (context: docs/plan_context/pre-canon-2026-09-24.md).

## Deferred

- [ ] Implement JPEG-LS restart validation and test dormant run-mode/context findings.
- [ ] Inventory remaining T.81/T.87 gaps including DNL, multiscan lossless, differential/hierarchical modes and uncommon component layouts.
- [ ] Consider DRI parallelism and SIMD after correctness coverage; measure pixel divergence before proposing spec-derived IDCT/color replacement.
- [x] Gate the C CLI "DEBUG BUILD" banner on the real optimize mode: build.zig defines JPEGZ_DEBUG_BUILD, the source refuses to compile without it, and tests/cli asserts the banner matches the mode (red in ReleaseSafe before the fix) (done 2026-11-03 22:03 EST; delivered by this change).
