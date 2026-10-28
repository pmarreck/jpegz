//! Detection rates for ./corruption-coverage.
//!
//! A "corrupt" count is jpegz's own verdict on a mutated byte string. It is
//! an observed rejection, not proof that the mutation is spec-invalid: a
//! conforming edit can stay valid, and a valid edit that jpegz rejects is a
//! false reject. Wilson intervals are over completed judgments only. No-ops,
//! crashes, timeouts and I/O errors stay outside that denominator.

const std = @import("std");

pub const z95: f64 = 1.959963984540054;

pub const Interval = struct { lo: f64, hi: f64 };

/// Wilson score interval for k successes in n Bernoulli trials at 95%.
/// Null when n is 0. The bounds stay inside [0, 1], including when k is 0 or n.
pub fn wilson(k: u64, n: u64) ?Interval {
    if (n == 0) return null;
    const kf: f64 = @floatFromInt(k);
    const nf: f64 = @floatFromInt(n);
    const z2 = z95 * z95;
    const center = (kf + z2 / 2.0) / (nf + z2);
    const half = (z95 / (nf + z2)) * @sqrt(kf * (nf - kf) / nf + z2 / 4.0);
    return .{ .lo = @max(0.0, center - half), .hi = @min(1.0, center + half) };
}

/// Rounds so the worst-case (p = 0.5) Wilson half-width is at most `half`.
pub fn roundsForHalfWidth(half: f64) u64 {
    const n = (z95 * z95) / (4.0 * half * half);
    return @intFromFloat(@ceil(n));
}

pub const Class = enum {
    detected,
    accepted,
    known_defect,
    unsupported,
    indeterminate,
    inconsistent,
    io_error,
    timeout,
    crash,
    harness,
    noop,
};

/// Map one corruption-reader case and one jpegz run onto a coverage class.
/// Exit 1 counts as detection only together with verdict "corrupt". A
/// disagreement is `inconsistent`, not a detection and not an acceptance.
pub fn classify(status: []const u8, rc: i32, verdict: []const u8) Class {
    if (std.mem.eql(u8, status, "noop")) return .noop;
    if (!std.mem.eql(u8, status, "applied")) return .harness;
    if (rc == 124) return .timeout;
    if (rc < 0 or rc >= 128) return .crash;
    if (rc == 126 or rc == 127) return .harness;
    if (rc == 2) return .io_error;
    if (rc == 0) return if (std.mem.eql(u8, verdict, "valid")) .accepted else .inconsistent;
    if (rc == 1) return if (std.mem.eql(u8, verdict, "corrupt")) .detected else .inconsistent;
    if (rc == 4) return if (std.mem.eql(u8, verdict, "known_defect")) .known_defect else .inconsistent;
    if (rc == 3) {
        if (std.mem.eql(u8, verdict, "unsupported")) return .unsupported;
        if (std.mem.eql(u8, verdict, "indeterminate")) return .indeterminate;
        return .inconsistent;
    }
    return .harness;
}

pub const Cell = struct {
    fixture: []const u8,
    profile: []const u8,
    applied: u64 = 0,
    noop: u64 = 0,
    judged: u64 = 0,
    detected: u64 = 0,
    accepted: u64 = 0,
    known_defect: u64 = 0,
    unsupported: u64 = 0,
    indeterminate: u64 = 0,
    inconsistent: u64 = 0,
    io_error: u64 = 0,
    timeout: u64 = 0,
    crash: u64 = 0,
    harness: u64 = 0,
    lo: ?f64 = null,
    hi: ?f64 = null,
};

pub const Survivor = struct {
    fixture: []const u8,
    profile: []const u8,
    round: i64,
    class: Class,
    rc: i32,
    verdict: []const u8,
};

pub const Batch = struct {
    cells: []Cell,
    survivors: []Survivor,
};

const Result = struct { path: []const u8, rc: i32, verdict: []const u8 };

pub const Input = struct {
    fixture: []const u8,
    profile: []const u8,
    report: []const u8,
    results: []const u8,
};

pub fn aggregate(
    allocator: std.mem.Allocator,
    fixture: []const u8,
    profile: []const u8,
    report: []const u8,
    results: []const u8,
) !Batch {
    return aggregateAll(allocator, &.{.{
        .fixture = fixture,
        .profile = profile,
        .report = report,
        .results = results,
    }});
}

