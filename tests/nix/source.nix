{ libPath, fixtureRoot, sourceModule }:
let
	lib = import (builtins.toPath libPath);
	sourceFor = import (builtins.toPath sourceModule) { inherit lib; };
	root = name: builtins.toPath (fixtureRoot + "/" + name);
	source = name: sourceFor (root name);
	identity = name: (builtins.derivation {
		name = "jpegz-source-identity-control";
		system = builtins.currentSystem;
		builder = "/unused-source-control-builder";
		src = source name;
	}).drvPath;
	files = dir: prefix: lib.concatMap (name:
		let relative = prefix + name; in
		if (builtins.readDir dir).${name} == "directory"
		then files (dir + "/" + name) (relative + "/")
		else [ relative ]
	) (builtins.attrNames (builtins.readDir dir));
	expected = lib.sort builtins.lessThan [
		".future-config" "COPYING.md" "LICENSE" "LICENSE.md" "LICENSING_NOTES.md"
		"NOTICE.md" "THIRD_PARTY_NOTICES.md" "build.zig" "build.zig.zon"
		"data.md/keep.bin" "deps/vendor.c" "flake.lock" "flake.nix" "include/api.h" "scratch/check.zig"
		"src/alias.zig" "src/docs/nested.md" "src/main.zig" "tests/cli/check"
		"tests/unit/fixtures/image.bin" "tests/unit/fixtures/readme.md" "tools/tool"
	];
	baseline = identity "baseline";
	row = name: passed: { inherit name passed; };
	rows = [
		(row "complete retained file set" (files (toString (source "baseline")) "" == expected))
		(row "relocation keeps source identity" (toString (source "baseline") == toString (source "relocated project")))
		(row "relocation keeps derivation identity" (baseline == identity "relocated project"))
		(row "documentation edits keep derivation identity" (baseline == identity "documentation"))
		(row "CI metadata edits keep derivation identity" (baseline == identity "metadata"))
		(row "future files retain bytes and change derivation identity"
			(baseline != identity "future"
				&& builtins.pathExists ((toString (source "future")) + "/future-component/data")
				&& builtins.readFile ((toString (source "future")) + "/future-component/data") == "future input\n"))
		(row "relative source symlinks retain their target bytes"
			(builtins.readFile ((toString (source "baseline")) + "/src/alias.zig") == "original\n"))
	] ++ lib.genList (index:
		row ("required input edit " + toString index) (baseline != identity ("required-" + toString index))
	) 11;
in rows
