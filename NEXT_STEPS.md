# jpegz NEXT_STEPS — Handoff to Next Session

**Last updated:** 2026-05-13.
**Maintained for:** the next Claude session (or any other agent / human)
who picks this up. Anchored to commits on `yolo`.

> This is a **complete handoff document.** Read it top to bottom on
> session pickup. Past commits and memories are referenced inline.

---

## Pickup checklist (60 seconds)

1. `git pull` — confirm `yolo` HEAD ≥ `edce8d6` (most recent doc) or
   `649c0ae` (latest code commit, M2.8).
2. `./test` — must print `All checks passed.` (96/96 unit tests).
3. `./zig-out/bin/diag-one tests/unit/fixtures/progressive_8x8_rgb.jpg`
   — quick sanity that the progressive cleanroom is alive.
4. Read **§"What's next"** below — choose ONE of the prioritized tasks
   and follow TDD (write a failing test FIRST; see Peter's CLAUDE.md
   rules and the `superpowers:test-driven-development` skill).

**If anything is red:** stop and report. Don't barrel past test
failures into more code.

---

## Current state (after M2.8)

### Cleanroom variant coverage

| Variant                           | T.81 §        | Cleanroom    | Wrapper | Corpus impact                        |
|-----------------------------------|---------------|--------------|---------|--------------------------------------|
| Baseline DCT (SOF0)               | F             | ✅ 99.7%     | —       | 3844/3846 byte-perfect               |
| Extended Sequential (SOF1, 8-bit) | F             | ✅ M2.3      | —       | 0 corpus; spec coverage              |
| Extended Sequential (SOF1, 12-bit)| F             | ❌           | ✅      | very rare; wrapper backstop          |
| Progressive DCT (SOF2)            | G             | ✅ 100% ≤2 LSB | —     | 276/276 (199 byte-perfect)           |
| Progressive + DRI (SOF2+RST)      | G + F.2.1.3   | ✅ M2.5      | —       | 0 corpus; spec coverage              |
| Lossless (SOF3) 8-bit grayscale   | H §H.1        | ✅ M2.4      | —       | 0 corpus; DICOM/DNG synth fixtures   |
| Lossless (SOF3) 3-comp RGB        | H §H.1        | ✅ M2.6      | —       | 0 corpus; spec coverage              |
| Lossless + DRI (SOF3+RST)         | H + F.2.1.3   | ✅ M2.7      | —       | 0 corpus; spec coverage              |
| Lossless 12/14/16-bit             | H §H.1        | ✅ M2.8      | —       | DICOM/DNG; byte-perfect              |
| Lossless w/ non-1×1 sampling      | H §H.1        | ❌           | ✅      | extremely rare; deferred             |
| Differential variants (SOF5–7)    | H §H.2        | ❌           | ❌      | extremely rare; deferred             |
| Arithmetic-coded (SOF9–11)        | F §F.1.4      | ❌           | ✅      | almost zero modern use               |
| JPEG-LS (T.87)                    | T.87          | ❌           | charls? | medical imaging niche                |
| JPEG 2000 (T.800)                 | T.800         | ❌           | ✅ openjpeg | separate ABI namespace            |
| 12-bit Progressive (SOF2)         | G             | ❌           | ✅      | rare; needs 12-bit DCT pipeline      |

### Test counts
- **96 unit tests passing** (32 in `tests/unit/decode.zig`, plus inline
  module tests).
- **35 fixtures** in `tests/unit/fixtures/` covering every cleanroom
  variant + several wrapper fall-through paths.

### Module layout (src/decode/)

| File             | Lines  | Role                                          |
|------------------|--------|-----------------------------------------------|
| `baseline.zig`   | 1016   | SOF0/SOF1 8-bit DCT decode, threading pool    |
| `progressive.zig`| 1072   | SOF2 multi-scan DCT decode incl. DRI + refine |
| `lossless.zig`   |  432   | SOF3 8/12/14/16-bit, 1/3 comp, DRI, 7 predict |
| `huffman.zig`    |  278   | Canonical Huffman build + fast/slow decode    |
| `idct.zig`       |  337   | libjpeg-turbo islow integer IDCT             |
| `bitstream.zig`  |  241   | Byte-stuffed bit reader + marker handling     |
| `color.zig`      |  163   | Fixed-point YCbCr→RGB + fancy chroma upsample |

