{
  description = "jsnix";

  inputs.flake-utils.url = "github:numtide/flake-utils";

  outputs = { self, nixpkgs, flake-utils }:
    (flake-utils.lib.eachSystem [
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
    )
    ) // {
      lib = {
        mkWorkspace = rootDir: workspaces: paramPkgs:
          let
            rootDir_ = if (builtins.typeOf rootDir == "path")
                       then rootDir
                       else throw "first argument of mkWorkspace must be of type path";
            rootDir__ = if (builtins.pathExists (rootDir_ + ("/flake.nix")))
                        then rootDir_
                        else throw "first argument of mkWorkspace must point to a directory which contains flake.nix";
            getWorkspaceOverlays = nixpkgs.lib.foldr (p: l:
              (l ++ (nixpkgs.lib.optionals (builtins.pathExists (rootDir__ + ("/" + p + "/overlay.nix"))))
                [ (import (rootDir__ + ("/" + p + "/overlay.nix"))) ])) [];

            getWorkspacePkgNames = nixpkgs.lib.foldr (p: l:
              (l ++ (nixpkgs.lib.optionals (builtins.pathExists (rootDir__ + ("/" + p + "/package.nix"))))
                [ { name = (import (rootDir__ + ("/" + p + "/package.nix"))).name; path = p; } ])) [];

            getWorkspacePkgs = pkgs: builtins.map
              ({ name, path }: (if (builtins.hasAttr "${name}" pkgs)
                                then pkgs."${name}"
                                else if (builtins.hasAttr "${name}" pkgs)
                                then (import (rootDir__ + ("/" + path + "/package-lock.nix")))
                                else builtins.throw "package ${name} was not found in ${path}, did you remember to run `jsnix install` beforehand?"))
              (getWorkspacePkgNames workspaces);

            getWorkspacePkgs__internal = wspaces: pkgs: builtins.map
              ({ name, path }: (if builtins.hasAttr "${name}" pkgs
                                then { inherit name path; drv = pkgs."${name}"; }
                                else { inherit name path; drv = (import (rootDir__ + ("/" + path + "/package-lock.nix"))); } ))
              (getWorkspacePkgNames wspaces);

            mkDevShellHook = pkgs: (nixpkgs.lib.foldr ({ name, path, drv }: acc:
              "${acc}\n(cd ${path}; rm -rf node_modules; rm -f package.json;" +
              "mkdir node_modules; ln -s ${drv.nodeModules}/lib/node_modules/* node_modules; ln -s ${drv.pkgJsonFile} package.json)\n"
            ) ""
              (getWorkspacePkgs__internal workspaces pkgs));
          in {
            overlays = (getWorkspaceOverlays workspaces);
            topLevelPackages = (getWorkspacePkgs paramPkgs);
            devShellHook = (mkDevShellHook paramPkgs);
          };
      };
    };
}
