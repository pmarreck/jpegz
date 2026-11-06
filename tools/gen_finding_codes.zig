//! Generate or check `docs/FINDING_CODES.md` from
//! `src/core/finding_provenance.zig`.
//!
//!   gen_finding_codes <out_path>          write the table
//!   gen_finding_codes --check <doc_path>  fail when the doc differs
//!
//! `zig build finding-codes` writes the doc into the source tree and
//! `zig build test` runs the check, so a code added to the enum without a
//! provenance row fails to compile, and a stale doc fails the suite.

const std = @import("std");
const provenance = @import("provenance");

pub fn main(init: std.process.Init) !void {
	const a = init.arena.allocator();
	const io = init.io;
	const args = try init.minimal.args.toSlice(a);

	var rendered: std.Io.Writer.Allocating = .init(a);
	try provenance.render(&rendered.writer);
	const expected = rendered.written();

	if (args.len == 3 and std.mem.eql(u8, args[1], "--check")) {
		const actual = std.Io.Dir.cwd().readFileAlloc(io, args[2], a, .limited(4 * 1024 * 1024)) catch |err| {
			std.debug.print("finding-codes: cannot read {s}: {t}; run `zig build finding-codes`\n", .{ args[2], err });
			std.process.exit(1);
		};
		if (!std.mem.eql(u8, actual, expected)) {
			std.debug.print("finding-codes: docs/FINDING_CODES.md is stale; run `zig build finding-codes` and commit it\n", .{});
			std.process.exit(1);
		}
		return;
	}
	if (args.len != 2) {
		std.debug.print("usage: gen_finding_codes <out_path> | --check <doc_path>\n", .{});
		std.process.exit(2);
	}
	var file = try std.Io.Dir.cwd().createFile(io, args[1], .{});
	defer file.close(io);
	var buf: [4096]u8 = undefined;
	var w = file.writer(io, &buf);
	try w.interface.writeAll(expected);
	try w.interface.flush();
}
