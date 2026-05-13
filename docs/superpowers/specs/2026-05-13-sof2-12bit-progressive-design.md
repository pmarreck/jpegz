# SOF2 12-bit progressive cleanroom (A3) — Design

**Status:** Approved 2026-05-13. Implements A3 from `NEXT_STEPS.md`.
**Scope:** SOF2 (progressive DCT) at 12-bit precision, both 1-component
(grayscale) and 3-component (RGB) variants, across all 4 common chroma
sampling factors (4:4:4, 4:2:0, 4:2:2, 4:4:0). One milestone, all-in.
**Out of scope:** Arithmetic-coded progressive (SOF10) — separate
milestone (B1). JPEG-LS (T.87) and JP2 (T.800) — independent codecs.

---

## Goal

Close the SOF2 12-bit row of the cleanroom variant matrix. After this
milestone:

- `cjpeg -progressive -precision 12 <ppm>` (cjpeg default = 4:2:0)
  decodes through the cleanroom path instead of falling through to
  the wrapper.
- Same with `-sample 1x1`, `-sample 2x1,1x1,1x1`, `-sample 1x2,1x1,1x1`,
  and grayscale (`-grayscale -progressive -precision 12`).
- All output buffers match libjpeg-turbo wrapper to ≤4 LSB
  (same tolerance as A1 Part B).

## Why this works (unlike A2)

Empirical viability check (2026-05-13):

```
$ cjpeg -progressive -precision 12 in.ppm > prog12.jpg
$ djpeg -outfile out.ppm prog12.jpg
# SOF2 marker: FF C2 0011 0C 0010 0010 03 012200 021101 031101
#                       ^^ precision=12  ^^^^^^ Y=2×2 (4:2:0 default)
```

