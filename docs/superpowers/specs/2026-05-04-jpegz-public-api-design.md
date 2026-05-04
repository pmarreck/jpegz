# jpegz Public API Design

**Date:** 2026-05-04 (EST)
**Status:** Approved (brainstormed with Peter; validate inbox handoff incorporated)
**Supersedes:** `SPEC.md` §2 sketch (`Source` parameter type, `decodeStreaming` shape)
**Companion:** `SPEC.md` §6 milestones, `inbox/2026-05-04-source-type-from-validate.md`

This document is the frozen public API design for **jpegz**. It is the
input contract for the upcoming implementation plan. All subsequent
implementation work plans against this design; deviations require
re-brainstorming.

---

## 1. Scope and posture

jpegz is a general-purpose, spec-complete JPEG-family decoder library
in Zig. The library covers the full ISO JPEG ecosystem under a single
ABI surface:

- Baseline JPEG (T.81 SOF0)
- Extended sequential JPEG (T.81 SOF1)
- Progressive JPEG (T.81 SOF2)
- Lossless JPEG (T.81 SOF3 §13 — DICOM, DNG raw)
- Arithmetic-coded variants (T.81 SOF9/10/11 §F — patents expired,
  rarely seen but spec-mandatory)
- JPEG-LS (T.87 / ISO 14495-1)
- JPEG 2000 (T.800 / ISO 15444 — separate sub-namespace)

It is built on hexagonal architecture:

```
Any consumer ──► C FFI (the real public API) ──► Zig core (no I/O)
```

The Zig core does no I/O. The C FFI is what every external consumer
uses, including the in-tree C CLI (which dogfoods the FFI).

**Two-phase plan** (per SPEC.md §1):

- **Phase 1 (this design):** wrap libjpeg-turbo (BSD-3) for T.81 + JPEG-LS,
  wrap openjpeg (BSD-2) for JPEG 2000, lift validate's existing
  pure-Zig lossless decoder. Ship a working ABI in days; unblock validate
  + tiffz immediately.
- **Phase 2 (future):** cleanroom pure-Zig replacement codec by codec;
  C deps retained only as test oracles. End state: zero C deps in shipped
  binary.

Every API decision in this document holds across both phases. The
C deps move under the hood; the public API does not change.

---

## 2. Decisions locked

