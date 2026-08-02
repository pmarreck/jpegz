//! jpegz — spec-complete JPEG family decoder library (Zig core).
//!
//! Public API. The full API design lives in
//! `docs/superpowers/specs/2026-05-04-jpegz-public-api-design.md`.
//!
//! Phase 1 wraps libjpeg-turbo (BSD-3) for T.81 + JPEG-LS, openjpeg
//! (BSD-2) for JPEG 2000, and lifts validate's existing pure-Zig
//! lossless decoder for SOF3. Phase 2 retires the C deps with
//! cleanroom Zig replacements.
//!
//! No I/O in the core — all data flows in via `[]const u8` byte slices
//! the caller is responsible for materializing (mmap, readFile, network
//! buffer, embedded resource). The C FFI dogfoods this.

const std = @import("std");
const Allocator = std.mem.Allocator;
const build_options = @import("jpegz_build_options");

/// Sibling Zig project supplying the cleanroom T.800 codestream walker
/// behind `jpeg2000.validate`. Imported as a plain Zig module, NOT through
/// jp2z's C ABI, per Peter's 2026-07-31 facade ruling. Only `jp2z.validate`
/// is referenced: jp2z's decode path links openjpeg, and Zig's lazy
/// analysis is what keeps that C dependency off every jpegz consumer's
/// graph (guarded by `tests/cli/no_c_consumer.bash`).
const jp2z = @import("jp2z");
// ── Re-exports from canonical core modules ──────────────────────
const errors = @import("core/errors.zig");
pub const DecodeError = errors.DecodeError;
pub const Severity = errors.Severity;
pub const Variant = errors.Variant;
pub const FindingCode = errors.FindingCode;

const core_types = @import("core/types.zig");
pub const ColorSpace = core_types.ColorSpace;
pub const PixelLayout = core_types.PixelLayout;
pub const Image = core_types.Image;
pub const ImageMetadata = core_types.ImageMetadata;

/// Side-channel collector for spec-deviation findings emitted by the
/// cleanroom decoder during a lenient (tolerant) decode. Same `Finding`
/// shape used by `ValidationReport` — `severity` / `code` / `offset`
/// / `detail` — so consumers can uniformly walk the items in either
/// container.
///
/// Lifecycle: `FindingsSink.init(allocator)` → pass `&sink` to
/// `decodeWithOptions(.., .{ .findings_sink = &sink, .lenient = true })`
/// → walk `sink.items()` → `sink.deinit()`.
///
/// `lenient = true` + `findings_sink` attached is how callers opt into
/// libjpeg-turbo-style truncation recovery (`JWRN_HIT_MARKER` /
/// `JWRN_JPEG_EOF` parity). With `lenient = false` (default), the sink
/// still receives non-fatal markers like `extraneous_bytes_before_marker`,
/// but truncated entropy is a hard error.
pub const FindingsSink = @import("decode/findings.zig").FindingsSink;

pub const version: [:0]const u8 = "0.1.0";

/// Direct entry into the JPEG-LS cleanroom decoder. The main `decode`
/// dispatcher tries cleanroom first and falls back to the charls
/// wrapper on `NotImplemented`; this entry skips that fallback so
/// cleanroom-coverage tests can't be masked by charls.
pub const jpegls_cleanroom_decode = @import("decode/jpegls.zig").decode;

const last_error = @import("core/last_error.zig");

/// Return the thread-local last-error message, or an empty slice if
/// none has been recorded since the last successful call on this
/// thread. The slice borrows from a static per-thread buffer — copy
/// the bytes if you need them past the next public API call.
///
/// Useful when a generic `DecodeError` (e.g. `error.CallbackAborted`)
/// hides the underlying detail; this gives callers the original
/// reason. Same buffer the C ABI surfaces via
/// `jpegz_last_error_message()` — no duplication.
pub fn lastErrorMessage() []const u8 {
    return last_error.current();
}

// ─────────────────────────────────────────────────────────────────────
// 1. Pixel-data types
// ─────────────────────────────────────────────────────────────────────

// `ColorSpace`, `PixelLayout`, `Image`, `ImageMetadata` are
// re-exported from `core/types.zig` above. See that file for full
// documentation. Splitting them out lets the cleanroom decoder
// (`src/decode/baseline.zig` etc.) import the same types without
// creating a module cycle through this file.

// ─────────────────────────────────────────────────────────────────────
// 2. Streaming
// ─────────────────────────────────────────────────────────────────────

/// Row-streaming callback. Library calls `on_row` once per emitted row
/// in raster order (y = 0, 1, …, height-1). `row` is borrowed; copy if
/// you need it past return. Return an error to abort decode — the
/// library propagates it back as `error.CallbackAborted` and stores the
/// original error message via the thread-local last-error mechanism
/// (visible to C callers as `jpegz_last_error_message()`).
pub const RowCallback = struct {
    on_row: *const fn (ctx: ?*anyopaque, row: []const u8, y: u32) anyerror!void,
    ctx: ?*anyopaque = null,
};

