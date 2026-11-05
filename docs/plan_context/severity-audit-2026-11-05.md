# jpegz severity audit draft, 2026-11-05

Draft for validate and owner review under the 2026-11-05 rule (validate
TERMINOLOGY A2): FAIL is likely damage, WARN is a writer's spec violation,
KNOWN_DEFECT is an admitted producer pattern. Detection is unchanged. Nothing
here is implemented except the separately owner-decided JPEG XL row at the end.

## Evidence and method

- **jpegz build:** `82148c4` CLI, `jpegz --json`.
- **Damage campaigns:** corruption-reader 0.9.0 with profiles sniper, bolter, shotgun_variable and nuke, master `0x6a7065677a`, round 0.
  - **F** = 56 known-good test fixtures (the JPEG-LS fixtures this build does not call valid are excluded), 50 cases per profile, 11,200 cases.
  - **R** = 3 real photos (two baseline, one progressive, 239 KB to 959 KB), 100 cases per profile, 1,200 cases.
  - The fixtures are tiny (4x4 to 128x128), so header damage is over-represented in F. Real photos are mostly entropy data.
  - Each cell gives `all/sole`: the number of damaged cases carrying the row, then the number where it was the only non-INFO finding (the cases a reclassification would move).
- **Reader:** libjpeg-turbo 3.1.4 `djpeg`, on a minimal variant of a real fixture for each row checked. "fatal" means exit 1 with no image. "warns" means exit 2 with an image. "identical" means pixels equal to the unmodified fixture's.
- **Real-world corpus:** 805 JPEGs from one private local collection; aggregate counts only, no file leaves the machine. 738 are baseline and 67 progressive. 65 carry an EXIF Make (15 distinct makes), with 36 distinct Software values. Producer variety is moderate, so a zero here is weak evidence that no writer does it.
- **Test-suite corpus:** the 66 JPEG and JPEG-LS files in `tests/unit/fixtures`, including deliberately damaged ones.

**Current class** is the emitted severity, then the facade verdict from `classicFindingVerdict`. For example, "WARN→corrupt" means severity WARN, but the facade judges the file corrupt.

## T.81 / T.87 findings owned by jpegz