/// Fold every fixture/profile batch, then add one pooled row per profile and a grand total.
/// Cell and survivor strings borrow from the inputs and from "(all)".
pub fn aggregateAll(allocator: std.mem.Allocator, inputs: []const Input) !Batch {
    var cells: std.ArrayList(Cell) = .empty;
    errdefer cells.deinit(allocator);
    var survivors: std.ArrayList(Survivor) = .empty;
    errdefer survivors.deinit(allocator);
    for (inputs) |input| {
        try appendBatch(&cells, &survivors, allocator, input.fixture, input.profile, input.report, input.results);
    }
    if (inputs.len > 0) try appendPools(&cells, allocator);
    return .{
        .cells = try cells.toOwnedSlice(allocator),
        .survivors = try survivors.toOwnedSlice(allocator),
    };
}

fn appendBatch(
    cells: *std.ArrayList(Cell),
    survivors: *std.ArrayList(Survivor),
    allocator: std.mem.Allocator,
    fixture: []const u8,
    profile: []const u8,
    report: []const u8,
    results: []const u8,
) !void {
    const parsed = try parseResults(allocator, results);
    defer allocator.free(parsed);
    var cell = Cell{ .fixture = fixture, .profile = profile };
    var line_it = std.mem.splitScalar(u8, report, '\n');
    while (line_it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        if (line.len == 0) continue;
        const status = try jsonString(allocator, line, "status");
        defer allocator.free(status);
        if (std.mem.eql(u8, status, "noop")) {
            cell.noop += 1;
            continue;
        }
        if (!std.mem.eql(u8, status, "applied")) {
            cell.harness += 1;
            continue;
        }
        const path = try jsonString(allocator, line, "path");
        defer allocator.free(path);
        const round = jsonInt(line, "round") orelse return error.BadReport;
        const result = findResult(parsed, path) orelse return error.MissingResult;
        const class = classify("applied", result.rc, result.verdict);
        cell.applied += 1;
        switch (class) {
            .detected => cell.detected += 1,
            .accepted => cell.accepted += 1,
            .known_defect => cell.known_defect += 1,
            .unsupported => cell.unsupported += 1,
            .indeterminate => cell.indeterminate += 1,
            .inconsistent => cell.inconsistent += 1,
            .io_error => cell.io_error += 1,
            .timeout => cell.timeout += 1,
            .crash => cell.crash += 1,
            .harness => cell.harness += 1,
            .noop => unreachable,
        }
        if (class != .detected) {
            try survivors.append(allocator, .{
                .fixture = fixture,
                .profile = profile,
                .round = round,
                .class = class,
                .rc = result.rc,
                .verdict = result.verdict,
            });
        }
    }
    finish(&cell);
    try cells.append(allocator, cell);
}

fn finish(cell: *Cell) void {
    cell.judged = cell.detected + cell.accepted + cell.known_defect + cell.unsupported + cell.indeterminate + cell.inconsistent;
    if (wilson(cell.detected, cell.judged)) |iv| {
        cell.lo = iv.lo;
        cell.hi = iv.hi;
    }
}

fn absorb(into: *Cell, c: Cell) void {
    into.applied += c.applied;
    into.noop += c.noop;
    into.detected += c.detected;
    into.accepted += c.accepted;
    into.known_defect += c.known_defect;
    into.unsupported += c.unsupported;
    into.indeterminate += c.indeterminate;
    into.inconsistent += c.inconsistent;
    into.io_error += c.io_error;
    into.timeout += c.timeout;
    into.crash += c.crash;
    into.harness += c.harness;
}

