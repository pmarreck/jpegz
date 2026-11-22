# PLAN

Evidence and earlier request details: [queue context](docs/plan_context/pre-canon-2026-09-24.md).
Completed history: [plan log](docs/PLAN_LOG.md).

## Priority: dependency freshness

- [ ] Determine which terminal layer owns copy mode on a remote SSH session and document client-side clipboard routing; client terminal and activation shortcut requested, settings unchanged.
- [ ] Resolve the corruption-coverage default JPEG-LS fixture mismatch; owner choice requested among three supported defaults, an audited inconclusive JPEG-LS control, or retaining the blocked campaign; preserve classifications and denominators.
- [ ] Keep the non-luma-dominant sampling packet held; do not retry that research or edit the decoder for it without new direction.
- [ ] Keep the published JP2 pin and its real Nix closure hash; do not restore draft pin 54531e26 or any placeholder hash.

## Priority: Validate September 30 work order

- [ ] Reproduce and fix the non-luma-dominant sampling panic with synthetic inputs and valid sampling controls; return typed failure or support the layout without out-of-bounds access.
- [ ] Finish JP2 leaf exactness metadata and audit legacy severity-report locations; the provider cursor/anchor/extent contract is pending, so bounds alone must not imply exactness (context: docs/plan_context/validate-findings-2026-09-27-to-10-14.md).

## Priority: DHT memory safety

- [ ] Investigate Validate's full-stream false rejection; all four September 27 Huffman count vectors pass synthetic controls, but their acceptance does not establish validity of the private original.

## Priority: Canon CR2 sensor validation

- [ ] Confirm Validate's private full-container NRW/AVI replays after the tiffz re-pin without publishing originals or mutants.

## Existing ordered follow-ups

