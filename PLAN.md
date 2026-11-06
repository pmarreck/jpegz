# PLAN

Evidence and earlier request details: [queue context](docs/plan_context/pre-canon-2026-09-24.md).
Completed history: [plan log](docs/PLAN_LOG.md).

## Priority: dependency freshness

- [ ] Determine which terminal layer owns copy mode on a remote SSH session and document client-side clipboard routing; client terminal and activation shortcut requested, settings unchanged.
- [ ] Resolve the corruption-coverage default JPEG-LS fixture mismatch; owner choice requested among three supported defaults, an audited inconclusive JPEG-LS control, or retaining the blocked campaign; preserve classifications and denominators.
- [ ] Keep the non-luma-dominant sampling packet held; do not retry that research or edit the decoder for it without new direction.
- [ ] Keep the published JP2 pin and its real Nix closure hash; do not restore draft pin 54531e26 or any placeholder hash.
- [x] Owner approval of the generated, test-enforced docs/FINDING_CODES.md provenance table (code, name, owning project, approval reference). Answer: approved by the owner 2026-11-06. Done: src/core/finding_provenance.zig holds owner, approval basis and introducing commit for all 82 codes (EnumArray makes a missing row a compile error); tools/gen_finding_codes.zig renders the doc; zig build test fails on a stale doc, zig build finding-codes rewrites it; introducing commits recovered with a whitespace-tolerant git pickaxe; code 10 has no approval record and says so (done 2026-11-06 10:05 EST).

## Priority: Validate September 30 work order

- [ ] Reproduce and fix the non-luma-dominant sampling panic with synthetic inputs and valid sampling controls; return typed failure or support the layout without out-of-bounds access.
- [ ] Finish JP2 leaf exactness metadata and audit legacy severity-report locations; the provider cursor/anchor/extent contract is pending, so bounds alone must not imply exactness (context: docs/plan_context/validate-findings-2026-09-27-to-10-14.md).

## Priority: DHT memory safety

- [ ] Investigate Validate's full-stream false rejection; all four September 27 Huffman count vectors pass synthetic controls, but their acceptance does not establish validity of the private original.

## Priority: Canon CR2 sensor validation

- [ ] Confirm Validate's private full-container NRW/AVI replays after the tiffz re-pin without publishing originals or mutants.

## Existing ordered follow-ups

