# PLAN

Evidence and earlier request details: [queue context](docs/plan_context/pre-canon-2026-09-24.md).
Completed history: [plan log](docs/PLAN_LOG.md).

## Priority: dev shell reentry

- [x] Stop a nix dev shell reentry from repeating the libjxlz fetch when that pin is already in the Zig cache (done 2026-10-15 15:54 EDT).
- [x] Hand the repeated dev-shell zig fetch to the fleet coordinator for a cross-project check and a writing-nix skill note (done 2026-10-15 16:46 EDT).

## Priority: dependency freshness

- [x] Pin jp2z, libjpeg-turbo, Brotli, CharLS, and the flake lock to their newest published revisions with real hashes; leave unpublished libjxlz commits unpinned and keep OpenJPEG where it is already current (done 2026-10-15 14:56 EDT).
- [x] Repin JP2Z to published head `91264891`, regenerate the Zig dependency closure hash, pass complete local gates, and publish `8d325c6`; Mechatron Prime passed the exact commit in 14 seconds (done 2026-10-10 20:14 EDT).
- [ ] Determine which terminal layer owns copy mode on a remote SSH session and document client-side clipboard routing; do not change settings unasked.
- [x] Add ./corruption-coverage for sniper, bolter, shotgun and nuke, with a pristine gate and Wilson 95% intervals over judged cases only; a 100-round live run on baseline_2x2_rgb.jpg passed with corruption-reader 0.7.0 (done 2026-10-15 14:20 EDT).
- [x] Release the JPEG provider hold for published-pin adoption. Freshness gates stay, with no stale override and no placeholder hash. The non-luma sampling packet stays held (done 2026-10-15 22:35 EDT).
- [ ] Reconcile the October 14 inbox with published f1a255a and later yolo c8937a7. The provider hold is released for pin adoption and the sampling packet stays held. Advance one unblocked milestone and send the coordinator a receipt with any genuine owner decisions.
- [x] Send the requested safe checkpoint with the JP2 red witness, dirty source state and completed Nix hash-job receipt; leave adoption uncommitted and the sampling packet held (done 2026-10-10 00:29 EDT).
- [x] Adopt the SIZ tile-origin regression on jp2z 434b9d53 without restoring draft pin 54531e26; ARM64 link gates pass in ./test (done 2026-10-15 14:56 EDT, context: docs/measurements/jp2-tile-origin-2026-10-10.md).
- [ ] Keep the non-luma-dominant sampling packet held; do not retry that research or edit the decoder for it without new direction.
- [ ] Keep the published JP2 pin and its real Nix closure hash; do not restore draft pin 54531e26 or any placeholder hash.
- [ ] Mirror approved JP2 finding 261 with a red mapping/ABI regression and conditional-severity controls for 252; do not retry the held sampling research.
- [x] Refresh direct codec source pins and the transitive Zig/Nix lock graph against live upstream heads; update hashes, fix CharLS/Brotli build compatibility, pass tests/build and retain the queued strictness work (done 2026-10-08 21:12 EDT).
- [x] Retain the latest Zig 0.16.x release, refresh the overlay, track nixpkgs-unstable within seven days of its head and treat newer-series requirements as advisory (done 2026-10-08 21:12 EDT).

## Priority: Validate September 30 work order

- [ ] Reproduce and fix the non-luma-dominant sampling panic with synthetic inputs and valid sampling controls; return typed failure or support the layout without out-of-bounds access.
- [ ] Reproduce SOF1 with component ids 0/1/2 and Huffman table pairs 0/1/2; accept legal table ids 0-3 and distinguish any remaining private-stream failure.
- [ ] Verify JP2 leaf offset semantics; preserve exact in-buffer offsets and represent EOF or declared extents without claiming nonexistent byte locations.
- [ ] Reproduce zero-bit entropy padding; add its own typed FAIL finding and exact byte offset, retain the excess-entropy FAIL, and verify T.81 F.1.2.3 (Validate's September 30 correction confirms severity).
- [ ] Publish green bounded fixes and send Validate/tiffz exact SHA, package hash, scope and remaining blockers; preserve 5c5191a and 6ef766c.

## Priority: DHT memory safety

- [ ] Investigate Validate's full-stream false rejection; all four September 27 Huffman count vectors pass synthetic controls, but their acceptance does not establish validity of the private original.

## Priority: Canon CR2 sensor validation

- [ ] Confirm Validate's private full-container NRW/AVI replays after the tiffz re-pin without publishing originals or mutants.

## Existing ordered follow-ups

- [ ] Finish libjxlz benchmark-history publication coordination and the separate arithmetic scaling sweep; September 28 inspection finds local baseline 923d3c4c committed but the September 20 release-of-hold note still pending and the sibling PLAN still waiting for that baseline (context: docs/plan_context/pre-canon-2026-09-24.md).
- [ ] Adjudicate validate's 170-byte XOR sweep and proposed marker/JFIF/DQT/SOS checks against normative clauses and valid controls (context: docs/plan_context/pre-canon-2026-09-24.md).
- [ ] Evaluate validate's coverage-range API without exempting whole constrained segments or changing denominators to improve scores.
- [ ] Review newly published jp2z/libjxlz work before future pin changes; verify private-source access and preserve strict corruption precedence.
- [ ] Verify jp2z pixel APIs and component-resolution oracles before replacing OpenJPEG; retain the T.800 edition limit and unresolved warning-class review.

## JPEG entropy and comparison coverage

- [ ] Complete scan consumption, MCU counts, sampling edges, noninterleaved scans, restart cadence and predictor-reset coverage across supported modes.
- [ ] Complete progressive scan-history and coefficient-range constraints with independent normative review and valid boundary controls.
- [ ] Classify the known-good corpus as a set and expand reproducible corruption-probe sweeps across JPEG-LS, JPEG 2000 and JPEG XL.
- [ ] Align local mutation usage with corruption_probe a43f2cf algorithm v2: sparse shotgun flips 8-16 distinct bits in a contained 32-byte window; dense overwrite is nuke; preserve v1 history and never compare unlike definitions.
- [ ] Compare proven malformed fixtures and false rejects against prior art; report demonstrated detection, hypothetical detectability and valid changes separately.
- [ ] Confirm consumer promotion through tiffz.jpegz and rerun the private full-PDF experiment without publishing originals or mutants (context: docs/plan_context/pre-canon-2026-09-24.md).

## Build and CLI

- [ ] Port the requested upstream-first dependency-freshness gate with sibling fallback and set tests for current, stale, missing, offline and ahead-of-sibling cases.
- [ ] Vendor Brotli, preserve compressed-metadata validation, enable Windows JXL and run cross checks; coordinate the unnecessary encoder linkage with libjxlz.
- [ ] Add U5b progress controls and pure timestamp-injected rendering; verify rendered output with Peter and test terminal/width degradation.
- [ ] Confirm consumer dependency deduplication and send remaining append-only finding-registry notices (context: docs/plan_context/pre-canon-2026-09-24.md).

## Deferred

- [ ] Implement JPEG-LS restart validation and test dormant run-mode/context findings.
- [ ] Inventory remaining T.81/T.87 gaps including DNL, multiscan lossless, differential/hierarchical modes and uncommon component layouts.
- [ ] Consider DRI parallelism and SIMD after correctness coverage; measure pixel divergence before proposing spec-derived IDCT/color replacement.
