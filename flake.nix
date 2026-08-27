{
  description = "jpegz — spec-complete JPEG family decoder library in Zig";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # We pin Zig explicitly via mitchellh/zig-overlay. Now targeting 0.16.0
    # (the "Juicy Main" release). See ZIG_RECENT_API_CHANGES.md for the
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
        brotliPkg = if isLinux then pkgs.pkgsStatic.brotli else pkgs.brotli;
        # NOTE: there is deliberately no mingw-w64 Brotli here. Both nixpkgs
        # candidates were tried and neither works: `pkgsCross.mingwW64.brotli`
        # ships only `.dll.a` import libraries (Zig searches for
        # `brotli*.dll` / `brotli*.lib` / `libbrotli*.a` and finds none), and
        # `pkgsCross.mingwW64.pkgsStatic.brotli` fails to build. The Windows
        # cross check therefore passes `-Dwith-jxl=false`; see build.zig.
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
        commonBuildInputs = [ libjpegTurbo openjpegPkg brotliPkg ];

        # Fixed-output derivation pre-fetching every Zig dependency tarball
        # (CLAUDE.md Strategy 1). The only network dep is the vendored
        # openjpeg source (`deps/openjpeg/build.zig.zon` → uclouvain v2.5.4),
        # pulled when the build links openjpeg from source rather than the
        # system lib — i.e. the windows cross-check below, which has no
        # `-Dopenjpeg-lib` to short-circuit it.
        #
        # As of 2026-08-01 the NATIVE checks need this tree too: `jpeg2000.
        # validate` delegates to the sibling `jp2z` module, which is an eager
        # URL dependency in build.zig.zon. The sandbox has no network, so
        # every build phase seeds ZIG_GLOBAL_CACHE_DIR from here. (The older
        # note claiming the native checks "never touch this" was already
        # inaccurate — all three phases have always copied it — and jp2z makes
        # it plainly wrong.) Single hash covers the whole tree; bump it when
        # `build.zig.zon` (or deps/) changes:
        #   1. set zigDepsHash = pkgs.lib.fakeHash
        #   2. nix build .#checks.<system>.cross-windows  → prints real hash
        #   3. paste it back here.
        zigDepsHash = "sha256-O6Ag9WM7XUnohx2+sQZQ0JwRlUbMNaPhii+Is2l+5A4=";
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
              export BROTLI_INCLUDE_DIR=${brotliPkg.dev}/include
              export BROTLI_LIB_DIR=${brotliPkg.lib}/lib
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
            export BROTLI_INCLUDE_DIR=${brotliPkg.dev}/include
            export BROTLI_LIB_DIR=${brotliPkg.lib}/lib
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
            # Seed the cache with pre-fetched vendored deps (see mkJpegzPackage
            # for the why) so manifest resolution never needs network.
            cp -r ${zigDeps}/* "$ZIG_GLOBAL_CACHE_DIR/"
            chmod -R u+w "$ZIG_GLOBAL_CACHE_DIR"
            # Keep NIX_CFLAGS_COMPILE / NIX_LDFLAGS for libjpeg-turbo / openjpeg.
            # -Doptimize=ReleaseSafe: tests MUST be safety-checked. ReleaseFast
            # masks UB (integer overflow, bounds) — a fleet false-green (Pattern
            # 3, 2026-07-01): jpegls setDefaultThresholds overflowed on valid
            # 16-bit input yet ./test was green because it ran ReleaseFast.
            # This flips the WHOLE test compilation (jpegz_mod + every test
            # module) to ReleaseSafe; the package build keeps its explicit
            # -Doptimize=ReleaseFast, benchmarks stay ReleaseFast.
            timeout 600 zig build test -Doptimize=ReleaseSafe ${zigTargetFlag} ${depFlags} || { echo "Tests failed"; exit 1; }
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
            # No Brotli is exported on purpose, and -Dwith-jxl=false is the
            # honest consequence: nixpkgs has no usable mingw-w64 Brotli
            # (the dynamic build ships only `.dll.a` import libraries, which
            # Zig does not search for, and the static build fails to compile).
            # Smuggling the NATIVE Brotli into a Windows artifact would make
            # this gate pass while producing something that could never run,
            # which is precisely the dishonesty it exists to catch.
            #
            # Consequence for users: a Windows build reports JPEG XL files as
            # `indeterminate` / `jxl_validator_unavailable` rather than
            # pretending to validate them. Removing this needs Brotli vendored
            # and compiled by Zig, the way charls already is.
            zig build test-build -Dtarget=x86_64-windows-gnu \
              -Dwith-charls=false -Dwith-libjpeg-oracle=false -Dwith-jxl=false
          '';
          installPhase = ''
            mkdir -p $out
            echo "windows cross-link ok" > $out/result
          '';
        };

        validatorPackage = pkgs.stdenv.mkDerivation {
          pname = "jpegz-validator-proof";
          version = "0.1.0";
          src = ./.;
          nativeBuildInputs = commonNativeBuildInputs;
          buildInputs = [ brotliPkg ];
          dontConfigure = true;
          buildPhase = ''
            export HOME=$TMPDIR
            export BROTLI_INCLUDE_DIR=${brotliPkg.dev}/include
            export BROTLI_LIB_DIR=${brotliPkg.lib}/lib
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
            cp -r ${zigDeps}/* "$ZIG_GLOBAL_CACHE_DIR/"
            chmod -R u+w "$ZIG_GLOBAL_CACHE_DIR"
            zig build install-validator -Doptimize=ReleaseFast ${zigTargetFlag} \
              -Dwith-charls=false -Dwith-libjpeg-oracle=false --prefix $out
          '';
          installPhase = "true";
        };

        validatorRuntimeClosure = pkgs.closureInfo {
          rootPaths = [ validatorPackage ];
        };

        validatorClosureCheck = pkgs.runCommand "jpegz-validator-closure" {
          nativeBuildInputs = [ pkgs.binutils ];
        } ''
          probe=${validatorPackage}/bin/jpegz-validator-proof
          "$probe"
          ${pkgs.binutils}/bin/nm -u "$probe" > undefined-symbols.txt
          ${pkgs.binutils}/bin/readelf -d "$probe" > dynamic-section.txt
          if ${pkgs.gnugrep}/bin/grep -Eqi 'opj_|openjp2|jpeg_|charls|JxlDecoder|JxlSignature|djxl' undefined-symbols.txt dynamic-section.txt; then
            echo "forbidden external JPEG-family validator symbol or library" >&2
            cat undefined-symbols.txt dynamic-section.txt >&2
            exit 1
          fi
          cp ${validatorRuntimeClosure}/store-paths closure.txt
          if ${pkgs.gnugrep}/bin/grep -Eqi '/(openjpeg|libjpeg|charls|libjxl-[0-9]|djxl)' closure.txt; then
            echo "forbidden external JPEG-family validator in Nix closure" >&2
            cat closure.txt >&2
            exit 1
          fi
          mkdir -p $out
          cp undefined-symbols.txt dynamic-section.txt closure.txt $out/
          echo "validation-only closure excludes external JPEG-family validators" > $out/result
        '';
      in {
        packages.default = mkJpegzPackage {};
        packages.jpegz = self.packages.${system}.default;
        packages.validator = validatorPackage;

        checks = {
          build = self.packages.${system}.default;
          test = jpegzTestCheck;
          cross-windows = crossWindowsCheck;
          validator-closure = validatorClosureCheck;
        };

        devShells.default = pkgs.mkShell {
          # Dev shell uses the host's default libjpeg/openjpeg (glibc on
          # Linux, native on macOS). The musl pinning above is sandbox-only
          # — interactive dev doesn't need it. charls is built from
          # vendored source (Zig compiles 8 .cpp files); CHARLS_SRC tells
          # build.zig where the source tree is.
          packages = [ zigPkg pkgs.git pkgs.cacert pkgs.libjpeg pkgs.openjpeg pkgs.brotli pkgs.hyperfine pkgs.pkg-config ];
          CHARLS_SRC = charlsSrc;
          BROTLI_INCLUDE_DIR = "${pkgs.brotli.dev}/include";
          BROTLI_LIB_DIR = "${pkgs.brotli.lib}/lib";
          shellHook = ''
            echo "jpegz devShell — zig $(zig version), libjpeg-turbo ${pkgs.libjpeg.version}, openjpeg ${pkgs.openjpeg.version}, charls 2.4.3 (vendored)"
          '';
        };

        formatter = pkgs.alejandra;
      });
}
