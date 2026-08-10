#!/usr/bin/env bash
# U5 — CLI surface tests for the `jpegz` C CLI (validation only).
#
# The CLI dogfoods jpegz's C FFI (include/jpegz_core.h): C cannot
# `@import` the Zig module, so the bypass is inexpressible rather than
# merely forbidden. These tests drive the built binary as a black box.
#
# Per CLAUDE.md "Testing Principles": NO `set -euo pipefail`. `set -e`
# aborts the moment a command-under-test exits non-zero — which is the
# EXPECTED behavior for every corrupt-input case below. Accumulate
# failures explicitly instead.

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/capture.bash
source "$here/lib/capture.bash"

# Binary under test: argv[1], else $JPEGZ_CLI, else the conventional
# zig-out location.
jpegz_cli="${1:-${JPEGZ_CLI:-$here/../../zig-out/bin/jpegz}}"
fixtures="$here/../unit/fixtures"

passed=0
failed=0

pass() { passed=$((passed + 1)); printf '  ok   %s\n' "$1"; }
fail() {
	failed=$((failed + 1))
	printf '  FAIL %s\n' "$1"
	[ $# -gt 1 ] && printf '       %s\n' "$2"
	return 0
}

# assert_rc <expected-rc> <label> -- <cmd...>
assert_rc() {
	local want="$1" label="$2"
	shift 3 # drop want, label, and the literal `--`
	local out err rc
	capture "$@"
	if [ "$rc" -eq "$want" ]; then
		pass "$label"
	else
		fail "$label" "expected exit $want, got $rc; stderr: ${err:-<empty>}"
	fi
}

# assert_contains <haystack> <needle> <label>
assert_contains() {
	case "$1" in
	*"$2"*) pass "$3" ;;
	*) fail "$3" "expected to contain '$2', got: $1" ;;
	esac
}

echo "==> jpegz CLI ($jpegz_cli)"

if [ ! -x "$jpegz_cli" ]; then
	fail "binary exists and is executable" "not found: $jpegz_cli"
	echo
	echo "$failed failed, $passed passed"
	exit 1
fi

# ── 1. Baseline conventions ──────────────────────────────────────────

out=; err=; rc=
capture "$jpegz_cli" --about
# Assert on STDOUT alone. --about's payload belongs on stdout, and a debug
# build legitimately writes a "DEBUG BUILD" banner to stderr — folding the
# two together would make this test's verdict depend on the build mode.
assert_contains "$out" "jpegz" "--about names the tool"
[ "$rc" -eq 0 ] && pass "--about exits 0" || fail "--about exits 0" "got $rc"
# --about must be ONE line.
about_lines=$(printf '%s' "$out" | grep -c '')
[ "$about_lines" -eq 1 ] && pass "--about is one line" || fail "--about is one line" "got $about_lines lines"

assert_rc 0 "--help exits 0" -- "$jpegz_cli" --help
assert_rc 0 "-h exits 0" -- "$jpegz_cli" -h

# ── 2. Validation verdicts (the actual product) ──────────────────────

assert_rc 0 "clean baseline JPEG validates" -- "$jpegz_cli" "$fixtures/baseline_2x2_rgb.jpg"
assert_rc 0 "clean JP2 validates" -- "$jpegz_cli" "$fixtures/jp2_8x8_rgb.jp2"

# Truncated JPEG: structurally broken, must be rejected.
trunc="$TMPDIR/jpegz_cli_trunc_$$.jpg"
head -c 40 "$fixtures/baseline_2x2_rgb.jpg" >"$trunc"
assert_rc 1 "truncated JPEG is rejected" -- "$jpegz_cli" "$trunc"

# T.800 coverage through the facade (U1). Until 2026-08-01 this whole block
# would have failed: jpeg2000.validate was a stub returning PASS, so a
# shredded JP2 validated clean through the CLI.
#
# NOTE the fixture is 238 bytes. An earlier version of this suite "truncated"
# it with `head -c 300`, which copies the whole file — the test passed while
# measuring nothing. Derive the cut from the actual size instead of a literal.
jp2_src="$fixtures/jp2_8x8_rgb.jp2"
jp2_size=$(wc -c <"$jp2_src")
jp2_trunc="$TMPDIR/jpegz_cli_trunc_$$.jp2"
head -c $((jp2_size / 2)) "$jp2_src" >"$jp2_trunc"
[ "$(wc -c <"$jp2_trunc")" -lt "$jp2_size" ] \
	&& pass "JP2 truncation fixture is actually shorter than the source" \
	|| fail "JP2 truncation fixture is actually shorter than the source" \
		"cut=$(wc -c <"$jp2_trunc") source=$jp2_size"