// ─────────────────────────────────────────────────────────────────────
// 3. Validation
// ─────────────────────────────────────────────────────────────────────

/// One observation about the bitstream. Multiple findings per report
/// is normal; a healthy image is `findings.items.len == 0`.
pub const Finding = struct {
    severity: Severity,
    code: FindingCode,
    /// Byte offset in `data` where the issue was detected, if known.
    /// 0 is a legitimate offset; `null` means "didn't apply / unknown".
    offset: ?u64 = null,
    /// Optional human-readable detail. Allocated from the report's
    /// allocator; freed by `ValidationReport.deinit()`. `null` = no detail.
    detail: ?[]const u8 = null,
};

/// Structured validation report. `validate` and `jpeg2000.validate`
/// always populate this and return successfully — even for badly-broken
/// input. A Zig error is reserved for catastrophic conditions (OOM,
/// internal library bug). Structural problems with the file go in
/// `findings` with severity `.fail`.
pub const ValidationReport = struct {
    /// Highest severity in `findings`. `.pass` if findings is empty.
    overall: Severity,
    /// Best-effort variant detection (set even on fail, where possible).
    variant: Variant,
    /// Image dimensions from SOF, when available. `null` if SOF not parsed.
    width: ?u32,
    height: ?u32,
    /// All findings, in detection order. Caller must pass the same
    /// allocator to `deinit` that was used to construct the report
    /// (Zig 0.15.2 std.ArrayList is unmanaged).
    findings: std.ArrayList(Finding),

    pub fn isValid(self: ValidationReport) bool {
        return self.overall == .pass or self.overall == .info or self.overall == .warn;
    }

    pub fn deinit(self: *ValidationReport, allocator: Allocator) void {
        for (self.findings.items) |f| {
            if (f.detail) |d| allocator.free(d);
        }
        self.findings.deinit(allocator);
        self.* = undefined;
    }
};

// ─────────────────────────────────────────────────────────────────────
// 4. Public entry points
// ─────────────────────────────────────────────────────────────────────

/// Caller-controlled decode parameters. Adopted verbatim from the
/// cross-project threading-control convention validate proposed
/// 2026-05-07 (`inbox/2026-05-07-validate-threading-control-convention.md`).
/// Same shape will land in tiffz at M6+.
pub const DecodeOptions = struct {
    /// Number of threads jpegz may use for parallelizable decode steps.
    /// `1` (default) = run sequentially in the calling thread. No
    ///   threads spawned, no oversubscription with caller-side worker
    ///   pools (validate's primary concern).
    /// `0` = explicit caller opt-in to library-side auto-detection
    ///   (`std.Thread.getCpuCount()` capped at the number of independent
    ///   decode units, e.g. RST segments or MCU rows).
    /// `>1` = explicit budget; library may use fewer if the work
    ///   doesn't amortize.
    ///
    /// **No globals, no env vars, no implicit auto-detection.** The
    /// caller decides every call. Per-call decision so different
    /// pipelines in one process can make different choices.
    ///
    /// Today (M2.1d): the cleanroom decoder honors `threads` for
    /// parallelizable pipeline stages (IDCT, dequant, color conv,
    /// chroma upsample) when the image is large enough to amortize
    /// thread setup. Wrapper paths pass through where supported
    /// (openjpeg → `opj_codec_set_threads`); libjpeg-turbo's
    /// traditional API has no thread param.
    threads: u8 = 1,

    /// `false` (default) — strict decode. Truncated entropy data,
    /// missing markers, or any other bitstream deviation that
    /// libjpeg-turbo silently warns about returns a `DecodeError`.
    ///
    /// `true` — tolerant decode. The cleanroom mirrors libjpeg-turbo's
    /// recovery behavior: truncated baseline scans yield partial
    /// pixels (the rest filled with solid gray from zero-coef IDCT
    /// blocks). When a `findings_sink` is also attached, the
    /// deviation is reported there as a `Finding(.warn, ...)`.
    ///
    /// Pick `true` for thumbnail generators, image viewers, and
    /// best-effort format converters. Stay `false` (or omit) for
    /// pipelines where any deviation should halt processing.
    lenient: bool = false,

    /// Optional collector for `Finding(.warn, ...)` and
    /// `Finding(.info, ...)` notes the cleanroom emits while
    /// decoding. Caller owns the sink and frees it via
    /// `FindingsSink.deinit()`.
    ///
    /// What gets emitted is independent of `lenient`:
    ///   - `.extraneous_bytes_before_marker` fires whenever the
    ///     marker walker silently skips non-0xFF bytes (libjpeg's
    ///     `JWRN_EXTRANEOUS_DATA` equivalent).
    ///   - `.insufficient_data` fires only in lenient mode when a
    ///     truncated scan was recovered.
    ///
    /// `null` (default) suppresses all emission — the decoder still
    /// tolerates whatever it's been told to tolerate, but no
    /// findings are recorded.
    findings_sink: ?*FindingsSink = null,
};

