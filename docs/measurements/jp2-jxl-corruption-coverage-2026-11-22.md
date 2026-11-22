# JPEG 2000 and JPEG XL corruption coverage (2026-11-22)

jpegz at 3ddf9e4, corruption-reader 0.7 consumer CLI, master `0x6a7065677a`,
100 rounds per profile, `--jobs 4`. "Corrupt" counts jpegz's `corrupt`
verdict on bytes that corruption-reader changed. It is an observed rejection
rate, not proof that each mutation is invalid. Intervals are Wilson 95%
over judged cases.

Fixtures are the known-good JPEG 2000 and JPEG XL files in
`tests/unit/fixtures`. `jp2_8x8_yuv420_asym.jp2` is excluded: it is
corrupt by design, since a test uses it for an inconsistent container depth.
The pristine gate refused it. `jp2_8x8_rgb.jp2` and
`jxl_delta_palette_valid.jxl` belong to the default campaign
(`docs/measurements/jpegls-corruption-coverage-2026-11-21.md`).

```sh
JPEGZ=<nix build .> ./corruption-coverage --rounds 100 --jobs 4 <fixtures...>
```

| Fixture | sniper | bolter | shotgun_variable |
|---|---|---|---|
| jp2_1x1_3_components.j2k | 86.0% [77.9, 91.5] | 82.0% [73.3, 88.3] | 98.0% [93.0, 99.4] |
| jp2_8x8_lossless_5x3.jp2 | 56.0% [46.2, 65.3] | 53.0% [43.3, 62.5] | 92.0% [85.0, 95.9] |
| jp2_8x8_lossy_9x7.jp2 | 57.0% [47.2, 66.3] | 60.0% [50.2, 69.1] | 90.0% [82.6, 94.5] |
| jp2_8x8_subsampled.jp2 | 47.0% [37.5, 56.7] | 60.0% [50.2, 69.1] | 80.0% [71.1, 86.7] |
| jxl_lossless_9x7_gray12.jxl | 39.0% [30.0, 48.8] | 43.0% [33.7, 52.8] | 45.0% [35.6, 54.8] |
| jxl_lossless_9x7_gray8.jxl | 28.0% [20.1, 37.5] | 38.0% [29.1, 47.8] | 58.0% [48.2, 67.2] |
| jxl_lossless_9x7_rgb16.jxl | 56.0% [46.2, 65.3] | 77.0% [67.8, 84.2] | 89.0% [81.4, 93.7] |
| jxl_lossless_9x7_rgb8.jxl | 64.0% [54.2, 72.7] | 82.0% [73.3, 88.3] | 95.0% [88.8, 97.8] |
| jxl_lossless_9x7_rgba8.jxl | 69.0% [59.4, 77.2] | 94.0% [87.5, 97.2] | 97.0% [91.5, 99.0] |

Over all 3,600 cases: no crash, timeout, I/O or harness outcome.

- **nuke:** a nuke round replaces the whole of these small files, so all of
  its rounds are `indeterminate` (an unrecognized container). Over the other
  three profiles, 1,835 of 2,700 are corrupt.
- **Lossless grayscale JPEG XL** has the lowest rates. gray8 is 28% for
  sniper and 58% for shotgun_variable; gray12 is 39% and 45%.
  - Ten sniper and ten shotgun_variable survivors of the gray8 file were
    replayed from their seeds. Every one decodes cleanly with libjxl 0.12.0's
    reference decoder (`djxl`).
  - So jpegz agrees with the reference decoder on those cases. The
    mutations stay decodable JPEG XL, and modular entropy coding has no
    redundancy to catch them.
- **JPEG 2000** detection runs 47–60% for single-byte profiles and 80–98% for
  shotgun_variable. The three-component codestream (`.j2k`, no JP2 boxes)
  reaches 82–98%, because most of its bytes are header.