assert_rc 1 "truncated JP2 is rejected" -- "$jpegz_cli" "$jp2_trunc"

out=; err=; rc=
capture "$jpegz_cli" "$jp2_trunc"
assert_contains "$out$err" "truncated_stream" "truncated JP2 names a specific T.800 cause"

# A clean JP2 must not carry a failure-flavored code. Translating jp2z's
# registry into jpegz's previously degraded every unrecognized code to
# jp2_invalid_codestream, so a HEALTHY file reported an invalid codestream.
out=; err=; rc=
capture "$jpegz_cli" "$jp2_src"
case "$out$err" in
*jp2_invalid_codestream* | *jp2_invalid_signature*)
	fail "clean JP2 carries no failure-flavored code" "got: $out$err" ;;
*) pass "clean JP2 carries no failure-flavored code" ;;
esac
# ...and the positive evidence survives translation.
assert_contains "$out$err" "jp2_packets_walked_to_end" \
	"clean JP2 keeps jp2z's walked-to-end success signal"
assert_contains "$out$err" "JPEG 2000" "clean JP2 reports its variant"

# ── 3. Rich error reporting — the whole point of the slice ───────────
# A verdict alone is useless to a human or to validate. The CLI must
# name the SPECIFIC cause, not just say "invalid".

out=; err=; rc=
capture "$jpegz_cli" "$trunc"
combined="$out$err"
case "$combined" in
*[Ii]nvalid" "[Ii]mage* | *"failed"*)
	# A bare generic phrase is exactly what we're trying to avoid.
	fail "corrupt file names a specific cause" "generic-only output: $combined"
	;;
*)
	if [ -n "$combined" ]; then
		pass "corrupt file produces diagnostic output"
	else
		fail "corrupt file produces diagnostic output" "no output at all"
	fi
	;;
esac
assert_contains "$combined" "truncated" "diagnostic names the truncation"

# ── 4. JSON output for tooling ───────────────────────────────────────

out=; err=; rc=
capture "$jpegz_cli" --json "$trunc"
# The top-level field is `verdict`, not the old severity `overall`: the facade
# reports four outcomes, and "unsupported"/"indeterminate" have no severity
# that would not misrepresent them.
assert_contains "$out" '"verdict":"corrupt"' "--json emits a top-level verdict"
assert_contains "$out" '"findings"' "--json emits a findings array"
assert_contains "$out" '"code"' "--json findings carry a stable code"

# ── 5. stdin support ─────────────────────────────────────────────────

out=; err=; rc=
capture bash -c "cat '$fixtures/baseline_2x2_rgb.jpg' | '$jpegz_cli' -"
[ "$rc" -eq 0 ] && pass "reads from '-' (stdin)" || fail "reads from '-' (stdin)" "got $rc: $err"

out=; err=; rc=
capture bash -c "cat '$fixtures/baseline_2x2_rgb.jpg' | '$jpegz_cli' @stdin"
[ "$rc" -eq 0 ] && pass "reads from '@stdin'" || fail "reads from '@stdin'" "got $rc: $err"

# ── 6. Paths with spaces (quoted AND escaped) ────────────────────────

spacedir="$TMPDIR/jpegz cli spaces $$"
mkdir -p "$spacedir"
spaced="$spacedir/a file with spaces.jpg"
cp "$fixtures/baseline_2x2_rgb.jpg" "$spaced"
assert_rc 0 "accepts a quoted path with spaces" -- "$jpegz_cli" "$spaced"

# ── 7. Presentation switches suppress decoration ─────────────────────

esc=$(printf '\033')

# Show the offending bytes. A failure you cannot diagnose from its own
# message costs a whole debug cycle — especially here, where this suite runs
# inside the Nix sandbox and the local run may not reproduce it.
show_ansi_failure() {
	printf '%s' "$1" | cat -v | head -3
}

out=; err=; rc=
capture "$jpegz_cli" --no-color "$trunc"
case "$out$err" in
*"$esc["*) fail "--no-color emits no ANSI" "got: $(show_ansi_failure "$out$err")" ;;
*) pass "--no-color emits no ANSI" ;;
esac

