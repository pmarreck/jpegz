# B1 — Arithmetic-coded JPEG: pickup notes for the next session

**Last touched:** 2026-05-13 (commit `5a13240`).
**Status:** B1 **checkpoint 1 shipped**. Q-coder kernel is solid;
DC/AC binarization + DAC parser + SOF9/SOF10 dispatch remain. The
test suite is GREEN; new session can immediately start writing the
binarization without untangling anything from prior work.

> This doc is a **complete handoff**. Read it top to bottom on
> session start. The companion spec at
> `docs/superpowers/specs/2026-05-13-arithmetic-coded-jpeg-design.md`
> covers the higher-level design; this doc is the implementation
> playbook.

---

## 60-second pickup checklist

1. `git pull && git log --oneline -3` — confirm `5a13240` is HEAD or
   ancestor.
2. `./test` — expect "All checks passed."
3. `glob ls tests/unit/fixtures/arith_*.jpg` — expect 10 files.
4. Read **§ Spec interpretation crux** below — this is the single
   thing that bit me last session. Get it locked in before writing
   any binarization code.
5. Then **§ Implementation plan**.

---

## What's already shipped (commit `5a13240`)

| File | Status | What it does |
|------|--------|-------------|
| `src/decode/arith_coder.zig` | ✅ Q-coder kernel + 4 inline tests | `QCoder.decode(ctx_ptr)` returns one bit. `QE_TABLE[113]` ported byte-for-byte from `jaricom.c`. Byte-stuffing and marker detection in `getByte`. |
| `src/decode/arith_decode.zig` | ⚠️ Stub | `decode()` returns `error.NotImplemented`. Force-imports arith_coder. |
| `src/jpegz.zig` | ✅ Entry point | `internal.arithDecode(allocator, data)` routes to arith_decode.zig. |
| `build.zig` | ✅ Test target | `decode_arith_coder` (4 inline tests). |
| `tests/unit/decode.zig` | ⚠️ Placeholder test | Embeds 5 SOF9 fixtures and decodes via wrapper. Real cleanroom-vs-wrapper test lands when binarization ships. |
| `tests/unit/fixtures/arith_*.jpg` | ✅ 10 fixtures committed | 5 SOF9 + 5 SOF10 across all sampling layouts. |
| `scratch/gen_arith_fixtures.sh` | ✅ Generator (gitignored) | Reproducible: `bash scratch/gen_arith_fixtures.sh`. |

---

## Spec interpretation crux

**This is what tripped me up last session. Read carefully.**

The "magnitude category" SSSS in *arithmetic* JPEG (T.81 §F.1.4.4.1)
is **NOT** the same as the SSSS in Huffman JPEG. They both call it
SSSS but the bin boundaries are different. Specifically, arithmetic
JPEG uses a `m` accumulator that is **0 for magnitude 1**, **1 for
magnitude 2**, **2 for magnitudes 3..4**, **4 for magnitudes 5..8**,
etc. Mapping to libjpeg's code (`jdarith.c`):

| Decisions decoded | `m` value | Magnitude range | Mag bits |
|---|---|---|---|
| S0=0 | (skipped — value is 0) | 0 | 0 |
| S0=1, S2/S3=0 | 0 | 1 | 0 |
| S0=1, S2/S3=1, X1=0 | 1 | 2 | 0 |
| S0=1, S2/S3=1, X1=1, X2=0 | 2 | 3..4 | 1 |
| S0=1, S2/S3=1, X1=1, X2=1, X3=0 | 4 | 5..8 | 2 |
| ... (k-2 X-walks) | 2^(k-2) | 2^(k-2)+1 .. 2^(k-1) | k-2 |

Decoder algorithm (faithful trace of libjpeg `decode_mcu_DC_first`):

```
m = arith_decode(S2/S3)         # 0 or 1
if m != 0:
    st = X1 (index 20)
    while arith_decode(st) == 1:
        m <<= 1                  # 2, 4, 8, ...
        st += 1
v = m                            # v starts at m
st += 14                         # jump to mag-pattern context
mag_bits = 0
loop:
    m >>= 1                      # first test mutates m, then checks
    if m == 0: break
    if arith_decode(st) == 1: v |= m
v += 1                           # the +1 captures the offset (m=0 → v=1, m=1 → v=2, ...)
if sign: v = -v
```

**Verification:** for SSSS-arith category m=2 with mag bit=1:
- v=2, m>>=1 → m=1, decode bit=1, v |= 1 → v=3, m>>=1 → 0, exit, v+=1 → v=4. ✓ (in range 3..4)