- [ ] (Low priority) Opt-in recoverability API (validate TERMINOLOGY A4): degraded only after a verified RSTn resync with exact later MCU counts, extent as MCU and byte ranges; lost for baseline with no restart intervals and no resync; unassessed otherwise; grade with a corruption campaign before claiming any value.
- [x] Go 1.0 SOS known defect, finding 68 sequential_scan_zero_se (validate approved 2026-11-06). Done: Ss=0 Se=0 Ah=Al=0 in a sequential scan that covers every component is judged after the walk: known_defect at the Se byte when it is the only scan, FAIL 64 otherwise; exemplar is baseline_2x2_rgb.jpg with the Se byte set to 0 (a patched SOS tail, as Go wrote it), decoding pixel-identical; near misses (Se 5, Go tail plus Ah=1, Ss=1 with Se=0, the same scan followed by a second scan) stay 64; the 0..255 Se sweep now expects 68 at Se=0; 3 mutants killed (done 2026-11-07 03:00 EST).
- [ ] HOLD row 65 jfif_metadata_invalid at FAIL until the owner rules (validate recommends FAIL and will relay).
- [x] Finding 70 sof_component_id_duplicate (A29; validate approved 2026-11-07 00:00). Done: the validator reports a repeated SOF component ID at its Ci byte, WARN for exactly four components with IDs (1, 2, 3, 1) and FAIL otherwise; the baseline and extended decoder resolves that frame's interleaved (1, 2, 3, 1) scan by position, and the validator no longer reports that one scan's repeated selector; the A29 exemplar decodes pixel-identical to baseline_4x4_cmyk.jpg; near misses (1,1,3,4), (1,2,1,4), (2,2,3,1), SOS order (1,1,2,3) and a three-component duplicate all FAIL; 3 mutants killed (done 2026-11-07 00:45 EST).
- [x] Finding 69 huffman_tables_missing (A3, validate approved 2026-11-06). Done: the baseline and extended decoder installs the T.81 K.3 tables (src/decode/k3_tables.zig, bytes from libjpeg-turbo's standard tables) when no DHT precedes the first scan; the validator reports 69 at the first SOS, known_defect when no DHT exists anywhere and every scan decodes completely, FAIL otherwise, and FAIL at the exact Td/Ta byte when DHT exists but a scan names an undefined table (complete selector lists only); the A3 exemplar equals its control minus DHT and decodes pixel-identical; controls: half the entropy cut (FAIL 69), the chroma AC table removed (FAIL 69 at its Ta byte), progressive without DHT (FAIL, no 69); 3 mutants killed (done 2026-11-07 05:40 EST).
- [x] Map libjxlz raw finding 18 invalid_modular_transform as FindingCode 198 (validate approved 2026-11-06, FAIL class). Done in the libjxlz repin to ff81ff23 (done 2026-11-07 08:30 EST).
- [x] Repin libjxlz to ff81ff23 (includes 2cf83070 origin and detail, fd619360 trailing data, 3d0660c8 typed ICC entropy codes) and derive JXL class from origin. Done: mapJxlFindingWithOrigin maps FAIL to corrupt, WARN and INFO to valid with that severity, NONE to unsupported or inconclusive; a pairing libjxlz's rule cannot produce, an unknown origin value, or a verdict that disagrees with the origin fails closed; a test fails to compile if libjxlz changes its origin enum; FindingCode 198 jxl_invalid_modular_transform (raw 18, FAIL) and 199 jxl_trailing_data (raw 19, WARN, INFO for a PAR2 trailer) at the first byte after the image; FAIL findings keep the recoverability severity rule, so the 197 ICC treatment is unchanged; a test checks libjxlz's own rule against the facade for every code and detail, and that 9 and 13 have origin FAIL; zigDepsHash refreshed from the fixed-output rebuild; 2 mutants killed (done 2026-11-07 08:30 EST).
- [ ] Complete the separate libjxlz arithmetic scaling sweep; published e1c521d contains baseline 923d3c4c unchanged (228 fixed-size rows, hash verified), and the provider has a request for published scaling evidence or a bounded sweep (context: docs/plan_context/pre-canon-2026-09-24.md).
- [ ] Finish provider qualification after source review of jp2z 0c2162b and libjxlz e1c521d; facade 197 is shipped and libjxlz CI is complete for five targets at 1a53d9d9 and d6cfb688 (prepared-artifact reuse); real-input integration and cold private-source access remain required before any pin change; the November 3 provider note (more raw-8 histogram cases now raw-16 corrupt, open container prefixes now NEED_MORE_INPUT, local five-target evidence only) joins the same review (context: docs/plan_context/validate-findings-2026-09-27-to-10-14.md).
- [ ] Verify jp2z pixel APIs and component-resolution oracles before replacing OpenJPEG; retain the T.800 edition limit and unresolved warning-class review.

## JPEG entropy and comparison coverage

- [ ] Complete scan consumption, MCU counts, sampling edges, noninterleaved scans, restart cadence and predictor-reset coverage across supported modes.
- [ ] Complete progressive scan-history and coefficient-range constraints with independent normative review and valid boundary controls.
- [ ] Classify the known-good corpus as a set and expand reproducible corruption-probe sweeps across JPEG-LS, JPEG 2000 and JPEG XL.
- [ ] Compare proven malformed fixtures and false rejects against prior art; report demonstrated detection, hypothetical detectability and valid changes separately.
- [ ] Confirm consumer promotion through tiffz.jpegz and rerun the private full-PDF experiment without publishing originals or mutants (context: docs/plan_context/pre-canon-2026-09-24.md).

## JPEG-LS conformance

- [x] Fix JPEG-LS decode against the T.87 Annex E conformance streams. Done: LSE marker FF F8 (was FF F2), near-lossless k=0 correction, default thresholds above 8 bits; t8nde0/3 and t16e0/3 pass; custom LSE MAXVAL is NotImplemented (commit 29a183d; done 2026-11-21 15:45 EST).
- [x] Make every src/ file's inline tests run. Done: 38 orphaned tests wired; the test-reachability flake check guards it (commit bf1ea3d; done 2026-11-21 15:45 EST).
- [x] Decode JPEG-LS restart intervals. Done: DRI (2-4 byte Ri), RST0..7 in sequence, context and neighbor reset, for mono and ILV 1/2; CharLS restart streams exact; out-of-sequence RST is InvalidMarker (commit 8ea2a60; done 2026-11-21 17:05 EST).
- [x] Run a JPEG-LS codec check in validate. Done: the walker honors T.87 bit stuffing (28 of 29 CharLS JPEG-LS files had been false FAILs); 120, 121, 122 (new), 56, 57, insufficient_data and truncated_stream emitted per validate's 2026-11-21 rulings; CharLS test data now 18 valid, 3 unsupported, 8 corrupt (its invalid inputs) (commit 32d2501; done 2026-11-21 18:50 EST).
- [ ] Fuzz JPEG-LS decoding, restart streams included, for panics: a mutant that skipped the per-interval context reset hit an integer-cast panic in ReleaseSafe, so some decoder state is trusted unchecked.
- [ ] Accept JPEG-LS LSE ID 4 oversize dimensions (CharLS 3.0 writes them for X or Y above 65535; jpegz ignores the record and grades X=0/Y=0 FAIL 61); oracle: a CharLS-encoded 65536x1 image (context: docs/plan_context/t81-t87-gap-inventory-2026-11-21.md).
- [ ] Apply JPEG-LS LSE ID 2/3 mapping tables (palette images decode to indices today), and settle the ignored point transform and JPEG-LS DNL against the T.87 text (context: docs/plan_context/t81-t87-gap-inventory-2026-11-21.md).
- [ ] Settle how an LSE MAXVAL below 2^P-1 derives RANGE, qbpp and LIMIT (CharLS 3.0 uses P, FFmpeg uses MAXVAL); needs the T.87 A.2.1 text or a conformant encoder; until then such scans are NotImplemented (context: docs/plan_context/t81-t87-gap-inventory-2026-11-21.md).
- [ ] Decode the HP-encoder files in the charls input (banny-hp1..3, tulips hp-encoder) and the remaining conformance streams (t8c0-2e0/3, t8sse0/3) once multi-component ILV 0 and subsampling are supported.

## Build and CLI

- [ ] Measure fresh test execution separately from admission, dependency setup, evaluation and compilation; preserve complete coverage and report the one-second target/five-second budget; cached CI artifact reuse is qualified at dedea64 (context: docs/plan_context/validate-findings-2026-09-27-to-10-14.md).
- [ ] Vendor Brotli, preserve compressed-metadata validation, enable Windows JXL and run cross checks; coordinate the unnecessary encoder linkage with libjxlz.
- [ ] Add U5b progress controls and pure timestamp-injected rendering; verify rendered output with Peter and test terminal/width degradation.

## Deferred

- [x] Inventory remaining T.81/T.87 gaps including DNL, multiscan lossless, differential/hierarchical modes and uncommon component layouts. Done: inventory written; DNL for DCT frames honored (ecf812b); misplaced DNL 72 and differential SOF without DHP 73 shipped with validate approval (0be9de3) (context: docs/plan_context/t81-t87-gap-inventory-2026-11-21.md; done 2026-11-21 13:45 EST).
- [ ] Consider DRI parallelism and SIMD after correctness coverage; measure pixel divergence before proposing spec-derived IDCT/color replacement.
