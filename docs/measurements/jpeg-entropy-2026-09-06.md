# Baseline JPEG entropy remeasurement

The extracted-JPEG comparison below was measured by validate and independently
rerun by jpegz on 2026-09-06 (completed 13:49 EDT). The input is private local-only
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
promoted. The post-promotion full-PDF replay and broader known-good corpus
remain open; the pre-promotion full-PDF follow-up is below.

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

## Full-PDF follow-up at `e8f9982`

Validate's report arrived September 6 at 14:06 EDT, before consumer promotion.
jpegz independently replayed both native scratch binaries and clean controls,
finishing at 14:14 EDT. Input: the original 49,130,624-byte private PDF,
seed `1787878036`, 400 rounds.

| Control | Scratch `89d74e3` | Scratch `e8f9982` |
|---|---:|---:|
| All mutations detected | 303/400 (75.8%) | 319/400 (79.8%) |
| Single-byte mutations detected | 107/204 (52.5%) | 123/204 (60.3%) |
| Shotgun mutations detected | 196/196 (100%) | 196/196 (100%) |
| Unmodified PDF | Clean OK | Clean OK |

This is a net gain of 16 single-byte detections, 7.8 percentage points, on one
PDF and seed. The native before arm reproduced the earlier Nix baseline.
The printed single-byte 95% intervals were [45.6,59.2] and [53.4,66.8]. No
per-mutant attribution or general detection rate is established. Consumer
promotion and a post-promotion Nix replay remain open.

The reported scratch setup keeps validate `c582e410c` and tiffz `9ea64ff5`
as above, with jpegz changed to `e8f9982f2e5c770d4e1065750f6de4dae92ffd16`.
jpegz independently checked that the tiffz manifests differ only in jpegz's
URL/hash and verified both signed binaries. The before SHA-256 is unchanged
from the earlier table; the after SHA-256 is
`bd751b3e3a7d007d9e78b929c251a5d2437e35961419cd7aa3fc5f0fddbdda9a`.
Complete source/toolchain isolation still rests on validate's build record.

Both independent coverage runs used the command below, in separate user scopes
with `MemoryHigh=16G` and `MemorySwapMax=0`. All 400 trials ran and both commands
exited zero. Both normal-validation controls returned clean OK and exited zero.

```bash
VALIDATE_SEED=1787878036 validate --test-coverage 400 --no-heatmap --no-progress \
  --coverage-jobs 0 PDF_PATH
```

Validate also reports unchanged extracted-JPEG results at this checkpoint:
193/300 overall, 47/154 single-byte, 146/146 shotgun, and a clean original.
