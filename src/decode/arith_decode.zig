//! Arithmetic-coded JPEG decoder entry points (SOF9 / SOF10).
//!
//! SOF9 — extended sequential with arithmetic coding (T.81 §F.1.4).
//! SOF10 — progressive with arithmetic coding (T.81 §G.1).
//! SOF11 (lossless, arithmetic) is deferred — same A2 rationale:
//! `cjpeg -arithmetic -lossless` errors with "arithmetic coding is
//! not implemented", so the variant has no ground-truth encoder.
//!
//! This module is the SOF dispatcher. Entropy decode lives in
//! `arith_coder.zig` (Q-coder state machine + DC/AC binarization).
//! IDCT + assemble reuses `baseline.zig`'s `assembleOutput` (SOF9)
//! and `progressive.zig`'s `assembleProgressiveGeneric` (SOF10) —
//! the A3 refactor's Phase 2 seam pays off here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const errors = @import("../core/errors.zig");
const types = @import("../core/types.zig");
const arith_coder = @import("arith_coder.zig");

const Error = errors.DecodeError;

// Force-import the Q-coder so its inline tests are discovered.
comptime {
    _ = arith_coder;
}

/// Auto-detect SOF9 vs SOF10 vs SOF11 and dispatch.
/// Stub at this commit — returns error.NotImplemented until the
/// Q-coder + binarization land in arith_coder.zig.
pub fn decode(allocator: Allocator, data: []const u8) Error!types.Image {
    _ = allocator;
    _ = data;
    return error.NotImplemented;
}
