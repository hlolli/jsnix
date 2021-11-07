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
      let pkgs_ = nixpkgs.legacyPackages.${system};
          packageLock = import ./package-lock.nix pkgs_;
      in {
        packages = flake-utils.lib.flattenTree {
          "${system}" = {
            defaultPackage = {
              "${system}" = packageLock.jsnix;
            };
          };
        };
        defaultPackage = packageLock.jsnix;
        lib = {
          mkWorkspace = flakePath: pkgs: workspaces:
            let
              bashFindUp = ''
                ROOT_DIR=$(pwd)
                while [ "$ROOT_DIR" != "/" ] ; do
                if [ $(find "$ROOT_DIR" -maxdepth 1 -name flake.nix) ]; then break; fi;
                  export ROOT_DIR=$(dirname "$ROOT_DIR")
                done
              '';

              workspaceImports = nixpkgs.lib.foldr (pName: l:
                let pForm = builtins.getAttr pName workspaces;
                    pPath = (builtins.toPath (flakePath + ("/" + (builtins.getAttr "projectDir" pForm))));
                in if ((builtins.pathExists (pPath + "/package.nix")) &&
                       (builtins.pathExists (pPath + "/package-lock.nix")))
                   then
                     let pkg = import (pPath + "/package.nix");
                         pkgLock = import (pPath + "/package-lock.nix") pkgs;
                     in (l // (nixpkgs.lib.optionalAttrs ((builtins.hasAttr "name" pkg) && (builtins.hasAttr pkg.name pkgLock)))
                       { "${pName}" = pkgLock.${pkg.name} ; })
                   else l) {} (builtins.attrNames workspaces);

              getWorkspaceOverlays = nixpkgs.lib.foldr (p: l:
                (l ++
                 (let pPath = (builtins.toPath (flakePath + ("/" + (builtins.getAttr "projectDir" p))));
                  in (if (builtins.pathExists (pPath + "/overlay.nix"))
                      then [ (import (pPath + "/overlay.nix")) ]
                      else [ (final: prev: (import (pPath + "/package-lock.nix"))) ]))))
                [];

              getWorkspacePkgNames = nixpkgs.lib.foldr (p: l:
                (l ++ (nixpkgs.lib.optionals (builtins.pathExists (flakePath + (p + "/package.nix"))))
                  [ { name = (import (p + "/package.nix")).name; path = p; } ])) [];

              getWorkspacePkgs = pkgs: builtins.map
                ({ name, path }: (if (builtins.hasAttr "${name}" pkgs)
                                  then pkgs."${name}"
                                  else if (builtins.hasAttr "${name}" pkgs)
                                  then (import (path + "/package-lock.nix"))
                                  else builtins.throw "package ${name} was not found in ${path}, did you remember to run `jsnix install` beforehand?"))
                (getWorkspacePkgNames workspaces);

              getWorkspacePkgs__internal = wspaces: builtins.map
                ({ name, path }: (if builtins.hasAttr "${name}" pkgs
                                  then { inherit name path; drv = pkgs."${name}"; }
                                  else { inherit name path; drv = (import (path + "/package-lock.nix")); } ))
                (getWorkspacePkgNames wspaces);

              scriptWithAttrs =
                (pkgs.lib.attrsets.filterAttrs (k: v: (builtins.length v) > 0)
                  (pkgs.lib.attrsets.mapAttrs
                    (k: v: (
                      if (builtins.hasAttr "scripts" v)
                      then (builtins.attrValues
                        (pkgs.lib.attrsets.mapAttrs (sk: sv:
                          let text = ''
                            #!${pkgs.runtimeShell}
                            ${bashFindUp}
                            cd $ROOT_DIR
                            cd ${v.projectDir}
                            if [[ ! -e "./node_modules" ]]; then
                              mkdir -p node_modules
                              ln -s ${workspaceImports.${k}.nodeModules}/lib/node_modules/* ./node_modules
                            fi
                          '';
                          in (pkgs.runCommand "${k}-${sk}" {
                            buildInputs = if (builtins.hasAttr k workspaceImports)
                                          then ([workspaceImports.${k}.nodeModules] ++
                                                (pkgs.lib.optionals (builtins.hasAttr "buildInputs" workspaceImports.${k})
                                                  workspaceImports.${k}.buildInputs))
                                          else [];
                          }
                            ''
                              mkdir -p $out/bin
                              echo '${text}' > "$out/bin/${k}-${sk}"
                              echo PATH=$PATH:\$PATH >> "$out/bin/${k}-${sk}"
                              echo NODE_PATH=$NODE_PATH:\$NODE_PATH >> "$out/bin/${k}-${sk}"
                              echo '${sv}' >> "$out/bin/${k}-${sk}"
                              chmod +x "$out/bin/${k}-${sk}"
                            ''
                          )) v.scripts))
                      else []
                    ))
                    workspaces));

              scripts = (pkgs.lib.lists.flatten
                (builtins.attrValues scriptWithAttrs));

              getScriptNames = scriptGroup: builtins.concatStringsSep "\n"
                (builtins.map
                  (scriptName: "     \\033[1;30m${scriptGroup}-${scriptName}\\033[0m")
                  (builtins.attrNames workspaces.${scriptGroup}.scripts));

              mkDevShellHook = pkgs: (nixpkgs.lib.foldr ({ name, path, drv }: acc:
                ''
                 ${acc}
                 (cd $ROOT_DIR; cd ${path}; rm -rf node_modules; rm -f package.json;
                 mkdir node_modules; ln -s ${drv.nodeModules}/lib/node_modules/* node_modules; ln -s ${drv.pkgJsonFile} package.json)
               ''
              ) ''
                  ${bashFindUp}
                  export PATH=$PATH:${builtins.concatStringsSep ":" (builtins.map (s: s + "/bin") scripts)}
                  echo -e "\n"
                  echo -e "     \\033[1;96mJSNIX workspace devShellHook\\033[0m"
                  echo -e "${
                    if ((builtins.length (builtins.attrValues scriptWithAttrs)) > 0)
                    then "     \\033[1;30mthe following commands are available\\033[0m\n\""
                    else "     \\033[0;33mno devShellHook scripts were found\\033[0m\""
                  }
                  ${(builtins.concatStringsSep "\n"
                    (builtins.map
                      (s: ''echo -e "  •  \\033[1;95m${s}\\033[0m"
                            echo -e "${toString (getScriptNames s)}"'')
                      (builtins.attrNames scriptWithAttrs)))}
                  echo -e "\n"
                ''
                (getWorkspacePkgs__internal
                  (builtins.map (p: p.projectDir)
                    (builtins.attrValues workspaces))));

            in {
              apps = pkgs.lib.attrsets.mapAttrs (_: v: { type = "app"; program = v; }) scriptWithAttrs;
              scripts = scriptWithAttrs;
              packages = flake-utils.lib.flattenTree workspaceImports;
              overlays = (getWorkspaceOverlays (builtins.attrValues workspaces));
              topLevelPackages = (getWorkspacePkgs pkgs);
              devShellHook = (mkDevShellHook pkgs);
            };
        };
      }
    ));
}
