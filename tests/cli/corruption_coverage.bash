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

if [[ -z $stats || ! -x $stats ]]; then
	bad "coverage stats binary was passed to this test"
	echo "$failures check(s) failed." >&2
	exit 1
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/jpegz-coverage-cli.XXXXXX")
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

FAKE_JPEGZ_PRISTINE=corrupt JPEGZ=$work/jpegz CORRUPTION_READER=$work/cr JPEGZ_COVERAGE_STATS=$stats \
	bash "$driver" --rounds 1 --profiles sniper --out-dir "$work/bad" "$fixture" > "$work/bad-out.txt" 2> "$work/bad-err.txt"
rc=$?
if [[ $rc -eq 2 ]] && grep -q 'not known-good' "$work/bad-err.txt"; then
	ok "a fixture jpegz already calls corrupt is refused"
else
	bad "a fixture jpegz already calls corrupt is refused (rc=$rc)"
fi

if [[ $failures -eq 0 ]]; then
	echo "corruption-coverage checks passed."
	exit 0
fi
echo "$failures corruption-coverage check(s) failed." >&2
exit 1
