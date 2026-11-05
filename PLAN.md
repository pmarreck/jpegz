# PLAN

Evidence and earlier request details: [queue context](docs/plan_context/pre-canon-2026-09-24.md).
Completed history: [plan log](docs/PLAN_LOG.md).

## Priority: dependency freshness

- [x] Ship 08e622a, a3e5cac and 0ba8802: combined ./test 13/13, push verified, Mechatron Prime PASS 13/13 at 37231b9 (18 s, prepared reuse), package hash jpegz-0.1.0-staw4JSgFQDuobcXQtQFVjbBqMBzzSzQMAx7v2Ak-s0G; receipts sent to tiffz, validate and coordinator (done 2026-11-03 21:12 EST; commit 37231b9).
- [x] Randomize the ./fuzz --fuzz campaign seed per run and log it for reproduction: fresh 32-bit seed announced before the run, repeated with a ./fuzz --fuzz --seed 0xHEX command on failure by the wrapper and the gate, which also prints the saved crash input in base64 up to 64 KiB; ./test replay and packages.fuzz-campaign keep 0x6a706567. Red-first wrapper (9 failures) and gate (91/184) tests; random seed 0x7f6b2e4d passed 11289 decode/10305 validate runs; the unfixed decoder under --seed 0x6a706567 failed at 9492 runs and its printed base64 decoded to the original 286-byte crash (BLAKE3 101f796d); ./test passed, Mechatron Prime PASS 23 s (done 2026-11-04 02:33 EST; commit b287cc9).
- [x] Where is the canonical FindingCode registry? (question from coordinator Einstein) Answer: no standalone shared file exists; numbers live in jpegz src/core/errors.zig (the only complete superset, generating the C header and names), jp2z keeps its leaf subset and contract table, and approvals live in the coordinator's PLAN/context records; mirrored jp2z codes are 140-146, 207-208 and 250-261, all name/number-identical to jp2z 0c2162b, with 147-154 unassigned. A generated, test-enforced docs/FINDING_CODES.md provenance table was proposed for coordinator/owner approval; nothing created (done 2026-11-04 01:35 EST; reply note sent).
- [x] Fix the b287cc9 campaign wrapper building from every file on disk (builtins.getFlake on a path includes untracked files): the seed now travels in JPEGZ_FUZZ_SEED to legacyPackages.fuzz-campaign-seeded under --impure, so campaigns use the same git-tracked source as ./test; verified the seeded source excludes an untracked file, wrapper test red (7) then green, random seed 0xc93f3c0b passed 10891 decode runs (done 2026-11-04 06:10 EST; commit b14a73f).
- [x] Provide tiffz's requested public frame-header API: jpegz.frameHeader returns the first T.81 SOFn's marker offset, type, precision, dimensions and raw Ci/Hi/Vi/Tqi (up to 255 components, no allocation, no entropy decoding) with errors separating NoFrameHeader from MissingSoi, Truncated, InvalidMarkerStream, InvalidFrameHeader and UnsupportedFrameType; jpegz.frameKind classifies all 16 SOFn values; 7/7 mutants killed, 13 fixtures match djpeg and decoded dimensions, decode fuzz harness extended (seed 0xa48f4e78 clean); no tables parameter, since TN2 frame headers live in each segment; ./test 14/14 (done 2026-11-04 06:10 EST; commit 6f2b881).
- [x] Add tiffz's requested DHP report to frameHeader for finding 19 rule 6 (hierarchical stream whose first frame is SOF3): FrameHeader.dhp_offset is the first 0xFFDE marker before the SOFn, after fill bytes, or null; unit tests cover DHP before SOF3 with fill on both sides, none, repeated, DHP-only and truncation, plus a DHP spliced into a real lossless fixture; fuzz harness asserts placement; 5/5 behavioral mutants killed (a compile-error mutant was replaced), ./test 14/14, random campaign seed 0x5a4641d7 passed (done 2026-11-05 05:25 EST; commit b63d8e4).
- [ ] Determine which terminal layer owns copy mode on a remote SSH session and document client-side clipboard routing; client terminal and activation shortcut requested, settings unchanged.
- [ ] Resolve the corruption-coverage default JPEG-LS fixture mismatch; owner choice requested among three supported defaults, an audited inconclusive JPEG-LS control, or retaining the blocked campaign; preserve classifications and denominators.
- [ ] Keep the non-luma-dominant sampling packet held; do not retry that research or edit the decoder for it without new direction.
- [ ] Keep the published JP2 pin and its real Nix closure hash; do not restore draft pin 54531e26 or any placeholder hash.
- [ ] HOLD (coordinator, 2026-11-04 09:02 EST: surfaced to the owner, do not implement until approved): await owner approval of the proposed generated, test-enforced docs/FINDING_CODES.md provenance table (code, name, owning project, approval reference) before building it; no second registry until then.

## Priority: Validate September 30 work order

