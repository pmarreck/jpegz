# jpegz NEXT_STEPS — Path to 100% Cleanroom Variant Coverage

**Last updated:** 2026-05-07 EST, end of M2.1c + M2.1d session.
**Maintained for:** the next Claude session (or any other agent / human)
who picks this up. Anchored to commits on `yolo`.

## Current state (as of commit `2f863a4`)

### Variant coverage matrix

| Variant                  | T.81 §        | Cleanroom | Wrapper | Corpus impact                  |
|--------------------------|---------------|-----------|---------|--------------------------------|
| Baseline DCT (SOF0)      | F             | ✅ 99.7%  | —       | 3837/3848 pixel-perfect        |
| Extended Sequential (SOF1)| F            | ❌        | ✅      | very rare; deferred            |
| Progressive DCT (SOF2)   | G             | ⏳ scaffolded | ✅  | 277 corpus files fall back     |
| Lossless 8-bit (SOF3)    | H §13         | ✅        | ✅      | DICOM/DNG covered              |
| Lossless 12/16-bit       | H §13         | ✅ via M1.4b precision-routing | ✅ | rare; ships today |
| Differential variants (SOF5–7) | H §14   | ❌        | ❌      | extremely rare; deferred       |
| Arithmetic-coded (SOF9–11) | F §F.1.4    | ❌        | partial | rare in modern wild            |
| JPEG-LS (T.87)           | T.87          | ❌        | charls? | medical imaging; future         |
| JPEG 2000 (T.800)        | T.800         | ❌        | ✅ openjpeg | separate ABI namespace      |

**Reality check:** the corpus shows 99.7% pixel-perfect *because* the
wrapper backstops every variant the cleanroom hasn't shipped. When
Peter said "100% coverage of all jpeg variants, please let tiffz and
validate know" — that's the trigger to close THIS gap. Not the
corpus-passing-tests gap (already cleared); the cleanroom-handles-
everything-libjpeg-can gap.

### What's shipped on `yolo`

- **M1 series** (Phase 1 wrappers): libjpeg-turbo + openjpeg behind
  the public API. Validate / tiffz integration recipes delivered.
- **M2.1c** (cleanroom baseline robustness): six commits today
  (`b08794b` → `54463e4`) took baseline cleanroom from 1.5% pixel-
  perfect on Peter's 4,125-file corpus to 99.7%. Notable fixes:
  RST `seekToMarker`, i32 coefficient pipeline, **canonical Huffman
  zero-count gap shift** (the dominant bug — collapsed CLEAN-ERR
  2257 → 13), IJG fancy chroma upsampling, marker-tolerance, single-
  component scan layout, libjpeg-turbo islow IDCT, fixed-point
  YCbCr→RGB.
- **M2.1d** (caller-controlled threading): API surface +
  implementation. `DecodeOptions { threads: u8 = 1 }` per the
  cross-project convention validate proposed. `std.Thread.Pool`
  underneath, parallel IDCT + color conversion. Modest 1.09× speedup
  at 4 cores (Amdahl-bound — entropy is ~90% serial within a non-DRI
  scan).

### What's still using the wrapper at runtime

- **Progressive (SOF2)**: 277/4125 corpus files = 6.7%. Cleanroom
  has scaffolding in `src/decode/progressive.zig` but isn't wired
  into dispatch.
- **Extended sequential / arithmetic / JPEG-LS / JP2**: tiny corpus
  presence; wrapper handles them transparently.

## Gap-closers (in priority order)

### 1. Wire progressive cleanroom into dispatch (M2.2)

**Files:** `src/decode/progressive.zig`, `src/jpegz.zig` (dispatch),
`tests/unit/decode.zig`, possibly `tests/unit/fixtures/`.

**Status:** Scaffolding exists — all 4 scan-type variants (DC first,
DC refinement, AC first, AC refinement) plus EOB-run + ZRL handling
are written. Last known issue (memory observation S139, May 6):
output diverges from libjpeg-turbo on uniform-color test fixture.

**Likely now-fixable:** the Huffman zero-count gap bug (`557569b`)
that crippled baseline almost certainly cripples progressive too —
they share the Huffman code via `src/decode/huffman.zig`. Try wiring
progressive into dispatch immediately:

