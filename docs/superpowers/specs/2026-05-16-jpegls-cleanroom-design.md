# JPEG-LS (T.87) cleanroom — Design (B2.2)

**Status:** Approved 2026-05-16. Implements B2.2 from
`NEXT_STEPS.md`. B2.1 (charls wrapper) shipped 2026-05-15 (commit
`c3b1324`) — provides the runtime path today and the test oracle
for this milestone.

**Scope:** Pure-Zig decoder for JPEG-LS lossless (NEAR=0) at 8-bit
and 16-bit precision, 1- and 3-component, sample-interleaved and
none-interleaved (planar). Matches charls byte-exact for every
fixture in scope (lossless reconstruction is bit-exact by spec —
no LSB tolerance).

**Out of scope (v1):**
- Near-lossless mode (NEAR > 0). Spec-supported but adds a quantizer
  to every error-magnitude path; defer to v2 once a consumer asks.
- Line-interleaved color (interleave mode 1). Less common than
  sample-interleaved; defer until a fixture needs it.
- 12-bit precision. Allowed by T.87 but rare; current charls test
  matrix covers 8 and 16, so we mirror.
- SPIFF header (T.87 Annex F). charls peeks/skips it transparently;
  if a fixture includes one we'll surface it as INFO via validate.

**Sessions:** 4 sessions estimated. Breakdown in §"Session
breakdown" below. Each session ships a green commit.

---

## Why now (and what charls bought us)

The B2.1 wrapper gave us:
1. A runtime path so consumers (validate, tiffz) aren't blocked.
2. **An encoder + a reference decoder** in one BSD-3 package. We
   generate test fixtures from known patterns via charls' encoder
   (`scratch/gen_jpegls_fixtures.c` already exists), then assert
   our cleanroom decode produces those exact patterns back.
3. A diff oracle for **partial implementations**: the cleanroom can
   decode a header-only or single-row-only fixture and compare to
   charls' decode of the same prefix.

Lossless means **no LSB tolerance**: every decoded sample must
equal the encoder's input bit-exactly. This is stricter than the
DCT cleanrooms but actually easier to debug — a single off pixel
points at a single mis-decoded code.

---

## T.87 algorithm primer

JPEG-LS is fundamentally different from every other codec we've
built:

| Property | DCT JPEGs (T.81) | Lossless JPEG (SOF3) | JPEG-LS (T.87) |
|---|---|---|---|
| Transform | 8×8 DCT | None (predictor) | None (predictor) |
| Predictor | DC-only differential | 7 fixed selectors | LOCO-I (MED) |
| Entropy | Huffman / Q-coder | Huffman | Golomb-Rice + J-codes |
| Context model | None | None | 365 contexts × per-context state |
| Block-structured | Yes (MCUs) | No (per-sample) | No (per-sample) |
| Markers | SOI, SOFn, DHT/DAC, DQT, SOS, EOI | Same | SOI, **SOF55**, **LSE**, SOS, EOI |

### LOCO-I (LOw COmplexity LOssless Image compression) overview

For each sample `Ix`:

1. **Determine neighbors** in the causal template:
   ```
       Rc  Rb  Rd
       Ra  Ix
   ```
   Where `Ra` = west, `Rb` = north, `Rc` = north-west, `Rd` =
   north-east. (At image edges, neighbors that don't exist are
   replaced per T.87 §A.1.2.)

2. **Predict `Ix`** using MED (Median Edge Detection):
   ```
   Px = if Rc >= max(Ra, Rb): min(Ra, Rb)
        else if Rc <= min(Ra, Rb): max(Ra, Rb)
        else: Ra + Rb - Rc
   ```

3. **Form context** from local gradients:
   ```
   D1 = Rd - Rb,  D2 = Rb - Rc,  D3 = Rc - Ra
   ```
   Each `Di` quantized to one of 9 regions by thresholds T1, T2,
   T3. The tuple `(Q1, Q2, Q3)` ∈ {-4..4}³ maps to a context index
   `Q ∈ {0..364}` (363 unique + 1 reserved for run + 1 unused).
   See §"Context quantization" below.

