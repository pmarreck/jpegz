#!/usr/bin/env bash
# The dev shell seeds private libjxlz with `zig fetch`. Zig 0.16 rewrites the
# global-cache archive on every fetch, even when the bytes are unchanged, so
# a second entry must not call zig when the pinned archive is already there.

set -u

root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
seeder=$root/tools/seed-libjxlz-cache
failures=0

ok() { echo "    ok $*"; }
bad() { echo "    FAIL $*" >&2; failures=$((failures + 1)); }

if [[ ! -x $seeder ]]; then
	bad "seed-libjxlz-cache is executable"
	echo "$failures check(s) failed." >&2
	exit 1
fi
ok "seed-libjxlz-cache is executable"

hash=libjxlz-0.1.0-H-testonlyseedcache
work=$(mktemp -d "${TMPDIR:-/tmp}/jpegz-seed-cache.XXXXXX")
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

mkdir -p "$work/bin" "$work/proj"
cat >"$work/proj/build.zig.zon" <<EOF
.{
    .dependencies = .{
        .jp2z = .{ .hash = "jp2z-0.0.1-NOT-THE-LIBJXLZ-PIN" },
        .libjxlz = .{
            .hash = "$hash",
        },
    },
}
EOF

cat >"$work/bin/zig" <<EOF
#!$(command -v bash)
set -u
printf '%s\n' "\$*" >> "\$FAKE_ZIG_LOG"
if [[ \${FAKE_ZIG_RC:-0} -ne 0 ]]; then
	exit "\$FAKE_ZIG_RC"
fi
printed=\${FAKE_ZIG_HASH:-$hash}
if [[ -n \${ZIG_GLOBAL_CACHE_DIR:-} ]]; then
	cache=\$ZIG_GLOBAL_CACHE_DIR
elif [[ -n \${XDG_CACHE_HOME:-} ]]; then
	cache=\$XDG_CACHE_HOME/zig
else
	cache=\$HOME/.cache/zig
fi
mkdir -p "\$cache/p"
if [[ \${FAKE_ZIG_SKIP_ARCHIVE:-0} -eq 0 ]]; then
	printf 'pkg\n' > "\$cache/p/\$printed.tar.gz"
fi
printf '%s\n' "\$printed"
EOF
chmod +x "$work/bin/zig"

# "-" leaves that cache variable unset. The parent shell may already export
# both, so unset first and then set only the ones this case is testing.
seed() {
	local global=$1 xdg=$2
	local -a envargs=(
		env -u ZIG_GLOBAL_CACHE_DIR -u XDG_CACHE_HOME
		PATH="$work/bin:$PATH"
		FAKE_ZIG_LOG="$work/zig.log"
		HOME="$work/home"
		FAKE_ZIG_RC="${FAKE_ZIG_RC:-0}"
		FAKE_ZIG_HASH="${FAKE_ZIG_HASH:-$hash}"
		FAKE_ZIG_SKIP_ARCHIVE="${FAKE_ZIG_SKIP_ARCHIVE:-0}"
	)
	if [[ $global != - ]]; then
		envargs+=(ZIG_GLOBAL_CACHE_DIR="$global")
	fi
	if [[ $xdg != - ]]; then
		envargs+=(XDG_CACHE_HOME="$xdg")
	fi
	"${envargs[@]}" bash "$seeder" "$work/source-tree" "$work/proj/build.zig.zon"
}

: >"$work/zig.log"
mkdir -p "$work/source-tree" "$work/home"
FAKE_ZIG_RC=0
FAKE_ZIG_HASH=$hash
FAKE_ZIG_SKIP_ARCHIVE=0

seed "$work/cache" -
rc=$?
calls=$(wc -l <"$work/zig.log")
if [[ $rc -eq 0 && $calls -eq 1 && -s $work/cache/p/$hash.tar.gz ]]; then
	ok "missing archive fetches once"
else
	bad "missing archive fetches once (rc=$rc calls=$calls)"
fi

if [[ $(cat "$work/zig.log") == "fetch $work/source-tree" ]]; then
	ok "fetch receives the Nix source path"
else
	bad "fetch receives the Nix source path ($(cat "$work/zig.log"))"
fi

: >"$work/zig.log"
seed "$work/cache" -
rc=$?
calls=$(wc -l <"$work/zig.log")
if [[ $rc -eq 0 && $calls -eq 0 ]]; then
	ok "existing archive does not call zig"
else
	bad "existing archive does not call zig (rc=$rc calls=$calls)"
fi

rm -f "$work/cache/p/$hash.tar.gz"
rm -rf "$work/cache/p/$hash"
mkdir -p "$work/cache/p/$hash"
: >"$work/zig.log"
seed "$work/cache" -
rc=$?
calls=$(wc -l <"$work/zig.log")
if [[ $rc -eq 0 && $calls -eq 1 ]]; then
	ok "empty cache directory is fetched again"
else
	bad "empty cache directory is fetched again (rc=$rc calls=$calls)"
fi

rm -rf "$work/cache/p/$hash"
rm -f "$work/cache/p/$hash.tar.gz"
mkdir -p "$work/cache/p/$hash"
printf 'unpacked\n' >"$work/cache/p/$hash/build.zig.zon"
: >"$work/zig.log"
seed "$work/cache" -
rc=$?
calls=$(wc -l <"$work/zig.log")
if [[ $rc -eq 0 && $calls -eq 0 ]]; then
	ok "unpacked cache directory does not call zig"
