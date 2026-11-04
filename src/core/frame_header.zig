//! Codec-owned T.81 frame-header lookup (B.2.2) with no entropy decoding.
//!
//! `frameHeader` walks marker segments from SOI to the first SOFn and
//! reports its raw fields with the marker's byte offset. It does not judge
//! semantic validity (sampling factors outside 1..4, zero height awaiting
//! DNL, quantization selectors): `validate` owns those findings, and a
//! caller comparing geometry sees exactly what the frame declares.
//!
//! JPEG-in-TIFF (TIFF Technical Note 2) keeps the frame header in each
//! strip or tile; a JPEGTables stream holds only tables, so this function
//! reports `error.NoFrameHeader` for it rather than needing it as input.

const std = @import("std");

pub const FrameProcess = enum { sequential, progressive, lossless };
pub const FrameCoding = enum { huffman, arithmetic };

/// Classification of a T.81 SOFn marker (Table B.1).
pub const FrameKind = struct {
	process: FrameProcess,
	coding: FrameCoding,
	/// Differential (hierarchical) frames: SOF5..7 and SOF13..15.
	differential: bool,
	/// Only SOF0 is baseline sequential DCT.
	baseline: bool,

	pub fn isDct(self: FrameKind) bool {
		return self.process != .lossless;
	}
};

/// Classify the n of SOFn (marker 0xC0 + n). Returns null for 4 (DHT),
/// 8 (JPG, reserved) and 12 (DAC), which share the range but are not
/// frame headers. The switch is exhaustive over every u4 value.
pub fn frameKind(sof_type: u4) ?FrameKind {
	return switch (sof_type) {
		0 => kind(.sequential, .huffman, false, true),
		1 => kind(.sequential, .huffman, false, false),
		2 => kind(.progressive, .huffman, false, false),
		3 => kind(.lossless, .huffman, false, false),
		5 => kind(.sequential, .huffman, true, false),
		6 => kind(.progressive, .huffman, true, false),
		7 => kind(.lossless, .huffman, true, false),
		9 => kind(.sequential, .arithmetic, false, false),
		10 => kind(.progressive, .arithmetic, false, false),
		11 => kind(.lossless, .arithmetic, false, false),
		13 => kind(.sequential, .arithmetic, true, false),
		14 => kind(.progressive, .arithmetic, true, false),
		15 => kind(.lossless, .arithmetic, true, false),
		4, 8, 12 => null,
	};
}

fn kind(process: FrameProcess, coding: FrameCoding, differential: bool, baseline: bool) FrameKind {
	return .{ .process = process, .coding = coding, .differential = differential, .baseline = baseline };
}

pub const FrameComponent = struct {
	/// Component identifier Ci.
	id: u8,
	/// Horizontal and vertical sampling factors Hi and Vi, as stored.
	h: u4,
	v: u4,
	/// Quantization table selector Tqi, as stored.
	tq: u8,
};

pub const FrameHeader = struct {
	/// Byte offset of the 0xFF that begins the SOFn marker (after any fill bytes).
	sof_offset: usize,
	/// The n of SOFn.
	sof_type: u4,
	kind: FrameKind,
	precision: u8,
	/// Y as stored; 0 means the height is defined later by DNL.
	height: u16,
	width: u16,
	component_count: u8,
	component_storage: [255]FrameComponent,

	pub fn components(self: *const FrameHeader) []const FrameComponent {
		return self.component_storage[0..self.component_count];
	}
};

pub const FrameHeaderError = error{
	/// The input does not begin with SOI (0xFF 0xD8).
	MissingSoi,
	/// SOS or EOI arrived before any SOFn, as in a tables-only stream.
	NoFrameHeader,
	/// The input ends before a SOFn, SOS or EOI, or inside a marker or segment.
	Truncated,
	/// A byte that is not a marker where one is required, a stuffed 0xFF00,
	/// RSTn or a second SOI before the frame, or a segment length below 2.
	InvalidMarkerStream,
	/// Lf disagrees with Nf (Lf must equal 8 + 3 * Nf), or Nf is 0.
	InvalidFrameHeader,
	/// A JPEG-LS SOF55 (T.87) frame, which is not a T.81 SOFn.
	UnsupportedFrameType,
};

