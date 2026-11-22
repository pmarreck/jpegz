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