```zig
// in src/jpegz.zig decode dispatcher, after baseline cleanroom:
const progressive = @import("decode/progressive.zig");
if (progressive.decode(allocator, data)) |img| return img
else |err| switch (err) { error.NotImplemented => {}, else => return err };
```

Then run `cleanroom-diff` against the corpus's 277 progressive files
to see how many decode cleanly. If most pass, write a TDD test for
the synthetic fixtures and ship it. If many fail, debug like we did
for baseline — the same `[baseline:tag]` instrumentation pattern
(comptime-Debug-only `fail()` helper) works for progressive too.

**Win:** closes the largest cleanroom gap in the corpus.

### 2. DRI fast path (parallelism win)

**Files:** `src/decode/baseline.zig` (decodeScan), maybe a new
`src/decode/dri_partition.zig`.

**Status:** Today, baseline cleanroom decodes RST-marker JPEGs
correctly but serially. ~20% of Peter's corpus has DRI > 0.

**Plan:** When `restart_interval > 0` and `options.threads != 1`:

1. Pre-scan the entropy stream once to find every RST byte offset
   (cheap — single pass through bytes, looking for `FF D0..D7` not
   preceded by `FF 00`).
2. Each RST segment is `restart_interval` MCUs starting at a known
   `(mcu_x, mcu_y)`.
3. Per segment: enqueue a task that creates its own `BitReader` over
   the segment's byte range, with `prev_dc = {0,0,0}`, decodes its
   MCUs into the shared coefficient buffer at known coordinates.
4. After all segments complete, run the existing parallel transform
   + assemble pipeline.

**Expected gain:** near-linear speedup for the 20% of corpus with
DRI. No effect on the rest.

### 3. Extended sequential (SOF1)

**Files:** new code in `src/decode/baseline.zig` or split out.

**Plan:** SOF1 differs from SOF0 only in that it allows up to 8-bit
*and* 12-bit precision and up to 4 components. The DCT/Huffman/
restart logic is identical. Adding this is mostly: accept SOF1 in
the marker dispatcher, handle 12-bit precision through the same
i32 coefficient pipeline that already exists, route 12-bit output
through the existing 12-bit precision path used by lossless.

**Win:** rare; one or two corpus files. Closes a spec checkbox.

### 4. Arithmetic coding (SOF9, SOF10, SOF11)

**Files:** new `src/decode/arithmetic.zig` for the Q-coder; reused
SOF logic from baseline/progressive.

**Plan:** Implement the T.81 §F.1.4 arithmetic decoder (Q-coder) +
context conditioning. Substantial work — the Q-coder is fiddly. ~600
lines of code, careful adaptive-probability bookkeeping. Reference:
T.81 §F.1.4, Annex D, and PennebakerMitchell book.

**Win:** completes T.81 cleanroom coverage. Almost no real-world
files use this in 2026, but it's a spec checkbox.

### 5. JPEG-LS (T.87)

**Files:** new `src/decode/jpegls.zig`.

**Plan:** LOCO-I predictor + Golomb-Rice entropy coding. Independent
of T.81 work — different algorithm entirely. ~800–1000 lines.
charls (Apache-2 license) is fine to read for guidance per
SPEC.md §8. Medical-imaging niche; modest priority.

### 6. JPEG 2000 cleanroom (T.800)

**Files:** new `src/decode/jp2/` directory (lots).

**Plan:** This is multi-month effort. EBCOT tier-1/tier-2 + DWT 5/3
or 9/7 wavelet. Patent posture: confirm with Peter before shipping
per SPEC.md note. The existing openjpeg wrapper handles JP2 at
runtime; cleanroom is M2.7 in PLAN.md.

## Performance follow-ups (orthogonal to coverage)

### A. Close gap to libjpeg-turbo at `threads = 1`

Current: cleanroom is ~2.6× slower than wrapper at 1 thread on a
1500×1026 image (27.3 ms vs 10.2 ms). libjpeg-turbo's lead is mostly
hand-tuned NEON/AVX2 SIMD in IDCT and chroma upsampling. Options:

- **SIMD IDCT** — write `src/decode/idct_neon.zig` and `idct_avx2.zig`
  using Zig's `@Vector` builtin. Probably 1.5–2× win.
- **SIMD color conversion** — same idea, 4-pixel-at-once vector
  multiply-add. Probably 1.3× win.
