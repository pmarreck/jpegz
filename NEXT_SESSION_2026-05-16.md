# jpegz — Session Handoff, 2026-05-16

## Where we are

Cleanroom JPEG family decoder is now **byte-perfect against libjpeg-turbo**
across the entire feature surface in tree. 178/178 tests pass on
`origin/yolo`.

```
Last commits this session (oldest → newest):
55e03ed  B2.2 §3: cleanroom JPEG-LS RGB 8-bit sample-interleaved decode
43e1fe8  B2.2 §4: cleanroom JPEG-LS 16-bit grayscale decode
a1758d5  JPEG-LS RGB 16-bit cleanroom decode
c9c9461  JPEG-LS near-lossless decode (NEAR > 0)
2731933  docs: PLAN.md — M2.6 JPEG-LS marked WIP-shipped
624c996  M2.2 audit: progressive cleanroom is done, lock byte-perfect baseline
d9da13b  M2.2 byte-perfect: align PASS1_BITS to libjpeg-turbo at P=12
fde03ee  M2.3: lossless cleanroom audit — 13 fixtures byte-perfect
0cfc2bd  M2.5 audit: arithmetic cleanroom byte-perfect on gray + 4:4:4 RGB
1c2524e  Fancy upsample: port libjpeg's asymmetric +8/+7 bias to 8-bit path
```

### Current byte-perfect coverage (cleanroom vs libjpeg-turbo wrapper)

| Codec / mode                                | Status |
|---------------------------------------------|--------|
| 8-bit baseline (gray, RGB 4:4:4)            | ✅ ==0 |
| 8-bit baseline (RGB 4:2:0, 4:2:2)           | ✅ ==0 (was ≤2 LSB, fixed this session) |
| 8-bit progressive (gray, RGB, DRI > 0)      | ✅ ==0 |
| 12-bit baseline (gray, RGB at all 4 factors)| ✅ ==0 (was ≤4 LSB, fixed this session) |
| 12-bit progressive (gray, RGB at all 4)     | ✅ ==0 (was ≤4 LSB, fixed this session) |
| Lossless precision 8/12/14/16, 1 + 3 comp   | ✅ ==0 |
| Lossless DRI > 0 / all 7 predictors         | ✅ ==0 |
| SOF9 arithmetic (gray + RGB all 4 factors)  | ✅ ==0 (was ≤4 LSB, fixed this session) |
| SOF10 arith progressive (gray + RGB all 4)  | ✅ ==0 (was ≤4 LSB, fixed this session) |
| JPEG-LS mono 8-bit / 16-bit lossless        | ✅ byte-exact (cleanroom independent of libjpeg) |
| JPEG-LS RGB 8-bit / 16-bit sample-interleaved | ✅ byte-exact |
| JPEG-LS NEAR > 0 (near-lossless)            | ✅ within NEAR spec guarantee |

### Two algorithmic fixes that did the heavy lifting

1. **`PASS1_BITS = 1` at P > 8** (commit `d9da13b`)
   - libjpeg-turbo `jidctint.c:102-108` defines `PASS1_BITS = 2` only at
     `BITS_IN_JSAMPLE == 8`; at higher precisions it drops to 1
     ("lose a little precision to avoid overflow"). Our IDCT hardcoded 2
     for both; parameterizing `pass1Bits(P)` made every 12-bit DCT
     fixture byte-perfect.

2. **Asymmetric chroma-upsample rounding bias** (commit `1c2524e`)
   - libjpeg-turbo `jdsample.c` uses **asymmetric** bias for each
     2-pixel output pair: H2V2 → +8 left / +7 right; H2V1 → +1/+2;
     H1V2 → +1/+2. Our 8-bit `color.fancyUpsample` and the duplicate
     `baseline.fancyUpsample` used **symmetric** +8/+8 and +2/+2.
   - The 12-bit `color.fancyUpsample12` had already been ported
     correctly. The 8-bit ones had not.
   - This was the residual on every 8-bit subsampled fixture (arith and
     Huffman). Fixed in both 8-bit copies — `>> 4` with alternating
     +8/+7, etc.

