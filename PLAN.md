# PLAN

Evidence and earlier request details: [queue context](docs/plan_context/pre-canon-2026-09-24.md).
Completed history: [plan log](docs/PLAN_LOG.md).

## Priority: decode robustness on damaged input

- [ ] Explain the remaining pixel differences from libjpeg-turbo on damaged input (no crashes): 21 of 3,000 12-bit mutants, 34 of 3,000 general and 27 of 3,000 arithmetic; classify each as a parity bug or an accepted recovery difference.
- [x] Did validate confirm the two code extensions in c86fe21 (bad_marker_length on every T.81 SOS path; lossless_pointtransform_invalid for Pt >= P)? Answer: yes, both as implemented: existing codes, FAIL, exact offsets (done 2026-11-26 18:17 EST; commit c86fe21).
- [x] Lossless AC-class DHT tables are FAIL 51, non-blocking, and decoding continues (done 2026-11-26 13:24 EST; commit d62051e).
- [x] 12-bit progressive dequantization panic fixed, and 12-bit IDCT range limiting matches libjpeg-turbo's masked table (done 2026-11-26 15:33 EST; commit fa289eb).
- [x] Validate's allocation-failure segfault: no double free or leak at any refused allocation, swept over 21 fixtures (done 2026-11-26 17:00 EST; commit 1a01bd7).
- [x] Decode-path bounds: SOS and SOF fields are checked before indexing, with a single-byte totality test over every decoder family; 15,425 damaged files, 0 crashes (done 2026-11-26 18:16 EST; commit c86fe21).

## Priority: dependency freshness

- [ ] Determine which terminal layer owns copy mode on a remote SSH session and document client-side clipboard routing; client terminal and activation shortcut requested, settings unchanged.
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

- [x] Type Huffman-path data faults per validate's rulings F and G: 74, 58, FAIL 8, 56/57, truncated_stream and insufficient_data at file offsets on sequential, progressive and lossless paths; walker parity for DHT overruns, DHT symbols past the bound (51 at the byte), progressive undefined tables (69) and later-scan Ns; corpus report and reds to validate (context: docs/plan_context/arithmetic-error-classification-2026-11-22.md; done 2026-11-23 04:50 EST; commits 34e8c7e, a3eaba7, 175f09c, b30012a, 6294fcf).
- [x] Lenient Huffman resync on an out-of-order RSTm should account for the skipped intervals (libjpeg's resync advances its MCU count to the marker); today recovery stops at EOI with an extra truncated_stream. Answer: sequential and progressive resync now follow jpeg_resync_to_restart (ahead 1-2: empty interval, marker kept; behind 1-2: skip; else take); pixels outside the empty interval match the original and libjpeg-turbo (done 2026-11-23 06:30 EST; commit 3daedfd).
- [x] Complete scan consumption, MCU counts, sampling edges, noninterleaved scans, restart cadence and predictor-reset coverage across supported modes. Answer: covered on every supported mode by malformed-input tests plus 2,744 producer controls (all valid, pixel-identical to libjpeg-turbo); the sweep found and fixed lossless category 16 below 16-bit precision; lossless arithmetic has no producer and rests on hand-built tests (context: docs/plan_context/scan-geometry-coverage-2026-11-23.md; done 2026-11-23 07:35 EST).
- [x] Complete progressive scan-history and coefficient-range constraints with independent normative review and valid boundary controls. Answer: validate reviewed the rules against T.81 G.1.1.1 (rulings I); history faults are FAIL 59 with a history: detail, exact at Ss or AhAl, one per root cause; no new range rule (58 plus one-bit refinements bound it); 2,920 producer files stay valid (context: docs/plan_context/arithmetic-error-classification-2026-11-22.md; done 2026-11-23 09:20 EST).
- [ ] Classify the known-good corpus as a set and expand reproducible corruption-probe sweeps across JPEG-LS, JPEG 2000 and JPEG XL; JPEG-LS swept 2026-11-21 (93.0% of 1,600 on four T.87 streams; survivors all entropy) and JPEG 2000/JPEG XL swept 2026-11-22 (nine fixtures, 3,600 cases, no crash; lossless gray JXL survivors all decode in libjxl's djxl); the set-level corpus classification remains (context: docs/measurements/jp2-jxl-corruption-coverage-2026-11-22.md).
- [ ] Compare proven malformed fixtures and false rejects against prior art; report demonstrated detection, hypothetical detectability and valid changes separately. Blocked 2026-11-23: rerunning jpeg-fragments (docs/measurements/jpeg-probe-2026-09-11.md) builds with Maven-downloaded jars, and downloaded binaries are not run without owner approval or a Nix-pinned build.
- [ ] Confirm consumer promotion through tiffz.jpegz and rerun the private full-PDF experiment without publishing originals or mutants (context: docs/plan_context/pre-canon-2026-09-24.md).

## JPEG-LS conformance

- [ ] Owner decision: admit CharLS 3.0's RANGE-from-P coding of LSE MAXVAL < 2^P-1 (127 only_charls) as known_defect now, keep it unsupported until real-world files appear, or admit after checking CharLS 2.x and the latest release; validate queued it and recommends the version check if cheap (context: docs/plan_context/jpegls-t87-rulings-2026-11-22.md).
- [ ] Owner decision: how the JPEG-LS decode API should return components of unequal size (t8sse0/3): keep NotImplemented (validation and jpegls_cleanroom_decode_planes already work), upsample to full size by replication, or expose planes through the public API (context: docs/plan_context/jpegls-t87-rulings-2026-11-22.md).

## Build and CLI

- [x] Vendor Brotli, preserve compressed-metadata validation, enable Windows JXL and run cross checks. Answer: build.zig compiles the pinned brotliSrc (common, dec, enc) with Zig for each target via -Dbrotli-src/BROTLI_SRC, which every Nix build and the dev shell set; the Windows cross checks now link JXL; system libraries remain the fallback when no source is given (done 2026-11-23 11:45 EST).
- [ ] Track libjxlz's validator exports pulling the Brotli encoder into the link (FYI sent earlier); the vendored Brotli compiles the encoder until libjxlz drops that dependency.
- [ ] Add U5b progress controls and pure timestamp-injected rendering; verify rendered output with Peter and test terminal/width degradation.

## Deferred

- [ ] Consider DRI parallelism and SIMD after correctness coverage; measure pixel divergence before proposing spec-derived IDCT/color replacement.
