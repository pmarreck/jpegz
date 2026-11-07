//! Provenance for every `FindingCode`: which project owns its meaning, on
//! what basis its number was assigned, and the jpegz commit that added it.
//!
//! `docs/FINDING_CODES.md` is generated from this table by
//! `tools/gen_finding_codes.zig`; `zig build test` fails when the committed
//! file differs, and `zig build finding-codes` rewrites it. The numbers and
//! names themselves live only in `errors.zig`. This file never repeats them,
//! and `std.EnumArray.init` makes a missing or extra code a compile error.
//!
//! The registry is append-only. Since 2026-11-06 validate owns it (owner
//! ruling); before that the coordinator did. A new code needs approval before
//! it is used, and its row cites that date.

const std = @import("std");
pub const errors = @import("errors.zig");
pub const FindingCode = errors.FindingCode;

/// The project whose validator emits the condition and owns its meaning.
pub const Owner = enum { jpegz, jp2z, libjxlz };

pub const Basis = union(enum) {
	/// Assigned by jpegz before the shared registry existed (before 2026-08-01).
	pre_registry,
	/// Approved by the coordinator on this date (YYYY-MM-DD).
	coordinator: []const u8,
	/// Approved by validate, the registry owner since 2026-11-06, on this date.
	validate: []const u8,
	/// Inside the JPEG XL band 180..199 the coordinator reserved on 2026-08-05.
	jxl_band,
	/// Assigned in jp2z's leaf registry and mirrored here by number.
	leaf_registry,
	/// No approval record was found.
	no_record,
};

pub const Entry = struct {
	owner: Owner,
	basis: Basis,
	/// Short hash of the jpegz commit that added the value. Null only in
	/// the commit that adds a code, whose hash cannot be known yet; the next
	/// commit fills it in.
	commit: ?[]const u8,
	/// That commit's date, YYYY-MM-DD.
	date: []const u8,
};

