#!/usr/bin/env bash
# Record Nix adapter effects in a disposable project; never launch a compiler.
set -u
root=$(cd -- "$(dirname -- "$0")/../.." && pwd) || exit 1
work=$(mktemp -d "${TMPDIR:-/tmp}/jpegz-fuzz-cli.XXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/bin" "$work/project" || exit 1
cp "$root/fuzz" "$work/project/fuzz" || exit 1
{
	printf '#!%s\n' "$(command -v bash)"
	cat <<'EOF'
set -u
printf 'CALL\n' >> "$FAKE_NIX_LOG"
printf '%s\n' "$@" >> "$FAKE_NIX_LOG"
case ${1:-} in
	eval) printf 'x86_64-linux'; exit 0 ;;
	build) exit "${FAKE_NIX_STATUS:-0}" ;;
	*) exit 79 ;;
esac
EOF
} > "$work/bin/nix"
chmod +x "$work/bin/nix" || exit 1
failures=0
for selection in seeds campaign rebuild-seeds rebuild-campaign; do
	args=()
	target=checks.x86_64-linux.fuzz-seeds
	case $selection in
		campaign) args=(--fuzz); target=packages.x86_64-linux.fuzz-campaign ;;
		rebuild-seeds) args=(--rebuild) ;;
		rebuild-campaign) args=(--fuzz --rebuild); target=packages.x86_64-linux.fuzz-campaign ;;
	esac
	log=$work/$selection.log
	PATH="$work/bin:$PATH" FAKE_NIX_LOG=$log FUZZ_OPT=ReleaseSafe \
		bash "$work/project/fuzz" "${args[@]}" > "$work/$selection.out" 2> "$work/$selection.err"
	status=$?
	expected=$'CALL\neval\n--impure\n--raw\n--expr\nbuiltins.currentSystem\nCALL\nbuild\n'
	expected+="$work/project#$target"
	expected+=$'\n--no-link\n--print-build-logs'
	case $selection in rebuild-*) expected+=$'\n--rebuild' ;; esac
	actual=$(cat "$log")
	if [[ $status -eq 0 && $actual == "$expected" ]]; then
		printf '    ok fuzz selects the declared Nix artifact (%s)\n' "$selection"
	else
		printf '    FAIL fuzz selects the declared Nix artifact (%s, status=%s)\n' "$selection" "$status" >&2
		printf 'expected adapter effects:\n%s\nactual adapter effects:\n%s\n' "$expected" "$actual" >&2
		failures=$((failures+1))
	fi
done

# Classify the whole rejected argument set before any Nix effect.
for argument in --fuzz=120s --fuzz=0 --fuzz=10000 --unknown -j8; do
	log=$work/invalid.log
	: > "$log"
	PATH="$work/bin:$PATH" FAKE_NIX_LOG=$log FUZZ_OPT=ReleaseSafe \
		bash "$work/project/fuzz" "$argument" > "$work/invalid.out" 2> "$work/invalid.err"
	status=$?
	if [[ $status -eq 2 && ! -s $log ]]; then
		printf '    ok fuzz rejects unsupported arguments before Nix (%s)\n' "$argument"
	else
		printf '    FAIL fuzz rejects unsupported arguments before Nix (%s, status=%s)\n' "$argument" "$status" >&2
		failures=$((failures+1))
	fi
done

for optimize in Debug ReleaseFast ReleaseSmall; do
	log=$work/optimize.log
	: > "$log"
	PATH="$work/bin:$PATH" FAKE_NIX_LOG=$log FUZZ_OPT=$optimize \
		bash "$work/project/fuzz" > "$work/optimize.out" 2> "$work/optimize.err"
	status=$?
	if [[ $status -eq 2 && ! -s $log ]]; then
		printf '    ok fuzz refuses unqualified profiles (%s)\n' "$optimize"
	else
		printf '    FAIL fuzz refuses unqualified profiles (%s, status=%s)\n' "$optimize" "$status" >&2
		failures=$((failures+1))
	fi
done

log=$work/help.log
PATH="$work/bin:$PATH" FAKE_NIX_LOG=$log FUZZ_OPT=ReleaseSafe \
	bash "$work/project/fuzz" --help > "$work/help.out" 2> "$work/help.err"
status=$?
if [[ $status -eq 0 && ! -s $log ]] && grep -q '10000 iterations' "$work/help.out"; then
	printf '    ok fuzz help describes the bounded campaign without Nix\n'
else
	printf '    FAIL fuzz help describes the bounded campaign without Nix\n' >&2
	failures=$((failures+1))
fi

log=$work/failure.log
PATH="$work/bin:$PATH" FAKE_NIX_LOG=$log FAKE_NIX_STATUS=17 FUZZ_OPT=ReleaseSafe \
	bash "$work/project/fuzz" > "$work/failure.out" 2> "$work/failure.err"
status=$?
if [[ $status -eq 17 ]]; then
	printf '    ok fuzz preserves a failed Nix check status\n'
else
	printf '    FAIL fuzz preserves a failed Nix check status (status=%s)\n' "$status" >&2
	failures=$((failures+1))
fi
test "$failures" -eq 0
