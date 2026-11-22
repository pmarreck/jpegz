# PLAN

Evidence and earlier request details: [queue context](docs/plan_context/pre-canon-2026-09-24.md).
Completed history: [plan log](docs/PLAN_LOG.md).

## Priority: dependency freshness

- [ ] Determine which terminal layer owns copy mode on a remote SSH session and document client-side clipboard routing; client terminal and activation shortcut requested, settings unchanged.
- [x] Resolve the corruption-coverage default JPEG-LS fixture mismatch; owner choice requested among three supported defaults, an audited inconclusive JPEG-LS control, or retaining the blocked campaign. Answer: no choice needed; the JPEG-LS control was indeterminate only because validate never checked JPEG-LS (now valid since 32d2501), and coverage_stats misread the CLI's exit 5 as a harness failure (fixed); the default campaign exits 0 with classifications and the judged-case denominator unchanged in definition: 1,600 judged, 54.2% corrupt [51.7, 56.6] (commit abdf10a; done 2026-11-21 23:58 EST).
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
- [ ] HOLD row 65 jfif_metadata_invalid at FAIL until the owner rules (validate recommends FAIL and will relay).
- [ ] Complete the separate libjxlz arithmetic scaling sweep; published e1c521d contains baseline 923d3c4c unchanged (228 fixed-size rows, hash verified), and the provider has a request for published scaling evidence or a bounded sweep (context: docs/plan_context/pre-canon-2026-09-24.md).
- [ ] Finish provider qualification after source review of jp2z 0c2162b and libjxlz e1c521d; facade 197 is shipped and libjxlz CI is complete for five targets at 1a53d9d9 and d6cfb688 (prepared-artifact reuse); real-input integration and cold private-source access remain required before any pin change; the November 3 provider note (more raw-8 histogram cases now raw-16 corrupt, open container prefixes now NEED_MORE_INPUT, local five-target evidence only) joins the same review (context: docs/plan_context/validate-findings-2026-09-27-to-10-14.md).
- [ ] Verify jp2z pixel APIs and component-resolution oracles before replacing OpenJPEG; retain the T.800 edition limit and unresolved warning-class review.

## JPEG entropy and comparison coverage

- [ ] Complete scan consumption, MCU counts, sampling edges, noninterleaved scans, restart cadence and predictor-reset coverage across supported modes.
- [ ] Complete progressive scan-history and coefficient-range constraints with independent normative review and valid boundary controls.
- [ ] Classify the known-good corpus as a set and expand reproducible corruption-probe sweeps across JPEG-LS, JPEG 2000 and JPEG XL; JPEG-LS swept 2026-11-21 (93.0% of 1,600 on four T.87 streams; survivors all entropy) (context: docs/measurements/jpegls-corruption-coverage-2026-11-21.md).
- [ ] Check JPEG-LS interval and scan ends: leftover entropy bytes and nonzero padding before RSTm or the end marker go unreported today; classification asked of validate 2026-11-22 (context: docs/measurements/jpegls-corruption-coverage-2026-11-21.md).
- [ ] Compare proven malformed fixtures and false rejects against prior art; report demonstrated detection, hypothetical detectability and valid changes separately.
- [ ] Confirm consumer promotion through tiffz.jpegz and rerun the private full-PDF experiment without publishing originals or mutants (context: docs/plan_context/pre-canon-2026-09-24.md).

## JPEG-LS conformance

