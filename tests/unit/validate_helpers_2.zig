//! Helpers shared by the validate test files (part 2 of 2).

const std = @import("std");
const jpegz = @import("jpegz");
const h1 = @import("validate_helpers_1.zig");
const fixture_baseline_2x2_rgb = h1.fixture_baseline_2x2_rgb;
const fixture_progressive_8x8 = h1.fixture_progressive_8x8;
const fixture_lossless_4x4_gray8 = h1.fixture_lossless_4x4_gray8;
const fixture_arith_8x8_gray = h1.fixture_arith_8x8_gray;
const expectOnlyTypedFail = h1.expectOnlyTypedFail;
const expectExactTypedFailures = h1.expectExactTypedFailures;
const expectMixedPadFailures = h1.expectMixedPadFailures;
const expectOnlyTyped = h1.expectOnlyTyped;
const expectZeroPadWarnings = h1.expectZeroPadWarnings;
const fixture_baseline_4x4_bogus_dht = h1.fixture_baseline_4x4_bogus_dht;
const fixture_baseline_4x4_with_exif = h1.fixture_baseline_4x4_with_exif;
const fixture_baseline_4x4_with_trailing = h1.fixture_baseline_4x4_with_trailing;
const findMarker = h1.findMarker;
const reportHasCode = h1.reportHasCode;
const countCode = h1.countCode;
const expectDhtSymbolPastBound = h1.expectDhtSymbolPastBound;
const expectOneExact = h1.expectOneExact;
const decodeFindings = h1.decodeFindings;
const segmentEndMarker = h1.segmentEndMarker;
const entropyStart = h1.entropyStart;
const losslessHead = h1.losslessHead;
const patchU16BE = h1.patchU16BE;
const findSof0Body = h1.findSof0Body;
const fixture_jp2_rgb = h1.fixture_jp2_rgb;
const fixture_jp2_lossless = h1.fixture_jp2_lossless;
const fixture_jp2_lossy97 = h1.fixture_jp2_lossy97;
const fixture_jp2_subsampled = h1.fixture_jp2_subsampled;
const fixture_jp2_yuv420 = h1.fixture_jp2_yuv420;
const fixture_jp2_yuv420_matching_depth = h1.fixture_jp2_yuv420_matching_depth;
const jp2_specificity_corpus = h1.jp2_specificity_corpus;
const findSoc = h1.findSoc;
const fixture_seq_16x16_3scan = h1.fixture_seq_16x16_3scan;
const fixture_seq_17x13_420_y_cbcr_rst = h1.fixture_seq_17x13_420_y_cbcr_rst;
const fixture_seq_23x19_422_rev_rst = h1.fixture_seq_23x19_422_rev_rst;
const fixture_seq_23x19_rgb12_420_3scan = h1.fixture_seq_23x19_rgb12_420_3scan;
const sof1TableFixture = h1.sof1TableFixture;
const losslessWithTable = h1.losslessWithTable;
const withoutDht = h1.withoutDht;

/// A Multi-Picture Format file (CIPA DC-007): `primary` with an MPF APP2
/// after SOI whose Index IFD lists `second`, appended after the primary's EOI.
/// `size_delta` and `offset_delta` skew the second entry for near misses.
pub fn mpfFile(allocator: std.mem.Allocator, primary: []const u8, second: []const u8, size_delta: i32, offset_delta: i32, tail: []const u8) ![]u8 {
	const app2_len: usize = 2 + 4 + 8 + 42 + 32; // length field onward
	const base: usize = 2 + 2 + 2 + 4; // SOI, marker, length, "MPF\0"
	const second_at = 2 + 2 + app2_len + (primary.len - 2);
	var app2: [2 + app2_len]u8 = undefined;
	var w: usize = 0;
	const put = struct {
		fn b(buf: []u8, at: *usize, bytes: []const u8) void {
			@memcpy(buf[at.* .. at.* + bytes.len], bytes);
			at.* += bytes.len;
		}
		fn be32(buf: []u8, at: *usize, v: u32) void {
			std.mem.writeInt(u32, buf[at.*..][0..4], v, .big);
			at.* += 4;
		}
		fn be16(buf: []u8, at: *usize, v: u16) void {
			std.mem.writeInt(u16, buf[at.*..][0..2], v, .big);
			at.* += 2;
		}
	};
	put.b(&app2, &w, &.{ 0xff, 0xe2 });
	put.be16(&app2, &w, @intCast(app2_len));
	put.b(&app2, &w, "MPF\x00");
	put.b(&app2, &w, &.{ 'M', 'M', 0, 0x2a, 0, 0, 0, 8 }); // TIFF header, IFD at 8
	put.be16(&app2, &w, 3);
	put.be16(&app2, &w, 0xb000); put.be16(&app2, &w, 7); put.be32(&app2, &w, 4); put.b(&app2, &w, "0100");
	put.be16(&app2, &w, 0xb001); put.be16(&app2, &w, 4); put.be32(&app2, &w, 1); put.be32(&app2, &w, 2);
	put.be16(&app2, &w, 0xb002); put.be16(&app2, &w, 7); put.be32(&app2, &w, 32); put.be32(&app2, &w, 50);
	put.be32(&app2, &w, 0); // no next IFD
	// MP entries: the primary (offset 0), then the second image.
	put.be32(&app2, &w, 0x20030000); put.be32(&app2, &w, @intCast(second_at)); put.be32(&app2, &w, 0); put.be32(&app2, &w, 0);
	put.be32(&app2, &w, 0);
	put.be32(&app2, &w, @intCast(@as(i64, @intCast(second.len)) + size_delta));
	put.be32(&app2, &w, @intCast(@as(i64, @intCast(second_at - base)) + offset_delta));
	put.be32(&app2, &w, 0);
	std.debug.assert(w == app2.len);
	return std.mem.concat(allocator, u8, &.{ primary[0..2], &app2, primary[2..], second, tail });
}

