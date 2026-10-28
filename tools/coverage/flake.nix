{
  # corruption-reader for ./corruption-coverage only. The repository is private,
  # so it stays out of the main flake: a private input there would make every
  # build of this public project depend on SSH access to it. Consumer contract:
  # corruption_reader docs/consumer_cli.md. Pin forward when that project
  # announces a new consumer CLI. Old pins are not kept working.
  description = "corruption-reader executable pinned for jpegz ./corruption-coverage";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    corruption-reader = {
      url = "git+ssh://git@github.com/pmarreck/corruption_reader?rev=1ec8cbe4f246bd60156bff3cdc5865f99d64ec4b";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, corruption-reader }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      forAll = f: nixpkgs.lib.genAttrs systems f;
    in {
      packages = forAll (system: {
        default = corruption-reader.packages.${system}.default;
      });
    };
}
