# JPEG-LS fixture provenance

Generated with the CharLS 3.0.0 encoder that `flake.nix` pins as `charlsSrc`,
compiled from that source with `zig c++` (`-std=c++17 -fexceptions`). The
generator is a local scratch program; everything needed to rebuild these
files is recorded here. Each call is
`charls_jpegls_encoder_encode_from_buffer` with 8-bit samples, one
component, interleave mode none and NEAR 0, unless stated otherwise.

| File | Size | Samples | Encoder settings |
|---|---|---|---|
| `jpegls_65536x1_gray8.jls` | 65536 × 1 | `v[i] = i >> 8` (i = 0..65535, raster order) | defaults; CharLS writes SOF55 X = Y = 0 and an LSE ID 4 (T.87 C.2.4.1.4) with Wxy = 4 |
| `jpegls_1x65536_gray8.jls` | 1 × 65536 | `v[i] = i >> 8` | as above |
| `jpegls_16x16_gray8_maxval200.jls` | 16 × 16 | `v[y*16+x] = ((x*37 + y*91) ^ (x*y)) % 201` | `charls_jpegls_encoder_set_preset_coding_parameters` with MAXVAL 200, T1 2, T2 5, T3 9, RESET 16 (LSE ID 1) |
| `jpegls_16x16_gray8_mapping.jls` | 16 × 16 | as above | `charls_jpegls_encoder_write_mapping_table(1, entry size 1, entries 255 − i)` and `set_mapping_table_id(0, 1)`: an LSE ID 2 and SOS Tdi = 1 |

The oversize files test dimensions only: their samples follow the formula,
so a decoder is checked without a reference decoder. The MAXVAL 200 file is
not a pixel oracle: CharLS 3.0 derives RANGE from the bit depth while FFmpeg
derives it from the LSE MAXVAL, so jpegz refuses such scans
(`NotImplemented`) until T.87 A.2.1 settles it.

The ITU-T T.87 Annex E conformance streams and CharLS's restart streams used
by `tests/unit/decode.zig` are not copied here. `build.zig` stages them from
the declared charls source input (`test/data`, HP and Team CharLS,
BSD-3-Clause per CharLS's REUSE.toml).

The older 4×4 fixtures (`jpegls_4x4_*`, `jpegls_8x8_gray8_near2*`) predate
this note. Regenerating the 8-bit ones with CharLS 3.0.0 reproduces them byte
for byte; the 16-bit ones differ, and their original encoder version is
unrecorded.
