# jpegz — starting specification

**Status:** greenfield. No code yet beyond this scaffold. This document
is the briefing for the next agent.

**Read first:** `AGENTS.md` / `CLAUDE.md` (vault symlink) for project-
wide conventions. Then `LICENSING_NOTES.md` for the dep license matrix
(libjpeg-turbo BSD-3, openjpeg BSD-2, both MIT-compatible; JPEG patent
landscape clear; JPEG 2000 patent landscape mostly clear with two
nuances called out below).

---

## 0. Mission

A spec-complete JPEG family decoder library in Zig. Single ABI surface
covering:

- Baseline JPEG (T.81 sequential DCT, 8-bit and 12-bit precision)
- Progressive JPEG (T.81 progressive DCT)
- Lossless JPEG (T.81 §13 — predictive coding, used by DICOM and some
  early DNG)
- Arithmetic coding (T.81 §F — rare but spec-mandatory)
- JPEG-LS (T.87 / ISO 14495-1 — eventually)
- JPEG 2000 (T.800 / ISO 15444 — wavelet codec, separate ABI namespace
  in same project)

Both `validate` and `tiffz` will consume jpegz. JPEG-in-TIFF
(compression=7) and PDF-embedded JPEG streams flow through this single
implementation.

---

## 1. Two-phase plan

### Phase 1 — wrapper, MVP

Wrap existing C libraries:
- `libjpeg-turbo` (BSD-3, currently vendored in validate as
  `chearon/libjpeg-turbo` Zig-build fork) — handles baseline +
  progressive + arithmetic.
- `openjpeg` (BSD-2, currently vendored in validate as
  `deps/openjpeg`) — handles JPEG 2000.
- Lift validate's existing `jpeg_lossless_decoder.zig` (698 lines,
  pure Zig) for lossless JPEG.

Goal: a single Zig API + C ABI on day one. Internally these are
mostly FFI-into-C-libs calls, plus the lossless path that's already
pure Zig.

**Why wrapper first:** validate and tiffz both need a working JPEG
decoder NOW. Wrapping is fast; ships in a few days. Cleanroom rewrite
takes weeks at minimum and would block tiffz milestone 4 (JPEG-in-
TIFF) for months.

### Phase 2 — cleanroom pure-Zig replacement

Rewrite each codec in pure Zig, retaining libjpeg-turbo + openjpeg
as test oracles ONLY. End state: zero C deps in shipped binary.

Order (each step includes the prior step's tests as a regression
oracle):

1. Baseline JPEG (sequential DCT, 8-bit). Most-used path; biggest
   impact when retired off libjpeg-turbo.
2. Progressive JPEG. Builds on baseline's DCT; adds spectral selection
   and successive approximation.
3. Lossless JPEG cleanroom verification (existing 698-line decoder
   audited against spec + libjpeg-turbo oracle).
4. 12-bit precision support (rare but spec-mandatory).
5. Arithmetic coding. T.81 §F. Rare; do last among the T.81 codecs.
6. JPEG-LS (T.87). Different codec, different math (LOCO-I predictor
   + Golomb-Rice coding). Independent of T.81 work.
7. JPEG 2000 (T.800). Wavelet + EBCOT + tier-1/tier-2 packetization.
   Completely different codec; do last. Probably its own multi-month
   effort.

Track Phase 2 in `PLAN.md` — explicit checkbox per codec. Each Phase 2
step retires a chunk of the C dep.

---

## 2. ABI shape

### Zig public API (sketch — refine via brainstorming)

```zig
// Decoded image — caller owns the pixel buffer.
pub const Image = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    channels: u8,        // 1 = gray, 3 = RGB, 4 = CMYK
    bits_per_sample: u8, // 8, 12, 16
    color_space: ColorSpace,
};

// === Baseline / Progressive / Arithmetic / Lossless / JPEG-LS ===
pub fn decode(allocator: Allocator, source: Source) !Image;

// Streaming variant — decodes scan-by-scan or MCU-row-by-MCU-row,
// invoking callback. Caller never holds full pixel buffer.
pub fn decodeStreaming(
    allocator: Allocator,
    source: Source,
    callback: *const fn (RowCallback) anyerror!void,
) !void;

// Validation only — decodes through to verify integrity, discards
// pixels. Returns a report.
pub fn validate(allocator: Allocator, source: Source) !ValidationReport;

// === JPEG 2000 (separate namespace) ===
pub const jpeg2000 = struct {
    pub fn decode(allocator: Allocator, source: Source) !Image;
    pub fn decodeStreaming(...) !void;
    pub fn validate(...) !ValidationReport;
};
```

