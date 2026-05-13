# Arithmetic-coded JPEG cleanroom (B1) — Design

**Status:** SOF9 cleanroom **shipped 2026-05-13** (session 2 — gray
+ RGB all 4 sampling factors, cleanroom-vs-wrapper ≤4 LSB / ≤2 LSB
gray). SOF10 progressive deferred to a follow-on session. Approved
2026-05-13. Implements B1 from `NEXT_STEPS.md`.
**Scope:** SOF9 (extended sequential, arithmetic) and SOF10
(progressive, arithmetic). Closes T.81 spec coverage for the
Q-coder entropy path.
**Out of scope:** SOF11 (lossless arithmetic) — same A2-style
"no encoder produces it" deferral. SOF13–15 (differential arithmetic)
— same. JPEG-LS T.87 (B2) — different entropy (Golomb-Rice).

---

## Goal

Close the SOF9 and SOF10 rows of the cleanroom variant matrix. After
this milestone:

- `cjpeg -arithmetic <ppm>` (SOF9, default 4:2:0) decodes via cleanroom
  byte-equal to libjpeg-turbo wrapper (≤4 LSB tolerance per existing
  DCT-cleanroom rules).
- `cjpeg -arithmetic -progressive <ppm>` (SOF10) decodes via cleanroom
  to same tolerance.
- All 4 chroma sampling factors covered (4:4:4, 4:2:0, 4:2:2, 4:4:0).
- Grayscale fixtures included for both SOF9 and SOF10.

## Why this works (empirical viability check, 2026-05-13)

```
$ cjpeg -arithmetic in.ppm > arith_baseline.jpg     # SOF9 (FF C9)
$ cjpeg -arithmetic -progressive in.ppm > arith_prog.jpg  # SOF10 (FF CA)
$ cjpeg -arithmetic -lossless 1 in.ppm
  → "Sorry, arithmetic coding is not implemented"   # SOF11 unencodable
```

SOF9 and SOF10 both round-trip cleanly through libjpeg-turbo. SOF11
hits the same A2-style encoder gate — defer.

## Why this matters

Closes the **last remaining T.81 cleanroom row** (modulo deferred
differential variants and the unproducible SOF11). After B1 ships,
the cleanroom decoder covers the entire spec-legal Huffman + arithmetic
DCT decode universe, plus the lossless decode universe at non-sampled
modes. The "100% T.81 cleanroom" notification trigger from M2.1d fires.

## Patent status

All three Q-coder-related patents are expired as of 2026:
- IBM Q-coder family (US 4,652,856, US 4,891,643, US 5,059,976, etc.):
  filed 1985-1990, expired ~2010.
- JPEG-LS (T.87) related: expired ~2018.
- JPEG 2000 MQ-coder: IBM patents expired ~2015.

This was the historical reason JPEG arithmetic coding wasn't widely
adopted; the constraint is gone. Cleanroom decoder shipping is
unrestricted.

## Architecture

### Two new modules

```
src/decode/arith_coder.zig          (~300 LOC)
├── QCoder: pure binary arithmetic decoder state machine
│   - qe_table[113]: {qe, next_lps, next_mps, switch_mps}
│   - 16-bit range A, 32-bit code C, byte-stuffed input
│   - decode(stat_ptr) → bit (0/1), updates context state
│   ← REUSABLE for B3 (JP2 MQ-coder) via thin adapter
├── JPEG-specific binarization (T.81 §F.1.4.4.1):
│   - decodeDcDifferential(comp, prev_dc) → DC value
│   - decodeAcCoefficient(comp, k_position) → (run, amplitude)
│   - Context arrays: per-component DC (49 binary contexts) +
│     per-component AC (245 binary contexts)
└── Initial state setup + DAC reset handling

src/decode/arith_decode.zig          (~400 LOC)
├── SOF9 entry: decodeArithBaseline
│   - Parses SOS, walks MCUs via baseline.zig's existing pattern
│   - Calls arith_coder.decodeDcDifferential / decodeAcCoefficient
│     per coefficient (instead of Huffman decode)
│   - Reuses baseline.zig's `assembleOutput` for IDCT + color
├── SOF10 entry: decodeArithProgressive
│   - Parses SOS, walks multi-scan progressive entropy with arith binarization
│   - Mirrors progressive.zig's per-scan dispatch (DC-first / AC-first /
│     refinements) but with the arith versions of each binarization
│   - Reuses progressive.zig's `assembleProgressiveGeneric` for Phase 2
└── DAC marker parser
```

### Dispatch

`src/jpegz.zig` adds dispatch on SOF9 / SOF10:

