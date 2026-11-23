# Huffman-coded restart fixtures

A progressive Huffman JPEG (T.81 Annex G) with a restart interval of one MCU,
written on 2026-11-22 by libjpeg-turbo 3.2.1 `cjpeg -progressive -restart 1B`
at the default quality. Rerunning the same command reproduces it byte for
byte. Each restart interval is one MCU (one block in a single-component
scan), so the file has many consecutive RSTn markers. `djpeg` decodes it
without warnings.

Source: the 32x32 binary PPM (maxval 255) of ARITH_RESTART_PROVENANCE.md,
sample (x, y) = (8x mod 256, 8y mod 256, 3xy mod 256).

| Fixture | Extra cjpeg options | Restart intervals | Bytes | SHA-256 |
|---|---|---|---|---|
| `huffman_restart_32x32_rgb420_progressive_1b.jpg` | `-progressive` | 4 per interleaved DC scan, 16 or 4 per component AC scan | 991 | `b2399463e7064420028e64a48b0f0e505c0076dfdea87da44fc3c4eb117991f1` |