| # | Topic | Choice | Reasoning |
|---|---|---|---|
| 1 | Allocation strategy | Library allocates pixel buffer via caller-supplied `Allocator`. Caller frees via `Image.deinit()`. | Standard Zig idiom; trivial across the FFI. |
| 2 | Color-space conversion | Library converts to RGB by default (matches libjpeg-turbo's `JCS_RGB` default). Grayscale and CMYK stay native. No `target_color_space` option in v1. | Serves 99% of consumers without an extra parameter. Adding the option later is non-breaking. |
| 3 | DCT precision | Not exposed. Uses libjpeg-turbo's "accurate" (`JDCT_ISLOW`) default. | Premature optimization knob; cleanroom Phase 2 has to reimplement whatever we expose. |
| 4 | JPEG 2000 streaming | Whole-image only. No `decodeStreamingTiles` / `decodeStreamingResolutions` in v1. | openjpeg streaming has tricky lifetime rules; no v1 consumer asks. |
| 5 | T.81 streaming variants | `decode` (universal, all modes) plus `decodeStreamingRows` (sequential / lossless / arithmetic only; `error.NotRowStreamable` on progressive). Progressive scan-streaming deferred to v2. | Real memory/latency win on the high-volume sequential path. Progressive can't truly stream rows; rejecting cleanly is more honest than fake-streaming. |
| 6 | `data` parameter type | Plain `[]const u8` byte slice. No `Source` vtable in v1. Caller must keep `data` valid through the call's return. | validate's inbox handoff (`inbox/2026-05-04-source-type-from-validate.md`) argued this case — JPEGs are small enough that a streaming `Source` doesn't pay off, and the libjpeg-turbo / openjpeg wrappers materialize bytes anyway. |
| 7 | Pixel storage for >8-bit | `[]u16` regardless of actual precision (8/12/16). `bits_per_sample` reports meaningful bit count. | Wasteful at 12-bit; simpler. Optimize later if needed. |
| 8 | Streaming callback errors | Callback returns `anyerror!void`; library propagates via `error.CallbackAborted`. Original error preserved in thread-local last-error message. | No information loss; matches Zig idioms. |
| 9 | C error mapping | Sequential int codes from a build-generated header. Un-mapped Zig errors break the build. Plus thread-local `jpegz_last_error_message()`. | The tiffz pattern. Zero drift between Zig and C. |
| 10 | Validate-only mode | First-class `validate(data) → ValidationReport`. Walks the bitstream; never materializes pixels; accumulates findings (does NOT fail-fast). Returns Zig error only on OOM. | validate-the-project's primary path. Audit tools want every finding, not the first one. |

### 2.1 Three decode modes (the trichotomy)

| Mode | Allocates pixels? | Returns | Stop on first error? | Primary consumer |
|---|---|---|---|---|
| `decode` | ✅ full buffer | `Image` | ✅ fail-fast | image viewers, tiffz, format converters |
| `decodeStreamingRows` | ⚠️ one row at a time | `ImageMetadata` (no pixels) | ✅ fail-fast | server pipelines, low-RAM viewers |
| `validate` | ❌ none | `ValidationReport` | ❌ accumulates | validate, audit tools |

---

## 3. Public Zig API

### 3.1 Public types — `src/jpegz.zig`

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const errors = @import("core/errors.zig");

pub const DecodeError = errors.DecodeError;
pub const Severity    = errors.Severity;
pub const Variant     = errors.Variant;
pub const FindingCode = errors.FindingCode;

/// Source-encoded color space, populated by the decoder.
pub const ColorSpace = enum(u8) {
    unknown,
    grayscale,
    rgb,
    ycbcr,           // T.81 most-common; converted to RGB on output
    cmyk,
    ycck,            // Adobe YCCK; converted to CMYK on output
    srgb,            // JP2 enumerated colorspace 16
    greyscale_jp2,   // JP2 enumerated colorspace 17
};

/// What the decoded `pixels` buffer contains, after conversion.
pub const PixelLayout = enum(u8) {
    grayscale, // 1 sample per pixel
    rgb,       // 3 samples per pixel, R-G-B order
    cmyk,      // 4 samples per pixel, C-M-Y-K order
};

/// Decoded image. Caller owns `pixels`. Free via `image.deinit(allocator)`.
///
/// For 8-bit images, `pixels` is byte-shaped.
/// For 12/16-bit images, `pixels` is `u16`-shaped in **host endianness**,
/// reinterpret-cast as `[]u8`; access via `image.pixelsU16()`. Library
/// guarantees the unused high bits are zero on <16-bit precision.
pub const Image = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    /// 1 = grayscale, 3 = RGB, 4 = CMYK
    channels: u8,
    /// 8 (default) | 12 (12-bit baseline) | 16 (lossless DICOM/DNG)
    bits_per_sample: u8,
    /// Source color space, before output conversion (informational).
    source_color_space: ColorSpace,
    /// What the buffer actually contains.
    layout: PixelLayout,

    pub fn rowStride(self: Image) usize {
        const bytes_per_sample: usize = if (self.bits_per_sample > 8) 2 else 1;
        return self.width * self.channels * bytes_per_sample;
    }

    pub fn pixelsU16(self: Image) []u16 {
        std.debug.assert(self.bits_per_sample > 8);
        return std.mem.bytesAsSlice(u16, self.pixels);
    }

    pub fn deinit(self: *Image, allocator: Allocator) void {
        allocator.free(self.pixels);
        self.* = undefined;
    }
};

/// Returned by `decodeStreamingRows`. No pixel buffer.
pub const ImageMetadata = struct {
    width: u32,
    height: u32,
    channels: u8,
    bits_per_sample: u8,
    source_color_space: ColorSpace,
    layout: PixelLayout,

    pub fn rowStride(self: ImageMetadata) usize {
        const bytes_per_sample: usize = if (self.bits_per_sample > 8) 2 else 1;
        return self.width * self.channels * bytes_per_sample;
    }
};

