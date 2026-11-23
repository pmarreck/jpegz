# Producer pixel parity (2026-11-23)

`jpegz.decode` compared sample by sample with libjpeg-turbo 3.2.1 (the
build-time oracle, `internal.wrapperDecode`) on files written by the
producers themselves, at commit 3daedfd.

| Set | Writer | Files | Identical | Differ | Errors |
|---|---|---|---|---|---|
| Arithmetic producer sweep: sequential and progressive, 8- and 12-bit, sampling and restart variants | libjpeg-turbo 3.2.1 and IJG libjpeg 10 | 2,016 | 2,016 | 0 | 0 |
| Extreme-contrast arithmetic set (full-scale DC and AC steps) | libjpeg-turbo 3.2.1 and IJG libjpeg 10 | 288 | 288 | 0 | 0 |
| Huffman probes: baseline, progressive, 12-bit, 4:2:2, 4:4:0 and lossless, with and without restarts | libjpeg-turbo 3.2.1 | 40 | 40 | 0 | 0 |

Six lossless probes that `cjpeg` refused to write (empty outputs) are
excluded. The same files all validate as valid. The checker is a local
batch tool (`zig build pixel-diff`, built from an untracked scratch
source); this note records the result, not the tool.

## Huffman producer matrix

A second sweep targets the geometry of PLAN's coverage item: partial edge
MCUs, noninterleaved scans and restart cadence. Sources are eight
deterministic PPMs: 1x1, 7x5, 8x8, 16x16, 17x9, 33x31, 64x48 and 100x75,
a gradient plus LCG noise with seed 12345. Every combination of the
following was written:
- **Restarts:** none, `-restart 1B`, `3B` and `1` (one MCU row).
- **Sampling:** 1x1, 2x1, 2x2, 1x2, 4x1 and grayscale.
- **Modes, with both producers:** baseline, progressive, and
  noninterleaved multi-scan sequential (scan script `0; 1; 2;`, one
  component per scan).
- **Modes, libjpeg-turbo only:** 12-bit baseline and 12-bit progressive.
- **Lossless, libjpeg-turbo only:** predictors 1 to 7, point transforms 0
  and 3, RGB and grayscale.

| Set | Files | Valid | Identical pixels |
|---|---|---|---|
| DCT and lossless matrix, libjpeg-turbo 3.2.1 and IJG libjpeg 10 | 1,976 | 1,976 | 1,976 |
| Lossless precision matrix, libjpeg-turbo 3.2.1: precisions 2, 4, 7, 8, 10, 12, 15 and 16, predictors 1, 4 and 7, Pt 0 and 1, RGB and gray, no restart or one row, four sizes | 768 | 768 | 768 (after the fix below) |

- **Refusals:** libjpeg-turbo refused 392 lossless combinations with
  block restarts. A lossless restart interval must be a whole number of
  MCU rows, and cjpeg enforces it.
- **Defect found:** before the fix, four 15-bit predictor-4 files
  validated but did not decode. The decoder accepted difference category
  16 only at 16-bit precision. T.81 takes differences modulo 2^16 at
  every precision, and predictor 4 can leave the P-bit range, so a valid
  15-bit file can code the difference 32768. Fixed and pinned by a
  hand-built 2x2 test.
