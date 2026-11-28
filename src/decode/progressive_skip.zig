//! Scan skipping for recovery decodes of progressive frames.
//!
//! Validation decodes past a scan its marker walk has already judged
//! invalid, so the rest of the file can still be judged. A skipped scan
//! leaves its coefficients unset. A later AC refinement scan reads
//! correction bits only for coefficients that are already nonzero, so its
//! bit consumption depends on the scans before it: refining unset
//! coefficients would desynchronize and report faults that are not in the
//! file. Such a scan is skipped too, and its coefficients stay unknown.
//! DC refinement reads one bit per block regardless of history, and first
//! scans (Ah = 0) start fresh, so both stay decodable.

const std = @import("std");
const FindingsSink = @import("findings.zig").FindingsSink;

/// One progressive decode's scan skipping. `list` holds the SOS marker
/// offsets of scans the validator already reported invalid; an empty list
/// (every decode except validation's) changes nothing.
pub const Skipper = struct {
    list: []const u64,
    unknown: Unknown = .{},

    /// At an SOS whose length field is at `pos.*`, before its header is
    /// parsed: true when the scan is listed. Its band becomes unknown and
    /// `pos.*` moves to the marker that ends its entropy data.
    pub fn skipListed(self: *Skipper, data: []const u8, sos_at: usize, pos: *usize, frame: anytype) bool {
        if (!listed(self.list, sos_at)) return false;
        if (bandOf(data, pos.*, frame)) |b| self.unknown.mark(b.comps[0..b.n], b.ss, b.se) else self.unknown.markAll();
        pos.* = entropyEnd(data, headerEnd(data, pos.*));
        return true;
    }

    /// After a scan's header is parsed and `pos.*` is past it: true when
    /// the scan refines coefficients a skipped scan sets. It is reported as
    /// not judged (INFO at its SOS marker), its band becomes unknown (a
    /// skipped refinement can leave coefficients newly nonzero), and
    /// `pos.*` moves past its entropy data.
    pub fn skipRefinement(self: *Skipper, data: []const u8, sos_at: usize, pos: *usize, scan: anytype, sink: ?*FindingsSink) !bool {
        if (self.list.len == 0) return false;
        const comps = scan.comp_indices[0..scan.num_components];
        if (!self.unknown.refinesUnknown(comps, scan.ss, scan.se, scan.ah)) return false;
        try self.skipUnjudged(data, sos_at, pos, scan, sink, "scan not judged: it refines coefficients that a skipped invalid scan sets");
        return true;
    }

    /// Huffman frames, after the header is parsed: true when the scan names
    /// a table no DHT has defined. The marker walk reports only the first
    /// such scan (one root cause, one record); a later one is not judged.
    pub fn skipTableless(self: *Skipper, data: []const u8, sos_at: usize, pos: *usize, scan: anytype, frame: anytype, dc_tables: anytype, ac_tables: anytype, sink: ?*FindingsSink) !bool {
        if (self.list.len == 0 or tablesDefined(scan, frame, dc_tables, ac_tables)) return false;
        try self.skipUnjudged(data, sos_at, pos, scan, sink, "scan not judged: it names a Huffman table that no DHT segment defines");
        return true;
    }

    /// Skip a scan whose header is valid but whose data cannot be judged:
    /// INFO at its SOS marker, its band becomes unknown, and `pos.*` (past
    /// its header) moves past its entropy data.
    fn skipUnjudged(self: *Skipper, data: []const u8, sos_at: usize, pos: *usize, scan: anytype, sink: ?*FindingsSink, detail: []const u8) !void {
        if (sink) |s| try s.emitExact(.info, .unknown_marker, sos_at, detail);
        self.unknown.mark(scan.comp_indices[0..scan.num_components], scan.ss, scan.se);
        pos.* = entropyEnd(data, pos.*);
    }
};

/// True when every Huffman table the scan decodes with is defined: Td for a
/// DC first scan, Ta for an AC scan, none for a DC refinement. The header
/// parse has already bounded the selectors it uses to 0..3.
pub fn tablesDefined(scan: anytype, frame: anytype, dc_tables: anytype, ac_tables: anytype) bool {
    if (scan.ss == 0 and scan.ah != 0) return true;
    for (scan.comp_indices[0..scan.num_components]) |ci| {
        const c = frame.components[ci];
        const defined = if (scan.ss == 0) dc_tables[c.dc_table] != null else ac_tables[c.ac_table] != null;
        if (!defined) return false;
    }
    return true;
}

/// End of the SOS segment whose length field is at `pos`, as the marker
/// walk skips it: by its declared length, clamped to the data.
fn headerEnd(data: []const u8, pos: usize) usize {
    if (pos + 2 > data.len) return data.len;
    const seg_len = (@as(usize, data[pos]) << 8) | data[pos + 1];
    return @min(data.len, pos + @max(seg_len, 2));
}

/// Which coefficients (per frame component, zig-zag index) no decoded scan
/// can vouch for, because a scan that sets them was skipped.
pub const Unknown = struct {
    coef: [4][64]bool = .{.{false} ** 64} ** 4,

    /// A skipped scan whose header could not be located: nothing after it
    /// can be trusted to refine anything.
    pub fn markAll(self: *Unknown) void {
        for (&self.coef) |*c| @memset(c, true);
    }

    /// Mark coefficients ss..se of each listed frame component unknown.
    pub fn mark(self: *Unknown, comps: []const usize, ss: u8, se: u8) void {
        for (comps) |ci| {
            if (ci >= self.coef.len) continue;
            var k: usize = ss;
            while (k <= se and k < 64) : (k += 1) self.coef[ci][k] = true;
        }
    }

    /// True when an AC refinement scan over ss..se refines a coefficient
    /// that a skipped scan sets.
    pub fn refinesUnknown(self: *const Unknown, comps: []const usize, ss: u8, se: u8, ah: u8) bool {
        if (ss == 0 or ah == 0) return false;
        for (comps) |ci| {
            if (ci >= self.coef.len) return true;
            var k: usize = ss;
            while (k <= se and k < 64) : (k += 1) if (self.coef[ci][k]) return true;
        }
        return false;
    }
};