out=; err=; rc=
capture "$jpegz_cli" --simple "$trunc"
case "$out$err" in
*"$esc["*) fail "--simple emits no ANSI" "got: $(show_ansi_failure "$out$err")" ;;
*) pass "--simple emits no ANSI" ;;
esac

# ── 8. Argument discipline ───────────────────────────────────────────

# Later args override earlier ones.
assert_rc 0 "later --no-json overrides earlier --json" -- \
	"$jpegz_cli" --json --no-json "$fixtures/baseline_2x2_rgb.jpg"

# Unknown switch is an error, not a silently-ignored no-op.
out=; err=; rc=
capture "$jpegz_cli" --definitely-not-a-real-flag "$fixtures/baseline_2x2_rgb.jpg"
[ "$rc" -ne 0 ] && pass "unknown switch is rejected" || fail "unknown switch is rejected" "exited 0"

# Missing file is an error with a message on stderr.
out=; err=; rc=
capture "$jpegz_cli" "$TMPDIR/definitely-does-not-exist-$$.jpg"
[ "$rc" -ne 0 ] && pass "missing file is rejected" || fail "missing file is rejected" "exited 0"
[ -n "$err" ] && pass "missing-file error goes to stderr" || fail "missing-file error goes to stderr" "stderr empty"

# ── 9. Whole-family facade: JPEG XL, and honest four-way verdicts ────
#
# The CLI used to sniff containers itself, in C, and knew only two of them.
# Anything it did not recognize fell through to the JPEG path and was
# described in T.81 vocabulary — a JP2 with a damaged signature box came back
# as "missing_soi — JPEG must start with SOI marker", naming a marker that
# does not exist anywhere in T.800. Routing now lives in the library.

# JPEG XL was entirely unreachable from the CLI before the facade.
out=; err=; rc=
capture "$jpegz_cli" --simple "$fixtures/jxl_delta_palette_valid.jxl"
[ "$rc" -eq 0 ] && pass "known-good JPEG XL exits 0" || fail "known-good JPEG XL exits 0" "rc=$rc; $out$err"
assert_contains "$out" "valid" "known-good JPEG XL reports valid"

# A JXL using a feature libjxlz does not cover is NOT corruption. Reporting it
# as such would condemn a perfectly good file.
out=; err=; rc=
capture "$jpegz_cli" --simple "$fixtures/jxl_patches_lossless_unsupported.jxl"
assert_contains "$out" "unsupported" "unsupported JXL says unsupported, not corrupt"
[ "$rc" -ne 1 ] && pass "unsupported JXL does not exit as corrupt" || fail "unsupported JXL does not exit as corrupt" "rc=1"

# The motivating bug: a smashed JP2 signature must not be diagnosed in JPEG terms.
smashed="$TMPDIR/jpegz-cli-smashed-$$.jp2"
cp "$fixtures/jp2_8x8_rgb.jp2" "$smashed"
printf '\0\0\0\0\0\0\0\0\0\0\0\0' | dd of="$smashed" bs=1 seek=0 count=12 conv=notrunc status=none
out=; err=; rc=
capture "$jpegz_cli" --simple "$smashed"
case "$out" in
*missing_soi*) fail "smashed JP2 is not described as a JPEG missing SOI" "got: $out" ;;
*) pass "smashed JP2 is not described as a JPEG missing SOI" ;;
esac
[ "$rc" -ne 0 ] && pass "smashed JP2 does not exit clean" || fail "smashed JP2 does not exit clean" "rc=0"

# Foreign bytes are inconclusive, not corrupt: jpegz has no evidence of damage.
foreign="$TMPDIR/jpegz-cli-foreign-$$.bin"
printf '\211PNG\r\n\032\n' > "$foreign"
out=; err=; rc=
capture "$jpegz_cli" --simple "$foreign"
assert_contains "$out" "indeterminate" "foreign bytes report indeterminate"
[ "$rc" -eq 3 ] && pass "inconclusive input exits 3, distinct from corrupt" || fail "inconclusive input exits 3, distinct from corrupt" "rc=$rc"

# A corrupt file must still outrank an inconclusive one in the exit code.
out=; err=; rc=
capture "$jpegz_cli" --simple "$foreign" "$trunc"
[ "$rc" -eq 1 ] && pass "corrupt outranks inconclusive in the exit code" || fail "corrupt outranks inconclusive in the exit code" "rc=$rc"

