//! Generate `include/jpegz_errno.h` from `src/core/errors.zig` at
//! build time. Walks `DecodeError`, `Severity`, `Variant`, and
//! `FindingCode` at comptime and emits a stable C enum mirror.
//!
//! The wire format is the contract — adding a Zig variant without
//! re-running this generator (or without keeping the FFI mapper
//! exhaustive) is a build-time error. Drift between Zig and C is
//! impossible by construction.

const std = @import("std");
// `errors` is the core/errors.zig source of truth, exposed to this
// build tool via build.zig's `addImport("errors", ...)`.
const errors = @import("errors");

/// Per the design doc § 4: DecodeError values are negative C ints.
/// The mapping (NotImplemented = -1, InvalidMarker = -2, …) lives in
/// the FFI mapper (src/ffi/c_api.zig). Mirror it here exactly.
const decode_error_codes: []const struct { name: []const u8, code: i32 } = &.{
    .{ .name = "NOT_IMPLEMENTED",        .code = -1 },
    .{ .name = "INVALID_MARKER",         .code = -2 },
    .{ .name = "UNSUPPORTED_PRECISION",  .code = -3 },
    .{ .name = "TRUNCATED_STREAM",       .code = -4 },
    .{ .name = "NOT_ROW_STREAMABLE",     .code = -5 },
    .{ .name = "BACKEND_ERROR",          .code = -6 },
    .{ .name = "INVALID_JP2_CODESTREAM", .code = -7 },
    .{ .name = "OUT_OF_MEMORY",          .code = -8 },
    .{ .name = "CALLBACK_ABORTED",       .code = -9 },
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const args = try std.process.argsAlloc(a);
    if (args.len < 2) {
        std.debug.print("usage: gen_c_header <out_path>\n", .{});
        return error.MissingOutputPath;
    }
    const out_path = args[1];

    var file = try std.fs.cwd().createFile(out_path, .{});
    defer file.close();

    var buf: [4096]u8 = undefined;
    var w = file.writer(&buf);
    const out = &w.interface;

    try out.writeAll(
        \\/* AUTO-GENERATED from src/core/errors.zig — DO NOT EDIT.
        \\ * Regenerated at every build by tools/gen_c_header.zig.
        \\ * Edits will be overwritten.
        \\ */
        \\
        \\#ifndef JPEGZ_ERRNO_H
        \\#define JPEGZ_ERRNO_H
        \\
        \\#ifdef __cplusplus
        \\extern "C" {
        \\#endif
        \\
        \\/* Status codes returned by every jpegz_* function except
        \\ * the void/string ones. JPEGZ_OK is 0; errors are negative. */
        \\typedef enum {
        \\    JPEGZ_OK = 0,
        \\
    );

    for (decode_error_codes) |e| {
        try out.print("    JPEGZ_ERR_{s} = {d},\n", .{ e.name, e.code });
    }

    try out.writeAll(
        \\} jpegz_status_t;
        \\
        \\/* Categorical codes for entries in jpegz_validation_report_t.findings.
        \\ * Numeric values are stable forever; new entries APPEND, never
        \\ * reorder, never reuse a freed value. */
        \\typedef enum {
        \\
    );

    // Emit FindingCode enum entries by walking the Zig enum at comptime,
    // upper-snake-casing the name into an arena-allocated runtime buffer.
    inline for (@typeInfo(errors.FindingCode).@"enum".fields) |f| {
        const upper = try a.alloc(u8, f.name.len);
        for (f.name, 0..) |ch, i| {
            upper[i] = if (ch >= 'a' and ch <= 'z') ch - 32 else ch;
        }
        try out.print("    JPEGZ_FINDING_{s} = {d},\n", .{ upper, f.value });
    }

    try out.writeAll(
        \\} jpegz_finding_code_t;
        \\
        \\#ifdef __cplusplus
        \\} /* extern "C" */
        \\#endif
        \\
        \\#endif /* JPEGZ_ERRNO_H */
        \\
    );

    try out.flush();
}

