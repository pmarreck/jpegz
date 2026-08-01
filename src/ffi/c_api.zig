//! C ABI surface for jpegz. Defines the `export fn` entry points
//! consumed by `include/jpegz_core.h`. The Zig core (`src/jpegz.zig`)
//! is the single implementation; this module is pure marshalling.
//!
//! Layout choices documented in
//! `docs/superpowers/specs/2026-05-04-jpegz-public-api-design.md` § 5.

const std = @import("std");
const errors = @import("../core/errors.zig");
const jpegz = @import("../jpegz.zig");

// `c_int` is a Zig builtin for the C `int` type — no alias needed.

// ─────────────────────────────────────────────────────────────────────
// Allocator strategy: single global allocator backing all C-allocated
// memory (pixels, findings, detail strings). Using c_allocator keeps
// the picture simple — caller-owned C memory uses the C heap.
// Future: allow caller to supply a custom allocator via an opt struct.
// ─────────────────────────────────────────────────────────────────────
const c_allocator = std.heap.c_allocator;

// ─────────────────────────────────────────────────────────────────────
// Status / error mapping
// ─────────────────────────────────────────────────────────────────────

/// Exhaustive switch — adding a Zig variant to DecodeError without
/// updating this is a COMPILE-TIME ERROR. That's the design point:
/// the Zig declarations are the source of truth, the C ABI is the
/// formal mirror.
fn toCStatus(err: errors.DecodeError) c_int {
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

// ─────────────────────────────────────────────────────────────────────
// Thread-local last-error message
// ─────────────────────────────────────────────────────────────────────
//
// The backing buffer + setter live in `src/core/last_error.zig` so the
// public Zig API can read the same memory via `jpegz.lastErrorMessage()`
// without duplicating storage. The two locals below are thin aliases
// that keep existing call sites in this file unchanged.

const last_error = @import("../core/last_error.zig");
const clearLastError = last_error.clear;
const setLastError = last_error.set;

export fn jpegz_last_error_message() [*:0]const u8 {
    return last_error.cPtr();
}

// ─────────────────────────────────────────────────────────────────────
// Versioning
// ─────────────────────────────────────────────────────────────────────

export fn jpegz_version() [*:0]const u8 {
    return jpegz.version.ptr;
}

/// Human-readable name for a `jpegz_finding_code_t`, e.g. 3 →
/// `"truncated_stream"`. Returns a statically-allocated, NUL-terminated
/// string the caller must NOT free.
///
/// Exists so consumers can report a *specific cause* rather than a bare
/// integer or a generic phrase. Without it every consumer that renders
/// findings (the jpegz CLI, validate) would hand-maintain its own
/// code→name table, which silently drifts from `core/errors.zig` the
/// moment a code is appended — and appending codes is routine, since the
/// registry is append-only wire format.
///
/// The table is generated from the enum by `inline for` over
/// `@typeInfo(...).fields`, so drift is not merely discouraged but
/// inexpressible: a new `FindingCode` variant is nameable the instant it
/// is declared, with no second edit site.
///
/// Unknown codes return `"unknown_finding_code"` rather than null or a
/// garbage pointer. That case is reachable in normal operation, not just
/// from misuse: findings cross an ABI boundary, so a newer jpegz can hand
/// an older consumer a code it predates.
export fn jpegz_finding_code_name(code: c_int) [*:0]const u8 {
    inline for (@typeInfo(errors.FindingCode).@"enum".fields) |f| {
        if (code == f.value) return f.name.ptr;
    }
    return "unknown_finding_code";
}
// ─────────────────────────────────────────────────────────────────────
// Image — C representation
// ─────────────────────────────────────────────────────────────────────

const CImage = extern struct {
    pixels: [*c]u8,
    pixels_len: usize,
    width: u32,
    height: u32,
    channels: u8,
    bits_per_sample: u8,
    source_color_space: c_int,
    layout: c_int,
};

fn writeImageToC(out: *CImage, img: jpegz.Image) void {
    out.* = .{
        .pixels = img.pixels.ptr,
        .pixels_len = img.pixels.len,
        .width = img.width,
        .height = img.height,
        .channels = img.channels,
        .bits_per_sample = img.bits_per_sample,
        .source_color_space = @intFromEnum(img.source_color_space),
        .layout = @intFromEnum(img.layout),
    };
}

export fn jpegz_image_free(image: ?*CImage) void {
    const im = image orelse return;
    if (im.pixels != null and im.pixels_len > 0) {
        const slice: []u8 = im.pixels[0..im.pixels_len];
        c_allocator.free(slice);
    }
    im.* = std.mem.zeroes(CImage);
}

// ─────────────────────────────────────────────────────────────────────
// jpegz_decode / jpegz_jp2_decode (+ _ex variants for caller-controlled
// options — cross-project threading-control convention, agreed
// 2026-05-07; see jpegz_core.h docstring on jpegz_decode_options_t).
// ─────────────────────────────────────────────────────────────────────

/// Mirrors `jpegz_decode_options_t` in include/jpegz_core.h.
/// Layout: `threads: u8`, `lenient: u8`, 6 reserved zero bytes for
/// forward compatibility. Existing fields never shift; new fields
/// append. Total size: 8 bytes (unchanged across versions).
const CDecodeOptions = extern struct {
    threads: u8,
    /// 0 = strict decode (default; truncated entropy → error).
    /// non-0 = lenient (partial pixels + sink warn). See the Zig
    /// `DecodeOptions.lenient` doc comment for the full semantics.
    lenient: u8,
    reserved: [6]u8,
};

/// Build the Zig `DecodeOptions` for a C decode call. Threads through
/// the C options struct's fields plus an optional findings sink (set
/// by `jpegz_decode_with_findings`; null otherwise).
fn buildDecodeOptions(
    c_options: ?*const CDecodeOptions,
    sink: ?*jpegz.FindingsSink,
) jpegz.DecodeOptions {
    if (c_options) |co| {
        return .{
            .threads = co.threads,
            .lenient = co.lenient != 0,
            .findings_sink = sink,
        };
    }
    return .{ .findings_sink = sink };
}

fn doDecodeWithOptions(
    decoder: *const fn (std.mem.Allocator, []const u8, jpegz.DecodeOptions) errors.DecodeError!jpegz.Image,
    data: [*c]const u8,
    len: usize,
    c_options: ?*const CDecodeOptions,
    sink: ?*jpegz.FindingsSink,
    out_image: ?*CImage,
) c_int {
    clearLastError();
    const out = out_image orelse {
        setLastError("out_image must not be NULL", .{});
        return -3;
    };
    const slice: []const u8 = if (data == null or len == 0) &[_]u8{} else data[0..len];
    const opts = buildDecodeOptions(c_options, sink);
    const img = decoder(c_allocator, slice, opts) catch |err| {
        setLastError("decode failed: {s}", .{@errorName(err)});
        return toCStatus(err);
    };
    writeImageToC(out, img);
    return 0;
}

export fn jpegz_decode(data: [*c]const u8, len: usize, out_image: ?*CImage) c_int {
    return doDecodeWithOptions(jpegz.decodeWithOptions, data, len, null, null, out_image);
}

export fn jpegz_decode_ex(
    data: [*c]const u8,
    len: usize,
    options: ?*const CDecodeOptions,
    out_image: ?*CImage,
) c_int {
    return doDecodeWithOptions(jpegz.decodeWithOptions, data, len, options, null, out_image);
}

export fn jpegz_jp2_decode(data: [*c]const u8, len: usize, out_image: ?*CImage) c_int {
    return doDecodeWithOptions(jpegz.jpeg2000.decodeWithOptions, data, len, null, null, out_image);
}

export fn jpegz_jp2_decode_ex(
    data: [*c]const u8,
    len: usize,
    options: ?*const CDecodeOptions,
    out_image: ?*CImage,
) c_int {
    return doDecodeWithOptions(jpegz.jpeg2000.decodeWithOptions, data, len, options, null, out_image);
}

// ─────────────────────────────────────────────────────────────────────
// FindingsSink C ABI — opaque handle backed by a heap-allocated
// `jpegz.FindingsSink`. C consumers create one, pass it to
// `jpegz_decode_with_findings`, walk the collected findings via
// `_count` + `_get`, and free with `_free`. See the header for usage.
// ─────────────────────────────────────────────────────────────────────

/// Opaque to C; cast back inside Zig. Allocated via c_allocator so the
/// caller-owned heap matches all other C-allocated jpegz objects.
const CFindingsSink = jpegz.FindingsSink;

export fn jpegz_findings_sink_create() ?*CFindingsSink {
    clearLastError();
    const sink = c_allocator.create(CFindingsSink) catch {
        setLastError("findings_sink_create: out of memory", .{});
        return null;
    };
    sink.* = jpegz.FindingsSink.init(c_allocator);
    return sink;
}

export fn jpegz_findings_sink_free(sink_opt: ?*CFindingsSink) void {
    const sink = sink_opt orelse return;
    sink.deinit();
    c_allocator.destroy(sink);
}

export fn jpegz_findings_sink_count(sink_opt: ?*const CFindingsSink) usize {
    const sink = sink_opt orelse return 0;
    return sink.items().len;
}

/// Fills `out_finding` with the finding at `idx`. The `detail`
/// pointer borrows the sink's internal storage — valid until the
/// next `_free` or another emission on the same sink. Returns
/// `JPEGZ_OK` (0) on success, `-3` for invalid args, `-1` for
/// out-of-range index.
export fn jpegz_findings_sink_get(
    sink_opt: ?*const CFindingsSink,
    idx: usize,
    out_finding: ?*CSinkFinding,
) c_int {
    clearLastError();
    const sink = sink_opt orelse {
        setLastError("findings_sink_get: sink must not be NULL", .{});
        return -3;
    };
    const out = out_finding orelse {
        setLastError("findings_sink_get: out_finding must not be NULL", .{});
        return -3;
    };
    const items = sink.items();
    if (idx >= items.len) {
        setLastError("findings_sink_get: idx {d} out of range (count={d})",
            .{ idx, items.len });
        return -1;
    }
    const f = items[idx];
    out.severity = @intCast(@intFromEnum(f.severity));
    out.code = @intCast(@intFromEnum(f.code));
    if (f.offset) |o| {
        out.offset = @intCast(o);
    } else {
        out.offset = std.math.minInt(i64);
    }
    out.detail = if (f.detail) |d| d.ptr else null;
    out.detail_len = if (f.detail) |d| d.len else 0;
    return 0;
}

/// C-side mirror of `jpegz_sink_finding_t` (header). Distinct from
/// the existing `CFinding` (validation-report shape) on two axes:
/// (a) an explicit `detail_len` so callers don't have to strlen a
/// possibly non-NUL-terminated slice, and (b) `detail` is a borrow
/// from the sink's storage, not an owned C string.
const CSinkFinding = extern struct {
    severity: c_int,
    code: c_int,
    /// INT64_MIN sentinel = "no offset" (matches `jpegz_finding_t`
    /// convention); any other value is a real byte offset.
    offset: i64,
    /// Borrowed; valid until the sink is freed or mutated. NULL when
    /// the emitter didn't attach a detail string.
    detail: ?[*]const u8,
    detail_len: usize,
};

/// Decode with both a `CDecodeOptions` and a `FindingsSink`. The
/// canonical entry point for "tolerant decode that captures
/// warnings." Pass `lenient = 1` in `options` to mirror libjpeg's
/// truncation recovery. The sink collects every finding emitted
/// during decode and remains valid until `_free`. `options` may be
/// NULL (defaults); `sink` may be NULL if the caller only wants
/// the strict / extraneous-bytes side and doesn't care to consume
/// the findings.
export fn jpegz_decode_with_findings(
    data: [*c]const u8,
    len: usize,
    options: ?*const CDecodeOptions,
    sink: ?*CFindingsSink,
    out_image: ?*CImage,
) c_int {
    return doDecodeWithOptions(jpegz.decodeWithOptions, data, len, options, sink, out_image);
}

// ─────────────────────────────────────────────────────────────────────
// Row-streaming decode — C ABI surface parity with the Zig
// `decodeStreamingRows` / `decodeStreamingRowsWithOptions` entries.
// ─────────────────────────────────────────────────────────────────────

const CImageMetadata = extern struct {
    width: u32,
    height: u32,
    channels: u8,
    bits_per_sample: u8,
    source_color_space: c_int,
    layout: c_int,
};

const CRowCallbackFn = *const fn (
    ctx: ?*anyopaque,
    row: [*c]const u8,
    row_len: usize,
    y: u32,
) callconv(.c) c_int;

/// Bridge between the C-shaped row callback (returns int) and Zig's
/// `RowCallback` shape (returns `anyerror!void`). Lives on the
/// caller's stack during the streaming call.
const CRowBridge = struct {
    c_fn: CRowCallbackFn,
    c_ctx: ?*anyopaque,
    last_c_rc: c_int,
};

fn zigRowBridge(ctx_opaque: ?*anyopaque, row: []const u8, y: u32) anyerror!void {
    const bridge: *CRowBridge = @ptrCast(@alignCast(ctx_opaque.?));
    const rc = bridge.c_fn(bridge.c_ctx, row.ptr, row.len, y);
    if (rc != 0) {
        bridge.last_c_rc = rc;
        return error.CallbackAborted;
    }
}

fn doStreamingWithOptions(
    data: [*c]const u8,
    len: usize,
    c_options: ?*const CDecodeOptions,
    on_row: ?CRowCallbackFn,
    ctx: ?*anyopaque,
    out_meta: ?*CImageMetadata,
) c_int {
    clearLastError();
    const cb_fn = on_row orelse {
        setLastError("on_row must not be NULL", .{});
        return -3;
    };
    const slice: []const u8 = if (data == null or len == 0) &[_]u8{} else data[0..len];
    const opts: jpegz.DecodeOptions = if (c_options) |co|
        .{ .threads = co.threads }
    else
        .{};

    var bridge = CRowBridge{ .c_fn = cb_fn, .c_ctx = ctx, .last_c_rc = 0 };
    const meta = jpegz.decodeStreamingRowsWithOptions(c_allocator, slice, opts, .{
        .on_row = zigRowBridge,
        .ctx = &bridge,
    }) catch |err| {
        // The library's last_error path already records detail for
        // most errors; for callback aborts the message will say
        // "row N: callback returned error.CallbackAborted" which is
        // less helpful than the original C return value. Overwrite
        // with the C-friendly form.
        if (err == error.CallbackAborted) {
            setLastError("callback returned {d}", .{bridge.last_c_rc});
        }
        return toCStatus(err);
    };

    if (out_meta) |m| m.* = .{
        .width = meta.width,
        .height = meta.height,
        .channels = meta.channels,
        .bits_per_sample = meta.bits_per_sample,
        .source_color_space = @intFromEnum(meta.source_color_space),
        .layout = @intFromEnum(meta.layout),
    };
    return 0;
}

export fn jpegz_decode_streaming_rows(
    data: [*c]const u8,
    len: usize,
    on_row: ?CRowCallbackFn,
    ctx: ?*anyopaque,
    out_metadata: ?*CImageMetadata,
) c_int {
    return doStreamingWithOptions(data, len, null, on_row, ctx, out_metadata);
}

export fn jpegz_decode_streaming_rows_ex(
    data: [*c]const u8,
    len: usize,
    options: ?*const CDecodeOptions,
    on_row: ?CRowCallbackFn,
    ctx: ?*anyopaque,
    out_metadata: ?*CImageMetadata,
) c_int {
    return doStreamingWithOptions(data, len, options, on_row, ctx, out_metadata);
}

// ─────────────────────────────────────────────────────────────────────
// Validation — C representation
// ─────────────────────────────────────────────────────────────────────

const CFinding = extern struct {
    severity: c_int,
    code: u32,
    /// INT64_MIN for "no offset", any other for the byte offset.
    offset: i64,
    /// NUL-terminated, owned by the report. NULL = no detail.
    detail: ?[*:0]const u8,
};

const OFFSET_NONE: i64 = std.math.minInt(i64);

const CValidationReport = extern struct {
    overall: c_int,
    variant: c_int,
    /// 0 means "not parsed".
    width: u32,
    height: u32,
    findings: [*c]const CFinding,
    findings_len: usize,
};

fn buildCFindings(zig_findings: []const jpegz.Finding) ![*c]CFinding {
    if (zig_findings.len == 0) return null;
    const arr = try c_allocator.alloc(CFinding, zig_findings.len);
    errdefer c_allocator.free(arr);

    for (zig_findings, 0..) |f, i| {
        // For each detail string, allocate a NUL-terminated C copy.
        var detail_c: ?[*:0]const u8 = null;
        if (f.detail) |d| {
            const buf = try c_allocator.alloc(u8, d.len + 1);
            @memcpy(buf[0..d.len], d);
            buf[d.len] = 0;
            detail_c = @ptrCast(buf.ptr);
        }
        arr[i] = .{
            .severity = @intFromEnum(f.severity),
            .code = @intFromEnum(f.code),
            .offset = if (f.offset) |o| @intCast(o) else OFFSET_NONE,
            .detail = detail_c,
        };
    }
    return @ptrCast(arr.ptr);
}

fn freeCFindings(findings: [*c]const CFinding, len: usize) void {
    if (findings == null or len == 0) return;
    // Free detail strings.
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (findings[i].detail) |d| {
            const slice = std.mem.span(d);
            // Free the allocation including the NUL byte.
            const full = @as([*]u8, @ptrCast(@constCast(d)))[0 .. slice.len + 1];
            c_allocator.free(full);
        }
    }
    // Free the array itself.
    const arr_slice = @as([*]const CFinding, findings)[0..len];
    c_allocator.free(@as([*]CFinding, @constCast(@ptrCast(arr_slice.ptr)))[0..len]);
}