else
	bad "unpacked cache directory does not call zig (rc=$rc calls=$calls)"
fi

rm -rf "$work/cache/p/$hash"
: >"$work/cache/p/$hash.tar.gz"
: >"$work/zig.log"
seed "$work/cache" -
rc=$?
calls=$(wc -l <"$work/zig.log")
if [[ $rc -eq 0 && $calls -eq 1 && -s $work/cache/p/$hash.tar.gz ]]; then
	ok "empty archive is fetched again"
else
	bad "empty archive is fetched again (rc=$rc calls=$calls)"
fi

rm -rf "$work/xdg-cache"
mkdir -p "$work/xdg-cache/zig/p"
printf 'pkg\n' >"$work/xdg-cache/zig/p/$hash.tar.gz"
: >"$work/zig.log"
seed - "$work/xdg-cache"
rc=$?
calls=$(wc -l <"$work/zig.log")
if [[ $rc -eq 0 && $calls -eq 0 ]]; then
	ok "XDG_CACHE_HOME/zig is used when the global dir is unset"
else
	bad "XDG_CACHE_HOME/zig is used when the global dir is unset (rc=$rc calls=$calls)"
fi

rm -rf "$work/home/.cache"
mkdir -p "$work/home/.cache/zig/p"
printf 'pkg\n' >"$work/home/.cache/zig/p/$hash.tar.gz"
: >"$work/zig.log"
seed - -
rc=$?
calls=$(wc -l <"$work/zig.log")
if [[ $rc -eq 0 && $calls -eq 0 ]]; then
	ok "HOME/.cache/zig is the last resort"
else
	bad "HOME/.cache/zig is the last resort (rc=$rc calls=$calls)"
fi

# A global dir wins even when the XDG cache already has the archive.
rm -rf "$work/cache-priority"
: >"$work/zig.log"
seed "$work/cache-priority" "$work/xdg-cache"
rc=$?
calls=$(wc -l <"$work/zig.log")
if [[ $rc -eq 0 && $calls -eq 1 && -s $work/cache-priority/p/$hash.tar.gz ]]; then
	ok "ZIG_GLOBAL_CACHE_DIR wins over XDG_CACHE_HOME"
else
	bad "ZIG_GLOBAL_CACHE_DIR wins over XDG_CACHE_HOME (rc=$rc calls=$calls)"
fi

FAKE_ZIG_RC=7
: >"$work/zig.log"
seed "$work/cache-fail" -
rc=$?
FAKE_ZIG_RC=0
if [[ $rc -eq 7 ]]; then
	ok "zig fetch failure is returned"
else
	bad "zig fetch failure is returned (rc=$rc)"
fi

FAKE_ZIG_HASH=libjxlz-0.1.0-H-different
seed "$work/cache-mismatch" - >"$work/mismatch.out" 2>"$work/mismatch.err"
rc=$?
FAKE_ZIG_HASH=$hash
if [[ $rc -ne 0 && $(cat "$work/mismatch.err") == *"libjxlz-0.1.0-H-different"* && $(cat "$work/mismatch.err") == *"$hash"* ]]; then
	ok "hash mismatch is refused"
else
	bad "hash mismatch is refused (rc=$rc)"
fi

rm -f "$work/cache/p/$hash.tar.gz"
rm -rf "$work/cache/p/$hash"
printf 'pkg\n' >"$work/cache/p/libjxlz-0.1.0-H-previous.tar.gz"
: >"$work/zig.log"
seed "$work/cache" -
rc=$?
calls=$(wc -l <"$work/zig.log")
if [[ $rc -eq 0 && $calls -eq 1 && -s $work/cache/p/$hash.tar.gz ]]; then
	ok "a different cached hash does not satisfy this pin"
else
	bad "a different cached hash does not satisfy this pin (rc=$rc calls=$calls)"
fi

bash "$seeder" >/dev/null 2>"$work/usage.err"
rc=$?
if [[ $rc -eq 2 ]]; then
	ok "missing source path is usage"
else
	bad "missing source path is usage (rc=$rc)"
fi

bash "$seeder" "$work/source-tree" "$work/missing.zon" >/dev/null 2>"$work/missing.err"
rc=$?
if [[ $rc -eq 2 ]]; then
	ok "missing zon is usage"
else
	bad "missing zon is usage (rc=$rc)"
fi

cat >"$work/proj/two.zon" <<EOF
.{
    .hash = "libjxlz-0.1.0-H-one",
    .hash = "libjxlz-0.1.0-H-two",
}
EOF
bash "$seeder" "$work/source-tree" "$work/proj/two.zon" >/dev/null 2>"$work/two.err"
rc=$?
if [[ $rc -eq 2 ]]; then
	ok "two libjxlz hashes are refused"
else
	bad "two libjxlz hashes are refused (rc=$rc)"
fi

hook=$(awk '
	/shellHook = / {capture = 1}
	capture {print}
	capture && /'\'\'';/ {exit}
' "$root/flake.nix")
if [[ $hook == *seed-libjxlz-cache* && $hook != *zig\ fetch* ]]; then
	ok "dev shell delegates seeding and does not fetch on its own"
else
	bad "dev shell delegates seeding and does not fetch on its own"
fi

if [[ $failures -eq 0 ]]; then
	echo "    seed-libjxlz-cache checks passed"
	exit 0
fi
echo "$failures check(s) failed." >&2
exit 1