For m=4 with mag bits (1,0):
- v=4, m=2, decode 1, v=6, m=1, decode 0, v=6, m=0 exit, v+=1=7. ✓ (in range 5..8)

For m=0 (SSSS-arith=1): v=0, no iters, v+=1=1. ✓

For m=1 (SSSS-arith=2): v=1, no iters, v+=1=2. ✓

**Mag-bit-pattern context:** all mag bits for one value share the
SAME `st` (it doesn't increment inside the magnitude loop). The
Q-coder's per-context probability adaptation handles the across-iter
state automatically.

The bug in my mid-session attempt was initializing `var m: i32 = 1`
unconditionally; should be `var m: i32 = decode_at_S2;`. Re-trace
your Zig code carefully against the table above when you write it.

### AC differs from DC slightly

`decode_mcu_AC_first` has an **extra inner `arith_decode`** at the
"mag root" position before entering the X-walk. Quoting jdarith.c:

```c
if ((m = arith_decode(cinfo, st)) != 0) {       // S2/S3-equivalent
    if (arith_decode(cinfo, st)) {              // EXTRA, same st!
        m <<= 1;                                // m becomes 2
        st = ac_stats[tbl] + (k <= Kx ? 189 : 217);  // kx-conditioned jump
        while (arith_decode(cinfo, st)) {        // X-walk
            m <<= 1;
            st += 1;
        }
    }
}
```

Translation to the m-table:

| Decisions | m | Magnitude range | Mag bits |
|---|---|---|---|
| 1st bit = 0 | 0 | 1 | 0 |
| 1st = 1, 2nd = 0 | 1 | 2 | 0 |
| 1st = 1, 2nd = 1, kx-X1 = 0 | 2 | 3..4 | 1 |
| 1st = 1, 2nd = 1, kx-X1 = 1, kx-X2 = 0 | 4 | 5..8 | 2 |

Same `m` mapping as DC, just with an extra inner decision before the
X-walk, plus the kx-conditioned context split (mag-bit stride for
"low frequency" k ≤ Kx vs "high frequency" k > Kx).

### Context table layout (49 / 245 bytes)

**DC contexts** (49 bytes per DC table per T.81 Fig. F.4):

| Range | Purpose |
|---|---|
| 0..3 | S0 (zero-test) for dc_context bases {0, 4, 8, 12, 16} |
| 1..4 | S0+1 (sign) |
| 2..5 | S2 (positive mag-cat first bit) |
| 3..6 | S3 (negative mag-cat first bit) |
| 20..33 | X1..X14 (unary continuation) |
| 14 + S2/S3 offset OR 14 + X-exit offset | mag-pattern (single context, reused) |
| 34..47 | mag-pattern slots (one per SSSS-arith bin) |

(Approximate — re-derive from libjpeg if precise count matters.)

**AC contexts** (245 bytes per AC table per T.81 Fig. F.5):

| Range | Purpose |
|---|---|
| 3*(k-1) for k∈[1,63] | EOB at base, "is-zero" at +1, mag-decision at +2 |
| 189..216 | mag-bit unary for k ≤ Kx (28 slots) |
| 217..244 | mag-bit unary for k > Kx (28 slots) |
| (st_walk_exit + 14) | mag-pattern context (single, reused per value) |
| fixed_bin (separate Context cell) | AC sign decisions (T.81 calls it the "fixed-probability bin") |

---

## Implementation plan (resume here)

### Step 1 — DC binarization (~150 LOC)

Add to `src/decode/arith_coder.zig` (where the WIP comment block
currently sits):

```zig
pub const ScanState = struct {
    qcoder: QCoder,
    dc_stats: [4][49]Context,
    ac_stats: [4][245]Context,
    fixed_bin: Context,
    last_dc_val: [4]i32,
    dc_context: [4]u8,    // ∈ {0, 4, 8, 12, 16}
    arith_dc_L: [4]u8,    // default 0
    arith_dc_U: [4]u8,    // default 1
    arith_ac_K: [4]u8,    // default 5

    pub fn init(data: []const u8) ScanState { ... }
    pub fn resetForRestart(self: *ScanState, data: []const u8, pos: usize) void { ... }
};

pub fn decodeDcSof9(state: *ScanState, ci: usize, dc_tbl: u8) i32 {
    // Faithful translation of decode_mcu_DC_first per the m-table above.
    // Watch out: m starts as the FIRST decoded bit (0 or 1), NOT 1.
}

pub fn decodeAcSof9(state: *ScanState, ac_tbl: u8, block: *[64]i16) void {
    // Faithful translation of decode_mcu_AC_first.
}

pub const ZIGZAG_AC: [64]u8 = .{...};  // same as baseline.zig's ZIGZAG
```

Add inline unit tests:
- Hand-craft a `ScanState` with `arith_decode` returning known
  sequences (or use a tiny test fixture if practical).
- Assert decodeDcSof9 returns the expected i32 for each
  m-table case.

### Step 2 — DAC marker parser (~60 LOC)

Per T.81 §B.2.4.3. Format: `FF CC <length> [<Tc/Tb> <Cs>]*`.

```zig
fn parseDac(data: []const u8, pos: usize, state: *ScanState) Error!void {
    const seg_len = (@as(usize, data[pos]) << 8) | data[pos + 1];
    if (seg_len < 4 or pos + seg_len > data.len) return error.TruncatedStream;
    var i: usize = 2;
    while (i + 1 < seg_len) : (i += 2) {
        const tc_tb = data[pos + i];
        const cs = data[pos + i + 1];
        const tc: u8 = tc_tb >> 4;
        const tb: u8 = tc_tb & 0x0F;
        if (tb >= 4) return error.InvalidMarker;
        if (tc == 0) {
            // DC: Cs = (U << 4) | L
            state.arith_dc_L[tb] = cs & 0x0F;
            state.arith_dc_U[tb] = cs >> 4;
        } else if (tc == 1) {
            // AC: Cs = Kx
            state.arith_ac_K[tb] = cs;
        } else return error.InvalidMarker;
    }
}
```

### Step 3 — SOF9 entry point + dispatch (~200 LOC)

`src/decode/arith_decode.zig`: replace the stub `decode()` with real
dispatch:

```zig
pub fn decode(allocator: Allocator, data: []const u8) Error!types.Image {
    // Walk markers until SOF found, classify SOF9 vs SOF10 vs other,
    // dispatch.
    var pos: usize = 0;
    // ... marker walk ...
    switch (sof_marker) {
        0xC9 => return decodeArithBaseline(allocator, data),
        0xCA => return decodeArithProgressive(allocator, data),  // Session 2
        0xCB => return error.NotImplemented, // SOF11 — see A2-style deferral
        else => unreachable,
    }
}

fn decodeArithBaseline(allocator: Allocator, data: []const u8) Error!types.Image {
    // Walk all markers, parse SOF/DQT/DAC/DRI, find SOS.
    // Set up FrameInfo, quant tables (same shape as baseline.zig).
    // Allocate i16 coefficient buffers per component.
    // For each MCU:
    //   For each component:
    //     For each block in MCU (h_factor × v_factor):
    //       block = zeroes
    //       block[0] = decodeDcSof9(state, ci, dc_tbl)
    //       decodeAcSof9(state, ac_tbl, &block)
    //       coef_buf[ci][block_idx] = block  // i16, zig-zag → natural already applied inside decodeAcSof9
    //   handle RST if at boundary
    // Call baseline.zig's assembleOutput (which takes a coef_buf and
    // does dequant + IDCT + chroma upsample + color convert).
}
```

**Critical reuse:** Phase 2 of baseline (`assembleOutput` and friends
in `baseline.zig`) is already precision-agnostic for 8-bit input. We
just need to feed it the coefficient buffer in the right shape.

Need to extract or expose:
- `baseline.assembleOutput` — currently `fn`, may need to be `pub fn`
- `baseline.FrameInfo` — same
- `baseline.ComponentInfo` — same

OR re-implement the assemble shape locally in `arith_decode.zig`.
Smaller blast radius to just duplicate the assemble (~80 LOC).

**Recommendation:** start by making `baseline.assembleOutput` `pub fn`
(or moving to a shared module) to avoid duplication. The signature is
already stable from A1 work.

### Step 4 — Wire jpegz.zig dispatch

Currently `jpegz.decode` (the public dispatcher) does:
```zig
if (cleanroomBaseline.try(data)) ... else if (progressive.try(data)) ... else wrapper(data);
```

Add an `else if (arith_decode.try(data)) ...` branch. The dispatcher
needs a way to peek the SOF marker without consuming it; existing
modules return `error.NotImplemented` from a quick header parse if
the variant doesn't match. Follow that pattern.

Alternatively, the cleanest hook: detect SOF9/SOF10 at the top of
`baseline.decode` and `progressive.decode` and short-circuit to
`arith_decode.decode`. The existing dispatch already routes by SOF
marker through these modules.

### Step 5 — RED the test, watch GREEN

Restore the failing test that was reverted in `5a13240`:

```zig
test "B1 SOF9: arithmetic baseline cleanroom (gray + RGB at all sampling factors)" {
    // Restored from commit 5a13240^ (just before the checkpoint).
    // Asserts cleanroom byte-equals wrapper to ≤4 LSB for RGB cases
    // and ≤2 LSB for grayscale.
}
```

`git log -1 -p 5a13240 -- tests/unit/decode.zig` will show you the
exact diff to reverse.

Run `./test`. Cycle until GREEN.

### Step 6 — Session 1 commit

Commit messages:
- "B1: SOF9 (arithmetic baseline) cleanroom"
- Update `NEXT_STEPS.md` (matrix row SOF9 → ✅).

### Session 2 — SOF10 progressive (~300 LOC follow-on)

Same shape, different binarization helpers:
- `decodeDcFirstArith` (SOF10 first-DC scan)
- `decodeAcFirstArith` (SOF10 first-AC scan)
- `decodeDcRefineArith` (SOF10 DC refinement)
- `decodeAcRefineArith` (SOF10 AC refinement)

Then `decodeArithProgressive` orchestrates per-scan dispatch and
reuses `progressive.assembleProgressiveGeneric(8, ...)` for the
Phase 2 assemble.

T.81 §G.1 specifies the four progressive arithmetic scan types.
libjpeg-turbo's `jdarith.c` has the reference implementations
(`decode_mcu_AC_refine` etc., lines ~430-630).

---

## Known traps

1. **`m` starts at 0 or 1**, never just `1`. The mid-session attempt
   had `var m: i32 = 1;` which silently corrupts the SSSS=1 case.

2. **`while (m >>= 1)` is `do { m=m>>1; if m==0 break; }`**, not
   `do { if m>>1 == 0 break; m=m>>1; }`. The mutation happens before
   the check.

3. **Mag-bit context doesn't increment.** All k-1 mag bits share one
   `st`. The Q-coder's state update inside `decode()` handles
   adaptation.

4. **AC has extra inner decision** at the same `st` before the
   X-walk. DC doesn't. Don't try to share helpers between them.

5. **`last_dc_val` is mod 2^16.** The C `& 0xffff` matters; Zig
   should `@as(i16, @bitCast(@as(u16, @truncate(...))))` to match
   libjpeg's wraparound semantics.

6. **Q-coder state is initialized at decode start**, not at the
   first arith_decode call. The init pattern is: create a QCoder
   with A=0, ct=-16; the first decode call's renormalization loop
   pulls the initial 2 bytes into C and lifts A to 0x8000. Watch
   the existing `QCoder.init` and the comment about T.81 §D.2.6.

7. **DAC defaults matter.** Even fixtures that don't emit DAC have
   implicit conditioning (L=0, U=1, Kx=5). The `ScanState.init`
   should set these.

8. **`fixed_bin` is shared across all AC sign decisions.** Don't
   per-table-ify it.

---

## Quick reference: file map

```
src/decode/arith_coder.zig     # add ScanState, decodeDcSof9, decodeAcSof9, ZIGZAG_AC
src/decode/arith_decode.zig    # replace stub; add parseDac, decodeArithBaseline, marker walk
src/decode/baseline.zig        # may need: make assembleOutput pub fn for reuse
src/jpegz.zig                  # already has internal.arithDecode; no changes needed
build.zig                      # already has decode_arith_coder target; no changes needed
tests/unit/decode.zig          # restore the B1 SOF9 test from 5a13240^
```

---

## What to NOT do this session

- Don't refactor baseline.zig / progressive.zig beyond making
  `assembleOutput` public. Save the comptime-P-generic engine
  unification for a separate post-B1 milestone.
- Don't pursue SOF11 (arithmetic lossless) — defer per A2 rationale.
  Same A2 wall: libjpeg's encoder errors with "arithmetic coding is
  not implemented" for `-arithmetic -lossless`.

---

**End of pickup notes.** Next session: open this, lock in the
m-table, then write decodeDcSof9 → decodeAcSof9 → parseDac →
decodeArithBaseline → wire dispatch → restore test → GREEN → commit.
