{
  description = "jsnix";

  inputs.flake-utils.url = "github:numtide/flake-utils";

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachSystem [
      "aarch64-darwin"
      "x86_64-darwin"
      "aarch64-linux"
      "x86_64-linux"
    ] (system:
      let pkgs = nixpkgs.legacyPackages.${system};
          packageLock = import ./package-lock.nix pkgs;
      in
        rec {
          packages = flake-utils.lib.flattenTree {
            "${system}" = {
              defaultPackage = {
                "${system}" = packageLock.jsnix;
              };
            };
          };
          defaultPackage = packageLock.jsnix;
        }
    );
}