/// Row-streaming callback. Library calls `on_row` once per emitted row in
/// raster order (y = 0..height-1). `row` is borrowed; copy if you need it
/// past return. Return an error to abort decode.
pub const RowCallback = struct {
    on_row: *const fn (ctx: ?*anyopaque, row: []const u8, y: u32) anyerror!void,
    ctx: ?*anyopaque = null,
};

/// Validation finding. See `core/errors.zig` for `Severity`, `FindingCode`.
pub const Finding = struct {
    severity: Severity,
    code: FindingCode,
    /// Byte offset in `data` where issue was detected, if known.
    offset: ?u64 = null,
    /// Optional detail string. Owned by report's allocator.
    detail: ?[]const u8 = null,
};

/// Structured validation report. Always populated; structural problems
/// are findings (not Zig errors). Free via `deinit`.
pub const ValidationReport = struct {
    overall: Severity,
    variant: Variant,
    width: ?u32,
    height: ?u32,
    findings: std.ArrayList(Finding),

    pub fn isValid(self: ValidationReport) bool {
        return self.overall == .pass or self.overall == .info or self.overall == .warn;
    }

    pub fn deinit(self: *ValidationReport) void {
        const a = self.findings.allocator;
        for (self.findings.items) |f| {
            if (f.detail) |d| a.free(d);
        }
        self.findings.deinit();
        self.* = undefined;
    }
};
```

### 3.2 T.81 / T.87 entry points

```zig
/// Library version (semver string).
pub const version: [:0]const u8 = "0.1.0";

/// Decode any T.81 / T.87 JPEG (sequential / progressive / lossless /
/// arithmetic / JPEG-LS) into a fully-realized Image. Universal entry.
///
/// `data` must remain valid through the call's return.
pub fn decode(allocator: Allocator, data: []const u8) DecodeError!Image;

/// Decode JPEG row-by-row, invoking `cb` once per emitted row in raster
/// order. Returns `error.NotRowStreamable` for SOF2 progressive — caller
/// can fall back to `decode`.
pub fn decodeStreamingRows(
    allocator: Allocator,
    data: []const u8,
    cb: RowCallback,
) DecodeError!ImageMetadata;

/// Walk the bitstream without materializing pixels. Accumulates findings.
/// Always returns a populated report; structural problems are findings,
/// not errors. Returns Zig error only on OOM.
pub fn validate(
    allocator: Allocator,
    data: []const u8,
) error{OutOfMemory}!ValidationReport;
```

### 3.3 JPEG 2000 sub-namespace

```zig
pub const jpeg2000 = struct {
    /// Decode a JPEG 2000 codestream (J2K) or JP2 file into an Image.
    /// Whole-image only; tile/resolution streaming = v2.
    pub fn decode(allocator: Allocator, data: []const u8) DecodeError!Image;

    pub fn validate(
        allocator: Allocator,
        data: []const u8,
    ) error{OutOfMemory}!ValidationReport;
};
```

### 3.4 Auto-detection rules

`decode` / `decodeStreamingRows` / `validate` auto-detect the variant from
the leading bytes:

- `0xFF 0xD8 0xFF` (SOI marker) → T.81 / T.87 path (libjpeg-turbo wraps,
  or lifted lossless decoder for SOF3)
- `0x00 0x00 0x00 0x0C 0x6A 0x50 0x20 0x20` ("....jP  ") → JP2 box (route to
  openjpeg). Caller can also call `jpeg2000.decode` directly.
- `0xFF 0x4F 0xFF 0x51` → raw J2K codestream → openjpeg
- Anything else → `error.InvalidMarker`
- `data.len < 4` (too short to detect any signature) → `error.TruncatedStream`

Calling `jpeg2000.decode` on a T.81 file or vice-versa returns
`error.InvalidJp2Codestream` / `error.InvalidMarker` respectively.

---

## 4. Error model

### 4.1 Single source of truth — `src/core/errors.zig`

The Zig declarations are authoritative. The C header is generated from them
at build time. Drift is impossible because mismatch is a build failure.

```zig
//! Public error vocabulary for jpegz. Ordered by introduction;
//! new entries APPEND, never reorder. Numeric codes are stable forever.

