#!/usr/bin/env bash
# Contract tests for tools/check-dependency-freshness using real local Git
# repositories as upstream remotes and sibling checkouts; no network.
set -u
root=$(cd -- "$(dirname -- "$0")/../.." && pwd) || exit 1
subject=$root/tools/check-dependency-freshness
work=$(mktemp -d "${TMPDIR:-/tmp}/jpegz-freshness.XXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT
export HOME=$work/home GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
mkdir -p "$HOME" "$work/remotes" || exit 1

# Upstream history c1 -> c2, published as a bare remote whose HEAD is c2.
git init -q -b yolo "$work/source" || exit 1
commit() { git -C "$work/source" commit -q --allow-empty -m "$1" && git -C "$work/source" rev-parse HEAD; }
c1=$(commit one) && c2=$(commit two) || exit 1
git clone -q --bare "$work/source" "$work/remotes/alpha.git" || exit 1
c3=$(commit three) || exit 1 # exists upstream source only, never in a sibling

failures=0
case_number=0
# run_case LABEL EXPECTED_STATUS EXPECTED_TEXT PIN REMOTE(up|down) SIBLING(none|c1|c2|c2-ahead|feature) [HOLDS] [ENV...]
run_case() {
	local label=$1 want=$2 text=$3 pin=$4 remote=$5 sibling=$6 holds=${7-}
	shift 7 2>/dev/null || shift $#
	case_number=$((case_number + 1))
	local parent=$work/case$case_number
	mkdir -p "$parent/project" || return 1
	printf '.{\n    .dependencies = .{\n        .alpha = .{\n            .url = "https://github.com/pmarreck/alpha/archive/%s.tar.gz",\n            .hash = "alpha-0",\n        },\n        .other = .{ .url = "https://example.invalid/x.tar.gz" },\n    },\n}\n' "$pin" > "$parent/project/build.zig.zon"
	case $sibling in
		none) ;;
		c1) git clone -q "$work/remotes/alpha.git" "$parent/alpha" && git -C "$parent/alpha" update-ref refs/remotes/origin/yolo "$c1" && git -C "$parent/alpha" reset -q --hard "$c1" ;;
		c2) git clone -q "$work/remotes/alpha.git" "$parent/alpha" ;;
		c2-ahead) git clone -q "$work/remotes/alpha.git" "$parent/alpha" && git -C "$parent/alpha" update-ref refs/remotes/origin/yolo "$c1" ;;
		feature) git clone -q "$work/remotes/alpha.git" "$parent/alpha" && git -C "$parent/alpha" checkout -q -b feature && git -C "$parent/alpha" commit -q --allow-empty -m feature ;;
	esac
	local base=$work/remotes/
	[ "$remote" = down ] && base=$work/unreachable/
	local args=(--manifest "$parent/project/build.zig.zon" --repo-root "$parent/project")
	if [ -n "$holds" ]; then
		printf '%s\n' "$holds" > "$parent/holds"
		args+=(--holds "$parent/holds")
	fi
	env JPEGZ_FRESHNESS_REMOTE_BASE="$base" "$@" bash "$subject" "${args[@]}" > "$parent/out" 2> "$parent/err"
	local status=$?
	if [ "$status" -eq "$want" ] && grep -q -- "$text" "$parent/err"; then
		printf '    ok %s\n' "$label"
	else
		printf '    FAIL %s (status=%s, want %s, text %s)\n' "$label" "$status" "$want" "$text" >&2
		cat "$parent/err" >&2
		failures=$((failures + 1))
	fi
}

run_case 'current pin passes against upstream' 0 'alpha current' "$c2" up none ''
run_case 'stale pin fails against upstream even when the sibling agrees with it' 1 'alpha is stale' "$c1" up c1 ''
run_case 'missing upstream and sibling fails closed' 1 'no readable sibling' "$c2" down none ''
run_case 'offline current pin passes against sibling origin/HEAD' 0 'alpha current' "$c2" down c2 ''
run_case 'offline stale pin fails against sibling' 1 'alpha is stale' "$c1" down c2 ''
run_case 'pin ahead of sibling passes' 0 'is ahead of sibling' "$c2" down c2-ahead ''
run_case 'sibling lacking the pinned commit fails closed' 1 'lacks pinned' "$c3" down c2 ''
run_case 'feature-branch sibling checkout reads origin/HEAD' 0 'alpha current' "$c2" down feature ''
run_case 'hold on the exact stale pin permits the build loudly' 0 'warning: dependency freshness: alpha held' "$c1" up none "alpha $c1 awaiting qualification"
run_case 'hold naming another commit fails' 1 'update or remove the hold' "$c1" up none "alpha $c2 obsolete hold"
run_case 'hold for an unknown dependency fails' 1 'not a pinned sibling dependency' "$c2" up none "beta $c1 stray hold"
run_case 'hold without a reason is a usage error' 2 'DEPENDENCY COMMIT REASON' "$c1" up none "alpha $c1"
run_case 'ALLOW_STALE permits a stale pin loudly' 0 'ALLOW_STALE permits' "$c1" up none '' ALLOW_STALE=1
run_case 'abbreviated pin fails' 1 'full lowercase 40-character commit' "${c2:0:12}" up none ''

if [ "$failures" -ne 0 ]; then
	printf 'dependency-freshness checks failed: %s\n' "$failures" >&2
	exit 1
fi
printf 'dependency-freshness checks passed\n'
