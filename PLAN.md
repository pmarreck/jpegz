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
- [x] Name trailing whole bytes after a lossless scan instead of reporting huffman_table_corrupt BackendError (tiffz observation 2026-11-06). Done: the lossless boundary handler reports finding 51 with the baseline detail "N whole byte(s) after valid padding before marker 0xXX" at end of scan and at restart boundaries; class unchanged; red on one stray byte, controls for two bytes and a stuffed FF00 (done 2026-11-06 13:35 EST).
- [x] Add jpegz.jpegxl.decode through libjxlz's decoder API at the current pin (tiffz request 2026-11-06, JPEG XL in TIFF 50002 and DNG 1.7 52546). Done: returns Decoded{image, color_channels, has_alpha, extra_channels_dropped}; first coalesced frame in stored orientation; u8 or host-order u16 rescaled exactly from the API's full-range output to the stored depth; UnsupportedPrecision for float, NotImplemented without JPEG XL or for alpha at another depth; six cjxl -d 0 fixtures (gray, gray+alpha, RGB, RGBA at 8 bits, gray 12, RGB 16) decode every formula sample exactly, djxl agrees byte for byte; truncation and garbage give typed errors; 2 mutants killed (no rescale: 62 of 63 12-bit samples wrong; alpha dropped) (done 2026-11-06 19:55 EST).
- [x] Exactly-full Huffman table (Pentax K-x, K-r, Ricoh GR, DJI FC4382 DNGs; validate approved code 71 on 2026-11-06, owner admitted as a known defect). Done: huffman.codeSpace classifies valid, full_all_ones (Kraft sum exactly 1 with the all-ones code the only violation) or invalid; decoders accept a full table and decode its all-ones code (T.81 F.2.2.3); the validator reports 71 at known_defect at the BITS byte for the full length; a hand-encoded lossless stream that uses the all-ones code decodes every sample; a baseline file with an unused full DC table decodes identically; near misses (one code oversubscribed, a longer code after the full length) stay FAIL 51; 3 mutants killed (done 2026-11-06 22:45 EST).
- [x] Prevalence report for bytes after the first EOI (validate request 2026-11-07, no code change). Answer: 1 of 5,391 real-world JPEGs (805 photos, 4,586 scans) has trailing bytes, a 2-byte CRLF; none has an MPF, PAR2 or SEFT trailer; the only fixture trailer is the 19-byte JUNK in baseline_4x4_with_trailing.jpg (and its copy in validate/tiffz); MPF and PAR2 carve-outs will need synthetic fixtures; table sent to validate (done 2026-11-07 00:36 EST).
- [ ] Then re-grade 212 trailing_data_after_eoi (owner 2026-11-06 PAR2 rule): bytes MPF fully explains are no finding or INFO, PAR2\0PKT is INFO with detail par2 and the trailer offset, anything else WARN; controlled red, an MPF near miss one offset short, and a cut PAR2 magic that stays WARN; keep code 212 with a detail value (mpf, par2, other); validate edge rules 2026-11-07: MPF entries consume what they cover, bytes past the last covered image are other (WARN) at the first uncovered byte, a PAR2 trailer after MPF images is INFO at its own start, and the CRLF real-world file becomes WARN.
- [x] Go 1.0 SOS known defect, finding 68 sequential_scan_zero_se (validate approved 2026-11-06). Done: Ss=0 Se=0 Ah=Al=0 in a sequential scan that covers every component is judged after the walk: known_defect at the Se byte when it is the only scan, FAIL 64 otherwise; exemplar is baseline_2x2_rgb.jpg with the Se byte set to 0 (a patched SOS tail, as Go wrote it), decoding pixel-identical; near misses (Se 5, Go tail plus Ah=1, Ss=1 with Se=0, the same scan followed by a second scan) stay 64; the 0..255 Se sweep now expects 68 at Se=0; 3 mutants killed (done 2026-11-07 03:00 EST).
- [x] Emit finding 67 at known_defect for exactly JFIF version bytes 02 01 in an otherwise sound APP0 (A2, FFmpeg/Libav, owner admitted 2026-11-06). Done: sound means units 0..2, nonzero densities and a thumbnail filling the segment exactly; exemplar historic_a2_ffmpeg_jfif_0201.jpg exits 4; near matches (02 00, 02 02, 03 01, units 3, zero density, missing or extra thumbnail bytes) stay WARN 67, and 01 01, JFXX and a 13-byte body raise nothing; red was the exemplar at WARN; 4 mutants killed (no match, density, units, thumbnail length) (done 2026-11-06 17:50 EST).
- [x] Re-grade any severity chosen because readers decode the file (owner 2026-11-06: WARN is a likely-writer spec violation, never a reader judgment). Done: one changed row, missing_eoi WARN to FAIL severity (verdict already corrupt; legacy isValid now rejects it; the codec check still runs); rows 8, 60, 63, 67 and the reader-citing FAIL rows hold on spec and producer grounds; reader-based rationale removed from code comments and SPEC; red was the severity and isValid assertions; 2 mutants killed (WARN kept, FAIL made blocking) (context: docs/plan_context/severity-audit-2026-11-05.md; done 2026-11-06 19:10 EST).
- [ ] HOLD row 65 jfif_metadata_invalid at FAIL until the owner rules (validate recommends FAIL and will relay).
- [x] Finding 70 sof_component_id_duplicate (A29; validate approved 2026-11-07 00:00). Done: the validator reports a repeated SOF component ID at its Ci byte, WARN for exactly four components with IDs (1, 2, 3, 1) and FAIL otherwise; the baseline and extended decoder resolves that frame's interleaved (1, 2, 3, 1) scan by position, and the validator no longer reports that one scan's repeated selector; the A29 exemplar decodes pixel-identical to baseline_4x4_cmyk.jpg; near misses (1,1,3,4), (1,2,1,4), (2,2,3,1), SOS order (1,1,2,3) and a three-component duplicate all FAIL; 3 mutants killed (done 2026-11-07 00:45 EST).
- [x] Finding 69 huffman_tables_missing (A3, validate approved 2026-11-06). Done: the baseline and extended decoder installs the T.81 K.3 tables (src/decode/k3_tables.zig, bytes from libjpeg-turbo's standard tables) when no DHT precedes the first scan; the validator reports 69 at the first SOS, known_defect when no DHT exists anywhere and every scan decodes completely, FAIL otherwise, and FAIL at the exact Td/Ta byte when DHT exists but a scan names an undefined table (complete selector lists only); the A3 exemplar equals its control minus DHT and decodes pixel-identical; controls: half the entropy cut (FAIL 69), the chroma AC table removed (FAIL 69 at its Ta byte), progressive without DHT (FAIL, no 69); 3 mutants killed (done 2026-11-07 05:40 EST).
- [ ] Map libjxlz raw finding 18 invalid_modular_transform (libjxlz f3b7933f, owner-chosen, FAIL class) once validate reserves FindingCode 198: append to errors.zig, map in the facade with a controlled red, extend the exhaustive pair tests and repin libjxlz (at or after badad57a, truncated containers report jxl_truncated instead of jxl_malformed; update any pinned expectation); raw 18 fails closed as indeterminate until then.
- [ ] libjxlz origin and detail fields landed in 2cf83070: repin with the 198 mapping and derive JXL class from origin through an exhaustive switch (unknown origin fails closed); validate assigned 199 jxl_trailing_data (2026-11-07: WARN, INFO for detail par2 with the trailer start offset, zero_fill WARN); raw 19 detection landed in libjxlz fd619360 (exact first trailing byte; par2 INFO, zero_fill and none WARN), so repin at or after fd619360 (3d0660c8 also turns ICC entropy stops into typed CORRUPT codes and names a FAIL finding before an unclassified stop; update pinned expectations) and map 199 with the trailer offset; keep a test that 9 and 13 stay FAIL; the JPEG XL band is full, so a further mirror needs a new band from validate.
- [ ] Complete the separate libjxlz arithmetic scaling sweep; published e1c521d contains baseline 923d3c4c unchanged (228 fixed-size rows, hash verified), and the provider has a request for published scaling evidence or a bounded sweep (context: docs/plan_context/pre-canon-2026-09-24.md).
- [ ] Finish provider qualification after source review of jp2z 0c2162b and libjxlz e1c521d; facade 197 is shipped and libjxlz CI is complete for five targets at 1a53d9d9 and d6cfb688 (prepared-artifact reuse); real-input integration and cold private-source access remain required before any pin change; the November 3 provider note (more raw-8 histogram cases now raw-16 corrupt, open container prefixes now NEED_MORE_INPUT, local five-target evidence only) joins the same review (context: docs/plan_context/validate-findings-2026-09-27-to-10-14.md).
- [ ] Verify jp2z pixel APIs and component-resolution oracles before replacing OpenJPEG; retain the T.800 edition limit and unresolved warning-class review.

## JPEG entropy and comparison coverage

- [x] Measure the zero-padding treatment change over identical seeded corruption-coverage inputs, reporting known defects separately while preserving the judged-case denominator. Answer: ca500f9 vs 8fd246d on four T.81 Huffman fixtures, 1,600 judged cases each: exactly 7 cases (0.44% [0.21, 0.90], all bolter) moved from corrupt to accepted and none the other way; replayed through HEAD all 7 are known_defect with finding 63 as the only non-INFO finding, so damage mimics the admitted signature at that rate (context: docs/plan_context/zero-padding-coverage-2026-11-06.md; done 2026-11-06 14:20 EST).
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