pub const DecodeError = error{
    NotImplemented,          // = -1
    InvalidMarker,           // = -2
    UnsupportedPrecision,    // = -3
    TruncatedStream,         // = -4
    NotRowStreamable,        // = -5
    BackendError,            // = -6
    InvalidJp2Codestream,    // = -7
    OutOfMemory,             // = -8
    CallbackAborted,         // = -9
};

pub const Severity = enum(u8) {
    pass = 0,
    info = 1,
    warn = 2,
    fail = 3,
};

pub const Variant = enum(u8) {
    unknown                = 0,
    baseline_huffman       = 1,
    extended_huffman       = 2,
    progressive_huffman    = 3,
    lossless_huffman       = 4,
    baseline_arithmetic    = 5,
    progressive_arithmetic = 6,
    lossless_arithmetic    = 7,
    jpegls                 = 8,
    jpeg2000               = 9,
};

/// Validation finding codes. Numeric values stable; new entries APPEND.
pub const FindingCode = enum(u32) {
    // ── Structural (1..49) ──
    missing_soi               = 1,
    missing_eoi               = 2,
    truncated_stream          = 3,
    bad_marker_length         = 4,
    unknown_marker            = 5,
    duplicate_sof             = 6,

    // ── T.81 codec-specific (50..99) ──
    invalid_sof_precision       = 50,
    huffman_table_corrupt       = 51,
    quantization_table_corrupt  = 52,
    arithmetic_table_corrupt    = 53,
    sof_component_count_invalid = 54,
    sos_component_mismatch      = 55,
    restart_marker_missing      = 56,
    restart_marker_unexpected   = 57,
    dct_coefficient_overflow    = 58,
    progressive_scan_invalid    = 59,

    // ── Lossless (T.81 §13) (100..119) ──
    lossless_predictor_invalid       = 100,
    lossless_pointtransform_invalid  = 101,

    // ── JPEG-LS (T.87) (120..139) ──
    jpegls_invalid_run_mode      = 120,
    jpegls_context_table_invalid = 121,

    // ── JPEG 2000 (140..179) ──
    jp2_invalid_signature        = 140,
    jp2_invalid_codestream       = 141,
    jp2_bad_progression_order    = 142,
    jp2_tile_decode_failed       = 143,
    jp2_codeblock_decode_failed  = 144,

    // ── Informational (severity = .info) (200..249) ──
    arithmetic_coding_used    = 200,
    twelve_bit_precision      = 201,
    sixteen_bit_lossless      = 202,
    progressive_scan_count    = 203,
    embedded_thumbnail_present = 204,
    exif_metadata_present     = 205,
    icc_profile_present       = 206,
    jp2_uses_9x7_wavelet      = 207,
    jp2_uses_5x3_wavelet      = 208,
};
```

### 4.2 Mapper — `src/ffi/c_api.zig`

Exhaustive switch. Adding a Zig variant without updating this is a
compile-time error.

```zig
pub fn toCStatus(err: errors.DecodeError) c_int {
    return switch (err) {
        error.NotImplemented        => -1,
        error.InvalidMarker         => -2,
        error.UnsupportedPrecision  => -3,
        error.TruncatedStream       => -4,
        error.NotRowStreamable      => -5,
        error.BackendError          => -6,
        error.InvalidJp2Codestream  => -7,
        error.OutOfMemory           => -8,
        error.CallbackAborted       => -9,
    };
}
```

### 4.3 Header generator — `tools/gen_c_header.zig`

Standalone Zig executable run as a `build.zig` step. Walks
`DecodeError` and `FindingCode` at comptime, emits
`include/jpegz_errno.h` with `JPEGZ_OK = 0`, `JPEGZ_ERR_*` (negative)
and `JPEGZ_FINDING_*` (positive) entries.

### 4.4 Last-error message

```zig
threadlocal var last_error_buf: [512]u8 = undefined;
threadlocal var last_error_len: usize = 0;

