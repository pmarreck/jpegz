#!/usr/bin/env bash
# Orchestration contract for ./corruption-coverage. The Wilson arithmetic lives
# in tools/coverage_stats.zig. This script checks that the driver refuses a bad
# fixture, keeps a no-op out of the rate, and does not call a crash a detection.
# Fakes stand in for jpegz and corruption-reader so the check has no network
# and no dependency on a built validator.

set -u

stats=${1:-}
root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
driver=$root/corruption-coverage
failures=0

ok() { echo "    ok $*"; }
bad() { echo "    FAIL $*" >&2; failures=$((failures + 1)); }

if [[ ! -x $driver ]]; then
	bad "corruption-coverage is executable"
else
	ok "corruption-coverage is executable"
fi

out=$(bash "$driver" --help 2>&1)
rc=$?
if [[ $rc -eq 0 && $out == *sniper* && $out == *Wilson* ]]; then
	ok "--help describes the profiles and the interval"
else
	bad "--help describes the profiles and the interval (rc=$rc)"
fi

bash "$driver" --rounds 0 >/dev/null 2>&1
rc=$?
if [[ $rc -eq 2 ]]; then
	ok "--rounds 0 is refused"
else
	bad "--rounds 0 is refused (rc=$rc)"
fi

if [[ -z $stats || ! -f $stats || ! -x $stats ]]; then
	bad "coverage stats binary was passed to this test"
	echo "$failures check(s) failed." >&2
	exit 1
fi
stats=$(realpath -- "$stats") || exit 1

work=$(mktemp -d "${TMPDIR:-/tmp}/jpegz-coverage-cli.XXXXXX") || exit 1
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

{
	printf '#!%s\n' "$(command -v bash)"
	cat <<'EOF'
set -u
if [[ ${1:-} == --about ]]; then
	echo "corruption-reader 0.7.0 test double"
	exit 0
fi
[[ ${1:-} == corrupt ]] || exit 2
if [[ -n ${FAKE_CR_LOG:-} ]]; then printf '%s\n' "$*" >> "$FAKE_CR_LOG"; fi
shift
profile=$1
shift
count= tmp= report=
while [[ $# -gt 0 ]]; do
	case "$1" in
		--master|--round|--emit|--ext) shift 2 ;;
		--count) count=$2; shift 2 ;;
		--tmp-dir) tmp=$2; shift 2 ;;
		--report) report=$2; shift 2 ;;
		--omit-noop) shift ;;
		*) shift ;;
	esac
done
mkdir -p "$tmp"
: > "$report"
i=0
while [[ $i -lt $count ]]; do
	case $i in
		0)
			path=$tmp/r0.bin
			printf 'CORRUPT' > "$path"
			printf '%s\n' "{\"report\":1,\"item\":$i,\"round\":$i,\"status\":\"applied\",\"noop\":null,\"emitted\":true,\"path\":\"$path\",\"record\":{}}" >> "$report"
			printf '%s\n' "$path"
			;;
		1)
			path=$tmp/r1.bin
			printf 'VALID' > "$path"
			printf '%s\n' "{\"report\":1,\"item\":$i,\"round\":$i,\"status\":\"applied\",\"noop\":null,\"emitted\":true,\"path\":\"$path\",\"record\":{}}" >> "$report"
			printf '%s\n' "$path"
			;;
		2)
			printf '%s\n' "{\"report\":1,\"item\":$i,\"round\":$i,\"status\":\"noop\",\"noop\":\"too_small\",\"emitted\":false,\"path\":null,\"record\":{}}" >> "$report"
			;;
		*)
			path=$tmp/r$i.bin
			printf 'CRASH' > "$path"
			printf '%s\n' "{\"report\":1,\"item\":$i,\"round\":$i,\"status\":\"applied\",\"noop\":null,\"emitted\":true,\"path\":\"$path\",\"record\":{}}" >> "$report"
			printf '%s\n' "$path"
			;;
	esac
	i=$((i + 1))
done
exit 3
EOF
} > "$work/cr"

