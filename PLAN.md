# PLAN

Evidence and earlier request details: [queue context](docs/plan_context/pre-canon-2026-09-24.md).
Completed history: [plan log](docs/PLAN_LOG.md).

## Priority: dependency freshness

- [ ] Determine which terminal layer owns copy mode on a remote SSH session and document client-side clipboard routing; client terminal and activation shortcut requested, settings unchanged.
- [x] Re-lock tools/coverage to corruption_reader 1ec8cbe, reaching performance_profiling 01ae85b and printable_binary cdefa95; refresh both nixpkgs locks to 58deea6, pass full ./test and a 60-case three-format real-tool smoke; JPEG-LS pristine gate remains open (done 2026-10-28 19:53 EDT; delivered by this change).
- [x] Expose coverage-stats through a declared Nix output, replace its dev-shell compiler bootstrap, reject unusable artifacts before mutation and pass installed-copy controls plus full ./test (done 2026-10-28 19:53 EDT; delivered by this change).
- [ ] Resolve the corruption-coverage default JPEG-LS fixture mismatch; owner choice requested among three supported defaults, an audited inconclusive JPEG-LS control, or retaining the blocked campaign; preserve classifications and denominators.
- [ ] Reconcile the October 14 inbox with published f1a255a and later yolo c8937a7; bounded fixes and fresh tooling shipped, remaining owner decisions requested from the coordinator; provider pin hold is released and sampling stays held.
- [ ] Keep the non-luma-dominant sampling packet held; do not retry that research or edit the decoder for it without new direction.
- [ ] Keep the published JP2 pin and its real Nix closure hash; do not restore draft pin 54531e26 or any placeholder hash.
- [x] Mirror approved JP2 finding 261 through Zig/C wire identity and classify its proven violation as corrupt regardless of severity; preserve conditional 252 treatment, keep unknown codes inconclusive, and pass full ./test (done 2026-10-28 19:06 EDT; delivered by this change).

## Priority: Validate false FAILs and labels (context: docs/plan_context/validate-findings-2026-09-27-to-10-14.md)

- [x] Reject additional sequential Huffman SOS after complete component coverage with exact FAIL 55; skip opaque metadata, stop at first EOI and preserve missing-EOI decode outcomes; full ./test passes (done 2026-10-28 17:21 EDT; delivered by this change).

## Priority: Validate September 30 work order

- [ ] Reproduce and fix the non-luma-dominant sampling panic with synthetic inputs and valid sampling controls; return typed failure or support the layout without out-of-bounds access.
- [x] Verify SOF1 with component IDs 0/1/2 and DHT Lh=626; all 256 cyclic ID triplets and 16 legal DC/AC destination pairs match libjpeg pixels, while 240 out-of-range selectors and eight undefined-table controls fail; no decoder change needed, full ./test passes (done 2026-10-28 17:45 EDT; delivered by this change).
- [ ] Obtain Validate's private SOF1 replay; if still failing, reproduce its first typed finding with a synthetic regression before changing the decoder; keep originals private.
- [x] Bound JP2 strict-facade positions by the input, preserve reported extents in detail, fill host cursors and retain corruption; public bit-mutation regression, production CLI JSON and full ./test pass (done 2026-10-28 18:17 EDT; delivered by this change).
- [ ] Finish JP2 leaf exactness metadata and audit legacy severity-report locations; the provider cursor/anchor/extent contract is pending, so bounds alone must not imply exactness (context: docs/plan_context/validate-findings-2026-09-27-to-10-14.md).
- [x] Publish bounded fixes through 446274f, preserving 5c5191a and 6ef766c; send Validate/tiffz exact SHAs, package hashes, scope and remaining private replay/provider blockers after exact-commit CI passes (done 2026-10-28 19:26 EDT).

## Priority: DHT memory safety

- [ ] Investigate Validate's full-stream false rejection; all four September 27 Huffman count vectors pass synthetic controls, but their acceptance does not establish validity of the private original.

## Priority: Canon CR2 sensor validation

- [ ] Confirm Validate's private full-container NRW/AVI replays after the tiffz re-pin without publishing originals or mutants.

## Existing ordered follow-ups