/// Find and parse the first frame header. See the module comment for scope.
pub fn frameHeader(data: []const u8) FrameHeaderError!FrameHeader {
	if (data.len < 2) {
		if (data.len == 1 and data[0] != 0xFF) return error.MissingSoi;
		return error.Truncated;
	}
	if (data[0] != 0xFF or data[1] != 0xD8) return error.MissingSoi;
	var pos: usize = 2;
	while (true) {
		if (pos >= data.len) return error.Truncated;
		if (data[pos] != 0xFF) return error.InvalidMarkerStream;
		// T.81 B.1.1.2: any marker may be preceded by 0xFF fill bytes.
		while (pos + 1 < data.len and data[pos + 1] == 0xFF) pos += 1;
		if (pos + 1 >= data.len) return error.Truncated;
		const marker_offset = pos;
		const code = data[pos + 1];
		pos += 2;
		switch (code) {
			0x01 => continue, // TEM is standalone.
			0x00, 0xD0...0xD8 => return error.InvalidMarkerStream,
			0xD9, 0xDA => return error.NoFrameHeader,
			0xF7 => return error.UnsupportedFrameType,
			0xC0...0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF => {
				return parseFrame(data, marker_offset, @intCast(code - 0xC0));
			},
			else => {
				if (data.len - pos < 2) return error.Truncated;
				const length = readU16(data, pos);
				if (length < 2) return error.InvalidMarkerStream;
				if (data.len - pos < length) return error.Truncated;
				pos += length;
			},
		}
	}
}

fn parseFrame(data: []const u8, marker_offset: usize, sof_type: u4) FrameHeaderError!FrameHeader {
	const pos = marker_offset + 2;
	if (data.len - pos < 2) return error.Truncated;
	const length = readU16(data, pos);
	if (length < 8) return error.InvalidFrameHeader;
	if (data.len - pos < length) return error.Truncated;
	const count = data[pos + 7];
	if (count == 0 or length != 8 + 3 * @as(usize, count)) return error.InvalidFrameHeader;
	var header: FrameHeader = .{
		.sof_offset = marker_offset,
		.sof_type = sof_type,
		.kind = frameKind(sof_type).?,
		.precision = data[pos + 2],
		.height = readU16(data, pos + 3),
		.width = readU16(data, pos + 5),
		.component_count = count,
		.component_storage = undefined,
	};
	for (header.component_storage[0..count], 0..) |*component, index| {
		const at = pos + 8 + index * 3;
		component.* = .{
			.id = data[at],
			.h = @intCast(data[at + 1] >> 4),
			.v = @intCast(data[at + 1] & 0x0F),
			.tq = data[at + 2],
		};
	}
	return header;
}

fn readU16(data: []const u8, at: usize) u16 {
	return (@as(u16, data[at]) << 8) | data[at + 1];
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "frameKind classifies every SOFn value against T.81 Table B.1" {
	const Row = struct { n: u4, expected: ?FrameKind };
	const rows = [_]Row{
		.{ .n = 0, .expected = kind(.sequential, .huffman, false, true) },
		.{ .n = 1, .expected = kind(.sequential, .huffman, false, false) },
		.{ .n = 2, .expected = kind(.progressive, .huffman, false, false) },
		.{ .n = 3, .expected = kind(.lossless, .huffman, false, false) },
		.{ .n = 4, .expected = null },
		.{ .n = 5, .expected = kind(.sequential, .huffman, true, false) },
		.{ .n = 6, .expected = kind(.progressive, .huffman, true, false) },
		.{ .n = 7, .expected = kind(.lossless, .huffman, true, false) },
		.{ .n = 8, .expected = null },
		.{ .n = 9, .expected = kind(.sequential, .arithmetic, false, false) },
		.{ .n = 10, .expected = kind(.progressive, .arithmetic, false, false) },
		.{ .n = 11, .expected = kind(.lossless, .arithmetic, false, false) },
		.{ .n = 12, .expected = null },
		.{ .n = 13, .expected = kind(.sequential, .arithmetic, true, false) },
		.{ .n = 14, .expected = kind(.progressive, .arithmetic, true, false) },
		.{ .n = 15, .expected = kind(.lossless, .arithmetic, true, false) },
	};
	for (rows, 0..) |row, index| {
		try testing.expectEqual(@as(usize, row.n), index);
		try testing.expectEqual(row.expected, frameKind(row.n));
	}
	const dct = [_]u4{ 0, 1, 2, 5, 6, 9, 10, 13, 14 };
	for (dct) |n| try testing.expect(frameKind(n).?.isDct());
	const lossless = [_]u4{ 3, 7, 11, 15 };
	for (lossless) |n| try testing.expect(!frameKind(n).?.isDct());
}

/// SOI, an APP0 stub, optional fill bytes, SOFn, then `tail`.
fn buildStream(buffer: []u8, sof_code: u8, fill: usize, frame: []const u8, tail: []const u8) []const u8 {
	const prefix = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0xAA, 0xBB };
	var len: usize = 0;
	@memcpy(buffer[len..][0..prefix.len], &prefix);
	len += prefix.len;
	@memset(buffer[len..][0..fill], 0xFF);
	len += fill;
	buffer[len] = 0xFF;
	buffer[len + 1] = sof_code;
	len += 2;
	@memcpy(buffer[len..][0..frame.len], frame);
	len += frame.len;
	@memcpy(buffer[len..][0..tail.len], tail);
	len += tail.len;
	return buffer[0..len];
}