fn appendPools(cells: *std.ArrayList(Cell), allocator: std.mem.Allocator) !void {
    const n = cells.items.len;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const profile = cells.items[i].profile;
        var seen = false;
        for (cells.items[0..i]) |prev| {
            if (std.mem.eql(u8, prev.profile, profile)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        var pool = Cell{ .fixture = "(all)", .profile = profile };
        for (cells.items[0..n]) |c| {
            if (std.mem.eql(u8, c.profile, profile)) absorb(&pool, c);
        }
        finish(&pool);
        try cells.append(allocator, pool);
    }
    var grand = Cell{ .fixture = "(all)", .profile = "(all)" };
    for (cells.items[0..n]) |c| absorb(&grand, c);
    finish(&grand);
    try cells.append(allocator, grand);
}

fn parseResults(allocator: std.mem.Allocator, results: []const u8) ![]Result {
    var list: std.ArrayList(Result) = .empty;
    errdefer list.deinit(allocator);
    var it = std.mem.splitScalar(u8, results, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const path = fields.next() orelse return error.BadResults;
        const rc_s = fields.next() orelse return error.BadResults;
        const verdict = fields.next() orelse return error.BadResults;
        if (fields.next() != null) return error.BadResults;
        if (path.len == 0) return error.BadResults;
        for (list.items) |prev| {
            if (std.mem.eql(u8, prev.path, path)) return error.BadResults;
        }
        try list.append(allocator, .{
            .path = path,
            .rc = std.fmt.parseInt(i32, rc_s, 10) catch return error.BadResults,
            .verdict = verdict,
        });
    }
    return list.toOwnedSlice(allocator);
}

fn findResult(results: []const Result, path: []const u8) ?Result {
    for (results) |r| {
        if (std.mem.eql(u8, r.path, path)) return r;
    }
    return null;
}

fn keyAt(line: []const u8, key: []const u8) ?usize {
    var i: usize = 0;
    while (i + key.len + 3 <= line.len) : (i += 1) {
        if (line[i] != '"') continue;
        if (!std.mem.eql(u8, line[i + 1 .. i + 1 + key.len], key)) continue;
        if (line[i + 1 + key.len] != '"') continue;
        if (line[i + 2 + key.len] != ':') continue;
        var at = i + key.len + 3;
        while (at < line.len and line[at] == ' ') at += 1;
        return at;
    }
    return null;
}

fn jsonInt(line: []const u8, key: []const u8) ?i64 {
    const at = keyAt(line, key) orelse return null;
    if (at >= line.len) return null;
    var i = at;
    var sign: i64 = 1;
    if (line[i] == '-') {
        sign = -1;
        i += 1;
    }
    if (i >= line.len or line[i] < '0' or line[i] > '9') return null;
    var n: i64 = 0;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) {
        n = n * 10 + (line[i] - '0');
    }
    return sign * n;
}

fn jsonString(allocator: std.mem.Allocator, line: []const u8, key: []const u8) ![]u8 {
    const at = keyAt(line, key) orelse return error.BadReport;
    if (at >= line.len or line[at] != '"') return error.BadReport;
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var i = at + 1;
    while (i < line.len) : (i += 1) {
        if (line[i] == '\\') {
            i += 1;
            if (i >= line.len) return error.BadReport;
            const ch: u8 = switch (line[i]) {
                'n' => '\n',
                't' => '\t',
                '"' => '"',
                '\\' => '\\',
                '/' => '/',
                else => line[i],
            };
            try buf.append(allocator, ch);
        } else if (line[i] == '"') {
            return buf.toOwnedSlice(allocator);
        } else {
            try buf.append(allocator, line[i]);
        }
    }
    return error.BadReport;
}

fn appendSanitized(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    for (text) |c| {
        const out: u8 = if (c == '\t' or c == '\n' or c == '\r') ' ' else c;
        try buf.append(allocator, out);
    }
}

fn appendInterval(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, cell: Cell) !void {
    if (cell.judged == 0 or cell.lo == null or cell.hi == null) {
        try buf.appendSlice(allocator, "n/a");
        return;
    }
    const rate = 100.0 * @as(f64, @floatFromInt(cell.detected)) / @as(f64, @floatFromInt(cell.judged));
    const text = try std.fmt.allocPrint(allocator, "{d:.1}% [{d:.1}, {d:.1}]", .{
        rate, 100.0 * cell.lo.?, 100.0 * cell.hi.?,
    });
    defer allocator.free(text);
    try buf.appendSlice(allocator, text);
}

/// Human table. One row per cell, including the pooled rows aggregateAll appends.
pub fn formatTable(allocator: std.mem.Allocator, cells: []const Cell) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator,
        \\# Corrupt counts jpegz verdict "corrupt" (exit 1) on bytes corruption-reader changed.
        \\# That is an observed rejection, not proof the mutation is spec-invalid. A conforming
        \\# edit can stay valid, and a valid edit that jpegz rejects is a false reject.
        \\# Wilson 95% is corrupt/judged. No-ops, crashes, timeouts, I/O errors and harness
        \\# failures stay outside that denominator. At p = 0.5, a 10-point half-width needs
        \\
    );
    const rounds = try std.fmt.allocPrint(allocator, "# {d} rounds and a 5-point half-width needs {d}.\n", .{
        roundsForHalfWidth(0.10), roundsForHalfWidth(0.05),
    });
    defer allocator.free(rounds);
    try buf.appendSlice(allocator, rounds);
    try buf.appendSlice(allocator, "fixture\tprofile\tapplied\tnoop\tjudged\tcorrupt\twilson95\taccepted\tknown_defect\tunsupported\tindeterminate\tinconsistent\tio\ttimeout\tcrash\tharness\n");
    for (cells) |cell| {
        try appendSanitized(&buf, allocator, cell.fixture);
        try buf.append(allocator, '\t');
        try appendSanitized(&buf, allocator, cell.profile);
        const counts = try std.fmt.allocPrint(allocator, "\t{d}\t{d}\t{d}\t{d}\t", .{
            cell.applied, cell.noop, cell.judged, cell.detected,
        });
        defer allocator.free(counts);
        try buf.appendSlice(allocator, counts);
        try appendInterval(&buf, allocator, cell);
        const rest = try std.fmt.allocPrint(allocator, "\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
            cell.accepted, cell.known_defect, cell.unsupported, cell.indeterminate, cell.inconsistent,
            cell.io_error, cell.timeout, cell.crash, cell.harness,
        });
        defer allocator.free(rest);
        try buf.appendSlice(allocator, rest);
    }
    return buf.toOwnedSlice(allocator);
}

