# T.81 / T.87 gap inventory (2026-11-21)

Read from the code at 2668f6c. "Decode" means the cleanroom pixel decoder;
"validate" means `jpegz.validate` (marker walk plus the codec check that
decodes through the cleanroom path). A row marked *code-read* was found by
reading the source; it has not yet been reproduced with a fixture.

Under the owner's rulings ("just what's out of spec", "parse everything
parseable"), two kinds of gap matter differently:

- **False FAIL**: a spec-valid stream graded as damage. These are defects.
- **Unchecked**: the codec check reports INFO `unknown_marker` ("codec
  integrity not checked"). Honest, but the stream is not validated.

## False FAIL or silent mis-decode (fix first)

| Gap | Where | Today | Spec |
|---|---|---|---|
| DNL with SOF Y=0 (DCT modes) | validator.zig SOF check; jpeg_markers.zig `dnlLines` | **Fixed 2026-11-21**: was FAIL 61; the decoders and validator now read the DNL, and pixels match the Y≠0 original on five fixtures | T.81 B.2.2/B.2.5: Y=0 is valid when a DNL follows the first scan |
| JPEG-LS LSE ID 2/3 mapping tables | jpegls.zig `parseLse` | Ignored; a palette image decodes to its indices, not its colors (*code-read*) | T.87 C.2.4.1.2-3, Annex D table mapping via Tdi |
| JPEG-LS LSE ID 4 | jpegls.zig `parseOversize` | **Fixed 2026-11-21**: was ignored, so CharLS files above 65535 in either dimension were FAIL 61; now decoded and validated (65536x1 and 1x65536 fixtures) | T.87 C.2.4.1.4 |
| JPEG-LS LSE marker | jpegls.zig `M_LSE` | **Fixed 2026-11-21**: the decoder looked for FF F2, so it never applied an LSE (T1-T3, RESET); T.87 and CharLS use FF F8. Oracle: T.87 Annex E t8nde0 (T1=T2=T3=9, RESET=31) | T.87 Table C.1 |
| JPEG-LS near-lossless k=0 correction | jpegls.zig regular mode (3 sites) | **Fixed 2026-11-21**: applied when NEAR>0 too; desynced t8nde3 | T.87 A.5.2; CharLS `get_error_correction(k \| near)` |
| JPEG-LS default thresholds | jpegls_codec.zig `setDefaultThresholds` | **Fixed 2026-11-21**: T2/T3 used a shared floor of 2, wrong for MAXVAL ≥ 128 above 8 bits (12-bit: 82/306, not 67/276); the MAXVAL < 128 branch put NEAR outside the floor. Every 12/16-bit JPEG-LS image with default parameters decoded wrong. Oracle: t16e0/t16e3, plus CharLS and FFmpeg formulas | T.87 C.2.4.1.1 |
| JPEG-LS LSE MAXVAL ≠ 2^P−1 | jpegls.zig `customMaxval` | Now NotImplemented. CharLS 3.0 derives RANGE/qbpp/LIMIT from P; FFmpeg derives them from the LSE MAXVAL. Needs the T.87 A.2.1 text or a conformant encoder to settle | T.87 A.2.1, C.2.4.1.1 |
| JPEG-LS point transform (Al) | jpegls.zig `parseSos` | Field ignored (*code-read*) | T.87 C.2.3; confirm whether nonzero Pt is permitted |
| JPEG-LS DNL | jpegls.zig | Segment skipped; Y=0 handling unverified (*code-read*) | T.87 C.2.5 |
| Differential SOF (5-7, 13-15) without DHP | validator.zig SOF branch | **Fixed 2026-11-21**: graded valid with no finding (confirmed by test); now FAIL 73 | T.81 J.1: differential frames occur only in hierarchical mode |
| Misplaced DNL (Y≠0, repeated, before or after a later scan) | validator.zig DNL segment | **Fixed 2026-11-21**: skipped silently; now 72, WARN or FAIL by validate's rule | T.81 B.2.5 |

## Unchecked (INFO "not checked" or decode `NotImplemented`)

| Mode / layout | Decode | Validate |
|---|---|---|
| Hierarchical (DHP, SOF5-7, SOF13-15, EXP) | Not implemented | INFO not checked (Annex J) |
| Lossless arithmetic (SOF11) | Not implemented ("no encoder produces it") | Codec check reports unsupported |
| Arithmetic 12-bit (SOF9/SOF10 P=12) | Not implemented | Unsupported |
| Lossless multiscan (Ns < Nf) | Not implemented | Not implemented |
| Lossless with H/V ≠ 1 | Not implemented | Syntax validated (single full-component scan) |
| Lossless DNL | Not implemented | Not implemented |
| Baseline/extended Nf=2 | Not implemented | Unsupported |
| Extended 12-bit Nf=4 | Not implemented | Unsupported |
| Progressive Nf ∉ {1,3} | Not implemented | Unsupported |
| JPEG-LS Nf ∉ {1,3} | Not implemented | No codec check at all |
| JPEG-LS ILV=0 with Nf>1 (one scan per component) | **Decoded 2026-11-21** (t8c0e0/3, test8_ilv_none_rm_7) | Checked |
| JPEG-LS restart intervals | **Decoded 2026-11-21** (mono, ILV 1, ILV 2; CharLS restart streams exact) | No codec check yet |
| JPEG-LS entropy (any) | Decoded | **Checked 2026-11-21**: codec check on; 120, 121, 122, 56, 57 emitted. The walker had treated FF + byte < 0x80 as a marker, so 28 of 29 CharLS test files (every conformance stream) were false FAILs |
| JPEG-LS subsampled components | Not implemented (t8sse0/3) | Codec not checked |

## Stale documentation found

- `jpegls_codec.zig` header said NEAR > 0 is stubbed; `tests/unit/decode.zig`
  decodes a NEAR=2 fixture within tolerance. Corrected with the DNL fix.

## Oracles available

- DNL (used for the fix): metamorphic. Rewrite a valid fixture's SOF to Y=0 and append a DNL
  after the first scan; pixels must equal the original's. libjpeg-turbo does
  not support DNL, so it cannot serve as the oracle.
- JPEG-LS mapping tables, oversize dimensions and point transform: no
  encoder in the closure writes them (CharLS 3.0 can write mapping tables;
  check its API before hand-building).
- Hierarchical and lossless arithmetic: no encoder in the closure.
- JPEG-LS: the declared charls source input carries the T.87 Annex E
  conformance streams with reference images (HP, BSD-3-Clause), HP-encoder
  files (banny-hp1..3, tulips hp-encoder) and restart-interval streams
  (test16_rm_5, test8_ilv_{none,line,sample}_rm_7, test8_ilv_sample_rm_300)
  under test/data. build.zig stages them for the decode tests. The restart
  streams are the missing oracle for JPEG-LS restart validation.
- Fixture drift: regenerating the committed 4x4 16-bit JPEG-LS fixtures with
  CharLS 3.0 gives different bytes (the 8-bit ones match); their origin
  encoder version is unrecorded.