- **SIMD fancy upsample** — same idea, somewhat trickier rounding.

Note: under M2.1d's threading API, all of these are pure
correctness-preserving optimizations behind the existing `threads`
contract — caller doesn't see anything change.

### B. Parallel entropy decode for non-DRI scans

Hard: the DC predictor chain across MCUs makes entropy decode
inherently serial within a scan. Workarounds people have tried:

- Two-pass: pre-scan to find Huffman code boundaries, then decode
  blocks in parallel from known offsets. Requires knowing where each
  Huffman code ends, which requires parsing them. Unclear if it's
  net positive.
- Speculative parallelism: each worker assumes a starting bit
  position, decodes, and validates against a checkpoint. Brittle.

Probably not worth the engineering complexity. **Recommendation:
ship DRI fast path (gap-closer #2) and accept Amdahl on the rest.**

### C. Premature-end tolerance for truncated files

9 of the remaining 11 CLEAN-ERR are truncated downloads (PlayBoy
35,688-byte files). libjpeg-turbo emits a "Premature end of JPEG
file" warning and returns whatever it managed to decode. Our
cleanroom errors out — *correctly* per strict-validator semantics,
but if a future consumer wants tolerance (some image viewers
prefer "show what you have" over "fail loudly"), this could go
behind a `DecodeOptions.tolerate_truncation` flag.

Not blocking. Wait for a real consumer ask.

## The 100%-coverage notification trigger

Peter set this trigger in the M2.1d session:

> "when you get basically 100% coverage of all jpeg variants, please
> let tiffz and validate know after tests are passing and CI passes"

**Trigger fires when:** every variant in the matrix above has
"Cleanroom: ✅" *and* `./test` + Garnix CI both pass *and* corpus
runs cleanly with cleanroom dispatch only (wrapper retired from the
default path). At that point notify both projects via LLMsend. The
relevant inboxes:

- `~/Documents-CloudManaged/validate/inbox/`
- `~/Documents-CloudManaged/tiffz/inbox/`

A natural cut-off short of full T.81+T.87+T.800 100% coverage is
"all of T.81 cleanroom complete" (gap-closers 1, 3, 4 done; 5 and
6 deferred to their own milestones). That's a reasonable
intermediate notification trigger if Peter agrees.

## Reference: today's session arc, in numbers

Started: 432 CLEAN-OK / 2823 CLEAN-ERR (10.5% pixel-perfect)
Ended:  3837 CLEAN-OK / 0 CLEAN-DIV / 11 CLEAN-ERR (99.7% pixel-perfect)
Commits on `yolo`:
- `b08794b` RST seekToMarker
- `5269b07` i32 coefficient pipeline + Huffman short-buffer
- `04c6146` chore: gitignore .claude
- `557569b` THE BUG: Huffman zero-count gap shift
- `17e70d3` IJG fancy chroma upsampling
- `644ad58` extraneous-bytes-before-marker tolerance + non-interleaved scan
- `54463e4` islow IDCT + fixed-point YCbCr→RGB
- `91cea19` PLAN.md update
- `7d4d113` internal.progressiveDecode export
- `f685ec3` build: bench-one harness
- `8657dbc` M2.1d: threading API surface
- `2f863a4` M2.1d: parallel IDCT + color conversion + Garnix badge

Cross-project messages (delivered, not blocking):
- validate: threading convention adopted (with 3 minor refinements)
- tiffz: shared convention recommended for M6+
- validate's reply: confirmed std.Thread.Pool as v1; noted misleading
  "work-stealing" comment in their `memory_budget.zig` they'll fix

## Pickup checklist for the next session

1. `git pull` to confirm `yolo` HEAD = `2f863a4` or later.
2. `nix develop --command codescan status` — make sure the index is
   alive before search-heavy work.
3. `./test` — green check before touching anything.
4. `./zig-out/bin/cleanroom-diff /Volumes/Fileserver/clips-image/` —
   confirm the corpus baseline is still 3837/0/277/11.
5. Pick a gap-closer above. **Recommend starting with progressive
   wiring (#1)** — likely the easiest big win given today's Huffman
   fix probably also fixed progressive.
6. When the trigger conditions for the 100%-variants notification
   are met, send via LLMsend per the inboxes listed above.