{
	printf '#!%s\n' "$(command -v bash)"
	cat <<'EOF'
set -u
if [[ ${1:-} == --about ]]; then
	echo "jpegz test double"
	exit 0
fi
file=
for arg in "$@"; do
	case $arg in
		--json|--no-color) ;;
		*) file=$arg ;;
	esac
done
body=$(cat -- "$file" 2>/dev/null || true)
case $body in
	CORRUPT*)
		printf '%s\n' '{"verdict":"corrupt"}'
		exit 1
		;;
	VALID*)
		printf '%s\n' '{"verdict":"valid"}'
		exit 0
		;;
	CRASH*)
		exit 139
		;;
	*)
		if [[ ${FAKE_JPEGZ_PRISTINE:-valid} == corrupt ]]; then
			printf '%s\n' '{"verdict":"corrupt"}'
			exit 1
		fi
		printf '%s\n' '{"verdict":"valid"}'
		exit 0
		;;
esac
EOF
} > "$work/jpegz"
chmod +x "$work/cr" "$work/jpegz"

fixture=$root/tests/unit/fixtures/baseline_2x2_rgb.jpg
out=$work/out
mkdir -p "$out"

JPEGZ=$work/jpegz CORRUPTION_READER=$work/cr JPEGZ_COVERAGE_STATS=$stats \
	bash "$driver" --rounds 4 --profiles sniper --jobs 1 --out-dir "$out" "$fixture" > "$work/table.txt" 2> "$work/err.txt"
rc=$?
summary=$out/corruption_coverage.ndjson
if [[ $rc -eq 1 && -f $summary ]] \
	&& grep -q '"detected":1' "$summary" \
	&& grep -q '"judged":2' "$summary" \
	&& grep -q '"noop":1' "$summary" \
	&& grep -q '"crash":1' "$summary" \
	&& grep -q '"accepted":1' "$summary"; then
	ok "crash and no-op stay out of the judged rate"
else
	bad "crash and no-op stay out of the judged rate (rc=$rc)"
	sed -n '1,40p' "$work/table.txt" >&2
	sed -n '1,20p' "$summary" >&2
	sed -n '1,20p' "$work/err.txt" >&2
fi

if grep -q '50.0% \[' "$work/table.txt"; then
	ok "table shows the 1/2 Wilson interval"
else
	bad "table shows the 1/2 Wilson interval"
	sed -n '1,20p' "$work/table.txt" >&2
fi

# Compare complete requested profile sets, including an explicit fixed-count
# profile, so the variable default cannot silently rewrite a caller's choice.
for selection in default explicit; do
	profile_args=()
	case $selection in
		default) expected_profiles=$'sniper\nbolter\nshotgun_variable\nnuke' ;;
		explicit)
			profile_args=(--profiles shotgun,nuke,shotgun_variable)
			expected_profiles=$'shotgun\nnuke\nshotgun_variable'
			;;
	esac
	profile_log=$work/profiles-$selection.log
	FAKE_CR_LOG=$profile_log JPEGZ=$work/jpegz CORRUPTION_READER=$work/cr JPEGZ_COVERAGE_STATS=$stats \
		bash "$driver" --rounds 1 --jobs 1 "${profile_args[@]}" --out-dir "$work/profiles-$selection" "$fixture" \
		> "$work/profiles-$selection.out" 2> "$work/profiles-$selection.err"
	rc=$?
	actual_profiles=$(awk '{print $2}' "$profile_log")
	if [[ $rc -eq 0 && $actual_profiles == "$expected_profiles" ]]; then
		ok "mutation profile selection preserves the declared set ($selection)"
	else
		bad "mutation profile selection preserves the declared set ($selection, rc=$rc)"
		printf 'expected profiles:\n%s\nactual profiles:\n%s\n' "$expected_profiles" "$actual_profiles" >&2
	fi
done

