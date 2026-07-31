#!/usr/bin/env bash
# Gate: a pure-Zig consumer must be able to import the `jpegz` module and call
# `validate()` with ZERO C dependencies in scope — no libjpeg-turbo, no
# openjpeg, no charls headers or libraries.
#
# WHY THIS EXISTS. `src/jpegz.zig` used to force-link the C ABI with a
# top-level `comptime { _ = @import("ffi/c_api.zig"); }`. A comptime block is
# analyzed unconditionally, so importing the module dragged the exported
# `jpegz_jp2_decode` → `jpeg2000.decodeWithOptions` → `openjpeg_wrapper.decode`
# → `@cImport(<openjpeg.h>)` chain into EVERY consumer's analysis. A
# validate-only consumer could not compile without openjpeg headers, which is
# almost certainly why `validate` ended up vendoring its own `deps/openjpeg`.
# The force-link now lives in `src/lib_root.zig`, used only by the static
# library artifact.
#
# This is the MFIC control for that invariant: the oracle is the Zig compiler,
# not a claim in a doc comment, and it BLOCKS (non-zero exit) rather than
# merely observing. A regression here is silent at the jpegz level — every
# jpegz test would still pass, because jpegz's own build always has the C libs
# available. Only an out-of-graph compile with C deliberately withheld can
# falsify it.
#
# Per CLAUDE.md: NO `set -euo pipefail` — the compile under test is EXPECTED to
# fail in the negative control below.

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
zig="${ZIG:-zig}"

work="$(mktemp -d "${TMPDIR:-/tmp}/jpegz-no-c-XXXXXX")"
trap 'rm -rf "$work"' EXIT

passed=0
failed=0
pass() { passed=$((passed + 1)); printf '  ok   %s\n' "$1"; }
fail() {
	failed=$((failed + 1))
	printf '  FAIL %s\n' "$1"
	[ $# -gt 1 ] && printf '       %s\n' "$2"
	return 0
}

# A consumer that does exactly what tiffz/validate want: import jpegz, call
# validate(), touch nothing else.
cat >"$work/consumer.zig" <<'ZIG'
const std = @import("std");
const jpegz = @import("jpegz");

pub fn main() !void {
	const alloc = std.heap.page_allocator;
	var r = try jpegz.validate(alloc, "\xFF\xD8not-a-real-jpeg");
	defer r.deinit(alloc);
	if (r.overall != .fail) return error.ExpectedFail;
	std.debug.print("ok findings={d}\n", .{r.findings.items.len});
}
ZIG

# Stand in for the generated options module, with BOTH C oracles off — the
# posture a lean consumer builds with.
cat >"$work/jpegz_build_options.zig" <<'ZIG'
pub const with_charls = false;
pub const with_libjpeg_oracle = false;
ZIG

# Note the deliberate absence of any -I / -L / -l flag for libjpeg, openjpeg or
# charls. `-lc` only.
build_consumer() {
	"$zig" build-exe \
		--dep jpegz -Mroot="$work/consumer.zig" \
		--dep jpegls_bitstream --dep jpegz_build_options \
		-Mjpegz="$repo/src/jpegz.zig" \
		-Mjpegls_bitstream="$repo/src/decode/jpegls_bitstream.zig" \
		-Mjpegz_build_options="$work/jpegz_build_options.zig" \
		-lc --name no_c_consumer \
		--cache-dir "$work/zig-cache" --global-cache-dir "$work/zig-global" \
		2>&1
}

echo "==> zero-C-dependency Zig consumer"

out="$(cd "$work" && build_consumer)"
rc=$?

if [ "$rc" -eq 0 ]; then
	pass "jpegz module imports and builds with no C deps in scope"
else
	case "$out" in
	*"openjpeg.h"*) detail="openjpeg.h was pulled in — the C ABI force-link leaked back into the module root (see src/lib_root.zig)" ;;
	*"jpeglib.h"*) detail="jpeglib.h was pulled in — a libjpeg-oracle path is no longer gated on with_libjpeg_oracle" ;;
	*"charls"*) detail="charls was pulled in — a JPEG-LS wrapper path is no longer gated on with_charls" ;;
	*) detail="$(printf '%s' "$out" | head -5)" ;;
	esac
	fail "jpegz module imports and builds with no C deps in scope" "$detail"
fi

# Specificity / negative control: this gate must be capable of FAILING. If a
# consumer that genuinely needs openjpeg still compiles with no C in scope,
# the check is vacuous and proves nothing.
cat >"$work/needs_c.zig" <<'ZIG'
const std = @import("std");
const jpegz = @import("jpegz");

pub fn main() !void {
	const alloc = std.heap.page_allocator;
	// jpeg2000.decode routes to the openjpeg wrapper — MUST require C.
	var img = try jpegz.jpeg2000.decode(alloc, "not-a-jp2");
	defer img.deinit(alloc);
}
ZIG

out2="$(cd "$work" && "$zig" build-exe \
	--dep jpegz -Mroot="$work/needs_c.zig" \
	--dep jpegls_bitstream --dep jpegz_build_options \
	-Mjpegz="$repo/src/jpegz.zig" \
	-Mjpegls_bitstream="$repo/src/decode/jpegls_bitstream.zig" \
	-Mjpegz_build_options="$work/jpegz_build_options.zig" \
	-lc --name needs_c \
	--cache-dir "$work/zig-cache" --global-cache-dir "$work/zig-global" 2>&1)"
rc2=$?

if [ "$rc2" -ne 0 ]; then
	pass "negative control: a jp2-decoding consumer still requires C (gate can fail)"
else
	fail "negative control: a jp2-decoding consumer still requires C (gate can fail)" \
		"it compiled without openjpeg — this gate is vacuous and would pass anything"
fi

echo
echo "$failed failed, $passed passed"
[ "$failed" -eq 0 ]
