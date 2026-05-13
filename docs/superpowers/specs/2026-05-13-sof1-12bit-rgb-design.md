# SOF1 12-bit RGB cleanroom (A1 Part B) — Design

**Status:** Approved 2026-05-13. Implements A1 Part B from
`NEXT_STEPS.md` (follow-on to A1 Part A grayscale, commit `3ab85d9`).
**Scope this milestone:** 3-component RGB SOF1 at 12-bit precision,
**all chroma sampling factors** (4:4:4, 4:2:0, 4:2:2, 4:4:0).
**Out of scope:** SOF2 12-bit progressive (A3), SOF3 non-1×1
sampling (A2). 16-bit DCT precision — not in T.81.

---

## Goal

Close the SOF1 12-bit row of the cleanroom variant matrix at all common
chroma sampling factors. After this milestone:

- `cjpeg -baseline -precision 12 -sample 1x1 grad_rgb.ppm` decodes
  through cleanroom (4:4:4 case).
- Same with `-sample 2x2,1x1,1x1` (4:2:0).
- Same with `-sample 2x1,1x1,1x1` (4:2:2).
- Same with `-sample 1x2,1x1,1x1` (4:4:0).
- All output buffers byte-equal libjpeg-turbo wrapper to ≤2 LSB,
  per the established cleanroom DCT tolerance.

## Non-goals

