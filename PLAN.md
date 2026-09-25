# PLAN

Evidence and earlier request details: [queue context](docs/plan_context/pre-canon-2026-09-24.md).
Completed history: [plan log](docs/PLAN_LOG.md).

## Priority: Canon CR2 sensor validation

- [x] Resolve rawz's two-component SOF3 validation with failing regressions, checked entropy/EOI traversal and payload-relative findings; pixel decoding remains unchanged (done 2026-09-24 22:05 EDT, 6ef766c).
- [x] Measure Canon mutations: random replacement51/100, bit flips24/100, XOR-FF64/100, truncations100/100, final64 EOF cuts64/64, pristine controls4/4 (done 2026-09-24 22:04 EDT, 6ef766c; context: docs/measurements/canon-sof3-2026-09-24.md).
- [x] Pass the full suite, build, Windows and closure checks; publish 6ef766c and send rawz/tiffz its exact SHA/API, evidence and limits (done 2026-09-24 22:13 EDT; exact-commit CI status follows in their handoffs).
- [ ] Confirm consumer-owned promotion of Canon SOF3 support through tiffz.jpegz after the rawz/tiffz handoff (production pin: 6ef766c8d35d9e4b3aebf533a0854632df9bda96).

## Existing ordered follow-ups

- [ ] Finish libjxlz benchmark-history publication coordination and the separate arithmetic scaling sweep (context: docs/plan_context/pre-canon-2026-09-24.md).
- [ ] Adjudicate validate's 170-byte XOR sweep and proposed marker/JFIF/DQT/SOS checks against normative clauses and valid controls (context: docs/plan_context/pre-canon-2026-09-24.md).
- [ ] Evaluate validate's coverage-range API without exempting whole constrained segments or changing denominators to improve scores.
- [ ] Review newly published jp2z/libjxlz work before future pin changes; verify private-source access and preserve strict corruption precedence.
- [ ] Verify jp2z pixel APIs and component-resolution oracles before replacing OpenJPEG; retain the T.800 edition limit and unresolved warning-class review.

## JPEG entropy and comparison coverage

- [ ] Complete scan consumption, MCU counts, sampling edges, noninterleaved scans, restart cadence and predictor-reset coverage across supported modes.
- [ ] Complete progressive scan-history and coefficient-range constraints with independent normative review and valid boundary controls.
- [ ] Classify the known-good corpus as a set and expand reproducible corruption-probe sweeps across JPEG-LS, JPEG 2000 and JPEG XL.
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
