//! Shared debug-mode error tracer for the cleanroom decoders.
//!
//! `fail` is the single, fleet-wide error-reporting helper: in Debug
//! builds it prints `[where] ErrorName` to stderr then returns the
//! error unchanged; in release builds it compiles to a bare
//! `return err` with zero cost (the `comptime` branch is folded away).
//!
//! Centralizing it means every decoder reports errors the same way
//! (baseline pioneered the pattern; the shared marker-parse helpers in
//! `jpeg_markers.zig` and any decoder that wants tracing now share this
//! one implementation) — which is the prerequisite for consolidating
//! the per-decoder marker parsers without per-decoder error-style drift.
//!
//! `where` should encode module + site, e.g. `"baseline:rst_no_marker"`
//! or `"markers:dqt_bad_tq"`, so a Debug trace pinpoints the origin.

const std = @import("std");
const builtin = @import("builtin");
const errors = @import("../core/errors.zig");

pub inline fn fail(comptime where: []const u8, err: errors.DecodeError) errors.DecodeError {
    if (comptime builtin.mode == .Debug) {
        std.debug.print("[{s}] {s}\n", .{ where, @errorName(err) });
    }
    return err;
}
