# JPEG-LS T.87 rulings and evidence (2026-11-22)

Source text: ITU-T T.87 (06/98), the freely available PDF from the ITU.
The ITU reference implementation in the same package ships only as
Windows binaries and was not run.

## LSE MAXVAL below 2^P - 1 (validate ruling 2026-11-22)

- **The spec:** T.87 A.2.1 step 1 derives RANGE, qbpp, bpp and LIMIT from
  the MAXVAL in force, an LSE ID 1 value or the default 2^P - 1.
- **FFmpeg** (libavcodec/jpegls.c) follows A.2.1.
- **CharLS 3.0** (make_scan_codec.cpp) builds its coding traits from
  2^P - 1 and uses the preset MAXVAL only for the thresholds, which it
  writes explicitly into the LSE.
  - Its `default_traits` also clamps with a bit mask and computes bpp as
    `log2_ceiling(MAXVAL)`. Both are correct only when MAXVAL is 2^k - 1.
  - No upstream issue was found. CharLS issue #51 is a related thresholds
    bug, and dicos.rs describes the same behavior.
- **Ruling:** implement A.2.1, and decode each LSE-MAXVAL scan both ways.

  | Clean decodes | Result |
  |---|---|
  | Both | `valid` plus INFO (new code, proposed 127) `also_charls` |
  | Only A.2.1 | `valid` |
  | Only CharLS | INFO `only_charls` and `unsupported`, until a known-defect admission |
  | Neither | the A.2.1 findings |

- **Before shipping:** send validate the admission numbers:
  - a CharLS corpus over MAXVAL, NEAR and content: how many decode clean
    under A.2.1, under CharLS's derivation, or both;
  - how often the both-clean pixels match the formula under each derivation;
  - the affected CharLS versions;
  - FFmpeg against jpegz on the A.2.1 decodes.

  The A.2.1 decode, the dual-decode classification and the INFO code ship
  together.
- **Oracles:**
  - "Spec-mode CharLS" is CharLS 3.0's make_scan_codec.cpp rebuilt with a
    force-included header that maps `calculate_maximum_bit_sample_value`
    to the preset MAXVAL, plus `-DDISABLE_SPECIALIZATIONS`. Over 72 streams
    (MAXVAL 2^k - 1, NEAR 0/1/3, four contents), FFmpeg 9.0.1 reproduces
    every source: 24 exactly and 48 within NEAR.
  - Over 144 stock CharLS 3.0 streams, FFmpeg gives 114 mismatches and 18
    errors. The other 12, where RANGE coincides under both derivations,
    are within NEAR.

## Mapping tables, point transform, DNL (validate codes 2026-11-22)

- **Decoding is unaffected:** T.87 clause 7 places the sample mapping and
  the inverse point transform after decoding, so neither changes entropy
  decoding.
- **124 `jpegls_mapping_table_undefined`, FAIL:** a Tmi names a table not
  yet specified (C.2.3). Offset: the SOS Tmi byte.
- **125 `jpegls_mapping_with_point_transform`, WARN:** Pt is nonzero while
  some Tmi is nonzero (C.2.3). Offset: the Tmi byte.
- **126 `jpegls_mapping_table_invalid`, FAIL,** with one detail token per
  rule:
  - `tid_range`, `wt_range`: TID or Wt outside 1..255;
  - `length`: Ll is not 5 + Wt(MAXTAB+1), per Figure C.7;
  - `continuation`: an ID 3 segment without a preceding ID 2 or ID 3
    segment with the same TID and Wt;
  - `entries`: the entry count is not MAXVAL+1 for the MAXVAL in force at
    the referring scan.

  The segment-local rules FAIL even when no scan uses the table. `entries`
  applies only at a referring scan, at the LSE marker, with the SOS offset
  in the detail.
- **DNL:** with Y = 0, read Y from a DNL immediately after the first scan
  (C.2.2), and reuse 72 `dnl_misplaced` otherwise. Control: a CharLS
  stream with Y set to 0 and a DNL inserted must decode to identical
  pixels.
- **Point transform:** the decode output is Rx << Pt (4.3.2). Table C.2's
  default MAXVAL is 2^P - 1 whatever Pt is.
- **Before shipping:** a corpus report and controlled reds, including a
  CharLS-made mapping-table stream.

## Point transform overflow (validate ruling 2026-11-22)

- **128 `jpegls_point_transform_overflow`, FAIL:** a sample with
  Rx · 2^Pt > 2^P − 1.
  - The output saturates to 2^P − 1, never wraps.
  - One record per scan, at the first occurrence, with the count. Offset:
    the SOS Al byte (not exact), unless the exact bit is tracked.
  - It applies only to unmapped components, since 125 covers Pt with a
    mapping table.
- **No finding** for an LSE MAXVAL above (2^P − 1) >> Pt, because Table
  C.2's default does the same.
- **Key fixtures:** Pt = 1 with one overflowing Rx (128 at P = 8), and a
  control whose largest sample, 127, shifts to 254.
