# PLAN

Evidence and earlier request details: [queue context](docs/plan_context/pre-canon-2026-09-24.md).
Completed history: [plan log](docs/PLAN_LOG.md).

## Priority: dependency freshness

- [x] Add tiffz's requested DHP report to frameHeader for finding 19 rule 6 (hierarchical stream whose first frame is SOF3): FrameHeader.dhp_offset is the first 0xFFDE marker before the SOFn, after fill bytes, or null; unit tests cover DHP before SOF3 with fill on both sides, none, repeated, DHP-only and truncation, plus a DHP spliced into a real lossless fixture; fuzz harness asserts placement; 5/5 behavioral mutants killed (a compile-error mutant was replaced), ./test all checks passed, random campaign seed 0x5a4641d7 passed (done 2026-11-05 05:25 EST; commit b63d8e4).
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

- [x] Implement validate's 2026-11-05 approved severity rows, each with a controlled red: reserved FF02..FFBF markers FAIL; repeated SOF FAIL except DHP hierarchical streams (with a legal multi-frame DHP fixture that stays clean); FAIL severity for insufficient_data and restart findings; legal 0xFF fill INFO; JFIF version above 1.02 WARN as "not in the claimed spec version" (context: docs/plan_context/severity-audit-2026-11-05.md; red 7 unit tests and 16 CLI assertions; ./test 14/14; no fixture or real-world verdict change; done 2026-11-05 15:25 EST; commit 933d915).
- [ ] Go 1.0 SOS known defect (owner 2026-11-05: an upstream bug report and fix describing the pattern exactly is writer evidence): synthesize a faithful exemplar (Go's pre-fix image/jpeg writer via Nix if cheap, else a patched SOS tail matching its header layout), near-match controls that stay FAIL 64 (one of several scans, Se neither 0 nor 63, progressive, tail plus another SOS fault) and a typed finding once Einstein reserves 68 sequential_scan_zero_se; send validate the exemplar hashes and the code (context: docs/plan_context/severity-audit-2026-11-05.md).
- [ ] HOLD row 65 jfif_metadata_invalid at FAIL until the owner rules (validate recommends FAIL and will relay).
- [x] Split "whole bytes after valid padding before EOI" from invalid end-of-scan entropy as a narrower reason with no detection change, and send validate its real-world count as a WARN or registry candidate. Done: detail "N whole bytes after valid padding before marker 0xXX" on code 51, class unchanged; real-world 0 of 805; damage produces it in 32 of 1,200 real-photo cases (always the sole finding) versus 42 for invalid entropy, so it is not damage-free (done 2026-11-05 19:00 EST; commit f8a1e57).
- [x] Detection gap: a bogus multi-component SOF sampling factor (outside 1..4 or impossible MCU geometry) yields unsupported with no finding; add a typed finding with a fixture and controlled red. Done: FAIL 66 for every T.81 component and for interleaved MCUs above 10 units, djpeg agrees at the 10/11 boundary, no corpus effect, ./test 14/14 (done 2026-11-05 15:45 EST; commit 4de3c9f).
- [x] Detection gap: a damaged SOI yields unrecognized_container; keep JPEG identity (FAIL, not indeterminate) only on strong evidence such as two or more valid marker segments in sequence, and report the false-identification rate on non-JPEG files. Done: two or more complete T.81/T.87 segments chained from offset 2 keep identity with FAIL missing_soi at 0; 0 of 29,181 non-JPEG files misidentified (95% upper bound about 0.01%); ./test 14/14 (done 2026-11-05 17:05 EST; commit 2b58ce9).
- [x] Let a known defect outrank inconclusive in jpegz's strict verdict and CLI (validate recommendation 2026-11-05: inconclusive is reach, a claim about the tool, so it never changes the file's verdict; FAIL still outranks both); keep exit numbers, update batch precedence and help text, with a controlled red. Done: exit order 2, 1, 4, 3, 0 with help text; ./test 14/14 (done 2026-11-05 18:05 EST; commit aeb6909).
- [x] (Low priority, after current audits) Historic encoder bugs for jpegz from validate's owner-requested research (validate docs/plan_context/historic_encoder_flubs.md): cases A1 JPEG APP2 ICC, A2, A3, A16, A29, A30, A31 JPEG APP13, B7, B8, B9; per case confirm the cited source, check detection (gap if none), synthesize an exemplar with provenance (real pre-fix writer when cheap), propose an exact registry signature with near-match controls; B7 analysis only with no class until the owner rules; skip anything marked a spec erratum; report one table to validate. Done: all eight sources confirmed verbatim, exemplars for A2, A3, A16, A29, A31 and B7, registry candidates and controls proposed, two detection gaps found (context: docs/plan_context/historic-encoder-bugs-2026-11-05.md; done 2026-11-05 19:15 EST).
- [ ] Detection gaps from the historic-bug audit (validate: typed codes, not detail tokens): once Einstein reserves 69 huffman_tables_missing (A3) and 70 sof_component_id_duplicate (A29, at the SOF byte), implement both as FAIL with controlled reds and the fixtures in tests/unit/fixtures/HISTORIC_ENCODER_PROVENANCE.md, including an A3 control that decodes with K.3 tables but is cut short and must stay plain FAIL (context: docs/plan_context/historic-encoder-bugs-2026-11-05.md).
- [x] Re-export libjxlz's finding enum for validate's exhaustive leaf-code switch (validate request 2026-11-05). Done: jpegz.jpegxl.FindingCode and jpegxl.leafCode(finding), null for other sources or codes outside the pin; leaf_code and the C ABI unchanged; round-trip test over every pinned value also fails a repin until jpegz maps a new code; two mutants killed by both tests (done 2026-11-05 22:25 EST).
- [ ] Map libjxlz raw finding 18 invalid_modular_transform (libjxlz f3b7933f, owner-chosen, FAIL class) once Einstein reserves FindingCode 198: append to errors.zig, map in the facade with a controlled red, extend the exhaustive pair tests and repin libjxlz (at or after badad57a, truncated containers report jxl_truncated instead of jxl_malformed; update any pinned expectation); raw 18 fails closed as indeterminate until then.
- [x] Apply the owner's 2026-11-05 reversal of the September 16 JXL contract relayed by libjxlz: jxl_nonzero_padding (189) and jxl_truncated_box_header (193) now carry FAIL whatever libjxlz's recoverability severity says; verdicts, provider warning counts and the ICC (197) assessment unchanged; controlled red was the CLI JSON assertion plus 3 facade unit tests; ./test 14/14 (done 2026-11-05 13:15 EST; commit 6653274).
- [x] Draft the per-finding severity table validate requested (one row per jpegz code and reason; damage campaigns F 11,200 and R 1,200 cases, libjpeg-turbo djpeg reader checks, 805-file real-world and 66-file test corpora); no real-world or test-suite verdict changes from any proposal (context: docs/plan_context/severity-audit-2026-11-05.md; done 2026-11-05 13:15 EST).
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

- [ ] Measure fresh test execution separately from admission, dependency setup, evaluation and compilation; preserve complete coverage and report the one-second target/five-second budget; cached CI artifact reuse is qualified at dedea64 (context: docs/plan_context/validate-findings-2026-09-27-to-10-14.md).
- [ ] Vendor Brotli, preserve compressed-metadata validation, enable Windows JXL and run cross checks; coordinate the unnecessary encoder linkage with libjxlz.
- [ ] Add U5b progress controls and pure timestamp-injected rendering; verify rendered output with Peter and test terminal/width degradation.

## Deferred

- [ ] Implement JPEG-LS restart validation and test dormant run-mode/context findings.
- [ ] Inventory remaining T.81/T.87 gaps including DNL, multiscan lossless, differential/hierarchical modes and uncommon component layouts.
- [ ] Consider DRI parallelism and SIMD after correctness coverage; measure pixel divergence before proposing spec-derived IDCT/color replacement.