pub const table = std.EnumArray(FindingCode, Entry).init(.{
	.missing_soi = .{ .owner = .jpegz, .basis = .pre_registry, .commit = "6629e2b", .date = "2026-05-04" },
	.missing_eoi = .{ .owner = .jpegz, .basis = .pre_registry, .commit = "6629e2b", .date = "2026-05-04" },
	.truncated_stream = .{ .owner = .jpegz, .basis = .pre_registry, .commit = "6629e2b", .date = "2026-05-04" },
	.bad_marker_length = .{ .owner = .jpegz, .basis = .pre_registry, .commit = "6629e2b", .date = "2026-05-04" },
	.unknown_marker = .{ .owner = .jpegz, .basis = .pre_registry, .commit = "6629e2b", .date = "2026-05-04" },
	.duplicate_sof = .{ .owner = .jpegz, .basis = .pre_registry, .commit = "6629e2b", .date = "2026-05-04" },
	.insufficient_data = .{ .owner = .jpegz, .basis = .pre_registry, .commit = "3c19849", .date = "2026-05-15" },
	.extraneous_bytes_before_marker = .{ .owner = .jpegz, .basis = .pre_registry, .commit = "3c19849", .date = "2026-05-15" },
	.entropy_fill_bytes = .{ .owner = .jpegz, .basis = .pre_registry, .commit = "d44b558", .date = "2026-05-22" },
	.unrecognized_container = .{ .owner = .jpegz, .basis = .no_record, .commit = "a94b102", .date = "2026-08-10" },
	.invalid_sof_precision = .{ .owner = .jpegz, .basis = .pre_registry, .commit = "6629e2b", .date = "2026-05-04" },
	.huffman_table_corrupt = .{ .owner = .jpegz, .basis = .pre_registry, .commit = "6629e2b", .date = "2026-05-04" },
	.quantization_table_corrupt = .{ .owner = .jpegz, .basis = .pre_registry, .commit = "6629e2b", .date = "2026-05-04" },
	.arithmetic_table_corrupt = .{ .owner = .jpegz, .basis = .pre_registry, .commit = "6629e2b", .date = "2026-05-04" },
	.sof_component_count_invalid = .{ .owner = .jpegz, .basis = .pre_registry, .commit = "6629e2b", .date = "2026-05-04" },
	.sos_component_mismatch = .{ .owner = .jpegz, .basis = .pre_registry, .commit = "6629e2b", .date = "2026-05-04" },
	.restart_marker_missing = .{ .owner = .jpegz, .basis = .pre_registry, .commit = "6629e2b", .date = "2026-05-04" },
	.restart_marker_unexpected = .{ .owner = .jpegz, .basis = .pre_registry, .commit = "6629e2b", .date = "2026-05-04" },
	.dct_coefficient_overflow = .{ .owner = .jpegz, .basis = .pre_registry, .commit = "6629e2b", .date = "2026-05-04" },
	.progressive_scan_invalid = .{ .owner = .jpegz, .basis = .pre_registry, .commit = "6629e2b", .date = "2026-05-04" },
	.adobe_app14_conflicts_jfif = .{ .owner = .jpegz, .basis = .pre_registry, .commit = "d44b558", .date = "2026-05-22" },
	.invalid_dimensions = .{ .owner = .jpegz, .basis = .pre_registry, .commit = "9c8fd4b", .date = "2026-07-24" },
	.entropy_padding_not_ones = .{ .owner = .jpegz, .basis = .{ .coordinator = "2026-10-20" }, .commit = "860654d", .date = "2026-10-20" },
	.entropy_padding_zero_bits = .{ .owner = .jpegz, .basis = .{ .coordinator = "2026-10-23" }, .commit = "8fd246d", .date = "2026-10-23" },
	.sequential_scan_invalid = .{ .owner = .jpegz, .basis = .{ .coordinator = "2026-10-28" }, .commit = "d7f627a", .date = "2026-10-28" },
	.jfif_metadata_invalid = .{ .owner = .jpegz, .basis = .{ .coordinator = "2026-10-28" }, .commit = "6b038ec", .date = "2026-10-28" },
	.sof_sampling_invalid = .{ .owner = .jpegz, .basis = .{ .coordinator = "2026-10-28" }, .commit = "faf0c92", .date = "2026-10-28" },
	.jfif_version_unchecked = .{ .owner = .jpegz, .basis = .{ .coordinator = "2026-10-28" }, .commit = "a7ddd65", .date = "2026-10-29" },
	.sof_component_id_duplicate = .{ .owner = .jpegz, .basis = .{ .validate = "2026-11-06" }, .commit = null, .date = "2026-11-06" },
	.huffman_table_full_all_ones = .{ .owner = .jpegz, .basis = .{ .validate = "2026-11-06" }, .commit = "fc1625c", .date = "2026-11-06" },
	.lossless_predictor_invalid = .{ .owner = .jpegz, .basis = .pre_registry, .commit = "6629e2b", .date = "2026-05-04" },
	.lossless_pointtransform_invalid = .{ .owner = .jpegz, .basis = .pre_registry, .commit = "6629e2b", .date = "2026-05-04" },
	.jpegls_invalid_run_mode = .{ .owner = .jpegz, .basis = .pre_registry, .commit = "6629e2b", .date = "2026-05-04" },
	.jpegls_context_table_invalid = .{ .owner = .jpegz, .basis = .pre_registry, .commit = "6629e2b", .date = "2026-05-04" },
	.jp2_invalid_signature = .{ .owner = .jp2z, .basis = .pre_registry, .commit = "6629e2b", .date = "2026-05-04" },
	.jp2_invalid_codestream = .{ .owner = .jp2z, .basis = .pre_registry, .commit = "6629e2b", .date = "2026-05-04" },
	.jp2_bad_progression_order = .{ .owner = .jp2z, .basis = .pre_registry, .commit = "6629e2b", .date = "2026-05-04" },
	.jp2_tile_decode_failed = .{ .owner = .jp2z, .basis = .pre_registry, .commit = "6629e2b", .date = "2026-05-04" },
	.jp2_codeblock_decode_failed = .{ .owner = .jp2z, .basis = .pre_registry, .commit = "6629e2b", .date = "2026-05-04" },
	.jp2_unsupported_marker_ignored = .{ .owner = .jp2z, .basis = .leaf_registry, .commit = "84c3c6f", .date = "2026-08-02" },
	.jp2_invalid_siz = .{ .owner = .jp2z, .basis = .leaf_registry, .commit = "84c3c6f", .date = "2026-08-02" },
	.jxl_invalid_signature = .{ .owner = .libjxlz, .basis = .jxl_band, .commit = "fb72045", .date = "2026-08-05" },
	.jxl_truncated = .{ .owner = .libjxlz, .basis = .jxl_band, .commit = "fb72045", .date = "2026-08-05" },
	.jxl_malformed = .{ .owner = .libjxlz, .basis = .jxl_band, .commit = "fb72045", .date = "2026-08-05" },
	.jxl_unsupported_feature = .{ .owner = .libjxlz, .basis = .jxl_band, .commit = "fb72045", .date = "2026-08-05" },
	.jxl_resource_limit = .{ .owner = .libjxlz, .basis = .jxl_band, .commit = "fb72045", .date = "2026-08-05" },
	.jxl_out_of_memory = .{ .owner = .libjxlz, .basis = .jxl_band, .commit = "fb72045", .date = "2026-08-05" },
	.jxl_invalid_argument = .{ .owner = .libjxlz, .basis = .jxl_band, .commit = "fb72045", .date = "2026-08-05" },
	.jxl_unclassified_decoder_error = .{ .owner = .libjxlz, .basis = .jxl_band, .commit = "fb72045", .date = "2026-08-05" },
	.jxl_validator_unavailable = .{ .owner = .jpegz, .basis = .jxl_band, .commit = "98824e7", .date = "2026-08-10" },
	.jxl_nonzero_padding = .{ .owner = .libjxlz, .basis = .jxl_band, .commit = "491bebc", .date = "2026-09-17" },
	.jxl_invalid_context_map = .{ .owner = .libjxlz, .basis = .jxl_band, .commit = "491bebc", .date = "2026-09-17" },
	.jxl_invalid_ma_tree = .{ .owner = .libjxlz, .basis = .jxl_band, .commit = "491bebc", .date = "2026-09-17" },
	.jxl_invalid_ans_state = .{ .owner = .libjxlz, .basis = .jxl_band, .commit = "491bebc", .date = "2026-09-17" },
	.jxl_truncated_box_header = .{ .owner = .libjxlz, .basis = .jxl_band, .commit = "491bebc", .date = "2026-09-17" },
	.jxl_invalid_ac_nonzero_count = .{ .owner = .libjxlz, .basis = .jxl_band, .commit = "491bebc", .date = "2026-09-17" },
	.jxl_invalid_hybrid_uint_config = .{ .owner = .libjxlz, .basis = .jxl_band, .commit = "8a92dbd", .date = "2026-09-18" },
	.jxl_invalid_histogram = .{ .owner = .libjxlz, .basis = .jxl_band, .commit = "8a92dbd", .date = "2026-09-18" },
	.jxl_invalid_icc_symbol = .{ .owner = .libjxlz, .basis = .{ .coordinator = "2026-10-29" }, .commit = "e8ef262", .date = "2026-10-29" },
	.arithmetic_coding_used = .{ .owner = .jpegz, .basis = .pre_registry, .commit = "6629e2b", .date = "2026-05-04" },
	.twelve_bit_precision = .{ .owner = .jpegz, .basis = .pre_registry, .commit = "6629e2b", .date = "2026-05-04" },
	.sixteen_bit_lossless = .{ .owner = .jpegz, .basis = .pre_registry, .commit = "6629e2b", .date = "2026-05-04" },
	.progressive_scan_count = .{ .owner = .jpegz, .basis = .pre_registry, .commit = "6629e2b", .date = "2026-05-04" },
	.embedded_thumbnail_present = .{ .owner = .jpegz, .basis = .pre_registry, .commit = "6629e2b", .date = "2026-05-04" },
	.exif_metadata_present = .{ .owner = .jpegz, .basis = .pre_registry, .commit = "6629e2b", .date = "2026-05-04" },
	.icc_profile_present = .{ .owner = .jpegz, .basis = .pre_registry, .commit = "6629e2b", .date = "2026-05-04" },
	.jp2_uses_9x7_wavelet = .{ .owner = .jp2z, .basis = .pre_registry, .commit = "6629e2b", .date = "2026-05-04" },
	.jp2_uses_5x3_wavelet = .{ .owner = .jp2z, .basis = .pre_registry, .commit = "6629e2b", .date = "2026-05-04" },
	.jfif_metadata_present = .{ .owner = .jpegz, .basis = .pre_registry, .commit = "c48fd66", .date = "2026-05-06" },
	.xmp_metadata_present = .{ .owner = .jpegz, .basis = .pre_registry, .commit = "c48fd66", .date = "2026-05-06" },
	.photoshop_irb_present = .{ .owner = .jpegz, .basis = .pre_registry, .commit = "c48fd66", .date = "2026-05-06" },
	.trailing_data_after_eoi = .{ .owner = .jpegz, .basis = .pre_registry, .commit = "c48fd66", .date = "2026-05-06" },
	.jp2_packets_under_read = .{ .owner = .jp2z, .basis = .leaf_registry, .commit = "84c3c6f", .date = "2026-08-02" },
	.entropy_over_read = .{ .owner = .jp2z, .basis = .leaf_registry, .commit = "84c3c6f", .date = "2026-08-02" },
	.entropy_under_read = .{ .owner = .jp2z, .basis = .leaf_registry, .commit = "84c3c6f", .date = "2026-08-02" },
	.coding_pass_overflow = .{ .owner = .jp2z, .basis = .leaf_registry, .commit = "84c3c6f", .date = "2026-08-02" },
	.jp2_packets_walked_to_end = .{ .owner = .jp2z, .basis = .leaf_registry, .commit = "84c3c6f", .date = "2026-08-02" },
	.zero_bitplane_overflow = .{ .owner = .jp2z, .basis = .leaf_registry, .commit = "82111d7", .date = "2026-09-19" },
	.packed_headers_mismatch = .{ .owner = .jp2z, .basis = .leaf_registry, .commit = "82111d7", .date = "2026-09-19" },
	.jp2_trailing_bytes = .{ .owner = .jp2z, .basis = .leaf_registry, .commit = "82111d7", .date = "2026-09-19" },
	.segmentation_symbol_mismatch = .{ .owner = .jp2z, .basis = .leaf_registry, .commit = "82111d7", .date = "2026-09-19" },
	.profile_violation = .{ .owner = .jp2z, .basis = .leaf_registry, .commit = "82111d7", .date = "2026-09-19" },
	.reversible_exponent_mismatch = .{ .owner = .jp2z, .basis = .leaf_registry, .commit = "82111d7", .date = "2026-09-19" },
	.cblk_contribution_ends_ff = .{ .owner = .jp2z, .basis = .{ .coordinator = "2026-10-28" }, .commit = "446274f", .date = "2026-10-28" },
});