4. **Two modes** based on `Q`:
   - **Q == 0** (i.e. Q1==Q2==Q3==0, the smooth region) → **run mode**.
   - Otherwise → **regular mode**.

### Regular mode (per-sample encode/decode)

Per-context state (kept in 365 entries):
- `A[Q]` — accumulated absolute prediction errors, used to select `k`.
- `B[Q]` — signed running bias.
- `N[Q]` — occurrence count.
- `C[Q]` — bias correction (integer added to `Px`).

**Encode** (charls/T.87 §A.5):
1. Compute `Px`.
2. **Sign-flip context** if needed (T.87 §A.3.4): if the canonical
   context ordering says this `(Q1, Q2, Q3)` is the "negative
   twin", flip `(Q1, Q2, Q3) → (-Q1, -Q2, -Q3)` and remember
   `SIGN = -1`. Otherwise `SIGN = +1`. Halves the context count.
3. **Bias correction**: `Px = Px + SIGN * C[Q]`. Clamp to `[0, MAXVAL]`.
4. Compute `Errval = SIGN * (Ix - Px)`.
5. **Modulo reduce** `Errval` into `[-RANGE/2, RANGE/2)`:
   `if Errval < 0: Errval += RANGE; if Errval >= RANGE/2: Errval -= RANGE`.
   (RANGE = MAXVAL + 1.)
6. **Compute `k`**: smallest `k` such that `N[Q] << k >= A[Q]`.
   Equivalently, count leading zeros.
7. **Map signed → unsigned** for Golomb-Rice:
   `MErrval = if Errval >= 0: 2*Errval else: -2*Errval - 1`
   (T.87 §A.5.2). Plus a tweak when `k==0` and `Errval` would round
   to zero — see "Sign handling at k=0" trap.
8. **Encode** `MErrval` as Golomb-Rice with parameter `k`.

**Decode** (mirror):
1. Compute `Px`, form context, apply sign-flip + bias correction.
2. Compute `k` from current `(N[Q], A[Q])`.
3. Read Golomb-Rice code → `MErrval`.
4. Map unsigned → signed `Errval`.
5. Reverse modulo: `if Errval < something_threshold: Errval += RANGE`.
6. `Ix = (Px + SIGN * Errval) mod RANGE`.
7. **Update state**:
   - `B[Q] += Errval`
   - `A[Q] += abs(Errval)`
   - `N[Q] += 1`
   - If `N[Q] >= RESET`: halve `A`, `B`, `N` (decimation).
   - Update `C[Q]` per T.87 §A.6.1 bias-correction rules.

### Run mode (T.87 §A.7)

Triggered when `Q1==Q2==Q3==0`. The encoder writes a **run length**
(number of consecutive samples equal to `Ra`), then either:
- An **end-of-line** marker (no interruption — the run hit the row
  boundary).
- A **run interruption sample** — the next non-Ra sample, encoded
  with its own dedicated context (1 of 2 — see "RIType" below).

Run lengths use **J-codes** (T.87 §A.7.1): a length-prefix coded
table indexed by `RUNindex` ∈ {0..31}, which dynamically grows on
long runs.

Decoder logic:
1. While in run: read 1 bit. If 1, the run continues for `1 << J[RUNindex]`
   samples. Bump `RUNindex` (capped at 31). Repeat.
2. If bit is 0, read `J[RUNindex]` more bits — this is the residual
   run length. Total run = (previous bumps) + residual.
3. If we hit end-of-line before the run terminates, no interruption
   sample is decoded. Otherwise the next sample is the "run
   interruption" sample, decoded via its own context (RItype = 0
   or 1) and updated separately.

### Context quantization

Default thresholds for 8-bit (`MAXVAL = 255`):
- `T1 = 3, T2 = 7, T3 = 21`

