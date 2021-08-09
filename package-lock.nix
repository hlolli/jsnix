{pkgs, stdenv, lib, nodejs, fetchurl, fetchgit, fetchFromGitHub, jq, makeWrapper, python3, runCommand, runCommandCC, xcodebuild, ... }:

let
  packageNix = import ./package.nix;
  linkNodeModules = {dependencies ? [], extraDependencies ? []}:
    (lib.lists.foldr (dep: acc:
      let pkgName = if (builtins.hasAttr "packageName" dep)
                    then dep.packageName else dep.name;
      in (acc + (lib.optionalString
      ((lib.findSingle (px: px.packageName == dep.packageName) "none" "found" extraDependencies) == "none")
      ''
      if [[ ! -f "node_modules/${pkgName}" && \
            ! -d "node_modules/${pkgName}" && \
            ! -L "node_modules/${pkgName}" && \
            ! -e "node_modules/${pkgName}" ]]
     then
       mkdir -p "node_modules/${pkgName}"
       ln -s "${dep}/lib/node_modules/${pkgName}"/* "node_modules/${pkgName}"
       ${lib.optionalString (builtins.hasAttr "dependencies" dep)
         ''
         rm -rf "node_modules/${pkgName}/node_modules"
         (cd node_modules/${dep.packageName}; ${linkNodeModules { inherit (dep) dependencies; inherit extraDependencies;}})
         ''}
     fi
     '')))
     "" dependencies);
  copyNodeModules = {dependencies ? [], extraDependencies ? [], stripScripts ? false }:
    (lib.lists.foldr (dep: acc:
      let pkgName = if (builtins.hasAttr "packageName" dep)
                    then dep.packageName else dep.name;
      in (acc + (lib.optionalString
      ((lib.findSingle (px: px.packageName == dep.packageName) "none" "found" extraDependencies) == "none")
      ''
      if [[ ! -f "node_modules/${pkgName}" && \
            ! -d "node_modules/${pkgName}" && \
            ! -L "node_modules/${pkgName}" && \
            ! -e "node_modules/${pkgName}" ]]
     then
       mkdir -p "node_modules/${pkgName}"
       cp -rLT "${dep}/lib/node_modules/${pkgName}" "node_modules/${pkgName}"
       chmod -R +rw "node_modules/${pkgName}"
       ${lib.optionalString stripScripts "cat <<< $(jq 'del(.scripts,.bin)' \"node_modules/${pkgName}/package.json\") > \"node_modules/${pkgName}/package.json\""}
       ${lib.optionalString (builtins.hasAttr "dependencies" dep)
         "(cd node_modules/${dep.packageName}; ${linkNodeModules { inherit (dep) dependencies; inherit extraDependencies stripScripts; }})"}
     fi
     '')))
     "" dependencies);
  gitignoreSource = 
    (import (fetchFromGitHub {
      owner = "hercules-ci";
      repo = "gitignore.nix";
      rev = "211907489e9f198594c0eb0ca9256a1949c9d412";
      sha256 = "sha256-qHu3uZ/o9jBHiA3MEKHJ06k7w4heOhA+4HCSIvflRxo=";
    }) { inherit lib; }).gitignoreSource;
  transitiveDepInstallPhase = {dependencies ? [], pkgName}: ''
    export packageDir="$(pwd)"
    mkdir -p $out/lib/node_modules/${pkgName}
    cd $out/lib/node_modules/${pkgName}
    cp -rfT "$packageDir" "$(pwd)"
    mkdir -p node_modules/.bin
    ${linkNodeModules { inherit dependencies; }} '';
  transitiveDepUnpackPhase = {dependencies ? [], pkgName}: ''
     unpackFile "$src";
     # not ideal, but some perms are fubar
     chmod -R +777 . || true
     packageDir="$(find . -maxdepth 1 -type d | tail -1)"
     cd "$packageDir"
   '';
  getNodeDep = packageName: dependencies:
    (let depList = if ((builtins.typeOf dependencies) == "set")
                  then (builtins.attrValues dependencies)
                  else dependencies;
    in (builtins.head
        (builtins.filter (p: p.packageName == packageName) depList)));
  nodeSources = runCommand "node-sources" {} ''
    tar --no-same-owner --no-same-permissions -xf ${nodejs.src}
    mv node-* $out
  '';
  flattenScript = ''
    ${goFlatten}/bin/flatten
'';
  sanitizeName = nm: lib.strings.sanitizeDerivationName
    (builtins.replaceStrings [ "@" "/" ] [ "_at_" "_" ] nm);
  jsnixDrvOverrides = { drv, jsnixDeps ? {} }:
    let skipUnpackFor = if (builtins.hasAttr "skipUnpackFor" drv)
                        then drv.skipUnpackFor else [];
        copyUnpackFor = if (builtins.hasAttr "copyUnpackFor" drv)
                        then drv.copyUnpackFor else [];
        linkDeps = (builtins.filter
                                (p: (((lib.findSingle (px: px == p.packageName) "none" "found" skipUnpackFor) == "none") &&
                                      (lib.findSingle (px: px == p.packageName) "none" "found" copyUnpackFor) == "none"))
                              (builtins.map
                              (dep: jsnixDeps."${dep}")
                              (builtins.attrNames packageNix.dependencies)));
         copyDeps = (builtins.filter
                                (p: (((lib.findSingle (px: px == p.packageName) "none" "found" skipUnpackFor) == "none") &&
                                      (lib.findSingle (px: px == p.packageName) "none" "found" copyUnpackFor) == "found"))
                                (builtins.map
                                    (dep: jsnixDeps."${dep}")
                                    (builtins.attrNames packageNix.dependencies)));
         extraLinkDeps = (builtins.filter
                                (p: (((lib.findSingle (px: px == p.packageName) "none" "found" skipUnpackFor) == "none") &&
                                      (lib.findSingle (px: px == p.packageName) "none" "found" copyUnpackFor) == "none"))
                                (if (builtins.hasAttr "extraDependencies" drv) then drv.extraDependencies else []));
         extraCopyDeps = (builtins.filter
                                (p: (((lib.findSingle (px: px == p.packageName) "none" "found" skipUnpackFor) == "none") &&
                                      (lib.findSingle (px: px == p.packageName) "none" "found" copyUnpackFor) == "found"))
                                (if (builtins.hasAttr "extraDependencies" drv) then drv.extraDependencies else []));
         buildDepDep = lib.lists.unique (lib.lists.concatMap (d: d.buildInputs) (linkDeps ++ copyDeps));
         nodeModules = runCommandCC "${sanitizeName packageNix.name}_node_modules" { buildInputs = buildDepDep; } ''
           echo 'unpack, dedupe and flatten dependencies...'
           mkdir -p $out/lib/node_modules
           cd $out/lib
           ${linkNodeModules {
                dependencies = linkDeps;
                extraDependencies = (lib.optionals (builtins.hasAttr "extraDependencies" drv) drv.extraDependencies);
           }}
           ${copyNodeModules {
                dependencies = copyDeps;
                extraDependencies = (lib.optionals (builtins.hasAttr "extraDependencies" drv) drv.extraDependencies);
           }}
           ${copyNodeModules {
                dependencies = extraCopyDeps;
                stripScripts = true;
           }}
           ${linkNodeModules {
                dependencies = extraLinkDeps;
           }}
           chmod -R +rw node_modules
           ${flattenScript}
           export HOME=$TMPDIR
           npm --offline config set node_gyp ${nodejs}/lib/node_modules/npm/node_modules/node-gyp/bin/node-gyp.js
           npm --offline config set global_style true
           NODE_PATH="$(pwd)/node_modules:$NODE_PATH" \
             npm --offline --no-bin-links --nodedir=${nodeSources} \
               "--production" "--preserve-symlinks" rebuild
        '';
    in stdenv.mkDerivation (drv // {
      inherit nodeModules;
      version = packageNix.version;
      name = sanitizeName packageNix.name;
      packageJson = "${builtins.placeholder "out"}/lib/node_modules/${packageNix.name}";
      preUnpackBan_ = mkPhaseBan "preUnpack" drv;
      unpackBan_ = mkPhaseBan "unpackPhase" drv;
      postUnpackBan_ = mkPhaseBan "postUnpack" drv;
      preConfigureBan_ = mkPhaseBan "preConfigure" drv;
      configureBan_ = mkPhaseBan "configurePhase" drv;
      postConfigureBan_ = mkPhaseBan "postConfigure" drv;
      src = if (builtins.hasAttr "src" packageNix) then packageNix.src else gitignoreSource ./.;
      packageName = packageNix.name;
      dontStrip = true;
      doUnpack = true;
      NODE_OPTIONS = "--preserve-symlinks";
      buildInputs = [ nodejs jq ] ++ lib.optionals (builtins.hasAttr "buildInputs" drv) drv.buildInputs;
      passAsFile = [ "unpackFlattenDedupe" ];

      unpackFlattenDedupe = ''
        mkdir -p node_modules
        chmod -R +rw node_modules
        cp -arfT ${nodeModules}/lib/node_modules node_modules
        export NODE_PATH="$(pwd)/node_modules:$NODE_PATH"
        export NODE_OPTIONS="--preserve-symlinks"
        echo ${toPackageJson { inherit jsnixDeps; }} > package.json
        cat <<< $(jq "package.json") > "package.json"
      '';
      configurePhase = ''
        source $unpackFlattenDedupePath
      '';
      buildPhase = ''
        runHook preBuild
       ${lib.optionalString (builtins.hasAttr "buildPhase" drv) drv.buildPhase}
       runHook postBuild
      '';
      installPhase = if (builtins.hasAttr "installPhase" drv) then
        ''
          runHook preInstall
            ${drv.installPhase}
          runHook postInstall
        '' else ''
          runHook preInstall
          if [[ -d "./bin" ]]
          then
            mkdir $out/bin
            ln -s ./bin/* $out/bin
          fi
          if [[ -d "./node_modules" ]]
          then
            find ./node_modules -maxdepth 2 -name '*package.json' ! -name "*@*" | while read d; do
              chmod +rw "$(dirname $d)"
              chmod +rw "$d" 2>/dev/null || true
              if [ -w "$d" ]
              then
                cat <<< $(jq 'del(.scripts,.bin)' "$d") > "$d"
              else
                orig="$(readlink $(echo $d))"
                rm -f "$d"
                cp -f "$orig" "$d" && chmod 0666 "$d" 2>/dev/null || true
                cat <<< $(jq 'del(.scripts,.bin)' "$d") > "$d"
              fi
            done
          fi
           mkdir -p $out/lib/node_modules/${packageNix.name}
          cp -rfL ./ $out/lib/node_modules/${packageNix.name}
          runHook postInstall
       '';
  });
  toPackageJson = { jsnixDeps ? {} }:
    let
      main = if (builtins.hasAttr "main" packageNix) then packageNix else throw "package.nix is missing main attribute";
      pkgName = if (builtins.hasAttr "packageName" packageNix)
                then packageNix.packageName else packageNix.name;
      packageNixDeps = if (builtins.hasAttr "dependencies" packageNix)
                       then packageNix.dependencies
                       else {};
      prodDeps = lib.lists.foldr
        (depName: acc: acc // {
          "${depName}" = (if ((builtins.typeOf packageNixDeps."${depName}") == "string")
                          then packageNixDeps."${depName}"
                          else
                            if (((builtins.typeOf packageNixDeps."${depName}") == "set") &&
                                ((builtins.typeOf packageNixDeps."${depName}".version) == "string"))
                          then packageNixDeps."${depName}".version
                          else "latest");}) {} (builtins.attrNames packageNixDeps);
      safePkgNix = lib.lists.foldr (key: acc:
        if ((builtins.typeOf packageNix."${key}") != "lambda")
        then (acc // { "${key}" =  packageNix."${key}"; })
        else acc)
        {} (builtins.attrNames packageNix);
    in lib.strings.escapeNixString
      (builtins.toJSON (safePkgNix // { dependencies = prodDeps; name = pkgName; }));
  mkPhaseBan = phaseName: usrDrv:
      if (builtins.hasAttr phaseName usrDrv) then
      throw "jsnix error: using ${phaseName} isn't supported at this time"
      else  "";
  mkPhase = pkgs_: {phase, pkgName}:
     lib.optionalString ((builtins.hasAttr "${pkgName}" packageNix.dependencies) &&
                         (builtins.typeOf packageNix.dependencies."${pkgName}" == "set") &&
                         (builtins.hasAttr "${phase}" packageNix.dependencies."${pkgName}"))
      (if builtins.typeOf packageNix.dependencies."${pkgName}"."${phase}" == "string"
       then
         packageNix.dependencies."${pkgName}"."${phase}"
       else
         (packageNix.dependencies."${pkgName}"."${phase}" (pkgs_ // { inherit getNodeDep copyNodeModules linkNodeModules; })));
  mkExtraBuildInputs = pkgs_: {pkgName}:
     lib.optionals ((builtins.hasAttr "${pkgName}" packageNix.dependencies) &&
                    (builtins.typeOf packageNix.dependencies."${pkgName}" == "set") &&
                    (builtins.hasAttr "extraBuildInputs" packageNix.dependencies."${pkgName}"))
      (if builtins.typeOf packageNix.dependencies."${pkgName}"."extraBuildInputs" == "list"
       then
         packageNix.dependencies."${pkgName}"."extraBuildInputs"
       else
         (packageNix.dependencies."${pkgName}"."extraBuildInputs" (pkgs_ // { inherit getNodeDep copyNodeModules linkNodeModules; })));
  mkExtraDependencies = pkgs_: {pkgName}:
     lib.optionals ((builtins.hasAttr "${pkgName}" packageNix.dependencies) &&
                    (builtins.typeOf packageNix.dependencies."${pkgName}" == "set") &&
                    (builtins.hasAttr "extraDependencies" packageNix.dependencies."${pkgName}"))
      (if builtins.typeOf packageNix.dependencies."${pkgName}"."extraDependencies" == "list"
       then
         packageNix.dependencies."${pkgName}"."extraDependencies"
       else
         (packageNix.dependencies."${pkgName}"."extraDependencies" (pkgs_ // { inherit getNodeDep copyNodeModules linkNodeModules; })));
  mkUnpackScript = { dependencies ? [], extraDependencies ? [], pkgName }:
     let copyNodeDependencies =
       if ((builtins.hasAttr "${pkgName}" packageNix.dependencies) &&
           (builtins.typeOf packageNix.dependencies."${pkgName}" == "set") &&
           (builtins.hasAttr "copyNodeDependencies" packageNix.dependencies."${pkgName}") &&
           (builtins.typeOf packageNix.dependencies."${pkgName}"."copyNodeDependencies" == "bool") &&
           (packageNix.dependencies."${pkgName}"."copyNodeDependencies" == true))
       then true else false;
     in ''
      ${(if copyNodeDependencies then copyNodeModules else linkNodeModules) { inherit dependencies extraDependencies; }}
      chmod -R +rw $(pwd)
    '';
  mkConfigureScript = {}: ''
    ${flattenScript}
'';
  mkBuildScript = { dependencies ? [], pkgName }:
    let extraNpmFlags =
      if ((builtins.hasAttr "${pkgName}" packageNix.dependencies) &&
          (builtins.typeOf packageNix.dependencies."${pkgName}" == "set") &&
          (builtins.hasAttr "npmFlags" packageNix.dependencies."${pkgName}") &&
          (builtins.typeOf packageNix.dependencies."${pkgName}"."npmFlags" == "string"))
      then packageNix.dependencies."${pkgName}"."npmFlags" else "";
    in ''
      runHook preBuild
      export HOME=$TMPDIR
      npm --offline config set node_gyp ${nodejs}/lib/node_modules/npm/node_modules/node-gyp/bin/node-gyp.js
      npm --offline config set omit dev
      NODE_PATH="$(pwd)/node_modules:$NODE_PATH" \
      npm --offline --nodedir=${nodeSources} --location="$(pwd)" \
          ${extraNpmFlags} "--production" "--preserve-symlinks" \
          rebuild --build-from-source
      runHook postBuild
    '';
  mkInstallScript = { pkgName }: ''
      runHook preInstall
      export packageDir="$(pwd)"
      mkdir -p $out/lib/node_modules/${pkgName}
      cd $out/lib/node_modules/${pkgName}
      cp -rfT "$packageDir" "$(pwd)"
      if [[ -d "$out/lib/node_modules/${pkgName}/bin" ]]
      then
         mkdir -p $out/bin
         ln -s "$out/lib/node_modules/${pkgName}/bin"/* $out/bin
      fi
      cd $out/lib/node_modules/${pkgName}
      runHook postInstall
    '';
  goFlatten = pkgs.buildGoModule {
  pname = "flatten";
  version = "0.0.0";
  vendorSha256 = null;
  src = pkgs.fetchFromGitHub {
    owner = "hlolli";
    repo = "jsnix";
    rev = "0c04c09759f4f34689db025cdde6d6d44bcc3c74";
    sha256 = "JPYOxtbX7wEO19PFsVYmMxW/ZzjnaLvd/cbpK2hskkk=";
  };
  preBuild = ''
    cd go
  '';
};
  sources = rec {
    "@npmcli/move-file-1.1.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_npmcli_slash_move-file";
      packageName = "@npmcli/move-file";
      version = "1.1.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@npmcli/move-file"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@npmcli/move-file"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/@npmcli/move-file/-/move-file-1.1.2.tgz";
        sha512 = "1SUf/Cg2GzGDyaf15aR9St9TWlb+XvbZXWpDx8YKs7MLzMH/BCeopv+y9vzrzgkfykCGuWOlSu3mZhj2+FQcrg==";
      };
    };
    "@tootallnate/once-1.1.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_tootallnate_slash_once";
      packageName = "@tootallnate/once";
      version = "1.1.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@tootallnate/once"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@tootallnate/once"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/@tootallnate/once/-/once-1.1.2.tgz";
        sha512 = "RbzJvlNzmRq5c3O09UipeuXno4tA1FE6ikOjxZK0tuxVv3412l64l5t1W5pj4+rJq9vpkm/kwiR07aZXnsKPxw==";
      };
    };
    "abbrev-1.1.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "abbrev";
      packageName = "abbrev";
      version = "1.1.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "abbrev"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "abbrev"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/abbrev/-/abbrev-1.1.1.tgz";
        sha512 = "nne9/IiQ/hzIhY6pdDnbBtz7DjPTKrY00P/zvPSm5pOFkl6xuGrGnXn/VtTNNfNtAfZ9/1RtehkszU9qcTii0Q==";
      };
    };
    "agent-base-6.0.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "agent-base";
      packageName = "agent-base";
      version = "6.0.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "agent-base"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "agent-base"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/agent-base/-/agent-base-6.0.2.tgz";
        sha512 = "RZNwNclF7+MS/8bDg70amg32dyeZGZxiDuQmZxKLAlQjr3jGyLx+4Kkk58UO7D2QdgFIQCovuSuZESne6RG6XQ==";
      };
    };
    "agentkeepalive-4.1.4" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "agentkeepalive";
      packageName = "agentkeepalive";
      version = "4.1.4";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "agentkeepalive"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "agentkeepalive"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/agentkeepalive/-/agentkeepalive-4.1.4.tgz";
        sha512 = "+V/rGa3EuU74H6wR04plBb7Ks10FbtUQgRj/FQOG7uUIEuaINI+AiqJR1k6t3SVNs7o7ZjIdus6706qqzVq8jQ==";
      };
    };
    "aggregate-error-3.1.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "aggregate-error";
      packageName = "aggregate-error";
      version = "3.1.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "aggregate-error"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "aggregate-error"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/aggregate-error/-/aggregate-error-3.1.0.tgz";
        sha512 = "4I7Td01quW/RpocfNayFdFVk1qSuoh0E7JrbRJ16nH01HhKFQ88INq9Sd+nd72zqRySlr9BmDA8xlEJ6vJMrYA==";
      };
    };
    "ansi-regex-2.1.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "ansi-regex";
      packageName = "ansi-regex";
      version = "2.1.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "ansi-regex"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "ansi-regex"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/ansi-regex/-/ansi-regex-2.1.1.tgz";
        sha1 = "c3b33ab5ee360d86e0e628f0468ae7ef27d654df";
      };
    };
    "aproba-1.2.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "aproba";
      packageName = "aproba";
      version = "1.2.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "aproba"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "aproba"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/aproba/-/aproba-1.2.0.tgz";
        sha512 = "Y9J6ZjXtoYh8RnXVCMOU/ttDmk1aBjunq9vO0ta5x85WDQiQfUF9sIPBITdbiiIVcBo03Hi3jMxigBtsddlXRw==";
      };
    };
    "are-we-there-yet-1.1.5" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "are-we-there-yet";
      packageName = "are-we-there-yet";
      version = "1.1.5";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "are-we-there-yet"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "are-we-there-yet"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/are-we-there-yet/-/are-we-there-yet-1.1.5.tgz";
        sha512 = "5hYdAkZlcG8tOLujVDTgCT+uPX0VnpAH28gWsLfzpXYm7wP6mp5Q/gYyR7YQ0cKVJcXJnl3j2kpBan13PtQf6w==";
      };
    };
    "balanced-match-1.0.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "balanced-match";
      packageName = "balanced-match";
      version = "1.0.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "balanced-match"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "balanced-match"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/balanced-match/-/balanced-match-1.0.2.tgz";
        sha512 = "3oSeUO0TMV67hN1AmbXsK4yaqU7tjiHlbxRDZOpH0KW9+CeX4bRAaX0Anxt0tx2MrpRpWwQaPwIlISEJhYU5Pw==";
      };
    };
    "brace-expansion-1.1.11" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "brace-expansion";
      packageName = "brace-expansion";
      version = "1.1.11";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "brace-expansion"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "brace-expansion"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/brace-expansion/-/brace-expansion-1.1.11.tgz";
        sha512 = "iCuPHDFgrHX7H2vEI/5xpz07zSHB00TpugqhmYtVmMO6518mCuRMoOYFldEBl0g187ufozdaHgWKcYFb61qGiA==";
      };
    };
    "builtins-1.0.3" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "builtins";
      packageName = "builtins";
      version = "1.0.3";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "builtins"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "builtins"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/builtins/-/builtins-1.0.3.tgz";
        sha1 = "cb94faeb61c8696451db36534e1422f94f0aee88";
      };
    };
    "cacache-15.2.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "cacache";
      packageName = "cacache";
      version = "15.2.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "cacache"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "cacache"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/cacache/-/cacache-15.2.0.tgz";
        sha512 = "uKoJSHmnrqXgthDFx/IU6ED/5xd+NNGe+Bb+kLZy7Ku4P+BaiWEUflAKPZ7eAzsYGcsAGASJZsybXp+quEcHTw==";
      };
    };
    "call-bind-1.0.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "call-bind";
      packageName = "call-bind";
      version = "1.0.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "call-bind"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "call-bind"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/call-bind/-/call-bind-1.0.2.tgz";
        sha512 = "7O+FbCihrB5WGbFYesctwmTKae6rOiIzmz1icreWJ+0aA7LJfuqhEso2T9ncpcFtzMQtzXf2QGGueWJGTYsqrA==";
      };
    };
    "chownr-2.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "chownr";
      packageName = "chownr";
      version = "2.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "chownr"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "chownr"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/chownr/-/chownr-2.0.0.tgz";
        sha512 = "bIomtDF5KGpdogkLd9VspvFzk9KfpyyGlS8YFVZl7TGPBHL5snIOnxeshwVgPteQ9b4Eydl+pVbIyE1DcvCWgQ==";
      };
    };
    "clean-stack-2.2.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "clean-stack";
      packageName = "clean-stack";
      version = "2.2.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "clean-stack"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "clean-stack"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/clean-stack/-/clean-stack-2.2.0.tgz";
        sha512 = "4diC9HaTE+KRAMWhDhrGOECgWZxoevMc5TlkObMqNSsVU62PYzXZ/SMTjzyGAFF1YusgxGcSWTEXBhp0CPwQ1A==";
      };
    };
    "code-point-at-1.1.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "code-point-at";
      packageName = "code-point-at";
      version = "1.1.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "code-point-at"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "code-point-at"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/code-point-at/-/code-point-at-1.1.0.tgz";
        sha1 = "0d070b4d043a5bea33a2f1a40e2edb3d9a4ccf77";
      };
    };
    "concat-map-0.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "concat-map";
      packageName = "concat-map";
      version = "0.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "concat-map"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "concat-map"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/concat-map/-/concat-map-0.0.1.tgz";
        sha1 = "d8a96bd77fd68df7793a73036a3ba0d5405d477b";
      };
    };
    "config-chain-1.1.13" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "config-chain";
      packageName = "config-chain";
      version = "1.1.13";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "config-chain"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "config-chain"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/config-chain/-/config-chain-1.1.13.tgz";
        sha512 = "qj+f8APARXHrM0hraqXYb2/bOVSV4PvJQlNZ/DVj0QrmNM2q2euizkeuVckQ57J+W0mRH6Hvi+k50M4Jul2VRQ==";
      };
    };
    "console-control-strings-1.1.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "console-control-strings";
      packageName = "console-control-strings";
      version = "1.1.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "console-control-strings"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "console-control-strings"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/console-control-strings/-/console-control-strings-1.1.0.tgz";
        sha1 = "3d7cf4464db6446ea644bf4b39507f9851008e8e";
      };
    };
    "core-util-is-1.0.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "core-util-is";
      packageName = "core-util-is";
      version = "1.0.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "core-util-is"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "core-util-is"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/core-util-is/-/core-util-is-1.0.2.tgz";
        sha1 = "b5fd54220aa2bc5ab57aab7140c940754503c1a7";
      };
    };
    "debug-4.3.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "debug";
      packageName = "debug";
      version = "4.3.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "debug"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "debug"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/debug/-/debug-4.3.2.tgz";
        sha512 = "mOp8wKcvj7XxC78zLgw/ZA+6TSgkoE2C/ienthhRD298T7UNwAg9diBpLRxC0mOezLl4B0xV7M0cCO6P/O0Xhw==";
      };
    };
    "decode-uri-component-0.2.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "decode-uri-component";
      packageName = "decode-uri-component";
      version = "0.2.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "decode-uri-component"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "decode-uri-component"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/decode-uri-component/-/decode-uri-component-0.2.0.tgz";
        sha1 = "eb3913333458775cb84cd1a1fae062106bb87545";
      };
    };
    "delegates-1.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "delegates";
      packageName = "delegates";
      version = "1.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "delegates"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "delegates"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/delegates/-/delegates-1.0.0.tgz";
        sha1 = "84c6e159b81904fdca59a0ef44cd870d31250f9a";
      };
    };
    "depd-1.1.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "depd";
      packageName = "depd";
      version = "1.1.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "depd"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "depd"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/depd/-/depd-1.1.2.tgz";
        sha1 = "9bcd52e14c097763e749b274c4346ed2e560b5a9";
      };
    };
    "err-code-2.0.3" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "err-code";
      packageName = "err-code";
      version = "2.0.3";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "err-code"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "err-code"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/err-code/-/err-code-2.0.3.tgz";
        sha512 = "2bmlRpNKBxT/CRmPOlyISQpNj+qSeYvcym/uT0Jx2bMOlKLtSy1ZmLuVxSEKKyor/N5yhvp/ZiG1oE3DEYMSFA==";
      };
    };
    "filter-obj-1.1.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "filter-obj";
      packageName = "filter-obj";
      version = "1.1.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "filter-obj"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "filter-obj"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/filter-obj/-/filter-obj-1.1.0.tgz";
        sha1 = "9b311112bc6c6127a16e016c6c5d7f19e0805c5b";
      };
    };
    "fs-minipass-2.1.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "fs-minipass";
      packageName = "fs-minipass";
      version = "2.1.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "fs-minipass"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "fs-minipass"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/fs-minipass/-/fs-minipass-2.1.0.tgz";
        sha512 = "V/JgOLFCS+R6Vcq0slCuaeWEdNC3ouDlJMNIsacH2VtALiu9mV4LPrHc5cDl8k5aw6J8jwgWWpiTo5RYhmIzvg==";
      };
    };
    "fs.realpath-1.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "fs.realpath";
      packageName = "fs.realpath";
      version = "1.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "fs.realpath"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "fs.realpath"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/fs.realpath/-/fs.realpath-1.0.0.tgz";
        sha1 = "1504ad2523158caa40db4a2787cb01411994ea4f";
      };
    };
    "function-bind-1.1.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "function-bind";
      packageName = "function-bind";
      version = "1.1.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "function-bind"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "function-bind"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/function-bind/-/function-bind-1.1.1.tgz";
        sha512 = "yIovAzMX49sF8Yl58fSCWJ5svSLuaibPxXQJFLmBObTuCr0Mf1KiPopGM9NiFjiYBCbfaa2Fh6breQ6ANVTI0A==";
      };
    };
    "gauge-2.7.4" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "gauge";
      packageName = "gauge";
      version = "2.7.4";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "gauge"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "gauge"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/gauge/-/gauge-2.7.4.tgz";
        sha1 = "2c03405c7538c39d7eb37b317022e325fb018bf7";
      };
    };
    "get-intrinsic-1.1.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "get-intrinsic";
      packageName = "get-intrinsic";
      version = "1.1.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "get-intrinsic"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "get-intrinsic"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/get-intrinsic/-/get-intrinsic-1.1.1.tgz";
        sha512 = "kWZrnVM42QCiEA2Ig1bG8zjoIMOgxWwYCEeNdwY6Tv/cOSeGpcoX4pXHfKUxNKVoArnrEr2e9srnAxxGIraS9Q==";
      };
    };
    "git-up-4.0.5" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "git-up";
      packageName = "git-up";
      version = "4.0.5";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "git-up"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "git-up"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/git-up/-/git-up-4.0.5.tgz";
        sha512 = "YUvVDg/vX3d0syBsk/CKUTib0srcQME0JyHkL5BaYdwLsiCslPWmDSi8PUMo9pXYjrryMcmsCoCgsTpSCJEQaA==";
      };
    };
    "glob-7.1.7" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "glob";
      packageName = "glob";
      version = "7.1.7";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "glob"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "glob"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/glob/-/glob-7.1.7.tgz";
        sha512 = "OvD9ENzPLbegENnYP5UUfJIirTg4+XwMWGaQfQTY0JenxNvvIKP3U3/tAQSPIu/lHxXYSZmpXlUHeqAIdKzBLQ==";
      };
    };
    "graceful-fs-4.2.6" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "graceful-fs";
      packageName = "graceful-fs";
      version = "4.2.6";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "graceful-fs"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "graceful-fs"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/graceful-fs/-/graceful-fs-4.2.6.tgz";
        sha512 = "nTnJ528pbqxYanhpDYsi4Rd8MAeaBA67+RZ10CM1m3bTAVFEDcd5AuA4a6W5YkGZ1iNXHzZz8T6TBKLeBuNriQ==";
      };
    };
    "has-1.0.3" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "has";
      packageName = "has";
      version = "1.0.3";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "has"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "has"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/has/-/has-1.0.3.tgz";
        sha512 = "f2dvO0VU6Oej7RkWJGrehjbzMAjFp5/VKPp5tTpWIV4JHHZK1/BxbFRtf/siA2SWTe09caDmVtYYzWEIbBS4zw==";
      };
    };
    "has-symbols-1.0.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "has-symbols";
      packageName = "has-symbols";
      version = "1.0.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "has-symbols"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "has-symbols"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/has-symbols/-/has-symbols-1.0.2.tgz";
        sha512 = "chXa79rL/UC2KlX17jo3vRGz0azaWEx5tGqZg5pO3NUyEJVB17dMruQlzCCOfUvElghKcm5194+BCRvi2Rv/Gw==";
      };
    };
    "has-unicode-2.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "has-unicode";
      packageName = "has-unicode";
      version = "2.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "has-unicode"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "has-unicode"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/has-unicode/-/has-unicode-2.0.1.tgz";
        sha1 = "e0e6fe6a28cf51138855e086d1691e771de2a8b9";
      };
    };
    "hosted-git-info-4.0.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "hosted-git-info";
      packageName = "hosted-git-info";
      version = "4.0.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "hosted-git-info"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "hosted-git-info"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/hosted-git-info/-/hosted-git-info-4.0.2.tgz";
        sha512 = "c9OGXbZ3guC/xOlCg1Ci/VgWlwsqDv1yMQL1CWqXDL0hDjXuNcq0zuR4xqPSuasI3kqFDhqSyTjREz5gzq0fXg==";
      };
    };
    "http-cache-semantics-4.1.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "http-cache-semantics";
      packageName = "http-cache-semantics";
      version = "4.1.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "http-cache-semantics"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "http-cache-semantics"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/http-cache-semantics/-/http-cache-semantics-4.1.0.tgz";
        sha512 = "carPklcUh7ROWRK7Cv27RPtdhYhUsela/ue5/jKzjegVvXDqM2ILE9Q2BGn9JZJh1g87cp56su/FgQSzcWS8cQ==";
      };
    };
    "http-proxy-agent-4.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "http-proxy-agent";
      packageName = "http-proxy-agent";
      version = "4.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "http-proxy-agent"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "http-proxy-agent"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/http-proxy-agent/-/http-proxy-agent-4.0.1.tgz";
        sha512 = "k0zdNgqWTGA6aeIRVpvfVob4fL52dTfaehylg0Y4UvSySvOq/Y+BOyPrgpUrA7HylqvU8vIZGsRuXmspskV0Tg==";
      };
    };
    "https-proxy-agent-5.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "https-proxy-agent";
      packageName = "https-proxy-agent";
      version = "5.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "https-proxy-agent"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "https-proxy-agent"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/https-proxy-agent/-/https-proxy-agent-5.0.0.tgz";
        sha512 = "EkYm5BcKUGiduxzSt3Eppko+PiNWNEpa4ySk9vTC6wDsQJW9rHSa+UhGNJoRYp7bz6Ht1eaRIa6QaJqO5rCFbA==";
      };
    };
    "humanize-ms-1.2.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "humanize-ms";
      packageName = "humanize-ms";
      version = "1.2.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "humanize-ms"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "humanize-ms"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/humanize-ms/-/humanize-ms-1.2.1.tgz";
        sha1 = "c46e3159a293f6b896da29316d8b6fe8bb79bbed";
      };
    };
    "imurmurhash-0.1.4" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "imurmurhash";
      packageName = "imurmurhash";
      version = "0.1.4";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "imurmurhash"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "imurmurhash"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/imurmurhash/-/imurmurhash-0.1.4.tgz";
        sha1 = "9218b9b2b928a238b13dc4fb6b6d576f231453ea";
      };
    };
    "indent-string-4.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "indent-string";
      packageName = "indent-string";
      version = "4.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "indent-string"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "indent-string"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/indent-string/-/indent-string-4.0.0.tgz";
        sha512 = "EdDDZu4A2OyIK7Lr/2zG+w5jmbuk1DVBnEwREQvBzspBJkCEbRa8GxU1lghYcaGJCnRWibjDXlq779X1/y5xwg==";
      };
    };
    "infer-owner-1.0.4" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "infer-owner";
      packageName = "infer-owner";
      version = "1.0.4";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "infer-owner"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "infer-owner"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/infer-owner/-/infer-owner-1.0.4.tgz";
        sha512 = "IClj+Xz94+d7irH5qRyfJonOdfTzuDaifE6ZPWfx0N0+/ATZCbuTPq2prFl526urkQd90WyUKIh1DfBQ2hMz9A==";
      };
    };
    "inflight-1.0.6" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "inflight";
      packageName = "inflight";
      version = "1.0.6";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "inflight"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "inflight"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/inflight/-/inflight-1.0.6.tgz";
        sha1 = "49bd6331d7d02d0c09bc910a1075ba8165b56df9";
      };
    };
    "inherits-2.0.4" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "inherits";
      packageName = "inherits";
      version = "2.0.4";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "inherits"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "inherits"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/inherits/-/inherits-2.0.4.tgz";
        sha512 = "k/vGaX4/Yla3WzyMCvTQOXYeIHvqOKtnqBduzTHpzpQZzAskKMhZ2K+EnBiSM9zGSoIFeMpXKxa4dYeZIQqewQ==";
      };
    };
    "ini-1.3.8" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "ini";
      packageName = "ini";
      version = "1.3.8";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "ini"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "ini"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/ini/-/ini-1.3.8.tgz";
        sha512 = "JV/yugV2uzW5iMRSiZAyDtQd+nxtUnjeLt0acNdw98kKLrvuRVyB80tsREOE7yvGVgalhZ6RNXCmEHkUKBKxew==";
      };
    };
    "ip-1.1.5" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "ip";
      packageName = "ip";
      version = "1.1.5";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "ip"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "ip"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/ip/-/ip-1.1.5.tgz";
        sha1 = "bdded70114290828c0a039e72ef25f5aaec4354a";
      };
    };
    "is-fullwidth-code-point-1.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "is-fullwidth-code-point";
      packageName = "is-fullwidth-code-point";
      version = "1.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "is-fullwidth-code-point"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "is-fullwidth-code-point"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/is-fullwidth-code-point/-/is-fullwidth-code-point-1.0.0.tgz";
        sha1 = "ef9e31386f031a7f0d643af82fde50c457ef00cb";
      };
    };
    "is-lambda-1.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "is-lambda";
      packageName = "is-lambda";
      version = "1.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "is-lambda"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "is-lambda"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/is-lambda/-/is-lambda-1.0.1.tgz";
        sha1 = "3d9877899e6a53efc0160504cde15f82e6f061d5";
      };
    };
    "is-ssh-1.3.3" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "is-ssh";
      packageName = "is-ssh";
      version = "1.3.3";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "is-ssh"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "is-ssh"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/is-ssh/-/is-ssh-1.3.3.tgz";
        sha512 = "NKzJmQzJfEEma3w5cJNcUMxoXfDjz0Zj0eyCalHn2E6VOwlzjZo0yuO2fcBSf8zhFuVCL/82/r5gRcoi6aEPVQ==";
      };
    };
    "isarray-1.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "isarray";
      packageName = "isarray";
      version = "1.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "isarray"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "isarray"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/isarray/-/isarray-1.0.0.tgz";
        sha1 = "bb935d48582cba168c06834957a54a3e07124f11";
      };
    };
    "jsonfile-6.1.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "jsonfile";
      packageName = "jsonfile";
      version = "6.1.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "jsonfile"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "jsonfile"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/jsonfile/-/jsonfile-6.1.0.tgz";
        sha512 = "5dgndWOriYSm5cnYaJNhalLNDKOqFwyDB/rr1E9ZsGciGvKPs8R2xYGCacuf3z6K1YKDz182fd+fY3cn3pMqXQ==";
      };
    };
    "jsonparse-1.3.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "jsonparse";
      packageName = "jsonparse";
      version = "1.3.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "jsonparse"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "jsonparse"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/jsonparse/-/jsonparse-1.3.1.tgz";
        sha1 = "3f4dae4a91fac315f71062f8521cc239f1366280";
      };
    };
    "lru-cache-6.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "lru-cache";
      packageName = "lru-cache";
      version = "6.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "lru-cache"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "lru-cache"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/lru-cache/-/lru-cache-6.0.0.tgz";
        sha512 = "Jo6dJ04CmSjuznwJSS3pUeWmd/H0ffTlkXXgwZi+eq1UCmqQwCh+eLsYOYCwY991i2Fah4h1BEMCx4qThGbsiA==";
      };
    };
    "make-fetch-happen-9.0.4" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "make-fetch-happen";
      packageName = "make-fetch-happen";
      version = "9.0.4";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "make-fetch-happen"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "make-fetch-happen"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/make-fetch-happen/-/make-fetch-happen-9.0.4.tgz";
        sha512 = "sQWNKMYqSmbAGXqJg2jZ+PmHh5JAybvwu0xM8mZR/bsTjGiTASj3ldXJV7KFHy1k/IJIBkjxQFoWIVsv9+PQMg==";
      };
    };
    "minimatch-3.0.4" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "minimatch";
      packageName = "minimatch";
      version = "3.0.4";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "minimatch"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "minimatch"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/minimatch/-/minimatch-3.0.4.tgz";
        sha512 = "yJHVQEhyqPLUTgt9B83PXu6W3rx4MvvHvSUvToogpwoGDOUQ+yDrR0HRot+yOCdCO7u4hX3pWft6kWBBcqh0UA==";
      };
    };
    "minimist-1.2.5" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "minimist";
      packageName = "minimist";
      version = "1.2.5";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "minimist"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "minimist"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/minimist/-/minimist-1.2.5.tgz";
        sha512 = "FM9nNUYrRBAELZQT3xeZQ7fmMOBg6nWNmJKTcgsJeaLstP/UODVpGsr5OhXhhXg6f+qtJ8uiZ+PUxkDWcgIXLw==";
      };
    };
    "minipass-3.1.3" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "minipass";
      packageName = "minipass";
      version = "3.1.3";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "minipass"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "minipass"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/minipass/-/minipass-3.1.3.tgz";
        sha512 = "Mgd2GdMVzY+x3IJ+oHnVM+KG3lA5c8tnabyJKmHSaG2kAGpudxuOf8ToDkhumF7UzME7DecbQE9uOZhNm7PuJg==";
      };
    };
    "minipass-collect-1.0.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "minipass-collect";
      packageName = "minipass-collect";
      version = "1.0.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "minipass-collect"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "minipass-collect"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/minipass-collect/-/minipass-collect-1.0.2.tgz";
        sha512 = "6T6lH0H8OG9kITm/Jm6tdooIbogG9e0tLgpY6mphXSm/A9u8Nq1ryBG+Qspiub9LjWlBPsPS3tWQ/Botq4FdxA==";
      };
    };
    "minipass-fetch-1.3.4" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "minipass-fetch";
      packageName = "minipass-fetch";
      version = "1.3.4";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "minipass-fetch"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "minipass-fetch"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/minipass-fetch/-/minipass-fetch-1.3.4.tgz";
        sha512 = "TielGogIzbUEtd1LsjZFs47RWuHHfhl6TiCx1InVxApBAmQ8bL0dL5ilkLGcRvuyW/A9nE+Lvn855Ewz8S0PnQ==";
      };
    };
    "minipass-flush-1.0.5" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "minipass-flush";
      packageName = "minipass-flush";
      version = "1.0.5";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "minipass-flush"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "minipass-flush"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/minipass-flush/-/minipass-flush-1.0.5.tgz";
        sha512 = "JmQSYYpPUqX5Jyn1mXaRwOda1uQ8HP5KAT/oDSLCzt1BYRhQU0/hDtsB1ufZfEEzMZ9aAVmsBw8+FWsIXlClWw==";
      };
    };
    "minipass-json-stream-1.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "minipass-json-stream";
      packageName = "minipass-json-stream";
      version = "1.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "minipass-json-stream"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "minipass-json-stream"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/minipass-json-stream/-/minipass-json-stream-1.0.1.tgz";
        sha512 = "ODqY18UZt/I8k+b7rl2AENgbWE8IDYam+undIJONvigAz8KR5GWblsFTEfQs0WODsjbSXWlm+JHEv8Gr6Tfdbg==";
      };
    };
    "minipass-pipeline-1.2.4" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "minipass-pipeline";
      packageName = "minipass-pipeline";
      version = "1.2.4";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "minipass-pipeline"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "minipass-pipeline"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/minipass-pipeline/-/minipass-pipeline-1.2.4.tgz";
        sha512 = "xuIq7cIOt09RPRJ19gdi4b+RiNvDFYe5JH+ggNvBqGqpQXcru3PcRmOZuHBKWK1Txf9+cQ+HMVN4d6z46LZP7A==";
      };
    };
    "minipass-sized-1.0.3" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "minipass-sized";
      packageName = "minipass-sized";
      version = "1.0.3";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "minipass-sized"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "minipass-sized"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/minipass-sized/-/minipass-sized-1.0.3.tgz";
        sha512 = "MbkQQ2CTiBMlA2Dm/5cY+9SWFEN8pzzOXi6rlM5Xxq0Yqbda5ZQy9sU75a673FE9ZK0Zsbr6Y5iP6u9nktfg2g==";
      };
    };
    "minizlib-2.1.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "minizlib";
      packageName = "minizlib";
      version = "2.1.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "minizlib"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "minizlib"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/minizlib/-/minizlib-2.1.2.tgz";
        sha512 = "bAxsR8BVfj60DWXHE3u30oHzfl4G7khkSuPW+qvpd7jFRHm7dLxOjUk1EHACJ/hxLY8phGJ0YhYHZo7jil7Qdg==";
      };
    };
    "mkdirp-0.5.5" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "mkdirp";
      packageName = "mkdirp";
      version = "0.5.5";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "mkdirp"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "mkdirp"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/mkdirp/-/mkdirp-0.5.5.tgz";
        sha512 = "NKmAlESf6jMGym1++R0Ra7wvhV+wFW63FaSOFPwRahvea0gMUcGUhVeAg/0BC0wiv9ih5NYPB1Wn1UEI1/L+xQ==";
      };
    };
    "mkdirp-1.0.4" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "mkdirp";
      packageName = "mkdirp";
      version = "1.0.4";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "mkdirp"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "mkdirp"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/mkdirp/-/mkdirp-1.0.4.tgz";
        sha512 = "vVqVZQyf3WLx2Shd0qJ9xuvqgAyKPLAiqITEtqW0oIUjzo3PePDd6fW9iFz30ef7Ysp/oiWqbhszeGWW2T6Gzw==";
      };
    };
    "ms-2.1.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "ms";
      packageName = "ms";
      version = "2.1.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "ms"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "ms"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/ms/-/ms-2.1.2.tgz";
        sha512 = "sGkPx+VjMtmA6MX27oA4FBFELFCZZ4S4XqeGOXCv68tT+jb3vk/RyaKWP0PTKyWtmLSM0b+adUTEvbs1PEaH2w==";
      };
    };
    "negotiator-0.6.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "negotiator";
      packageName = "negotiator";
      version = "0.6.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "negotiator"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "negotiator"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/negotiator/-/negotiator-0.6.2.tgz";
        sha512 = "hZXc7K2e+PgeI1eDBe/10Ard4ekbfrrqG8Ep+8Jmf4JID2bNg7NvCPOZN+kfF574pFQI7mum2AUqDidoKqcTOw==";
      };
    };
    "nopt-3.0.6" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "nopt";
      packageName = "nopt";
      version = "3.0.6";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "nopt"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "nopt"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/nopt/-/nopt-3.0.6.tgz";
        sha1 = "c6465dbf08abcd4db359317f79ac68a646b28ff9";
      };
    };
    "normalize-url-6.1.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "normalize-url";
      packageName = "normalize-url";
      version = "6.1.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "normalize-url"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "normalize-url"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/normalize-url/-/normalize-url-6.1.0.tgz";
        sha512 = "DlL+XwOy3NxAQ8xuC0okPgK46iuVNAK01YN7RueYBqqFeGsBjV9XmCAzAdgt+667bCl5kPh9EqKKDwnaPG1I7A==";
      };
    };
    "npm-package-arg-8.1.5" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "npm-package-arg";
      packageName = "npm-package-arg";
      version = "8.1.5";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "npm-package-arg"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "npm-package-arg"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/npm-package-arg/-/npm-package-arg-8.1.5.tgz";
        sha512 = "LhgZrg0n0VgvzVdSm1oiZworPbTxYHUJCgtsJW8mGvlDpxTM1vSJc3m5QZeUkhAHIzbz3VCHd/R4osi1L1Tg/Q==";
      };
    };
    "number-is-nan-1.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "number-is-nan";
      packageName = "number-is-nan";
      version = "1.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "number-is-nan"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "number-is-nan"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/number-is-nan/-/number-is-nan-1.0.1.tgz";
        sha1 = "097b602b53422a522c1afb8790318336941a011d";
      };
    };
    "object-assign-4.1.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "object-assign";
      packageName = "object-assign";
      version = "4.1.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "object-assign"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "object-assign"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/object-assign/-/object-assign-4.1.1.tgz";
        sha1 = "2109adc7965887cfc05cbbd442cac8bfbb360863";
      };
    };
    "object-inspect-1.11.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "object-inspect";
      packageName = "object-inspect";
      version = "1.11.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "object-inspect"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "object-inspect"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/object-inspect/-/object-inspect-1.11.0.tgz";
        sha512 = "jp7ikS6Sd3GxQfZJPyH3cjcbJF6GZPClgdV+EFygjFLQ5FmW/dRUnTd9PQ9k0JhoNDabWFbpF1yCdSWCC6gexg==";
      };
    };
    "once-1.3.3" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "once";
      packageName = "once";
      version = "1.3.3";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "once"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "once"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/once/-/once-1.3.3.tgz";
        sha1 = "b2e261557ce4c314ec8304f3fa82663e4297ca20";
      };
    };
    "once-1.4.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "once";
      packageName = "once";
      version = "1.4.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "once"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "once"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/once/-/once-1.4.0.tgz";
        sha1 = "583b1aa775961d4b113ac17d9c50baef9dd76bd1";
      };
    };
    "optparse-1.0.5" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "optparse";
      packageName = "optparse";
      version = "1.0.5";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "optparse"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "optparse"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/optparse/-/optparse-1.0.5.tgz";
        sha1 = "75e75a96506611eb1c65ba89018ff08a981e2c16";
      };
    };
    "os-homedir-1.0.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "os-homedir";
      packageName = "os-homedir";
      version = "1.0.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "os-homedir"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "os-homedir"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/os-homedir/-/os-homedir-1.0.2.tgz";
        sha1 = "ffbc4988336e0e833de0c168c7ef152121aa7fb3";
      };
    };
    "os-tmpdir-1.0.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "os-tmpdir";
      packageName = "os-tmpdir";
      version = "1.0.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "os-tmpdir"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "os-tmpdir"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/os-tmpdir/-/os-tmpdir-1.0.2.tgz";
        sha1 = "bbe67406c79aa85c5cfec766fe5734555dfa1274";
      };
    };
    "osenv-0.1.5" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "osenv";
      packageName = "osenv";
      version = "0.1.5";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "osenv"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "osenv"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/osenv/-/osenv-0.1.5.tgz";
        sha512 = "0CWcCECdMVc2Rw3U5w9ZjqX6ga6ubk1xDVKxtBQPK7wis/0F2r9T6k4ydGYhecl7YUBxBVxhL5oisPsNxAPe2g==";
      };
    };
    "p-map-4.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "p-map";
      packageName = "p-map";
      version = "4.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "p-map"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "p-map"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/p-map/-/p-map-4.0.0.tgz";
        sha512 = "/bjOqmgETBYB5BoEeGVea8dmvHb2m9GLy1E9W43yeyfP6QQCZGFNa+XRceJEuDB6zqr+gKpIAmlLebMpykw/MQ==";
      };
    };
    "parse-path-4.0.3" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "parse-path";
      packageName = "parse-path";
      version = "4.0.3";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "parse-path"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "parse-path"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/parse-path/-/parse-path-4.0.3.tgz";
        sha512 = "9Cepbp2asKnWTJ9x2kpw6Fe8y9JDbqwahGCTvklzd/cEq5C5JC59x2Xb0Kx+x0QZ8bvNquGO8/BWP0cwBHzSAA==";
      };
    };
    "parse-url-6.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "parse-url";
      packageName = "parse-url";
      version = "6.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "parse-url"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "parse-url"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/parse-url/-/parse-url-6.0.0.tgz";
        sha512 = "cYyojeX7yIIwuJzledIHeLUBVJ6COVLeT4eF+2P6aKVzwvgKQPndCBv3+yQ7pcWjqToYwaligxzSYNNmGoMAvw==";
      };
    };
    "path-is-absolute-1.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "path-is-absolute";
      packageName = "path-is-absolute";
      version = "1.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "path-is-absolute"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "path-is-absolute"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/path-is-absolute/-/path-is-absolute-1.0.1.tgz";
        sha1 = "174b9268735534ffbc7ace6bf53a5a9e1b5c5f5f";
      };
    };
    "process-nextick-args-2.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "process-nextick-args";
      packageName = "process-nextick-args";
      version = "2.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "process-nextick-args"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "process-nextick-args"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/process-nextick-args/-/process-nextick-args-2.0.1.tgz";
        sha512 = "3ouUOpQhtgrbOa17J7+uxOTpITYWaGP7/AhoR3+A+/1e9skrzelGi/dXzEYyvbxubEF6Wn2ypscTKiKJFFn1ag==";
      };
    };
    "promise-inflight-1.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "promise-inflight";
      packageName = "promise-inflight";
      version = "1.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "promise-inflight"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "promise-inflight"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/promise-inflight/-/promise-inflight-1.0.1.tgz";
        sha1 = "98472870bf228132fcbdd868129bad12c3c029e3";
      };
    };
    "promise-retry-2.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "promise-retry";
      packageName = "promise-retry";
      version = "2.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "promise-retry"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "promise-retry"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/promise-retry/-/promise-retry-2.0.1.tgz";
        sha512 = "y+WKFlBR8BGXnsNlIHFGPZmyDf3DFMoLhaflAnyZgV6rG6xu+JwesTo2Q9R6XwYmtmwAFCkAk3e35jEdoeh/3g==";
      };
    };
    "proto-list-1.2.4" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "proto-list";
      packageName = "proto-list";
      version = "1.2.4";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "proto-list"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "proto-list"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/proto-list/-/proto-list-1.2.4.tgz";
        sha1 = "212d5bfe1318306a420f6402b8e26ff39647a849";
      };
    };
    "protocols-1.4.8" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "protocols";
      packageName = "protocols";
      version = "1.4.8";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "protocols"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "protocols"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/protocols/-/protocols-1.4.8.tgz";
        sha512 = "IgjKyaUSjsROSO8/D49Ab7hP8mJgTYcqApOqdPhLoPxAplXmkp+zRvsrSQjFn5by0rhm4VH0GAUELIPpx7B1yg==";
      };
    };
    "qs-6.10.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "qs";
      packageName = "qs";
      version = "6.10.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "qs"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "qs"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/qs/-/qs-6.10.1.tgz";
        sha512 = "M528Hph6wsSVOBiYUnGf+K/7w0hNshs/duGsNXPUCLH5XAqjEtiPGwNONLV0tBH8NoGb0mvD5JubnUTrujKDTg==";
      };
    };
    "query-string-6.14.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "query-string";
      packageName = "query-string";
      version = "6.14.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "query-string"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "query-string"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/query-string/-/query-string-6.14.1.tgz";
        sha512 = "XDxAeVmpfu1/6IjyT/gXHOl+S0vQ9owggJ30hhWKdHAsNPOcasn5o9BW0eejZqL2e4vMjhAxoW3jVHcD6mbcYw==";
      };
    };
    "readable-stream-2.3.7" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "readable-stream";
      packageName = "readable-stream";
      version = "2.3.7";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "readable-stream"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "readable-stream"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/readable-stream/-/readable-stream-2.3.7.tgz";
        sha512 = "Ebho8K4jIbHAxnuxi7o42OrZgF/ZTNcsZj6nRKyUmkhLFq8CHItp/fy6hQZuZmP/n3yZ9VBUbp4zz/mX8hmYPw==";
      };
    };
    "retry-0.12.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "retry";
      packageName = "retry";
      version = "0.12.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "retry"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "retry"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/retry/-/retry-0.12.0.tgz";
        sha1 = "1b42a6266a21f07421d1b0b54b7dc167b01c013b";
      };
    };
    "rimraf-3.0.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "rimraf";
      packageName = "rimraf";
      version = "3.0.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "rimraf"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "rimraf"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/rimraf/-/rimraf-3.0.2.tgz";
        sha512 = "JZkJMZkAGFFPP2YqXZXPbMlMBgsxzE8ILs4lMIX/2o0L9UBw9O/Y3o6wFw/i9YLapcUJWwqbi3kdxIPdC62TIA==";
      };
    };
    "safe-buffer-5.1.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "safe-buffer";
      packageName = "safe-buffer";
      version = "5.1.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "safe-buffer"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "safe-buffer"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/safe-buffer/-/safe-buffer-5.1.2.tgz";
        sha512 = "Gd2UZBJDkXlY7GbJxfsE8/nvKkUEU1G38c1siN6QP6a9PT9MmHB8GnpscSmMJSoF8LOIrt8ud/wPtojys4G6+g==";
      };
    };
    "safe-buffer-5.2.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "safe-buffer";
      packageName = "safe-buffer";
      version = "5.2.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "safe-buffer"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "safe-buffer"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/safe-buffer/-/safe-buffer-5.2.1.tgz";
        sha512 = "rp3So07KcdmmKbGvgaNxQSJr7bGVSVk5S9Eq1F+ppbRo70+YeaDxkw5Dd8NPN+GD6bjnYm2VuPuCXmpuYvmCXQ==";
      };
    };
    "semver-4.3.6" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "semver";
      packageName = "semver";
      version = "4.3.6";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "semver"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "semver"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/semver/-/semver-4.3.6.tgz";
        sha1 = "300bc6e0e86374f7ba61068b5b1ecd57fc6532da";
      };
    };
    "semver-7.3.5" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "semver";
      packageName = "semver";
      version = "7.3.5";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "semver"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "semver"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/semver/-/semver-7.3.5.tgz";
        sha512 = "PoeGJYh8HK4BTO/a9Tf6ZG3veo/A7ZVsYrSA6J8ny9nb3B1VrpkuN+z9OE5wfE5p6H4LchYZsegiQgbJD94ZFQ==";
      };
    };
    "set-blocking-2.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "set-blocking";
      packageName = "set-blocking";
      version = "2.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "set-blocking"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "set-blocking"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/set-blocking/-/set-blocking-2.0.0.tgz";
        sha1 = "045f9782d011ae9a6803ddd382b24392b3d890f7";
      };
    };
    "side-channel-1.0.4" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "side-channel";
      packageName = "side-channel";
      version = "1.0.4";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "side-channel"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "side-channel"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/side-channel/-/side-channel-1.0.4.tgz";
        sha512 = "q5XPytqFEIKHkGdiMIrY10mvLRvnQh42/+GoBlFW3b2LXLE2xxJpZFdm94we0BaoV3RwJyGqg5wS7epxTv0Zvw==";
      };
    };
    "signal-exit-3.0.3" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "signal-exit";
      packageName = "signal-exit";
      version = "3.0.3";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "signal-exit"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "signal-exit"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/signal-exit/-/signal-exit-3.0.3.tgz";
        sha512 = "VUJ49FC8U1OxwZLxIbTTrDvLnf/6TDgxZcK8wxR8zs13xpx7xbG60ndBlhNrFi2EMuFRoeDoJO7wthSLq42EjA==";
      };
    };
    "slasp-0.0.4" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "slasp";
      packageName = "slasp";
      version = "0.0.4";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "slasp"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "slasp"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/slasp/-/slasp-0.0.4.tgz";
        sha1 = "9adc26ee729a0f95095851a5489f87a5258d57a9";
      };
    };
    "smart-buffer-4.2.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "smart-buffer";
      packageName = "smart-buffer";
      version = "4.2.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "smart-buffer"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "smart-buffer"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/smart-buffer/-/smart-buffer-4.2.0.tgz";
        sha512 = "94hK0Hh8rPqQl2xXc3HsaBoOXKV20MToPkcXvwbISWLEs+64sBq5kFgn2kJDHb1Pry9yrP0dxrCI9RRci7RXKg==";
      };
    };
    "socks-2.6.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "socks";
      packageName = "socks";
      version = "2.6.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "socks"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "socks"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/socks/-/socks-2.6.1.tgz";
        sha512 = "kLQ9N5ucj8uIcxrDwjm0Jsqk06xdpBjGNQtpXy4Q8/QY2k+fY7nZH8CARy+hkbG+SGAovmzzuauCpBlb8FrnBA==";
      };
    };
    "socks-proxy-agent-5.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "socks-proxy-agent";
      packageName = "socks-proxy-agent";
      version = "5.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "socks-proxy-agent"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "socks-proxy-agent"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/socks-proxy-agent/-/socks-proxy-agent-5.0.1.tgz";
        sha512 = "vZdmnjb9a2Tz6WEQVIurybSwElwPxMZaIc7PzqbJTrezcKNznv6giT7J7tZDZ1BojVaa1jvO/UiUdhDVB0ACoQ==";
      };
    };
    "split-on-first-1.1.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "split-on-first";
      packageName = "split-on-first";
      version = "1.1.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "split-on-first"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "split-on-first"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/split-on-first/-/split-on-first-1.1.0.tgz";
        sha512 = "43ZssAJaMusuKWL8sKUBQXHWOpq8d6CfN/u1p4gUzfJkM05C8rxTmYrkIPTXapZpORA6LkkzcUulJ8FqA7Uudw==";
      };
    };
    "ssri-8.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "ssri";
      packageName = "ssri";
      version = "8.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "ssri"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "ssri"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/ssri/-/ssri-8.0.1.tgz";
        sha512 = "97qShzy1AiyxvPNIkLWoGua7xoQzzPjQ0HAH4B0rWKo7SZ6USuPcrUiAFrws0UH8RrbWmgq3LMTObhPIHbbBeQ==";
      };
    };
    "strict-uri-encode-2.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "strict-uri-encode";
      packageName = "strict-uri-encode";
      version = "2.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "strict-uri-encode"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "strict-uri-encode"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/strict-uri-encode/-/strict-uri-encode-2.0.0.tgz";
        sha1 = "b9c7330c7042862f6b142dc274bbcc5866ce3546";
      };
    };
    "string-width-1.0.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "string-width";
      packageName = "string-width";
      version = "1.0.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "string-width"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "string-width"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/string-width/-/string-width-1.0.2.tgz";
        sha1 = "118bdf5b8cdc51a2a7e70d211e07e2b0b9b107d3";
      };
    };
    "string_decoder-1.1.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "string_decoder";
      packageName = "string_decoder";
      version = "1.1.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "string_decoder"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "string_decoder"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/string_decoder/-/string_decoder-1.1.1.tgz";
        sha512 = "n/ShnvDi6FHbbVfviro+WojiFzv+s8MPMHBczVePfUpDJLwoLT0ht1l4YwBCbi8pJAveEEdnkHyPyTP/mzRfwg==";
      };
    };
    "strip-ansi-3.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "strip-ansi";
      packageName = "strip-ansi";
      version = "3.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "strip-ansi"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "strip-ansi"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/strip-ansi/-/strip-ansi-3.0.1.tgz";
        sha1 = "6a385fb8853d952d5ff05d0e8aaf94278dc63dcf";
      };
    };
    "tar-6.1.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "tar";
      packageName = "tar";
      version = "6.1.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "tar"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "tar"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/tar/-/tar-6.1.2.tgz";
        sha512 = "EwKEgqJ7nJoS+s8QfLYVGMDmAsj+StbI2AM/RTHeUSsOw6Z8bwNBRv5z3CY0m7laC5qUAqruLX5AhMuc5deY3Q==";
      };
    };
    "uid-number-0.0.5" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "uid-number";
      packageName = "uid-number";
      version = "0.0.5";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "uid-number"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "uid-number"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/uid-number/-/uid-number-0.0.5.tgz";
        sha1 = "5a3db23ef5dbd55b81fce0ec9a2ac6fccdebb81e";
      };
    };
    "unique-filename-1.1.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "unique-filename";
      packageName = "unique-filename";
      version = "1.1.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "unique-filename"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "unique-filename"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/unique-filename/-/unique-filename-1.1.1.tgz";
        sha512 = "Vmp0jIp2ln35UTXuryvjzkjGdRyf9b2lTXuSYUiPmzRcl3FDtYqAwOnTJkAngD9SWhnoJzDbTKwaOrZ+STtxNQ==";
      };
    };
    "unique-slug-2.0.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "unique-slug";
      packageName = "unique-slug";
      version = "2.0.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "unique-slug"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "unique-slug"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/unique-slug/-/unique-slug-2.0.2.tgz";
        sha512 = "zoWr9ObaxALD3DOPfjPSqxt4fnZiWblxHIgeWqW8x7UqDzEtHEQLzji2cuJYQFCU6KmoJikOYAZlrTHHebjx2w==";
      };
    };
    "universalify-2.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "universalify";
      packageName = "universalify";
      version = "2.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "universalify"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "universalify"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/universalify/-/universalify-2.0.0.tgz";
        sha512 = "hAZsKq7Yy11Zu1DE0OzWjw7nnLZmJZYTDZZyEFHZdUhV8FkH5MCfoU1XMaxXovpyW5nq5scPqq0ZDP9Zyl04oQ==";
      };
    };
    "util-deprecate-1.0.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "util-deprecate";
      packageName = "util-deprecate";
      version = "1.0.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "util-deprecate"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "util-deprecate"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/util-deprecate/-/util-deprecate-1.0.2.tgz";
        sha1 = "450d4dc9fa70de732762fbd2d4a28981419a0ccf";
      };
    };
    "validate-npm-package-name-3.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "validate-npm-package-name";
      packageName = "validate-npm-package-name";
      version = "3.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "validate-npm-package-name"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "validate-npm-package-name"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/validate-npm-package-name/-/validate-npm-package-name-3.0.0.tgz";
        sha1 = "5fa912d81eb7d0c74afc140de7317f0ca7df437e";
      };
    };
    "wide-align-1.1.3" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "wide-align";
      packageName = "wide-align";
      version = "1.1.3";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "wide-align"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "wide-align"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/wide-align/-/wide-align-1.1.3.tgz";
        sha512 = "QGkOQc8XL6Bt5PwnsExKBPuMKBxnGxWWW3fU55Xt4feHozMUhdUMaBCk290qpm/wG5u/RSKzwdAC4i51YigihA==";
      };
    };
    "wrappy-1.0.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "wrappy";
      packageName = "wrappy";
      version = "1.0.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "wrappy"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "wrappy"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/wrappy/-/wrappy-1.0.2.tgz";
        sha1 = "b5243d8f3ec1aa35f1364605bc0d1036e30ab69f";
      };
    };
    "yallist-4.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "yallist";
      packageName = "yallist";
      version = "4.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "yallist"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts,.bin)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "yallist"; };
      doCheck = false;
      dontStrip = true;
      dontFixup = true;
      src = fetchurl {
        url = "https://registry.npmjs.org/yallist/-/yallist-4.0.0.tgz";
        sha512 = "3wdGidZyq5PB084XLES5TpOSRA3wjXAlIWMhum2kRcv/41Sn2emQ0dycQW4uZXLejwKvg6EsvbdlVL+FYEct7A==";
      };
    };
  };
  jsnixDeps = sources // {
    base64-js = let
      dependencies = [];
      extraDependencies = [] ++
        mkExtraDependencies
           (pkgs // { inherit jsnixDeps dependencies; })
            { pkgName = "base64-js"; };
    in
    stdenv.mkDerivation {
      inherit dependencies extraDependencies;
      name = "base64-js";
      packageName = "base64-js";
      version = "1.5.1";
      src = fetchurl {
        url = "https://registry.npmjs.org/base64-js/-/base64-js-1.5.1.tgz";
        sha512 = "AKpaYlHn8t4SVbOHCy+b5+KKgvR4vrsD8vbvrbiQJps7fKDTkjkDry6ji0rUJjC0kzbNePLwzxq8iypo41qeWA==";
      };
      buildInputs = [ nodejs python3 makeWrapper jq  ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "base64-js"; });
      dontStrip = true;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "configureScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "base64-js"; };
      configureScript = mkConfigureScript {};
      buildScript = mkBuildScript { inherit dependencies; pkgName = "base64-js"; };
      buildPhase = ''
      source $unpackScriptPath 
      source $configureScriptPath
      runHook preBuild
      if [ -z "$preBuild" ]; then
        runHook preInstall
      fi
      source $buildScriptPath
      if [ -z "$postBuild" ]; then
        runHook postBuild
      fi
    '';
      patchPhase = ''
      if [ -z "$prePatch" ]; then
        runHook prePatch
      fi
      
      if [ -z "$postPatch" ]; then
        runHook postPatch
      fi
    '';
      installScript = mkInstallScript { pkgName = "base64-js"; };
      installPhase = ''
      if [ -z "$preInstall" ]; then
        runHook preInstall
      fi
      source $installScriptPath
      if [ -z "$postInstall" ]; then
        runHook postInstall
      fi
    '';
      preInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preInstall"; pkgName = "base64-js"; });
      postInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postInstall"; pkgName = "base64-js"; });
      preBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preBuild"; pkgName = "base64-js"; });
      postBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postBuild"; pkgName = "base64-js"; });
      doInstallCheck = true;
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "base64-js"; });
      meta = {
        description = "Base64 encoding/decoding in pure JS";
        license = "MIT";
        homepage = "https://github.com/beatgammit/base64-js";
      };
    };
    cachedir = let
      dependencies = [];
      extraDependencies = [] ++
        mkExtraDependencies
           (pkgs // { inherit jsnixDeps dependencies; })
            { pkgName = "cachedir"; };
    in
    stdenv.mkDerivation {
      inherit dependencies extraDependencies;
      name = "cachedir";
      packageName = "cachedir";
      version = "2.3.0";
      src = fetchurl {
        url = "https://registry.npmjs.org/cachedir/-/cachedir-2.3.0.tgz";
        sha512 = "A+Fezp4zxnit6FanDmv9EqXNAi3vt9DWp51/71UEhXukb7QUuvtv9344h91dyAxuTLoSYJFU299qzR3tzwPAhw==";
      };
      buildInputs = [ nodejs python3 makeWrapper jq  ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "cachedir"; });
      dontStrip = true;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "configureScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "cachedir"; };
      configureScript = mkConfigureScript {};
      buildScript = mkBuildScript { inherit dependencies; pkgName = "cachedir"; };
      buildPhase = ''
      source $unpackScriptPath 
      source $configureScriptPath
      runHook preBuild
      if [ -z "$preBuild" ]; then
        runHook preInstall
      fi
      source $buildScriptPath
      if [ -z "$postBuild" ]; then
        runHook postBuild
      fi
    '';
      patchPhase = ''
      if [ -z "$prePatch" ]; then
        runHook prePatch
      fi
      
      if [ -z "$postPatch" ]; then
        runHook postPatch
      fi
    '';
      installScript = mkInstallScript { pkgName = "cachedir"; };
      installPhase = ''
      if [ -z "$preInstall" ]; then
        runHook preInstall
      fi
      source $installScriptPath
      if [ -z "$postInstall" ]; then
        runHook postInstall
      fi
    '';
      preInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preInstall"; pkgName = "cachedir"; });
      postInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postInstall"; pkgName = "cachedir"; });
      preBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preBuild"; pkgName = "cachedir"; });
      postBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postBuild"; pkgName = "cachedir"; });
      doInstallCheck = true;
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "cachedir"; });
      meta = {
        description = "Provides a directory where the OS wants you to store cached files.";
        license = "MIT";
        homepage = "https://github.com/LinusU/node-cachedir#readme";
      };
    };
    commander = let
      dependencies = [];
      extraDependencies = [] ++
        mkExtraDependencies
           (pkgs // { inherit jsnixDeps dependencies; })
            { pkgName = "commander"; };
    in
    stdenv.mkDerivation {
      inherit dependencies extraDependencies;
      name = "commander";
      packageName = "commander";
      version = "8.1.0";
      src = fetchurl {
        url = "https://registry.npmjs.org/commander/-/commander-8.1.0.tgz";
        sha512 = "mf45ldcuHSYShkplHHGKWb4TrmwQadxOn7v4WuhDJy0ZVoY5JFajaRDKD0PNe5qXzBX0rhovjTnP6Kz9LETcuA==";
      };
      buildInputs = [ nodejs python3 makeWrapper jq  ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "commander"; });
      dontStrip = true;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "configureScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "commander"; };
      configureScript = mkConfigureScript {};
      buildScript = mkBuildScript { inherit dependencies; pkgName = "commander"; };
      buildPhase = ''
      source $unpackScriptPath 
      source $configureScriptPath
      runHook preBuild
      if [ -z "$preBuild" ]; then
        runHook preInstall
      fi
      source $buildScriptPath
      if [ -z "$postBuild" ]; then
        runHook postBuild
      fi
    '';
      patchPhase = ''
      if [ -z "$prePatch" ]; then
        runHook prePatch
      fi
      
      if [ -z "$postPatch" ]; then
        runHook postPatch
      fi
    '';
      installScript = mkInstallScript { pkgName = "commander"; };
      installPhase = ''
      if [ -z "$preInstall" ]; then
        runHook preInstall
      fi
      source $installScriptPath
      if [ -z "$postInstall" ]; then
        runHook postInstall
      fi
    '';
      preInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preInstall"; pkgName = "commander"; });
      postInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postInstall"; pkgName = "commander"; });
      preBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preBuild"; pkgName = "commander"; });
      postBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postBuild"; pkgName = "commander"; });
      doInstallCheck = true;
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "commander"; });
      meta = {
        description = "the complete solution for node.js command-line programs";
        license = "MIT";
        homepage = "https://github.com/tj/commander.js#readme";
      };
    };
    findit = let
      dependencies = [];
      extraDependencies = [] ++
        mkExtraDependencies
           (pkgs // { inherit jsnixDeps dependencies; })
            { pkgName = "findit"; };
    in
    stdenv.mkDerivation {
      inherit dependencies extraDependencies;
      name = "findit";
      packageName = "findit";
      version = "2.0.0";
      src = fetchurl {
        url = "https://registry.npmjs.org/findit/-/findit-2.0.0.tgz";
        sha1 = "6509f0126af4c178551cfa99394e032e13a4d56e";
      };
      buildInputs = [ nodejs python3 makeWrapper jq  ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "findit"; });
      dontStrip = true;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "configureScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "findit"; };
      configureScript = mkConfigureScript {};
      buildScript = mkBuildScript { inherit dependencies; pkgName = "findit"; };
      buildPhase = ''
      source $unpackScriptPath 
      source $configureScriptPath
      runHook preBuild
      if [ -z "$preBuild" ]; then
        runHook preInstall
      fi
      source $buildScriptPath
      if [ -z "$postBuild" ]; then
        runHook postBuild
      fi
    '';
      patchPhase = ''
      if [ -z "$prePatch" ]; then
        runHook prePatch
      fi
      
      if [ -z "$postPatch" ]; then
        runHook postPatch
      fi
    '';
      installScript = mkInstallScript { pkgName = "findit"; };
      installPhase = ''
      if [ -z "$preInstall" ]; then
        runHook preInstall
      fi
      source $installScriptPath
      if [ -z "$postInstall" ]; then
        runHook postInstall
      fi
    '';
      preInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preInstall"; pkgName = "findit"; });
      postInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postInstall"; pkgName = "findit"; });
      preBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preBuild"; pkgName = "findit"; });
      postBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postBuild"; pkgName = "findit"; });
      doInstallCheck = true;
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "findit"; });
      meta = {
        description = "walk a directory tree recursively with events";
        license = "MIT";
        homepage = "https://github.com/substack/node-findit";
      };
    };
    fs-extra = let
      dependencies = [
        (sources."graceful-fs-4.2.6" {
          dependencies = [];
        })
        (sources."jsonfile-6.1.0" {
          dependencies = [];
        })
        (sources."universalify-2.0.0" {
          dependencies = [];
        })
      ];
      extraDependencies = [] ++
        mkExtraDependencies
           (pkgs // { inherit jsnixDeps dependencies; })
            { pkgName = "fs-extra"; };
    in
    stdenv.mkDerivation {
      inherit dependencies extraDependencies;
      name = "fs-extra";
      packageName = "fs-extra";
      version = "10.0.0";
      src = fetchurl {
        url = "https://registry.npmjs.org/fs-extra/-/fs-extra-10.0.0.tgz";
        sha512 = "C5owb14u9eJwizKGdchcDUQeFtlSHHthBk8pbX9Vc1PFZrLombudjDnNns88aYslCyF6IY5SUw3Roz6xShcEIQ==";
      };
      buildInputs = [ nodejs python3 makeWrapper jq  ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "fs-extra"; });
      dontStrip = true;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "configureScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "fs-extra"; };
      configureScript = mkConfigureScript {};
      buildScript = mkBuildScript { inherit dependencies; pkgName = "fs-extra"; };
      buildPhase = ''
      source $unpackScriptPath 
      source $configureScriptPath
      runHook preBuild
      if [ -z "$preBuild" ]; then
        runHook preInstall
      fi
      source $buildScriptPath
      if [ -z "$postBuild" ]; then
        runHook postBuild
      fi
    '';
      patchPhase = ''
      if [ -z "$prePatch" ]; then
        runHook prePatch
      fi
      
      if [ -z "$postPatch" ]; then
        runHook postPatch
      fi
    '';
      installScript = mkInstallScript { pkgName = "fs-extra"; };
      installPhase = ''
      if [ -z "$preInstall" ]; then
        runHook preInstall
      fi
      source $installScriptPath
      if [ -z "$postInstall" ]; then
        runHook postInstall
      fi
    '';
      preInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preInstall"; pkgName = "fs-extra"; });
      postInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postInstall"; pkgName = "fs-extra"; });
      preBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preBuild"; pkgName = "fs-extra"; });
      postBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postBuild"; pkgName = "fs-extra"; });
      doInstallCheck = true;
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "fs-extra"; });
      meta = {
        description = "fs-extra contains methods that aren't included in the vanilla Node.js fs package. Such as recursive mkdir, copy, and remove.";
        license = "MIT";
        homepage = "https://github.com/jprichardson/node-fs-extra";
      };
    };
    git-url-parse = let
      dependencies = [
        (sources."call-bind-1.0.2" {
          dependencies = [];
        })
        (sources."decode-uri-component-0.2.0" {
          dependencies = [];
        })
        (sources."filter-obj-1.1.0" {
          dependencies = [];
        })
        (sources."function-bind-1.1.1" {
          dependencies = [];
        })
        (sources."get-intrinsic-1.1.1" {
          dependencies = [];
        })
        (sources."git-up-4.0.5" {
          dependencies = [];
        })
        (sources."has-1.0.3" {
          dependencies = [];
        })
        (sources."has-symbols-1.0.2" {
          dependencies = [];
        })
        (sources."is-ssh-1.3.3" {
          dependencies = [];
        })
        (sources."normalize-url-6.1.0" {
          dependencies = [];
        })
        (sources."object-inspect-1.11.0" {
          dependencies = [];
        })
        (sources."parse-path-4.0.3" {
          dependencies = [];
        })
        (sources."parse-url-6.0.0" {
          dependencies = [];
        })
        (sources."protocols-1.4.8" {
          dependencies = [];
        })
        (sources."qs-6.10.1" {
          dependencies = [];
        })
        (sources."query-string-6.14.1" {
          dependencies = [];
        })
        (sources."side-channel-1.0.4" {
          dependencies = [];
        })
        (sources."split-on-first-1.1.0" {
          dependencies = [];
        })
        (sources."strict-uri-encode-2.0.0" {
          dependencies = [];
        })
      ];
      extraDependencies = [] ++
        mkExtraDependencies
           (pkgs // { inherit jsnixDeps dependencies; })
            { pkgName = "git-url-parse"; };
    in
    stdenv.mkDerivation {
      inherit dependencies extraDependencies;
      name = "git-url-parse";
      packageName = "git-url-parse";
      version = "11.5.0";
      src = fetchurl {
        url = "https://registry.npmjs.org/git-url-parse/-/git-url-parse-11.5.0.tgz";
        sha512 = "TZYSMDeM37r71Lqg1mbnMlOqlHd7BSij9qN7XwTkRqSAYFMihGLGhfHwgqQob3GUhEneKnV4nskN9rbQw2KGxA==";
      };
      buildInputs = [ nodejs python3 makeWrapper jq  ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "git-url-parse"; });
      dontStrip = true;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "configureScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "git-url-parse"; };
      configureScript = mkConfigureScript {};
      buildScript = mkBuildScript { inherit dependencies; pkgName = "git-url-parse"; };
      buildPhase = ''
      source $unpackScriptPath 
      source $configureScriptPath
      runHook preBuild
      if [ -z "$preBuild" ]; then
        runHook preInstall
      fi
      source $buildScriptPath
      if [ -z "$postBuild" ]; then
        runHook postBuild
      fi
    '';
      patchPhase = ''
      if [ -z "$prePatch" ]; then
        runHook prePatch
      fi
      
      if [ -z "$postPatch" ]; then
        runHook postPatch
      fi
    '';
      installScript = mkInstallScript { pkgName = "git-url-parse"; };
      installPhase = ''
      if [ -z "$preInstall" ]; then
        runHook preInstall
      fi
      source $installScriptPath
      if [ -z "$postInstall" ]; then
        runHook postInstall
      fi
    '';
      preInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preInstall"; pkgName = "git-url-parse"; });
      postInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postInstall"; pkgName = "git-url-parse"; });
      preBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preBuild"; pkgName = "git-url-parse"; });
      postBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postBuild"; pkgName = "git-url-parse"; });
      doInstallCheck = true;
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "git-url-parse"; });
      meta = {
        description = "A high level git url parser for common git providers.";
        license = "MIT";
        homepage = "https://github.com/IonicaBizau/git-url-parse";
      };
    };
    nijs = let
      dependencies = [
        (sources."optparse-1.0.5" {
          dependencies = [];
        })
        (sources."slasp-0.0.4" {
          dependencies = [];
        })
      ];
      extraDependencies = [] ++
        mkExtraDependencies
           (pkgs // { inherit jsnixDeps dependencies; })
            { pkgName = "nijs"; };
    in
    stdenv.mkDerivation {
      inherit dependencies extraDependencies;
      name = "nijs";
      packageName = "nijs";
      version = "0.0.25";
      src = fetchurl {
        url = "https://registry.npmjs.org/nijs/-/nijs-0.0.25.tgz";
        sha1 = "04b035cb530d46859d1018839a518c029133f676";
      };
      buildInputs = [ nodejs python3 makeWrapper jq  ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "nijs"; });
      dontStrip = true;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "configureScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "nijs"; };
      configureScript = mkConfigureScript {};
      buildScript = mkBuildScript { inherit dependencies; pkgName = "nijs"; };
      buildPhase = ''
      source $unpackScriptPath 
      source $configureScriptPath
      runHook preBuild
      if [ -z "$preBuild" ]; then
        runHook preInstall
      fi
      source $buildScriptPath
      if [ -z "$postBuild" ]; then
        runHook postBuild
      fi
    '';
      patchPhase = ''
      if [ -z "$prePatch" ]; then
        runHook prePatch
      fi
      
      if [ -z "$postPatch" ]; then
        runHook postPatch
      fi
    '';
      installScript = mkInstallScript { pkgName = "nijs"; };
      installPhase = ''
      if [ -z "$preInstall" ]; then
        runHook preInstall
      fi
      source $installScriptPath
      if [ -z "$postInstall" ]; then
        runHook postInstall
      fi
    '';
      preInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preInstall"; pkgName = "nijs"; });
      postInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postInstall"; pkgName = "nijs"; });
      preBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preBuild"; pkgName = "nijs"; });
      postBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postBuild"; pkgName = "nijs"; });
      doInstallCheck = true;
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "nijs"; });
      meta = {
        description = "An internal DSL for the Nix package manager in JavaScript";
        license = "MIT";
        homepage = "https://github.com/svanderburg/nijs#readme";
      };
    };
    npm-registry-fetch = let
      dependencies = [
        (sources."@npmcli/move-file-1.1.2" {
          dependencies = [];
        })
        (sources."@tootallnate/once-1.1.2" {
          dependencies = [];
        })
        (sources."agent-base-6.0.2" {
          dependencies = [];
        })
        (sources."agentkeepalive-4.1.4" {
          dependencies = [];
        })
        (sources."aggregate-error-3.1.0" {
          dependencies = [];
        })
        (sources."balanced-match-1.0.2" {
          dependencies = [];
        })
        (sources."brace-expansion-1.1.11" {
          dependencies = [];
        })
        (sources."builtins-1.0.3" {
          dependencies = [];
        })
        (sources."cacache-15.2.0" {
          dependencies = [];
        })
        (sources."chownr-2.0.0" {
          dependencies = [];
        })
        (sources."clean-stack-2.2.0" {
          dependencies = [];
        })
        (sources."concat-map-0.0.1" {
          dependencies = [];
        })
        (sources."debug-4.3.2" {
          dependencies = [];
        })
        (sources."depd-1.1.2" {
          dependencies = [];
        })
        (sources."err-code-2.0.3" {
          dependencies = [];
        })
        (sources."fs-minipass-2.1.0" {
          dependencies = [];
        })
        (sources."fs.realpath-1.0.0" {
          dependencies = [];
        })
        (sources."glob-7.1.7" {
          dependencies = [];
        })
        (sources."hosted-git-info-4.0.2" {
          dependencies = [];
        })
        (sources."http-cache-semantics-4.1.0" {
          dependencies = [];
        })
        (sources."http-proxy-agent-4.0.1" {
          dependencies = [];
        })
        (sources."https-proxy-agent-5.0.0" {
          dependencies = [];
        })
        (sources."humanize-ms-1.2.1" {
          dependencies = [];
        })
        (sources."imurmurhash-0.1.4" {
          dependencies = [];
        })
        (sources."indent-string-4.0.0" {
          dependencies = [];
        })
        (sources."infer-owner-1.0.4" {
          dependencies = [];
        })
        (sources."inflight-1.0.6" {
          dependencies = [];
        })
        (sources."inherits-2.0.4" {
          dependencies = [];
        })
        (sources."ip-1.1.5" {
          dependencies = [];
        })
        (sources."is-lambda-1.0.1" {
          dependencies = [];
        })
        (sources."jsonparse-1.3.1" {
          dependencies = [];
        })
        (sources."lru-cache-6.0.0" {
          dependencies = [];
        })
        (sources."make-fetch-happen-9.0.4" {
          dependencies = [];
        })
        (sources."minimatch-3.0.4" {
          dependencies = [];
        })
        (sources."minipass-3.1.3" {
          dependencies = [];
        })
        (sources."minipass-collect-1.0.2" {
          dependencies = [];
        })
        (sources."minipass-fetch-1.3.4" {
          dependencies = [];
        })
        (sources."minipass-flush-1.0.5" {
          dependencies = [];
        })
        (sources."minipass-json-stream-1.0.1" {
          dependencies = [];
        })
        (sources."minipass-pipeline-1.2.4" {
          dependencies = [];
        })
        (sources."minipass-sized-1.0.3" {
          dependencies = [];
        })
        (sources."minizlib-2.1.2" {
          dependencies = [];
        })
        (sources."mkdirp-1.0.4" {
          dependencies = [];
        })
        (sources."ms-2.1.2" {
          dependencies = [];
        })
        (sources."negotiator-0.6.2" {
          dependencies = [];
        })
        (sources."npm-package-arg-8.1.5" {
          dependencies = [];
        })
        (sources."once-1.4.0" {
          dependencies = [];
        })
        (sources."p-map-4.0.0" {
          dependencies = [];
        })
        (sources."path-is-absolute-1.0.1" {
          dependencies = [];
        })
        (sources."promise-inflight-1.0.1" {
          dependencies = [];
        })
        (sources."promise-retry-2.0.1" {
          dependencies = [];
        })
        (sources."retry-0.12.0" {
          dependencies = [];
        })
        (sources."rimraf-3.0.2" {
          dependencies = [];
        })
        (sources."semver-7.3.5" {
          dependencies = [];
        })
        (sources."smart-buffer-4.2.0" {
          dependencies = [];
        })
        (sources."socks-2.6.1" {
          dependencies = [];
        })
        (sources."socks-proxy-agent-5.0.1" {
          dependencies = [];
        })
        (sources."ssri-8.0.1" {
          dependencies = [];
        })
        (sources."tar-6.1.2" {
          dependencies = [];
        })
        (sources."unique-filename-1.1.1" {
          dependencies = [];
        })
        (sources."unique-slug-2.0.2" {
          dependencies = [];
        })
        (sources."validate-npm-package-name-3.0.0" {
          dependencies = [];
        })
        (sources."wrappy-1.0.2" {
          dependencies = [];
        })
        (sources."yallist-4.0.0" {
          dependencies = [];
        })
      ];
      extraDependencies = [] ++
        mkExtraDependencies
           (pkgs // { inherit jsnixDeps dependencies; })
            { pkgName = "npm-registry-fetch"; };
    in
    stdenv.mkDerivation {
      inherit dependencies extraDependencies;
      name = "npm-registry-fetch";
      packageName = "npm-registry-fetch";
      version = "11.0.0";
      src = fetchurl {
        url = "https://registry.npmjs.org/npm-registry-fetch/-/npm-registry-fetch-11.0.0.tgz";
        sha512 = "jmlgSxoDNuhAtxUIG6pVwwtz840i994dL14FoNVZisrmZW5kWd63IUTNv1m/hyRSGSqWjCUp/YZlS1BJyNp9XA==";
      };
      buildInputs = [ nodejs python3 makeWrapper jq  ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "npm-registry-fetch"; });
      dontStrip = true;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "configureScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "npm-registry-fetch"; };
      configureScript = mkConfigureScript {};
      buildScript = mkBuildScript { inherit dependencies; pkgName = "npm-registry-fetch"; };
      buildPhase = ''
      source $unpackScriptPath 
      source $configureScriptPath
      runHook preBuild
      if [ -z "$preBuild" ]; then
        runHook preInstall
      fi
      source $buildScriptPath
      if [ -z "$postBuild" ]; then
        runHook postBuild
      fi
    '';
      patchPhase = ''
      if [ -z "$prePatch" ]; then
        runHook prePatch
      fi
      
      if [ -z "$postPatch" ]; then
        runHook postPatch
      fi
    '';
      installScript = mkInstallScript { pkgName = "npm-registry-fetch"; };
      installPhase = ''
      if [ -z "$preInstall" ]; then
        runHook preInstall
      fi
      source $installScriptPath
      if [ -z "$postInstall" ]; then
        runHook postInstall
      fi
    '';
      preInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preInstall"; pkgName = "npm-registry-fetch"; });
      postInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postInstall"; pkgName = "npm-registry-fetch"; });
      preBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preBuild"; pkgName = "npm-registry-fetch"; });
      postBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postBuild"; pkgName = "npm-registry-fetch"; });
      doInstallCheck = true;
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "npm-registry-fetch"; });
      meta = {
        description = "Fetch-based http client for use with npm registry APIs";
        license = "ISC";
        homepage = "https://github.com/npm/npm-registry-fetch#readme";
      };
    };
    npmconf = let
      dependencies = [
        (sources."abbrev-1.1.1" {
          dependencies = [];
        })
        (sources."config-chain-1.1.13" {
          dependencies = [];
        })
        (sources."inherits-2.0.4" {
          dependencies = [];
        })
        (sources."ini-1.3.8" {
          dependencies = [];
        })
        (sources."minimist-1.2.5" {
          dependencies = [];
        })
        (sources."mkdirp-0.5.5" {
          dependencies = [];
        })
        (sources."nopt-3.0.6" {
          dependencies = [];
        })
        (sources."once-1.3.3" {
          dependencies = [];
        })
        (sources."os-homedir-1.0.2" {
          dependencies = [];
        })
        (sources."os-tmpdir-1.0.2" {
          dependencies = [];
        })
        (sources."osenv-0.1.5" {
          dependencies = [];
        })
        (sources."proto-list-1.2.4" {
          dependencies = [];
        })
        (sources."safe-buffer-5.2.1" {
          dependencies = [];
        })
        (sources."semver-4.3.6" {
          dependencies = [];
        })
        (sources."uid-number-0.0.5" {
          dependencies = [];
        })
        (sources."wrappy-1.0.2" {
          dependencies = [];
        })
      ];
      extraDependencies = [] ++
        mkExtraDependencies
           (pkgs // { inherit jsnixDeps dependencies; })
            { pkgName = "npmconf"; };
    in
    stdenv.mkDerivation {
      inherit dependencies extraDependencies;
      name = "npmconf";
      packageName = "npmconf";
      version = "2.1.3";
      src = fetchurl {
        url = "https://registry.npmjs.org/npmconf/-/npmconf-2.1.3.tgz";
        sha512 = "iTK+HI68GceCoGOHAQiJ/ik1iDfI7S+cgyG8A+PP18IU3X83kRhQIRhAUNj4Bp2JMx6Zrt5kCiozYa9uGWTjhA==";
      };
      buildInputs = [ nodejs python3 makeWrapper jq  ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "npmconf"; });
      dontStrip = true;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "configureScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "npmconf"; };
      configureScript = mkConfigureScript {};
      buildScript = mkBuildScript { inherit dependencies; pkgName = "npmconf"; };
      buildPhase = ''
      source $unpackScriptPath 
      source $configureScriptPath
      runHook preBuild
      if [ -z "$preBuild" ]; then
        runHook preInstall
      fi
      source $buildScriptPath
      if [ -z "$postBuild" ]; then
        runHook postBuild
      fi
    '';
      patchPhase = ''
      if [ -z "$prePatch" ]; then
        runHook prePatch
      fi
      
      if [ -z "$postPatch" ]; then
        runHook postPatch
      fi
    '';
      installScript = mkInstallScript { pkgName = "npmconf"; };
      installPhase = ''
      if [ -z "$preInstall" ]; then
        runHook preInstall
      fi
      source $installScriptPath
      if [ -z "$postInstall" ]; then
        runHook postInstall
      fi
    '';
      preInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preInstall"; pkgName = "npmconf"; });
      postInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postInstall"; pkgName = "npmconf"; });
      preBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preBuild"; pkgName = "npmconf"; });
      postBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postBuild"; pkgName = "npmconf"; });
      doInstallCheck = true;
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "npmconf"; });
      meta = {
        description = "The config module for npm circa npm@1 and npm@2";
        license = "ISC";
        homepage = "https://github.com/npm/npmconf#readme";
      };
    };
    npmlog = let
      dependencies = [
        (sources."ansi-regex-2.1.1" {
          dependencies = [];
        })
        (sources."aproba-1.2.0" {
          dependencies = [];
        })
        (sources."are-we-there-yet-1.1.5" {
          dependencies = [];
        })
        (sources."code-point-at-1.1.0" {
          dependencies = [];
        })
        (sources."console-control-strings-1.1.0" {
          dependencies = [];
        })
        (sources."core-util-is-1.0.2" {
          dependencies = [];
        })
        (sources."delegates-1.0.0" {
          dependencies = [];
        })
        (sources."gauge-2.7.4" {
          dependencies = [];
        })
        (sources."has-unicode-2.0.1" {
          dependencies = [];
        })
        (sources."inherits-2.0.4" {
          dependencies = [];
        })
        (sources."is-fullwidth-code-point-1.0.0" {
          dependencies = [];
        })
        (sources."isarray-1.0.0" {
          dependencies = [];
        })
        (sources."number-is-nan-1.0.1" {
          dependencies = [];
        })
        (sources."object-assign-4.1.1" {
          dependencies = [];
        })
        (sources."process-nextick-args-2.0.1" {
          dependencies = [];
        })
        (sources."readable-stream-2.3.7" {
          dependencies = [];
        })
        (sources."safe-buffer-5.1.2" {
          dependencies = [];
        })
        (sources."set-blocking-2.0.0" {
          dependencies = [];
        })
        (sources."signal-exit-3.0.3" {
          dependencies = [];
        })
        (sources."string-width-1.0.2" {
          dependencies = [];
        })
        (sources."string_decoder-1.1.1" {
          dependencies = [];
        })
        (sources."strip-ansi-3.0.1" {
          dependencies = [];
        })
        (sources."util-deprecate-1.0.2" {
          dependencies = [];
        })
        (sources."wide-align-1.1.3" {
          dependencies = [];
        })
      ];
      extraDependencies = [] ++
        mkExtraDependencies
           (pkgs // { inherit jsnixDeps dependencies; })
            { pkgName = "npmlog"; };
    in
    stdenv.mkDerivation {
      inherit dependencies extraDependencies;
      name = "npmlog";
      packageName = "npmlog";
      version = "4.1.2";
      src = fetchurl {
        url = "https://registry.npmjs.org/npmlog/-/npmlog-4.1.2.tgz";
        sha512 = "2uUqazuKlTaSI/dC8AzicUck7+IrEaOnN/e0jd3Xtt1KcGpwx30v50mL7oPyr/h9bL3E4aZccVwpwP+5W9Vjkg==";
      };
      buildInputs = [ nodejs python3 makeWrapper jq  ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "npmlog"; });
      dontStrip = true;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "configureScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "npmlog"; };
      configureScript = mkConfigureScript {};
      buildScript = mkBuildScript { inherit dependencies; pkgName = "npmlog"; };
      buildPhase = ''
      source $unpackScriptPath 
      source $configureScriptPath
      runHook preBuild
      if [ -z "$preBuild" ]; then
        runHook preInstall
      fi
      source $buildScriptPath
      if [ -z "$postBuild" ]; then
        runHook postBuild
      fi
    '';
      patchPhase = ''
      if [ -z "$prePatch" ]; then
        runHook prePatch
      fi
      
      if [ -z "$postPatch" ]; then
        runHook postPatch
      fi
    '';
      installScript = mkInstallScript { pkgName = "npmlog"; };
      installPhase = ''
      if [ -z "$preInstall" ]; then
        runHook preInstall
      fi
      source $installScriptPath
      if [ -z "$postInstall" ]; then
        runHook postInstall
      fi
    '';
      preInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preInstall"; pkgName = "npmlog"; });
      postInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postInstall"; pkgName = "npmlog"; });
      preBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preBuild"; pkgName = "npmlog"; });
      postBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postBuild"; pkgName = "npmlog"; });
      doInstallCheck = true;
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "npmlog"; });
      meta = {
        description = "logger for npm";
        license = "ISC";
        homepage = "https://github.com/npm/npmlog#readme";
      };
    };
    optparse = let
      dependencies = [];
      extraDependencies = [] ++
        mkExtraDependencies
           (pkgs // { inherit jsnixDeps dependencies; })
            { pkgName = "optparse"; };
    in
    stdenv.mkDerivation {
      inherit dependencies extraDependencies;
      name = "optparse";
      packageName = "optparse";
      version = "1.0.5";
      src = fetchurl {
        url = "https://registry.npmjs.org/optparse/-/optparse-1.0.5.tgz";
        sha1 = "75e75a96506611eb1c65ba89018ff08a981e2c16";
      };
      buildInputs = [ nodejs python3 makeWrapper jq  ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "optparse"; });
      dontStrip = true;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "configureScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "optparse"; };
      configureScript = mkConfigureScript {};
      buildScript = mkBuildScript { inherit dependencies; pkgName = "optparse"; };
      buildPhase = ''
      source $unpackScriptPath 
      source $configureScriptPath
      runHook preBuild
      if [ -z "$preBuild" ]; then
        runHook preInstall
      fi
      source $buildScriptPath
      if [ -z "$postBuild" ]; then
        runHook postBuild
      fi
    '';
      patchPhase = ''
      if [ -z "$prePatch" ]; then
        runHook prePatch
      fi
      
      if [ -z "$postPatch" ]; then
        runHook postPatch
      fi
    '';
      installScript = mkInstallScript { pkgName = "optparse"; };
      installPhase = ''
      if [ -z "$preInstall" ]; then
        runHook preInstall
      fi
      source $installScriptPath
      if [ -z "$postInstall" ]; then
        runHook postInstall
      fi
    '';
      preInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preInstall"; pkgName = "optparse"; });
      postInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postInstall"; pkgName = "optparse"; });
      preBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preBuild"; pkgName = "optparse"; });
      postBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postBuild"; pkgName = "optparse"; });
      doInstallCheck = true;
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "optparse"; });
      meta = {
        description = "Command-line option parser";
        homepage = "";
      };
    };
    rambda = let
      dependencies = [];
      extraDependencies = [] ++
        mkExtraDependencies
           (pkgs // { inherit jsnixDeps dependencies; })
            { pkgName = "rambda"; };
    in
    stdenv.mkDerivation {
      inherit dependencies extraDependencies;
      name = "rambda";
      packageName = "rambda";
      version = "6.9.0";
      src = fetchurl {
        url = "https://registry.npmjs.org/rambda/-/rambda-6.9.0.tgz";
        sha512 = "yosVdGg1hNGkXPzqGiOYNEpXKjEOxzUCg2rB0l+NKdyCaSf4z+i5ojbN0IqDSezMMf71YEglI+ZUTgTffn5afw==";
      };
      buildInputs = [ nodejs python3 makeWrapper jq  ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "rambda"; });
      dontStrip = true;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "configureScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "rambda"; };
      configureScript = mkConfigureScript {};
      buildScript = mkBuildScript { inherit dependencies; pkgName = "rambda"; };
      buildPhase = ''
      source $unpackScriptPath 
      source $configureScriptPath
      runHook preBuild
      if [ -z "$preBuild" ]; then
        runHook preInstall
      fi
      source $buildScriptPath
      if [ -z "$postBuild" ]; then
        runHook postBuild
      fi
    '';
      patchPhase = ''
      if [ -z "$prePatch" ]; then
        runHook prePatch
      fi
      
      if [ -z "$postPatch" ]; then
        runHook postPatch
      fi
    '';
      installScript = mkInstallScript { pkgName = "rambda"; };
      installPhase = ''
      if [ -z "$preInstall" ]; then
        runHook preInstall
      fi
      source $installScriptPath
      if [ -z "$postInstall" ]; then
        runHook postInstall
      fi
    '';
      preInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preInstall"; pkgName = "rambda"; });
      postInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postInstall"; pkgName = "rambda"; });
      preBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preBuild"; pkgName = "rambda"; });
      postBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postBuild"; pkgName = "rambda"; });
      doInstallCheck = true;
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "rambda"; });
      meta = {
        description = "Lightweight and faster alternative to Ramda with included TS definitions";
        license = "MIT";
        homepage = "https://github.com/selfrefactor/rambda#readme";
      };
    };
    semver = let
      dependencies = [
        (sources."lru-cache-6.0.0" {
          dependencies = [];
        })
        (sources."yallist-4.0.0" {
          dependencies = [];
        })
      ];
      extraDependencies = [] ++
        mkExtraDependencies
           (pkgs // { inherit jsnixDeps dependencies; })
            { pkgName = "semver"; };
    in
    stdenv.mkDerivation {
      inherit dependencies extraDependencies;
      name = "semver";
      packageName = "semver";
      version = "7.3.5";
      src = fetchurl {
        url = "https://registry.npmjs.org/semver/-/semver-7.3.5.tgz";
        sha512 = "PoeGJYh8HK4BTO/a9Tf6ZG3veo/A7ZVsYrSA6J8ny9nb3B1VrpkuN+z9OE5wfE5p6H4LchYZsegiQgbJD94ZFQ==";
      };
      buildInputs = [ nodejs python3 makeWrapper jq  ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "semver"; });
      dontStrip = true;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "configureScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "semver"; };
      configureScript = mkConfigureScript {};
      buildScript = mkBuildScript { inherit dependencies; pkgName = "semver"; };
      buildPhase = ''
      source $unpackScriptPath 
      source $configureScriptPath
      runHook preBuild
      if [ -z "$preBuild" ]; then
        runHook preInstall
      fi
      source $buildScriptPath
      if [ -z "$postBuild" ]; then
        runHook postBuild
      fi
    '';
      patchPhase = ''
      if [ -z "$prePatch" ]; then
        runHook prePatch
      fi
      
      if [ -z "$postPatch" ]; then
        runHook postPatch
      fi
    '';
      installScript = mkInstallScript { pkgName = "semver"; };
      installPhase = ''
      if [ -z "$preInstall" ]; then
        runHook preInstall
      fi
      source $installScriptPath
      if [ -z "$postInstall" ]; then
        runHook postInstall
      fi
    '';
      preInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preInstall"; pkgName = "semver"; });
      postInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postInstall"; pkgName = "semver"; });
      preBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preBuild"; pkgName = "semver"; });
      postBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postBuild"; pkgName = "semver"; });
      doInstallCheck = true;
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "semver"; });
      meta = {
        description = "The semantic version parser used by npm.";
        license = "ISC";
        homepage = "https://github.com/npm/node-semver#readme";
      };
    };
    spdx-license-ids = let
      dependencies = [];
      extraDependencies = [] ++
        mkExtraDependencies
           (pkgs // { inherit jsnixDeps dependencies; })
            { pkgName = "spdx-license-ids"; };
    in
    stdenv.mkDerivation {
      inherit dependencies extraDependencies;
      name = "spdx-license-ids";
      packageName = "spdx-license-ids";
      version = "3.0.9";
      src = fetchurl {
        url = "https://registry.npmjs.org/spdx-license-ids/-/spdx-license-ids-3.0.9.tgz";
        sha512 = "Ki212dKK4ogX+xDo4CtOZBVIwhsKBEfsEEcwmJfLQzirgc2jIWdzg40Unxz/HzEUqM1WFzVlQSMF9kZZ2HboLQ==";
      };
      buildInputs = [ nodejs python3 makeWrapper jq  ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "spdx-license-ids"; });
      dontStrip = true;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "configureScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "spdx-license-ids"; };
      configureScript = mkConfigureScript {};
      buildScript = mkBuildScript { inherit dependencies; pkgName = "spdx-license-ids"; };
      buildPhase = ''
      source $unpackScriptPath 
      source $configureScriptPath
      runHook preBuild
      if [ -z "$preBuild" ]; then
        runHook preInstall
      fi
      source $buildScriptPath
      if [ -z "$postBuild" ]; then
        runHook postBuild
      fi
    '';
      patchPhase = ''
      if [ -z "$prePatch" ]; then
        runHook prePatch
      fi
      
      if [ -z "$postPatch" ]; then
        runHook postPatch
      fi
    '';
      installScript = mkInstallScript { pkgName = "spdx-license-ids"; };
      installPhase = ''
      if [ -z "$preInstall" ]; then
        runHook preInstall
      fi
      source $installScriptPath
      if [ -z "$postInstall" ]; then
        runHook postInstall
      fi
    '';
      preInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preInstall"; pkgName = "spdx-license-ids"; });
      postInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postInstall"; pkgName = "spdx-license-ids"; });
      preBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preBuild"; pkgName = "spdx-license-ids"; });
      postBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postBuild"; pkgName = "spdx-license-ids"; });
      doInstallCheck = true;
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "spdx-license-ids"; });
      meta = {
        description = "A list of SPDX license identifiers";
        license = "CC0-1.0";
        homepage = "https://github.com/jslicense/spdx-license-ids#readme";
      };
    };
    tar = let
      dependencies = [
        (sources."chownr-2.0.0" {
          dependencies = [];
        })
        (sources."fs-minipass-2.1.0" {
          dependencies = [];
        })
        (sources."minipass-3.1.3" {
          dependencies = [];
        })
        (sources."minizlib-2.1.2" {
          dependencies = [];
        })
        (sources."mkdirp-1.0.4" {
          dependencies = [];
        })
        (sources."yallist-4.0.0" {
          dependencies = [];
        })
      ];
      extraDependencies = [] ++
        mkExtraDependencies
           (pkgs // { inherit jsnixDeps dependencies; })
            { pkgName = "tar"; };
    in
    stdenv.mkDerivation {
      inherit dependencies extraDependencies;
      name = "tar";
      packageName = "tar";
      version = "6.1.2";
      src = fetchurl {
        url = "https://registry.npmjs.org/tar/-/tar-6.1.2.tgz";
        sha512 = "EwKEgqJ7nJoS+s8QfLYVGMDmAsj+StbI2AM/RTHeUSsOw6Z8bwNBRv5z3CY0m7laC5qUAqruLX5AhMuc5deY3Q==";
      };
      buildInputs = [ nodejs python3 makeWrapper jq  ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "tar"; });
      dontStrip = true;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "configureScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "tar"; };
      configureScript = mkConfigureScript {};
      buildScript = mkBuildScript { inherit dependencies; pkgName = "tar"; };
      buildPhase = ''
      source $unpackScriptPath 
      source $configureScriptPath
      runHook preBuild
      if [ -z "$preBuild" ]; then
        runHook preInstall
      fi
      source $buildScriptPath
      if [ -z "$postBuild" ]; then
        runHook postBuild
      fi
    '';
      patchPhase = ''
      if [ -z "$prePatch" ]; then
        runHook prePatch
      fi
      
      if [ -z "$postPatch" ]; then
        runHook postPatch
      fi
    '';
      installScript = mkInstallScript { pkgName = "tar"; };
      installPhase = ''
      if [ -z "$preInstall" ]; then
        runHook preInstall
      fi
      source $installScriptPath
      if [ -z "$postInstall" ]; then
        runHook postInstall
      fi
    '';
      preInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preInstall"; pkgName = "tar"; });
      postInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postInstall"; pkgName = "tar"; });
      preBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preBuild"; pkgName = "tar"; });
      postBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postBuild"; pkgName = "tar"; });
      doInstallCheck = true;
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "tar"; });
      meta = {
        description = "tar for node";
        license = "ISC";
        homepage = "https://github.com/npm/node-tar#readme";
      };
    };
    web-tree-sitter = let
      dependencies = [];
      extraDependencies = [] ++
        mkExtraDependencies
           (pkgs // { inherit jsnixDeps dependencies; })
            { pkgName = "web-tree-sitter"; };
    in
    stdenv.mkDerivation {
      inherit dependencies extraDependencies;
      name = "web-tree-sitter";
      packageName = "web-tree-sitter";
      version = "0.19.4";
      src = fetchurl {
        url = "https://registry.npmjs.org/web-tree-sitter/-/web-tree-sitter-0.19.4.tgz";
        sha512 = "8G0xBj05hqZybCqBtW7RPZ/hWEtP3DiLTauQzGJZuZYfVRgw7qj7iaZ+8djNqJ4VPrdOO+pS2dR1JsTbsLxdYg==";
      };
      buildInputs = [ nodejs python3 makeWrapper jq  ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "web-tree-sitter"; });
      dontStrip = true;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "configureScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "web-tree-sitter"; };
      configureScript = mkConfigureScript {};
      buildScript = mkBuildScript { inherit dependencies; pkgName = "web-tree-sitter"; };
      buildPhase = ''
      source $unpackScriptPath 
      source $configureScriptPath
      runHook preBuild
      if [ -z "$preBuild" ]; then
        runHook preInstall
      fi
      source $buildScriptPath
      if [ -z "$postBuild" ]; then
        runHook postBuild
      fi
    '';
      patchPhase = ''
      if [ -z "$prePatch" ]; then
        runHook prePatch
      fi
      
      if [ -z "$postPatch" ]; then
        runHook postPatch
      fi
    '';
      installScript = mkInstallScript { pkgName = "web-tree-sitter"; };
      installPhase = ''
      if [ -z "$preInstall" ]; then
        runHook preInstall
      fi
      source $installScriptPath
      if [ -z "$postInstall" ]; then
        runHook postInstall
      fi
    '';
      preInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preInstall"; pkgName = "web-tree-sitter"; });
      postInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postInstall"; pkgName = "web-tree-sitter"; });
      preBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preBuild"; pkgName = "web-tree-sitter"; });
      postBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postBuild"; pkgName = "web-tree-sitter"; });
      doInstallCheck = true;
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "web-tree-sitter"; });
      meta = {
        description = "Tree-sitter bindings for the web";
        license = "MIT";
        homepage = "https://github.com/tree-sitter/tree-sitter/tree/master/lib/binding_web";
      };
    };
  };
in
jsnixDeps // (if builtins.hasAttr "packageDerivation" packageNix then {
  "${packageNix.name}" = jsnixDrvOverrides {
    inherit jsnixDeps;
    drv = packageNix.packageDerivation (pkgs // {
      inherit nodejs copyNodeModules linkNodeModules gitignoreSource jsnixDeps getNodeDep;
    });
  };
} else {})