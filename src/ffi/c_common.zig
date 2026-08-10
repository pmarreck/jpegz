//! Marshalling helpers shared by the two C ABI surfaces.
//!
//! WHY THIS FILE EXISTS. jpegz ships two static libraries from one header:
//!
//!   libjpegz.a           full ABI — decode + validation (needs libjpeg-turbo,
//!                        openjpeg and CharLS at link time)
//!   libjpegz-validate.a  validation only — pure Zig plus Brotli, no external
//!                        JPEG-family decoder anywhere in its closure
//!
//! The split is not cosmetic. A static Zig library bundles the system static
//! archives its module graph links, and those nested `.a` members are not
//! objects LLD can use ("neither ET_REL nor LLVM bitcode"), so it only warns
//! about them — which Zig escalates to a hard error the moment anything makes
//! the linker scan that deep. Reaching the JPEG XL leg through the ABI was
//! enough to trigger it. A validation-only library links none of those C
//! libraries, so the nested archives do not exist to be scanned.
//!
//! It also buys the thing the project already gates on elsewhere: the
//! validation CLI now has the same closure guarantee as
//! `tools/facade_validator_probe.zig` — no OpenJPEG, no libjpeg, no CharLS.
//!
//! Everything here is deliberately NOT an `export fn`. Exported symbols live
//! in exactly one of the two surface files so that neither library can define
//! the same symbol twice.

const std = @import("std");
const errors = @import("../core/errors.zig");
const jpegz = @import("../jpegz.zig");

/// Single global allocator backing all C-allocated memory (pixels, findings,
/// detail strings). Caller-owned C memory uses the C heap.
pub const c_allocator = std.heap.c_allocator;

/// Backing buffer lives in `src/core/last_error.zig` so the public Zig API
/// reads the same memory via `jpegz.lastErrorMessage()` without duplicating
/// storage. Both ABI surfaces share one error slot per artifact.
pub const last_error = @import("../core/last_error.zig");
pub const clearLastError = last_error.clear;
pub const setLastError = last_error.set;

/// INT64_MIN for "no offset"; any other value is a real byte offset. Offset 0
/// is legitimate, so a sentinel is required rather than a zero check.
pub const OFFSET_NONE: i64 = std.math.minInt(i64);

/// Exhaustive switch — adding a Zig variant to DecodeError without updating
/// this is a COMPILE-TIME ERROR. That is the design point: the Zig
/// declarations are the source of truth, the C ABI is the formal mirror.
pub fn toCStatus(err: errors.DecodeError) c_int {
    return switch (err) {
        error.NotImplemented => -1,
        error.InvalidMarker => -2,
        error.UnsupportedPrecision => -3,
        error.TruncatedStream => -4,
        error.NotRowStreamable => -5,
        error.BackendError => -6,
        error.InvalidJp2Codestream => -7,
        error.OutOfMemory => -8,
        error.CallbackAborted => -9,
    };
}

pub const CFinding = extern struct {
    severity: c_int,
    code: u32,
    /// INT64_MIN for "no offset", any other for the byte offset.
    offset: i64,
    /// NUL-terminated, owned by the report. NULL = no detail.
    detail: ?[*:0]const u8,
};

pub const CValidationReport = extern struct {
    overall: c_int,
    variant: c_int,
    /// 0 means "not parsed".
    width: u32,
    height: u32,
    findings: [*c]const CFinding,
    findings_len: usize,
};

/// Copy a detail string into the C heap as a NUL-terminated buffer. Returns
/// null for a null input so callers can pass through optional details.
pub fn dupeDetailToC(detail: ?[]const u8) !?[*:0]const u8 {
    const d = detail orelse return null;
    const buf = try c_allocator.alloc(u8, d.len + 1);
    @memcpy(buf[0..d.len], d);
    buf[d.len] = 0;
    return @ptrCast(buf.ptr);
}

/// Free a string produced by `dupeDetailToC`, including its NUL byte.
pub fn freeDetailFromC(detail: [*:0]const u8) void {
    const slice = std.mem.span(detail);
    const full = @as([*]u8, @ptrCast(@constCast(detail)))[0 .. slice.len + 1];
    c_allocator.free(full);
}

pub fn buildCFindings(zig_findings: []const jpegz.Finding) ![*c]CFinding {
    if (zig_findings.len == 0) return null;
    const arr = try c_allocator.alloc(CFinding, zig_findings.len);
    errdefer c_allocator.free(arr);

    for (zig_findings, 0..) |f, i| {
        arr[i] = .{
            .severity = @intFromEnum(f.severity),
            .code = @intFromEnum(f.code),
            .offset = if (f.offset) |o| @intCast(o) else OFFSET_NONE,
            .detail = try dupeDetailToC(f.detail),
        };
    }
    return @ptrCast(arr.ptr);
}

pub fn freeCFindings(findings: [*c]const CFinding, len: usize) void {
    if (findings == null or len == 0) return;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (findings[i].detail) |d| freeDetailFromC(d);
    }
    const arr_slice = @as([*]const CFinding, findings)[0..len];
    c_allocator.free(@as([*]CFinding, @constCast(@ptrCast(arr_slice.ptr)))[0..len]);
}