`src/jpegz.zig` is the public dispatch:
```
baseline cleanroom     (SOF0/SOF1 8-bit)
progressive cleanroom  (SOF2, incl. DRI)
lossless cleanroom     (SOF3 8/12/14/16-bit, 1/3 comp, incl. DRI)
libjpeg-turbo wrapper  (everything else + final fallback)
```

NotImplemented from each cleanroom falls through to the next layer.

---

## What's next (prioritized)

### Tier A — Smaller, finish T.81 cleanroom faster

#### A1. SOF1 12-bit precision (extended sequential 12-bit)

- **Effort:** medium-large. Needs 12-bit DCT/IDCT pipeline distinct
  from the 8-bit `islow` IDCT.
- **Why it's worth doing:** closes the last SOF1 row in the matrix.
  Without it, `cjpeg -baseline -precision 12 -dct int` (the existing
  `baseline_4x4_gray12_dct.jpg` fixture path) keeps falling through
  to the wrapper.
- **Approach (sketch):**
  1. Lift `precision != 8` rejection in `baseline.zig` for SOF1
     (currently NotImplemented for P=12 falls through to wrapper).
  2. Port libjpeg-turbo's `jidct12.c` `jpeg_idct_12_islow` (lives in
     `scratch/libjpeg_turbo_instr/src/jidct12.c` if still vendored).
     Same coefficients as islow but with 12-bit-shifted ranges.
  3. Output buffer becomes `u16` host-endian like lossless's M2.8;
     consumer reads via `image.pixelsU16()`.
  4. Dequantization: DQT entries for 12-bit are already 16-bit per
     spec; existing `parseDqt` handles `precision_id == 1`.
  5. YCbCr→RGB conversion at 12-bit precision: scale the libjpeg
     fixed-point constants accordingly, OR convert to 8-bit by
     right-shifting before color conversion (libjpeg does the latter
     internally).
- **Fixture:** the existing `baseline_4x4_gray12_dct.jpg` (uniform 0x800
  expected). Add a non-uniform 12-bit fixture for predictor coverage.

#### A2. SOF3 lossless with non-1×1 sampling

- **Effort:** small. Just lift the `c.h_factor != 1 or c.v_factor != 1`
  check and walk the MCU correctly (variable blocks per component per
  MCU).
- **Why:** rare in practice (DICOM/DNG default to 1×1), but closes the
  matrix row. Zero corpus impact.
- **Fixture:** generate with `cjpeg -lossless 1 -sample 2x2,1x1,1x1` on
  a PPM. Worth a try.

#### A3. 12-bit precision SOF2 progressive

- **Effort:** large. Same precision pipeline as A1 but in progressive
  context. Defer until A1 lands so the 12-bit IDCT is reusable.

### Tier B — Big lifts (one full session each)

#### B1. Arithmetic-coded JPEG (SOF9/10/11)

- **Effort:** ~600 LOC for the Q-coder + ~400 LOC adapting SOF0/2
  scaffolding. Two full sessions, probably.
- **Why:** completes T.81 spec coverage. Modern-use almost zero, but
  some scanner output and legacy archive JPEGs use it.
- **References:**
  - T.81 §F.1.4 (encoder) / §F.2.4 (decoder)
  - T.81 Annex D (Q-coder spec)
  - Pennebaker & Mitchell "JPEG: Still Image Data Compression Standard"
    (the canonical book; google "pennebaker mitchell pdf").
  - libjpeg-turbo `jdarith.c` for a reference implementation. Apache-2
    licensed, fine to read for guidance (per SPEC.md).