export fn jpegz_validation_report_free(report: ?*CValidationReport) void {
    const r = report orelse return;
    freeCFindings(r.findings, r.findings_len);
    r.* = std.mem.zeroes(CValidationReport);
}

fn doValidate(
    validator: *const fn (std.mem.Allocator, []const u8) error{OutOfMemory}!jpegz.ValidationReport,
    data: [*c]const u8,
    len: usize,
    out_report: ?*CValidationReport,
) c_int {
    clearLastError();
    const out = out_report orelse {
        setLastError("out_report must not be NULL", .{});
        return -8; // OUT_OF_MEMORY-adjacent; reuse for invalid-arg-NULL.
    };
    const slice: []const u8 = if (data == null or len == 0) &[_]u8{} else data[0..len];
    var report = validator(c_allocator, slice) catch |err| {
        setLastError("validate failed: {s}", .{@errorName(err)});
        return toCStatus(err);
    };
    defer report.deinit(c_allocator);

    const c_findings = buildCFindings(report.findings.items) catch {
        setLastError("OOM building C findings", .{});
        return -8;
    };

    out.* = .{
        .overall = @intFromEnum(report.overall),
        .variant = @intFromEnum(report.variant),
        .width = report.width orelse 0,
        .height = report.height orelse 0,
        .findings = c_findings,
        .findings_len = report.findings.items.len,
    };
    return 0;
}

export fn jpegz_validate(data: [*c]const u8, len: usize, out_report: ?*CValidationReport) c_int {
    return doValidate(jpegz.validate, data, len, out_report);
}

export fn jpegz_jp2_validate(data: [*c]const u8, len: usize, out_report: ?*CValidationReport) c_int {
    return doValidate(jpegz.jpeg2000.validate, data, len, out_report);
}