- [ ] Complete the separate libjxlz arithmetic scaling sweep; published e1c521d contains baseline 923d3c4c unchanged (228 fixed-size rows, hash verified), and the provider has a request for published scaling evidence or a bounded sweep (context: docs/plan_context/pre-canon-2026-09-24.md).
- [x] Verify libjxlz benchmark-history publication: 923d3c4c is an ancestor of published e1c521d, and all 228 fixed-size rows retain SHA-256 3e7b42191359de69231e34e4f235480f655b6a632fbd033599c50a60fbe83195; scaling remains a separate request (done 2026-10-28 20:15 EDT).
- [ ] Adjudicate validate's 170-byte XOR sweep and proposed marker/JFIF/DQT/SOS checks against normative clauses and valid controls (context: docs/plan_context/pre-canon-2026-09-24.md).
- [ ] Evaluate validate's coverage-range API without exempting whole constrained segments or changing denominators to improve scores.
- [ ] Review newly published jp2z/libjxlz work before future pin changes; verify private-source access and preserve strict corruption precedence.
- [ ] Verify jp2z pixel APIs and component-resolution oracles before replacing OpenJPEG; retain the T.800 edition limit and unresolved warning-class review.

## JPEG entropy and comparison coverage

- [ ] Measure the zero-padding treatment change over identical seeded corruption-coverage inputs, reporting known defects separately while preserving the judged-case denominator.
- [ ] Complete scan consumption, MCU counts, sampling edges, noninterleaved scans, restart cadence and predictor-reset coverage across supported modes.
- [ ] Complete progressive scan-history and coefficient-range constraints with independent normative review and valid boundary controls.
- [ ] Classify the known-good corpus as a set and expand reproducible corruption-probe sweeps across JPEG-LS, JPEG 2000 and JPEG XL.
- [ ] Align local mutation usage with corruption_probe a43f2cf algorithm v2: sparse shotgun flips 8-16 distinct bits in a contained 32-byte window; dense overwrite is nuke; preserve v1 history and never compare unlike definitions.
- [ ] Compare proven malformed fixtures and false rejects against prior art; report demonstrated detection, hypothetical detectability and valid changes separately.
- [ ] Confirm consumer promotion through tiffz.jpegz and rerun the private full-PDF experiment without publishing originals or mutants (context: docs/plan_context/pre-canon-2026-09-24.md).

## Build and CLI

- [x] Stabilize Nix source identity, retain required inputs and future-file bytes, and pass 18 controls plus full ./test; published dedea64 passes all 11 CI targets in 17 seconds with archive/local derivation identities equal (context: docs/plan_context/validate-findings-2026-09-27-to-10-14.md; done 2026-10-28 20:19 EDT; commit dedea64).
- [ ] Measure fresh test execution separately from admission, dependency setup, evaluation and compilation; preserve complete coverage and report the one-second target/five-second budget; cached CI artifact reuse is qualified at dedea64 (context: docs/plan_context/validate-findings-2026-09-27-to-10-14.md).
- [x] Move no-C consumer compilation into a Nix check with all three paired controls and disposable scratch; full ./test passes and the exact-commit manifest includes the check (context: docs/plan_context/validate-findings-2026-09-27-to-10-14.md; done 2026-10-28 19:53 EDT; delivered by this change).
- [ ] Port the requested upstream-first dependency-freshness gate with sibling fallback and set tests for current, stale, missing, offline and ahead-of-sibling cases.
- [ ] Vendor Brotli, preserve compressed-metadata validation, enable Windows JXL and run cross checks; coordinate the unnecessary encoder linkage with libjxlz.
- [ ] Add U5b progress controls and pure timestamp-injected rendering; verify rendered output with Peter and test terminal/width degradation.
- [ ] Confirm consumer dependency deduplication and send remaining append-only finding-registry notices (context: docs/plan_context/pre-canon-2026-09-24.md).

## Deferred

- [ ] Implement JPEG-LS restart validation and test dormant run-mode/context findings.
- [ ] Inventory remaining T.81/T.87 gaps including DNL, multiscan lossless, differential/hierarchical modes and uncommon component layouts.
- [ ] Consider DRI parallelism and SIMD after correctness coverage; measure pixel divergence before proposing spec-derived IDCT/color replacement.
- [ ] The C CLI prints "DEBUG BUILD" in ReleaseSafe because it keys on NDEBUG, which Zig leaves undefined there. Gate the banner on the real optimize mode (a build-time define) and cover ReleaseSafe in tests/cli.