```zig
const sof_marker = peek_sof(data); // 0xC9 or 0xCA
return switch (sof_marker) {
    0xC0, 0xC1 => baseline.decode(...),    // existing Huffman path
    0xC2 => progressive.decode(...),       // existing Huffman path
    0xC3 => lossless.decode(...),          // existing lossless path
    0xC9 => arith_decode.decodeArithBaseline(...),   // NEW
    0xCA => arith_decode.decodeArithProgressive(...),// NEW
    0xCB => error.NotImplemented,          // SOF11 — defer per A2 rationale
    else => error.NotImplemented,
};
```

(Actual dispatch lives in the SOF-marker switch in each cleanroom
module's decode loop, plus the top-level dispatcher in `jpegz.zig`.
Concrete plumbing decided at implementation time; structure shown
here for clarity.)

### DAC marker (T.81 §B.2.4.3)

Define Arithmetic Coding conditioning. Appears in place of DHT for
arithmetic JPEGs.

```
FF CC <length> <Tc/Tb> <Cs>
        ^^^^^^^         ^^^
        upper nibble: Tc (0=DC, 1=AC); lower: Tb (destination 0-3)
        Cs: conditioning parameter
            - DC tables (Tc=0): Cs = (U<<4) | L, magnitude category bounds
            - AC tables (Tc=1): Cs = kx, the AC-context threshold
```

Multiple DAC segments concatenate to fill the 4×2 = 8 conditioning
slots. Default values per T.81 §F.1.4.4.1.4 apply if a needed table
isn't defined.

### Q-coder state machine

Per T.81 Annex D and libjpeg's `jdarith.c`:

```zig
const QeEntry = struct {
    qe: u16,            // LPS subinterval estimate
    next_lps: u8,       // state after LPS coding
    next_mps: u8,       // state after MPS coding
    switch_mps: bool,   // MPS swap flag at this state
};
const QE_TABLE: [113]QeEntry = .{ ... }; // verbatim from T.81 Annex D

const Context = struct {
    state_index: u8,    // 0..112
    mps: u1,            // current "More Probable Symbol"
};

const QCoder = struct {
    A: u16,             // range (renormalized to 2^15..2^16)
    C: u32,             // code register
    ct: u8,             // bit counter for renormalization

    fn decode(self: *QCoder, br: *BitReader, ctx: *Context) bool {
        // T.81 §D.2.1 — binary arithmetic decode
        // Returns the decoded bit. Updates ctx (state_index, mps) per
        // qe_table transitions. Renormalizes A and C as needed.
    }
};
```

The `qe_table` is the JPEG committee's deterministic spec; matching
libjpeg byte-for-byte is the testable cleanroom-vs-wrapper ground
truth.

### DC / AC binarization

Per T.81 §F.1.4.4.1:

**DC** (each block):
1. Decide V==0 vs V≠0 (binary decision using context index based on
   prev_block_dc_magnitude_category).
2. If V≠0: decide sign (binary).
3. Then unary code for log₂(|V|) bracketing (binary decisions).
4. Then refinement bits for actual amplitude.

**AC** (per zig-zag position k from 1..63):
1. Decide END-OF-BLOCK marker at position k (binary).
2. If not EOB: decide if coef at this k is zero or not.
3. If non-zero: sign decision.
4. Magnitude category unary code (binary decisions, context-conditioned
   on k vs kx threshold).
5. Refinement bits.

Context indexing follows libjpeg's `dc_stats[]` and `ac_stats[]`
arrays. We allocate equivalent context arrays per-component on
arithmetic stream start and reset them at restart markers.

### Restart marker handling

T.81 §F.2.4.5: when a RST marker is encountered, Q-coder state
resets — A=0, C reloaded from stream, all DC predictors zeroed, all
context state_index/mps reset to initial defaults. Same per-RST cycle
0xD0..0xD7 as Huffman case.

### Reuse of Phase 2 (IDCT + assemble)

SOF9 → reuse `baseline.assembleOutput` (already comptime-P-generic
indirectly via `assembleProgressiveGeneric` — actually baseline's
assembleOutput is 8-bit-only today; we'd dispatch to it for the
8-bit arith case. cjpeg's `-arithmetic` defaults to 8-bit so this
is fine).

SOF10 → reuse `progressive.assembleProgressiveGeneric(8, ...)` for
the IDCT + color convert pass. The coefficient buffer produced by
arith entropy decode has the same shape as the Huffman one (i16
per coefficient, zig-zag ordered), so Phase 2 doesn't care which
entropy decoder filled the buffer.

This is the **payoff of the A3 refactor**: the IDCT+assemble seam is
already isolated and precision-generic.

## Testing

### Fixtures

Generated via a small `scratch/gen_arith_fixtures.sh` (similar
pattern to the gen_rgb12 / gen_prog12 scripts):

