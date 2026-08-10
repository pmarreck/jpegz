//! Locale parsing and resolution — the two pieces of i18n that are pure
//! computation and therefore belong in the Zig core rather than the CLI.
//!
//! Both are tested as classifiers over sets. A locale parser is exactly the
//! kind of code that looks right on the happy path and silently mangles the
//! awkward codes: `fil` truncating to `fi`, `pt_br` splitting at the
//! separator, `zh` matching nothing because it carries no script subtag.

const std = @import("std");
const jpegz = @import("jpegz");
const Locale = jpegz.i18n.Locale;

test "locale parser takes the longest match, so 3- and 5-char codes survive" {
	// `fil` (Filipino) shares its first two bytes with `fi` (Finnish), and
	// `pt_br` / `zh_hans` are single units rather than a code plus a suffix.
	// A shortest-match or split-on-separator parser mis-handles all of them
	// while still passing every 2-letter case.
	const Case = struct { input: []const u8, want: ?Locale };
	const cases = [_]Case{
		.{ .input = "fi", .want = .fi },
		.{ .input = "fil", .want = .fil },
		.{ .input = "pt_br", .want = .pt_br },
		.{ .input = "zh_hans", .want = .zh_hans },
		.{ .input = "zh_hant", .want = .zh_hant },
		.{ .input = "en", .want = .en },
		.{ .input = "ar", .want = .ar },
		// Case and separator normalization: users type what their platform
		// hands them, which is rarely our canonical spelling.
		.{ .input = "PT_BR", .want = .pt_br },
		.{ .input = "pt-BR", .want = .pt_br },
		.{ .input = "de_DE.UTF-8", .want = .de },
		.{ .input = "fr_FR@euro", .want = .fr },
		// Not ours.
		.{ .input = "xx", .want = null },
		.{ .input = "", .want = null },
		.{ .input = "f", .want = null },
		.{ .input = "C", .want = null },
		.{ .input = "POSIX", .want = null },
	};
	for (cases) |case| {
		const got = Locale.parse(case.input);
		if (got != case.want) {
			std.debug.print("parse(\"{s}\") returned the wrong locale\n", .{case.input});
			return error.TestExpectedEqual;
		}
	}
}

test "generic and region-only Chinese folds to a script, defaulting to Simplified" {
	// `zh`, `zh_CN` and friends carry no script subtag, so a parser that only
	// matches canonical names rejects the most common spellings outright.
	// CLDR's likely-subtags rule reduces to: Traditional for TW/HK/MO,
	// Simplified otherwise.
	const Case = struct { input: []const u8, want: Locale };
	const cases = [_]Case{
		.{ .input = "zh", .want = .zh_hans },
		.{ .input = "zh_CN", .want = .zh_hans },
		.{ .input = "zh_SG", .want = .zh_hans },
		.{ .input = "zh_MY", .want = .zh_hans },
		.{ .input = "zh_TW", .want = .zh_hant },
		.{ .input = "zh_HK", .want = .zh_hant },
		.{ .input = "zh_MO", .want = .zh_hant },
		// An explicit script subtag always beats the region table.
		.{ .input = "zh_Hant", .want = .zh_hant },
		.{ .input = "zh_Hant_HK", .want = .zh_hant },
		.{ .input = "zh_Hans_TW", .want = .zh_hans },
		.{ .input = "zh_Hans", .want = .zh_hans },
	};
	for (cases) |case| {
		const got = Locale.parse(case.input);
		if (got != case.want) {
			std.debug.print("parse(\"{s}\") returned the wrong locale\n", .{case.input});
			return error.TestExpectedEqual;
		}
	}
}