# JSON carries the verdict and the format that answered, for tooling.
out=; err=; rc=
capture "$jpegz_cli" --json "$fixtures/jxl_delta_palette_valid.jxl"
assert_contains "$out" '"verdict":"valid"' "JSON exposes the verdict"
assert_contains "$out" '"format":"jpeg_xl"' "JSON names the format that answered"

rm -f "$smashed" "$foreign" 2>/dev/null

# ── 10b. Locale selection (i18n prepare phase) ───────────────────────
#
# Prepare phase: the resolver is complete, the catalogs are not. So a
# recognized locale must resolve and say its catalog is missing, and an
# unrecognized one must be reported — never silently answered in English,
# which is how a missing locale goes unnoticed for a year.

out=; err=; rc=
capture "$jpegz_cli" --simple --lang fr "$fixtures/baseline_2x2_rgb.jpg"
[ "$rc" -eq 0 ] && pass "--lang with a known locale still validates" || fail "--lang with a known locale still validates" "rc=$rc"
assert_contains "$err" "fr" "--lang fr warns that its catalog is missing"

# An unsupported explicit request is a user error worth naming.
out=; err=; rc=
capture "$jpegz_cli" --simple --lang klingon "$fixtures/baseline_2x2_rgb.jpg"
assert_contains "$err" "klingon" "unsupported --lang names what was asked for"

# The app-specific env var works, and --lang outranks it.
out=; err=; rc=
JPEGZ_LANG=de capture "$jpegz_cli" --simple "$fixtures/baseline_2x2_rgb.jpg"
assert_contains "$err" "de" "JPEGZ_LANG selects a locale"

out=; err=; rc=
JPEGZ_LANG=de capture "$jpegz_cli" --simple --lang fr "$fixtures/baseline_2x2_rgb.jpg"
case "$err" in
*fr*) pass "--lang outranks JPEGZ_LANG" ;;
*) fail "--lang outranks JPEGZ_LANG" "expected fr in: $err" ;;
esac

# An unusable SYSTEM locale is not the user's doing and must stay quiet, or
# the warning fires on every machine we do not translate.
out=; err=; rc=
LANG=xx_XX.UTF-8 capture "$jpegz_cli" --simple "$fixtures/baseline_2x2_rgb.jpg"
case "$err" in
*xx*) fail "an unusable system locale does not warn" "got: $err" ;;
*) pass "an unusable system locale does not warn" ;;
esac

# English is the floor and must not warn on the common path. Asserting stderr
# is EMPTY would be wrong: a debug build legitimately prints its DEBUG banner
# there. Assert the absence of the locale complaints specifically.
out=; err=; rc=
capture "$jpegz_cli" --simple --lang en "$fixtures/baseline_2x2_rgb.jpg"
case "$err" in
*"translation"* | *"unsupported locale"*) fail "--lang en warns about nothing" "stderr: $err" ;;
*) pass "--lang en warns about nothing" ;;
esac

# ── 10. Forcing decoration on ─────────────────────────────────────────
#
# Suppression already existed; forcing did not. Without `--color` there is no
# way to get colored output into a pager or a captured log, because stdout is
# not a terminal in either case and jpegz correctly defaults decoration off.

out=; err=; rc=
capture "$jpegz_cli" --color "$fixtures/baseline_2x2_rgb.jpg"
case "$out" in
*"$esc["*) pass "--color forces ANSI when stdout is not a terminal" ;;
*) fail "--color forces ANSI when stdout is not a terminal" "no escapes in: $out" ;;
esac

# Later wins, in both directions — the general argument rule, applied to a
# switch that now has a real opposite.
out=; err=; rc=
capture "$jpegz_cli" --color --no-color "$fixtures/baseline_2x2_rgb.jpg"
case "$out" in
*"$esc["*) fail "later --no-color beats earlier --color" "got: $(show_ansi_failure "$out")" ;;
*) pass "later --no-color beats earlier --color" ;;
esac

out=; err=; rc=
capture "$jpegz_cli" --simple --color "$fixtures/baseline_2x2_rgb.jpg"
case "$out" in
*"$esc["*) pass "later --color beats earlier --simple" ;;
*) fail "later --color beats earlier --simple" "no escapes in: $out" ;;
esac

rm -f "$trunc" "$spaced" 2>/dev/null
rmdir "$spacedir" 2>/dev/null

echo
echo "$failed failed, $passed passed"
[ "$failed" -eq 0 ]
