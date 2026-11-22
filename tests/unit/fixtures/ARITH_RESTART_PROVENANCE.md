# Arithmetic-coded restart fixtures

Arithmetic-coded JPEGs (T.81 Annex D) with a restart interval of one MCU,
written on 2026-11-22 by libjpeg-turbo 3.2.1 `cjpeg -arithmetic -restart 1B`
at the default quality. Each restart interval is one MCU, so these files have
many consecutive RSTn markers.
`djpeg` decodes all three without warnings. The tests compare jpegz's
coefficients and pixels with libjpeg-turbo's (the build-time oracle).

Source: a 32x32 binary PPM (maxval 255) with sample (x, y) =
(8x mod 256, 8y mod 256, 3xy mod 256).

| Fixture | Extra cjpeg options | Restart intervals | Bytes | SHA-256 |
|---|---|---|---|---|
| `arith_restart_32x32_gray_1b.jpg` | `-grayscale` | 16 | 389 | `547b9ae37ed883d9b22d8679826db33e088904874362ba6741de378750d791dc` |
| `arith_restart_32x32_rgb420_1b.jpg` | (none; 4:2:0) | 4 | 501 | `ef2ce1a0fac662d6780db9034aca83eefcf281e4d9b09f34840ea589afb45664` |
| `arith_restart_32x32_rgb420_progressive_1b.jpg` | `-progressive` | 4 per interleaved DC scan, 16 or 4 per component AC scan | 812 | `fd24b31515d199f1c81edf31136922115025d2822ab579615b4239a8aafade64` |