/// Writes the complete `docs/FINDING_CODES.md` in numeric order.
pub fn render(w: *std.Io.Writer) std.Io.Writer.Error!void {
	try w.writeAll(
		\\# Finding codes
		\\
		\\<!-- Generated from src/core/finding_provenance.zig by tools/gen_finding_codes.zig. Do not edit; run `zig build finding-codes`. -->
		\\
		\\Every `FindingCode` jpegz can report, with its provenance. Numbers are
		\\stable forever: the registry is append-only, and a value is never reused
		\\or renumbered. The enum in `src/core/errors.zig` is the source of truth
		\\for numbers and names; this table adds who owns each code and why its
		\\number was assigned. A new code needs validate's approval first (the
		\\coordinator approved codes before 2026-11-06).
		\\
		\\- **Owner** is the project whose validator emits the condition. jp2z
		\\  and libjxlz codes keep the leaf's own number in `leaf_code` as well.
		\\- **Introduced** is the jpegz commit that added the value.
		\\
		\\| Code | Name | Owner | Approval | Introduced |
		\\|---:|---|---|---|---|
		\\
	);
	var codes = std.enums.values(FindingCode)[0..].*;
	std.mem.sortUnstable(FindingCode, &codes, {}, struct {
		fn lessThan(_: void, a: FindingCode, b: FindingCode) bool {
			return @intFromEnum(a) < @intFromEnum(b);
		}
	}.lessThan);
	for (codes) |code| {
		const entry = table.get(code);
		try w.print("| {d} | `{t}` | {t} | ", .{ @intFromEnum(code), code, entry.owner });
		switch (entry.basis) {
			.pre_registry => try w.writeAll("Assigned by jpegz before the shared registry"),
			.coordinator => |date| try w.print("Coordinator approval, {s}", .{date}),
			.validate => |date| try w.print("validate approval, {s}", .{date}),
			.jxl_band => try w.writeAll("Coordinator's JPEG XL band 180..199, reserved 2026-08-05"),
			.leaf_registry => try w.writeAll("Assigned in jp2z's leaf registry"),
			.no_record => try w.writeAll("No approval record found"),
		}
		try w.print(" | {s} ({s}) |\n", .{ entry.commit orelse "this commit", entry.date });
	}
}

