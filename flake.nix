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

              # just to spare my syntax highligher :)
              escapeMadnessPrefix = ''\"\n\\\\033[1;96m'';
              escapeMadnessPostfix = ''\n\\\\033[0m\"'';
              doubleQuote = ''\"'';

              bashGetOpt = progname: ''
                # usage function
                function usage() {
                    echo "JSNIX development script for ${progname}"
                    echo ""
                    echo "Usage: ${progname} [--link PROJECT_ID] [--sidebuild PROJECT_ID] [--sidebuild-action ACTION_PATH]"
                    echo ""
                    echo "optional arguments:"
                    echo "-h, --help                         show this help message and exit"
                    echo "-l, --link PROJECT_ID              build a given projects scripts.build and symlink it"
                    echo "-b, --sidebuild PROJECT_ID         starts a watcher on given build of a given project scripts .build"
                    echo "-a, --sidebuild-action ACTION_PATH speficies"
                    echo ""
                }
                _watchexec_ps=
                link=
                sidebuild=
                sidebuild_action=
                opts="hlba"
                long_opts="help,link:,sidebuild:,sidebuild-action"

                while [[ ! -z "$1" ]]; do
                  getopt -o "$opts" -l "$long_opts" > /dev/null
                  case "$1" in
                    -h | --help ) usage; exit; ;;
                    -l | --link ) link="$2"; shift 2 ;;
                    -b | --sidebuild ) sidebuild="$2"; shift 2 ;;
                    -a | --sidebuild-action ) sidebuild_action="$2"; shift 2 ;;
                    -- ) shift; break ;;
                    * ) break ;;
                  esac
                done

                if [[ ! -z "$sidebuild" ]]; then
                  case "$sidebuild" in
                  ${builtins.concatStringsSep "\n"
                    (builtins.map
                      (k: ''${k} ) ${
                        if (builtins.hasAttr "scripts" workspaces.${k})
                        then
                          if (builtins.hasAttr "build" workspaces.${k}.scripts)
                          then ("( ${pkgs.watchexec}/bin/watchexec -w ${workspaces.${k}.projectDir} " +
                                "-r \"echo -e ${escapeMadnessPrefix}JSNIX sidebuild hook called ${workspaces.${k}.projectDir}...${escapeMadnessPostfix}" +
                                " ; ${k}-build\" & ) ; export _watchexec_ps=\"$!\" \n ;;")
                          else "echo \"No build target was defined in scripts for ${k}\" \n ;;"
                        else "echo \"${k} has no script targets whatsoever\" \n ;;"}
                        ''
                      )
                      (builtins.attrNames workspaces))}
                    * ) echo "no project in workspace: $sidebuild" ;;
                  esac
                fi
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

              getWorkspacePkgName = path:
                if (builtins.pathExists (flakePath + ("/" + path + "/package.nix")))
                then (import (flakePath + ("/" + path + "/package.nix"))).name
                else builtins.throw "Tried linking a package under ${path} but didn't find package.nix there";

              getWorkspacePkgs = pkgs: builtins.map
                ({ name, path }: (if (builtins.hasAttr "${name}" pkgs)
                                  then pkgs."${name}"
                                  else if (builtins.hasAttr "${name}" pkgs)
                                  then (import (flakePath ("/" + path + "/package-lock.nix")))
                                  else builtins.throw "package ${name} was not found in ${path}, did you remember to run `jsnix install` beforehand?"))
                (getWorkspacePkgNames workspaces);

              scriptWithAttrs =
                (pkgs.lib.attrsets.filterAttrs (k: v: (builtins.length v) > 0)
                  (pkgs.lib.attrsets.mapAttrs
                    (k: v: (
                      if (builtins.hasAttr "scripts" v)
                      then (builtins.attrValues
                        (pkgs.lib.attrsets.mapAttrs (sk: sv:
                          let text = ''
                            #!${pkgs.bash}/bin/bash
                            ${bashGetOpt "${k}-${sk}"}
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
                                          then ([pkgs.getopt workspaceImports.${k}.nodeModules] ++
                                                (pkgs.lib.optionals (builtins.hasAttr "buildInputs" workspaceImports.${k})
                                                  workspaceImports.${k}.buildInputs))
                                          else [pkgs.getopt];
                          }
                            ''
                              mkdir -p $out/bin
                              echo '${text}' > "$out/bin/${k}-${sk}"
                              echo PATH=$PATH:\$PATH >> "$out/bin/${k}-${sk}"
                              echo NODE_PATH=$NODE_PATH:\$NODE_PATH >> "$out/bin/${k}-${sk}"
                              echo '(${sv}); ret="$?";' >> "$out/bin/${k}-${sk}"
                              echo '[[ ! -z $_watchexec_ps ]] && kill -9 $_watchexec_ps || true;' >> "$out/bin/${k}-${sk}"
                              echo '[[ ! -z "$ret" ]] && exit $ret;' >> "$out/bin/${k}-${sk}"
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

              mkDevShellHook = pkgs: (
                ''
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
                '' + # pkgs.lib.foldr ({ name, path, drv }: acc:
                (builtins.concatStringsSep "\n"
                  (builtins.attrValues
                    (pkgs.lib.attrsets.mapAttrs (name: xform:
                      let pkgName = getWorkspacePkgName xform.projectDir;
                      in ''
                         (cd ${xform.projectDir}; rm -rf node_modules > /dev/null; rm -f package.json > /dev/null;
                          mkdir node_modules; ln -s ${pkgs.${pkgName}.nodeModules}/lib/node_modules/* node_modules/;
                          ln -s ${pkgs.${pkgName}.pkgJsonFile} package.json;
                          ${pkgs.lib.strings.optionalString (builtins.hasAttr "links" workspaces.${name})
                            (builtins.concatStringsSep "\n"
                              (builtins.map (link:
                                if (builtins.hasAttr link workspaces)
                                then let lp = getWorkspacePkgName workspaces.${link}.projectDir; in ''
                                  __root_link=$(echo '${lp}' | sed 's|/.*||g')
                                  rm -f node_modules/$__root_link > /dev/null 2>&1
                                  mkdir -p node_modules/${lp}

                                  _relp=${pkgs.coreutils}/bin/realpath \
                                    --relative-to="$ROOT_DIR/${xform.projectDir}/node_modules/$__root_link" \
                                    "$ROOT_DIR/${workspaces.${link}.projectDir}"
                                  for f in $_relp/*; do [ "$f" != "node_modules" ] && ln -s "$f" "node_modules/${lp}/$f"; done
                                  if [[ -d "${pkgs.${pkgName}.nodeModules}/lib/node_modules/${lp}/node_modules" ]]
                                  then
                                    ln -s ${pkgs.${pkgName}.nodeModules}/lib/node_modules/${lp}/node_modules \
                                      $ROOT_DIR/${xform.projectDir}/node_modules/${lp}/node_modules
                                  elif [[ -d "$_relp/node_modules" ]]
                                  then
                                    ln -s "$_relp/node_modules" "$ROOT_DIR/${xform.projectDir}/node_modules/${lp}/node_modules"
                                  fi
                                ''
                                else builtins.throw "A linked project ${name}->${link} is not declared!" )
                              workspaces.${name}.links))}
                          )
                        ''
                    )
                      workspaces))));
              # (getWorkspacePkgs__internal
              #   (builtins.map (p: p.projectDir)
              #     (builtins.attrValues workspaces)))));

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
