# RGB-signaled fixtures

Three-component JPEGs whose samples are already R, G, B, written on 2026-11-06
by libjpeg-turbo 3.2.1 `cjpeg -rgb -quality 100`. cjpeg writes Adobe APP14
with ColorTransform 0 and component IDs 'R','G','B', and no JFIF APP0. `djpeg
-pnm` returns every source sample exactly, so the source formula is the oracle.

The source images are 8x8 PPMs:
- 12-bit (maxval 4095): sample (x, y, c) = 256x + 128y + 512c + 100.
- 8-bit: sample (x, y, c) = (16x + 8y + 32c + 10) mod 256.

| Fixture | cjpeg options | SHA-256 |
|---|---|---|
| `rgb_8x8_p12_baseline.jpg` | `-precision 12 -quality 100 -rgb` | `9ee8703e668497a0ca8a4fec37ed36ad6e4870076b9813d2029a35ab82aa1f6f` |
| `rgb_8x8_p12_progressive.jpg` | `-precision 12 -quality 100 -rgb -progressive` | `8bbe1c69a0b518d0a5f3aba93a2a731d5bcc709bb18a07503c9844a7fd449c98` |
| `rgb_8x8_p8_progressive.jpg` | `-quality 100 -rgb -progressive` | `cc9583b2d57ed840bb190c937ed200df9d96ce08334fede7eefa6d80e2b0f9b3` |
| `rgb_8x8_p8_arith_progressive.jpg` | `-quality 100 -rgb -progressive -arithmetic` | `c3640138c5768e1b34049a7f49ffe153bf68d55ecf1617cbb38bfe99e8454b38` |
| `rgb_8x8_p8_baseline.jpg` | `-quality 100 -rgb` | `770156ed57459a336a9fe8d979dc945beccfd264f9827737a007cf3f5ca2dc57` |

`rgb_8x8_p12_baseline.jpg` reproduces tiffz's bug report: the same command and source
image (tiffz used libjpeg-turbo 3.1.4), also 218 bytes; bytes not compared.
The tests also strip APP14 (IDs only, still RGB) and replace it
with a JFIF APP0 (JFIF wins: YCbCr), following libjpeg-turbo's precedence.