Both the encoder and the decoder agree. The variant is alive in the
wild (libjpeg supports it, tools accept it, the SOF2-P=12 row is a
real-world combination — DICOM and DNG aren't the only consumers).

## Architecture

### Hybrid factoring: split entropy decode from assemble

Progressive's existing `decodeProgressive` (in `src/decode/progressive.zig`)
has two natural phases:

1. **Phase 1 — multi-scan entropy decode** (~600 LOC):
   `decodeOneScan` → `decodeProgressiveBlock` → DC-first / DC-refine /
   AC-first / AC-refine helpers. All operate on `[]i32` coefficient
   buffers. **Already precision-agnostic** — the SSSS limits and
   coefficient ranges work for both P=8 and P=12 without changes
   (verified: same logic shape as `decodeBlockCoefficients` from
   baseline, which we already extended for P=12 in A1).

2. **Phase 2 — IDCT + plane assembly** (`assembleProgressive`):
   Takes the final coefficient buffer, runs IDCT on each block, copies
   to per-component planes, upsamples chroma, color-converts. **This
   is where types diverge by precision.**

Strategy: **keep Phase 1 unchanged** (already P-agnostic). **Refactor
Phase 2 to be comptime-P-generic** by extracting a single
`assembleProgressiveGeneric(comptime P: u8, ...)` function that the
existing 8-bit `assembleProgressive` becomes a thin wrapper over.

### `assembleProgressiveGeneric(comptime P, ...)` shape

```zig
fn assembleProgressiveGeneric(
    comptime P: u8,
    allocator: Allocator,
    frame: *const FrameInfo,
    coef_buf: *const [3][]i32,
    blocks_w: [3]u32,
    blocks_h: [3]u32,
    plane_w: [3]u32,
    plane_h: [3]u32,
    max_h: u32,
    max_v: u32,
) Error!types.Image {
    const Sample = idct.Sample(P); // u8 or u16
    var planes: [3][]Sample = ...;
    // IDCT each block via idct.idct8x8Generic(P, ...) into planes
    // Upsample chroma via color.fancyUpsample(8-bit) or fancyUpsample12 (12-bit)
    // Color-convert via color.ycbcrRowToRgb(8-bit) or ycbcrRowToRgb12 (12-bit)
    // Allocate output []u8 (sized for u8 or u16 per Sample(P))
    // Return Image with bits_per_sample = P
}
```

For the upsample / color-convert dispatch, branch on `P` at comptime:

```zig
const upsampled = if (P == 8)
    try color.fancyUpsample(...)
else
    try color.fancyUpsample12(...);
```

Zig comptime eliminates the branch at compile time — each P
instantiation gets one concrete code path.

### Precision dispatch

Existing lines 149 / 268 reject `precision != 8`. Lift to allow
P ∈ {8, 12}:

```zig
const p_ok = frame.?.precision == 8 or frame.?.precision == 12;
if (!p_ok) return error.UnsupportedPrecision;
```

At assemble time, branch on precision:

```zig
return if (frame.precision == 8)
    try assembleProgressiveGeneric(8, ...)
else
    try assembleProgressiveGeneric(12, ...);
```

### Output format

Same convention as A1:
- P=8: `pixels = []u8` interleaved, `bits_per_sample = 8`.
- P=12: `pixels = []u8` (host-endian byte view of `[]u16`),
  `bits_per_sample = 12`. Consumer reads via `image.pixelsU16()`.

### Grayscale handling

`assembleProgressiveGeneric` handles `channels == 1` by skipping the
upsample + color-convert phases entirely and copying the luma plane
directly. Same shape as the 8-bit grayscale path.

### Entropy decoder

No changes — Phase 1 is precision-agnostic. `decodeProgressiveDcFirst`,
`decodeProgressiveAcFirst`, refinements all operate on coefficient
amplitudes that fit naturally at both 8-bit and 12-bit precision (the
i32 coefficient buffer is wide enough). The SSSS limits in the
progressive helpers (mostly via Huffman table semantics + Ah/Al point
transform parameters) work identically for both precisions per T.81 §G.

## Testing

### Fixtures (committed under `tests/unit/fixtures/`)

Generated via `scratch/gen_prog12_fixtures.sh` (a small Bash script,
similar to `gen_rgb12_fixtures.sh`):

| File | Sampling | cjpeg args |
|------|----------|------------|
| `progressive_16x16_rgb12_444.jpg` | 4:4:4 | `-progressive -precision 12 -sample 1x1` |
| `progressive_16x16_rgb12_420.jpg` | 4:2:0 | `-progressive -precision 12 -sample 2x2,1x1,1x1` |
| `progressive_16x16_rgb12_422.jpg` | 4:2:2 | `-progressive -precision 12 -sample 2x1,1x1,1x1` |
| `progressive_16x16_rgb12_440.jpg` | 4:4:0 | `-progressive -precision 12 -sample 1x2,1x1,1x1` |
| `progressive_8x8_gray12.jpg` | grayscale | `-progressive -precision 12 -grayscale` |

### Test

Single parametric test in `tests/unit/decode.zig`, iterating over the
5 fixtures, asserting `internal.progressiveDecode` byte-equals
`internal.wrapperDecode` to ≤4 LSB per sample (same tolerance as A1
Part B; rationale: 12-bit YCbCr→RGB + DCT round-trip + chroma
upsample drift). Grayscale fixture should achieve ≤2 LSB.

### Tolerance

- Grayscale 12-bit progressive: ≤2 LSB (no color conversion to
  compound rounding errors).
- 4:4:4 RGB 12-bit progressive: ≤2 LSB (no chroma upsample).
- 4:2:0 / 4:2:2 / 4:4:0 RGB 12-bit progressive: ≤4 LSB (chroma
  upsample amplifies sub-pixel rounding through color conversion).

Same gates as A1 Part B.

## Implementation order (TDD, ~5 small commits)

1. **Fixture generation** — `scratch/gen_prog12_fixtures.sh` produces
   the 5 fixtures via cjpeg. Verify SOF2 markers and 12-bit precision
   byte. Commit the generated `.jpg` files.

2. **RED — failing parametric test**: add the test above; current
   HEAD fails at line 149 (`error.UnsupportedPrecision`).

3. **GREEN1 — Phase 2 refactor**: extract `assembleProgressiveGeneric`
   from `assembleProgressive`. Existing 8-bit path becomes a thin
   `return assembleProgressiveGeneric(8, ...)` wrapper. All existing
   progressive tests stay green.

4. **GREEN2 — lift precision gate + 12-bit instantiation**: lift the
   `precision != 8` checks at lines 149 and 268 to allow {8, 12}.
   Dispatch in the SOS marker handler to
   `assembleProgressiveGeneric(12, ...)` for P=12. Failing test goes
   green.

5. **REFACTOR**: tidy comments, full suite green, update
   NEXT_STEPS.md matrix row to "SOF2 12-bit ✅", commit.

Each its own commit on `yolo`.

## Risks / unknowns

- **DC predictor at 12-bit**: progressive DC scans accumulate
  differential values across blocks within a scan. At P=12, intermediate
  DC accumulators can reach ~2^15 in pathological cases. Existing i32
  storage handles this; verify no implicit narrowing in the refactor.
- **EOB-run / ZRL / refinement at 12-bit**: T.81 §G.1.2 specifies
  these for progressive at any precision. The SSSS values for AC
  amplitudes have the same upper bound (P+2 = 14 for P=12) as we
  already established for baseline in A1. Verify SSSS limit consts
  in the progressive helpers don't hardcode 10.
- **i32 overflow in 12-bit IDCT (already addressed by A1)**:
  `idct.idct8x8Generic(12, ...)` widens to i64 accumulators
  internally; nothing for A3 to do here.
- **Wrapper output format**: the libjpeg wrapper handles 12-bit
  progressive via `jpeg12_read_scanlines` (already plumbed in M1.4b
  for the lossless path). Verify it works for progressive too —
  djpeg test above already confirms it does at the CLI layer.

## References

- T.81 §G.1 (progressive DCT), §G.1.2 (entropy decoding successive
  approximation)
- T.81 §F.1.4 / Table F.1 (SSSS limits, same as baseline)
- libjpeg-turbo `jdphuff.c` (progressive entropy reference)
- A1 spec: `docs/superpowers/specs/2026-05-13-sof1-12bit-precision-design.md`
- A1 Part B spec: `docs/superpowers/specs/2026-05-13-sof1-12bit-rgb-design.md`
- Memory: `feedback_prefer_integer_fixed_point.md` (no float)

## Open questions resolved

- **Scope (gray-first vs all-in)**: all-in. cjpeg's default for
  `-progressive -precision 12` is 4:2:0, forcing subsampling support
  from commit #1. Grayscale and 4:4:4 are bonus easier cases that
  flow naturally from the same code path. (Peter, 2026-05-13)
- **Sampling coverage**: all 4 (4:4:4, 4:2:0, 4:2:2, 4:4:0) + 1
  grayscale fixture. Same coverage as A1 Part B. (Peter, 2026-05-13)
- **Code-sharing strategy**: hybrid factor (c) — keep Phase 1
  unchanged (already P-agnostic); refactor only Phase 2
  (`assembleProgressive`) to be comptime-P-generic.
  (Peter, 2026-05-13)
- **Pre-emptive refactor of baseline+progressive into single generic
  engine**: deferred. Do A3 first, then assess. (Peter, 2026-05-13)