Use the same seekable `Source` abstraction tiffz uses (see
`tiffz/SPEC.md` Appendix A's discussion of seekable Source vs forward
Reader). One `Source` shape across the sibling-project family.

### C ABI (mirrors Zig API)

```c
// jpegz_core.h

typedef struct jpegz_source {
    void *ctx;
    int (*read_at)(void *ctx, uint8_t *buf, size_t buf_len, uint64_t offset, size_t *out_read);
    int (*size)(void *ctx, uint64_t *out_size);
} jpegz_source_t;

typedef struct {
    uint8_t *pixels;
    uint32_t width;
    uint32_t height;
    uint8_t  channels;
    uint8_t  bits_per_sample;
    int      color_space;
} jpegz_image_t;

// Baseline / progressive / lossless / arithmetic / JPEG-LS
int jpegz_decode(const jpegz_source_t *src, jpegz_image_t *out);
int jpegz_validate(const jpegz_source_t *src, jpegz_validation_report_t *out);

// JPEG 2000 (separate ABI namespace, same project)
int jpegz_jp2_decode(const jpegz_source_t *src, jpegz_image_t *out);
int jpegz_jp2_validate(const jpegz_source_t *src, jpegz_validation_report_t *out);

// Caller frees pixels (caller-allocates, library-fills pattern preferred
// where buffer size is knowable up front; out-buffer mode for unknown
// streaming pixel count).
```

---

## 3. Existing assets to lift

From `validate/`:

- `src/core/jpeg_lossless_decoder.zig` (698 lines, pure Zig) — lift
  wholesale into jpegz Phase 1. This is the lossless JPEG path; works
  today; covers DICOM and DNG embedded thumbnails.