export fn jpegz_last_error_message() [*:0]const u8 {
    last_error_buf[last_error_len] = 0;
    return @ptrCast(&last_error_buf);
}
```

Per-thread, NUL-terminated, cleared on the next successful call.

### 4.5 Properties

| Property | Mechanism |
|---|---|
| Adding a Zig error without a C code | `toCStatus` switch is non-exhaustive → build fails |
| Renaming a Zig error | mapper references old name → build fails |
| Removing a Zig error | C code reserved forever; new errors append → safe |
| C-only codes | codegen reads only Zig → impossible |
| FFI thread safety | per-thread last-error → no cross-thread stomping |

---

## 5. C ABI

`include/jpegz_core.h` is **hand-curated** (auto-generated C from Zig
produces ugly output). The error enum (`include/jpegz_errno.h`) is
**auto-generated** from the Zig source of truth.

### 5.1 jpegz_core.h (curated header)

```c
/* jpegz_core.h — public C ABI for jpegz.
 *
 * Buffer-lifetime: every (data, len) pair is borrowed for the call's
 *   duration only.
 * Thread safety: every function reentrant; no shared state except the
 *   thread-local last-error string.
 * Memory: structs containing pointers own them; free via the matching
 *   _free function.
 */

#ifndef JPEGZ_CORE_H
#define JPEGZ_CORE_H

#include <stdint.h>
#include <stddef.h>
#include "jpegz_errno.h"  /* Auto-generated. Defines jpegz_status_t,
                             jpegz_finding_code_t. */