| Code, reason | Current | From damage? (F, R all/sole) | From a writer? | Decodes anyway? | Proposed | KNOWN_DEFECT | Corpus effect (real 805 / test 66) |
|---|---|---|---|---|---|---|---|
| 1 `missing_soi` | FAIL→corrupt | Yes, but standalone SOI damage is reported as 10 `unrecognized_container` instead (F 2824/2824, mostly nuke overwriting whole small fixtures; sniper 24) | No | No (djpeg: not a JPEG) | FAIL | none | 0 / 0 |
| 2 `missing_eoi` (segments complete, no EOI) | WARN→corrupt | Truncation; corruption-reader does not truncate, so F 0, R 0 | No producer evidence found | djpeg warns "Premature end"; pixels identical when only EOI is absent | FAIL (interrupted transfer) | none | 0 / 0 |
| 3 `truncated_stream`: segment extends past end | FAIL→corrupt | F 817/648, R 32/7 | No | No | FAIL (declared length) | none | 0 / 0 |
| 3: SOS entropy not terminated by a marker | FAIL→corrupt | F 26/26 (EOI bytes hit) | No producer evidence found | djpeg warns; identical when only EOI is lost | FAIL | none | 0 / 0 |
| 3: decoder ran out of data (`TruncatedStream`) | FAIL→corrupt | F 240/240 | No | Partially, with fill | FAIL | none | 0 / 1 (fuzz fixture) |
| 3: no SOS; ended before length or at marker prefix; EOI where restart intervals belong | FAIL→corrupt | F 10/0, 15/1, 3/0 | No | No | FAIL | none | 0 / 0 |
| 4 `bad_marker_length`: non-0xFF bytes between segments | FAIL→corrupt | F 1019/723, R 276/46: the most frequent damage reason | libjpeg's "extraneous bytes" warning; no producer found | djpeg warns "2 extraneous bytes before marker 0xc0"; identical | FAIL | none | 0 / 1 (JPEG-LS fixture, see notes) |
| 4: length < 2; sequential SOS length ≠ 6+2Ns; SOF too short | FAIL→corrupt | F 25/23, 19/4, 8/0; R 3/0 | No | No | FAIL (declared length) | none | 0 / 0 |
| 5 `unknown_marker`: reserved FF02..FFBF | WARN→indeterminate | F 321/40 (19 now indeterminate, 21 unsupported), R 242/0 | None known | No: djpeg fatal "Unsupported marker type 0x02" | **FAIL** (no specified decode; damage-produced) | none | 0 / 0 verdict changes (only 2 JPEG-LS fixtures, already corrupt) |
| 5: zero marker byte outside entropy | FAIL→corrupt | R 2/1 | No | No | FAIL | none | 0 / 0 |
| 5: INFO "codec variant beyond cleanroom scope" | INFO→unsupported | n/a | n/a | n/a | INFO (not a violation; the code name is a misnomer here) | none | 0 / 0 |
| 6 `duplicate_sof`: repeated SOF | WARN→valid, or unsupported | F 38/8, R 12/0 | None known | No: djpeg fatal "two SOF markers" | **FAIL**, except hierarchical streams (see notes) | none | 0 / 0 |
| 6: no SOF marker | FAIL→corrupt | F 31/4 | No | No | FAIL | none | 0 / 0 |
| 7 `insufficient_data` (recovered scan truncation) | WARN→corrupt | F 244/103, R 230/142 | No | djpeg warns and fills gray (the Preview.app case) | **FAIL** severity; verdict already corrupt | none | 0 / 0 |
| 8 `extraneous_bytes_before_marker` | WARN→valid | F 0, R 0: in `validate` the walker (row 4) and the end-of-scan check (row 51b) report these bytes first | Widely reported "N extraneous bytes before marker 0xd9" from webcam MJPEG encoders (public reports; not measured here) | djpeg warns; identical | WARN | none | 0 / 0 |
| 9 `entropy_fill_bytes` (0xFF fill before a marker) | WARN→valid | F 0, R 0 | Legal per T.81 B.1.1.2 | Yes; identical | **INFO** (not a violation) | none | 0 / 0 |
| 10 `unrecognized_container` | WARN→indeterminate | see row 1 | n/a | n/a | unchanged (no format claimed) | none | 0 / 0 |
| 50 `invalid_sof_precision` | FAIL→corrupt | F 64/19 | No | No: djpeg fatal "Unsupported JPEG data precision 9" | FAIL | none | 0 / 0 |
| 51 `huffman_table_corrupt`: decoder error buckets (BackendError, InvalidMarker, TruncatedStream) | FAIL→corrupt | F 1437/1352, R 119/119 | No | No, or garbage | FAIL | none | 0 / 1 (bogus DHT fixture) |
| 51b: invalid entropy or padding at end of scan | FAIL→corrupt | F 56/54, R 74/74 | Whole extra bytes after a complete final MCU are the writer pattern in row 8, but this reason does not separate them from invalid entropy | djpeg is silent on 2 appended zero bytes; identical | FAIL; WARN only for a narrower reason that isolates whole trailing bytes after valid padding (detection unchanged; may need a registry code) | none | 0 / 0 |
| 51: at restart boundary; progressive EOB run at restart | FAIL→corrupt | F 81/0 and 13/0, R 88/0 | No | Resync with loss | FAIL | none | 0 / 0 |
| 52 `quantization_table_corrupt`: Pq/Tq invalid | FAIL→corrupt | F 56/19 | No | not checked with djpeg | FAIL | none | 0 / 0 |
| 52: Qk = 0 | FAIL→corrupt | F 34/29 (a 1→0 bit flip in a quality-100 table) | None known | Decodes, but pixels differ from the original (16x16 check) | FAIL | none | 0 / 0 |
| 53 `arithmetic_table_corrupt` | FAIL→corrupt | F 47/22, R 2/0 | No | not checked with djpeg | FAIL | none | 0 / 0 |
| 54 `sof_component_count_invalid` | FAIL→corrupt | F 156 | No | No | FAIL (declared length) | none | 0 / 0 |
| 55 `sos_component_mismatch`: Cs undeclared / repeated / Ns out of range | FAIL→corrupt | F 223/137, 6/3, 9/0; R 4/0, 3/0 | No | No: djpeg fatal "Invalid component ID 1 in SOS" | FAIL | none | 0 / 0 |
| 56 `restart_marker_missing` | WARN→corrupt | F 101/0, R 88/0 | No | djpeg resyncs with loss | **FAIL** severity; verdict already corrupt | none | 0 / 0 |
| 57 `restart_marker_unexpected` (wrong RSTn; RST after final MCU) | WARN→corrupt, FAIL→corrupt | F 10/0 and 6/0, R 35/0 | No | Resync with loss | **FAIL** severity; verdict already corrupt | none | 0 / 0 |
| 58 `dct_coefficient_overflow` | FAIL→corrupt | F 2/2 | No | Garbage | FAIL | none | 0 / 1 (overflow fixture) |
| 59 `progressive_scan_invalid` | FAIL→corrupt | F 75/54, R 1/0 | No | No (libjpeg rejects a bad progression) | FAIL | none | 0 / 1 (fuzz fixture) |
| 60 `adobe_app14_conflicts_jfif` | WARN→valid | F 0, R 0 | Plausible: tools that write both APP0 and APP14 (not measured) | Yes (libjpeg honors APP14) | WARN | none | 0 / 0 |
| 61 `invalid_dimensions` | FAIL→corrupt | F 12/6 | No | No | FAIL | none | 0 / 0 |
| 62 `entropy_padding_not_ones` (mixed pad bits) | FAIL→corrupt | F 174/138, R 51/42 | None known (writers that pad with 0s are row 63) | djpeg ignores pad bits | FAIL | none | 0 / 0 |
| 63 `entropy_padding_zero_bits` | WARN→known_defect | F 50/26: damage that clears pad bits mimics the defect | Intel JPEG Library 1.51, Olympus firmware | Yes | KNOWN_DEFECT | all-zero 1..7 pad bits before a marker; known-defect treatment | 1 / 1 (unchanged) |
| 64 `sequential_scan_invalid` (Ss, Se, Ah, Al) | FAIL→corrupt | F 60/19, R 12/0 | libjpeg-turbo keeps a dedicated warning (JWRN_NOT_SEQUENTIAL), which suggests producers exist; none in our corpus | djpeg warns "Invalid SOS parameters for sequential JPEG"; identical | FAIL unless validate has producer evidence; WARN candidate | none | 0 / 0 |
| 65 `jfif_metadata_invalid` (units > 2) | FAIL→corrupt | F 42/26 (one bit flip of the units byte) | None found | Yes; identical | FAIL absent producer evidence; owner decision (metadata only) | none | 0 / 0 |
| 66 `sof_sampling_invalid` (single component) | FAIL→corrupt | F 7/0 | No | No: djpeg fatal "Bogus sampling factors" | FAIL | none | 0 / 0 |
| 67 `jfif_version_unchecked` (> 1.02) | WARN→indeterminate | F 99/66 (version bytes hit) | None known; no JFIF version after 1.02 exists | Yes | **WARN** (A2 deviation with no proven violation; damage that reaches it counts apart) | none | 0 / 0 |
| 100 `lossless_predictor_invalid` | FAIL→corrupt | F 24/19 | No | No | FAIL | none | 0 / 0 |
| 101 `lossless_pointtransform_invalid` | FAIL→corrupt | F 14/9 | No | No | FAIL | none | 0 / 0 |
| 120, 121 `jpegls_*` | not emitted | none | n/a | n/a | not applicable (reserved; no code path emits them) | none | 0 / 0 |
| 200..212 INFO observations | INFO | n/a | n/a | n/a | INFO; `trailing_data_after_eoi` is a common writer trailer | none | real: 1 trailing, 684 JFIF, 236 EXIF, 217 ICC, 198 XMP, 190 IRB |

