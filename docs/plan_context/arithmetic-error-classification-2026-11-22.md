# Arithmetic-coded JPEG decode error classification (validate ruling 2026-11-22)

Context: jpegz 5f8c2f6 fixed the arithmetic decoders' restart resume offset.
That exposed that SOF9/SOF10 decode errors are untyped, and that the
validator's generic mapping reports every one as FAIL 51
`huffman_table_corrupt`. Validate's ruling, following the 2026-11-21 JPEG-LS
rulings (same code as the T.81 Huffman path for the same situation):

1. **Restart faults:** an RSTm that is missing, out of order or unexpected
   where DRI applies is FAIL 56 `restart_marker_missing` or 57
   `restart_marker_unexpected`, typed at the marker.
2. **Entropy data ends early:** `insufficient_data` at the marker, 57 for an
   RSTm, and `truncated_stream` when the file ends there.
3. **Invalid DAC values:** values outside T.81 B.2.4.3 (Tc, Tb, DC L > U or
   U > 15, AC Kx outside 1..63) are FAIL 53 `arithmetic_table_corrupt` at
   the offending DAC byte.
4. **Decoded values with no specified decode:** the code the Huffman path
   gives the same condition, e.g. 58 `dct_coefficient_overflow`.

**Mapping rules:**
- No arithmetic decode error maps to `huffman_table_corrupt`.
- The mapping is an exhaustive switch, as for JPEG-LS (`mapJpeglsDecodeError`
  in src/core/validator.zig).
- An error with no Huffman analogue goes to validate with a proposed code
  before it ships.
- A failure that cannot be localized to a byte reports at the start of its
  restart interval, or at the SOS without DRI, labeled as the interval.

**Before shipping:** send the corpus report and controlled reds to validate.

## Follow-up ruling (validate, 2026-11-22)

**A. Unread bytes before a marker:** FAIL 8 `extraneous_bytes_before_marker`,
exactly at the first byte the decoder never fetched. Detail is
`arithmetic_interval` or `arithmetic_scan_end`.
- **Basis:** the T.81 D.1.8 flush emits only bytes the decoder fetches.
- **Not unread:** 0xFF fill bytes, and bytes already taken by pre-fetch.
- **Before shipping:** run every reachable arithmetic producer
  (libjpeg-turbo across restart intervals and image sizes, jpegtran
  `-arithmetic`, IJG libjpeg 9 if available, corpus SOF9/SOF10 files). Any
  producer that leaves unread bytes goes back to validate for a re-grade
  instead of shipping FAIL.

**B. Early end of entropy data:** no separate finding.
- **Why:** D.1.8 lets encoders drop trailing zero bytes, and D.2.6 supplies
  zeros past a marker.
- **Where damage surfaces:** short intervals desynchronize and show up as
  56, 57 or 8 at the next boundary.
- **Missing marker:** a file that ends without its marker keeps
  `truncated_stream`.
- **Detection limit (document in SPEC):** a short final interval whose
  zero-filled decode completes cleanly cannot be detected.

## Decoded-fault ruling (validate, 2026-11-22)

1. **58 `dct_coefficient_overflow`** covers every magnitude category past
   T.81's bound for precision P.
   - **DCT:** a DC difference category above P+3, or an AC category above
     P+2. That is 11 and 10 at 8 bits, and 15 and 14 at 12 bits (F.1.2.1,
     F.1.2.2). Progressive scans use the same unshifted bound.
   - **Lossless:** a difference category above 16 (H.1.2.2).
   - **Scope:** applies to the Huffman path as well, for parity.
   - **Offset:** the restart interval start (or SOS without DRI), labeled
     as the interval and not exact.
   - **Before shipping:** a producer and corpus check; any producer past
     the bound goes back for a re-grade.
2. **New FAIL 74 `entropy_decode_invalid`:** the entropy-coded decision or
   code sequence has no valid T.81 decode at that point. First use: a zero
   run past Se.
   - **Offset:** the interval start, labeled as the interval.
   - **Requested:** a list of Huffman-path cases now mapped to 51 that are
     data faults rather than table faults (for example a run past Se with a
     valid table, or a code that matches no table entry), with corpus
     counts. Validate rules separately on moving them to 74; they stay at
     51 until then.
