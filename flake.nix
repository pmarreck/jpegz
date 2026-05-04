{
  description = "jpegz — spec-complete JPEG family decoder library in Zig";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # We pin Zig explicitly via mitchellh/zig-overlay because nixpkgs unstable
    # has moved to Zig 0.16 (which removed `addStaticLibrary` and other APIs
    # we rely on). Targeting 0.15.2 per Peter; revisit when 0.16.1 ships and
    # we explicitly migrate (see ZIG_0.15_TO_0.16_MIGRATION.md).
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # Pinned tool versions for the build sandbox.
        # libjpeg in nixpkgs is libjpeg-turbo (BSD-3); openjpeg is BSD-2.
        # Both MIT-compatible per LICENSING_NOTES.md.
        zigPkg = zig-overlay.packages.${system}."0.15.2";
        libjpegTurbo = pkgs.libjpeg;  # libjpeg-turbo 3.1.x
        openjpegPkg = pkgs.openjpeg;  # 2.5.x

        commonNativeBuildInputs = [ zigPkg pkgs.git pkgs.cacert ];
        commonBuildInputs = [ libjpegTurbo openjpegPkg ];

        # Phase 1 has no external Zig dependencies — `build.zig.zon` will be
        # added when the first dependency is introduced. Until then we don't
        # need the fixed-output `zigDeps` derivation pattern from CLAUDE.md.

        mkJpegzPackage = { optimize ? "ReleaseFast" }:
          pkgs.stdenv.mkDerivation {
            pname = "jpegz";
            version = "0.0.1";
            src = ./.;
            nativeBuildInputs = commonNativeBuildInputs;
            buildInputs = commonBuildInputs
              ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.apple-sdk ];
            dontConfigure = true;
            buildPhase = ''
              export HOME=$TMPDIR
              export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
              mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
              # Keep NIX_CFLAGS_COMPILE / NIX_LDFLAGS — Zig consults them
              # to find libjpeg-turbo and openjpeg headers and libraries.
              zig build -Doptimize=${optimize} --prefix $out
            '';
            installPhase = "true"; # build.zig already installs to $out
          };

        jpegzTestCheck = pkgs.stdenv.mkDerivation {
          pname = "jpegz-tests";
          version = "0.0.1";
          src = ./.;
          nativeBuildInputs = commonNativeBuildInputs;
          buildInputs = commonBuildInputs
            ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.apple-sdk ];
          dontConfigure = true;
          buildPhase = ''
            export HOME=$TMPDIR
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
            # Keep NIX_CFLAGS_COMPILE / NIX_LDFLAGS for libjpeg-turbo / openjpeg.
            timeout 600 zig build test || { echo "Tests failed"; exit 1; }
          '';
          installPhase = ''
            mkdir -p $out
            echo "tests passed" > $out/result
          '';
        };
      in {
        packages.default = mkJpegzPackage {};
        packages.jpegz = self.packages.${system}.default;

        checks = {
          build = self.packages.${system}.default;
          test = jpegzTestCheck;
        };

        devShells.default = pkgs.mkShell {
          packages = commonNativeBuildInputs ++ commonBuildInputs ++ [
            pkgs.hyperfine
            pkgs.pkg-config
          ];
          shellHook = ''
            echo "jpegz devShell — zig $(zig version), libjpeg-turbo ${libjpegTurbo.version}, openjpeg ${openjpegPkg.version}"
          '';
        };

        formatter = pkgs.alejandra;
      });
}
