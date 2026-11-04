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
pass() { printf '    ok %s\n' "$1"; }
fail() { printf '    FAIL %s\n' "$1" >&2; failures=$((failures+1)); }
run_fuzz() { # NAME ARGS...; leaves $status, $work/NAME.{log,out,err}
	local name=$1; shift
	: > "$work/$name.log"
	PATH="$work/bin:$PATH" FAKE_NIX_LOG=$work/$name.log FUZZ_OPT=${FUZZ_OPT_UNDER_TEST:-ReleaseSafe} \
		bash "$work/project/fuzz" "$@" > "$work/$name.out" 2> "$work/$name.err"
	status=$?
}
eval_call=$'CALL\neval\n--impure\n--raw\n--expr\nbuiltins.currentSystem\n'
campaign_expr() {
	printf '(builtins.getFlake "%s").legacyPackages.x86_64-linux.fuzzCampaign "%s"' "$work/project" "$1"
}

for selection in seeds rebuild-seeds; do
	args=()
	[[ $selection == rebuild-seeds ]] && args=(--rebuild)
	run_fuzz "$selection" "${args[@]}"
	expected=$eval_call$'CALL\nbuild\n'"$work/project#checks.x86_64-linux.fuzz-seeds"$'\n--no-link\n--print-build-logs'
	[[ $selection == rebuild-seeds ]] && expected+=$'\n--rebuild'
	if [[ $status -eq 0 && $(cat "$work/$selection.log") == "$expected" ]]; then
		pass "fuzz replays the fixed seed corpus ($selection)"
	else
		fail "fuzz replays the fixed seed corpus ($selection, status=$status)"
		printf 'expected:\n%s\nactual:\n%s\n' "$expected" "$(cat "$work/$selection.log")" >&2
	fi
done

# An explicit seed is normalized to eight lowercase hex digits.
for form in '--seed 0xABCD' '--seed=0x0000abcd' '--seed 0XaBcD'; do
	read -r -a seed_args <<< "$form"
	for rebuild in no yes; do
		args=(--fuzz "${seed_args[@]}")
		[[ $rebuild == yes ]] && args+=(--rebuild)
		run_fuzz explicit "${args[@]}"
		expected=$eval_call$'CALL\nbuild\n--impure\n--expr\n'"$(campaign_expr 0x0000abcd)"$'\n--no-link\n--print-build-logs'
		[[ $rebuild == yes ]] && expected+=$'\n--rebuild'
		if [[ $status -eq 0 && $(cat "$work/explicit.log") == "$expected" ]] &&
			grep -qF 'campaign seed 0x0000abcd (reproduce with: ./fuzz --fuzz --seed 0x0000abcd)' "$work/explicit.err"; then
			pass "fuzz campaign uses and announces an explicit seed ($form, rebuild=$rebuild)"
		else
			fail "fuzz campaign uses and announces an explicit seed ($form, rebuild=$rebuild, status=$status)"
			printf 'expected:\n%s\nactual:\n%s\nstderr:\n%s\n' "$expected" "$(cat "$work/explicit.log")" "$(cat "$work/explicit.err")" >&2
		fi
	done
done

# Without --seed each campaign draws a fresh seed, announces it and builds it.
seeds=()
random_ok=1
for attempt in 1 2 3; do
	run_fuzz random --fuzz
	announced=$(sed -n 's/^fuzz: campaign seed \(0x[0-9a-f]\{8\}\) (reproduce with: \.\/fuzz --fuzz --seed \1)$/\1/p' "$work/random.err")
	if [[ $status -ne 0 || ! $announced =~ ^0x[0-9a-f]{8}$ ]]; then random_ok=0; break; fi
	expected=$eval_call$'CALL\nbuild\n--impure\n--expr\n'"$(campaign_expr "$announced")"$'\n--no-link\n--print-build-logs'
	[[ $(cat "$work/random.log") == "$expected" ]] || { random_ok=0; break; }
	seeds+=("$announced")
done
if [[ $random_ok -eq 1 && ${#seeds[@]} -eq 3 ]] &&
	! [[ ${seeds[0]} == "${seeds[1]}" && ${seeds[1]} == "${seeds[2]}" ]]; then
	pass "fuzz campaign builds the random seed it announces (${seeds[*]})"
else
	fail "fuzz campaign builds the random seed it announces (status=$status, seeds=${seeds[*]:-none})"
	cat "$work/random.err" "$work/random.log" >&2
fi

# A failed campaign keeps the Nix status and repeats the reproduction seed.
FAKE_NIX_STATUS=17 run_fuzz failed-campaign --fuzz --seed 0x1
if [[ $status -eq 17 ]] && grep -qF 'campaign failed with seed 0x00000001; reproduce with: ./fuzz --fuzz --seed 0x00000001' "$work/failed-campaign.err"; then
	pass "fuzz reports the reproduction seed when a campaign fails"
else
	fail "fuzz reports the reproduction seed when a campaign fails (status=$status)"
	cat "$work/failed-campaign.err" >&2
fi
FAKE_NIX_STATUS=17 run_fuzz failed-seeds
if [[ $status -eq 17 ]]; then
	pass "fuzz preserves a failed Nix check status"
else
	fail "fuzz preserves a failed Nix check status (status=$status)"
fi

# Classify the whole rejected argument set before any Nix effect.
for argument_set in --fuzz=120s --fuzz=0 --fuzz=10000 --unknown -j8 '--seed 0x1' '--fuzz --seed' \
	'--fuzz --seed=123' '--fuzz --seed=0x' '--fuzz --seed=0x123456789' '--fuzz --seed=0xg1' '--fuzz --seed=-0x1'; do
	read -r -a args <<< "$argument_set"
	run_fuzz invalid "${args[@]}"
	if [[ $status -eq 2 && ! -s $work/invalid.log ]]; then
		pass "fuzz rejects unsupported arguments before Nix ($argument_set)"
	else
		fail "fuzz rejects unsupported arguments before Nix ($argument_set, status=$status)"
	fi
done

for optimize in Debug ReleaseFast ReleaseSmall; do
	FUZZ_OPT_UNDER_TEST=$optimize run_fuzz optimize
	if [[ $status -eq 2 && ! -s $work/optimize.log ]]; then
		pass "fuzz refuses unqualified profiles ($optimize)"
	else
		fail "fuzz refuses unqualified profiles ($optimize, status=$status)"
	fi
done

run_fuzz help --help
if [[ $status -eq 0 && ! -s $work/help.log ]] && grep -q '10000 iterations' "$work/help.out" &&
	grep -q 'random 32-bit seed' "$work/help.out" && grep -q -- '--seed 0xHEX' "$work/help.out"; then
	pass "fuzz help describes the random-seed bounded campaign without Nix"
else
	fail "fuzz help describes the random-seed bounded campaign without Nix"
fi
test "$failures" -eq 0
