# jpegz NEXT_STEPS — Path to 100% Cleanroom Variant Coverage

**Last updated:** 2026-05-07 EST, end of M2.1c + M2.1d session.
**Maintained for:** the next Claude session (or any other agent / human)
who picks this up. Anchored to commits on `yolo`.

## Current state (as of commit `2f863a4`)

### Variant coverage matrix

| Variant                  | T.81 §        | Cleanroom | Wrapper | Corpus impact                  |
|--------------------------|---------------|-----------|---------|--------------------------------|
| Baseline DCT (SOF0)      | F             | ✅ 99.7%  | —       | 3844/3846 pixel-perfect        |
| Extended Sequential (SOF1, 8-bit) | F    | ✅ M2.3   | —       | 0 corpus; spec coverage        |
| Extended Sequential (SOF1, 12-bit) | F   | ❌        | ✅      | very rare; deferred            |
| Progressive DCT (SOF2)   | G             | ✅ 100% ≤2 LSB | —  | 276/276 (199 byte-perfect)     |
| Progressive + DRI (SOF2+RST) | G + F.2.1.3 | ✅ M2.5    | —       | 0 corpus; spec coverage        |
| Lossless 8-bit (SOF3)    | H §H.1        | ✅ M2.4   | —       | 0 corpus; DICOM/DNG fixture    |
| Lossless 8-bit RGB (SOF3, 3-comp) | H §H.1 | ✅ M2.6  | —       | 0 corpus; spec coverage        |
| Lossless + DRI (SOF3+RST) | H + F.2.1.3  | ✅ M2.7   | —       | 0 corpus; spec coverage        |
| Lossless 12/14/16-bit (SOF3) | H §H.1    | ✅ M2.8   | —       | DICOM/DNG fixture; byte-perfect |
| Differential variants (SOF5–7) | H §H.2  | ❌        | ❌      | extremely rare; deferred       |
| Arithmetic-coded (SOF9–11) | F §F.1.4    | ❌        | partial | rare in modern wild            |
| JPEG-LS (T.87)           | T.87          | ❌        | charls? | medical imaging; future        |
| JPEG 2000 (T.800)        | T.800         | ❌        | ✅ openjpeg | separate ABI namespace     |

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

- **SOF1 12-bit precision** (needs 12-bit DCT/IDCT pipeline —
  separate from cleanroom's 8-bit islow path).
- **SOF3 lossless with non-1×1 sampling** (extremely rare in
  practice; DICOM/DNG default to 1×1).
- **arithmetic (SOF9–11)**, **JPEG-LS (T.87)**, **JP2 (T.800)**:
  no cleanroom yet (substantial future work).
- **Progressive features cleanroom doesn't yet handle**: 12-bit
  precision SOF2.

## Gap-closers (in priority order)

### 1. Wire progressive cleanroom into dispatch (M2.2) — ✅ COMPLETE 2026-05-08

**Files:** `src/decode/progressive.zig`, `src/jpegz.zig` (dispatch),
`tests/unit/decode.zig`, possibly `tests/unit/fixtures/`.

**Status (2026-05-08, commits dbb9e97 → bcd39de):** SHIPPED. Wired into
dispatch in `src/jpegz.zig` after baseline cleanroom. 276/276 corpus
progressive JPEGs decode within ≤2 LSB of libjpeg-turbo (199/276
byte-perfect). Same threshold baseline cleanroom uses against wrapper.

**Six concrete bugs fixed:**
1. **End-of-scan marker detection** (markerHit→seekToMarker, mirrors
   baseline RST handling).
2. **libjpeg-turbo `insufficient_data` parity** — when entropy
   exhausts at a marker, leave current/remaining blocks at their
   current value (matches libjpeg's "leave the MCU set to zeroes"
   behavior). Wired into all six error sites.
3. **YCbCr→RGB float→fixed-point** (16-bit SCALEBITS, libjpeg
   constants Cred=91881, Cgreen_cb=-22554, Cgreen_cr=-46802,
   Cblue=116130). Collapsed delta=1 → delta=0. Per Peter's
   preference: avoid IEEE754 in numerical paths.
4. **IJG fancy chroma upsampling** — replaces nearest-neighbor
   `samplePlane` with the same 9/3/3/1 (h2v2), 3/1 (h2v1, v2h1)
   weights baseline cleanroom uses. Extracted into shared
   `src/decode/color.zig`. Active-frame boundary clamping.
5. **Single-component scan iteration uses xi/yi per T.81 §A.2.4**
   — `xi = ceil(W * Hi / (8 * Hmax))` for the inner loop bound,
   stride=`blocks_w[comp_idx]` for the buffer. Multi-component
   scans still use MCU-padded iteration. Fixes 549×304 4:2:0
   class of files where MCU-padding adds an extra Y column.
6. **AC refinement ZRL break semantics** — match libjpeg's
   `if (--r < 0) break;` exactly. Track `is_zrl = (size==0 && run==15)`;
   break the inner walk immediately after the 16th zero is decremented
   on ZRL, instead of letting the loop iterate once more (which
   would refine a nonzero immediately following the 16-zero window
   without the encoder having written a refinement bit for it).
   Found via per-scan coef diff against libjpeg-turbo.

**Diagnostic tooling shipped (under `scratch/`, all gitignored):**
- `dump_coefs_libjpeg.c` — uses `jpeg_read_coefficients()` to dump
  post-entropy quantized coefficients in natural order.
- `dump_coefs_jpegz.zig` — same format, calls
  `internal.progressiveDecodeAndDumpCoefs` (added to public-but-
  internal namespace; not part of stable ABI).
- `scan_walk_diff.py` — truncates the file after each SOS scan
  with a synthetic EOI marker, runs both decoders on each truncated
  version, and identifies the first diverging scan. Found bug #6.
- `pixel_diff.zig` — per-pixel diff + 8×8-cell delta heatmap.
- `libjpeg_turbo_instr/` — vendored libjpeg-turbo 3.1.1 source for
  invasive instrumentation if scan-walk approach isn't enough.

**Validation-strictness consideration (Peter, 2026-05-08):** libjpeg-
turbo silently tolerates several malformed-bitstream conditions
(`insufficient_data` zero-padding being the most prominent). Our
goal differs — we care about format integrity for validation tools.
Today the cleanroom matches libjpeg's tolerance for byte-equal output,
but a future enhancement could expose these tolerances as
`Finding(severity=warn)` entries in `validate(...)`'s ValidationReport
so callers can choose strict vs lenient mode. Not blocking M2.2.

**Outstanding follow-ups:**
- DRI in progressive scans (currently NotImplemented; small corpus
  presence). Needs baseline-style RST handling: `seekToMarker()` at
  restart-interval boundaries, `prev_dc` reset, RSTm marker cycle.
- 12-bit precision in SOF2 (looks like SOF1 with progressive
  storage; probably very rare).
- Validation strictness mode (above).

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
