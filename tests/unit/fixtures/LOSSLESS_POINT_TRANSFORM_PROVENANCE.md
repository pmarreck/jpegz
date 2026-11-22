# Lossless point-transform fixtures

Lossless JPEGs (SOF3) with a point transform Pt > 0, written on 2026-11-22 by
libjpeg-turbo 3.2.1 `cjpeg -lossless PSV,Pt`. T.81 A.4: the encoder divides
each input sample by 2^Pt, and "the output of the decoder is rescaled by
multiplying by 2^Pt". So decoding must return exactly `(source >> Pt) << Pt`
for every sample. The test uses that formula as its oracle, and `djpeg -pnm`
output also matches it for all three files.

Sources are 16x16 binary PNM files:
- 8-bit RGB (maxval 255): sample (x, y, c) = (16x + 8y + 32c + 10) mod 256.
- 12-bit gray (maxval 4095): sample (x, y) = (256x + 16y + 7) mod 4096.
- 16-bit gray (maxval 65535): sample (x, y) = (4096x + 256y + 1234) mod 65536.

| Fixture | cjpeg options | Bytes | SHA-256 |
|---|---|---|---|
| `lossless_16x16_rgb_p8_pt2_sel7_rst1.jpg` | `-lossless 7,2 -restart 1` | 549 | `400ab9f3354bac5b4685b187ffc60b3466a4b620bc66abddf2512cc1bdf9e616` |
| `lossless_16x16_gray_p12_pt3_sel1.jpg` | `-precision 12 -lossless 1,3` | 288 | `04cdb76bddcaa19ea99177d43e332455d45c9d70f88562955a2c3546f00ba41f` |
| `lossless_16x16_gray_p16_pt4_sel4.jpg` | `-precision 16 -lossless 4,4` | 140 | `aaf69828b36434ae78ba2f2cc40769008dd332ef1571ebe6d29da006b4570c07` |
