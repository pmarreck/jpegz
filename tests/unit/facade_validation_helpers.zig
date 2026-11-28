//! Helpers shared by the facade_validation test files (part 1 of 1).

const std = @import("std");
const jpegz = @import("jpegz");

pub const sof3_pair = [_]u8{ 0xff, 0xd8, 0xff, 0xc3, 0, 14, 12, 0, 1, 0, 1, 2, 1, 0x11, 0, 2, 0x11, 0 } ++
	[_]u8{ 0xff, 0xc4, 0, 20, 0, 1 } ++ ([_]u8{0} ** 15) ++ [_]u8{0} ++
	[_]u8{ 0xff, 0xda, 0, 10, 2, 1, 0, 2, 0, 1, 0, 0, 0x3f, 0xff, 0xd9 };

test "SOF3 header constraints preserve lossless precision and bound parser indices" {
	const allocator = std.testing.allocator;
	const cases = [_]struct { offset: usize, value: u8, verdict: jpegz.StrictVerdict }{
		.{ .offset = 6, .value = 2, .verdict = .valid },
		.{ .offset = 6, .value = 14, .verdict = .valid },
		.{ .offset = 6, .value = 16, .verdict = .valid },
		.{ .offset = 6, .value = 1, .verdict = .corrupt },
		.{ .offset = 13, .value = 0, .verdict = .corrupt },
		.{ .offset = 13, .value = 0x51, .verdict = .corrupt },
		.{ .offset = 15, .value = 1, .verdict = .corrupt },
		.{ .offset = 23, .value = 3, .verdict = .corrupt },
		.{ .offset = 39, .value = 17, .verdict = .corrupt },
		.{ .offset = 44, .value = 4, .verdict = .corrupt },
		.{ .offset = 46, .value = 0x40, .verdict = .corrupt },
		.{ .offset = 46, .value = 1, .verdict = .corrupt },
		.{ .offset = 47, .value = 1, .verdict = .corrupt },
		.{ .offset = 50, .value = 1, .verdict = .corrupt },
		.{ .offset = 51, .value = 0x10, .verdict = .corrupt },
	};
	for (cases) |case| {
		var bytes = sof3_pair;
		bytes[case.offset] = case.value;
		var result = try jpegz.validateAny(allocator, &bytes);
		defer result.deinit(allocator);
		try std.testing.expectEqual(case.verdict, result.verdict);
	}
}

/// A minimal legal hierarchical stream (T.81 Annex J): DHP, a lossless SOF3
/// frame, then a differential lossless SOF7 frame at the same 1x1 size, whose
/// scan uses selection value 0 ("no prediction", Table H.1, hierarchical
/// differential coding only). Each scan codes one zero difference: Huffman
/// code '0' (SSSS = 0) then 1-bit padding. `dhp` false omits the DHP and
/// `dhp_late` moves it after the first frame.
pub fn hierarchicalStream(comptime dhp: bool, comptime dhp_late: bool) []const u8 {
	const dht = [_]u8{ 0xff, 0xc4, 0, 20, 0x00, 1 } ++ ([_]u8{0} ** 15) ++ [_]u8{0};
	const dhp_segment = [_]u8{ 0xff, 0xde, 0, 11, 8, 0, 1, 0, 1, 1, 1, 0x11, 0 };
	const frame = [_]u8{ 0, 11, 8, 0, 1, 0, 1, 1, 1, 0x11, 0 };
	const first = [_]u8{ 0xff, 0xc3 } ++ frame ++ [_]u8{ 0xff, 0xda, 0, 8, 1, 1, 0, 1, 0, 0, 0x7f };
	const differential = [_]u8{ 0xff, 0xc7 } ++ frame ++ [_]u8{ 0xff, 0xda, 0, 8, 1, 1, 0, 0, 0, 0, 0x7f };
	const early: []const u8 = if (dhp and !dhp_late) &dhp_segment else &.{};
	const late: []const u8 = if (dhp and dhp_late) &dhp_segment else &.{};
	return [_]u8{ 0xff, 0xd8 } ++ dht ++ early ++ first ++ late ++ differential ++ [_]u8{ 0xff, 0xd9 };
}