- [ ] Reproduce and fix the non-luma-dominant sampling panic with synthetic inputs and valid sampling controls; return typed failure or support the layout without out-of-bounds access.
- [ ] Finish JP2 leaf exactness metadata and audit legacy severity-report locations; the provider cursor/anchor/extent contract is pending, so bounds alone must not imply exactness (context: docs/plan_context/validate-findings-2026-09-27-to-10-14.md).

## Priority: DHT memory safety

- [ ] Investigate Validate's full-stream false rejection; all four September 27 Huffman count vectors pass synthetic controls, but their acceptance does not establish validity of the private original.

## Priority: Canon CR2 sensor validation

- [ ] Confirm Validate's private full-container NRW/AVI replays after the tiffz re-pin without publishing originals or mutants.

## Existing ordered follow-ups

- [ ] Complete the separate libjxlz arithmetic scaling sweep; published e1c521d contains baseline 923d3c4c unchanged (228 fixed-size rows, hash verified), and the provider has a request for published scaling evidence or a bounded sweep (context: docs/plan_context/pre-canon-2026-09-24.md).
- [ ] Finish provider qualification after source review of jp2z 0c2162b and libjxlz e1c521d; facade 197 is shipped and libjxlz CI is complete for five targets at 1a53d9d9 and d6cfb688 (prepared-artifact reuse); real-input integration and cold private-source access remain required before any pin change; the November 3 provider note (more raw-8 histogram cases now raw-16 corrupt, open container prefixes now NEED_MORE_INPUT, local five-target evidence only) joins the same review (context: docs/plan_context/validate-findings-2026-09-27-to-10-14.md).
- [ ] Verify jp2z pixel APIs and component-resolution oracles before replacing OpenJPEG; retain the T.800 edition limit and unresolved warning-class review.

## JPEG entropy and comparison coverage

- [ ] Measure the zero-padding treatment change over identical seeded corruption-coverage inputs, reporting known defects separately while preserving the judged-case denominator.
- [ ] Complete scan consumption, MCU counts, sampling edges, noninterleaved scans, restart cadence and predictor-reset coverage across supported modes.
- [ ] Complete progressive scan-history and coefficient-range constraints with independent normative review and valid boundary controls.
- [ ] Classify the known-good corpus as a set and expand reproducible corruption-probe sweeps across JPEG-LS, JPEG 2000 and JPEG XL.
- [ ] Compare proven malformed fixtures and false rejects against prior art; report demonstrated detection, hypothetical detectability and valid changes separately.
- [ ] Confirm consumer promotion through tiffz.jpegz and rerun the private full-PDF experiment without publishing originals or mutants (context: docs/plan_context/pre-canon-2026-09-24.md).

## Build and CLI

- [x] Prevent ./test from publishing the checkout result link: a disposable-project stub-nix regression found seven builds without --no-link and a replaced sentinel; all thirteen builds now pass --no-link and the check runs in the unit-test step (done 2026-11-03 21:33 EST; delivered by this change).
- [ ] Measure fresh test execution separately from admission, dependency setup, evaluation and compilation; preserve complete coverage and report the one-second target/five-second budget; cached CI artifact reuse is qualified at dedea64 (context: docs/plan_context/validate-findings-2026-09-27-to-10-14.md).
- [x] Port the upstream-first dependency-freshness gate into ./build with sibling origin/HEAD fallback, ancestry-aware ahead pins and fail-closed missing references; assumption: deliberate holds live in committed .dependency-holds naming exact pins (jp2z, libjxlz now) instead of a blanket override; 14 local-Git cases plus three caught mutations (done 2026-11-03 22:34 EST; delivered by this change).
- [ ] Vendor Brotli, preserve compressed-metadata validation, enable Windows JXL and run cross checks; coordinate the unnecessary encoder linkage with libjxlz.
- [ ] Add U5b progress controls and pure timestamp-injected rendering; verify rendered output with Peter and test terminal/width degradation.
- [x] Confirm consumer dependency deduplication and send remaining registry notices: validate has no direct openjpeg/libjxlz/jpegz dependency, routes through tiffz.jpegz and seeds libjxlz only at 93b29e86 under an FOD assertion; the mirrored jp2z codes 145, 146 and 250-254 FYI went to the coordinator (context: docs/plan_context/pre-canon-2026-09-24.md; done 2026-11-03 22:40 EST; registry note).

## Deferred

- [ ] Implement JPEG-LS restart validation and test dormant run-mode/context findings.
- [ ] Inventory remaining T.81/T.87 gaps including DNL, multiscan lossless, differential/hierarchical modes and uncommon component layouts.
- [ ] Consider DRI parallelism and SIMD after correctness coverage; measure pixel divergence before proposing spec-derived IDCT/color replacement.
- [x] Gate the C CLI "DEBUG BUILD" banner on the real optimize mode: build.zig defines JPEGZ_DEBUG_BUILD, the source refuses to compile without it, and tests/cli asserts the banner matches the mode (red in ReleaseSafe before the fix) (done 2026-11-03 22:03 EST; delivered by this change).