#ifdef __cplusplus
extern "C" {
#endif

/* ── Versioning ────────────────────────────────────────────────── */
#define JPEGZ_VERSION_MAJOR 0
#define JPEGZ_VERSION_MINOR 1
#define JPEGZ_VERSION_PATCH 0
const char *jpegz_version(void);

/* ── Diagnostics ───────────────────────────────────────────────── */
const char *jpegz_last_error_message(void);

/* ── Pixel data ────────────────────────────────────────────────── */
typedef enum {
    JPEGZ_LAYOUT_GRAYSCALE = 0,
    JPEGZ_LAYOUT_RGB       = 1,
    JPEGZ_LAYOUT_CMYK      = 2,
} jpegz_pixel_layout_t;

typedef enum {
    JPEGZ_CS_UNKNOWN        = 0,
    JPEGZ_CS_GRAYSCALE      = 1,
    JPEGZ_CS_RGB            = 2,
    JPEGZ_CS_YCBCR          = 3,
    JPEGZ_CS_CMYK           = 4,
    JPEGZ_CS_YCCK           = 5,
    JPEGZ_CS_SRGB           = 6,
    JPEGZ_CS_GREYSCALE_JP2  = 7,
} jpegz_color_space_t;

typedef struct {
    uint8_t              *pixels;
    size_t                pixels_len;       /* size in bytes */
    uint32_t              width;
    uint32_t              height;
    uint8_t               channels;         /* 1 | 3 | 4 */
    uint8_t               bits_per_sample;  /* 8 | 12 | 16 */
    jpegz_color_space_t   source_color_space;
    jpegz_pixel_layout_t  layout;
} jpegz_image_t;

void jpegz_image_free(jpegz_image_t *image);

/* ── Decode (T.81 / T.87) ──────────────────────────────────────── */
jpegz_status_t jpegz_decode(
    const uint8_t  *data,
    size_t          len,
    jpegz_image_t  *out_image
);

/* ── Decode (JPEG 2000) ────────────────────────────────────────── */
jpegz_status_t jpegz_jp2_decode(
    const uint8_t  *data,
    size_t          len,
    jpegz_image_t  *out_image
);

/* ── Streaming (T.81 only) ─────────────────────────────────────── */
typedef struct {
    uint32_t              width;
    uint32_t              height;
    uint8_t               channels;
    uint8_t               bits_per_sample;
    jpegz_color_space_t   source_color_space;
    jpegz_pixel_layout_t  layout;
} jpegz_image_metadata_t;

typedef jpegz_status_t (*jpegz_row_callback_fn)(
    void           *ctx,
    const uint8_t  *row,
    size_t          row_len,
    uint32_t        y
);

jpegz_status_t jpegz_decode_streaming_rows(
    const uint8_t           *data,
    size_t                   len,
    jpegz_row_callback_fn    callback,
    void                    *callback_ctx,
    jpegz_image_metadata_t  *out_metadata
);

/* ── Validation ────────────────────────────────────────────────── */
typedef enum {
    JPEGZ_SEVERITY_PASS = 0,
    JPEGZ_SEVERITY_INFO = 1,
    JPEGZ_SEVERITY_WARN = 2,
    JPEGZ_SEVERITY_FAIL = 3,
} jpegz_severity_t;

typedef enum {
    JPEGZ_VARIANT_UNKNOWN                 = 0,
    JPEGZ_VARIANT_BASELINE_HUFFMAN        = 1,
    JPEGZ_VARIANT_EXTENDED_HUFFMAN        = 2,
    JPEGZ_VARIANT_PROGRESSIVE_HUFFMAN     = 3,
    JPEGZ_VARIANT_LOSSLESS_HUFFMAN        = 4,
    JPEGZ_VARIANT_BASELINE_ARITHMETIC     = 5,
    JPEGZ_VARIANT_PROGRESSIVE_ARITHMETIC  = 6,
    JPEGZ_VARIANT_LOSSLESS_ARITHMETIC     = 7,
    JPEGZ_VARIANT_JPEGLS                  = 8,
    JPEGZ_VARIANT_JPEG2000                = 9,
} jpegz_variant_t;

typedef struct {
    jpegz_severity_t      severity;
    jpegz_finding_code_t  code;
    /* INT64_MIN means "not applicable". Any other value is a byte offset. */
    int64_t               offset;
    /* NUL-terminated. NULL = no detail. Owned by report. */
    const char           *detail;
} jpegz_finding_t;

typedef struct {
    jpegz_severity_t       overall;
    jpegz_variant_t        variant;
    /* 0 means "not parsed". (No real JPEG is 0×0.) */
    uint32_t               width;
    uint32_t               height;
    const jpegz_finding_t *findings;
    size_t                 findings_len;
} jpegz_validation_report_t;

void jpegz_validation_report_free(jpegz_validation_report_t *report);

jpegz_status_t jpegz_validate(
    const uint8_t              *data,
    size_t                      len,
    jpegz_validation_report_t  *out_report
);

jpegz_status_t jpegz_jp2_validate(
    const uint8_t              *data,
    size_t                      len,
    jpegz_validation_report_t  *out_report
);

#ifdef __cplusplus
}
#endif

#endif /* JPEGZ_CORE_H */
```

### 5.2 Ownership / lifetime contract

| Pointer | Owner | Free via |
|---|---|---|
| `jpegz_image_t.pixels` | library | `jpegz_image_free(&image)` |
| `jpegz_validation_report_t.findings` | library | `jpegz_validation_report_free(&report)` |
| `jpegz_finding_t.detail` | library (lives inside `findings`) | freed transitively by `jpegz_validation_report_free` |
| `data` parameter (decode functions) | caller | caller's responsibility; library borrows |
| `jpegz_last_error_message()` return value | library (thread-local) | do not free; valid until next jpegz call on this thread |

---

## 6. Build wiring

```zig
// build.zig (sketch — full version in implementation plan)

// 1. Generate the auto-generated header.
const gen_header = b.addExecutable(.{
    .name = "jpegz-gen-header",
    .root_source_file = b.path("tools/gen_c_header.zig"),
    .target = b.host,
});
const run_gen = b.addRunArtifact(gen_header);
const generated_errno_path = run_gen.addOutputFileArg("jpegz_errno.h");