- `src/core/jpeg_validator.zig` (359 lines) — **LIFT into jpegz, do not
  retire**. Despite the name, this is the libjpeg-turbo *deep*-validation
  wrapper: setjmp/longjmp error handling, `jpeg_mem_src` →
  `jpeg_read_header` → `jpeg_start_decompress` → `jpeg_read_scanlines`.
  Three pub entry points (`validateJpegDeep`,
  `validateJpegDeepFromHandle`, `validateJpegDeepFromBuffer`) consumed
  by `image_validators.zig`, `pdf_image_validator.zig`,
  `scientific_validators.zig`, `video_validator.zig`, and `mod.zig`'s
  test discovery — 9 call sites total. **Windows caveat:** the file
  contains a silent-skip violation that Phase 1 must close. On Windows,
  Zig's cImport cannot translate libjpeg-turbo's setjmp; the file
  silently falls back to a structural marker scan with no INFO/WARN.
  Phase 1 lift must surface that fallback as INFO ("JPEG deep
  validation unavailable on Windows — structural marker scan only;
  see https://github.com/ziglang/zig/issues/<...> for setjmp gap")
  rather than continue the silent degrade. Salvage the marker-walk as
  a private helper used during structural pre-flight before deep,
  never as a public terminal verdict.
- `src/core/jpeg2000_validator.zig` (317 lines) — lift. Currently
  wraps openjpeg; becomes jpegz's `jpeg2000.validate` Phase 1 path.
- `deps/openjpeg/` — vendored openjpeg source. Move to jpegz's deps.
- libjpeg-turbo dep (chearon Zig-build fork) — move to jpegz.

From `validate/`'s `image_validators.zig`:

- The libjpeg-turbo deep-validation path (see "============ JPEG Deep
  Validation (libjpeg-turbo) ============" comment block) — move into
  jpegz as Phase 1's baseline+progressive impl.

From zigimg fork:

- `src/formats/jpeg.zig` (322 lines, pure Zig baseline-only) —
  reference reading allowed (MIT). Useful for Phase 2 baseline
  cleanroom work; not lifted directly (zigimg's API differs).

---

## 4. Specification sources

**Primary spec authority:**

- **ISO/IEC 10918-1 / ITU-T Recommendation T.81** — the canonical JPEG
  spec. Free download from ITU-T at `https://www.itu.int/rec/T-REC-T.81`.
  This is THE spec for baseline, progressive, sequential, lossless,
  and arithmetic coding.
- **ISO/IEC 14495-1 / ITU-T T.87** — JPEG-LS. ITU-T mirror at
  `https://www.itu.int/rec/T-REC-T.87`.
- **ISO/IEC 15444-1 / ITU-T T.800** — JPEG 2000 Part 1 (core).
  ITU-T at `https://www.itu.int/rec/T-REC-T.800`.
- **JFIF (JPEG File Interchange Format)** — the de-facto JPEG file
  wrapper; original spec by Eric Hamilton, mirrored at
  `https://www.w3.org/Graphics/JPEG/jfif3.pdf`.
- **Exif 2.32** (CIPA DC-008-2019) — JPEG metadata extension widely
  used by cameras. `https://www.cipa.jp/std/documents/e/DC-X008-Translation-2019-E.pdf`.

**Reference implementations (read-permitted in Phase 2 — see
`LICENSING_NOTES.md`):**

- libjpeg-turbo source (BSD-3) — the gold-standard reference. Phase 2
  cleanroom work uses it as oracle (binary-only assertions) AND as
  ambiguity-resolution reference (read OK; cite if shape adapted).
- openjpeg source (BSD-2) — same, for JPEG 2000.
- libjpeg (BSD-3-style with attribution-required clause) — older,
  superseded by libjpeg-turbo. Reference if needed.
- charls (Apache-2) — JPEG-LS reference.

**Avoid (license incompatible or murky):**

- ffmpeg's JPEG codecs are LGPL/GPL depending on build config — do
  not read for Phase 2 cleanroom work.

---

## 5. Patent landscape

- **Baseline JPEG / DCT** — patent-free. Forgent Networks' claim
  (`5,253,341`) was rejected in 2007. Free to implement.
- **Arithmetic coding in JPEG (T.81 §F)** — IBM's patents on
  arithmetic coding expired in the early 2000s. Free.
- **JPEG-LS (T.87)** — HP's LOCO-I patent expired in 2018. Free.
- **JPEG 2000 (T.800)** — JPEG Committee's patent pool. Most patents
  expired or covered by ISO RAND grants. Two specific patents on
  visual masking (Quintessence Inc.) were declared but not enforced
  as of 2020. **Status:** widely-implemented in open source (openjpeg,
  GraphicsMagick, etc.); cleanroom implementation is low-risk in
  practice. **If unsure, ask Peter before shipping a JPEG 2000
  cleanroom.**

See `LICENSING_NOTES.md` for the long version.

---

## 6. Phase 1 milestones (in order)

1. **Scaffold + flake.nix.** `zig build`, basic Nix devShell with
   libjpeg-turbo + openjpeg + zig + hyperfine. Garnix CI passing.
2. **Baseline + progressive wrap.** `jpegz_decode` calls libjpeg-turbo
   via FFI. ~5–10 small JPEG fixtures (different sizes, 8-bit, 12-bit,
   gray, RGB, CMYK, progressive, baseline). Oracle assertion: decoded
   pixels match `djpeg` reference output byte-for-byte.
3. **Lossless lift.** Move validate's `jpeg_lossless_decoder.zig` →
   jpegz. Add fixtures (DICOM-style 16-bit lossless). Oracle:
   libjpeg-turbo's `cjpeg`/`djpeg` lossless path.
4. **Validate-only API.** `jpegz_validate` decodes through, discards
   pixels, returns report. This is what `validate` actually consumes.
5. **JPEG 2000 wrap.** `jpegz_jp2_decode` calls openjpeg via FFI.
   Fixtures (lossy + lossless 5-3 wavelet + lossless 9-7 wavelet,
   tile and codeblock variations). Oracle: openjpeg reference.
6. **C FFI.** Hand-curated `jpegz_core.h`. Validate's C CLI dogfood
   path consumes it.
7. **validate integration.** Replace `image_validators.zig`'s
   libjpeg-turbo direct-FFI path with jpegz. Replace
   `jpeg2000_validator.zig` with jpegz's `jpeg2000.validate`. Retire
   `jpeg_validator.zig` entirely (the structural-only one — see §7).
8. **tiffz integration.** When tiffz reaches its milestone 4 (JPEG-in-
   TIFF), it depends on jpegz's decode path.

---

## 7. Why no "structural only" verdict path

The existing `validate/src/core/jpeg_validator.zig` walks the JPEG
marker chain (SOI → segments → EOI) without decoding. It exists for
historical reasons. Per validate's no-silent-skip invariant
(RULES.md), structural-only as a *terminal verdict* is forbidden:

- If a file is JPEG, jpegz decodes it. Always.
- If decoding fails, jpegz reports the specific failure (FAIL).
- If decoding partially succeeds (some MCUs decode, some don't),
  jpegz reports a hard failure with location (FAIL or WARN with
  specifics — never silently degrade).
- The marker-chain walk lives inside jpegz as a private helper used
  during decode; it is never exposed as a public verdict.

This applies to all consumers. Validate must not expose a
"structural-only" JPEG result — every JPEG goes through jpegz's
deep path.

---

## 8. Build / test convention

- `flake.nix` controls all build-time deps. Garnix CI auto-evaluates.
- `./test` runs the full suite; `./build` builds; `./bm` benchmarks
  via hyperfine (Phase 2 perf comparison vs libjpeg-turbo).
- Test fixtures generated via `cjpeg` / `tjbench` / `opj_compress`
  from public-domain seed images (e.g. `magick -size 32x32 plasma:`).
- Real-world fixtures from validate's `ground_truth_examples/jpeg/`
  and `dng/` directories.
- TDD throughout: failing test before each wrap-impl step.

---

## 9. Open design questions (brainstorm before coding)

- **Allocation strategy.** Caller-allocates pixel buffer when size is
  known up front (decode mode). What about progressive scan-by-scan?
  Need a callback shape that lets caller allocate once-per-scan.
- **Color space conversion.** Decode to RGB always, or expose YCbCr /
  CMYK / grayscale and let caller convert? libjpeg-turbo gives both
  options; jpegz should too. Default to RGB for non-streaming;
  streaming exposes raw component planes.
- **DCT precision.** libjpeg-turbo has fast / accurate / float DCT
  modes. jpegz API should expose this; default to "accurate".
- **Streaming mode for JPEG 2000.** JPEG 2000's tile + packet
  structure makes streaming harder than baseline JPEG. Decide whether
  jp2 streaming is jp2-tile-per-callback or punt to "decode whole
  image only" in Phase 1.

Use `superpowers:brainstorming` to lock these.

---

## 10. Where things live

- This repo: `~/Documents-CloudManaged/jpegz/`
- Sibling reference implementations:
  - libjpeg-turbo (vendored Phase 1 dep, cleanroom-reference Phase 2)
  - openjpeg (same)
  - zigimg's `src/formats/jpeg.zig` (322 lines, MIT, baseline only —
    Phase 2 reference reading allowed)
- validate: `../validate/` — Phase 1 customer (replace its
  libjpeg-turbo direct-FFI path).
- tiffz: `../tiffz/` — Phase 1 customer (JPEG-in-TIFF, milestone 4).

---

## 11. Reporting back

When the next agent makes meaningful progress, drop a status note in:
- `~/Documents-CloudManaged/validate/inbox/`
- `~/Documents-CloudManaged/tiffz/inbox/`

Both projects are downstream consumers and need to know when jpegz is
ready for them to depend on.

---

Good luck. Phase 1 should ship in a few days. Phase 2 is months. The
honest path is to ship Phase 1, unblock validate + tiffz, then
incrementally retire each C dep over time as cleanroom replacements
mature.
