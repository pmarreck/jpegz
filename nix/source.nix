{ lib }:
root:
# Keep nested fixture documents and legal notices while excluding root records.
lib.cleanSourceWith {
	name = "source";
	src = root;
	filter = path: type:
		let
			relative = lib.removePrefix ((toString root) + "/") (toString path);
			top = builtins.head (lib.splitString "/" relative);
			rootMarkdown = !(lib.hasInfix "/" relative) && lib.hasSuffix ".md" relative;
			legal = builtins.elem relative [
				"LICENSE.md" "NOTICE.md" "COPYING.md" "THIRD_PARTY_NOTICES.md" "LICENSING_NOTES.md"
			];
			# The one generated document the test suite checks against its source.
			generated = (relative == "docs" && type == "directory") || relative == "docs/FINDING_CODES.md";
		in generated || !(builtins.elem top [ ".git" "docs" ".mechatron-prime" ]
			|| relative == ".dirtree-state"
			|| (type != "directory" && rootMarkdown && !legal));
}
