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
- [ ] Classify the known-good corpus as a set and expand reproducible corruption-probe sweeps across JPEG-LS, JPEG 2000 and JPEG XL; JPEG-LS swept 2026-11-21 (93.0% of 1,600 on four T.87 streams; survivors all entropy) and JPEG 2000/JPEG XL swept 2026-11-22 (nine fixtures, 3,600 cases, no crash; lossless gray JXL survivors all decode in libjxl's djxl); the set-level corpus classification remains (context: docs/measurements/jp2-jxl-corruption-coverage-2026-11-22.md).
- [x] Check JPEG-LS interval and scan ends: leftover entropy bytes are finding 8 (detail jpegls_interval / jpegls_scan_end) and nonzero padding is new FAIL 123 per T.87 A.1, per validate's 2026-11-22 rulings; starved segments stay truncation; test16_rm_5 sniper 60% to 65%, shotgun_variable 87% to 96%; no verdict change on 29 CharLS and 4 ffmpeg JPEG-LS files (context: docs/measurements/jpegls-corruption-coverage-2026-11-21.md; done 2026-11-22 03:40 EST).
- [ ] Compare proven malformed fixtures and false rejects against prior art; report demonstrated detection, hypothetical detectability and valid changes separately.
- [ ] Confirm consumer promotion through tiffz.jpegz and rerun the private full-PDF experiment without publishing originals or mutants (context: docs/plan_context/pre-canon-2026-09-24.md).

## JPEG-LS conformance

- [x] Stop JPEG-LS mapping-table scans decoding to indices. Done: a scan with SOS Tdi != 0 is NotImplemented (CharLS fixture; clearing Tdi decodes) (commit 3868527; done 2026-11-21 22:15 EST).
- [x] Validate JPEG-LS mapping tables per T.87 C.2.3/C.2.4.1.2-3 with validate's codes 124 (undefined table, FAIL), 125 (Tmi with Pt, WARN) and 126 (malformed table, FAIL; tokens tid_range, wt_range, length, continuation, entries) instead of refusing the scan; one-byte tables map in the decode API, wider ones are NotImplemented there and validate on indices; CharLS fixture plus byte-edited variants, an ID 2 + ID 3 split, replacement and ILV 0 cases; fifteen mutants killed (context: docs/plan_context/jpegls-t87-rulings-2026-11-22.md; done 2026-11-22 10:15 EST).
- [x] Read JPEG-LS Y from a DNL immediately after the first scan when SOF Y = 0 (T.87 C.2.2), reusing 72 dnl_misplaced; t8nde0 and the three-scan t8c0e0 with Y zeroed and a DNL inserted decode to identical pixels and validate clean; no DNL or NL = 0 is 61 and InvalidMarker; six mutants killed (context: docs/plan_context/jpegls-t87-rulings-2026-11-22.md; done 2026-11-22 07:50 EST).
- [x] Output JPEG-LS samples as Rx << Pt for a nonzero point transform (T.87 4.3.2), saturating at 2^P-1 with validate's FAIL 128 jpegls_point_transform_overflow once per scan; Pt=1 control (127 -> 254) and one-overflowing-sample fixtures, ILV 0 and 12-bit cases; nine mutants killed (context: docs/plan_context/jpegls-t87-rulings-2026-11-22.md; done 2026-11-22 09:00 EST).
- [x] Decode LSE MAXVAL < 2^P-1 scans per T.87 A.2.1 with validate's dual-decode classification and approved INFO 127 jpegls_maxval_derivation (also_charls valid, only_charls unsupported); 144 stock CharLS 3.0 streams: 132 only_charls, 12 both; 72 FFmpeg-verified spec-coded streams: 60 A.2.1-only, 12 both; jpegz equals FFmpeg on every A.2.1 decode (context: docs/plan_context/jpegls-t87-rulings-2026-11-22.md; done 2026-11-22 06:10 EST).
- [ ] Owner decision: admit CharLS 3.0's RANGE-from-P coding of LSE MAXVAL < 2^P-1 (127 only_charls) as known_defect now, keep it unsupported until real-world files appear, or admit after checking CharLS 2.x and the latest release; validate queued it and recommends the version check if cheap (context: docs/plan_context/jpegls-t87-rulings-2026-11-22.md).
- [x] Decode JPEG-LS subsampled components: line-interleaved scans decode per T.87 B.2/B.4 (Vi lines per component per MCU, per-component plane sizes, padding lines dropped); t8sse0 matches the HP reference planes test8r/test8gr4/test8bs2 exactly and t8sse3 within NEAR 3, and both now validate as decoded; restarts, point transform, mapping tables, the dual MAXVAL decode and ILV 0/2 stay NotImplemented for unequal planes; seven mutants killed (context: docs/plan_context/jpegls-t87-rulings-2026-11-22.md; done 2026-11-22 11:20 EST).
- [ ] Owner decision: how the JPEG-LS decode API should return components of unequal size (t8sse0/3): keep NotImplemented (validation and jpegls_cleanroom_decode_planes already work), upsample to full size by replication, or expose planes through the public API (context: docs/plan_context/jpegls-t87-rulings-2026-11-22.md).
- [x] Report ILV 2 over JPEG-LS components of unequal size as validate's FAIL 129 jpegls_sample_interleave_subsampled at the SOS ILV byte (T.87 C.2.3), detail each component's Hi x Vi; three mutants killed (context: docs/plan_context/jpegls-t87-rulings-2026-11-22.md; done 2026-11-22 12:30 EST).

## Build and CLI

- [x] Measure fresh test execution separately from admission, dependency setup, evaluation and compilation; preserve complete coverage and report the one-second target/five-second budget. Answer: run steps with compiles cached took 10.6 s, 85% in one exhaustive validate sweep; a frame-free leak-checked allocator (524d1ac) and validate's per-SOF finding 66 (aeb75d2) bring execution to about 4.1 s with full coverage, inside the 5 s budget but not the 1 s target; facade_validation (1-2 s) is the largest remaining share; -Dtest-filter=TEXT added for bisection (context: docs/measurements/test-timing-2026-11-22.md; done 2026-11-22 16:10 EST).
- [ ] Vendor Brotli, preserve compressed-metadata validation, enable Windows JXL and run cross checks; coordinate the unnecessary encoder linkage with libjxlz.
- [ ] Add U5b progress controls and pure timestamp-injected rendering; verify rendered output with Peter and test terminal/width degradation.

## Deferred

- [ ] Consider DRI parallelism and SIMD after correctness coverage; measure pixel divergence before proposing spec-derived IDCT/color replacement.
