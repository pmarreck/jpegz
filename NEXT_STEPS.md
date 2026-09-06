# Retained decisions from the May 2026 handoff

Retired as a pickup document on 2026-09-06. Use [PLAN.md](PLAN.md) for active
work and [SPEC.md](SPEC.md) for the current interface. The old coverage matrix,
commands, and task recommendations described May snapshots and contradicted
later implementations. Their full text remains in Git at `187248d:NEXT_STEPS.md`.

This file remains because source comments, tests, and design records cite the
decisions below. Original milestone names A1/A2/A3/B1/B2 refer to the dated
designs under `docs/superpowers/specs/`, not pending work.

## Validation-strictness: warns over silent tolerance

Peter's decision, 2026-05-08, confirmed 2026-05-09: when a decoder recovers
using libjpeg-style tolerance, validation must surface the condition in its
findings. Image renderers can opt into partial pixels; integrity validators
need the deviations reported.

The current API defaults to strict decoding. Recovery is opt-in through
`DecodeOptions.lenient`, with a `FindingsSink` for diagnostics.
The older `ValidationReport` accepts warning-level findings in `isValid()`.
`validateAny` classifies recovered entropy truncation and restart faults as
corrupt while preserving legal fill warnings. Classification of unchecked
variants and remaining entropy-accounting gaps stays in PLAN.md.

The original review list included premature entropy exhaustion, absent or
misordered restart markers, DC predictor reset errors, entropy fill handling,
Huffman table structure, and conflicting color markers. Each requires a
spec-derived check and good-input controls; this list does not establish that
every listed condition is illegal or that all checks are implemented.
The entropy work order in PLAN.md supplies the current acceptance criteria.

## Integer/fixed-point over IEEE754

Peter's decision, 2026-05-08: prefer integer/fixed-point arithmetic for IDCT,
color conversion, and DSP so rounding is reproducible across platforms.
The production DSP kernels are IJG-attributed Zig ports. The Annex A floating
IDCT remains a reference implementation; changing the production path requires
pixel-difference analysis and consumer coordination.

## Threading API contract

`DecodeOptions.threads` defaults to 1 (calling thread); 0 explicitly opts
into automatic selection; values above 1 are per-call budgets. No environment
variable or process-global setting implicitly enables parallel work.
Implementations may use fewer threads when work is too small to amortize
creation. This contract does not imply parallel entropy decoding exists in
every codec.

## Test fidelity

Use exact pixel comparisons for the fixture modes whose oracle parity is
already established. Preserve each test's actual precision and tolerance.
The old blanket allowance of two LSBs was superseded by tighter comparisons;
do not loosen tests from this historical document. Pixel parity alone cannot
prove validation strictness.

## Consumer-coordination gaps

Output `Image.layout` describes the returned bytes; `source_color_space`
describes the encoded source. An opt-in native-color output mode remains a
future consumer-driven decision.

RGB-marked baseline and Mode-2 component-ID handling were fixed in June 2026;
the former gap D is closed. Shared marker parsing and the precision-generic
baseline scan/assembly paths also shipped. They are not pending refactors.

## Coverage notification

Peter requested notification to tiffz and validate after broad variant
coverage, passing tests, and passing CI. Mechatron Prime is the CI authority.
Report measured coverage and remaining unsupported modes; do not use the
retired May matrix as evidence of completion.