/// A skipped scan's frame components and spectral band.
pub const Band = struct { comps: [4]usize = .{ 0, 0, 0, 0 }, n: usize = 0, ss: u8 = 0, se: u8 = 0 };

/// Locate the components and band of the scan whose SOS length field is at
/// `pos`, without judging the rest of its header (selectors, Ah, Al,
/// history). Null when they cannot be located: Ns outside 1..4, a length
/// other than 6 + 2*Ns, a selector naming no frame component, or a band
/// outside 0..63. A wrong length leaves the segment's extent unknown: a
/// length past the real header makes the marker walk, and this decode,
/// resume inside or beyond the next scan, which is then never seen, so
/// nothing after it can be trusted to refine anything.
pub fn bandOf(data: []const u8, pos: usize, frame: anytype) ?Band {
    if (pos + 3 > data.len) return null;
    const seg_len = (@as(usize, data[pos]) << 8) | data[pos + 1];
    const ns: usize = data[pos + 2];
    if (ns == 0 or ns > 4 or 6 + 2 * ns != seg_len or pos + seg_len > data.len) return null;
    var band = Band{ .n = ns };
    for (0..ns) |i| {
        const cs = data[pos + 3 + 2 * i];
        band.comps[i] = for (frame.components[0..frame.num_components], 0..) |c, j| {
            if (c.id == cs) break j;
        } else return null;
    }
    band.ss = data[pos + 3 + 2 * ns];
    band.se = data[pos + 4 + 2 * ns];
    if (band.ss > 63 or band.se > 63 or band.ss > band.se) return null;
    return band;
}

/// True when `at` (an SOS marker's file offset) is in `list`.
pub fn listed(list: []const u64, at: usize) bool {
    for (list) |x| if (x == at) return true;
    return false;
}

/// Offset of the marker that ends the entropy data starting at `from`:
/// the first 0xFF followed by neither a stuffed zero, a fill byte nor an
/// RSTm. Returns `data.len` when no marker follows.
pub fn entropyEnd(data: []const u8, from: usize) usize {
    var p = from;
    while (p + 1 < data.len) : (p += 1) {
        if (data[p] != 0xFF) continue;
        const m = data[p + 1];
        if (m == 0x00 or m == 0xFF or (m >= 0xD0 and m <= 0xD7)) continue;
        return p;
    }
    return data.len;
}

test "entropyEnd stops at the first real marker, past stuffing, fill and RSTm" {
    const d = [_]u8{ 0x12, 0xFF, 0x00, 0x34, 0xFF, 0xD3, 0x56, 0xFF, 0xFF, 0xD9 };
    // 0xFF 0xFF is fill: the marker is the second 0xFF, before D9.
    try std.testing.expectEqual(@as(usize, 8), entropyEnd(&d, 0));
    try std.testing.expectEqual(@as(usize, 3), entropyEnd(&[_]u8{ 0x00, 0xFF, 0x00 }, 0));
}

test "bandOf locates components and band, and refuses what it cannot locate" {
    const Comp = struct { id: u8 };
    const Frame = struct { components: [4]Comp, num_components: u8 };
    const frame = Frame{ .components = .{ .{ .id = 1 }, .{ .id = 2 }, .{ .id = 3 }, .{ .id = 0 } }, .num_components = 3 };
    // SOS length field onward: Ls=8, Ns=1, Cs=2 (Td/Ta=0x05, judged
    // elsewhere), Ss=6, Se=63, AhAl.
    const sos = [_]u8{ 0x00, 0x08, 0x01, 0x02, 0x05, 0x06, 0x3f, 0x02 };
    const b = bandOf(&sos, 0, frame).?;
    try std.testing.expectEqual(@as(usize, 1), b.n);
    try std.testing.expectEqual(@as(usize, 1), b.comps[0]);
    try std.testing.expectEqual(@as(u8, 6), b.ss);
    try std.testing.expectEqual(@as(u8, 63), b.se);
    var bad = sos;
    bad[3] = 9; // no such component
    try std.testing.expect(bandOf(&bad, 0, frame) == null);
    bad = sos;
    bad[6] = 70; // Se past 63
    try std.testing.expect(bandOf(&bad, 0, frame) == null);
    bad = sos;
    bad[1] = 0x06; // shorter than Ns implies
    try std.testing.expect(bandOf(&bad, 0, frame) == null);
    const longer = sos ++ [_]u8{ 0, 0 };
    var long = longer;
    long[1] = 0x0A; // longer than Ns implies: the extent is unknown
    try std.testing.expect(bandOf(&long, 0, frame) == null);
}

test "refinesUnknown only for AC refinement over a marked coefficient" {
    var u = Unknown{};
    u.mark(&.{1}, 6, 63);
    try std.testing.expect(u.refinesUnknown(&.{1}, 1, 63, 2));
    try std.testing.expect(!u.refinesUnknown(&.{1}, 1, 5, 2)); // band below the skip
    try std.testing.expect(!u.refinesUnknown(&.{0}, 1, 63, 2)); // other component
    try std.testing.expect(!u.refinesUnknown(&.{1}, 6, 63, 0)); // a first scan
    try std.testing.expect(!u.refinesUnknown(&.{1}, 0, 0, 1)); // DC refinement
}