test "the canonical set is exactly 50 locales including the 5 RTL ones" {
	const all = std.enums.values(Locale);
	try std.testing.expectEqual(@as(usize, 50), all.len);

	var rtl_count: usize = 0;
	for (all) |loc| {
		if (loc.isRtl()) rtl_count += 1;
	}
	try std.testing.expectEqual(@as(usize, 5), rtl_count);
	// Naming them individually: a count alone would pass if the wrong five
	// were flagged.
	for ([_]Locale{ .ar, .he, .fa, .ps, .ur }) |loc| {
		try std.testing.expect(loc.isRtl());
	}
	for ([_]Locale{ .en, .de, .ja, .zh_hans, .sw }) |loc| {
		try std.testing.expect(!loc.isRtl());
	}
}

test "every locale round-trips through its own canonical name" {
	// The name table is what the CLI prints and what `--lang` accepts, so a
	// typo in one entry silently makes that locale unreachable.
	for (std.enums.values(Locale)) |loc| {
		const name = loc.code();
		try std.testing.expect(name.len >= 2);
		try std.testing.expectEqual(loc, Locale.parse(name).?);
	}
}

test "resolution prefers an explicit request over the environment" {
	// Precedence is pure: the caller reads the environment, this decides. That
	// keeps the rule testable without mutating any process state.
	const req = jpegz.i18n.Request;

	// --lang beats JPEGZ_LANG beats the POSIX chain.
	try std.testing.expectEqual(Locale.fr, jpegz.i18n.resolve(req{
		.lang_arg = "fr",
		.app_env = "de",
		.lc_all = "ja",
		.lc_messages = "ko",
		.lang = "it",
	}).locale);
	try std.testing.expectEqual(Locale.de, jpegz.i18n.resolve(req{
		.app_env = "de",
		.lc_all = "ja",
		.lang = "it",
	}).locale);
	try std.testing.expectEqual(Locale.ja, jpegz.i18n.resolve(req{
		.lc_all = "ja",
		.lc_messages = "ko",
		.lang = "it",
	}).locale);
	try std.testing.expectEqual(Locale.ko, jpegz.i18n.resolve(req{
		.lc_messages = "ko",
		.lang = "it",
	}).locale);
	try std.testing.expectEqual(Locale.it, jpegz.i18n.resolve(req{ .lang = "it" }).locale);

	// No signal at all is English, not an error.
	try std.testing.expectEqual(Locale.en, jpegz.i18n.resolve(req{}).locale);

	// `C`/`POSIX` are explicitly "no localization", not an unsupported locale
	// to complain about.
	const posix = jpegz.i18n.resolve(req{ .lang = "C" });
	try std.testing.expectEqual(Locale.en, posix.locale);
	try std.testing.expect(!posix.unsupported_request);
}

test "an unsupported explicit request is reported, not silently downgraded" {
	// Prepare phase renders English anyway, but the caller must be able to
	// tell that it ignored what the user asked for. Silently answering in
	// English is how a missing locale goes unnoticed for a year.
	const req = jpegz.i18n.Request;

	const bad_arg = jpegz.i18n.resolve(req{ .lang_arg = "klingon" });
	try std.testing.expectEqual(Locale.en, bad_arg.locale);
	try std.testing.expect(bad_arg.unsupported_request);
	try std.testing.expectEqualStrings("klingon", bad_arg.requested.?);

	const bad_env = jpegz.i18n.resolve(req{ .app_env = "xx" });
	try std.testing.expect(bad_env.unsupported_request);

	// An unusable *system* locale is NOT a user error — the user did not ask
	// jpegz for anything. Warning here would fire on every machine whose LANG
	// we do not translate.
	const sys = jpegz.i18n.resolve(req{ .lang = "xx" });
	try std.testing.expectEqual(Locale.en, sys.locale);
	try std.testing.expect(!sys.unsupported_request);
}

test "catalog availability is honest during prepare phase" {
	// Only English is populated today. `hasCatalog` is what the CLI warns on,
	// so it must not claim coverage that does not exist.
	try std.testing.expect(Locale.en.hasCatalog());
	var populated: usize = 0;
	for (std.enums.values(Locale)) |loc| {
		if (loc.hasCatalog()) populated += 1;
	}
	try std.testing.expectEqual(@as(usize, 1), populated);
}