fn appendJsonString(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    try buf.append(allocator, '"');
    for (text) |c| switch (c) {
        '"' => try buf.appendSlice(allocator, "\\\""),
        '\\' => try buf.appendSlice(allocator, "\\\\"),
        '\n' => try buf.appendSlice(allocator, "\\n"),
        '\r' => try buf.appendSlice(allocator, "\\r"),
        '\t' => try buf.appendSlice(allocator, "\\t"),
        else => try buf.append(allocator, c),
    };
    try buf.append(allocator, '"');
}

pub fn formatSummary(allocator: std.mem.Allocator, cells: []const Cell) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (cells) |cell| {
        try buf.appendSlice(allocator, "{\"fixture\":");
        try appendJsonString(&buf, allocator, cell.fixture);
        try buf.appendSlice(allocator, ",\"profile\":");
        try appendJsonString(&buf, allocator, cell.profile);
        const counts = try std.fmt.allocPrint(allocator, ",\"applied\":{d},\"noop\":{d},\"judged\":{d},\"detected\":{d},\"accepted\":{d},\"known_defect\":{d},\"unsupported\":{d},\"indeterminate\":{d},\"inconsistent\":{d},\"io_error\":{d},\"timeout\":{d},\"crash\":{d},\"harness\":{d},", .{
            cell.applied, cell.noop, cell.judged, cell.detected, cell.accepted,
            cell.known_defect, cell.unsupported, cell.indeterminate, cell.inconsistent,
            cell.io_error, cell.timeout, cell.crash, cell.harness,
        });
        defer allocator.free(counts);
        try buf.appendSlice(allocator, counts);
        if (cell.lo) |lo| {
            const bounds = try std.fmt.allocPrint(allocator, "\"lo\":{d:.10},\"hi\":{d:.10}}}\n", .{ lo, cell.hi.? });
            defer allocator.free(bounds);
            try buf.appendSlice(allocator, bounds);
        } else {
            try buf.appendSlice(allocator, "\"lo\":null,\"hi\":null}\n");
        }
    }
    return buf.toOwnedSlice(allocator);
}

pub fn formatSurvivors(allocator: std.mem.Allocator, survivors: []const Survivor) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (survivors) |s| {
        try buf.appendSlice(allocator, "{\"fixture\":");
        try appendJsonString(&buf, allocator, s.fixture);
        try buf.appendSlice(allocator, ",\"profile\":");
        try appendJsonString(&buf, allocator, s.profile);
        const mid = try std.fmt.allocPrint(allocator, ",\"round\":{d},\"class\":\"{s}\",\"rc\":{d},\"verdict\":", .{
            s.round, @tagName(s.class), s.rc,
        });
        defer allocator.free(mid);
        try buf.appendSlice(allocator, mid);
        try appendJsonString(&buf, allocator, s.verdict);
        try buf.appendSlice(allocator, "}\n");
    }
    return buf.toOwnedSlice(allocator);
}