| File | SOF | Sampling | cjpeg flags |
|------|-----|----------|-------------|
| `baseline_4x4_arithmetic.jpg` | SOF9 | 4:2:0 (existing) | preserved fixture |
| `arith_baseline_16x16_rgb_444.jpg` | SOF9 | 4:4:4 | `-arithmetic -sample 1x1` |
| `arith_baseline_16x16_rgb_420.jpg` | SOF9 | 4:2:0 | `-arithmetic -sample 2x2,1x1,1x1` |
| `arith_baseline_16x16_rgb_422.jpg` | SOF9 | 4:2:2 | `-arithmetic -sample 2x1,1x1,1x1` |
| `arith_baseline_16x16_rgb_440.jpg` | SOF9 | 4:4:0 | `-arithmetic -sample 1x2,1x1,1x1` |
| `arith_baseline_8x8_gray.jpg` | SOF9 | grayscale | `-arithmetic -grayscale` |
| `arith_progressive_16x16_rgb_444.jpg` | SOF10 | 4:4:4 | `-arithmetic -progressive -sample 1x1` |
| `arith_progressive_16x16_rgb_420.jpg` | SOF10 | 4:2:0 | `-arithmetic -progressive -sample 2x2,1x1,1x1` |
| `arith_progressive_16x16_rgb_422.jpg` | SOF10 | 4:2:2 | `-arithmetic -progressive -sample 2x1,1x1,1x1` |
| `arith_progressive_16x16_rgb_440.jpg` | SOF10 | 4:4:0 | `-arithmetic -progressive -sample 1x2,1x1,1x1` |
| `arith_progressive_8x8_gray.jpg` | SOF10 | grayscale | `-arithmetic -progressive -grayscale` |

### Tests

Two parametric tests in `tests/unit/decode.zig`:

```zig
test "B1 SOF9: arithmetic baseline cleanroom (gray + RGB all sampling)" { ... }
test "B1 SOF10: arithmetic progressive cleanroom (gray + RGB all sampling)" { ... }
```

Each iterates over its 5 fixtures, asserts cleanroom byte-equals
wrapper to ≤4 LSB (≤2 LSB for grayscale, same gates as A1/A3).

## Implementation order (TDD, two sessions likely)

### Session 1: Q-coder + SOF9 baseline

1. **Fixture generation**: `scratch/gen_arith_fixtures.sh` produces
   all 11 fixtures. Verify SOF9/SOF10 markers and DAC marker presence.
   Commit fixtures.

2. **RED — failing SOF9 test**: 5 fixtures × byte-equal-to-wrapper
   ≤4 LSB. Current HEAD has no SOF9 dispatch — falls through to
   wrapper.

3. **GREEN1a — Q-coder kernel**: `src/decode/arith_coder.zig` with
   the `QE_TABLE` ported byte-for-byte from libjpeg `jdarith.c`,
   `Context` struct, `QCoder.decode(stat_ptr)` returning bits.
   Inline unit test: feed a hand-crafted bit sequence, assert correct
   bits decoded.

4. **GREEN1b — DC/AC binarization**: per T.81 §F.1.4.4.1 — DC
   differential decode (unary mag-category + sign + magnitude bits)
   and AC coefficient decode (EOB / run / mag-category / sign /
   magnitude). Context indexing per libjpeg `dc_stats[]` / `ac_stats[]`.

5. **GREEN1c — DAC marker parser**: parse FF CC segments, populate
   the 8 conditioning slots. Defaults per T.81 §F.1.4.4.1.4 when
   needed slot is undefined.

6. **GREEN1d — SOF9 dispatch**: `decodeArithBaseline` in
   `arith_decode.zig`. Reuses baseline's MCU walk shape + assembleOutput.
   SOF9 test goes green.

7. **Commit session 1**: SOF9 cleanroom shipped.

### Session 2: SOF10 progressive

8. **RED — failing SOF10 test**: 5 progressive fixtures.

9. **GREEN2a — progressive arithmetic binarization**: the per-scan
   variants (DC-first, AC-first, DC-refinement, AC-refinement) with
   arith-encoded successive approximation per T.81 §G.1.

10. **GREEN2b — SOF10 dispatch**: `decodeArithProgressive` in
    `arith_decode.zig`. Reuses `assembleProgressiveGeneric(8, ...)`
    for Phase 2.

11. **REFACTOR**: tidy, full suite green, update NEXT_STEPS.md
    (matrix rows for SOF9/SOF10 → ✅, fire the 100%-coverage trigger
    if Peter agrees), commit.

## Risks / unknowns

- **Q-coder byte-stuffing**: 0xFF input bytes in arithmetic streams
  follow JPEG's marker-byte escape convention (0xFF 0x00 = literal
  0xFF). libjpeg handles this via `process_restart`. We must mirror.
- **Initial Q-coder state at scan start**: A and C must be initialized
  per T.81 §F.1.4.4.4. Specifically C is filled by reading the first
  4 bytes of the entropy stream. Subtle.