For arbitrary MAXVAL (T.87 Eq. A.8):
```
if MAXVAL >= 128:
    BPP = ceil(log2(MAXVAL + 1))  // bits per pixel
    FACTOR = (min(MAXVAL, 4095) + 128) >> 8
    T1 = clamp(FACTOR * 2 + 3, NEAR + 3, MAXVAL)
    T2 = clamp(FACTOR * 7 + 7 - 2*NEAR, T1, MAXVAL)
    T3 = clamp(FACTOR * 21 + 21 - 3*NEAR, T2, MAXVAL)
```

Quantization (T.87 §A.3.3):
```
fn quantize(D, T1, T2, T3, NEAR) -> i32:
    if D <= -T3: return -4
    if D <= -T2: return -3
    if D <= -T1: return -2
    if D <  -NEAR: return -1
    if D <=  NEAR: return  0
    if D <   T1:   return  1
    if D <   T2:   return  2
    if D <   T3:   return  3
    return 4
```

Context index calculation (T.87 §A.3.5): the tuple `(Q1, Q2, Q3)`
is mapped to a unique `Q ∈ [0..364]` via:
```
Q = 81 * Q1 + 9 * Q2 + Q3 (+ 365 offset)
```
…but with sign canonicalization so `(Q1, Q2, Q3)` and `(-Q1, -Q2, -Q3)`
share the same index. The implementation uses a table or fast
branch — see `charls/src/jls_codec_factory.h`.

---

## Architecture

### File layout (proposed)

```
src/decode/
  jpegls.zig          — public entry point (decode + marker walk)
  jpegls_codec.zig    — LOCO-I codec: predictor, context, Golomb-Rice
                        regular + run mode. Pure functions over a
                        ScanState struct (analogous to arith_coder.zig
                        for arithmetic JPEG).
  jpegls_bitstream.zig — JPEG-LS bit reader. Different from
                        decode/bitstream.zig because:
                        (a) no 0xFF stuffing inside JPEG-LS entropy
                            (JPEG-LS uses 0xFF byte-stuffing rules
                            from T.87 §A.1.3 — different from T.81),
                        (b) Golomb-Rice unary decode is the hot path,
                            wants a fast `count_leading_zeros` helper.
```

`src/jpegz.zig`: add cleanroom dispatch BEFORE the charls wrapper
fall-through. Marker peek (`looksLikeJpegLs` from `charls_wrapper`)
already classifies; we just need to call our cleanroom first and
fall through to charls on NotImplemented.

### Public API

```zig
// src/decode/jpegls.zig
pub fn decode(allocator: Allocator, data: []const u8) Error!types.Image;
```

Same signature as every other decode entry. Returns
`error.NotImplemented` for variants we don't yet cleanroom (NEAR>0,
line-interleaved, 12-bit) — charls wrapper picks up the slack.

---

## Algorithm detail (Zig implementation skeletons)

### Markers

```zig
// JPEG-LS marker bytes (T.87 Table A.1):
//   SOI    = 0xD8  (shared with T.81)
//   SOF55  = 0xF7  (the only SOF used by JPEG-LS)
//   LSE    = 0xF2  (Define Mapping Table / Bias / etc.)
//   SOS    = 0xDA  (shared)
//   EOI    = 0xD9  (shared)
//   DRI    = 0xDD  (shared, optional)
//   COM    = 0xFE  (shared, optional)
//   APPn   = 0xE0..0xEF (shared, optional)
//
// LSE subtypes (T.87 §C.2.4): selector byte after length:
//   1 = Mapping table specification (rare; we skip)
//   2 = Mapping table continuation (rare; we skip)
//   3 = X-extended mapping table specification (rare)
//   4 = JPEG-LS preset coding parameters — MAXVAL, T1, T2, T3, RESET
//
// For v1, only LSE subtype 4 affects the codec; subtypes 1-3 can
// be skipped (only matter for transcoder applications).
```

### Frame header (SOF55) — T.87 §C.2.2