fn writeOut(io: std.Io, path: []const u8, data: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(allocator);
    var inputs: std.ArrayList(Input) = .empty;
    var table_path: ?[]const u8 = null;
    var summary_path: ?[]const u8 = null;
    var survivors_path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--batch")) {
            if (i + 4 >= args.len) return error.Usage;
            const fixture = args[i + 1];
            const profile = args[i + 2];
            const report = try std.Io.Dir.cwd().readFileAlloc(io, args[i + 3], allocator, .limited(64 * 1024 * 1024));
            const results = try std.Io.Dir.cwd().readFileAlloc(io, args[i + 4], allocator, .limited(64 * 1024 * 1024));
            try inputs.append(allocator, .{ .fixture = fixture, .profile = profile, .report = report, .results = results });
            i += 4;
        } else if (std.mem.eql(u8, arg, "--table")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            table_path = args[i];
        } else if (std.mem.eql(u8, arg, "--summary")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            summary_path = args[i];
        } else if (std.mem.eql(u8, arg, "--survivors")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            survivors_path = args[i];
        } else return error.Usage;
    }
    if (inputs.items.len == 0 or table_path == null or summary_path == null) return error.Usage;
    const batch = aggregateAll(allocator, inputs.items) catch |err| {
        std.debug.print("coverage-stats: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
    const table = try formatTable(allocator, batch.cells);
    const summary = try formatSummary(allocator, batch.cells);
    try writeOut(io, table_path.?, table);
    try writeOut(io, summary_path.?, summary);
    if (survivors_path) |path| {
        const lines = try formatSurvivors(allocator, batch.survivors);
        try writeOut(io, path, lines);
    }
    var trouble = false;
    for (batch.cells) |cell| {
        if (cell.harness > 0) std.process.exit(2);
        if (cell.crash > 0 or cell.timeout > 0 or cell.io_error > 0) trouble = true;
    }
    if (trouble) std.process.exit(1);
}

fn near(a: f64, b: f64) !void {
    try std.testing.expectApproxEqAbs(b, a, 1e-9);
}

test "wilson 95 percent stays inside the unit interval at the extremes" {
    const mid = wilson(5, 10).?;
    try near(mid.lo, 0.2365930905);
    try near(mid.hi, 0.7634069095);
    const none = wilson(0, 10).?;
    try near(none.lo, 0.0);
    try near(none.hi, 0.2775327999);
    const all = wilson(10, 10).?;
    try near(all.lo, 0.7224672001);
    try near(all.hi, 1.0);
    const small = wilson(0, 7).?;
    try near(small.lo, 0.0);
    try near(small.hi, 0.3543304351);
    try std.testing.expect(wilson(0, 0) == null);
}

test "worst-case half-width sets the round count" {
    try std.testing.expectEqual(@as(u64, 97), roundsForHalfWidth(0.10));
    try std.testing.expectEqual(@as(u64, 385), roundsForHalfWidth(0.05));
}

test "classify trusts the exit code only when the verdict agrees" {
    try std.testing.expectEqual(Class.noop, classify("noop", 0, ""));
    try std.testing.expectEqual(Class.detected, classify("applied", 1, "corrupt"));
    try std.testing.expectEqual(Class.accepted, classify("applied", 0, "valid"));
    try std.testing.expectEqual(Class.unsupported, classify("applied", 3, "unsupported"));
    try std.testing.expectEqual(Class.indeterminate, classify("applied", 3, "indeterminate"));
    try std.testing.expectEqual(Class.inconsistent, classify("applied", 1, "valid"));
    try std.testing.expectEqual(Class.inconsistent, classify("applied", 0, "corrupt"));
    try std.testing.expectEqual(Class.io_error, classify("applied", 2, ""));
    try std.testing.expectEqual(Class.timeout, classify("applied", 124, ""));
    try std.testing.expectEqual(Class.crash, classify("applied", 139, ""));
    try std.testing.expectEqual(Class.harness, classify("applied", 127, ""));
    try std.testing.expectEqual(Class.harness, classify("other", 1, "corrupt"));
}

test "known-defect exit and verdict must agree across the outcome set" {
    const verdicts = [_][]const u8{ "valid", "corrupt", "unsupported", "indeterminate", "known_defect" };
    const expected = [_][]const u8{
        "accepted", "inconsistent", "inconsistent", "inconsistent", "inconsistent",
        "inconsistent", "detected", "inconsistent", "inconsistent", "inconsistent",
        "io_error", "io_error", "io_error", "io_error", "io_error",
        "inconsistent", "inconsistent", "unsupported", "indeterminate", "inconsistent",
        "inconsistent", "inconsistent", "inconsistent", "inconsistent", "known_defect",
    };
    for (0..5) |rc| {
        for (verdicts, 0..) |verdict, i| {
            try std.testing.expectEqualStrings(expected[rc * 5 + i], @tagName(classify("applied", @intCast(rc), verdict)));
        }
    }
}

test "known defects retain a separate count in cells pools and JSON" {
    const allocator = std.testing.allocator;
    const report =
        \\{"status":"applied","path":"/tmp/a","round":0}
        \\{"status":"applied","path":"/tmp/b","round":1}
        \\
    ;
    const results = "/tmp/a\t1\tcorrupt\n/tmp/b\t4\tknown_defect\n";
    const batch = try aggregate(allocator, "fixture", "sniper", report, results);
    defer allocator.free(batch.cells);
    defer allocator.free(batch.survivors);
    for (batch.cells) |cell| {
        try std.testing.expectEqual(@as(u64, 2), cell.judged);
        try std.testing.expectEqual(@as(u64, 1), cell.detected);
        try std.testing.expectEqual(@as(u64, 1), cell.known_defect);
        try std.testing.expectEqual(@as(u64, 0), cell.accepted);
        try std.testing.expectEqual(@as(u64, 0), cell.harness);
    }
    try std.testing.expectEqual(@as(usize, 1), batch.survivors.len);
    try std.testing.expectEqual(Class.known_defect, batch.survivors[0].class);
    const summary = try formatSummary(allocator, batch.cells[0..1]);
    defer allocator.free(summary);
    const parsed = try std.json.parseFromSlice(struct { known_defect: u64, judged: u64, detected: u64 },
        allocator, summary, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, 1), parsed.value.known_defect);
    try std.testing.expectEqual(@as(u64, 2), parsed.value.judged);
    try std.testing.expectEqual(@as(u64, 1), parsed.value.detected);
}