- [x] Fix JPEG-LS decode against the T.87 Annex E conformance streams. Done: LSE marker FF F8 (was FF F2), near-lossless k=0 correction, default thresholds above 8 bits; t8nde0/3 and t16e0/3 pass; custom LSE MAXVAL is NotImplemented (commit 29a183d; done 2026-11-21 15:45 EST).
- [x] Make every src/ file's inline tests run. Done: 38 orphaned tests wired; the test-reachability flake check guards it (commit bf1ea3d; done 2026-11-21 15:45 EST).
- [x] Decode JPEG-LS restart intervals. Done: DRI (2-4 byte Ri), RST0..7 in sequence, context and neighbor reset, for mono and ILV 1/2; CharLS restart streams exact; out-of-sequence RST is InvalidMarker (commit 8ea2a60; done 2026-11-21 17:05 EST).
- [x] Run a JPEG-LS codec check in validate. Done: the walker honors T.87 bit stuffing (28 of 29 CharLS JPEG-LS files had been false FAILs); 120, 121, 122 (new), 56, 57, insufficient_data and truncated_stream emitted per validate's 2026-11-21 rulings; CharLS test data now 18 valid, 3 unsupported, 8 corrupt (its invalid inputs) (commit 32d2501; done 2026-11-21 18:50 EST).
- [x] Fuzz JPEG-LS decoding, restart streams included, for panics. Done: JPEG-LS fixtures and a restart stream seed both harnesses (a planted panic in restartAt fails the replay); three bounded campaigns (seeds 0x0c9ca8aa, 0x48e23318, 0x776d5275; 10000 iterations per harness each) found no panic or leak; the earlier integer-cast panic needed a mutant that skipped the context reset (commit 57c94d8; done 2026-11-21 21:40 EST).
- [x] Accept JPEG-LS LSE ID 4 oversize dimensions. Done: decoder and validator read Wxy/Ye/Xe; 65536x1 and 1x65536 CharLS files decode to their formula and validate clean (commit f8b2c53; done 2026-11-21 20:40 EST).
- [x] Stop JPEG-LS mapping-table scans decoding to indices. Done: a scan with SOS Tdi != 0 is NotImplemented (CharLS fixture; clearing Tdi decodes) (commit 3868527; done 2026-11-21 22:15 EST).
- [ ] Apply JPEG-LS mapping tables (LSE ID 2/3, including multi-byte entries that expand a component) and settle the ignored point transform (SOS Al) and JPEG-LS DNL against the T.87 text; CharLS exposes tables without applying them, so it is no oracle for the output (context: docs/plan_context/t81-t87-gap-inventory-2026-11-21.md).
- [ ] Settle how an LSE MAXVAL below 2^P-1 derives RANGE, qbpp and LIMIT (CharLS 3.0 uses P, FFmpeg uses MAXVAL); needs the T.87 A.2.1 text or a conformant encoder; until then such scans are NotImplemented (context: docs/plan_context/t81-t87-gap-inventory-2026-11-21.md).
- [x] Decode the HP-encoder files and multi-component ILV 0 streams in the charls input. Done: banny-hp1..3 and the tulips hp-encoder file validate clean after the walker fix (32d2501); t8c0e0/3 and test8_ilv_none_rm_7 decode exactly (commit 774db69; done 2026-11-21 20:40 EST).
- [ ] Decode JPEG-LS subsampled components (t8sse0/3, reference planes test8r/test8gr4/test8bs2); needs the T.87 line-interleave rule for unequal Vi and an output decision for unequal channel sizes; CharLS's compliance tests skip these streams, so there is no second implementation to compare against.

## Build and CLI

- [ ] Measure fresh test execution separately from admission, dependency setup, evaluation and compilation; preserve complete coverage and report the one-second target/five-second budget; cached CI artifact reuse is qualified at dedea64 (context: docs/plan_context/validate-findings-2026-09-27-to-10-14.md).
- [ ] Vendor Brotli, preserve compressed-metadata validation, enable Windows JXL and run cross checks; coordinate the unnecessary encoder linkage with libjxlz.
- [ ] Add U5b progress controls and pure timestamp-injected rendering; verify rendered output with Peter and test terminal/width degradation.

## Deferred

- [x] Inventory remaining T.81/T.87 gaps including DNL, multiscan lossless, differential/hierarchical modes and uncommon component layouts. Done: inventory written; DNL for DCT frames honored (ecf812b); misplaced DNL 72 and differential SOF without DHP 73 shipped with validate approval (0be9de3) (context: docs/plan_context/t81-t87-gap-inventory-2026-11-21.md; done 2026-11-21 13:45 EST).
- [ ] Consider DRI parallelism and SIMD after correctness coverage; measure pixel divergence before proposing spec-derived IDCT/color replacement.
