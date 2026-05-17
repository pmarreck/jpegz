//! Side-channel collector for spec-deviation findings emitted by the
//! cleanroom decoder. When the decoder tolerates a deviation that
//! libjpeg-turbo would WARNMS about (e.g. extraneous bytes before a
//! marker, premature EOI with recovered data), it appends a Finding
//! here so `validate(...)` and other strict consumers can surface them.
//!
//! Architecture: matches the "validate-warns over silent tolerance"
//! decision in NEXT_STEPS.md. The wrapper path harvests warnings via
//! libjpeg's WARNMS callback (`src/ffi/libjpeg_wrapper.zig`); the
//! cleanroom path emits them here. Both feed the same `Finding` shape,
//! so the validator surface can be unified.
//!
//! Empty list = clean decode. Caller owns the sink; pass `null` to the
//! decoder when warnings are uninteresting (the normal `decode` path).

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../jpegz.zig");
const errors = @import("../core/errors.zig");

pub const Finding = types.Finding;
pub const Severity = errors.Severity;
pub const FindingCode = errors.FindingCode;

pub const FindingsSink = struct {
    allocator: Allocator,
    list: std.ArrayList(Finding),

    pub fn init(allocator: Allocator) FindingsSink {
        return .{
            .allocator = allocator,
            .list = .empty,
        };
    }

    pub fn deinit(self: *FindingsSink) void {
        for (self.list.items) |f| {
            if (f.detail) |d| self.allocator.free(d);
        }
        self.list.deinit(self.allocator);
    }

    /// Append a finding. `detail` (if non-null) is duped from the sink's
    /// allocator and freed by `deinit`. The caller's slice is borrowed
    /// only for the duration of this call.
    pub fn emit(
        self: *FindingsSink,
        severity: Severity,
        code: FindingCode,
        offset: ?u64,
        detail: ?[]const u8,
    ) Allocator.Error!void {
        const stored: ?[]const u8 = if (detail) |d|
            try self.allocator.dupe(u8, d)
        else
            null;
        errdefer if (stored) |s| self.allocator.free(s);

        try self.list.append(self.allocator, .{
            .severity = severity,
            .code = code,
            .offset = offset,
            .detail = stored,
        });
    }

    pub fn items(self: *const FindingsSink) []const Finding {
        return self.list.items;
    }
};

test "FindingsSink: init, emit, deinit cleans owned details" {
    var sink = FindingsSink.init(std.testing.allocator);
    defer sink.deinit();

    try sink.emit(.warn, .extraneous_bytes_before_marker, 42, "hello");
    try sink.emit(.info, .twelve_bit_precision, null, null);

    try std.testing.expectEqual(@as(usize, 2), sink.items().len);
    try std.testing.expectEqual(Severity.warn, sink.items()[0].severity);
    try std.testing.expectEqual(@as(?u64, 42), sink.items()[0].offset);
    try std.testing.expectEqualStrings("hello", sink.items()[0].detail.?);
    try std.testing.expectEqual(@as(?[]const u8, null), sink.items()[1].detail);
}