const ycbcr_420_frame = [_]u8{
	0x00, 0x11, 0x08, 0x00, 0x10, 0x00, 0x20, 0x03, // Lf=17, P=8, Y=16, X=32, Nf=3
	0x01, 0x22, 0x00,
	0x02, 0x11, 0x01,
	0x03, 0x11, 0x01,
};
const sos_tail = [_]u8{ 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00 };

test "frameHeader reports raw fields and the SOF marker offset" {
	var buffer: [128]u8 = undefined;
	for ([_]usize{ 0, 3 }) |fill| {
		const stream = buildStream(&buffer, 0xC0, fill, &ycbcr_420_frame, &sos_tail);
		const header = try frameHeader(stream);
		try testing.expectEqual(@as(usize, 8 + fill), header.sof_offset);
		try testing.expectEqual(@as(u8, 0xFF), stream[header.sof_offset]);
		try testing.expectEqual(@as(u8, 0xC0), stream[header.sof_offset + 1]);
		try testing.expectEqual(@as(u4, 0), header.sof_type);
		try testing.expect(header.kind.baseline);
		try testing.expectEqual(@as(u8, 8), header.precision);
		try testing.expectEqual(@as(u16, 16), header.height);
		try testing.expectEqual(@as(u16, 32), header.width);
		const expected = [_]FrameComponent{
			.{ .id = 1, .h = 2, .v = 2, .tq = 0 },
			.{ .id = 2, .h = 1, .v = 1, .tq = 1 },
			.{ .id = 3, .h = 1, .v = 1, .tq = 1 },
		};
		try testing.expectEqualSlices(FrameComponent, &expected, header.components());
	}
}

test "frameHeader classifies every SOFn marker code it accepts" {
	var buffer: [128]u8 = undefined;
	var code: u8 = 0xC0;
	while (code <= 0xCF) : (code += 1) {
		const stream = buildStream(&buffer, code, 0, &ycbcr_420_frame, &sos_tail);
		const n: u4 = @intCast(code - 0xC0);
		if (frameKind(n)) |expected| {
			const header = try frameHeader(stream);
			try testing.expectEqual(n, header.sof_type);
			try testing.expectEqual(expected, header.kind);
		} else {
			// DHT, JPG and DAC are ordinary segments: the walk continues to SOS.
			try testing.expectError(error.NoFrameHeader, frameHeader(stream));
		}
	}
}

test "frameHeader keeps values that validation, not lookup, judges" {
	var buffer: [128]u8 = undefined;
	// Nf=5, Y=0 (DNL), Hi/Vi of 0 and 15, Tq of 9: reported as stored.
	const frame = [_]u8{
		0x00, 0x17, 0x0C, 0x00, 0x00, 0x00, 0x05, 0x05,
		0x01, 0x0F, 0x09, 0x02, 0xF0, 0x00, 0x03, 0x11, 0x00,
		0x04, 0x11, 0x00, 0x05, 0x11, 0x00,
	};
	const header = try frameHeader(buildStream(&buffer, 0xC1, 0, &frame, &sos_tail));
	try testing.expectEqual(@as(u16, 0), header.height);
	try testing.expectEqual(@as(u8, 5), header.component_count);
	try testing.expectEqual(FrameComponent{ .id = 1, .h = 0, .v = 15, .tq = 9 }, header.components()[0]);
	try testing.expectEqual(FrameComponent{ .id = 2, .h = 15, .v = 0, .tq = 0 }, header.components()[1]);
}

