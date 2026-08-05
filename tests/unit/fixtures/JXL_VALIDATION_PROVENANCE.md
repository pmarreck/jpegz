# JPEG XL validation fixture provenance

These three fixtures were copied without modification from the labeled-good
corpus at exact `libjxlz` commit
`5e8f9d68152ae8a70cb823061f4b6c733eb09166`:

| Local fixture | libjxlz source | SHA-256 | Expected strict result |
|---|---|---|---|
| `jxl_delta_palette_valid.jxl` | `tests/corpus/labeled/good/delta_palette.jxl` | `00e24cc453cdf84897d62b0aafc7a9f7024205bbce1922e99d7ad0003759ae7c` | valid |
| `jxl_patches_lossless_unsupported.jxl` | `tests/corpus/labeled/good/patches_lossless.jxl` | `2a47b6766264ac6243a43bbb85684688717591bb3bd9b4c2db56226192418b4e` | unsupported |
| `jxl_bicycles_indeterminate.jxl` | `tests/corpus/labeled/good/bicycles.jxl` | `8ef03ccccb45bdb5f3d37c9a4c392f745e3e4ad7f4ffc2cbc1e1ba68487a75a6` | indeterminate |

The latter two are valid files whose current leaf implementation cannot fully
validate. They are controls against the dangerous promotion of unsupported or
indeterminate input to valid or corrupt.
