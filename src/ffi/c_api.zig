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

threadlocal var last_error_buf: [512]u8 = undefined;
threadlocal var last_error_len: usize = 0;

fn clearLastError() void {
    last_error_len = 0;
    last_error_buf[0] = 0;
}

fn setLastError(comptime fmt: []const u8, args: anytype) void {
    const slice = std.fmt.bufPrint(&last_error_buf, fmt, args) catch &last_error_buf;
    last_error_len = slice.len;
    if (last_error_len < last_error_buf.len) last_error_buf[last_error_len] = 0;
}

export fn jpegz_last_error_message() [*:0]const u8 {
    if (last_error_len < last_error_buf.len) {
        last_error_buf[last_error_len] = 0;
    } else {
        last_error_buf[last_error_buf.len - 1] = 0;
    }
    return @ptrCast(&last_error_buf[0]);
}

// ─────────────────────────────────────────────────────────────────────
// Versioning
// ─────────────────────────────────────────────────────────────────────

export fn jpegz_version() [*:0]const u8 {
    return jpegz.version.ptr;
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
// jpegz_decode / jpegz_jp2_decode
// ─────────────────────────────────────────────────────────────────────

fn doDecode(
    decoder: *const fn (std.mem.Allocator, []const u8) errors.DecodeError!jpegz.Image,
    data: [*c]const u8,
    len: usize,
    out_image: ?*CImage,
) c_int {
    clearLastError();
    const out = out_image orelse {
        setLastError("out_image must not be NULL", .{});
        return -3; // UnsupportedPrecision is wrong; let's be explicit:
    };
    const slice: []const u8 = if (data == null or len == 0) &[_]u8{} else data[0..len];
    const img = decoder(c_allocator, slice) catch |err| {
        setLastError("decode failed: {s}", .{@errorName(err)});
        return toCStatus(err);
    };
    writeImageToC(out, img);
    return 0;
}

export fn jpegz_decode(data: [*c]const u8, len: usize, out_image: ?*CImage) c_int {
    return doDecode(jpegz.decode, data, len, out_image);
}

export fn jpegz_jp2_decode(data: [*c]const u8, len: usize, out_image: ?*CImage) c_int {
    return doDecode(jpegz.jpeg2000.decode, data, len, out_image);
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
