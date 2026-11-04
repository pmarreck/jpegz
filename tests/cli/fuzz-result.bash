#!/usr/bin/env bash
# Pinned Zig records crashes independently of its top-level exit status.
set -u
root=$(cd -- "$(dirname -- "$0")/../.." && pwd) || exit 1
gate=$root/tools/check-fuzz-result
work=$(mktemp -d "${TMPDIR:-/tmp}/jpegz-fuzz-result.XXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT
failures=0
cases=0
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
	for driver_status in 0 1 17 124 126 127 134 255; do
		expected=$driver_status
		if [[ $driver_status -eq 0 ]]; then expected=$expected_zero; fi
		bash "$gate" "$driver_status" "$case_dir/cache" "$log" > "$case_dir/out" 2> "$case_dir/err"
		actual=$?
		cases=$((cases+1))
		if [[ $actual -ne $expected ]]; then
			printf '    FAIL fuzz result evidence=%s driver=%s expected=%s actual=%s\n' "$evidence" "$driver_status" "$expected" "$actual" >&2
			failures=$((failures+1))
		fi
	done
done
printf 'Fuzz result: %s cases, %s failures\n' "$cases" "$failures"
test "$failures" -eq 0
