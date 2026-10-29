#!/usr/bin/env bash
# Source classification and derivation identity checks use test-owned trees/store.
set -u
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd) || exit 1
: "${JPEGZ_TEST_NIXPKGS_LIB:?Nixpkgs lib must be supplied by the check}"
work=$(mktemp -d "${TMPDIR:-/tmp}/jpegz-source.XXXXXX") || exit 1
cleanup() {
	local status=$?
	trap - EXIT
	# Nix makes this test-owned store read-only; never touch the host store.
	if [[ -d $work/store ]]; then chmod -R u+w -- "$work/store" || status=1; fi
	rm -rf -- "$work" || status=1
	exit "$status"
}
trap cleanup EXIT
base=$work/fixtures/baseline
mkdir -p "$base/src/docs" "$base/tests/unit/fixtures" "$base/tests/cli" \
	"$base/include" "$base/tools" "$base/deps" "$base/scratch" \
	"$base/docs" "$base/.mechatron-prime" "$base/.git" "$base/data.md" || exit 1
retained=(
	.future-config COPYING.md LICENSE LICENSE.md LICENSING_NOTES.md NOTICE.md THIRD_PARTY_NOTICES.md
	build.zig build.zig.zon data.md/keep.bin deps/vendor.c flake.lock flake.nix include/api.h scratch/check.zig
	src/docs/nested.md src/main.zig tests/cli/check tests/unit/fixtures/image.bin
	tests/unit/fixtures/readme.md tools/tool
)
for path in "${retained[@]}" README.md AGENTS.md PLAN.md docs/note.md .dirtree-state .mechatron-prime/targets .git/config; do
	printf 'original\n' > "$base/$path" || exit 1
done
ln -s main.zig "$base/src/alias.zig" || exit 1
copy_case() {
	mkdir -p "$work/fixtures/$1" && cp -a "$base/." "$work/fixtures/$1"
}
for name in 'relocated project' documentation metadata future; do copy_case "$name" || exit 1; done
for path in README.md PLAN.md docs/note.md; do
	printf 'changed\n' > "$work/fixtures/documentation/$path" || exit 1
done
printf 'new documentation\n' > "$work/fixtures/documentation/docs/new.md" || exit 1
for path in .dirtree-state .mechatron-prime/targets .git/config; do
	printf 'changed\n' > "$work/fixtures/metadata/$path" || exit 1
done
mkdir -p "$work/fixtures/future/future-component" || exit 1
printf 'future input\n' > "$work/fixtures/future/future-component/data" || exit 1
required=(src/main.zig build.zig build.zig.zon tests/unit/fixtures/image.bin tests/unit/fixtures/readme.md
	include/api.h tools/tool deps/vendor.c scratch/check.zig flake.nix LICENSE.md)
index=0
for path in "${required[@]}"; do
	copy_case "required-$index" || exit 1
	printf 'changed\n' > "$work/fixtures/required-$index/$path" || exit 1
	index=$((index + 1))
done
JPEGZ_SOURCE_FIXTURE_ROOT=$work/fixtures JPEGZ_SOURCE_MODULE=$repo/nix/source.nix \
	nix --extra-experimental-features nix-command --store "local?root=$work/store" \
	eval --impure --json --file "$repo/tests/nix/source.nix" --apply 'f: f {
		libPath = builtins.getEnv "JPEGZ_TEST_NIXPKGS_LIB";
		fixtureRoot = builtins.getEnv "JPEGZ_SOURCE_FIXTURE_ROOT";
		sourceModule = builtins.getEnv "JPEGZ_SOURCE_MODULE";
	}' > "$work/result.json" 2> "$work/err"
status=$?
if [[ $status -ne 0 ]]; then cat "$work/err" >&2; exit 1; fi
jq -r '.[] | (if .passed then "ok " else "FAIL " end) + .name' "$work/result.json"
jq -e 'length == 18 and all(.[]; .passed == true)' "$work/result.json" >/dev/null
