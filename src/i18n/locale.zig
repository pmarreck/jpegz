//! Locale identification and resolution.
//!
//! This is the part of i18n that is pure computation, so it lives in the Zig
//! core rather than the CLI: parsing a locale tag and deciding which one a
//! user asked for are decisions, and decisions belong where they can be tested
//! without a process environment or a terminal. The CLI reads `argv` and the
//! environment, hands the strings here, and renders whatever comes back.
//!
//! Phase: PREPARE (see RULES.md § Internationalization and docs/I18N.md). The
//! 50-locale set is fixed and resolution is complete; catalogs are not. A
//! locale with no catalog resolves, reports itself as having none, and the CLI
//! warns — it does not fail the build. That flips when the string surface
//! stops churning.

const std = @import("std");

/// The canonical 50. Fixed set, chosen for high computer penetration PLUS
/// deliberately under-served languages (Hausa, Amharic, Yoruba, Igbo,
/// Filipino) on a "seed adoption where English penetration is thin"
/// rationale — NOT a top-50-by-speakers list. See docs/I18N.md before
/// proposing an addition or removal.
///
/// Tag names are the canonical codes: `@tagName` IS the wire format, which is
/// why `pt_br`, `zh_hans` and `zh_hant` are spelled with underscores.
pub const Locale = enum {
    am,
    ar,
    az,
    bg,
    bn,
    bs,
    da,
    de,
    el,
    en,
    es,
    fa,
    fi,
    fil,
    fr,
    ha,
    he,
    hi,
    hr,
    hu,
    id,
    ig,
    is,
    it,
    ja,
    km,
    ko,
    mk,
    nb,
    nl,
    pa,
    pl,
    ps,
    pt_br,
    ro,
    ru,
    sl,
    sq,
    sr,
    sv,
    sw,
    ta,
    th,
    tr,
    uk,
    ur,
    vi,
    yo,
    zh_hans,
    zh_hant,

    /// Canonical code, e.g. `.pt_br` → `"pt_br"`. This is both what `--lang`
    /// accepts and what gets printed, so it must round-trip through `parse`.
    pub fn code(self: Locale) []const u8 {
        return @tagName(self);
    }

    /// Right-to-left script. Five of the fifty. Callers that compose a line
    /// mixing localized text with an English original need this to emit the
    /// bidi marks, or the terminal reorders the result confusingly.
    pub fn isRtl(self: Locale) bool {
        return switch (self) {
            .ar, .he, .fa, .ps, .ur => true,
            else => false,
        };
    }

    /// Whether a translated catalog actually exists. Prepare phase: only
    /// English. Deliberately a real check rather than `true`, because the CLI
    /// warns on the difference and a stub that claimed coverage would make
    /// every missing catalog invisible.
    pub fn hasCatalog(self: Locale) bool {
        return self == .en;
    }

    /// Parse a locale tag, taking the LONGEST match.
    ///
    /// Longest-match is the whole difficulty. `fil` (Filipino) shares its
    /// first two bytes with `fi` (Finnish), and `pt_br` / `zh_hans` are single
    /// units rather than a code plus a discardable suffix — so a parser that
    /// takes the first two characters, or splits on the separator and keeps
    /// the head, silently mis-identifies them while passing every ordinary
    /// two-letter case.
    ///
    /// Accepts what platforms actually hand us: any case, `-` or `_`, and the
    /// POSIX `de_DE.UTF-8` / `fr_FR@euro` decorations. Returns null rather
    /// than guessing; `C` and `POSIX` are not locales and are rejected here
    /// (`resolve` treats them as "no localization requested").
    pub fn parse(raw: []const u8) ?Locale {
        var buf: [64]u8 = undefined;
        const norm = normalize(raw, &buf) orelse return null;
        if (norm.len < 2) return null;

        // Try the whole tag, then progressively shorter prefixes that end on a
        // separator boundary. Boundary-only truncation is what stops `fil`
        // from ever being considered as `fi`.
        var end: usize = norm.len;
        while (true) {
            if (matchCanonical(norm[0..end])) |loc| return loc;
            var i = end;
            while (i > 0 and norm[i - 1] != '_') i -= 1;
            if (i == 0) break; // no separator left to cut at
            end = i - 1;
            if (end == 0) break;
        }

        // Chinese carrying no script subtag. `zh`, `zh_CN`, `zh_TW` and
        // friends match nothing above, because the canonical names are
        // script-qualified. Fold by region instead of rejecting the most
        // commonly typed spellings outright.
        if (norm.len >= 2 and std.mem.eql(u8, norm[0..2], "zh") and
            (norm.len == 2 or norm[2] == '_'))
        {
            return chineseFromRegion(norm);
        }
        return null;
    }

    fn matchCanonical(candidate: []const u8) ?Locale {
        inline for (@typeInfo(Locale).@"enum".fields) |f| {
            if (std.mem.eql(u8, candidate, f.name)) return @field(Locale, f.name);
        }
        return null;
    }

    /// CLDR's likely-subtags rule, reduced to the three Traditional-script
    /// regions so we need not vendor a likelihood database: Traditional for
    /// TW / HK / MO, Simplified for everything else including bare `zh`.
    fn chineseFromRegion(norm: []const u8) Locale {
        var it = std.mem.splitScalar(u8, norm, '_');
        _ = it.next(); // "zh"
        while (it.next()) |part| {
            if (std.mem.eql(u8, part, "tw") or
                std.mem.eql(u8, part, "hk") or
                std.mem.eql(u8, part, "mo")) return .zh_hant;
        }
        return .zh_hans;
    }

    /// Lowercase, map `-` to `_`, and drop the POSIX charset (`.UTF-8`) and
    /// modifier (`@euro`) suffixes. Returns null if the tag is longer than any
    /// real locale tag, rather than silently truncating into a wrong match.
    fn normalize(raw: []const u8, buf: []u8) ?[]const u8 {
        var n: usize = 0;
        for (raw) |c| {
            if (c == '.' or c == '@') break;
            if (n == buf.len) return null;
            buf[n] = switch (c) {
                'A'...'Z' => c + 32,
                '-' => '_',
                else => c,
            };
            n += 1;
        }
        return buf[0..n];
    }
};

