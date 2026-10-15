{
  description = "jpegz — spec-complete JPEG family decoder library in Zig";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # Private source is fetched by Nix using the caller's SSH credentials,
    # before sandboxed builds. Never put credentials in a derivation or URL.
    libjxlz-src = {
      url = "git+ssh://git@github.com/pmarreck/libjxlz?ref=yolo";
      flake = false;
    };
    # We pin Zig explicitly via mitchellh/zig-overlay. Now targeting 0.16.0
    # (the "Juicy Main" release). See ZIG_RECENT_API_CHANGES.md for the
    # patterns applied during the migration.
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay, libjxlz-src }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ] (system:
      let
        pkgs = import nixpkgs { inherit system; };
        isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
        isLinux = pkgs.stdenv.hostPlatform.isLinux;

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
        # Use Nixpkgs build recipes with immutable upstream source pins.
        # Linux libraries use pkgsStatic to match the musl target.
        libjpegSrc = pkgs.fetchFromGitHub {
          owner = "libjpeg-turbo";
          repo = "libjpeg-turbo";
          rev = "2fa570c514a4b0e70342ef8b32ce1cda21b85710";
          hash = "sha256-6zMSh3aDSd6ZTbHsdoVLkc8sSroYS64ZyhOZwhkrM0s=";
        };
        libjpegTurbo = (if isLinux then pkgs.pkgsStatic.libjpeg else pkgs.libjpeg).overrideAttrs (_: {
          version = "3.2.1";
          src = libjpegSrc;
        });
        libjpegNativePkg = pkgs.libjpeg.overrideAttrs (_: {
          version = "3.2.1";
          src = libjpegSrc;
        });
        openjpegSrc = pkgs.fetchFromGitHub {
          owner = "uclouvain";
          repo = "openjpeg";
          rev = "8314119b067c0fc77834731168daaebd379fdb12";
          hash = "sha256-ER+EMxToPJuwtwl6ImdCEUcILUOIWt99oCfOBVaqAVs=";
        };
        openjpegPkg = (if isLinux then pkgs.pkgsStatic.openjpeg else pkgs.openjpeg).overrideAttrs (_: {
          src = openjpegSrc;
        });
        openjpegNativePkg = pkgs.openjpeg.overrideAttrs (_: {
          src = openjpegSrc;
        });
        brotliSrc = pkgs.fetchFromGitHub {
          owner = "google";
          repo = "brotli";
          rev = "86ee1f65f62d6272345dee751d49e7d1f01c2b11";
          hash = "sha256-mn8ukkfdeBc8HKOolbcjQ20VC9RdgJU4n2BOmIbgw6c=";
        };
        alreadyAppliedBrotliPatch = pkgs.fetchurl {
          url = "https://github.com/google/brotli/commit/e230f474b87134e8c6c85b630084c612057f253e.patch";
          hash = "sha256-QERl8RHJz7tFr++hZIYwdj1/ogPpjArC+ia8S/bWxKk=";
        };
        brotliAtHead = package: package.overrideAttrs (old: {
          src = brotliSrc;
          meta = old.meta // {
            changelog = "https://github.com/google/brotli/blob/${brotliSrc.rev}/CHANGELOG.md";
          };
          # This Nixpkgs platform patch is already in the pinned head.
          # Keep any other patches supplied by the package recipe.
          patches = builtins.filter
            (patch: toString patch != toString alreadyAppliedBrotliPatch)
            (old.patches or []);
        });
        brotliPkg = brotliAtHead (if isLinux then pkgs.pkgsStatic.brotli else pkgs.brotli);
        brotliNativePkg = brotliAtHead pkgs.brotli;
        dependencyCompatibilityCheck = let
          appliedPatch = builtins.head pkgs.brotli.patches;
          keep = [ "other.patch" "other-e230f474b87134e8c6c85b630084c612057f253e.patch" ];
          controls = [
            { input = []; expected = []; }
            { input = keep; expected = keep; }
            { input = [ appliedPatch ] ++ keep ++ [ appliedPatch ]; expected = keep; }
          ];
          classified = map (control: (brotliAtHead {
            overrideAttrs = f: f { patches = control.input; meta = {}; };
          }).patches) controls;
        in assert classified == map (control: control.expected) controls;
          builtins.deepSeq (map (package: package.meta.changelog or null)
            [ libjpegTurbo openjpegPkg brotliPkg ])
          (pkgs.writeText "jpegz-dependency-compatibility" "Codec metadata and patch-list controls passed.\n");
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
        # Zig's bundled clang compiles the CharLS sources into a static
        # library and links against Zig's libc++ on every target.
        charlsSrc = pkgs.fetchFromGitHub {
          owner = "team-charls";
          repo = "charls";
          rev = "5f54145968ff51c3ff84896c2ec8e422154a69cf";
          hash = "sha256-wMUQuuZOzMJWD/JK5EmhGI0BjrqKZHljfyo6UhRoZsg=";
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

        # Prefetch jp2z, private libjxlz and the optional OpenJPEG source used
        # by Windows cross-builds. All native and cross builds seed their
        # offline Zig cache from this source-bearing output; never publish
        # it to a public binary cache. This must stay the real fixed-output
        # hash for the current build.zig.zon. Never commit a placeholder.
        zigDepsHash = "sha256-n86bl1BO1NcPy8YAV/sLAUTGcfndo4LfpxAbwVBivRY=";
        zigDeps = assert pkgs.lib.hasInfix "archive/${libjxlz-src.rev}.tar.gz"
          (builtins.readFile ./build.zig.zon); pkgs.stdenv.mkDerivation {
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
            zig fetch ${libjxlz-src}
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

        # Foreign-target compile/link gates. Vendored static OpenJPEG is what
        # lets jpegz cross-compile where system openjp2/libjpeg are unavailable.
        # test-build compiles and links every test executable but does not run
        # it. The link step is where missing opj_* symbols surface. CharLS and
        # the libjpeg oracle are off. JXL stays off because no target-built
        # Brotli is supplied: nixpkgs has no usable mingw-w64 Brotli that Zig
        # can link, and a native Brotli would make a foreign gate pass while
        # producing an artifact that cannot run. Those builds report JPEG XL
        # as indeterminate / jxl_validator_unavailable. Native tests cover JXL.
        mkCrossLinkCheck = crossTarget: pkgs.stdenv.mkDerivation {
          pname = "jpegz-cross-${crossTarget}";
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
            zig build test-build -j2 -Dtarget=${crossTarget} \
              -Dwith-charls=false -Dwith-libjpeg-oracle=false -Dwith-jxl=false
          '';
          installPhase = ''
            mkdir -p $out
            echo "${crossTarget} cross-link ok (JXL and external oracles disabled; not a runtime test)" > $out/result
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
          dependency-compatibility = dependencyCompatibilityCheck;
          build = self.packages.${system}.default;
          test = jpegzTestCheck;
          cross-windows = mkCrossLinkCheck "x86_64-windows-gnu";
          cross-aarch64-linux = mkCrossLinkCheck "aarch64-linux-musl";
          cross-aarch64-macos = mkCrossLinkCheck "aarch64-macos";
          cross-aarch64-windows = mkCrossLinkCheck "aarch64-windows-gnu";
          validator-closure = validatorClosureCheck;
        };

        devShells.default = pkgs.mkShell {
          # Interactive builds use native C libraries and the same
          # codec source pins as sandboxed builds. CHARLS_SRC supplies
          # the CharLS sources for compilation by Zig.
          packages = [ zigPkg pkgs.git pkgs.cacert libjpegNativePkg openjpegNativePkg brotliNativePkg pkgs.hyperfine pkgs.pkg-config ];
          CHARLS_SRC = charlsSrc;
          BROTLI_INCLUDE_DIR = "${brotliNativePkg.dev}/include";
          BROTLI_LIB_DIR = "${brotliNativePkg.lib}/lib";
          shellHook = ''
            # Zig cannot authenticate a private archive URL itself. Seed the
            # locked package once; repeating the fetch rewrites the same
            # global-cache archive on every shell entry.
            ${./tools/seed-libjxlz-cache} ${libjxlz-src} ${./build.zig.zon} || exit 1
            echo "jpegz devShell — zig $(zig version), libjpeg-turbo ${libjpegNativePkg.version}, openjpeg ${openjpegNativePkg.version}, charls 3.0.0 (vendored)"
          '';
        };

        formatter = pkgs.alejandra;
      });
}
