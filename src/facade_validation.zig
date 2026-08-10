//! Honest JPEG 2000 and JPEG XL validation result translation.
//!
//! The facade preserves each leaf's raw finding code and four-way outcome.
//! Unknown future leaf codes fail closed as indeterminate instead of being
//! silently promoted to valid or mislabeled as corrupt.

const std = @import("std");
const jp2z = @import("jp2z");
const libjxlz = @import("libjxlz");
const errors = @import("core/errors.zig");

pub const Severity = errors.Severity;
pub const FindingCode = errors.FindingCode;

pub const StrictVerdict = enum(u8) {
    valid,
    corrupt,
    unsupported,
    indeterminate,
};

pub const ValidatorSource = enum(u8) {
    jp2z,
    libjxlz,
    /// jpegz's own cleanroom T.81 / T.87 validator. Appended 2026-08-06 when
    /// `validateAny` began routing the JPEG leg through this same result type.
    jpegz,
};

pub const ValidationFormat = enum(u8) {
    jpeg2000,
    jpeg_xl,
    /// T.81 and T.87 both open with SOI and are validated by the same walker,
    /// so they share one format here; `ValidationReport.variant` is what
    /// separates baseline from progressive from JPEG-LS.
    jpeg,
    /// No JPEG-family signature matched. Distinct from every verdict: this
    /// says which validator ran (none), not whether the bytes are damaged.
    unknown,
};

/// The 12-byte JP2 signature box (T.800 §I.5.1) and its JPEG XL counterpart
/// (18181-2 §3.1). They are byte-identical except for the 4-byte type field,
/// which is the only thing that may be used to tell them apart.
const jp2_signature_box = [_]u8{
    0x00, 0x00, 0x00, 0x0C, 'j', 'P', ' ', ' ', 0x0D, 0x0A, 0x87, 0x0A,
};
const jxl_signature_box = [_]u8{
    0x00, 0x00, 0x00, 0x0C, 'J', 'X', 'L', ' ', 0x0D, 0x0A, 0x87, 0x0A,
};

/// Classify a byte string into the JPEG-family container that owns it, using
/// magic numbers only — no parsing, no allocation, no I/O.
///
/// This is the routing decision `validateAny` makes, split out so it can be
/// tested as a classifier over a labeled corpus (both sensitivity and
/// specificity) rather than as a predicate over one happy example. Answering
/// `.unknown` is a real answer: it keeps foreign bytes from being handed to a
/// validator that would then describe them in a vocabulary they never claimed.
pub fn sniff(data: []const u8) ValidationFormat {
    if (data.len >= jp2_signature_box.len) {
        const head = data[0..jp2_signature_box.len];
        if (std.mem.eql(u8, head, &jp2_signature_box)) return .jpeg2000;
        if (std.mem.eql(u8, head, &jxl_signature_box)) return .jpeg_xl;
    }
    if (data.len >= 2 and data[0] == 0xFF) return switch (data[1]) {
        0xD8 => .jpeg, // SOI — T.81 §B.1.1.3, shared by T.87
        0x4F => .jpeg2000, // SOC — T.800 §A.4.1
        0x0A => .jpeg_xl, // bare codestream — 18181-1 §9.1
        else => .unknown,
    };
    return .unknown;
}

pub const StrictFinding = struct {
    source: ValidatorSource,
    leaf_code: u32,
    code: ?FindingCode,
    severity: Severity,
    offset: ?u64 = null,
    host_offset: ?u64 = null,
    offset_is_exact: bool = false,
    detail: ?[]const u8 = null,
};

pub const StrictValidationResult = struct {
    verdict: StrictVerdict,
    format: ValidationFormat,
    /// Which storage variant was detected inside `format`. `format` is the
    /// routing answer (which validator ran); this is the codec detail beneath
    /// it — baseline vs progressive vs arithmetic vs JPEG-LS all sniff as
    /// `.jpeg`, and collapsing them would make the report less specific than
    /// the severity-rated one it replaces.
    variant: errors.Variant = .unknown,
    width: ?u32 = null,
    height: ?u32 = null,
    frames_validated: u32 = 0,
    findings: std.ArrayList(StrictFinding) = .empty,

    pub fn isValid(self: StrictValidationResult) bool {
        return self.verdict == .valid;
    }

    pub fn deinit(self: *StrictValidationResult, allocator: std.mem.Allocator) void {
        for (self.findings.items) |finding| {
            if (finding.detail) |detail| allocator.free(detail);
        }
        self.findings.deinit(allocator);
        self.* = undefined;
    }
};

pub const MappedFinding = struct {
    verdict: StrictVerdict,
    code: ?FindingCode,
    severity: Severity,
};

fn mappedJp2Code(raw: u32, container_ok: bool) ?FindingCode {
    if (raw == @intFromEnum(jp2z.FindingCode.missing_soi)) {
        return if (container_ok) .jp2_invalid_codestream else .jp2_invalid_signature;
    }
    return std.enums.fromInt(FindingCode, raw);
}

