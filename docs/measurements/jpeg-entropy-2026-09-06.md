# Baseline JPEG entropy remeasurement

Measured by validate and independently rerun by jpegz on 2026-09-06
(jpegz verification completed 13:49 EDT). The input is private local-only
paperwork. No original or mutated image belongs in this repository or off
the measurement host. Paths and extraction instructions are local metadata in
`.git/jpegz-private-entropy-reproducer.md`.

## Results

| Control | Before `89d74e3` | After `8b3e7ed` |
|---|---:|---:|
| All mutations detected | 183/300 (61.0%) | 193/300 (64.3%) |
| Single-byte mutations detected | 37/154 (24.0%) | 47/154 (30.5%) |
| 4096-byte shotgun mutations detected | 146/146 (100%) | 146/146 (100%) |
| Unmodified JPEG | Clean OK | Clean OK |

The identical seeded workload gained ten net single-byte detections, a
6.5-percentage-point increase. The printed 95% intervals for the single-byte
rates were [18.0,31.4] and [23.8,38.2]. These are results for one input and seed.
No per-mutant gain/loss classification or population-wide rate is established.
Some entropy mutations remain legal, so detecting every mutation is not an
appropriate correctness target.

This measurement covers the CI-green baseline checkpoint `8b3e7ed`, not the
later progressive checkpoints `7df6ba3` or `e8f9982`. No consumer pins were
promoted. Full-PDF acceptance and the broader known-good corpus remain open.

## Reproduction and fixed inputs

The source graph and build setup below are validate-reported. jpegz checked
the tiffz manifest change, signed-binary hashes, input hash, and result replays;
it did not independently reconstruct the complete source/toolchain isolation.

- JPEG SHA-256: `4a2e013e63ff9674ebce3f19cde91491e827ca1fb8202a2f0c22da7ef44154fa`.
- Size: 698,412 bytes; baseline Huffman JFIF, 2538x3296, 300x300 dpi.
- validate source: `c582e410c` in both arms.
- tiffz source: `9ea64ff5860672955bec6f354a9a18b2ab99bf63` in both arms.
- jpegz before: `89d74e335d9c537ea9985e782fedeb57fc48fc0e`.
- jpegz after: `8b3e7ed792a38227e2e2940ace62d7be285fd52b`.
- Both binaries used Zig 0.16.0, ReleaseFast, identical build commands,
  separate local caches, fixed remaining dependency pins, and validate's
  required binary signing step, according to validate's build record.

```bash
VALIDATE_SEED=1787878261 validate --test-coverage 300 --no-heatmap --no-progress \
  --coverage-jobs 0 JPEG_PATH
```

Default modes were sniper plus shotgun, shotgun span 4096, automatic jobs,
and early-stop radius 0.025. All 300 trials ran in both arms. The coverage tool
counts any outcome other than clean OK as detected. Separate normal-validation
calls returned clean OK with both binaries.

Validate constructed scratch copies of its fixed source and tiffz source.
The consumer's tiffz dependency used a corresponding local path in each arm;
the only tiffz manifest difference was the jpegz URL/hash. jpegz independently
checked that manifest difference and both signed-binary hashes, then reran
the coverage command and clean-input controls. The before arm reproduced the
earlier Nix-built count, although these two controlled arms were native
ReleaseFast builds, not separate Nix derivations.

| Signed binary | SHA-256 |
|---|---|
| Before | `5c387668f0b3dd871b804a9cca5dcdf0a9fc2637402d59ea86d18b20e6baf36c` |
| After | `cd81bd000bb9f1ad02836d01d21d964a26f4bbf6e257f69f051a644d18ac21a0` |

The after checkpoint's exact Mechatron run passed all four manifest targets
on September 6 at 12:19 EDT, taking 361 seconds. The independent native reruns
completed without errors and reproduced validate's mutation counts.