fn isDate(text: []const u8) bool {
	if (text.len != 10 or text[4] != '-' or text[7] != '-') return false;
	for (text, 0..) |c, i| {
		if (i == 4 or i == 7) continue;
		if (!std.ascii.isDigit(c)) return false;
	}
	return true;
}

test "every provenance row has a short commit hash and real dates" {
	for (std.enums.values(FindingCode)) |code| {
		const entry = table.get(code);
		if (entry.commit) |commit| {
			try std.testing.expectEqual(@as(usize, 7), commit.len);
			for (commit) |c| try std.testing.expect(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'));
		}
		try std.testing.expect(isDate(entry.date));
		switch (entry.basis) {
			.coordinator, .validate => |date| {
				try std.testing.expect(isDate(date));
				// An approval cannot postdate the commit that used the number.
				try std.testing.expect(std.mem.order(u8, date, entry.date) != .gt);
			},
			.pre_registry => try std.testing.expect(std.mem.order(u8, entry.date, "2026-08-01") == .lt),
			.jxl_band => try std.testing.expect(@intFromEnum(code) >= 180 and @intFromEnum(code) <= 199),
			else => {},
		}
	}
}

test "the rendered table has exactly one row per code" {
	var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
	defer buf.deinit();
	try render(&buf.writer);
	const text = buf.written();
	for (std.enums.values(FindingCode)) |code| {
		var needle_buf: [96]u8 = undefined;
		const needle = try std.fmt.bufPrint(&needle_buf, "\n| {d} | `{t}` |", .{ @intFromEnum(code), code });
		try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, needle));
	}
	try std.testing.expectEqual(std.enums.values(FindingCode).len, std.mem.count(u8, text, "\n| ") - 1);
}