```
SOF55 ::= FF F7  LENGTH(2)  P(1)  Y(2)  X(2)  Nf(1)
          {Ci(1) Hi(1):Vi(1) Tqi(1)}*Nf
```

`P` is precision in bits, `Y` and `X` are dimensions, `Nf` is
number of components, `Hi/Vi` sampling factors (always 1×1 in
v1), `Tqi` reserved (must be 0). Tqi is parsed but ignored.

### SOS (T.87 §C.2.3)

```
SOS ::= FF DA  LENGTH(2)  Ns(1)  {Cj(1) (Tdj:Taj)(1)}*Ns  NEAR(1)  ILV(1)  Al:Ah(1)
```

`NEAR` is the near-lossless parameter (0 for v1).
`ILV` is the interleave mode (0 = none/planar, 1 = line,
2 = sample). We support 0 and 2.

### ScanState struct (jpegls_codec.zig)

```zig
pub const ScanState = struct {
    // Per-context regular-mode state (T.87 §A.3.4).
    // 365 entries: 0 is reserved for run mode; 1..364 are regular.
    // Plus 2 extra slots for run-interruption contexts.
    A: [367]u32,   // accumulated abs(error) — 32 bits for headroom
    B: [367]i32,   // bias (signed) — separately maintained per ctx
    C: [367]i8,    // correction
    N: [367]u32,   // occurrence count
    // Run-mode J table state (T.87 §A.7.1):
    run_index: [2]u8,  // RItype indexes into J[2][32]
    // Frame parameters (filled by SOF55 + LSE-4 parsing).
    MAXVAL: u32,
    NEAR: u32,
    T1: u32, T2: u32, T3: u32,
    RESET: u32,
    qbpp: u8,      // quantized bits per pixel (T.87 §A.2.1)
    bpp: u8,       // bits per pixel from precision (typically 8 or 16)
    LIMIT: u8,     // unary-limit for k=0 (T.87 §A.5.3)
    // Reader state.
    reader: BitReader,
};

pub fn init(state: *ScanState, bpp: u8, near: u32) void {
    // Reset all A/B/C/N counters per T.87 §A.8.
    // Compute T1, T2, T3 from bpp/NEAR if defaults are in effect.
    // ...
}
```

### Bit reader (jpegls_bitstream.zig)

JPEG-LS byte-stuffing rule (T.87 §A.1.3): after any byte ≥ 0x80,
the encoder may have inserted a zero bit before the next byte
boundary to prevent a future 0xFF marker. Specifically:
- If the LAST written byte is 0xFF, the encoder writes a 0 bit
  before continuing, then the next 7 bits, etc.
- Reader rule: after consuming an 0xFF byte (as data, not marker),
  read 1 bit but **discard** it before resuming normal reads.

This is **different** from T.81's 0xFF 0x00 stuffing — JPEG-LS
stuffs **a bit**, not a byte. The bit reader's `peek` / `consume`
loops must handle this.

```zig
pub const BitReader = struct {
    data: []const u8,
    pos: usize,
    buf: u64,           // bit accumulator, MSB-first
    valid: u6,          // bits in buf
    marker_seen: bool,
    marker_byte: u8,

    /// Read up to 32 bits. MSB-first. Refills from data as needed.
    pub fn readBits(self: *BitReader, n: u6) u32;
    /// Read a unary code (count of 1-bits followed by a 0). The
    /// 0 is consumed. Used in Golomb-Rice decode.
    pub fn readUnary(self: *BitReader, limit: u8) u32;
};
```

### Predictor

```zig
inline fn predictMed(ra: i32, rb: i32, rc: i32) i32 {
    if (rc >= @max(ra, rb)) return @min(ra, rb);
    if (rc <= @min(ra, rb)) return @max(ra, rb);
    return ra + rb - rc;
}
```

### Context quantization