// 2. Build the static library.
const lib = b.addLibrary(.{
    .name = "jpegz",
    .linkage = .static,
    .root_module = jpegz_mod,
});
lib.step.dependOn(&run_gen.step);
b.installArtifact(lib);

// 3. Install both headers.
b.installFile(b.path("include/jpegz_core.h"), "include/jpegz_core.h");
b.installFile(generated_errno_path, "include/jpegz_errno.h");
```

---

## 7. Phase 1 milestone alignment (SPEC.md §6 cross-reference)

| Milestone | Deliverable | This-design touchpoints |
|---|---|---|
| M1.1 | Scaffold + flake.nix + build.zig + smoke tests | Done 2026-05-04 |
| M1.2 | **This design + brainstorm § 9 lock** | THIS DOCUMENT |
| M1.3 | Baseline + progressive wrap (libjpeg-turbo) | §3.2 `decode`, §3.2 `decodeStreamingRows`, error-mapping § 4 |
| M1.4 | Lossless lift (validate's existing decoder) | §3.2 `decode` for SOF3 path |
| M1.5 | `validate`-only API | §3.2 `validate`, §3.1 `ValidationReport` |
| M1.6 | JPEG 2000 wrap (openjpeg) | §3.3 `jpeg2000.{decode,validate}` |
| M1.7 | C FFI | §5 hand-curated `jpegz_core.h` + auto `jpegz_errno.h` |
| M1.8 | validate integration | replaces validate's libjpeg-turbo direct-FFI |
| M1.9 | tiffz integration | tiffz milestone 4 (JPEG-in-TIFF) |

---

## 8. Out of scope (deferred to v2 PLAN)

| # | Feature | Trigger to revisit |
|---|---|---|
| 1 | `decodeStreamingScans` (progressive scan-streaming, browser-preview UX) | First image-viewer / browser-like consumer asks. |
| 2 | JP2 tile / resolution / quality-layer streaming | First cinema / GIS / satellite consumer asks. |
| 3 | `target_color_space` decode option | Consumer needs raw YCbCr planes. |
| 4 | `dct_precision` decode option (fast / accurate / float) | Profiling-driven need surfaces. |
| 5 | `target_bit_depth` decode option | Consumer wants in-codec downsampling. |
| 6 | Encoder side (`jpegz.encode`) | Sibling project `jpegzz` or follow-up milestone. |
| 7 | Streaming `Source` vtable (pread-style) | A real consumer hits a wall with multi-GB JP2 files. |
| 8 | JPEG XL support | Sibling project `libjxlz`. |
| 9 | Async / cancellation tokens | Only if v2 streaming for huge JP2 lands. |

---

## 9. Test strategy (cross-reference)

Per CLAUDE.md TDD discipline + SPEC.md §8:

- **Per-codec fixtures** generated from public-domain seed images via
  `cjpeg`, `tjbench`, `opj_compress`. Variants: baseline / progressive /
  lossless / arithmetic / 12-bit / JPEG-LS / JP2 (lossy and lossless).
- **Real-world fixtures** lifted from validate's
  `ground_truth_examples/jpeg/` and `dng/`.
- **Oracle assertions:** decoded pixels must match `djpeg` /
  `opj_decompress` byte-for-byte for every fixture.
- **Validate-mode tests** assert the right `Severity` / `FindingCode`
  combinations on hand-curated broken fixtures.
- **C ABI smoke tests** call every `jpegz_*` function from a tiny C
  program (the in-tree CLI dogfoods this).
- **Failing-test-first** at each milestone entry: write the test that
  fails (because the wrap-impl doesn't exist yet), then make it pass.

---

## 10. Open follow-ups

- **SPEC.md §2 update** — current sketch shows `Source` as the
  parameter type. Replace with `data: []const u8` (per validate's
  inbox handoff). Edit at the start of M1.3 implementation.
- **Inbox housekeeping** — move
  `inbox/2026-05-04-source-type-from-validate.md` to an archived
  location (or delete) once M1.3 starts; the design has absorbed it.

---

— Design locked 2026-05-04 EST. Implementation plan to follow.
