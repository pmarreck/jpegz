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
so a decoder is checked without a reference decoder.

## LSE MAXVAL below 2^P − 1 (T.87 A.2.1)

T.87 A.2.1 derives RANGE, qbpp, bpp and LIMIT from the MAXVAL in force.
CharLS 3.0 codes an LSE MAXVAL below 2^P − 1 with those parameters taken
from 2^P − 1 instead. jpegz decodes such scans both ways
(`decodeScanChecked`), so these fixtures cover each outcome.

- **CharLS-only.** `jpegls_16x16_gray8_maxval200.jls` (stock CharLS)
  decodes cleanly only under CharLS's coding.
- **A.2.1-only.** The 32 × 32 files below (raw sources beside them) come
  from a scratch generator, 32 × 32 with one component and MAXVAL in the
  LSE ID 1 (T1–T3 and RESET as CharLS writes them):

  | File | P | MAXVAL | NEAR | Samples | Encoder |
  |---|---|---|---|---|---|
  | `jpegls_32x32_gray8_maxval63.jls` | 8 | 63 | 0 | LCG `r = r·1103515245 + 12345`, seed `0x6a7065 ^ MAXVAL ^ NEAR<<20`, `v = (r >> 8) % (MAXVAL+1)` | spec-mode CharLS |
  | `jpegls_32x32_gray12_maxval1023.jls` | 12 | 1023 | 0 | `((x·37 + y·91) ^ (x·y)) % (MAXVAL+1)` | spec-mode CharLS |
  | `jpegls_32x32_gray8_maxval63_near1.jls` | 8 | 63 | 1 | `(x + y)·MAXVAL / 62` | stock CharLS; byte-identical to the spec-mode output |

  "Spec-mode CharLS" is CharLS 3.0.0 with `src/make_scan_codec.cpp` rebuilt
  with `-DDISABLE_SPECIALIZATIONS` and a force-included header that includes
  `jpegls_algorithm.hpp` and then defines
  `calculate_maximum_bit_sample_value(b)` as
  `(pc_parameters.maximum_sample_value)`. Its traits then follow A.2.1. That
  holds only for MAXVAL = 2^k − 1, because CharLS clamps with a bit mask.
  FFmpeg 9.0.1, an independent A.2.1 decoder, reproduces each source: exactly
  at NEAR 0, within NEAR otherwise.
- **Both.** The NEAR 1 file decodes cleanly under both codings.

The ITU-T T.87 Annex E conformance streams and CharLS's restart streams used
by `tests/unit/decode.zig` are not copied here. `build.zig` stages them from
the declared charls source input (`test/data`, HP and Team CharLS,
BSD-3-Clause per CharLS's REUSE.toml).

The older 4×4 fixtures (`jpegls_4x4_*`, `jpegls_8x8_gray8_near2*`) predate
this note. Regenerating the 8-bit ones with CharLS 3.0.0 reproduces them byte
for byte; the 16-bit ones differ, and their original encoder version is
unrecorded.

## MAXVAL oracle sets

`jpegls_maxval_charls30.jlspack` holds 144 streams from stock CharLS 3.0.0.
`jpegls_maxval_specmode.jlspack` holds 72 streams from spec-mode CharLS,
with MAXVAL 2^k − 1 only. Both come from
`tools/jpegls-maxval-corpus/maxval_corpus.c`. Each stream is 32 × 32 with
one component; its name `p{P}_m{MAXVAL}_n{NEAR}_{content}` gives the
parameters and one of the four content formulas in that file. The tests
regenerate the sources from those formulas.

A pack is `JLSCORP1` followed by, for each stream sorted by name:

- a u8 name length and the name;
- a little-endian u32 payload length and the stream.

To rebuild, from the repository root inside `nix develop`, with `R` the
charls source path and `O` the CharLS 3.0.0 library objects (every
`src/*.cpp` compiled with `zig c++ -std=c++17 -fexceptions
-DCHARLS_STATIC -I$R/include -I$R/src -c`):

```sh
zig cc -DCHARLS_STATIC -I$R/include -c tools/jpegls-maxval-corpus/maxval_corpus.c -o gen.o
zig c++ -o stock gen.o $O                     # stock CharLS
zig c++ -std=c++17 -fexceptions -DCHARLS_STATIC -DDISABLE_SPECIALIZATIONS \
    -I$R/include -I$R/src -include tools/jpegls-maxval-corpus/spec_shim.h \
    -c $R/src/make_scan_codec.cpp -o spec_codec.o
zig c++ -o spec gen.o $O_without_make_scan_codec spec_codec.o
./stock OUT_STOCK && ./spec OUT_SPEC pow2
```

The packs and their verdicts are reported in
`docs/plan_context/jpegls-t87-rulings-2026-11-22.md`.