```zig
inline fn quantize(d: i32, t1: i32, t2: i32, t3: i32, near: i32) i32 {
    if (d <= -t3) return -4;
    if (d <= -t2) return -3;
    if (d <= -t1) return -2;
    if (d <  -near) return -1;
    if (d <=  near) return  0;
    if (d <   t1) return 1;
    if (d <   t2) return 2;
    if (d <   t3) return 3;
    return 4;
}

inline fn contextIndex(q1: i32, q2: i32, q3: i32) struct { q: usize, sign: i8 } {
    // Canonicalize so (q1,q2,q3) and -(q1,q2,q3) share an index.
    // T.87 §A.3.6 sign rule:
    //   if q1 < 0 or (q1 == 0 and q2 < 0) or (q1 == 0 and q2 == 0 and q3 < 0):
    //     negate all three, sign = -1
    //   else: sign = +1
    // Then index = 81 * (q1+4) + 9 * (q2+4) + (q3+4)  — and prune to 365.
    // (The canonical mapping table is 9*9*9=729 entries; half are
    // mirrored, leaving 365.)
}
```

### Regular-mode decode loop

```zig
pub fn decodeRegularSample(state: *ScanState, ra: i32, rb: i32, rc: i32, rd: i32) i32 {
    // 1. Context.
    const d1 = rd - rb;
    const d2 = rb - rc;
    const d3 = rc - ra;
    const q1 = quantize(d1, state.T1, state.T2, state.T3, state.NEAR);
    const q2 = quantize(d2, state.T1, state.T2, state.T3, state.NEAR);
    const q3 = quantize(d3, state.T1, state.T2, state.T3, state.NEAR);
    // Q1=Q2=Q3=0 → run mode; caller routes around this fn.
    const ctx = contextIndex(q1, q2, q3);

    // 2. Predict + bias-correct.
    var px = predictMed(ra, rb, rc);
    px += @as(i32, state.C[ctx.q]) * ctx.sign;
    px = @max(0, @min(@as(i32, state.MAXVAL), px));

    // 3. Compute k.
    var k: u5 = 0;
    while ((@as(u32, state.N[ctx.q]) << k) < state.A[ctx.q]) : (k += 1) {}

    // 4. Decode Golomb-Rice → MErrval.
    const merrval = decodeGolombRice(&state.reader, k, state.LIMIT, state.qbpp);

    // 5. Map MErrval → Errval (T.87 §A.5.2 inverse).
    var errval: i32 = if (merrval & 1 != 0)
        -(@as(i32, @intCast(merrval)) + 1) >> 1
    else
        @as(i32, @intCast(merrval)) >> 1;
    // Sign correction for k=0 zero rounding (see traps).

    // 6. Reconstruct sample (mod RANGE).
    var ix: i32 = px + ctx.sign * errval;
    if (ix < 0) ix += @as(i32, state.MAXVAL) + 1;
    if (ix > state.MAXVAL) ix -= @as(i32, state.MAXVAL) + 1;

    // 7. Update state (A, B, N, C). T.87 §A.6.
    state.A[ctx.q] += @abs(errval);
    state.B[ctx.q] += errval * ctx.sign;
    state.N[ctx.q] += 1;
    if (state.N[ctx.q] >= state.RESET) {
        state.A[ctx.q] >>= 1;
        state.B[ctx.q] = (state.B[ctx.q] + 1) >> 1;
        state.N[ctx.q] >>= 1;
    }
    updateBiasCorrection(state, ctx.q);

    return ix;
}
```

### Golomb-Rice decode

```zig
fn decodeGolombRice(reader: *BitReader, k: u5, limit: u8, qbpp: u8) u32 {
    const high = reader.readUnary(limit);
    if (high < limit - qbpp - 1) {
        // Standard Golomb-Rice: high * 2^k + low.
        const low = reader.readBits(k);
        return (high << k) | low;
    } else {
        // Escape: large value, read qbpp bits then add (qbpp + 1).
        const escape = reader.readBits(qbpp);
        return escape + 1;
    }
}
```

### Run mode

