#!/usr/bin/env bash
# Pinned Zig records crashes independently of its top-level exit status.
set -u
root=$(cd -- "$(dirname -- "$0")/../.." && pwd) || exit 1
gate=$root/tools/check-fuzz-result
work=$(mktemp -d "${TMPDIR:-/tmp}/jpegz-fuzz-result.XXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT
failures=0
cases=0
seed=0x0000abcd
for evidence in clean unrelated crash empty directory dangling diagnostic ansi-diagnostic failed-command missing-cache missing-log; do
	case_dir=$work/$evidence
	mkdir -p "$case_dir/cache/f" || exit 1
	log=$case_dir/driver.log
	printf '======= FUZZING REPORT =======\n' > "$log" || exit 1
	expected_zero=1
	case $evidence in
		clean) expected_zero=0 ;;
		unrelated)
			printf 'quoted diagnostic: error: payload text\n' >> "$log"
			printf 'seed input\n' > "$case_dir/cache/f/in0"
			expected_zero=0
			;;
		crash) printf 'Smith input\n' > "$case_dir/cache/f/crash" ;;
		empty) : > "$case_dir/cache/f/crash" ;;
		directory) mkdir "$case_dir/cache/f/crash" ;;
		dangling) ln -s missing-input "$case_dir/cache/f/crash" ;;
		diagnostic)
			printf "error: test 'decode_fuzz.test.fuzz: jpegz.decode never panics or leaks' terminated with signal ABRT; input saved to '.zig-cache/f/crash'\n" >> "$log"
			;;
		ansi-diagnostic)
			printf '\033[31merror:\033[0m test terminated with signal ABRT\n' >> "$log"
			;;
		failed-command) printf 'failed command: ./decode_fuzz --listen=-\n' >> "$log" ;;
		missing-cache) rmdir "$case_dir/cache/f" "$case_dir/cache" ;;
		missing-log) mv "$log" "$case_dir/unavailable.log" ;;
	esac
	setup_status=$?
	test "$setup_status" -eq 0 || exit 1
	for seed_args in '' "$seed"; do
		for driver_status in 0 1 17 124 126 127 134 255; do
			expected=$driver_status
			if [[ $driver_status -eq 0 ]]; then expected=$expected_zero; fi
			# shellcheck disable=SC2086
			bash "$gate" "$driver_status" "$case_dir/cache" "$log" $seed_args > "$case_dir/out" 2> "$case_dir/err"
			actual=$?
			cases=$((cases+1))
			reported=0
			grep -qF "failed with seed $seed; reproduce with: ./fuzz --fuzz --seed $seed" "$case_dir/err" && reported=1
			want_report=0
			[[ -n $seed_args && $expected -ne 0 ]] && want_report=1
			if [[ $actual -ne $expected || $reported -ne $want_report ]]; then
				printf '    FAIL fuzz result evidence=%s driver=%s seed=%s expected=%s/%s actual=%s/%s\n' \
					"$evidence" "$driver_status" "${seed_args:-none}" "$expected" "$want_report" "$actual" "$reported" >&2
				failures=$((failures+1))
			fi
		done
	done
done

# The printed crash input must decode to the exact saved bytes.
check_crash_print() { # NAME SIZE EXPECT_PRINTED
	local case_dir=$work/print-$1
	mkdir -p "$case_dir/cache/f" || exit 1
	printf 'log\n' > "$case_dir/driver.log"
	head -c "$2" /dev/urandom > "$case_dir/cache/f/crash" || exit 1
	bash "$gate" 0 "$case_dir/cache" "$case_dir/driver.log" "$seed" > "$case_dir/out" 2> "$case_dir/err"
	local status=$? printed=0
	sed -n '/crash input, .* base64:$/,/^fuzz-check: end of crash input$/p' "$case_dir/err" | sed '1d;$d' |
		base64 -d > "$case_dir/decoded" 2>/dev/null && cmp -s "$case_dir/decoded" "$case_dir/cache/f/crash" && printed=1
	cases=$((cases+1))
	if [[ $status -eq 1 && $printed -eq $3 ]] && { [[ $3 -eq 1 ]] || grep -q 'over the 65536-byte print limit' "$case_dir/err"; }; then
		:
	else
		printf '    FAIL fuzz result crash print %s: status=%s printed=%s want=%s\n' "$1" "$status" "$printed" "$3" >&2
		failures=$((failures+1))
	fi
}
check_crash_print small 286 1
check_crash_print limit 65536 1
check_crash_print oversize 65537 0

# Seedless calls never print crash bytes; malformed seeds and arity are usage errors.
case_dir=$work/crash
bash "$gate" 1 "$case_dir/cache" "$case_dir/driver.log" > /dev/null 2> "$work/seedless.err"
cases=$((cases+1))
if grep -q -e 'base64' -e 'reproduce' "$work/seedless.err"; then
	printf '    FAIL fuzz result seedless call printed reproduction data\n' >&2
	failures=$((failures+1))
fi
for bad in 0xABCD0000 0x123 6a706567 '0x0000abcd extra'; do
	# shellcheck disable=SC2086
	bash "$gate" 0 "$work/clean/cache" "$work/clean/driver.log" $bad > /dev/null 2>&1
	status=$?
	cases=$((cases+1))
	if [[ $status -ne 2 ]]; then
		printf '    FAIL fuzz result accepted malformed seed arguments (%s): status=%s\n' "$bad" "$status" >&2
		failures=$((failures+1))
	fi
done
printf 'Fuzz result: %s cases, %s failures\n' "$cases" "$failures"
test "$failures" -eq 0