- Floating-point math anywhere in the path (Peter's standing rule).
- Subsampling factors beyond {1×1, 2×2, 2×1, 1×2} for chroma.
  Fallback for unsupported ratios is nearest-neighbor (matches 8-bit
  behavior).
- The "future refactor" toward comptime-P-generic `decodeScan` — that
  is a follow-on milestone of its own.

## Architecture

### Color helpers (new u16 siblings in `src/decode/color.zig`)

**`ycbcrRowToRgb12`** — per-row YCbCr→RGB at 12-bit precision.
Identical fixed-point constants to the 8-bit variant (Cred=91881,
Cgreen_cb=−22554, Cgreen_cr=−46802, Cblue=116130, ONE_HALF=32768,
SCALEBITS=16) — they encode the same ratios. Only:
- Input bias: `Cb' = Cb − 2048`, `Cr' = Cr − 2048` (was 128).
- Output clamp: `[0, 4095]` (was `[0, 255]`).
- Input/output: `[]const u16` planes, `[]align(1) u16` RGB out.
- Accumulators: i32 (worst-case `|Cb' * 116130| ≈ 2^28`, plus Y up
  to 4095 → still < 2^29).

**`fancyUpsample12`** — IJG cosited-center upsampling at 12-bit. Same
weights `(9·C + 3·H + 3·V + D + 8) >> 4` for H2V2; `(3·C + N + 2) >> 2`
for H2V1 / V2H1. `u16` neighbors, u32 accumulator (max sum 16 × 4095
= 65520, comfortable). Boundary-clamping mirrors the 8-bit version.

**`sampleComponent12`** — nearest-neighbor `u16` plane sampler. Drop-in
type swap of the 8-bit `sampleComponent` for unsupported ratios.

### Decode dispatch

`src/decode/baseline.zig` SOF marker handler lifts the SOF1@P=12
restriction from "Nf=1 only" to "Nf ∈ {1, 3}". SOS marker handler
dispatches:

| (precision, Nf) | Path |
|-----------------|------|
| (8, 1) or (8, 3) | `decodeScan` (8-bit, all sampling) |
| (12, 1) | `decodeScan12Gray` (Part A, shipped) |
| (12, 3) | `decodeScan12Rgb` (new, this milestone) |
| any other | `error.NotImplemented`, falls through to wrapper |

### `decodeScan12Rgb` shape

Mirrors `decodeScan` structurally:

1. **Setup**: compute `max_h`, `max_v` from frame components.
   `mcu_cols`, `mcu_rows`, per-component `plane_w[i]`, `plane_h[i]`,
   `blocks_w[i]`, `blocks_h[i]`. All identical to the 8-bit code.
2. **Allocate** `[3][]u16 planes` and `[3][]i32 coef_buf`.
3. **Phase 1 entropy decode** — calls `decodeBlockCoefficients` (already
   precision-aware from Part A) into `coef_buf`. MCU loop identical to
   `decodeScan`.
4. **Phase 2 IDCT** — per block, `idct.idct8x8_12(coef_slot, &u16_block)`
   writes into the plane. Single-threaded at this milestone; parallel
   IDCT for 12-bit can come in a follow-on once `transformBlockRow`
   is generic over P.
5. **Phase 3 assemble**: if any component has `(h_factor, v_factor) ≠
   max_h, max_v)`, run `fancyUpsample12` on its plane → canvas-sized
   u16 plane. Then `ycbcrRowToRgb12` per row → interleaved u16 RGB.
6. **Output**: `Image{ .pixels = u8 view of u16 RGB buffer, .channels = 3,
   .bits_per_sample = 12, .layout = .rgb, .source_color_space = .ycbcr }`.

### Entropy decoder

No changes — `decodeBlockCoefficients` already handles P=12 SSSS limits
(DC ≤ 15, AC ≤ 14) from Part A.

## Testing

### Fixtures (committed under `tests/unit/fixtures/`)

Generate during implementation plan step 1 using `cjpeg` against a
12-bit PPM input (a small ~8×8 RGB gradient):

| File | Sampling | cjpeg args |
|------|----------|------------|
| `baseline_8x8_rgb12_444.jpg` | 4:4:4 | `-sample 1x1` |
| `baseline_8x8_rgb12_420.jpg` | 4:2:0 | `-sample 2x2,1x1,1x1` |
| `baseline_8x8_rgb12_422.jpg` | 4:2:2 | `-sample 2x1,1x1,1x1` |
| `baseline_8x8_rgb12_440.jpg` | 4:4:0 | `-sample 1x2,1x1,1x1` |

Source PPM (`grad_rgb12.ppm`, P6 format with maxval = 4095, 2 bytes
per sample) is NOT committed; it's a build artifact. Generation
script lives in `scratch/` and is gitignored — the committed JPEGs
are the test inputs.

### Test

Single parametric test in `tests/unit/decode.zig`:

```zig
test "A1 Part B: SOF1 12-bit RGB cleanroom decodes byte-for-byte vs wrapper, all sampling factors" {
    const cases = [_]struct { data: []const u8, label: []const u8 }{
        .{ .data = fixture_8x8_rgb12_444, .label = "4:4:4" },
        .{ .data = fixture_8x8_rgb12_420, .label = "4:2:0" },
        .{ .data = fixture_8x8_rgb12_422, .label = "4:2:2" },
        .{ .data = fixture_8x8_rgb12_440, .label = "4:4:0" },
    };
    inline for (cases) |c| {
        var cleanroom = try jpegz.internal.cleanroomDecode(allocator, c.data);
        defer cleanroom.deinit(allocator);
        var wrapper = try jpegz.internal.wrapperDecode(allocator, c.data);
        defer wrapper.deinit(allocator);
        try expectEqual(@as(u8, 12), cleanroom.bits_per_sample);
        try expectEqual(@as(u8, 3), cleanroom.channels);
        const c_u16 = cleanroom.pixelsU16();
        const w_u16 = wrapper.pixelsU16();
        for (c_u16, w_u16) |a, b| try expect(@abs(@as(i32, a) - @as(i32, b)) <= 2);
    }
}
```

### Tolerance

≤2 LSB per RGB sample vs libjpeg-turbo wrapper output. Same gate as
8-bit baseline cleanroom. Lossless byte-equality is not expected
because DCT round-trip + color conversion introduces sub-pixel
rounding that may differ in tie-breaks from libjpeg.

## Implementation order (TDD, 5 small commits)

1. **Fixture generation** — generate the 4 JPEGs via `cjpeg`,
   commit under `tests/unit/fixtures/`. Document the source script
   in `scratch/`.
2. **RED — failing test**: add the parametric test above; verify
   it fails for all 4 cases with `NotImplemented` (SOF gate rejects
   Nf=3 at P=12 today).
3. **GREEN1 — color helpers**: add `ycbcrRowToRgb12`, `fancyUpsample12`,
   `sampleComponent12` to `color.zig`. No call sites yet; verify
   compile and inline unit tests for the new fns (round-trip at
   uniform color → expected fixed-point output).
4. **GREEN2 — `decodeScan12Rgb`**: add function and dispatch; lift
   SOF1@P=12 restriction to allow Nf=3. Run the suite. Expect 4 new
   tests green.
5. **REFACTOR**: tidy, full suite green, update NEXT_STEPS.md
   matrix row to "SOF1 12-bit RGB ✅". Commit.

Each step its own commit on `yolo`.

## Risks / unknowns

- **PPM generation**: cjpeg expects PNM input; for 12-bit precision
  it accepts PPM/PGM with `maxval > 255` per its docs. We need to
  verify `maxval = 4095` is honored end-to-end. If not, fall back to
  `maxval = 65535` and let cjpeg downcast — the fixture is still
  ground-truth via the wrapper round-trip.
- **Subsampled chroma + DCT round-trip**: libjpeg's fancy upsampling
  combined with 12-bit IDCT rounding may exceed 2 LSB in
  pathological cases. If so, document the higher tolerance per
  fixture in the test and surface as a Finding later via validate(...).
- **i32 accumulator margins** in color conversion: spot-checked; max
  intermediate ≈ 2^29 (i32 max 2^31), safe.
- **Memory leak detection**: testing allocator catches drops; the
  new code must `defer allocator.free(plane)` / `errdefer
  allocator.free(pixels)` everywhere it allocates.

## References

- T.81 §A.2.2 (MCU walk for interleaved scans), §A.3.1 (level shift)
- T.81 §F.1.4 (entropy SSSS limits) — already handled in Part A
- libjpeg-turbo `jdcolor.c` `ycc_rgb_convert` — fixed-point constants
- libjpeg-turbo `jdsample.c` IJG fancy upsample (M2.2c reference)
- NEXT_STEPS.md §A1 — milestone description
- Spec for Part A: `docs/superpowers/specs/2026-05-13-sof1-12bit-precision-design.md`

## Open questions resolved

- **Chroma sampling scope**: all 4 common factors in one milestone, not
  4:4:4 first. (Peter, 2026-05-13)
- **Color math**: integer fixed-point with widened input range; same
  FIX constants as 8-bit. No float. (standing rule)
- **Code structure**: standalone `decodeScan12Rgb` mirroring
  `decodeScan`'s shape. Comptime-P-generic refactor deferred to a
  follow-on milestone. (incremental ship, surgery first)
