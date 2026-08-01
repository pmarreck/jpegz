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
assert_contains "$out" '"overall"' "--json emits an overall verdict"
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

rm -f "$trunc" "$spaced" 2>/dev/null
rmdir "$spacedir" 2>/dev/null

echo
echo "$failed failed, $passed passed"
[ "$failed" -eq 0 ]
