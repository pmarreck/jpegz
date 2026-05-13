# SOF1 12-bit precision (extended sequential, grayscale) — Design

**Status:** Approved 2026-05-13. Implements A1 from `NEXT_STEPS.md`.
**Scope this milestone:** Grayscale (1-component) SOF1 at 12-bit precision only.
**Out of scope (deferred):** 3-component YCbCr→RGB at 12-bit (separate milestone, brainstormed after Part A ships).

---

## Goal

Close the SOF1 12-bit row of the cleanroom variant matrix for grayscale
JPEGs. After this milestone, `cjpeg -baseline -precision 12 -dct int`
output on a 1-component PPM decodes through the cleanroom path (not the
libjpeg-turbo wrapper).

Specifically: `tests/unit/fixtures/baseline_4x4_gray12_dct.jpg` (uniform
0x800 expected, 4×4 mono) routes through cleanroom dispatch and the test
asserts byte-equal output in a `u16` host-endian buffer.

## Non-goals

- 3-component (RGB) 12-bit SOF1 — separate brainstorm/milestone.
- 12-bit SOF2 (progressive) — gated on this work landing first (A3 in
  NEXT_STEPS.md).
- 16-bit DCT precision — T.81 doesn't define it; lossless covers it.
- Float arithmetic anywhere in the pipeline (Peter's standing rule).

## Architecture

### IDCT module — comptime-parameterized over precision

Refactor `src/decode/idct.zig` to expose `islow` as
`comptime P: u8` generic. Same libjpeg-turbo islow algorithm topology
(1-D row pass + column pass, 11+18 SCALEBITS shift, identical FIX_*
multiplier constants). Differences captured at comptime:

| Aspect              | P = 8                | P = 12                  |
|---------------------|----------------------|-------------------------|
| Input range (DCT)   | dequant × i16 coefs  | dequant × i16 coefs     |
| Accumulator width   | i32                  | i32 (4095·91881 ≈ 376M, fits)|
| Final DESCALE shift | adjusted for 8-bit out | adjusted for 12-bit out|
| Output range        | [0, 255] → u8        | [0, 4095] → u16         |
| Centering bias      | +128                 | +2048                   |

Public surface after the refactor:

```zig
pub fn islow(comptime P: u8, ...) [64]Sample(P)
fn Sample(comptime P: u8) type { return if (P == 8) u8 else u16; }
```

8-bit call sites become `islow(8, ...)` (mechanical rename).

### Baseline decode path

In `src/decode/baseline.zig`:

1. Lift the `precision != 8` rejection at line 153 for SOF1 with
   `Nf == 1` (1-component frames only at this milestone). 3-component
   SOF1 at 12-bit continues to fall through to the wrapper.
2. Output buffer becomes `[]u16` (host-endian) for the 12-bit grayscale
   path, mirroring M2.8 lossless. Consumer reads via `image.pixelsU16()`.
3. Threading: keep parallel IDCT path active — threading API contract
   is precision-agnostic (`DecodeOptions.threads` unchanged).

### Dispatch

`src/jpegz.zig` gets a small precision-aware branch: SOF1@P=12 with
Nf=1 routes to baseline cleanroom; SOF1@P=12 with Nf=3 (and everything
else 12-bit) keeps wrapper fallback. NotImplemented from cleanroom
still falls through to wrapper.

### DQT

Already correct — `parseDqt` handles `precision_id == 1` (16-bit
entries) per T.81 §B.2.4.1. No change needed.

## Testing

### Precision-parametric test harness

Per Peter's note ("tests can cover all expected precisions"): the IDCT
unit tests will run under both P=8 and P=12 via a Zig comptime test
loop:

```zig
inline for (.{ 8, 12 }) |P| {
    test "islow round-trip identity at P=" ++ ... {
        // identity DCT input (DC-only) → uniform output at midpoint
    }
}
```

This guarantees both precision branches stay green as the IDCT evolves.

### End-to-end fixture test

- `tests/unit/decode.zig`: add "SOF1 12-bit grayscale uniform" — decode
  `baseline_4x4_gray12_dct.jpg`, assert 16 × `0x0800` in
  `image.pixelsU16()`.

### Tolerance

Byte-exact against the known-good DC-only input. (12-bit DCT with
uniform input is exactly reconstructible; no IDCT rounding loss for
DC-only coefficients.) If a non-DC-only fixture is added later,
tolerance reverts to the standard "max delta ≤ 2 LSB vs wrapper" rule.

## Implementation order (TDD)

1. **RED — fixture test**: write the failing assertion against
   `baseline_4x4_gray12_dct.jpg`. Confirm failure (compile-time or
   runtime).
2. **GREEN1 — IDCT refactor**: parameterize `islow` over `comptime P`.
   8-bit path unchanged behaviorally. 96/96 unit tests still green.
3. **GREEN2 — 12-bit IDCT path**: enable `islow(12, ...)`. Add inline
   identity tests at both precisions.
4. **GREEN3 — lift rejection + dispatch**: enable SOF1@P=12@Nf=1
   through cleanroom. Fixture test goes green.
5. **REFACTOR**: tidy any churn, confirm full suite still green, commit.

Each step is its own commit on `yolo`.

## Risks / unknowns

- **IDCT scaling math**: the DESCALE final-shift for 12-bit output is
  the only non-mechanical part. The 8-bit islow shifts by
  `CONST_BITS + PASS1_BITS + 3` after the column pass (bringing the
  internal 8-bit-centered sample into a u8 range). The 12-bit variant
  shifts 4 bits less in the final step so the output is u12-ranged
  rather than u8. Exact shift value confirmed against the identity
  test in step GREEN2.
- **Comptime generic friction**: if Zig's type system makes
  `Sample(P)`-generic functions awkward (e.g. slice-of-Sample(P) in
  parallel worker closures), fallback is approach (2) — a parallel
  `idct12.zig` module. Decision point at GREEN1.
- **Wrapper fallback regression**: must ensure SOF1@P=12@Nf=3 still
  routes to wrapper, not to a half-implemented cleanroom that asserts.

## References

- T.81 §A.4.2 / §F.1.1 — SOF1 frame syntax, precision byte
- T.81 §A.3.3 — IDCT specification (informative; islow is an
  approximation)
- libjpeg-turbo `jidct12.c::jpeg_idct_12_islow` — reference
  implementation (Apache-2, fine to read per SPEC.md)
- NEXT_STEPS.md §A1 — milestone description and sketch
- Memory: `feedback_prefer_integer_fixed_point.md` — fixed-point rule

## Open questions resolved

- **Scope (grayscale vs. RGB)**: grayscale-only this milestone; RGB
  brainstormed separately after this ships. (Peter, 2026-05-13)
- **IDCT implementation strategy**: comptime-parameterize, not a
  parallel module. (Peter, 2026-05-13)
- **Test coverage**: precision-parametric inline tests at every
  expected P. (Peter, 2026-05-13)