/// Decode any T.81 / T.87 JPEG (sequential / progressive / lossless /
/// arithmetic / JPEG-LS) into a fully-realized `Image`. Universal
/// entry point — works for every storage mode and precision.
///
/// `data` must remain valid through the call's return.
///
/// Output:
///   - 8-bit images: `pixels` is byte-shaped, RGB/grayscale/CMYK per `layout`.
///   - 12/16-bit images: `pixels` is `u16` host-endian (reinterpret-cast
///     as `[]u8`); accessed via `image.pixelsU16()`.
///
/// Default options (`threads = 1`). For caller-controlled threading,
/// use `decodeWithOptions`.
pub fn decode(allocator: Allocator, data: []const u8) DecodeError!Image {
    return decodeWithOptions(allocator, data, .{});
}

/// Same as `decode` but accepts a `DecodeOptions` struct for caller-
/// controlled behavior (today: thread-count budget). Existing call
/// sites of `decode` are unaffected; new consumers needing thread
/// control call this entry point.
pub fn decodeWithOptions(
    allocator: Allocator,
    data: []const u8,
    options: DecodeOptions,
) DecodeError!Image {
    // Cleanroom-only at runtime. Each cleanroom path returns
    // `error.NotImplemented` for variants it doesn't own; the
    // dispatcher tries them in order and surfaces NotImplemented
    // to the caller if none match — NEVER falls back to a
    // libjpeg/charls runtime dependency. The C wrappers live
    // exclusively under `jpegz.internal.*` as build-time oracles
    // for byte-perfect regression testing.
    //
    // (The lone documented exception is `jpegz.jpeg2000.decode`,
    // which delegates to openjpeg until the jp2z JP2 path lands — a
    // faithful Zig PORT of openjpeg (BSD-2, attributed), NOT a cleanroom
    // reimplementation — separate entry point, not reached through this
    // dispatcher.)
    const baseline = @import("decode/baseline.zig");

    // JPEG-LS comes first: T.87 uses a different SOF marker (SOF55 =
    // 0xF7) that the other cleanroom paths' marker walkers don't
    // recognize — they'd misclassify and surface InvalidMarker
    // instead of NotImplemented.
    const jpegls_cleanroom = @import("decode/jpegls.zig");
    if (jpegls_cleanroom.decode(allocator, data)) |img| {
        return img;
    } else |err| switch (err) {
        error.NotImplemented => {},
        else => return err,
    }

    // Try baseline cleanroom first (SOF0). Convert public DecodeOptions
    // → baseline's structurally-identical DecodeOptions (separate types
    // to keep baseline.zig free of a dependency on the parent module).
    const baseline_opts: baseline.DecodeOptions = .{
        .threads = options.threads,
        .lenient = options.lenient,
        .findings_sink = options.findings_sink,
    };
    if (baseline.decodeWithOptions(allocator, data, baseline_opts)) |img| {
        return img;
    } else |err| switch (err) {
        error.NotImplemented => {},
        else => return err,
    }

    // Try progressive cleanroom (SOF2). Validated 2026-05-08 against
    // 276 real-world progressive JPEGs from Peter's corpus: all decoded
    // within ≤2 LSB of libjpeg-turbo's wrapper output, with 199/276
    // byte-perfect (the residual 77 files differ only by sub-LSB
    // rounding noise — same threshold as baseline cleanroom). Six
    // bug fixes shipped: end-of-scan marker (markerHit→seekToMarker),
    // libjpeg `insufficient_data` parity, AC refinement ZRL break
    // semantics (libjpeg's `--r < 0`), float→fixed-point YCbCr,
    // single-component scan iteration via T.81 §A.2.4 xi/yi, IJG
    // fancy chroma upsampling. NotImplemented falls through to wrapper
    // for: DRI in progressive, 12-bit precision, multi-component scans
    // with > 4 components, etc.
    const progressive = @import("decode/progressive.zig");
    if (progressive.decode(allocator, data)) |img| {
        return img;
    } else |err| switch (err) {
        error.NotImplemented => {},
        else => return err,
    }

    // Try lossless cleanroom (SOF3, T.81 §H — predictive coding).
    // Byte-perfect vs libjpeg-turbo across all 13 lossless fixtures:
    // precision 8/12/14/16, 1- and 3-component, DRI > 0, all 7
    // predictors. NotImplemented falls through to wrapper for non-1×1
    // sampling factors and point transform Al > 0.
    const lossless = @import("decode/lossless.zig");
    if (lossless.decode(allocator, data)) |img| {
        return img;
    } else |err| switch (err) {
        error.NotImplemented => {},
        else => return err,
    }

    // Try arithmetic-coded cleanroom (SOF9 sequential; SOF10/11
    // fall through). Patents expired in early 2000s; libjpeg-turbo
    // decodes them. B1 milestone — see arith_decode.zig.
    const arith_decode = @import("decode/arith_decode.zig");
    if (arith_decode.decode(allocator, data)) |img| {
        return img;
    } else |err| switch (err) {
        error.NotImplemented => {},
        else => return err,
    }

    // No cleanroom path matched. Cleanroom-only at runtime: surface
    // `NotImplemented` to the caller rather than silently falling
    // back to a runtime libjpeg/charls dependency. The two C-FFI
    // wrappers remain available exclusively as build-time oracles
    // via `jpegz.internal.{wrapperDecode, charlsDecode,
    // wrapperDumpCoefs}` for byte-perfect regression testing — they
    // are never reached through this public dispatcher.
    return error.NotImplemented;
}