pub const TrailingSeen = struct { severity: jpegz.Severity, offset: ?u64, detail: []const u8 };

pub fn trailingFindings(report: jpegz.ValidationReport, out: *[4]TrailingSeen) usize {
	var n: usize = 0;
	for (report.findings.items) |f| {
		if (f.code != .trailing_data_after_eoi) continue;
		if (n < out.len) out[n] = .{ .severity = f.severity, .offset = f.offset, .detail = f.detail orelse "" };
		n += 1;
	}
	return n;
}

/// T.81 B.2.2/B.2.5 rewrite of a valid single-frame fixture: zero the SOF's Y
/// and put a DNL segment right after the first scan. `lines` null keeps the
/// original height; `dnl` false leaves the DNL out. The fixtures chain their
/// segments without fill bytes.
pub const DnlRewrite = struct { dnl: bool = true, lines: ?u16 = null };

pub fn dnlVariant(allocator: std.mem.Allocator, data: []const u8, rewrite: DnlRewrite) ![]u8 {
	var pos: usize = 2;
	var sof_y: ?usize = null;
	while (true) {
		const marker = data[pos + 1];
		const len = (@as(usize, data[pos + 2]) << 8) | data[pos + 3];
		const sof = marker >= 0xc0 and marker <= 0xcf and marker != 0xc4 and marker != 0xc8 and marker != 0xcc;
		if (sof) sof_y = pos + 5;
		pos += 2 + len;
		if (marker == 0xda) break;
	}
	// The first marker after the entropy data that is not a stuffed FF or RSTn.
	while (!(data[pos] == 0xff and data[pos + 1] != 0 and !(data[pos + 1] >= 0xd0 and data[pos + 1] <= 0xd7))) pos += 1;
	const y = sof_y.?;
	const height = (@as(u16, data[y]) << 8) | data[y + 1];
	const lines = rewrite.lines orelse height;
	const dnl = [_]u8{ 0xff, 0xdc, 0, 4, @intCast(lines >> 8), @truncate(lines) };
	return std.mem.concat(allocator, u8, &.{ data[0..y], &.{ 0, 0 }, data[y + 2 .. pos], if (rewrite.dnl) &dnl else &.{}, data[pos..] });
}

pub const dnl_fixtures = [_]struct { name: []const u8, data: []const u8 }{
	.{ .name = "baseline 4:2:0", .data = @embedFile("fixtures/baseline_16x16_rgb_420.jpg") },
	.{ .name = "baseline with restarts", .data = @embedFile("fixtures/baseline_128x128_dri4.jpg") },
	.{ .name = "extended 12-bit", .data = @embedFile("fixtures/baseline_4x4_gray12_dct.jpg") },
	.{ .name = "progressive", .data = fixture_progressive_8x8 },
	.{ .name = "arithmetic baseline", .data = @embedFile("fixtures/arith_baseline_16x16_rgb_444.jpg") },
};

/// Offset of the first marker after the `n`th scan's entropy data (1-based)
/// in a fixture whose segments chain without fill bytes.
pub fn scanEnd(data: []const u8, n: usize) usize {
	var pos: usize = 2;
	var scans: usize = 0;
	while (true) {
		const marker = data[pos + 1];
		const len = (@as(usize, data[pos + 2]) << 8) | data[pos + 3];
		pos += 2 + len;
		if (marker != 0xda) continue;
		scans += 1;
		while (!(data[pos] == 0xff and data[pos + 1] != 0 and !(data[pos + 1] >= 0xd0 and data[pos + 1] <= 0xd7))) pos += 1;
		if (scans == n) return pos;
	}
}

/// Offset of the first SOS marker.
pub fn firstSos(data: []const u8) usize {
	var pos: usize = 2;
	while (data[pos + 1] != 0xda) pos += 2 + ((@as(usize, data[pos + 2]) << 8) | data[pos + 3]);
	return pos;
}

pub const DnlPlacement = struct { at: usize, lines: u16 };

/// Insert DNL segments at the given offsets of `data` (ascending), optionally
/// after zeroing the SOF's Y with `dnlVariant`'s rule.
pub fn withDnls(allocator: std.mem.Allocator, data: []const u8, placements: []const DnlPlacement) ![]u8 {
	var out: std.ArrayList(u8) = .empty;
	errdefer out.deinit(allocator);
	var from: usize = 0;
	for (placements) |p| {
		try out.appendSlice(allocator, data[from..p.at]);
		try out.appendSlice(allocator, &.{ 0xff, 0xdc, 0, 4, @intCast(p.lines >> 8), @truncate(p.lines) });
		from = p.at;
	}
	try out.appendSlice(allocator, data[from..]);
	return out.toOwnedSlice(allocator);
}

pub fn sofHeightOffset(data: []const u8) usize {
	var pos: usize = 2;
	while (true) {
		const marker = data[pos + 1];
		if (marker >= 0xc0 and marker <= 0xcf and marker != 0xc4 and marker != 0xc8 and marker != 0xcc) return pos + 5;
		pos += 2 + ((@as(usize, data[pos + 2]) << 8) | data[pos + 3]);
	}
}