## Proposed changes, in one place

1. **FAIL instead of indeterminate:** reserved markers FF02..FFBF (row 5). They are damage-produced, and libjpeg cannot decode them.
2. **FAIL instead of valid:** a repeated SOF outside a hierarchical stream (row 6).
3. **FAIL severity** for `insufficient_data`, `restart_marker_missing` and `restart_marker_unexpected`, so the label agrees with the verdict they already carry (rows 7, 56, 57).
4. **INFO instead of WARN:** legal 0xFF fill (row 9).
5. **WARN instead of indeterminate:** an unchecked future JFIF version (row 67).
6. **Owner decisions where the evidence is split:** rows 64 and 65, which damage produces and which decode to identical pixels, but where no producer was found. Row 51b would need a narrower reason before any WARN treatment.

Expected effect: no file in the real-world corpus or the test suite changes verdict. Among damaged cases, 40 F cases move from indeterminate or unsupported to corrupt (row 5), 8 move from unsupported to corrupt (row 6), and 66 move from indeterminate to warning class (row 67).

## Notes found during the audit

- **Hierarchical streams.** `classifyVariant` maps SOF5..7 and SOF13..15 to `.unknown`, which still counts as a SOF. A legal hierarchical stream (DHP, then several frames) would be reported as `duplicate_sof`. Row 6 must exempt streams with a DHP; `frameHeader().dhp_offset` now exposes one.
- **Multi-component sampling.** A bogus factor in a multi-component SOF currently yields `unsupported` with no finding: `sof_sampling_invalid` is scoped to one component. That is a detection gap, separate from severity.
- **JPEG-LS fixtures.** Two JPEG-LS fixtures (`jpegls_4x4_rgb16.jls`, `jpegls_4x4_rgb8_ilv1.jls`) are judged corrupt by the T.81 walker. This is the open PLAN item on the corruption-coverage JPEG-LS default, not a severity question.