/// Decode JPEG row-by-row, invoking `cb` once per emitted row in
/// raster order (y = 0, 1, …, height-1).
///
/// Supported storage modes: SOF0 / SOF1 (sequential), SOF3 (lossless),
/// SOF9 / SOF10 / SOF11 (arithmetic), JPEG-LS (T.87). **Returns
/// `error.NotRowStreamable` for SOF2 progressive** — caller can fall
/// back to `decode` and iterate the resulting buffer themselves.
///
/// The callback receives a borrowed slice. Copy if you need it past
/// return. Returning an error from the callback aborts decode and
/// propagates as `error.CallbackAborted`; the original error message
/// is preserved in the thread-local last-error mechanism.
pub fn decodeStreamingRows(
    allocator: Allocator,
    data: []const u8,
    cb: RowCallback,
) DecodeError!ImageMetadata {
    return decodeStreamingRowsWithOptions(allocator, data, .{}, cb);
}

/// Same as `decodeStreamingRows` but accepts a `DecodeOptions` struct
/// for caller-controlled behavior (today: thread budget). Pairs with
/// `decodeWithOptions` — every public API surface has a `_ex`-style
/// option-bearing variant so consumers can pass `threads` consistently.
pub fn decodeStreamingRowsWithOptions(
    allocator: Allocator,
    data: []const u8,
    options: DecodeOptions,
    cb: RowCallback,
) DecodeError!ImageMetadata {
    last_error.clear();
    if (data.len < 4) {
        last_error.set("input too short ({d} bytes)", .{data.len});
        return error.TruncatedStream;
    }
    if (data[0] != 0xFF or data[1] != 0xD8) {
        last_error.set("missing SOI marker (got 0x{x:0>2}{x:0>2})", .{ data[0], data[1] });
        return error.InvalidMarker;
    }

    // Reject progressive scans up front. T.81 §G.1 progressive bitstreams
    // are inherently multi-pass: every coefficient is touched across all
    // scans before its block is complete, so row-by-row delivery isn't
    // possible without full materialization. Callers wanting that
    // experience should call `decode` and iterate the pixel buffer.
    if (peekIsProgressive(data)) {
        last_error.set("progressive scan — call decode() and iterate the buffer", .{});
        return error.NotRowStreamable;
    }

    // v1 strategy: materialize the full image via `decode`, then iterate
    // rows. Memory profile is identical to plain `decode`; the API
    // contract is what callers depend on. A future per-decoder
    // implementation can deliver rows incrementally without touching
    // the public surface. Thread budget plumbs through to the
    // underlying decoder.
    var image = try decodeWithOptions(allocator, data, options);
    defer image.deinit(allocator);

    const stride = image.rowStride();
    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        const row = image.pixels[@as(usize, y) * stride ..][0..stride];
        cb.on_row(cb.ctx, row, y) catch |e| {
            // Preserve the original error name so callers can recover it
            // via `lastErrorMessage()` — the API contract collapses any
            // callback error to `CallbackAborted`, but the detail isn't
            // lost. Same buffer C consumers read via
            // `jpegz_last_error_message()` (single backing memory, no
            // duplication).
            last_error.set("row {d}: callback returned error.{s}", .{ y, @errorName(e) });
            return error.CallbackAborted;
        };
    }

    return ImageMetadata{
        .width = image.width,
        .height = image.height,
        .channels = image.channels,
        .bits_per_sample = image.bits_per_sample,
        .source_color_space = image.source_color_space,
        .layout = image.layout,
    };
}