### Diagnostic infrastructure added this session

Two new entry points under `jpegz.internal`, useful when chasing future
sub-LSB divergences:

- `wrapperDumpCoefs(allocator, data) → WrapperCoefDump` — wraps
  libjpeg-turbo's `jpeg_read_coefficients`. Natural order, pre-dequant,
  i16 per coefficient.
- `arithDumpCoefsSof9(allocator, data) → ArithCoefDump` — cleanroom
  arith SOF9 entropy decode only (no dequant, no IDCT). Same shape as
  the wrapper dump for direct bit-diff.

These were what let us prove the arith decoder was correct and isolate
the issue to the upsample step. Keep them — they will save hours next
time someone hunts a 1-LSB regression.

---

## What's left (open items)

### 1. Consolidate `fancyUpsample` (highest immediate value, easy)

There are currently **two byte-identical copies** of the H2V2 / H2V1 /
H1V2 fancy upsampler:
- `src/decode/color.zig::fancyUpsample` — used by `progressive.zig`
  through `assembleProgressiveGeneric(8, ...)`.
- `src/decode/baseline.zig::fancyUpsample` — used by `baseline.zig`
  through `baseline.assembleOutput`.

I had to apply the asymmetric-bias fix in both places. Next time
someone touches one and not the other, the test suite will catch it (we
now have direct byte-perfect coverage on both paths), but it's still
two-places-must-stay-in-sync. **Bias check first** before refactoring —
empirically these two implementations are byte-identical right now;
consolidating doesn't change output.

Plan:
- Move `fancyUpsample` (the 8-bit one) into `color.zig`.
- Delete the `baseline.zig` copy.
- Have `baseline.assembleOutput` call `color.fancyUpsample` directly.
- Same for `ycbcrRowToRgb` (also duplicated).
- Run the full sweep; output must be unchanged.

Estimated effort: 30 minutes, one commit.

### 2. JPEG-LS line-interleaved (ILV=1)

The cleanroom JPEG-LS decoder handles ILV=0 (planar/non-interleaved)
and ILV=2 (sample-interleaved). ILV=1 (line-interleaved) is the rare
third option — each scan line is decoded as N component strips per
row, with per-component context state.

The infrastructure is already in place: `ScanState` has `contexts[4]`,
`run_index[4]`, `run_contexts[4][2]` arrays designed for per-component
state. They're allocated but only `[0]` is exercised in v1.

Plan:
- Generate a fixture: `gen_jpegls_fixtures.c` add a 4×4 RGB ILV=1 case.
- Write `decodeScanLine` in `src/decode/jpegls.zig`. Per scan-line,
  loop: for each comp c in 0..nc, run an inner pass over W pixels using
  `state.contexts[c]`, `state.run_index[c]`, etc.
- Failing test first against the fixture, then implement, then verify
  byte-exact against charls.

Estimated effort: 1-2 sessions. The codec helpers and context plumbing
are done; this is mostly scan-loop orchestration with a new outer level.

### 3. JPEG-LS RST markers

T.87 §F.2.1.3 — restart-style state reset for JPEG-LS scans. Currently
the cleanroom doesn't handle them; charls fallback takes over. No
fixture in tree. Lower priority than ILV=1.

### 4. Lossless follow-ons

`src/decode/lossless.zig` has two `NotImplemented` gates:
- Non-1×1 sampling factors (rare; tiff-with-jpeg-compression sometimes
  uses subsampled lossless).
- Point transform `Al > 0` (sample shifted up by Al; trivial when a
  fixture surfaces it).

No fixtures in tree, no real-world demand. Don't pursue speculatively.

### 5. M2.7 — JPEG 2000 cleanroom (T.800)

Multi-month effort. Wavelet + EBCOT + tier-1 / tier-2 coding. Currently
wrapped via openjpeg. Patent posture should be confirmed with Peter
before starting. Worth scoping into discrete sub-milestones similar to
how M2.6 was broken into §1c, §2, §3, §4 plus the post-v1 polish bites.