## Mirrored and provider findings

- **JPEG 2000 (140-146, 207-208, 250-261):** classes come from jp2z's leaf severity. Their audit belongs to jp2z.
- **JPEG XL (180-197):** classes come from libjxlz; its audit is `doc/severity_audit_draft_20261105.md` (`1f995a90`).
  - **Changed today, on the owner's 12:14 decision:** 189 `jxl_nonzero_padding` and 193 `jxl_truncated_box_header` now carry FAIL whatever libjxlz's recoverability severity says. The controlled red was 3 unit tests plus the CLI assertion. The corpus effect is none on clean files; on damaged files these findings move from WARN to FAIL.
  - **Unchanged:** 197 keeps the provider's unresolved ICC assessment.

## Validate's ruling (2026-11-05, 13:14)

- **Approved:** the five proposed changes, implemented with controlled reds.
- **Held at FAIL** pending the owner: rows 64 and 65.
- **Next for row 51b:** split out the narrower reason "whole bytes after valid padding before EOI" and report its real-world count.
- **Separate detection items:** the multi-component sampling gap, and damaged-SOI identity.

### Row 64 provenance (bounded search)

There is a real producer.
- **Writer:** Go's `image/jpeg` encoder wrote `Ss=0, Se=0, Ah/Al=0` in every sequential SOS, where Se must be 63. It did this from Go 1.0 until August 2012.
- **Fix:** golang/go commit 5f7bec69 ("image/jpeg: send a correct Start Of Scan (SOS) header"), which fixed issue #3916, "Invalid SOS parameters for sequential JPEG", the libjpeg JWRN_NOT_SEQUENTIAL text. It was backported in 2015.
- **Signature:** the sequential header bytes `0x00 0x00 0x00` in place of `0x00 0x3f 0x00`.
- **Effect:** libjpeg-turbo warns, then decodes identical pixels.

Following validate's rule, this is a KNOWN_DEFECT registry candidate for exactly that signature, not a softer default for row 64. Every other sequential SOS field violation stays FAIL.
