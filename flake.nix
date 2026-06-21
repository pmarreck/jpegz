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
        # charls — BSD-3, JPEG-LS (T.87) reference codec. We vendor the
        # source (not a binary package) and compile it via Zig's own
        # bundled clang + libc++. Two attempts at consuming the binary
        # package failed:
        #
        #   1. pkgsStatic.charls (gcc + libstdc++_static): linker error
        #      "undefined symbol: std::__cxx11::basic_string..." — Zig's
        #      `link_libcpp` resolves to libc++ which uses different
        #      symbol mangling (`std::__1::basic_string` etc.).
        #   2. pkgsStatic.charls overridden to libcxxStdenv: the
        #      libcxxStdenv on musl can't even compile a trivial C
        #      executable ("cannot find -lgcc_eh") — the libc++/musl
        #      static toolchain in nixpkgs is incomplete.
        #
        # Vendoring is the robust path: Zig's bundled clang compiles the
        # 8 charls .cpp files into a static lib, links against Zig's
        # libc++, end-to-end consistent on every target. The C ABI we
        # consume is unchanged.
        charlsSrc = pkgs.fetchFromGitHub {
          owner = "team-charls";
          repo = "charls";
          rev = "2.4.3";
          sha256 = "1zhfz5qn22fh0qznh8wrzq68l77wv36wi3ji0hwx4g2kaism4vak";
        };

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
          "-Dcharls-src=${charlsSrc}"
        ];

        commonNativeBuildInputs = [ zigPkg pkgs.git pkgs.cacert ];
        commonBuildInputs = [ libjpegTurbo openjpegPkg ];

        # Fixed-output derivation pre-fetching every Zig dependency tarball
        # (CLAUDE.md Strategy 1). The only network dep is the vendored
        # openjpeg source (`deps/openjpeg/build.zig.zon` → uclouvain v2.5.4),
        # pulled when the build links openjpeg from source rather than the
        # system lib — i.e. the windows cross-check below, which has no
        # `-Dopenjpeg-lib` to short-circuit it. The native build/test checks
        # pass `-Dopenjpeg-lib` and never touch this. Single hash covers the
        # whole tree; bump it when `build.zig.zon` (or deps/) changes:
        #   1. set zigDepsHash = pkgs.lib.fakeHash
        #   2. nix build .#checks.<system>.cross-windows  → prints real hash
        #   3. paste it back here.
        zigDepsHash = "sha256-3PE/qYD4gEHF4COMwfxsNp7cMIMcTXtyt0Pq5DSmi/8=";
        zigDeps = pkgs.stdenv.mkDerivation {
          pname = "jpegz-zig-deps";
          version = "0.1.0";
          src = ./.;
          nativeBuildInputs = commonNativeBuildInputs;
          dontConfigure = true;
          outputHashMode = "recursive";
          outputHashAlgo = "sha256";
          outputHash = zigDepsHash;
          buildPhase = ''
            export HOME=$TMPDIR
            export ZIG_GLOBAL_CACHE_DIR=$out
            export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            export GIT_SSL_CAINFO=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            zig build --fetch=all
          '';
          dontInstall = true;
          dontFixup = true;
        };

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
              # Seed the cache with the pre-fetched vendored deps (openjpeg
              # source). Even on the native system-openjpeg path, Zig reads
              # the full build.zig.zon dependency tree at manifest resolution
              # and would try to fetch openjpeg_src from GitHub — which fails
              # in the network-less Linux sandbox. Pre-seeding from the FOD
              # makes that fetch a cache hit. (Same pattern the cross-windows
              # check uses; that check passes on Garnix Linux, proving it.)
              cp -r ${zigDeps}/* "$ZIG_GLOBAL_CACHE_DIR/"
              chmod -R u+w "$ZIG_GLOBAL_CACHE_DIR"
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
            # Seed the cache with pre-fetched vendored deps (see mkJpegzPackage
            # for the why) so manifest resolution never needs network.
            cp -r ${zigDeps}/* "$ZIG_GLOBAL_CACHE_DIR/"
            chmod -R u+w "$ZIG_GLOBAL_CACHE_DIR"
            # Keep NIX_CFLAGS_COMPILE / NIX_LDFLAGS for libjpeg-turbo / openjpeg.
            timeout 600 zig build test ${zigTargetFlag} ${depFlags} || { echo "Tests failed"; exit 1; }
          '';
          installPhase = ''
            mkdir -p $out
            echo "tests passed" > $out/result
          '';
        };

        # Windows cross-link regression gate. The vendored static openjpeg
        # (deps/openjpeg) is what lets jpegz cross-compile to mingw, where
        # the system openjp2/libjpeg are unavailable. We can't *run* a
        # windows binary in the sandbox, so this is build-only: `test-build`
        # compiles AND links every test exe (the link step is where missing
        # openjp2 symbols would surface — the original RED was 18 undefined
        # `opj_*`). charls + the libjpeg oracle are off so the closure is
        # openjpeg-only, exactly matching the shipping windows artifact.
        # Build-only ⇒ host-agnostic: this runs on any builder, no
        # x86_64-windows runner needed. Deps come from the FOD above.
        crossWindowsCheck = pkgs.stdenv.mkDerivation {
          pname = "jpegz-cross-windows";
          version = "0.0.1";
          src = ./.;
          nativeBuildInputs = commonNativeBuildInputs;
          dontConfigure = true;
          buildPhase = ''
            export HOME=$TMPDIR
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
            cp -r ${zigDeps}/* "$ZIG_GLOBAL_CACHE_DIR/"
            chmod -R u+w "$ZIG_GLOBAL_CACHE_DIR"
            zig build test-build -Dtarget=x86_64-windows-gnu \
              -Dwith-charls=false -Dwith-libjpeg-oracle=false
          '';
          installPhase = ''
            mkdir -p $out
            echo "windows cross-link ok" > $out/result
          '';
        };
      in {
        packages.default = mkJpegzPackage {};
        packages.jpegz = self.packages.${system}.default;

        checks = {
          build = self.packages.${system}.default;
          test = jpegzTestCheck;
          cross-windows = crossWindowsCheck;
        };

        devShells.default = pkgs.mkShell {
          # Dev shell uses the host's default libjpeg/openjpeg (glibc on
          # Linux, native on macOS). The musl pinning above is sandbox-only
          # — interactive dev doesn't need it. charls is built from
          # vendored source (Zig compiles 8 .cpp files); CHARLS_SRC tells
          # build.zig where the source tree is.
          packages = [ zigPkg pkgs.git pkgs.cacert pkgs.libjpeg pkgs.openjpeg pkgs.hyperfine pkgs.pkg-config ];
          CHARLS_SRC = charlsSrc;
          shellHook = ''
            echo "jpegz devShell — zig $(zig version), libjpeg-turbo ${pkgs.libjpeg.version}, openjpeg ${pkgs.openjpeg.version}, charls 2.4.3 (vendored)"
          '';
        };

        formatter = pkgs.alejandra;
      });
}