/// Cheap pre-flight: walk markers looking for a progressive SOF
/// (SOF2 0xC2 Huffman, SOF10 0xCA arithmetic). Stops at the first
/// SOFn or SOS — doesn't validate the rest of the stream. Used only
/// to gate `decodeStreamingRows` early; full classification lives in
/// `core/validator.zig`.
fn peekIsProgressive(data: []const u8) bool {
    var pos: usize = 2;
    while (pos + 1 < data.len) {
        while (pos < data.len and data[pos] != 0xFF) pos += 1;
        if (pos + 1 >= data.len) return false;
        while (pos + 1 < data.len and data[pos + 1] == 0xFF) pos += 1;
        if (pos + 1 >= data.len) return false;
        const marker = data[pos + 1];
        pos += 2;
        switch (marker) {
            0xC2, 0xCA => return true, // progressive Huffman / arithmetic
            // Any other SOFn or SOS: this is not a progressive image.
            0xC0, 0xC1, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCB, 0xCD, 0xCE, 0xCF,
            0xF7, 0xDA => return false,
            // Standalone markers we can skip safely.
            0x01, 0xD0...0xD7, 0xD8, 0xD9 => continue,
            // Length-prefixed marker — skip its payload.
            else => {
                if (pos + 1 >= data.len) return false;
                const seg_len: usize = (@as(usize, data[pos]) << 8) | data[pos + 1];
                if (seg_len < 2 or pos + seg_len > data.len) return false;
                pos += seg_len;
            },
        }
    }
    return false;
}

/// Walk the bitstream without materializing pixels. Accumulates
/// findings; **does not fail-fast on structural problems**. Returns
/// a Zig error only for OOM or genuinely-impossible internal states.
/// A FAIL-rated report still returns successfully.
pub fn validate(
    allocator: Allocator,
    data: []const u8,
) error{OutOfMemory}!ValidationReport {
    return @import("core/validator.zig").validate(allocator, data);
}

// ─────────────────────────────────────────────────────────────────────
// 5. JPEG 2000 sub-namespace
// ─────────────────────────────────────────────────────────────────────