```zig
fn decodeRun(state: *ScanState, ra: i32, samples_remaining_in_line: u32,
             out: []u8) u32 {
    var count: u32 = 0;
    // While bit == 1, the run extends by 2^J[run_index] samples.
    while (state.reader.readBits(1) == 1) {
        const step: u32 = @as(u32, 1) << @intCast(J_TABLE[state.run_index[0]]);
        count += step;
        if (count >= samples_remaining_in_line) {
            // End-of-line — no run-interruption sample.
            count = samples_remaining_in_line;
            // Cap run_index.
            if (state.run_index[0] < 31) state.run_index[0] += 1;
            // Fill with Ra. Caller handles the actual write.
            return count;
        }
        if (state.run_index[0] < 31) state.run_index[0] += 1;
    }
    // Read residual bits (J[run_index] bits).
    const residual = state.reader.readBits(@intCast(J_TABLE[state.run_index[0]]));
    count += residual;
    // Bump run_index down? No — run_index decrements only after
    // a run *interruption*, not within a run.
    return count;
}

fn decodeRunInterruption(state: *ScanState, ra: i32, rb: i32) i32 {
    // Choose RItype: 0 if abs(ra - rb) <= NEAR, 1 otherwise.
    const rt: u1 = if (@abs(ra - rb) <= state.NEAR) 0 else 1;
    // ... Golomb-Rice decode using a separate per-RItype context ...
}
```

(Run mode is the gnarliest part — see traps for the run_index
decrement rule on interruption.)

---

## TDD plan

Tests sit in `tests/unit/decode.zig` (same file as the wrapper
tests). Each cleanroom test asserts **byte-exact** match against
the original PPM/PGM input — JPEG-LS at NEAR=0 is lossless, so
there's no LSB tolerance to worry about.

### Test fixtures (extending what B2.1 already shipped)

Existing (`gen_jpegls_fixtures.c` extended for these):
- `jpegls_4x4_gray8.jls` — 4×4 grayscale gradient (B2.1).
- `jpegls_4x4_gray16.jls` — 4×4 16-bit grayscale (B2.1).
- `jpegls_4x4_rgb8.jls` — 4×4 RGB sample-interleaved (B2.1).

New for B2.2:
- `jpegls_16x16_gray8.jls` — bigger gradient + a "constant" row
  (exercises run mode and end-of-line interrupt).
- `jpegls_16x16_constant_gray8.jls` — all-zero (full run, no
  interruption, just end-of-line handling).
- `jpegls_8x8_random_gray8.jls` — pseudo-random bytes (exercises
  regular-mode k progression).
- `jpegls_4x4_gray16.jls` — verifies 16-bit works.

### RED → GREEN gate per session

Each session's gate is one new fixture passing while all previous
fixtures still pass. Test names:

- `B2.2 §1: JPEG-LS 4x4 gray8 cleanroom (regular mode only)`
- `B2.2 §2: JPEG-LS 16x16 gray8 with run mode`
- `B2.2 §3: JPEG-LS 4x4 RGB8 sample-interleaved`
- `B2.2 §4: JPEG-LS 4x4 gray16`

---

## Session breakdown

### Session 1 — Skeleton + marker parser + regular-mode 8-bit gray

Goal: decode a 4×4 8-bit grayscale gradient (no run mode triggered
because the first column has Ra==0 → context 0 → run, but we can
craft a gradient that avoids it, OR implement just enough of run
mode to handle the "all neighbors zero at start of row" case).

Tasks:
1. `src/decode/jpegls_bitstream.zig`: BitReader with JPEG-LS bit-
   stuffing rules. Inline tests for known sequences.
2. `src/decode/jpegls_codec.zig`: ScanState struct, init function,
   `predictMed`, `quantize`, `contextIndex`, `decodeRegularSample`,
   `decodeGolombRice`, bias-correction update.
3. `src/decode/jpegls.zig`: marker walker, SOF55/LSE/SOS parsing,
   `decode()` entry point that handles 1-component 8-bit only.