FAKE_JPEGZ_PRISTINE=corrupt JPEGZ=$work/jpegz CORRUPTION_READER=$work/cr JPEGZ_COVERAGE_STATS=$stats \
	bash "$driver" --rounds 1 --profiles sniper --out-dir "$work/bad" "$fixture" > "$work/bad-out.txt" 2> "$work/bad-err.txt"
rc=$?
if [[ $rc -eq 2 ]] && grep -q 'not known-good' "$work/bad-err.txt"; then
	ok "a fixture jpegz already calls corrupt is refused"
else
	bad "a fixture jpegz already calls corrupt is refused (rc=$rc)"
fi

# Exercise default preparation in a disposable project. A stale legacy output
# must not bypass the Nix artifact, and a directory is not an executable file.
project=$work/project
mkdir -p "$project/zig-out/bin" "$work/fake-bin" || exit 1
cp "$driver" "$project/corruption-coverage" || exit 1
printf '#!%s\nexit 99\n' "$(command -v bash)" > "$project/zig-out/bin/jpegz-coverage-stats"
chmod +x "$project/zig-out/bin/jpegz-coverage-stats"
{
	printf '#!%s\n' "$(command -v bash)"
	cat <<'EOF'
set -u
printf '%s\n' "$@" > "$FAKE_NIX_LOG"
if [[ $FAKE_NIX_STATUS -ne 0 ]]; then exit "$FAKE_NIX_STATUS"; fi
printf '%s\n' "$FAKE_NIX_OUTPUT"
EOF
} > "$work/fake-bin/nix"
chmod +x "$work/fake-bin/nix"
for kind in file symlink directory nonexec missing build_error; do
	package=$work/package-$kind
	mkdir -p "$package/bin" || exit 1
	case $kind in
		file) cp "$stats" "$package/bin/jpegz-coverage-stats" ;;
		symlink) ln -s "$stats" "$package/bin/jpegz-coverage-stats" ;;
		directory) mkdir "$package/bin/jpegz-coverage-stats" ;;
		nonexec) printf 'not executable\n' > "$package/bin/jpegz-coverage-stats" ;;
	esac
	setup_status=$?
	[[ $setup_status -eq 0 ]] || exit 1
	nix_status=0
	[[ $kind != build_error ]] || nix_status=77
	log=$work/nix-$kind.log
	cr_log=$work/cr-$kind.log
	PATH="$work/fake-bin:$PATH" FAKE_NIX_LOG=$log FAKE_NIX_OUTPUT=$package FAKE_NIX_STATUS=$nix_status \
		FAKE_CR_LOG=$cr_log JPEGZ_COVERAGE_INNER=1 JPEGZ=$work/jpegz CORRUPTION_READER=$work/cr JPEGZ_COVERAGE_STATS= \
		bash "$project/corruption-coverage" --rounds 1 --profiles sniper --out-dir "$work/bootstrap-$kind" "$fixture" \
		> "$work/bootstrap-$kind.out" 2> "$work/bootstrap-$kind.err"
	rc=$?
	expected=2
	case $kind in file|symlink) expected=0 ;; esac
	args=()
	if [[ -f $log ]]; then mapfile -t args < "$log"; fi
	effects_ok=0
	if [[ $expected -eq 0 && -s $cr_log ]] && grep -q '"judged":1' "$work/bootstrap-$kind/corruption_coverage.ndjson"; then
		effects_ok=1
	elif [[ $expected -eq 2 && ! -e $cr_log ]]; then
		effects_ok=1
	fi
	if [[ $rc -eq $expected && ${#args[@]} -eq 4 \
		&& ${args[0]:-} == build && ${args[1]:-} == "$project#coverage-stats" \
		&& ${args[2]:-} == --no-link && ${args[3]:-} == --print-out-paths && $effects_ok -eq 1 ]]; then
		ok "default stats preparation uses the Nix artifact ($kind)"
	else
		bad "default stats preparation uses the Nix artifact ($kind, rc=$rc)"
	fi
done

if [[ $failures -eq 0 ]]; then
	echo "corruption-coverage checks passed."
	exit 0
fi
echo "$failures corruption-coverage check(s) failed." >&2
exit 1
