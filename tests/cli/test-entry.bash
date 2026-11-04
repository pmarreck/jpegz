#!/usr/bin/env bash
# The ./test entry point must not publish Nix result links into the checkout.
# Run a copy in a disposable project whose stub nix records every call and,
# like real nix build, replaces ./result unless --no-link is given.
set -u
root=$(cd -- "$(dirname -- "$0")/../.." && pwd) || exit 1
work=$(mktemp -d "${TMPDIR:-/tmp}/jpegz-test-entry.XXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/bin" "$work/project" "$work/store" "$work/store/bin" || exit 1
cp "$root/test" "$work/project/test" || exit 1
printf '#!/bin/sh\nexit 0\n' > "$work/store/bin/jpegz-coverage-stats"
chmod +x "$work/store/bin/jpegz-coverage-stats" || exit 1
ln -s sentinel-target "$work/project/result" || exit 1
{
	printf '#!%s\n' "$(command -v bash)"
	cat <<'EOF'
set -u
printf 'CALL' >> "$FAKE_NIX_LOG"
printf ' %s' "$@" >> "$FAKE_NIX_LOG"
printf '\n' >> "$FAKE_NIX_LOG"
case ${1:-} in
	eval)
		case " $* " in
			*" builtins.currentSystem "*) printf 'x86_64-linux' ;;
			*) printf 'Package metadata evaluated.\n' ;;
		esac
		exit 0 ;;
	build)
		link=1
		for argument in "$@"; do [[ $argument == --no-link ]] && link=0; done
		if [[ $link -eq 1 ]]; then rm -f result && ln -s "$FAKE_NIX_STORE" result; fi
		for argument in "$@"; do [[ $argument == --print-out-paths ]] && printf '%s\n' "$FAKE_NIX_STORE"; done
		exit 0 ;;
	*) exit 79 ;;
esac
EOF
} > "$work/bin/nix"
chmod +x "$work/bin/nix" || exit 1

failures=0
log=$work/nix.log
(cd "$work/project" && PATH="$work/bin:$PATH" FAKE_NIX_LOG=$log FAKE_NIX_STORE=$work/store \
	bash ./test > "$work/out" 2> "$work/err")
status=$?

builds=$(grep -c '^CALL build ' "$log")
linked=$(grep '^CALL build ' "$log" | grep -v -e ' --no-link$' -e ' --no-link ')
if [[ $status -eq 0 && $builds -ge 13 ]]; then
	printf '    ok test runs every declared Nix build (%s calls)\n' "$builds"
else
	printf '    FAIL test runs every declared Nix build (status=%s, builds=%s)\n' "$status" "$builds" >&2
	cat "$work/out" "$work/err" >&2
	failures=$((failures+1))
fi
if [[ -z $linked ]]; then
	printf '    ok every test Nix build passes --no-link\n'
else
	printf '    FAIL test Nix builds without --no-link:\n%s\n' "$linked" >&2
	failures=$((failures+1))
fi
if [[ $(readlink "$work/project/result") == sentinel-target ]]; then
	printf '    ok test leaves an existing result link unchanged\n'
else
	printf '    FAIL test replaced the result link with %s\n' "$(readlink "$work/project/result")" >&2
	failures=$((failures+1))
fi

if [[ $failures -ne 0 ]]; then
	printf 'test-entry checks failed: %s\n' "$failures" >&2
	exit 1
fi
printf 'test-entry checks passed\n'