Suggested sub-milestones:
- M2.7a: codestream marker walker + SIZ/COD/QCD parse.
- M2.7b: Tier-2 (packet headers, layer/resolution/component/precinct).
- M2.7c: Tier-1 EBCOT decode (one code-block at a time).
- M2.7d: Wavelet inverse 5/3 lossless.
- M2.7e: Wavelet inverse 9/7 lossy.
- M2.7f: MCT (Multiple Component Transform) inverse.

### 6. validate(...) warn surface for cleanroom paths

`NEXT_STEPS.md` mentions: cleanroom decoders should emit
`Finding(severity=warn)` for tolerances that match libjpeg's silent
warning behavior (e.g. extraneous bytes before markers, premature EOI
with recovered data). The libjpeg wrapper has the WARNMS capture
machinery; cleanroom paths don't surface anything similar yet.

Plan: introduce a `Findings` collector argument threaded through the
cleanroom decoders, attach to `validate(...)` for spec deviations.
Audit each NotImplemented / silent-tolerance site in baseline,
progressive, lossless, arith, jpegls.

---

## Repo state snapshot

```
Branch:  yolo
Origin:  github.com:pmarreck/jpegz.git
Tests:   178/178 passing
Build:   nix flake check — green on darwin + linux musl
Charls:  vendored at 2.4.3, compiled via Zig's clang
Fixtures: 60+ in tests/unit/fixtures/, all under 1 KB each
```

Notable files added/modified this session:

```
M  PLAN.md                                      — milestones M2.2/M2.3/M2.5/M2.6 refreshed
A  NEXT_SESSION_2026-05-16.md                   — this file
M  src/decode/idct.zig                          — pass1Bits(P)
M  src/decode/color.zig                         — asymmetric upsample bias
M  src/decode/baseline.zig                      — asymmetric upsample bias
M  src/decode/jpegls.zig                        — full §3/§4/RGB16/NEAR>0
M  src/decode/jpegls_codec.zig                  — computeReconstructed(NEAR, RANGE)
M  src/decode/lossless.zig                      — refreshed stale doc comments
M  src/decode/arith_decode.zig                  — + dumpCoefsSof9 diagnostic
M  src/ffi/libjpeg_wrapper.zig                  — + dumpCoefs diagnostic
M  src/jpegz.zig                                — internal.{arithDumpCoefs, wrapperDumpCoefs}
M  tests/unit/decode.zig                        — tolerance tightening + new fixtures
A  tests/unit/fixtures/jpegls_4x4_rgb16.jls
A  tests/unit/fixtures/jpegls_8x8_gray8_near2.jls
A  tests/unit/fixtures/jpegls_8x8_gray8_near2.raw  — side-car for NEAR test
A  tests/unit/fixtures/baseline_16x16_rgb_420.jpg  — 8-bit Huffman subsampled regression
```

---

## When you pick this back up

**First** — run `nix develop -c zig build test --summary all` to confirm
178/178 still pass.

**Then** — decide direction:
- *Quick win (30 min)*: consolidate the duplicate `fancyUpsample` /
  `ycbcrRowToRgb` between `baseline.zig` and `color.zig`. Single
  source of truth.
- *Medium feature (1-2 sessions)*: JPEG-LS ILV=1 line-interleaved.
- *Big bite (multi-session)*: M2.7 JPEG 2000 sub-milestone M2.7a.
- *Architectural (1 session)*: cleanroom `Findings` collector for
  validate(...).

The session's MO worked well: **diagnostic sweep first, root-cause
second, fix and lock-in third.** Two of three "byte-perfect" wins this
session were one-line constant fixes once the right diagnostic was in
place. The coef-dump infrastructure (`internal.wrapperDumpCoefs` +
`internal.arithDumpCoefsSof9`) is the keystone tool for any future
≤N-LSB hunt — use it before assuming "this codec is wrong".
