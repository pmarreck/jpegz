# PLAN

Evidence and earlier request details: [queue context](docs/plan_context/pre-canon-2026-09-24.md).
Completed history: [plan log](docs/PLAN_LOG.md).

## Priority: decode robustness on damaged input

- [x] Split src/decode/baseline.zig (1,127 code lines) into five modules, behavior-neutrally (done 2026-11-28 06:25 EST; commit 55162e7).
- [ ] Extend validation past invalid scan headers to multi-scan sequential Huffman, lossless and arithmetic sequential frames (a sequential scan has no history, so only its own components go unjudged); tell validate (context: docs/plan_context/damaged-input-parity-2026-11-27.md).
- [ ] Awaiting validate: a dedicated finding code for "scan not judged" instead of INFO unknown_marker (asked 2026-11-28 in the eb03fb8 note); adopt whatever validate assigns.
- [x] Validation records an invalid progressive scan header and decodes past it: the walker FAIL is non-blocking, the decoder skips that scan and the refinements that depend on it (INFO "not judged"), and everything else is judged; DHT Tc/Th range became exact FAIL 51 and history stops after an SOS length mismatch; validate told (done 2026-11-28 05:56 EST; commits 925aa1a, eb03fb8, 58822f1).
- [x] Remove the unreachable IDCT overflow flag and its emissions; plain checked i64 arithmetic with a worst-case bound test; no finding changes; about 4x faster IDCT (done 2026-11-28 06:58 EST; commit 9f73b31).
- [ ] Split build.zig (787 code lines, one 1,100-line build function) into coherent modules so it can be changed under the line gate.
- [ ] Split src/jpegz.zig (632 code lines; the commit gate advised it on eb03fb8) into coherent modules behind the same public API.
- [x] Implement the owner ruling on IDCT range: 64-bit arithmetic with no wrap, then a clamp to 0..2^P-1; in-range output byte-identical to libjpeg-turbo; validate told (done 2026-11-28 04:05 EST; commit 54d12d3).
- [x] OWNER: for valid files whose IDCT input is far out of range, should jpegz output exact math plus a clamp, emulate libjpeg-turbo's LP64 C path, or leave it as is? Answer: exact math plus a clamp. "We need to do the most correct thing. We don't copy faulty oracle behavior." (done 2026-11-28 00:21 EST).

- [ ] Explain the remaining pixel differences from libjpeg-turbo on damaged input: lossless is fixed (7ceac1f); arithmetic SOF9 (29), 12-bit progressive (21), SOF10 (4) and sequential (3) remain, mostly gated on the IDCT owner question (context: docs/plan_context/damaged-input-parity-2026-11-27.md).
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

- [ ] Classify the known-good corpus as a set and expand reproducible corruption-probe sweeps across JPEG-LS, JPEG 2000 and JPEG XL; JPEG-LS swept 2026-11-21 (93.0% of 1,600 on four T.87 streams; survivors all entropy) and JPEG 2000/JPEG XL swept 2026-11-22 (nine fixtures, 3,600 cases, no crash; lossless gray JXL survivors all decode in libjxl's djxl); the set-level corpus classification remains (context: docs/measurements/jp2-jxl-corruption-coverage-2026-11-22.md).
- [ ] Compare proven malformed fixtures and false rejects against prior art; report demonstrated detection, hypothetical detectability and valid changes separately. Blocked 2026-11-23: rerunning jpeg-fragments (docs/measurements/jpeg-probe-2026-09-11.md) builds with Maven-downloaded jars, and downloaded binaries are not run without owner approval or a Nix-pinned build.
- [ ] Confirm consumer promotion through tiffz.jpegz and rerun the private full-PDF experiment without publishing originals or mutants (context: docs/plan_context/pre-canon-2026-09-24.md).

## JPEG-LS conformance

- [ ] Owner decision: admit CharLS 3.0's RANGE-from-P coding of LSE MAXVAL < 2^P-1 (127 only_charls) as known_defect now, keep it unsupported until real-world files appear, or admit after checking CharLS 2.x and the latest release; validate queued it and recommends the version check if cheap (context: docs/plan_context/jpegls-t87-rulings-2026-11-22.md).
- [ ] Owner decision: how the JPEG-LS decode API should return components of unequal size (t8sse0/3): keep NotImplemented (validation and jpegls_cleanroom_decode_planes already work), upsample to full size by replication, or expose planes through the public API (context: docs/plan_context/jpegls-t87-rulings-2026-11-22.md).

## Build and CLI

- [ ] Carry libjxlz's finding detail (PAR2, ZERO_FILL, none) into the JXL facade finding's detail text, with an exhaustive guard on JxlValidationDetail so a new value fails to compile, and add the result's observation count (libjxlz note 2026-11-28).
- [ ] Drop brotlienc from the system-Brotli link, the c/enc sources from vendoredBrotli and the build.zig comment saying libjxlz's validator reaches the encoder; brotlidec and brotlicommon stay. Waits on the build.zig split. (The libjxlz pin is now 1d3c7b20, fef98af.)
- [ ] Add U5b progress controls and pure timestamp-injected rendering; verify rendered output with Peter and test terminal/width degradation.

## Deferred

- [ ] Consider DRI parallelism and SIMD after correctness coverage; measure pixel divergence before proposing spec-derived IDCT/color replacement.
