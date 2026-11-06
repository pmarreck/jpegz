#!/usr/bin/env bash
# fuzz-save-crash must turn the record check-fuzz-result prints into the
# exact crash bytes, under the harness the driver named, without clobbering.
set -u
root=$(cd -- "$(dirname -- "$0")/../.." && pwd) || exit 1
gate=$root/tools/check-fuzz-result
saver=$root/tools/fuzz-save-crash
work=$(mktemp -d "${TMPDIR:-/tmp}/jpegz-fuzz-save.XXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT
failures=0
pass() { printf '    ok %s\n' "$1"; }
fail() { printf '    FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }
seed=0x0000abcd
nix_prefix="jpegz-fuzz-campaign-$seed> "

# A disposable project with both harness names, so the saver never writes
# into this checkout.
project=$work/project
mkdir -p "$project/tests/fuzz" || exit 1
: > "$project/tests/fuzz/decode_fuzz.zig"
: > "$project/tests/fuzz/validate_fuzz.zig"

# Build a campaign log the way the Nix check does: the driver log, then the
# gate's stderr, every line carrying Nix's build-log prefix.
make_log() { # NAME HARNESS CRASH_FILE
	local dir=$work/$1
	mkdir -p "$dir/cache/f" || return 1
	cp -- "$3" "$dir/cache/f/crash" || return 1
	printf "error: test '%s.test.fuzz: harness never panics' terminated with signal ABRT; input saved to '.zig-cache/f/crash'\n" "$2" > "$dir/driver.log"
	{ cat "$dir/driver.log"; bash "$gate" 1 "$dir/cache" "$dir/driver.log" "$seed" 2>&1; } |
		sed "s/^/$nix_prefix/" > "$dir/campaign.log"
}

# Bytes that would break a text round trip: NUL, 0xFF, CR, LF and a length
# long enough for base64 to wrap.
crash=$work/crash.bin
{ printf '\x00\xff\r\n\x10\x00\x00\x00'; head -c 300 /dev/urandom; } > "$crash"

make_log decode decode_fuzz "$crash" || exit 1
saved=$(bash "$saver" "$work/decode/campaign.log" "$project" 2> "$work/decode.err")
status=$?
dest=$project/tests/fuzz/regressions/decode_fuzz/$seed.bin
if [[ $status -eq 0 && $saved == "$dest" ]] && cmp -s "$crash" "$dest"; then
	pass "saves the exact crash bytes under the named harness and seed"
else
	fail "saves the exact crash bytes under the named harness and seed (status=$status saved=$saved)"
	cat "$work/decode.err" >&2
fi

saved=$(bash "$saver" "$work/decode/campaign.log" "$project" 2>/dev/null)
status=$?
if [[ $status -eq 0 && $saved == "$dest" ]] && cmp -s "$crash" "$dest"; then
	pass "saving the same crash again is idempotent"
else
	fail "saving the same crash again is idempotent (status=$status)"
fi

other=$work/other.bin
printf 'different input' > "$other"
make_log other decode_fuzz "$other" || exit 1
bash "$saver" "$work/other/campaign.log" "$project" > /dev/null 2>&1
status=$?
if [[ $status -eq 1 ]] && cmp -s "$crash" "$dest"; then
	pass "never overwrites a saved crash with different bytes"
else
	fail "never overwrites a saved crash with different bytes (status=$status)"
fi

make_log validate validate_fuzz "$other" || exit 1
saved=$(bash "$saver" "$work/validate/campaign.log" "$project" 2>/dev/null)
status=$?
if [[ $status -eq 0 && $saved == "$project/tests/fuzz/regressions/validate_fuzz/$seed.bin" ]] && cmp -s "$other" "$saved"; then
	pass "routes a validate_fuzz crash to its own harness directory"
else
	fail "routes a validate_fuzz crash to its own harness directory (status=$status saved=$saved)"
fi

# Incomplete or inconsistent records save nothing.
expect_refusal() { # LABEL LOG
	local before after
	before=$(find "$project/tests/fuzz/regressions" -type f 2>/dev/null | sort)
	bash "$saver" "$2" "$project" > /dev/null 2>&1
	local status=$?
	after=$(find "$project/tests/fuzz/regressions" -type f 2>/dev/null | sort)
	if [[ $status -eq 1 && $before == "$after" ]]; then
		pass "refuses $1"
	else
		fail "refuses $1 (status=$status)"
	fi
}
make_log unknown nonexistent_fuzz "$other" || exit 1
expect_refusal "an unknown harness" "$work/unknown/campaign.log"
grep -v 'end of crash input' "$work/decode/campaign.log" > "$work/unterminated.log"
expect_refusal "a crash block with no end marker" "$work/unterminated.log"
sed 's/crash input, \([0-9]*\) bytes/crash input, 1\1 bytes/' "$work/decode/campaign.log" > "$work/size.log"
expect_refusal "a block whose size disagrees with its bytes" "$work/size.log"
grep -v "input saved to" "$work/decode/campaign.log" > "$work/noharness.log"
expect_refusal "a log that names no harness" "$work/noharness.log"
grep -v 'failed with seed' "$work/decode/campaign.log" > "$work/noseed.log"
expect_refusal "a log that names no seed" "$work/noseed.log"
awk '/base64:$/ { print; print "not*base64"; next } { print }' "$work/decode/campaign.log" > "$work/garbage.log"
expect_refusal "a non-base64 line inside the block" "$work/garbage.log"

bash "$saver" > /dev/null 2>&1
status=$?
if [[ $status -eq 2 ]]; then pass "usage error without a log"; else fail "usage error without a log (status=$status)"; fi
test "$failures" -eq 0