/// Every signal that can select a language, as strings, so the decision below
/// is a pure function. The CLI fills these from `argv` and `getenv`; tests
/// fill them directly.
///
/// Deliberately NOT read from the environment here: a resolver that calls
/// `getenv` itself can only be tested by mutating the process environment,
/// which is global state shared with every other test in the binary.
pub const Request = struct {
    /// `--lang <code>`, or a localized alias for it.
    lang_arg: ?[]const u8 = null,
    /// `JPEGZ_LANG` — application-specific, so it outranks the system locale.
    app_env: ?[]const u8 = null,
    /// POSIX message-catalog chain, highest precedence first.
    lc_all: ?[]const u8 = null,
    lc_messages: ?[]const u8 = null,
    lang: ?[]const u8 = null,
};

pub const Resolution = struct {
    locale: Locale,
    /// The user explicitly asked for a locale jpegz does not support. Distinct
    /// from merely falling back: silently answering in English is how a
    /// missing locale goes unnoticed indefinitely.
    unsupported_request: bool = false,
    /// The unsupported tag, verbatim, for the warning message.
    requested: ?[]const u8 = null,
};

/// Decide which locale to render in.
///
/// Precedence: `--lang` beats `JPEGZ_LANG` beats `LC_ALL` beats `LC_MESSAGES`
/// beats `LANG`, and English is the floor. The first two are the user asking
/// *jpegz* for something and are honored loudly; the rest describe the machine
/// and are honored quietly.
///
/// That asymmetry is the point. An unparseable `--lang` is a user error worth
/// reporting. An unparseable `LANG` is not — it would fire on every machine
/// whose system locale we happen not to translate, training users to ignore
/// the warning.
pub fn resolve(req: Request) Resolution {
    if (firstPresent(&.{ req.lang_arg, req.app_env })) |explicit| {
        if (isLocaleNeutral(explicit)) return .{ .locale = .en };
        if (Locale.parse(explicit)) |loc| return .{ .locale = loc };
        return .{ .locale = .en, .unsupported_request = true, .requested = explicit };
    }
    if (firstPresent(&.{ req.lc_all, req.lc_messages, req.lang })) |system| {
        if (Locale.parse(system)) |loc| return .{ .locale = loc };
    }
    return .{ .locale = .en };
}

/// `C` and `POSIX` mean "no localization", which is a legitimate answer rather
/// than an unsupported locale to complain about.
fn isLocaleNeutral(tag: []const u8) bool {
    return std.ascii.eqlIgnoreCase(tag, "c") or std.ascii.eqlIgnoreCase(tag, "posix");
}

/// First non-null, non-empty entry. Empty environment variables are set far
/// more often than they are meaningful, so they must not shadow a later signal.
fn firstPresent(candidates: []const ?[]const u8) ?[]const u8 {
    for (candidates) |c| {
        if (c) |value| {
            if (value.len > 0) return value;
        }
    }
    return null;
}
