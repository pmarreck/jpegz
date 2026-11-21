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
| JPEG-LS LSE ID 4 | jpegls.zig `parseLse` | Ignored, and an inline test calls ID 4 a mapping table. CharLS 3.0 defines ID 4 as the oversize-image-dimension record (C.2.4.1.4: Wxy, Ye, Xe) and its encoder writes it, with SOF X=Y=0, whenever a dimension exceeds 65535, so such files are FAIL 61 today | T.87 C.2.4.1.4 |
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
| JPEG-LS ILV=0 with Nf>1 (one scan per component) | Not implemented | No codec check at all |
| JPEG-LS restart intervals | DRI skipped | No codec check; see the PLAN item on the missing restart oracle |
| JPEG-LS entropy (any) | Decoded | `shouldRunCodecCheck` excludes `.jpegls`, so findings 46/47 are dormant |

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