- [x] Owner 2026-11-06: consult validate on the refined FAIL / WARN / KNOWN_DEFECT / error semantics. Answer (validate 2026-11-06): KNOWN_DEFECT is independent of WARN and FAIL with no treatment, so its findings need their own severity; admission has three paths (3 real files, checksum-verified bytes, or a documented upstream producer bug with a synthetic exemplar); adopt validate's exit codes with inconclusive at 5; split access errors; recoverability is opt-in and low priority; JXL 9/13 FAIL confirmed shipped in 6653274 (done 2026-11-06 10:10 EST).
- [x] Give findings that make up a known defect their own Severity value known_defect (validate ruling 2026-11-06). Done: Severity.known_defect = 4 appended (Zig, curated C header, smoke ABI check); finding 63 emitted at it; overall severity uses Severity.rank (FAIL > KNOWN_DEFECT > WARN > INFO > PASS) so an appended value cannot outrank FAIL; CLI labels it KNOWN_DEFECT in orange with no WARN or FAIL tag; legacy ValidationReport.isValid stays true for a known defect as before; red 7 assertions, 2 mutants killed (numeric-max aggregation, classifier override) (done 2026-11-06 11:10 EST).
- [x] Adopt validate's exit codes in the jpegz CLI (validate recommendation 2026-11-06; the owner may override). Done: 0 OK, 1 FAIL, 2 usage only, 3 WARN, 4 known defect, 5 inconclusive (also over the input limit), 66 missing, 70 internal, 71 out of memory, 74 read error, 77 permission or access; batch precedence 1 > 71 > 70 > 74 > 77 > 66 > 4 > 5 > 3 > 0 through one rank function (assumption: 71 and 70 sit just below FAIL, which validate's list leaves open); 8x8 batch table with a printed SKIP when root can read a mode-000 file; red 40 assertions, 2 mutants killed (rank swap, errno mapping) (done 2026-11-06 11:45 EST).
- [ ] (Low priority) Opt-in recoverability API (validate TERMINOLOGY A4): degraded only after a verified RSTn resync with exact later MCU counts, extent as MCU and byte ranges; lost for baseline with no restart intervals and no resync; unassessed otherwise; grade with a corruption campaign before claiming any value.
- [x] Make fuzz crashes replayable after code changes (owner 2026-11-06: a coverage-guided seed alone does not reproduce). Done: ./fuzz --fuzz saves the crash input Zig records to tests/fuzz/regressions/<harness>/<seed>.bin via tools/fuzz-save-crash; build.zig lists that directory and appends every file to the harness corpus, so the default fuzz check in ./test replays it; replay proven with a harness mutant (passes without the file, fails with it); saver test 11/11 with 3 mutants killed; ./fuzz test red 3 then 28/28 (done 2026-11-06 10:55 EST).
- [x] Decode two- and four-component lossless (SOF3) frames for tiffz's DNG CFA tiles (tiffz request 2026-11-06). Done: gate lifted to 1..4 components; appended PixelLayout.components (C JPEGZ_LAYOUT_COMPONENTS = 3) with unknown color space for 2 and 4; four libjpeg-turbo fixtures (P8, P14, P16 with restarts, P12 four-component) decode every formula sample exactly, plus tiffz's minimal stream; subsampled control stays NotImplemented; red was NotImplemented (done 2026-11-06 12:30 EST).
- [x] Fix 12-bit RGB decode (tiffz bug 2026-11-06). Done: one shared libjpeg-turbo precedence (cmyk.rgbPassthrough with ColorSignals: JFIF means YCbCr, else Adobe transform 0 RGB, else IDs R,G,B) now used at every precision by the baseline, progressive and arithmetic progressive decoders; the progressive paths had no passthrough at any precision; five cjpeg -rgb fixtures (djpeg-exact) times three variants (Adobe, IDs only, JFIF wins); red 192 of 192 samples wrong; 3 mutants killed (done 2026-11-06 13:10 EST).
- [ ] Name trailing whole bytes after a lossless scan instead of reporting huffman_table_corrupt BackendError (tiffz observation 2026-11-06), matching the baseline reason from f8a1e57, with a controlled red.
- [ ] Exactly-full Huffman table (reserved all-ones codeword; Pentax K-x, K-r, Ricoh GR, DJI FC4382 DNGs): once Einstein numbers it (requested 71), split a typed code from 51 that matches only Kraft sum exactly 1 with the all-ones code as the sole violation, WARN until owner admission then known_defect; decode with that table (T.81 F.2.2.3 is deterministic for a full table); exemplar plus controls (oversubscribed stays 51, all-ones not last at its length, standalone baseline and lossless) (validate and tiffz requests 2026-11-06).
- [ ] Go 1.0 SOS known defect (owner 2026-11-05: an upstream bug report and fix describing the pattern exactly is writer evidence): synthesize a faithful exemplar (Go's pre-fix image/jpeg writer via Nix if cheap, else a patched SOS tail matching its header layout), near-match controls that stay FAIL 64 (one of several scans, Se neither 0 nor 63, progressive, tail plus another SOS fault) and a typed finding once Einstein reserves 68 sequential_scan_zero_se; send validate the exemplar hashes and the code (context: docs/plan_context/severity-audit-2026-11-05.md).
- [ ] HOLD row 65 jfif_metadata_invalid at FAIL until the owner rules (validate recommends FAIL and will relay).
- [x] Split "whole bytes after valid padding before EOI" from invalid end-of-scan entropy as a narrower reason with no detection change, and send validate its real-world count as a WARN or registry candidate. Done: detail "N whole bytes after valid padding before marker 0xXX" on code 51, class unchanged; real-world 0 of 805; damage produces it in 32 of 1,200 real-photo cases (always the sole finding) versus 42 for invalid entropy, so it is not damage-free (done 2026-11-05 19:00 EST; commit f8a1e57).
- [x] (Low priority, after current audits) Historic encoder bugs for jpegz from validate's owner-requested research (validate docs/plan_context/historic_encoder_flubs.md): cases A1 JPEG APP2 ICC, A2, A3, A16, A29, A30, A31 JPEG APP13, B7, B8, B9; per case confirm the cited source, check detection (gap if none), synthesize an exemplar with provenance (real pre-fix writer when cheap), propose an exact registry signature with near-match controls; B7 analysis only with no class until the owner rules; skip anything marked a spec erratum; report one table to validate. Done: all eight sources confirmed verbatim, exemplars for A2, A3, A16, A29, A31 and B7, registry candidates and controls proposed, two detection gaps found (context: docs/plan_context/historic-encoder-bugs-2026-11-05.md; done 2026-11-05 19:15 EST).
- [ ] Detection gaps from the historic-bug audit (validate: typed codes, not detail tokens; classes ruled 2026-11-06): once Einstein reserves 69 huffman_tables_missing (A3: WARN when no DHT exists and the scan decodes cleanly with the K.3 tables, FAIL otherwise) and 70 sof_component_id_duplicate (A29, at the SOF byte: WARN for exactly 4 components with IDs 1,2,3,1, FAIL for any other duplicate), implement both with controlled reds and the fixtures in tests/unit/fixtures/HISTORIC_ENCODER_PROVENANCE.md, including an A3 control that decodes with K.3 tables but is cut short and must stay FAIL (context: docs/plan_context/historic-encoder-bugs-2026-11-05.md).
- [x] Re-export libjxlz's finding enum for validate's exhaustive leaf-code switch (validate request 2026-11-05). Done: jpegz.jpegxl.FindingCode and jpegxl.leafCode(finding), null for other sources or codes outside the pin; leaf_code and the C ABI unchanged; round-trip test over every pinned value also fails a repin until jpegz maps a new code; two mutants killed by both tests (done 2026-11-05 22:25 EST).
- [ ] Map libjxlz raw finding 18 invalid_modular_transform (libjxlz f3b7933f, owner-chosen, FAIL class) once Einstein reserves FindingCode 198: append to errors.zig, map in the facade with a controlled red, extend the exhaustive pair tests and repin libjxlz (at or after badad57a, truncated containers report jxl_truncated instead of jxl_malformed; update any pinned expectation); raw 18 fails closed as indeterminate until then.
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