/// JPEG 2000 lives in its own namespace because the codec internals
/// share nothing with T.81 (wavelet + EBCOT vs. DCT + Huffman /
/// arithmetic).
pub const jpeg2000 = struct {
    pub fn decode(allocator: Allocator, data: []const u8) DecodeError!Image {
        return jpeg2000.decodeWithOptions(allocator, data, .{});
    }

    /// Same as `decode` but accepts `DecodeOptions`. Today's openjpeg
    /// wrapper does not yet plumb `options.threads` through to
    /// `opj_codec_set_threads` — that lands with the jp2z JP2 path
    /// or as a wrapper-side enhancement when needed.
    ///
    /// **Architecture note (documented):** this is the ONE runtime
    /// dependency on a C library in the public dispatch surface. JPEG
    /// 2000 (T.800) is handled by the sibling `jp2z` — a faithful Zig
    /// PORT of openjpeg (BSD-2, attributed), not a cleanroom rewrite —
    /// but jp2z's own production decode still routes through openjpeg
    /// today, so jpegz delegates to openjpeg here until that cutover.
    /// Every other public entry point is pure-Zig at runtime (no C
    /// dependency). Provenance is mixed (canonical: LICENSING_NOTES.md):
    /// the entropy / structural / lossless (T.81 §H) / JPEG-LS (T.87) /
    /// arithmetic (T.81 Annex D) layers are cleanroom from the ITU-T
    /// specs; the DCT DSP kernels (islow IDCT, YCbCr→RGB, upsampling)
    /// are pure-Zig ports of libjpeg-turbo under the IJG License
    /// (inherited libjpeg code — see THIRD_PARTY_NOTICES.md). The
    /// oracle libs (libjpeg-turbo / charls) remain available only as
    /// build-time oracles via `jpegz.internal.*` for byte-perfect
    /// regression testing.
    pub fn decodeWithOptions(
        allocator: Allocator,
        data: []const u8,
        options: DecodeOptions,
    ) DecodeError!Image {
        _ = options;
        return @import("ffi/openjpeg_wrapper.zig").decode(allocator, data);
    }

    /// The 12-byte JP2 file-format signature box (T.800 §I.5.1). Its
    /// presence tells us the *container* parsed, which is what lets us
    /// report a more precise cause than jp2z's generic `missing_soi`.
    const jp2_signature_box = [_]u8{
        0x00, 0x00, 0x00, 0x0C, 'j', 'P', ' ', ' ', 0x0D, 0x0A, 0x87, 0x0A,
    };

    /// Translate a jp2z finding code into jpegz's vocabulary.
    ///
    /// The two registries were deliberately reconciled by Einstein — both
    /// agree byte-for-byte on the structural band (1..5) and the `jp2_*`
    /// 140+ / informational 200+ bands — so the mapping is identity
    /// wherever jpegz declares the same value.
    ///
    /// The one deliberate exception is `missing_soi`. jp2z emits it for
    /// *both* "JP2 signature box is wrong" and "raw J2K SOC marker is
    /// wrong", because at its layer those are the same event. jpegz owns
    /// more precise codes for exactly this (`jp2_invalid_signature` 140,
    /// `jp2_invalid_codestream` 141) and, unlike jp2z, has already looked
    /// at the container shape. Handing a JP2 consumer a code literally
    /// named "missing **SOI**" — a JPEG marker that does not exist in
    /// T.800 — would be a worse answer than the one we can give.
    ///
    /// Codes jpegz does not declare (jp2z's 145/146 and the 250..254
    /// tier-2 packet band) degrade to `jp2_invalid_codestream` rather
    /// than being dropped: a consumer must never see a `.fail` report
    /// with no finding explaining it.
    fn translateCode(code: jp2z.FindingCode, container_ok: bool) FindingCode {
        if (code == .missing_soi) {
            return if (container_ok) .jp2_invalid_codestream else .jp2_invalid_signature;
        }
        const raw = @intFromEnum(code);
        inline for (@typeInfo(FindingCode).@"enum".fields) |f| {
            if (raw == f.value) return @field(FindingCode, f.name);
        }
        return .jp2_invalid_codestream;
    }

    /// Validate a JP2 (file format) or raw J2K codestream and return a
    /// report in jpegz's own vocabulary.
    ///
    /// Delegates to jp2z's cleanroom codestream walker rather than
    /// reimplementing it. This entry point was a stub returning `.pass`
    /// with zero findings until 2026-08-01, which meant a shredded JP2
    /// reported PASS through the facade — a false negative by
    /// construction, and the reason `validate` could not rely on jpegz
    /// for T.800 coverage.
    ///
    /// Note this calls ONLY `jp2z.validate`. jp2z's decode path still
    /// links openjpeg; Zig's lazy analysis is what keeps that off our
    /// dependency graph, and `tests/cli/no_c_consumer.bash` fails if it
    /// ever creeps back on.
    pub fn validate(
        allocator: Allocator,
        data: []const u8,
    ) error{OutOfMemory}!ValidationReport {
        const container_ok = data.len >= jp2_signature_box.len and
            std.mem.eql(u8, data[0..jp2_signature_box.len], &jp2_signature_box);

        var src = try jp2z.validate(allocator, data);
        defer src.deinit(allocator);

        var report = ValidationReport{
            .overall = @enumFromInt(@intFromEnum(src.overall)),
            .variant = if (src.overall == .fail and src.findings.items.len == 0)
                .unknown
            else
                .jpeg2000,
            .width = src.width,
            .height = src.height,
            .findings = .empty,
        };
        errdefer report.deinit(allocator);

        try report.findings.ensureTotalCapacity(allocator, src.findings.items.len);
        for (src.findings.items) |f| {
            // Detail strings belong to jp2z's report and are freed by its
            // deinit above, so each one has to be copied into ours.
            const detail: ?[]const u8 = if (f.detail) |d|
                try allocator.dupe(u8, d)
            else
                null;
            report.findings.appendAssumeCapacity(.{
                .severity = @enumFromInt(@intFromEnum(f.severity)),
                .code = translateCode(f.code, container_ok),
                .offset = f.offset,
                .detail = detail,
            });
        }

        return report;
    }
};

/// Force-link handle for the C ABI. Referencing this pulls every
/// `export fn` in `ffi/c_api.zig` past dead-code elimination and into
/// the static library.
///
/// It is a lazily-analyzed `pub const` — NOT a top-level `comptime`
/// block — and that distinction is the whole point. A `comptime`
/// force-link here is unconditional, so it dragged the exported
/// `jpegz_jp2_decode` → `jpeg2000.decodeWithOptions` →
/// `openjpeg_wrapper.decode` → `@cImport(<openjpeg.h>)` chain into the
/// analysis of EVERY consumer, including pure-Zig ones that only ever
/// call `validate()`. That forced tiffz / validate to have openjpeg
/// headers available merely to import this module (and is almost
/// certainly why validate ended up vendoring its own `deps/openjpeg`).
///
/// Zig analyzes a declaration only when something references it, so the
/// static-library root (`src/lib_root.zig`) references this and nobody
/// else does. Consumers importing `jpegz` as a Zig module pay for only
/// the code paths they actually call.
///
/// Guarded by `tests/cli/no_c_consumer.bash`, which compiles a
/// validate-only consumer with no C headers or libraries in scope.
pub const c_abi_force_link = @import("ffi/c_api.zig");

