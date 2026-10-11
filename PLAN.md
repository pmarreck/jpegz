# PLAN

Evidence and earlier request details: [queue context](docs/plan_context/pre-canon-2026-09-24.md).
Completed history: [plan log](docs/PLAN_LOG.md).

## Priority: dependency freshness

- [x] Repin JP2Z to published head `91264891`, regenerate the Zig dependency closure hash, pass complete local gates, and publish `8d325c6`; Mechatron Prime passed the exact commit in 14 seconds (done 2026-10-10 20:14 EDT).
- [x] Refresh direct codec source pins and the transitive Zig/Nix lock graph against live upstream heads; update hashes, fix CharLS/Brotli build compatibility, pass tests/build and retain the queued strictness work (done 2026-10-08 21:12 EDT).
- [x] Retain the latest Zig 0.16.x release, refresh the overlay, track nixpkgs-unstable within seven days of its head and treat newer-series requirements as advisory (done 2026-10-08 21:12 EDT).

## Priority: Validate September 30 work order

- [x] Fix partial plane/coefficient allocation leaks; sweep every allocation failure in 8/12-bit RGB, RGB passthrough, subsampled RGB and CMYK decodes (done 2026-09-30 02:57 EDT).
- [ ] Reproduce and fix the non-luma-dominant sampling panic with synthetic inputs and valid sampling controls; return typed failure or support the layout without out-of-bounds access.
- [ ] Reproduce SOF1 with component ids 0/1/2 and Huffman table pairs 0/1/2; accept legal table ids 0-3 and distinguish any remaining private-stream failure.
- [ ] Verify JP2 leaf offset semantics; preserve exact in-buffer offsets and represent EOF or declared extents without claiming nonexistent byte locations.
- [ ] Reproduce zero-bit entropy padding; add its own typed FAIL finding and exact byte offset, retain the excess-entropy FAIL, and verify T.81 F.1.2.3 (Validate's September 30 correction confirms severity).
- [ ] Publish green bounded fixes and send Validate/tiffz exact SHA, package hash, scope and remaining blockers; preserve 5c5191a and 6ef766c.

## Priority: DHT memory safety

- [x] Reject oversubscribed and reserved-all-ones DHTs before code assignment; preserve legal near-full and 256-symbol controls; pass ReleaseSafe/ReleaseFast, full tests/build, Windows and closure checks; existing private NRW/AVI JPEG payloads report corrupt without crashing (done 2026-09-29 19:51 EDT).
- [ ] Investigate Validate's full-stream false rejection; all four September 27 Huffman count vectors pass synthetic controls, but their acceptance does not establish validity of the private original.
- [x] Relay Peter's benchmark-history and scaling expectation to Einstein; his September 28 reply confirms the shared AGENTS policy, without retroactive fleet edits (done 2026-09-29 19:51 EDT; original relay 2026-09-28 14:51 EDT).

## Priority: Canon CR2 sensor validation

- [x] Resolve rawz's two-component SOF3 validation with failing regressions, checked entropy/EOI traversal and payload-relative findings; pixel decoding remains unchanged (done 2026-09-24 22:05 EDT, 6ef766c).
- [x] Measure Canon mutations: random replacement51/100, bit flips24/100, XOR-FF64/100, truncations100/100, final64 EOF cuts64/64, pristine controls4/4 (done 2026-09-24 22:04 EDT, 6ef766c; context: docs/measurements/canon-sof3-2026-09-24.md).
- [x] Pass the full suite, build, Windows and closure checks; publish 6ef766c and send rawz/tiffz its exact SHA/API, evidence and limits (done 2026-09-24 22:13 EDT; exact-commit CI status follows in their handoffs).
- [x] Confirm tiffz's single jpegz instance re-pinned to 5c5191a with Canon 6ef766c; tiffz b5e58c46 passed tests and exact-commit CI, and its public DHT repro now reports fail instead of SIGSEGV (done 2026-09-29 20:16 EDT, per tiffz's inbox replies).
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