- **DAC marker defaults**: per T.81 §F.1.4.4.1.4, if a needed DAC slot
  isn't defined, defaults apply: DC = (0, 1), AC = (5). We MUST
  initialize all 8 slots with defaults at scan start and let DAC
  markers override.
- **Restart state**: per T.81 §F.2.4.5, Q-coder state, DC predictors,
  and ALL contexts reset on RST. ALL contexts means every byte of the
  per-component dc_stats / ac_stats arrays goes back to initial.
- **Progressive refinement scans**: T.81 §G.1.2.3.2 specifies arith
  refinement with a slightly different conditioning context than DC
  initial. Easy to miss; the libjpeg jdarith.c reference is the
  byte-truth.
- **Multi-component scan interleave**: per T.81 §A.2.4, arith MCU walk
  identical to Huffman MCU walk — context lookup keys off component
  index, not interleave position.

## References

- T.81 §F.1.4 (arithmetic entropy coding), §F.1.4.4.1 (DC/AC
  binarization), §F.2.4 (arith decoder pseudocode), §G.1 (progressive
  arith), Annex D (Q-coder spec)
- T.81 §B.2.4.3 (DAC marker syntax)
- libjpeg-turbo `jdarith.c` (782 LOC, decoder reference, Apache-2)
- libjpeg-turbo `jcarith.c` (encoder reference, for context-table
  layouts)
- Pennebaker & Mitchell, "JPEG: Still Image Data Compression Standard",
  ISBN 0-442-01272-1 — the canonical book, ch. 12-14 cover the
  Q-coder. Free PDFs circulate.
- A3 spec for Phase 2 reuse pattern:
  `docs/superpowers/specs/2026-05-13-sof2-12bit-progressive-design.md`

## Session 1 progress checkpoint (commit, 2026-05-13)

Shipped:
- 10 fixtures (5 SOF9 + 5 SOF10) generated by `scratch/gen_arith_fixtures.sh`.
- `src/decode/arith_coder.zig` — Q-coder kernel with 113-entry
  `QE_TABLE` ported byte-for-byte from `jaricom.c`. 4 inline tests
  (table anchors, init state, byte-stuffing escape, marker detection).
- `src/decode/arith_decode.zig` — module stub. `decode()` returns
  `error.NotImplemented`.
- `internal.arithDecode` public-surface entry point in `jpegz.zig`.
- Build target `decode_arith_coder` exercises the Q-coder inline tests.
- Placeholder test embedding the 5 SOF9 fixtures (wrapper round-trip).

**Not yet shipped — pickup for next session:**
- DC/AC binarization (the meat). Translating libjpeg's
  `decode_mcu_DC_first` / `decode_mcu_AC_first` to indexed Zig was
  hitting interpretation issues in mid-session. **Required reading
  before resuming**: T.81 §F.1.4.4.1.1 (DC magnitude category
  encoding, Fig. F.19 → F.24), §F.1.4.4.1.2 (AC, Fig. F.20–F.24).
- Open issue noted mid-session: trace-walking SSSS=2 vs SSSS=3
  through libjpeg's `m` accumulator produced inconsistencies with
  T.81 Table F.1 magnitude ranges. **Next session should start by
  building a tiny truth-table fixture** (e.g., a hand-crafted 1×1
  arithmetic JPEG with known DC differential = ±1, ±2, ±3) and
  step-tracing through libjpeg via gdb to nail down the exact m
  convention before writing Zig. Spec interpretation here is the
  load-bearing prerequisite — not the Zig translation.
- DAC marker parser (small once binarization is clear).
- SOF9 dispatcher (`decodeArithBaseline`) + jpegz.zig SOF9 route.
- Then SOF10 (Session 2 as originally planned).

## Open questions resolved

- **Scope**: SOF9 + SOF10 in one milestone, two sessions. SOF11
  deferred — same A2 rationale (no encoder produces it).
  (Peter, 2026-05-13)
- **Q-coder implementation strategy**: port `qe_table` byte-for-byte
  from libjpeg-turbo (the deterministic state machine IS the JPEG
  committee's spec — no creative latitude); write our own Zig code
  structure around it. (Peter, 2026-05-13)
- **Code organization**: two new files —
  `src/decode/arith_coder.zig` (Q-coder kernel, JPEG-binarization)
  + `src/decode/arith_decode.zig` (SOF9 + SOF10 entry points,
  reusing baseline/progressive Phase 2). (Peter, 2026-05-13)
- **Q-coder kernel reusability for B3 (JP2 MQ-coder)**: factor the
  pure binary arithmetic decoder (state machine + qe_table) separately
  from the JPEG-specific binarization, so B3 can wrap the kernel with
  MQ adapter without duplicating the renormalization logic.
  (Peter, 2026-05-13)
