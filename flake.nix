{
  description = "jpegz — spec-complete JPEG family decoder library in Zig";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # We pin Zig explicitly via mitchellh/zig-overlay. Now targeting 0.16.0
    # (the "Juicy Main" release). See ZIG_0.15_TO_0.16_MIGRATION.md for the
    # patterns applied during the migration.
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        isDarwin = pkgs.stdenv.isDarwin;
        isLinux = pkgs.stdenv.isLinux;

        zigPkg = zig-overlay.packages.${system}."0.16.0";

        # On Linux we target musl explicitly so both the production lib
        # AND the test binaries are fully statically linked. Two reasons:
        #
        #   (1) zig-overlay ships vanilla (un-wrapped) Zig. Inside the
        #       Nix sandbox, its host-ABI / dynamic-linker detection
        #       fails ("FileNotFound, falling back to default ABI and
        #       dynamic linker"). The fallback is broken — test binaries
        #       can't find their interpreter at run time. Build of a
        #       static `.a` "succeeds" only because archives don't need
        #       a linker; an executable production binary (the C CLI in
        #       M1.7+) would hit exactly the same wall.
        #
        #   (2) The portfolio convention favors static Linux binaries
        #       (CLAUDE.md "Better static linking support"). tiffz uses
        #       the same musl pattern.
        #
        # macOS handles its own dynamic linker via apple-sdk and the
        # native target works there.
        zigTarget =
          if system == "x86_64-linux"      then "x86_64-linux-musl"
          else if system == "aarch64-linux" then "aarch64-linux-musl"
          else null;
        zigTargetFlag = if zigTarget == null then "" else "-Dtarget=${zigTarget}";

        # On Linux we need musl-linked C deps to match the Zig target.
        # nixpkgs provides these via `pkgsStatic` — same source versions,
        # built against musl + statically linkable.
        libjpegTurbo = if isLinux then pkgs.pkgsStatic.libjpeg else pkgs.libjpeg;
        openjpegPkg  = if isLinux then pkgs.pkgsStatic.openjpeg else pkgs.openjpeg;
        # charls — BSD-3, JPEG-LS (T.87) reference codec. C++ implementation
        # with a C ABI (charls_jpegls_decoder_*); we consume via cImport.
        # libjpeg-turbo does not ship a JPEG-LS path, so this is the only
        # T.87 oracle available for cleanroom-vs-wrapper testing.
        charlsPkg = if isLinux then pkgs.pkgsStatic.charls else pkgs.charls;

        # When cross-targeting (musl on Linux), Zig's host NIX_LDFLAGS /
        # NIX_CFLAGS don't apply, and `--search-prefix` only handles
        # standard `<prefix>/{lib,include}` layouts. openjpeg installs
        # its headers under `include/openjpeg-2.5/openjpeg.h` (versioned
        # subdir) — so a generic `--search-prefix ${openjpeg.dev}`
        # won't reach them. Pass include + library paths explicitly via
        # `-D` build options instead.
        #
        # Multi-output traps:
        # - pkgsStatic.libjpeg's default output is `bin`, NOT `out`.
        #   Use `.out` for libs, `.dev` for headers.
        # - openjpeg's headers nest under `include/openjpeg-2.5/`.
        depFlags = pkgs.lib.concatStringsSep " " [
          "-Dlibjpeg-include=${libjpegTurbo.dev}/include"
          "-Dlibjpeg-lib=${libjpegTurbo.out}/lib"
          "-Dopenjpeg-include=${openjpegPkg.dev}/include/openjpeg-2.5"
          "-Dopenjpeg-lib=${openjpegPkg.out}/lib"
          "-Dcharls-include=${charlsPkg}/include"
          "-Dcharls-lib=${charlsPkg}/lib"
        ];

        commonNativeBuildInputs = [ zigPkg pkgs.git pkgs.cacert ];
        commonBuildInputs = [ libjpegTurbo openjpegPkg charlsPkg ];

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
              ++ pkgs.lib.optionals isDarwin [ pkgs.apple-sdk ];
            dontConfigure = true;
            buildPhase = ''
              export HOME=$TMPDIR
              export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
              mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
              # Keep NIX_CFLAGS_COMPILE / NIX_LDFLAGS — Zig consults them
              # to find libjpeg-turbo and openjpeg headers and libraries.
              zig build -Doptimize=${optimize} ${zigTargetFlag} ${depFlags} --prefix $out
            '';
            installPhase = "true"; # build.zig already installs to $out
          };

        jpegzTestCheck = pkgs.stdenv.mkDerivation {
          pname = "jpegz-tests";
          version = "0.0.1";
          src = ./.;
          nativeBuildInputs = commonNativeBuildInputs;
          buildInputs = commonBuildInputs
            ++ pkgs.lib.optionals isDarwin [ pkgs.apple-sdk ];
          dontConfigure = true;
          buildPhase = ''
            export HOME=$TMPDIR
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
            # Keep NIX_CFLAGS_COMPILE / NIX_LDFLAGS for libjpeg-turbo / openjpeg.
            timeout 600 zig build test ${zigTargetFlag} ${depFlags} || { echo "Tests failed"; exit 1; }
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
          # Dev shell uses the host's default libjpeg/openjpeg (glibc on
          # Linux, native on macOS). The musl pinning above is sandbox-only
          # — interactive dev doesn't need it.
          packages = [ zigPkg pkgs.git pkgs.cacert pkgs.libjpeg pkgs.openjpeg pkgs.charls pkgs.hyperfine pkgs.pkg-config ];
          shellHook = ''
            echo "jpegz devShell — zig $(zig version), libjpeg-turbo ${pkgs.libjpeg.version}, openjpeg ${pkgs.openjpeg.version}, charls ${pkgs.charls.version}"
          '';
        };

        formatter = pkgs.alejandra;
      });
}