/// Internal test-only entry points. Not part of the public ABI; meant
/// for analysis tools (e.g., scratch/cleanroom_diff.zig) that need to
/// call cleanroom and wrapper paths directly without going through
/// the dispatcher in `decode`.
pub const internal = struct {
    /// Decode via the cleanroom baseline path, attaching a
    /// `FindingsSink` so spec-deviation findings (extraneous bytes,
    /// premature EOI with recovered data, etc.) are surfaced as warns.
    /// This is the entry point validate(...) will use once cleanroom
    /// becomes the source of truth for warnings on owned variants.
    pub fn cleanroomDecodeWithFindings(
        allocator: Allocator,
        data: []const u8,
        sink: *FindingsSink,
    ) DecodeError!Image {
        const baseline = @import("decode/baseline.zig");
        return baseline.decodeWithOptions(allocator, data, .{ .findings_sink = sink });
    }

    /// Lenient baseline cleanroom: tolerates truncated entropy data
    /// (returns partial pixels + emits a `Finding(.warn,
    /// .insufficient_data)` via the sink instead of erroring).
    /// Mirror of libjpeg-turbo's `JWRN_HIT_MARKER` / `JWRN_JPEG_EOF`
    /// recovery behavior. The default `cleanroomDecode` stays strict.
    pub fn cleanroomDecodeLenientWithFindings(
        allocator: Allocator,
        data: []const u8,
        sink: *FindingsSink,
    ) DecodeError!Image {
        const baseline = @import("decode/baseline.zig");
        return baseline.decodeWithOptions(allocator, data, .{
            .findings_sink = sink,
            .lenient = true,
        });
    }

    pub fn cleanroomDecode(allocator: Allocator, data: []const u8) DecodeError!Image {
        return @import("decode/baseline.zig").decode(allocator, data);
    }
    pub fn cleanroomDecodeWithOptions(
        allocator: Allocator,
        data: []const u8,
        options: DecodeOptions,
    ) DecodeError!Image {
        const baseline = @import("decode/baseline.zig");
        return baseline.decodeWithOptions(allocator, data, .{ .threads = options.threads });
    }
    pub fn progressiveDecode(allocator: Allocator, data: []const u8) DecodeError!Image {
        return @import("decode/progressive.zig").decode(allocator, data);
    }
    /// Progressive cleanroom decode that emits a `Finding(.warn,
    /// .insufficient_data)` into the supplied sink the first time
    /// within each scan that the entropy stream runs out before
    /// the scan completes (libjpeg `JWRN_HIT_MARKER`/`JWRN_JPEG_EOF`
    /// parity). Other tolerance sites are silent in v1.
    pub fn progressiveDecodeWithFindings(
        allocator: Allocator,
        data: []const u8,
        sink: *FindingsSink,
    ) DecodeError!Image {
        const progressive = @import("decode/progressive.zig");
        return progressive.decodeWithOptions(allocator, data, .{ .findings_sink = sink });
    }
    /// Progressive cleanroom decode with lenient RST recovery: emits
    /// `restart_marker_unexpected` / `restart_marker_missing` warns
    /// and resyncs the entropy stream instead of returning
    /// `error.InvalidMarker` on RST cycle drift or missing markers.
    /// Mirrors `cleanroomDecodeLenientWithFindings` for SOF2.
    pub fn progressiveDecodeLenientWithFindings(
        allocator: Allocator,
        data: []const u8,
        sink: *FindingsSink,
    ) DecodeError!Image {
        const progressive = @import("decode/progressive.zig");
        return progressive.decodeWithOptions(allocator, data, .{
            .findings_sink = sink,
            .lenient = true,
        });
    }
    pub fn losslessDecode(allocator: Allocator, data: []const u8) DecodeError!Image {
        return @import("decode/lossless.zig").decode(allocator, data);
    }
    /// Lossless cleanroom decode that emits a `Finding(.warn,
    /// .extraneous_bytes_before_marker)` when the pre-SOS marker
    /// walker scans past garbage bytes. Sample-stream tolerance is
    /// NOT added (a missing sample would cascade through the
    /// predictor chain). All other tolerance sites are silent in v1.
    pub fn losslessDecodeWithFindings(
        allocator: Allocator,
        data: []const u8,
        sink: *FindingsSink,
    ) DecodeError!Image {
        const lossless = @import("decode/lossless.zig");
        return lossless.decodeWithOptions(allocator, data, .{ .findings_sink = sink });
    }
    /// Lossless cleanroom decode with lenient RST recovery. Same
    /// shape as `progressiveDecodeLenientWithFindings`.
    pub fn losslessDecodeLenientWithFindings(
        allocator: Allocator,
        data: []const u8,
        sink: *FindingsSink,
    ) DecodeError!Image {
        const lossless = @import("decode/lossless.zig");
        return lossless.decodeWithOptions(allocator, data, .{
            .findings_sink = sink,
            .lenient = true,
        });
    }
    /// Diagnostic-only: decode a progressive JPEG and return the post-
    /// entropy quantized coefficients in natural order (un-zig-zagged),
    /// matching the layout of libjpeg-turbo's `jpeg_read_coefficients()`.
    /// Used by scratch/dump_coefs_jpegz.zig for byte-level diff against
    /// libjpeg's output. NOT part of the stable ABI.
    pub const ProgCoefDump = @import("decode/progressive.zig").CoefDump;
    pub fn progressiveDecodeAndDumpCoefs(allocator: Allocator, data: []const u8) DecodeError!ProgCoefDump {
        return @import("decode/progressive.zig").decodeAndDumpCoefs(allocator, data);
    }
    pub fn wrapperDecode(allocator: Allocator, data: []const u8) DecodeError!Image {
        if (comptime build_options.with_libjpeg_oracle) {
            return @import("ffi/libjpeg_wrapper.zig").decode(allocator, data);
        } else return error.NotImplemented;
    }
    /// Arithmetic-coded JPEG decode (SOF9 / SOF10). Returns
    /// `error.NotImplemented` until B1 lands; tests calling this
    /// entry point use that as their RED gate.
    /// Diagnostic: dump per-block coefs from the arith SOF9 cleanroom.
    /// Output mirrors libjpeg-turbo's `jpeg_read_coefficients`.
    pub const ArithCoefDump = @import("decode/arith_decode.zig").CoefDump;
    pub fn arithDumpCoefsSof9(allocator: Allocator, data: []const u8) DecodeError!ArithCoefDump {
        return @import("decode/arith_decode.zig").dumpCoefsSof9(allocator, data);
    }
    /// Diagnostic: dump per-block coefs from libjpeg-turbo via
    /// `jpeg_read_coefficients` — RAW, natural order, pre-dequant.
    /// Gated on the libjpeg oracle; an empty type when -Dwith-libjpeg-oracle=false.
    pub const WrapperCoefDump = if (build_options.with_libjpeg_oracle) @import("ffi/libjpeg_wrapper.zig").CoefDump else struct {};
    pub fn wrapperDumpCoefs(allocator: Allocator, data: []const u8) DecodeError!WrapperCoefDump {
        if (comptime build_options.with_libjpeg_oracle) {
            return @import("ffi/libjpeg_wrapper.zig").dumpCoefs(allocator, data);
        } else return error.NotImplemented;
    }
    pub fn arithDecode(allocator: Allocator, data: []const u8) DecodeError!Image {
        return @import("decode/arith_decode.zig").decode(allocator, data);
    }
    /// SOF9 arithmetic cleanroom decode that emits findings into the
    /// supplied sink. The Q-coder explicitly supplies zero bits past
    /// markers (T.81 §F.1.4), so the only emit site today is
    /// `extraneous_bytes_before_marker` in the SOF9 walker. SOF10/SOF11
    /// have no findings to surface in v1.
    pub fn arithDecodeWithFindings(
        allocator: Allocator,
        data: []const u8,
        sink: *FindingsSink,
    ) DecodeError!Image {
        const arith = @import("decode/arith_decode.zig");
        return arith.decodeWithOptions(allocator, data, .{ .findings_sink = sink });
    }
    /// JPEG-LS (SOF55) cleanroom decode with `FindingsSink`. The only
    /// emit site in v1 is `extraneous_bytes_before_marker` in the
    /// marker walker; entropy decode itself is fixed-pixel-count and
    /// gets zero-padded bits past EOF (T.87 §A.5.3) — no
    /// `insufficient_data` equivalent.
    pub fn jpeglsDecodeWithFindings(
        allocator: Allocator,
        data: []const u8,
        sink: *FindingsSink,
    ) DecodeError!Image {
        const jpegls = @import("decode/jpegls.zig");
        return jpegls.decodeWithOptions(allocator, data, .{ .findings_sink = sink });
    }
    /// Direct charls wrapper decode — bypasses dispatcher's cleanroom
    /// preference so tests can compare cleanroom output to charls
    /// reference output on the same fixture.
    pub fn charlsDecode(allocator: Allocator, data: []const u8) DecodeError!Image {
        return @import("ffi/charls_wrapper.zig").decode(allocator, data);
    }
};

// ─────────────────────────────────────────────────────────────────────
// Inline tests — wiring sanity. Real test suites in `tests/`.
// ─────────────────────────────────────────────────────────────────────

test "version is non-empty" {
    try std.testing.expect(version.len > 0);
}

test "Image.rowStride for 8-bit RGB" {
    const img = Image{
        .pixels = &[_]u8{},
        .width = 100,
        .height = 50,
        .channels = 3,
        .bits_per_sample = 8,
        .source_color_space = .ycbcr,
        .layout = .rgb,
    };
    try std.testing.expectEqual(@as(usize, 300), img.rowStride());
}

test "Image.rowStride for 16-bit grayscale" {
    const img = Image{
        .pixels = &[_]u8{},
        .width = 100,
        .height = 50,
        .channels = 1,
        .bits_per_sample = 16,
        .source_color_space = .grayscale,
        .layout = .grayscale,
    };
    try std.testing.expectEqual(@as(usize, 200), img.rowStride());
}
