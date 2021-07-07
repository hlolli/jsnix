{
  description = "nixjs";

  inputs.flake-utils.url = "github:numtide/flake-utils";

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = nixpkgs.legacyPackages.${system};
          gitignoreSource = (import (pkgs.fetchFromGitHub {
            owner = "hercules-ci";
            repo = "gitignore.nix";
            rev = "211907489e9f198594c0eb0ca9256a1949c9d412";
            sha256 = "sha256-qHu3uZ/o9jBHiA3MEKHJ06k7w4heOhA+4HCSIvflRxo=";
          }) { inherit (pkgs) lib; }).gitignoreSource;
      in
        rec {
          packages = flake-utils.lib.flattenTree {
            hello = pkgs.hello;
            gitAndTools = pkgs.gitAndTools;
          };
          defaultPackage = packages.hello;
          apps.hello = flake-utils.lib.mkApp { drv = packages.hello; };
          defaultApp = apps.hello;
        }
    );
}