test "detection rate ignores no-ops and crashes" {
    const report =
        \\{"report":1,"item":0,"round":0,"status":"applied","noop":null,"emitted":true,"path":"/tmp/a","record":{}}
        \\{"report":1,"item":1,"round":1,"status":"applied","noop":null,"emitted":true,"path":"/tmp/b","record":{}}
        \\{"report":1,"item":2,"round":2,"status":"applied","noop":null,"emitted":true,"path":"/tmp/c","record":{}}
        \\{"report":1,"item":3,"round":3,"status":"applied","noop":null,"emitted":true,"path":"/tmp/d","record":{}}
        \\{"report":1,"item":4,"round":4,"status":"noop","noop":"too_small","emitted":false,"path":null,"record":{}}
        \\
    ;
    const tab = "\t";
    const results = "/tmp/a" ++ tab ++ "1" ++ tab ++ "corrupt\n" ++
        "/tmp/b" ++ tab ++ "1" ++ tab ++ "corrupt\n" ++
        "/tmp/c" ++ tab ++ "0" ++ tab ++ "valid\n" ++
        "/tmp/d" ++ tab ++ "139" ++ tab ++ "\n";
    const batch = try aggregate(std.testing.allocator, "fixture", "sniper", report, results);
    defer std.testing.allocator.free(batch.cells);
    defer std.testing.allocator.free(batch.survivors);
    const cells = batch.cells;
    try std.testing.expectEqual(@as(usize, 2), batch.survivors.len);
    try std.testing.expectEqual(Class.accepted, batch.survivors[0].class);
    try std.testing.expectEqual(Class.crash, batch.survivors[1].class);
    try std.testing.expectEqual(@as(usize, 3), cells.len);
    const cell = cells[0];
    try std.testing.expectEqualStrings("fixture", cell.fixture);
    try std.testing.expectEqualStrings("sniper", cell.profile);
    try std.testing.expectEqual(@as(u64, 4), cell.applied);
    try std.testing.expectEqual(@as(u64, 1), cell.noop);
    try std.testing.expectEqual(@as(u64, 3), cell.judged);
    try std.testing.expectEqual(@as(u64, 2), cell.detected);
    try std.testing.expectEqual(@as(u64, 1), cell.accepted);
    try std.testing.expectEqual(@as(u64, 1), cell.crash);
    const iv = wilson(2, 3).?;
    try near(cell.lo.?, iv.lo);
    try near(cell.hi.?, iv.hi);
    const table = try formatTable(std.testing.allocator, cells);
    defer std.testing.allocator.free(table);
    try std.testing.expect(std.mem.indexOf(u8, table, "66.7% [20.8, 93.9]") != null);
    try std.testing.expect(std.mem.indexOf(u8, table, "(all)\t(all)") != null);
}

test "an applied case with no jpegz result is an error" {
    const report =
        \\{"status":"applied","path":"/tmp/missing","round":0,"record":{}}
        \\
    ;
    try std.testing.expectError(error.MissingResult, aggregate(std.testing.allocator, "f", "sniper", report, ""));
}