4. Dispatch in `src/jpegz.zig`: try cleanroom before charls wrapper.
5. RED test against a fixture chosen so the gradient avoids
   triggering long runs. GREEN.

Estimated: ~700 LOC.

### Session 2 — Run mode + bigger gray fixtures

Goal: decode a 16×16 grayscale with smooth regions (run mode
triggered + run interruption).

Tasks:
1. `decodeRun` + `decodeRunInterruption` in jpegls_codec.zig.
2. J-table for run-length codes (T.87 §A.7.1, 32-entry table).
3. End-of-line handling: when a run reaches the row boundary
   without interruption, no run-interrupt sample is decoded.
4. Run_index decrement-on-interruption rule (T.87 §A.7.2).
5. RED test against `jpegls_16x16_gray8.jls`. GREEN.

Estimated: ~400 LOC.

### Session 3 — Multi-component RGB (sample-interleaved)

Goal: 3-component 8-bit RGB at interleave mode 2 (sample-
interleaved). Per-component state is REPLICATED — each component
has its own (A, B, C, N) arrays for the 365 contexts. Run-index
state and J-table state are SHARED across all components within
a sample.

Tasks:
1. Extend ScanState to per-component arrays.
2. Sample iteration order: for each y, x: decode R, G, B at (x, y).
3. Per-component neighbors: `Ra = pixels[(y) * stride + (x-1) * 3 + ci]`, etc.
4. RED test against `jpegls_4x4_rgb8.jls`. GREEN.

Estimated: ~200 LOC.

### Session 4 — 16-bit precision + polish

Goal: 16-bit grayscale and RGB pass. Polish: error reporting,
LSE-4 preset-parameter parsing, validate-warns surface for JPEG-LS.

Tasks:
1. Verify the codec is precision-generic (`MAXVAL` should already
   drive everything — confirm no hardcoded `255`).
2. T1/T2/T3 recompute for 16-bit per T.87 Eq. A.8 (FACTOR formula).
3. LSE-4 marker parsing (override default MAXVAL/T1/T2/T3/RESET).
4. RED test against `jpegls_4x4_gray16.jls`. GREEN.
5. Remove charls dispatch precedence for variants now cleanroomed
   (keep wrapper as fallback for NEAR>0 and line-interleaved).

Estimated: ~300 LOC.

---

## Traps & gotchas

Compiled from charls source (`src/jls_codec_factory.cpp`,
`src/process_line.cpp`) and T.87 § A errata:

### 1. Sign handling at k=0

When `k == 0`, the Golomb-Rice map has a quirk: `MErrval` of an
even number maps to a *positive* Errval, odd to a *negative* one.
But the encoder also does a "round to nearer" tweak that the
decoder must mirror exactly. See T.87 §A.5.2 footnote.

### 2. C[Q] update is asymmetric

Bias correction (`C[Q]`) is updated by **comparing** `B[Q]` to
`-N[Q]` and `0`, and incrementing or decrementing `C` by 1
accordingly. Clamping is to `[-128, 127]`. Easy to get the
direction backwards — verify against charls' `update_variables`
function.

### 3. Run_index advance/retreat rules

- Inside a run (bit = 1 path): advance `run_index` (cap at 31)
  AFTER each successful continuation.
- After a run terminates with an **interruption sample**:
  `run_index = max(0, run_index - 1)`.
- After end-of-line: leave `run_index` advanced (no decrement).
- T.87 §A.7 is dense; charls' `decode_run_pixels` is the
  unambiguous reference.

### 4. End-of-line interrupt vs. interruption

At end-of-row mid-run: don't try to decode a run-interrupt sample;
the run was simply terminated by the line boundary. Easy off-by-
one bug if you check `samples_remaining` after the bump.

### 5. JPEG-LS bit-stuffing is BITS, not bytes

T.87 §A.1.3: after a 0xFF byte in the entropy stream, the encoder
writes a 0 bit before the next 7 bits of payload. Decoder must
read and DISCARD that bit. Unlike T.81's 0xFF 0x00 byte stuffing.
Our existing `bitstream.BitReader` (used by Huffman) is wrong for
JPEG-LS — need a separate `jpegls_bitstream.BitReader`.

