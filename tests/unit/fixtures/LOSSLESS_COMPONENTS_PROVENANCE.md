# Multi-component lossless fixtures

Two- and four-component lossless JPEG (SOF3) frames, the layout of a DNG CFA
tile (one component for each CFA color in a row pair). They were written on
2026-11-06 by `tools/gen-lossless-components.c` against libjpeg-turbo 3.2.1
(`jpeg_enable_lossless`, `JCS_UNKNOWN`, sampling 1x1, point transform 0).

Sample (x, y, c) = (37x + 101y + 53c + 7xy) mod 2^precision, so a test
recomputes every expected sample: an exact lossless decode reproduces them.

| Fixture | Components | Precision | Size | Predictor | Restart interval | SHA-256 |
|---|---:|---:|---|---:|---:|---|
| `lossless_6x5_2comp_p8_pred1.jpg` | 2 | 8 | 6x5 | 1 | 0 | `582071c74fcb809e104f2afeba2bfc5bf0960da3a835ad914980b1c4e5dc5094` |
| `lossless_8x6_2comp_p14_pred4.jpg` | 2 | 14 | 8x6 | 4 | 0 | `2aed70a17267d16927b3d5305b1d42e6bc99deb82ca6fa89d8ace2ed95bb78f1` |
| `lossless_9x7_2comp_p16_pred6_dri9.jpg` | 2 | 16 | 9x7 | 6 | 9 | `de5863ea9c4add64a7dfbdbe1203dbe07cccd352357ab5f5479a79d0d594b3d5` |
| `lossless_5x4_4comp_p12_pred7.jpg` | 4 | 12 | 5x4 | 7 | 0 | `c2a3a13f1c799c37aa7f00ac870fa72854bef632c543ae32b5e130a18cc69067` |

libjpeg-turbo requires a lossless restart interval to be a multiple of the
MCUs per row, so the restart fixture restarts every row.
