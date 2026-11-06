# Zero-padding treatment: corruption-coverage effect, 2026-11-06

This measures the effect of the 2026-10-23 change. Before it, a Huffman
segment whose pad bits were all 0 was FAIL. After it, that pattern is finding
63 `entropy_padding_zero_bits`, an admitted encoder defect. The two runs use
identical seeded inputs. Known defects are reported separately, and the
judged-case denominator is unchanged.

## Setup

- **Builds:**
  - before: `ca500f9`, the parent of `698c2c3`;
  - after: `8fd246d`, where WARN 63 covers every Huffman decoder.

  Both are built with `nix build .#jpegz` from detached worktrees. Comparing
  these two adjacent commits, rather than today's HEAD, isolates the change
  from every later severity revision.
- **Mutations:**
  - `./corruption-coverage` with the default master `0x6a7065677a` and 100 rounds;
  - the profiles sniper, bolter, shotgun_variable and nuke;
  - corruption-reader 0.9.0.
- **Fixtures:**
  - the four T.81 Huffman fixtures `baseline_2x2_rgb.jpg`, `baseline_16x16_rgb_420.jpg`, `progressive_32x32_gray_dri.jpg` and `lossless_16x16_gray_dri.jpg`;
  - each is known-good under both builds;
  - the default fixture set was not used: its JPEG-LS file is refused as not known-good (an open owner question), and its JP2 and JPEG XL files would mix in older provider pins.

## Result

| Build | judged | corrupt | Wilson 95% | accepted | known_defect | other |
|---|---:|---:|---|---:|---:|---:|
| before (`ca500f9`) | 1600 | 575 | 35.9% [33.6, 38.3] | 610 | 0 | 415 |
| after (`8fd246d`) | 1600 | 568 | 35.5% [33.2, 37.9] | 617 | 0 | 415 |

"Other" counts the unsupported and indeterminate cases, mostly nuke overwrites
that leave no JPEG signature. It is identical in both runs.

**Per case**, exactly 7 cases changed, all from corrupt to accepted, and none
changed the other way. All 7 came from the bolter profile:
- `baseline_16x16_rgb_420.jpg`, rounds 46 and 62;
- `lossless_16x16_gray_dri.jpg`, rounds 7, 24, 49 and 84;
- `progressive_32x32_gray_dri.jpg`, round 79.

That is 7 of 1,600 cases, or 0.44% [0.21, 0.90]; for bolter alone it is 7 of
400, or 1.75% [0.85, 3.57].

**Today's treatment.** At `8fd246d` the CLI had no known-defect verdict, so
WARN 63 counted as accepted. Replayed through HEAD (`1b1b0fb`), all 7 cases
are `known_defect` and exit 4. In each, the only non-INFO finding is
`entropy_padding_zero_bits` at severity `KNOWN_DEFECT`.

## Reading

- **Damage can mimic the admitted signature.** Random damage, a bolter burst
  that zeroes the last pad bits of a segment, produces the producer signature
  in about 0.4% of these cases. TERMINOLOGY A2 anticipates this ("Damage can
  mimic a writer's violation"). Coverage reports count these cases as
  known_defect, separately from damage caught as FAIL. They are not counted as
  detections.
- **No new false negatives elsewhere.** The change moved no other case.
- **Corrupt rate:** under the current treatment it is 568/1600 on this
  fixture set, and 7 more cases are flagged as known defects rather than
  passed silently.
