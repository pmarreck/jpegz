# Finding codes

<!-- Generated from src/core/finding_provenance.zig by tools/gen_finding_codes.zig. Do not edit; run `zig build finding-codes`. -->

Every `FindingCode` jpegz can report, with its provenance. Numbers are
stable forever: the registry is append-only, and a value is never reused
or renumbered. The enum in `src/core/errors.zig` is the source of truth
for numbers and names; this table adds who owns each code and why its
number was assigned. A new code needs validate's approval first (the
coordinator approved codes before 2026-11-06).

- **Owner** is the project whose validator emits the condition. jp2z
  and libjxlz codes keep the leaf's own number in `leaf_code` as well.
- **Introduced** is the jpegz commit that added the value.

| Code | Name | Owner | Approval | Introduced |
|---:|---|---|---|---|
| 1 | `missing_soi` | jpegz | Assigned by jpegz before the shared registry | 6629e2b (2026-05-04) |
| 2 | `missing_eoi` | jpegz | Assigned by jpegz before the shared registry | 6629e2b (2026-05-04) |
| 3 | `truncated_stream` | jpegz | Assigned by jpegz before the shared registry | 6629e2b (2026-05-04) |
| 4 | `bad_marker_length` | jpegz | Assigned by jpegz before the shared registry | 6629e2b (2026-05-04) |
| 5 | `unknown_marker` | jpegz | Assigned by jpegz before the shared registry | 6629e2b (2026-05-04) |
| 6 | `duplicate_sof` | jpegz | Assigned by jpegz before the shared registry | 6629e2b (2026-05-04) |
| 7 | `insufficient_data` | jpegz | Assigned by jpegz before the shared registry | 3c19849 (2026-05-15) |
| 8 | `extraneous_bytes_before_marker` | jpegz | Assigned by jpegz before the shared registry | 3c19849 (2026-05-15) |
| 9 | `entropy_fill_bytes` | jpegz | Assigned by jpegz before the shared registry | d44b558 (2026-05-22) |
| 10 | `unrecognized_container` | jpegz | No approval record found | a94b102 (2026-08-10) |
| 50 | `invalid_sof_precision` | jpegz | Assigned by jpegz before the shared registry | 6629e2b (2026-05-04) |
| 51 | `huffman_table_corrupt` | jpegz | Assigned by jpegz before the shared registry | 6629e2b (2026-05-04) |
| 52 | `quantization_table_corrupt` | jpegz | Assigned by jpegz before the shared registry | 6629e2b (2026-05-04) |
| 53 | `arithmetic_table_corrupt` | jpegz | Assigned by jpegz before the shared registry | 6629e2b (2026-05-04) |
| 54 | `sof_component_count_invalid` | jpegz | Assigned by jpegz before the shared registry | 6629e2b (2026-05-04) |
| 55 | `sos_component_mismatch` | jpegz | Assigned by jpegz before the shared registry | 6629e2b (2026-05-04) |
| 56 | `restart_marker_missing` | jpegz | Assigned by jpegz before the shared registry | 6629e2b (2026-05-04) |
| 57 | `restart_marker_unexpected` | jpegz | Assigned by jpegz before the shared registry | 6629e2b (2026-05-04) |
| 58 | `dct_coefficient_overflow` | jpegz | Assigned by jpegz before the shared registry | 6629e2b (2026-05-04) |
| 59 | `progressive_scan_invalid` | jpegz | Assigned by jpegz before the shared registry | 6629e2b (2026-05-04) |
| 60 | `adobe_app14_conflicts_jfif` | jpegz | Assigned by jpegz before the shared registry | d44b558 (2026-05-22) |
| 61 | `invalid_dimensions` | jpegz | Assigned by jpegz before the shared registry | 9c8fd4b (2026-07-24) |
| 62 | `entropy_padding_not_ones` | jpegz | Coordinator approval, 2026-10-20 | 860654d (2026-10-20) |
| 63 | `entropy_padding_zero_bits` | jpegz | Coordinator approval, 2026-10-23 | 8fd246d (2026-10-23) |
| 64 | `sequential_scan_invalid` | jpegz | Coordinator approval, 2026-10-28 | d7f627a (2026-10-28) |
| 65 | `jfif_metadata_invalid` | jpegz | Coordinator approval, 2026-10-28 | 6b038ec (2026-10-28) |
| 66 | `sof_sampling_invalid` | jpegz | Coordinator approval, 2026-10-28 | faf0c92 (2026-10-28) |
| 67 | `jfif_version_unchecked` | jpegz | Coordinator approval, 2026-10-28 | a7ddd65 (2026-10-29) |
| 71 | `huffman_table_full_all_ones` | jpegz | validate approval, 2026-11-06 | this commit (2026-11-06) |
| 100 | `lossless_predictor_invalid` | jpegz | Assigned by jpegz before the shared registry | 6629e2b (2026-05-04) |
| 101 | `lossless_pointtransform_invalid` | jpegz | Assigned by jpegz before the shared registry | 6629e2b (2026-05-04) |
| 120 | `jpegls_invalid_run_mode` | jpegz | Assigned by jpegz before the shared registry | 6629e2b (2026-05-04) |
| 121 | `jpegls_context_table_invalid` | jpegz | Assigned by jpegz before the shared registry | 6629e2b (2026-05-04) |
| 140 | `jp2_invalid_signature` | jp2z | Assigned by jpegz before the shared registry | 6629e2b (2026-05-04) |
| 141 | `jp2_invalid_codestream` | jp2z | Assigned by jpegz before the shared registry | 6629e2b (2026-05-04) |
| 142 | `jp2_bad_progression_order` | jp2z | Assigned by jpegz before the shared registry | 6629e2b (2026-05-04) |
| 143 | `jp2_tile_decode_failed` | jp2z | Assigned by jpegz before the shared registry | 6629e2b (2026-05-04) |
| 144 | `jp2_codeblock_decode_failed` | jp2z | Assigned by jpegz before the shared registry | 6629e2b (2026-05-04) |
| 145 | `jp2_unsupported_marker_ignored` | jp2z | Assigned in jp2z's leaf registry | 84c3c6f (2026-08-02) |
| 146 | `jp2_invalid_siz` | jp2z | Assigned in jp2z's leaf registry | 84c3c6f (2026-08-02) |
| 180 | `jxl_invalid_signature` | libjxlz | Coordinator's JPEG XL band 180..199, reserved 2026-08-05 | fb72045 (2026-08-05) |
| 181 | `jxl_truncated` | libjxlz | Coordinator's JPEG XL band 180..199, reserved 2026-08-05 | fb72045 (2026-08-05) |
| 182 | `jxl_malformed` | libjxlz | Coordinator's JPEG XL band 180..199, reserved 2026-08-05 | fb72045 (2026-08-05) |
| 183 | `jxl_unsupported_feature` | libjxlz | Coordinator's JPEG XL band 180..199, reserved 2026-08-05 | fb72045 (2026-08-05) |
| 184 | `jxl_resource_limit` | libjxlz | Coordinator's JPEG XL band 180..199, reserved 2026-08-05 | fb72045 (2026-08-05) |
| 185 | `jxl_out_of_memory` | libjxlz | Coordinator's JPEG XL band 180..199, reserved 2026-08-05 | fb72045 (2026-08-05) |
| 186 | `jxl_invalid_argument` | libjxlz | Coordinator's JPEG XL band 180..199, reserved 2026-08-05 | fb72045 (2026-08-05) |
| 187 | `jxl_unclassified_decoder_error` | libjxlz | Coordinator's JPEG XL band 180..199, reserved 2026-08-05 | fb72045 (2026-08-05) |
| 188 | `jxl_validator_unavailable` | jpegz | Coordinator's JPEG XL band 180..199, reserved 2026-08-05 | 98824e7 (2026-08-10) |
| 189 | `jxl_nonzero_padding` | libjxlz | Coordinator's JPEG XL band 180..199, reserved 2026-08-05 | 491bebc (2026-09-17) |
| 190 | `jxl_invalid_context_map` | libjxlz | Coordinator's JPEG XL band 180..199, reserved 2026-08-05 | 491bebc (2026-09-17) |
| 191 | `jxl_invalid_ma_tree` | libjxlz | Coordinator's JPEG XL band 180..199, reserved 2026-08-05 | 491bebc (2026-09-17) |
| 192 | `jxl_invalid_ans_state` | libjxlz | Coordinator's JPEG XL band 180..199, reserved 2026-08-05 | 491bebc (2026-09-17) |
| 193 | `jxl_truncated_box_header` | libjxlz | Coordinator's JPEG XL band 180..199, reserved 2026-08-05 | 491bebc (2026-09-17) |
| 194 | `jxl_invalid_ac_nonzero_count` | libjxlz | Coordinator's JPEG XL band 180..199, reserved 2026-08-05 | 491bebc (2026-09-17) |
| 195 | `jxl_invalid_hybrid_uint_config` | libjxlz | Coordinator's JPEG XL band 180..199, reserved 2026-08-05 | 8a92dbd (2026-09-18) |
| 196 | `jxl_invalid_histogram` | libjxlz | Coordinator's JPEG XL band 180..199, reserved 2026-08-05 | 8a92dbd (2026-09-18) |
| 197 | `jxl_invalid_icc_symbol` | libjxlz | Coordinator approval, 2026-10-29 | e8ef262 (2026-10-29) |
| 200 | `arithmetic_coding_used` | jpegz | Assigned by jpegz before the shared registry | 6629e2b (2026-05-04) |
| 201 | `twelve_bit_precision` | jpegz | Assigned by jpegz before the shared registry | 6629e2b (2026-05-04) |
| 202 | `sixteen_bit_lossless` | jpegz | Assigned by jpegz before the shared registry | 6629e2b (2026-05-04) |
| 203 | `progressive_scan_count` | jpegz | Assigned by jpegz before the shared registry | 6629e2b (2026-05-04) |
| 204 | `embedded_thumbnail_present` | jpegz | Assigned by jpegz before the shared registry | 6629e2b (2026-05-04) |
| 205 | `exif_metadata_present` | jpegz | Assigned by jpegz before the shared registry | 6629e2b (2026-05-04) |
| 206 | `icc_profile_present` | jpegz | Assigned by jpegz before the shared registry | 6629e2b (2026-05-04) |
| 207 | `jp2_uses_9x7_wavelet` | jp2z | Assigned by jpegz before the shared registry | 6629e2b (2026-05-04) |
| 208 | `jp2_uses_5x3_wavelet` | jp2z | Assigned by jpegz before the shared registry | 6629e2b (2026-05-04) |
| 209 | `jfif_metadata_present` | jpegz | Assigned by jpegz before the shared registry | c48fd66 (2026-05-06) |
| 210 | `xmp_metadata_present` | jpegz | Assigned by jpegz before the shared registry | c48fd66 (2026-05-06) |
| 211 | `photoshop_irb_present` | jpegz | Assigned by jpegz before the shared registry | c48fd66 (2026-05-06) |
| 212 | `trailing_data_after_eoi` | jpegz | Assigned by jpegz before the shared registry | c48fd66 (2026-05-06) |
| 250 | `jp2_packets_under_read` | jp2z | Assigned in jp2z's leaf registry | 84c3c6f (2026-08-02) |
| 251 | `entropy_over_read` | jp2z | Assigned in jp2z's leaf registry | 84c3c6f (2026-08-02) |
| 252 | `entropy_under_read` | jp2z | Assigned in jp2z's leaf registry | 84c3c6f (2026-08-02) |
| 253 | `coding_pass_overflow` | jp2z | Assigned in jp2z's leaf registry | 84c3c6f (2026-08-02) |
| 254 | `jp2_packets_walked_to_end` | jp2z | Assigned in jp2z's leaf registry | 84c3c6f (2026-08-02) |
| 255 | `zero_bitplane_overflow` | jp2z | Assigned in jp2z's leaf registry | 82111d7 (2026-09-19) |
| 256 | `packed_headers_mismatch` | jp2z | Assigned in jp2z's leaf registry | 82111d7 (2026-09-19) |
| 257 | `jp2_trailing_bytes` | jp2z | Assigned in jp2z's leaf registry | 82111d7 (2026-09-19) |
| 258 | `segmentation_symbol_mismatch` | jp2z | Assigned in jp2z's leaf registry | 82111d7 (2026-09-19) |
| 259 | `profile_violation` | jp2z | Assigned in jp2z's leaf registry | 82111d7 (2026-09-19) |
| 260 | `reversible_exponent_mismatch` | jp2z | Assigned in jp2z's leaf registry | 82111d7 (2026-09-19) |
| 261 | `cblk_contribution_ends_ff` | jp2z | Coordinator approval, 2026-10-28 | 446274f (2026-10-28) |
