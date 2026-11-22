# JPEG-LS corruption coverage (2026-11-21)

jpegz at 2243a84 (JPEG-LS codec check since 32d2501), corruption-reader 0.7
consumer CLI, master `0x6a7065677a`, 100 rounds per profile, `--jobs 4`.
Corrupt counts the `corrupt` verdict on bytes corruption-reader changed: an
observed rejection rate, not proof that each mutation is invalid. Wilson 95%
intervals over judged cases.

## Default four-fixture campaign

`JPEGZ=<nix build .> ./corruption-coverage --rounds 100 --jobs 4`

All four default fixtures pass the pristine gate. Before 32d2501 the JPEG-LS
control (`jpegls_4x4_gray8.jls`) was `indeterminate`, so the campaign could
not run. Before abdf10a the stats tool misread exit 5 as a harness failure.

| Fixture | sniper | bolter | shotgun_variable |
|---|---|---|---|
| jpegls_4x4_gray8.jls (48 bytes) | 37% | 49% | 89% |

Overall, 1,600 judged: 54.2% [51.7, 56.6]. nuke replaces the whole of a
file smaller than its 4096-byte window, so its rows mostly measure
container recognition.

## T.87 conformance and restart streams

Fixtures are read in place from the charls source input (`test/data`):

```sh
JPEGZ=<nix build .> ./corruption-coverage --rounds 100 --jobs 4 \
  <charls>/test/data/conformance/t8nde0.jls <charls>/test/data/conformance/t16e0.jls \
  <charls>/test/data/conformance/t8c1e0.jls <charls>/test/data/test16_rm_5.jls
```

| Stream | sniper | bolter | shotgun_variable | nuke |
|---|---|---|---|---|
| t8nde0 (8-bit, LSE thresholds) | 88% [80.2, 93.0] | 99% | 99% | 100% |
| t16e0 (12-bit) | 80% [71.1, 86.7] | 99% | 99% | 100% |
| t8c1e0 (RGB, line interleaved) | 91% [83.8, 95.2] | 100% | 100% | 100% |
| test16_rm_5 (12-bit, restart every 5 lines) | 60% [50.2, 69.1] | 86% | 87% | 100% |

Overall, 1,600 judged: 93.0% [91.6, 94.1]. No crash, timeout, I/O or
harness failure.

## Survivors

All 112 survivors were replayed from their seeds and compared with the
source. Every one changes entropy data; none touches a header. Most are
inherent: JPEG-LS entropy data has no redundancy, so a flip that still
forms valid codes decodes to different, well-formed samples.

The restart stream's lower rate has a second cause. At an interval boundary
jpegz drops unread bits and scans to the RSTm, so surplus entropy bytes left
by damage that makes an interval decode short are discarded unreported.
CharLS requires the marker at the read position (one padding bit at most,
remaining bits zero). The same holds at the end of a scan.

## After the interval and scan-end check (2026-11-22)

validate ruled leftover bytes finding 8 and nonzero padding new FAIL 123.
Same master and rounds, the same two streams:

| Stream | sniper | bolter | shotgun_variable |
|---|---|---|---|
| test16_rm_5 before | 60% [50.2, 69.1] | 86% | 87% |
| test16_rm_5 after | 65% [55.3, 73.6] | 89% | 96% |
| t8nde0 after | 88% | 99% | 99% (unchanged) |

Corrupt counts jpegz's own `corrupt` verdict. Finding 8 is a WARN there (validate
maps it to FAIL), so its cases count as accepted with exit 3: 7 of the 800.
No verdict changed on the 29 CharLS JPEG-LS files or validate's four
ffmpeg-made fixtures.