- **Approach (sketch):**
  1. New module `src/decode/arithmetic.zig` with the Q-coder state
     machine: 16-bit `A` (range) + 32-bit `C` (code), byte-stuffed input.
  2. Statistical area: 4 tables of 49 binary contexts each (DC), 1 table
     of 245 contexts (AC). Each context = {index, MPS}, indexed via
     the state transition tables (libjpeg's `qe_table`).
  3. Decode procedures: `decode(stat_index)` returns 0/1 bit based on
     current probability estimate; updates state via MPS/LPS table.
  4. SOF dispatch: lift SOF9/10/11 from rejection in baseline.zig;
     for arithmetic, parse DAC (Define Arithmetic Coding) markers
     instead of DHT; entropy decode uses Q-coder for DC differential
     (size + amplitude) and AC (run + size + amplitude) — same SSSS/
     RRRR codes as Huffman, different binarization.
- **Fixture:** existing `baseline_4x4_arithmetic.jpg`. Generate larger
  fixtures with `cjpeg -arithmetic`.
- **Validation-warns hookup:** if Q-coder encounters an invalid state
  (LPS-renorm overflow, MPS state index out of range), surface as a
  Finding in validate(...) per the strictness rule (see §Architecture).

#### B2. JPEG-LS (T.87)

- **Effort:** ~800-1000 LOC. Entirely different algorithm from T.81
  (LOCO-I predictor + Golomb-Rice entropy coding). One+ session.
- **Why:** medical imaging niche (DICOM uses it). Not gated for the
  100% trigger if Peter agrees on a "T.81 only" cut-off.
- **Approach (sketch):**
  1. New module `src/decode/jpegls.zig`.
  2. LOCO-I predictor (T.87 §A.4.1): `min(a,b)` if `c≥max(a,b)`,
     `max(a,b)` if `c≤min(a,b)`, else `a+b-c`. Like SOF3 predictor 4
     but with the median preprocessing.
  3. Context modeling: gradients `D1=b-d`, `D2=c-b`, `D3=a-c` quantized
     to ±4 bins each = 365 contexts (after symmetry merging). Each
     context tracks running `N` (count), `A` (absolute error sum),
     `B` (correction).
  4. Golomb-Rice entropy: parameter `k` derived per-context from
     `A/N`. Unary prefix + `k` binary bits.
  5. Run mode: extension for long flat regions.
- **References:** T.87 spec, charls (Apache-2) for reference.
- **Fixture:** need to generate via charls or another encoder; cjpeg
  doesn't emit JPEG-LS.

#### B3. JPEG 2000 (T.800) cleanroom

- **Effort:** multi-month. EBCOT tier-1 + tier-2 + DWT 5/3 or 9/7 wavelet
  + R/D allocation. The openjpeg wrapper handles JP2 at runtime.
- **Patent:** confirm with Peter before shipping (SPEC.md note).
- **Status:** out of scope until M2.7+ in the milestone plan.

### Tier C — Performance + tooling follow-ups

- **DRI fast path parallelism** (task #2 in the task list): pre-scan
  RST byte offsets, decode each segment in parallel under
  `options.threads > 1`. Near-linear speedup on the ~20% of corpus
  with DRI. Independent of variant coverage.
- **SIMD IDCT** (`src/decode/idct_neon.zig` / `idct_avx2.zig`) using
  Zig `@Vector`. 1.5–2× win, brings us closer to libjpeg-turbo's
  hand-tuned speed.
- **Premature-end tolerance** behind `DecodeOptions.tolerate_truncation`
  flag. Today the cleanroom errors out on truncated downloads (11
  corpus files); libjpeg returns a partial image. Add a flag if a
  consumer asks.

---

## Architecture decisions to remember

### Validation-strictness: warns over silent tolerance

**Source:** Peter, 2026-05-08, confirmed 2026-05-09.
**Memory file:** `feedback_validation_warns_not_silent_tolerance.md` (in
this project's auto-memory directory).

When the cleanroom decoder mirrors libjpeg-turbo's silent tolerances
(insufficient_data zero-padding, partial-EOI tolerance, etc.) to match
its pixel output, the **`validate(...)` API path must also surface those
conditions as `Finding(severity=warn)` entries on the
ValidationReport**. Two audiences:

- **Image renderers**: want libjpeg-style "just give me pixels" —
  cleanroom currently provides this.
- **Format-integrity validators**: want every spec deviation flagged —
  needs the warns we haven't wired up yet.

Don't change the cleanroom decode path's behavior. Add the Finding
emission in `validate(...)` (and any shared marker-walker code).
Tracker: task #7 in the task list.

**Conditions that should warn:**
- Entropy stream exhausted at scan end before all blocks decoded
  (insufficient_data — currently zero-padded silently).
- DRI > 0 but RSTm marker missing or wrong cycle.
- 0xFF fill bytes inside entropy stream (legal but non-canonical).
- Non-canonical Huffman table (gap in code lengths after the
  zero-count-gap-shift fix).
- DC predictor differential carries across what should be a restart
  boundary.
- Adobe APP14 transform byte missing or conflicting with JFIF.

### Integer/fixed-point over IEEE754

**Source:** Peter, 2026-05-08.
**Memory file:** `feedback_prefer_integer_fixed_point.md`.

For numerical code (color conversion, IDCT, DSP), reach for
integer/fixed-point FIRST. IEEE754's non-associativity, platform-
specific rounding, and SIMD-flag-sensitive results are a constant
source of byte-level reproducibility bugs. Concrete instance: the
M2.2b commit collapsed a delta=1 LSB drift to delta=0 on 3 progressive
corpus files just by porting libjpeg-turbo's fixed-point YCbCr
conversion (16-bit SCALEBITS, constants Cred=91881 etc.).

Only fall back to floats when the algorithm genuinely needs them and
the nondeterminism is acceptable in context. When in doubt, ask.

### Threading API contract

**Source:** M2.1d, cross-project convention with validate/tiffz.

```zig
pub const DecodeOptions = struct {
    threads: u8 = 1,
};
```

- `threads = 1` (default): run sequentially in the calling thread. No
  spawning, no oversubscription.
- `threads = 0`: explicit library-side auto-detect (capped at MCU
  rows / DRI segments).
- `threads > 1`: explicit budget. Library may use fewer if work
  doesn't amortize.

**No globals, no env vars, no implicit auto-detect.** Caller decides
every call.

Current implementation: parallel IDCT + color conversion in
`baseline.zig`. Progressive and lossless are still single-threaded
(modest images; parallel entropy decode is Amdahl-bound without DRI).

### Test fidelity threshold

- **Baseline / Progressive**: max delta ≤ 2 LSB against libjpeg-turbo
  wrapper output (sub-pixel rounding from IDCT/upsampling).
- **Lossless (any precision)**: byte-exact reconstruction
  (`expectEqualSlices(u8, ...)`). No rounding in lossless by
  definition.

### Float ban applies to all numerical paths

The progressive YCbCr was the last float in the decode pipeline. All
current cleanroom paths use integer/fixed-point only. **Do not
reintroduce floats** unless an algorithm genuinely needs them
(transcendentals etc.) and the rounding semantics are non-load-bearing.

---

## Diagnostic tooling (in `scratch/`, gitignored)

| Tool | Purpose |
|------|---------|
| `cleanroom-diff` | Walk a directory of JPEGs, classify each as CLEAN-OK / CLEAN-DIV / WRAP-ONLY / CLEAN-ERR / WRAP-ERR. Calls `internal.cleanroomDecode` (baseline). |
| `diag-one` | Per-file: try `progressiveDecode` and `wrapperDecode`, report max delta. |
| `pixel-diff` | Per-pixel diff between cleanroom (baseline OR progressive) and wrapper. Outputs histogram + 8×8-cell ASCII heatmap. |
| `dump_coefs_jpegz.zig` | Dump our progressive's natural-order quantized coefs. Calls `internal.progressiveDecodeAndDumpCoefs`. |
| `dump_coefs_libjpeg.c` | Same format using libjpeg-turbo's `jpeg_read_coefficients()`. |
| `scan_walk_diff.py` | Truncate file after each SOS+EOI, diff both decoders at each truncation. Identifies the first diverging scan. Found the M2.2e ZRL bug. |
| `bench-one` | Single-file decode timing (cleanroom vs wrapper) with hyperfine semantics. |
| `libjpeg_turbo_instr/` | Vendored libjpeg-turbo 3.1.1 source for invasive instrumentation if scan-walk isn't enough. Not needed since M2.2e shipped. |

Build any of them: `nix develop -c zig build <name>`.

`PROG_DEBUG: bool` in `src/decode/progressive.zig` flips
comptime-conditional `dbg()` printf statements throughout the
progressive decoder. Default false; flip to true for tracing.

---

## Recent commit history (most-relevant first)

```
edce8d6  docs: NEXT_STEPS — SOF3 cleanroom full coverage
649c0ae  M2.8: lossless 12/14/16-bit precision
d3fab0c  M2.7: lossless + DRI
9d2516e  M2.6: lossless 3-component RGB
ac3b787  docs: NEXT_STEPS — SOF2+DRI row
64fdb34  M2.5: progressive + DRI
7372141  docs: NEXT_STEPS — M2.3/M2.4 completion
a296a93  M2.4 hardening: 7-predictor lossless
2b70d1e  M2.4: lossless (SOF3) 8-bit grayscale
bebc28f  M2.3: SOF1 extended sequential 8-bit
f0a6d98  docs: NEXT_STEPS — M2.2 complete
bcd39de  M2.2: wire progressive into dispatch
96ddde7  M2.2e: progressive AC refine ZRL break
c1b7f32  M2.2d: progressive xi/yi single-comp iteration
1cd54ed  M2.2c: progressive IJG fancy upsampling
26dcc15  M2.2b: progressive YCbCr fixed-point
dbb9e97  M2.2a: progressive marker + insufficient_data + ZRL
```

For the broader history including M2.1c baseline corpus fixes, run
`git log yolo --oneline | head -60`.

---

## The 100%-coverage notification trigger

Peter set this trigger during M2.1d:

> "when you get basically 100% coverage of all jpeg variants, please
> let tiffz and validate know after tests are passing and CI passes"

**Trigger fires when:** every variant in the matrix above (modulo
deferred differential SOF5–7 and the explicit "out of scope" rows)
has Cleanroom: ✅, AND `./test` + Garnix CI both green, AND corpus
runs cleanly with cleanroom-only dispatch.

**Natural intermediate trigger:** "All of T.81 cleanroom complete" =
gap-closers A1, B1 done; B2 (JPEG-LS) and B3 (JP2) deferred to their
own milestones. Ask Peter when that lands whether to fire then or
hold for full T.87 + T.800 cleanroom.

**Notification inboxes** (use the `LLMsend` skill):
- `~/Documents-CloudManaged/validate/inbox/`
- `~/Documents-CloudManaged/tiffz/inbox/`

---

## Pickup tasks reference

```
#1  [completed] Wire progressive cleanroom into dispatch (M2.2)
#2  [pending]   DRI parallel fast path (performance, gap-closer #2)
#3  [completed] Extended sequential SOF1 (M2.3)
#4  [pending]   Arithmetic coding SOF9/10/11 (gap-closer #4 / B1)
#5  [pending]   JPEG-LS T.87 cleanroom (gap-closer #5 / B2)
#6  [completed] Lossless SOF3 cleanroom (M2.4+M2.6+M2.7+M2.8)
#7  [pending]   validate(...) emits warn-level findings for libjpeg
                tolerances (architecture decision; see above)
```

If the task list looks different at pickup, `TaskList` will tell you.

---

## Pickup recommendation (short version)

Pick **one** of these, in priority order. Each follows strict TDD:
write the failing test first, watch it fail, implement minimal code,
verify GREEN, commit.

1. **A1 — SOF1 12-bit** (medium-large). Reuses lossless's u16 output
   pattern; the new piece is the 12-bit IDCT. Closes the last SOF1 row.
2. **#7 — validate(...) warns** (medium). Architecture work that
   doesn't add a new variant but matters for downstream consumers.
3. **A2 — SOF3 non-1×1 sampling** (small). Tiny matrix row to close;
   good warm-up.
4. **B1 — Arithmetic SOF9** (large). Big lift but completes T.81.

Or wait for Peter's direction — he may have a preference based on
what `validate`/`tiffz` need next.

---

## Memory directory

The next LLM session inherits these auto-memory files:

- `MEMORY.md` (index)
- `reference_sibling_tmux_inbox_notify.md`
- `project_peter_jpeg_corpus.md`
- `feedback_prefer_integer_fixed_point.md`
- `feedback_validation_warns_not_silent_tolerance.md`

Read `MEMORY.md` for the one-line summaries on session start.

---

**End of handoff.** Keep this doc updated after each milestone — at
minimum, edit the variant matrix and `git log` block. The format is
designed to be skim-able in 60 seconds.