test "frameHeader distinguishes a missing frame from damaged input" {
	var buffer: [128]u8 = undefined;
	// A TIFF JPEGTables-style stream: SOI, DQT, EOI.
	const tables = [_]u8{ 0xFF, 0xD8, 0xFF, 0xDB, 0x00, 0x04, 0x00, 0x01, 0xFF, 0xD9 };
	try testing.expectError(error.NoFrameHeader, frameHeader(&tables));
	try testing.expectError(error.NoFrameHeader, frameHeader(&[_]u8{ 0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x02 }));

	try testing.expectError(error.MissingSoi, frameHeader(&[_]u8{ 0x89, 0x50, 0x4E, 0x47 }));
	try testing.expectError(error.MissingSoi, frameHeader(&[_]u8{0x00}));
	try testing.expectError(error.Truncated, frameHeader(&[_]u8{}));
	try testing.expectError(error.Truncated, frameHeader(&[_]u8{0xFF}));
	try testing.expectError(error.Truncated, frameHeader(&[_]u8{ 0xFF, 0xD8 }));
	try testing.expectError(error.Truncated, frameHeader(&[_]u8{ 0xFF, 0xD8, 0xFF, 0xFF }));
	try testing.expectError(error.Truncated, frameHeader(&[_]u8{ 0xFF, 0xD8, 0xFF, 0xE0, 0x00 }));
	try testing.expectError(error.Truncated, frameHeader(&[_]u8{ 0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x09, 0x00 }));

	// Every proper prefix of a complete frame header is truncated input.
	const full = buildStream(&buffer, 0xC0, 0, &ycbcr_420_frame, &.{});
	for (2..full.len) |cut| try testing.expectError(error.Truncated, frameHeader(full[0..cut]));
	_ = try frameHeader(full);

	try testing.expectError(error.InvalidMarkerStream, frameHeader(&[_]u8{ 0xFF, 0xD8, 0x00, 0xFF, 0xD9 }));
	try testing.expectError(error.InvalidMarkerStream, frameHeader(&[_]u8{ 0xFF, 0xD8, 0xFF, 0x00 }));
	try testing.expectError(error.InvalidMarkerStream, frameHeader(&[_]u8{ 0xFF, 0xD8, 0xFF, 0xD0 }));
	try testing.expectError(error.InvalidMarkerStream, frameHeader(&[_]u8{ 0xFF, 0xD8, 0xFF, 0xD8 }));
	try testing.expectError(error.InvalidMarkerStream, frameHeader(&[_]u8{ 0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x01 }));
	try testing.expectError(error.UnsupportedFrameType, frameHeader(&[_]u8{ 0xFF, 0xD8, 0xFF, 0xF7, 0x00, 0x0B }));

	// TEM is standalone and skipped.
	var tem: [128]u8 = undefined;
	const with_tem = buildStream(&tem, 0xC0, 0, &ycbcr_420_frame, &sos_tail);
	var shifted: [130]u8 = undefined;
	@memcpy(shifted[0..2], with_tem[0..2]);
	shifted[2] = 0xFF;
	shifted[3] = 0x01;
	@memcpy(shifted[4 .. with_tem.len + 2], with_tem[2..]);
	try testing.expectEqual(@as(usize, 10), (try frameHeader(shifted[0 .. with_tem.len + 2])).sof_offset);
}

test "frameHeader rejects a frame length that disagrees with its component count" {
	var buffer: [128]u8 = undefined;
	var frame = ycbcr_420_frame;
	frame[1] = 0x14; // Lf=20 with Nf=3 (needs 17); the bytes are present.
	var padded: [20]u8 = undefined;
	@memcpy(padded[0..17], &frame);
	@memset(padded[17..], 0);
	try testing.expectError(error.InvalidFrameHeader, frameHeader(buildStream(&buffer, 0xC0, 0, &padded, &sos_tail)));
	frame = ycbcr_420_frame;
	frame[7] = 0; // Nf=0
	try testing.expectError(error.InvalidFrameHeader, frameHeader(buildStream(&buffer, 0xC0, 0, &frame, &sos_tail)));
	try testing.expectError(error.InvalidFrameHeader, frameHeader(buildStream(&buffer, 0xC0, 0, &[_]u8{ 0x00, 0x07, 0, 0, 0, 0, 0 }, &sos_tail)));
}