### 6. Marker discovery inside entropy

Just like T.81, a real marker (0xFF NN where NN > 0) inside the
entropy stream means end-of-scan. JPEG-LS allows fewer markers
inline than T.81 — typically just EOI — but the bit reader's
refill logic must still bail out cleanly when a non-zero byte
follows 0xFF.

### 7. RANGE for modulo reduction

`RANGE = MAXVAL + 1`. For 8-bit, `RANGE = 256`. The modulo
reduction wraps Errval into `[-RANGE/2, RANGE/2)`. Easy bug:
using `RANGE = MAXVAL` (off by one).

### 8. Per-component state in 3-channel scans

Each component has its own (A, B, C, N) arrays. Run-index and the
run interruption contexts are also per-component. (T.87 §A.3.5:
"Each context table shall be processed independently for each
component.") Easy bug: sharing one ScanState across components.

### 9. LIMIT for the unary part

`LIMIT = 2 * (bpp + max(8, bpp)) - qbpp - 1` (T.87 §A.5.3, eq.
A.18). At 8-bit: `LIMIT = 23`. If the unary value reads more than
`LIMIT - qbpp - 1` ones, we're in the escape branch (large value
encoded directly). Easy bug: confusing `LIMIT` and `qbpp`.

### 10. Mapping table LSE subtypes (1, 2, 3) silently skipped

For NEAR=0 lossless without a custom palette, only subtype 4
(preset coding parameters) matters. Subtypes 1–3 (mapping tables)
are for transcoder use cases; ignoring them is correct for v1.
Document this explicitly in the LSE parser — if a fixture relies
on it, our decode is silently wrong.

---

## References

### Normative
- **ITU-T T.87 (1998) | ISO/IEC 14495-1:1999** — JPEG-LS spec.
  Free download: <https://www.itu.int/rec/T-REC-T.87/en>.
- **T.87 Annex A** — algorithm specification (LOCO-I).
- **T.87 Annex C** — marker syntax.

### Implementations consulted (cleanroom rules — read for spec
clarification, not for code copy)
- **charls** (BSD-3) — our test oracle. Key files:
  - `src/jls_codec_factory.cpp` — high-level codec dispatch.
  - `src/process_line.cpp` — per-line regular/run mode driver.
  - `src/run_mode_processor.cpp` — run mode + interruption.
  - `src/golomb_lut.cpp` — Golomb-Rice tables.
  - `src/jpeg_marker_segment.cpp` — marker parsing.
- **HP LOCO-I reference paper** (Weinberger, Seroussi, Sapiro 1996)
  — original algorithm description; useful for the bias-correction
  rationale.

### Internal
- `docs/superpowers/specs/2026-05-13-arithmetic-coded-jpeg-design.md`
  — sister milestone (B1 arithmetic). Same multi-session structure
  used here.
- `src/ffi/charls_wrapper.zig` — B2.1, the runtime path today.
- `scratch/gen_jpegls_fixtures.c` — fixture generator (extend for
  Sessions 2-4 fixtures).

---

## Done criteria for B2.2

- ✅ Sessions 1-4 all GREEN.
- ✅ Cleanroom decode byte-exact vs original PPM/PGM for all v1
  fixtures (1- and 3-component, 8 and 16-bit, NEAR=0,
  sample-interleaved and none-interleaved).
- ✅ `internal.jpeglsDecode` exposed for diff-against-charls tooling.
- ✅ NEXT_STEPS.md and the variant matrix updated.
- ✅ `./test` green; `./fuzz` smoke replay green over all JPEG-LS
  fixtures.
- ✅ charls wrapper retained as fallback for NEAR>0 and
  line-interleaved (until those are also cleanroomed).

**End of design spec.** Next session: open `src/decode/jpegls.zig`,
follow Session 1 task list, run `./test` to GREEN, commit.