/// Maps one jp2z finding without discarding its unsupported or unknown state.
/// The caller separately retains `raw` as `StrictFinding.leaf_code`.
pub fn mapJp2Finding(raw: u32, severity: Severity, container_ok: bool) MappedFinding {
    const code = mappedJp2Code(raw, container_ok);
    if (code == null) return .{ .verdict = .indeterminate, .code = null, .severity = .warn };
    if (raw == @intFromEnum(jp2z.FindingCode.jp2_unsupported_marker_ignored)) {
        return .{ .verdict = .unsupported, .code = code, .severity = severity };
    }
    return .{
        .verdict = if (severity == .fail) .corrupt else .valid,
        .code = code,
        .severity = severity,
    };
}

fn jxlCode(raw: i32) ?FindingCode {
    return switch (raw) {
        1 => .jxl_invalid_signature,
        2 => .jxl_truncated,
        3 => .jxl_malformed,
        4 => .jxl_unsupported_feature,
        5 => .jxl_resource_limit,
        6 => .jxl_out_of_memory,
        7 => .jxl_invalid_argument,
        8 => .jxl_unclassified_decoder_error,
        else => null,
    };
}

/// Maps every libjxlz strict verdict/code pair; inconsistent or future pairs
/// become indeterminate so version skew cannot manufacture a clean result.
pub fn mapJxlFinding(raw_verdict: i32, raw_code: i32) MappedFinding {
    if (raw_verdict == 0 and raw_code == 0) {
        return .{ .verdict = .valid, .code = null, .severity = .pass };
    }
    const code = jxlCode(raw_code) orelse
        return .{ .verdict = .indeterminate, .code = null, .severity = .warn };
    const expected_verdict: StrictVerdict = switch (raw_code) {
        1, 2, 3 => .corrupt,
        4 => .unsupported,
        5, 6, 7, 8 => .indeterminate,
        else => unreachable,
    };
    const expected_raw: i32 = switch (expected_verdict) {
        .valid => 0,
        .corrupt => 1,
        .unsupported => 2,
        .indeterminate => 3,
    };
    if (raw_verdict != expected_raw) {
        return .{ .verdict = .indeterminate, .code = code, .severity = .warn };
    }
    return .{
        .verdict = expected_verdict,
        .code = code,
        .severity = if (expected_verdict == .corrupt) .fail else .warn,
    };
}

/// Runs jp2z's public strict pure-Zig validator and translates its full report.
pub fn validateJp2(
    allocator: std.mem.Allocator,
    data: []const u8,
    container_ok: bool,
) error{OutOfMemory}!StrictValidationResult {
    var leaf = try jp2z.deepValidate(allocator, data, true);
    defer leaf.deinit(allocator);

    var result = StrictValidationResult{
        .verdict = .valid,
        .format = .jpeg2000,
        .variant = .jpeg2000,
        .width = leaf.width,
        .height = leaf.height,
    };
    errdefer result.deinit(allocator);
    try result.findings.ensureTotalCapacity(allocator, leaf.findings.items.len);

    var saw_unknown = false;
    var saw_unsupported = false;
    var saw_corrupt = false;
    for (leaf.findings.items) |finding| {
        const severity: Severity = @enumFromInt(@intFromEnum(finding.severity));
        const mapped = mapJp2Finding(@intFromEnum(finding.code), severity, container_ok);
        saw_unknown = saw_unknown or mapped.code == null;
        saw_unsupported = saw_unsupported or mapped.verdict == .unsupported;
        saw_corrupt = saw_corrupt or mapped.verdict == .corrupt;
        const detail = if (finding.detail) |value| try allocator.dupe(u8, value) else null;
        result.findings.appendAssumeCapacity(.{
            .source = .jp2z,
            .leaf_code = @intFromEnum(finding.code),
            .code = mapped.code,
            .severity = mapped.severity,
            .offset = finding.offset,
            .detail = detail,
        });
    }
    result.verdict = if (saw_corrupt)
        .corrupt
    else if (saw_unknown or leaf.overall == .fail)
        .indeterminate
    else if (saw_unsupported)
        .unsupported
    else
        .valid;
    return result;
}

pub const JxlOptions = libjxlz.validation.Options;
pub const default_jxl_options = libjxlz.validation.default_options;

/// Runs libjxlz strict validation and preserves its verdict, code, and offsets.
pub fn validateJxl(
    allocator: std.mem.Allocator,
    data: []const u8,
    options: JxlOptions,
) error{OutOfMemory}!StrictValidationResult {
    const leaf = libjxlz.validation.validate(data, options);
    const raw_verdict: i32 = @intCast(@intFromEnum(leaf.verdict));
    const raw_code: i32 = @intCast(@intFromEnum(leaf.code));
    const mapped = mapJxlFinding(raw_verdict, raw_code);
    var result = StrictValidationResult{
        .verdict = mapped.verdict,
        .format = .jpeg_xl,
        .variant = .jpeg_xl,
        .frames_validated = leaf.frames_validated,
    };
    errdefer result.deinit(allocator);
    if (raw_code != 0) {
        try result.findings.append(allocator, .{
            .source = .libjxlz,
            .leaf_code = @intCast(raw_code),
            .code = mapped.code,
            .severity = mapped.severity,
            .offset = leaf.byte_offset,
            .host_offset = leaf.host_byte_offset,
            .offset_is_exact = leaf.offset_is_exact != 0,
        });
    }
    return result;
}
