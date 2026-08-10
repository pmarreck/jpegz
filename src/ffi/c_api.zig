//! Decode half of the C ABI for jpegz. Defines the `export fn` entry points
//! consumed by `include/jpegz_core.h` for producing pixels; the Zig core
//! (`src/jpegz.zig`) is the single implementation and this module is pure
//! marshalling.
//!
//! The VALIDATION half lives in `c_api_validate.zig` and is the root of a
//! separate, C-library-free static archive. See `c_common.zig` for why the
//! split exists. Symbols are partitioned, never duplicated: anything exported
//! here must not also be exported there.
//!
//! Layout choices documented in
//! `docs/superpowers/specs/2026-05-04-jpegz-public-api-design.md` § 5.

const std = @import("std");
const errors = @import("../core/errors.zig");
const jpegz = @import("../jpegz.zig");
const common = @import("c_common.zig");

// Shared marshalling state — one allocator and one thread-local error slot per
// artifact, so a decode failure and a validation failure cannot clobber each
// other's message.
const c_allocator = common.c_allocator;
const clearLastError = common.clearLastError;
const setLastError = common.setLastError;
const toCStatus = common.toCStatus;

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

// The validation surface (jpegz_validate, jpegz_jp2_validate,
// jpegz_validate_any, jpegz_sniff, the name lookups and the report/result
// free functions) lives in `c_api_validate.zig`, which is also the root of the
// validation-only static library. See `c_common.zig` for why the two archives
// must be separate. This file owns the decode half exclusively; defining a
// symbol in both would collide when the full library links them together.
