# jpegz intent

## Purpose and users

Provide one JPEG-family validation interface for validate, tiffz and other
consumers handling standalone files, PDF-embedded images and JPEG-in-TIFF,
alongside pixel decoding. The intended coverage is classic JPEG (T.81),
JPEG-LS (T.87), JPEG 2000 (T.800) and JPEG XL (ISO/IEC 18181).

Full specification coverage is the goal, not a claim about today's code.
Unsupported features and inconclusive checks must remain distinguishable from
valid input and demonstrated corruption.

## Outcomes and boundaries

- Detect provably malformed streams while preserving valid encodings, including
  uncommon and inefficient ones. A mutation can produce a different valid image.
- Keep demonstrated detection, spec-derived but untested checks and changes
  that cannot be established as invalid from the file alone separate. Peter
  explicitly set this evidence boundary on September 6, 2026.
- Provide typed findings and available locations through Zig and C interfaces;
  callers should not need to reconcile the JPEG-family validators themselves.
- Keep computation in a buffer-based core; callers own I/O and memory lifetime.
  The C CLI exercises the public C ABI. Zig siblings use Zig modules with one
  instance of each dependency in the consumer's build graph.
- Work toward self-contained decoding while retaining port attribution and
  independent test oracles. JPEG XL pixel decoding is outside the current API.
- Do not treat visual implausibility, successful recovery or decoder agreement
  as proof of strict validity. Do not promise detection of every altered file
  without independent trusted reference information.

## Verification

Each new check needs a failing malformed-input regression and valid boundary
controls. Compare decoded samples to independent oracles where applicable;
pixel parity alone does not establish complete validation. Mutation experiments
must report false rejects, unsupported/inconclusive outcomes and unresolved
labels as well as rejection rates. Head-to-head claims require identical inputs,
pinned implementations and an explicit workload.

Use the canonical build/test scripts and the validation-closure gate. Preserve
the five-platform CLI target and the constraints in [RULES.md](RULES.md).
Production validation artifacts exclude external JPEG-family decoders; Brotli
is the permitted container-metadata dependency.

## Document map

- [SPEC.md](SPEC.md): interfaces, ownership, architecture and current capabilities.
- [TERMINOLOGY.md](TERMINOLOGY.md): shared codec and verdict definitions.
- [PLAN.md](PLAN.md): execution queue, known gaps and dated measurements.
- [Prior-art comparison](docs/JPEG_VALIDATION_PRIOR_ART.md): sources and proposed evaluation.
- [LICENSING_NOTES.md](LICENSING_NOTES.md) and
  [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md): provenance and attribution.

Migrated from the accepted project overview and Peter's September detection
directions. Implementation limitations do not narrow the intended coverage.
