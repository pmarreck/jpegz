# jpegz future directions

Reconciled on 2026-09-06. [PLAN.md](PLAN.md) owns active work. This file
retains deferred options from May; the original analysis is available in Git
at `187248d:FUTURE_DIRECTIONS.md`. Its market predictions, profitability
ratings, and sibling-project status claims have not been revalidated.

## Current scope boundary

The validation facade covers T.81, T.87 JPEG-LS, T.800 JPEG 2000, and JPEG XL.
Coverage remains incomplete. JP2/JXL codec source lives in sibling projects;
different internals do not exclude a codec from the shared validation API.
JPEG XL pixel decoding is outside jpegz's current API.

Differential and hierarchical T.81 processes remain deferred parts of the
spec-completeness goal. Inventory their actual parsing and decoding gaps with
fixtures before designing an implementation. The old document's claims about
unrecognized markers and unavailable fixture generators are historical.

## Options requiring a consumer and a scope decision

| Option | Decision to make before implementation |
|---|---|
| JPEG encoder | Determine the required output modes and quality controls; consider a sibling `jpegzz` with shared primitives. |
| JPEG XR, XS, or XT | Establish the consumer's input set and required validation depth; decide codec ownership separately from facade exposure. |
| MPF or other multi-picture metadata | Assign container parsing to a metadata owner, then pass extracted JPEG payloads to jpegz. |
| JFIF/Exif/IPTC/XMP library | Check existing consumer implementations before proposing a shared metadata project. |
| HEIF container support | Identify required payload codecs and the owning project; do not assume JPEG decoding satisfies the request. |
| Embedded camera previews | Keep outer container parsing with its owner; jpegz receives the extracted JPEG bytes. |
| JBIG/JBIG2 | Treat as a separate codec decision; these are outside the current JPEG-family facade. |

These options do not assert that a sibling project is absent or that an
extension has commercial demand. Verify current projects and consumer needs
when an option becomes active.

## Decision discipline

Record the requested behavior, fixture set, ownership, and acceptance tests
in PLAN.md before implementation. The JP2/JXL integrations provide an existing
pattern for independently maintained codecs behind one consumer interface.
