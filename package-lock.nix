{pkgs, stdenv, lib, nodejs, fetchurl, fetchgit, fetchFromGitHub, jq, makeWrapper, python3, runCommand, runCommandCC, xcodebuild, ... }:

let
  packageNix = import ./package.nix;
  copyNodeModules = {dependencies ? [] }:
    (lib.lists.foldr (dep: acc:
      let pkgName = if (builtins.hasAttr "packageName" dep)
                    then dep.packageName else dep.name;
      in
      acc + ''
      if [[ ! -f "node_modules/${pkgName}" && \
            ! -d "node_modules/${pkgName}" && \
            ! -L "node_modules/${pkgName}" && \
            ! -e "node_modules/${pkgName}" ]]
     then
       mkdir -p "node_modules/${pkgName}"
       cp -rLT "${dep}/lib/node_modules/${pkgName}" "node_modules/${pkgName}"
       chmod -R +rw "node_modules/${pkgName}"
     fi
     '')
     "" dependencies);
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
  gitignoreSource = 
    (import (fetchFromGitHub {
      owner = "hercules-ci";
      repo = "gitignore.nix";
      rev = "5b9e0ff9d3b551234b4f3eb3983744fa354b17f1";
      sha256 = "o/BdVjNwcB6jOmzZjOH703BesSkkS5O7ej3xhyO8hAY=";
    }) { inherit lib; }).gitignoreSource;
  transitiveDepInstallPhase = {dependencies ? [], pkgName}: ''
    export packageDir="$(pwd)"
    mkdir -p $out/lib/node_modules/${pkgName}
    cd $out/lib/node_modules/${pkgName}
    cp -rfT "$packageDir" "$(pwd)"
    ${copyNodeModules { inherit dependencies; }} '';
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
  linkBins = ''
    ${goBinLink}/bin/bin-link
'';
  flattenScript = args: '' ${goFlatten}/bin/flatten ${args}'';
  sanitizeName = nm: lib.strings.sanitizeDerivationName
    (builtins.replaceStrings [ "@" "/" ] [ "_at_" "_" ] nm);
  jsnixDrvOverrides = { drv_, jsnixDeps, dedupedDeps, isolateDeps }:
    let drv = drv_ (pkgs // { inherit nodejs copyNodeModules gitignoreSource jsnixDeps nodeModules getNodeDep; });
        skipUnpackFor = if (builtins.hasAttr "skipUnpackFor" drv)
                        then drv.skipUnpackFor else [];
        copyUnpackFor = if (builtins.hasAttr "copyUnpackFor" drv)
                        then drv.copyUnpackFor else [];
        pkgJsonFile = runCommand "package.json" { buildInputs = [jq]; } ''
          echo ${toPackageJson { inherit jsnixDeps; extraDeps = (if (builtins.hasAttr "extraDependencies" drv) then drv.extraDependencies else []); }} > $out
          cat <<< $(cat $out | jq) > $out
        '';
        copyDeps = builtins.attrValues jsnixDeps;
        copyDepsStr = builtins.concatStringsSep " " (builtins.map (dep: if (builtins.hasAttr "packageName" dep) then dep.packageName else dep.name) copyDeps);
        extraDeps = (builtins.map (dep: if (builtins.hasAttr "packageName" dep) then dep.packageName else dep.name)
                      (lib.optionals (builtins.hasAttr "extraDependencies" drv) drv.extraDependencies));
        extraDepsStr = builtins.concatStringsSep " " extraDeps;
        buildDepDep = lib.lists.unique (lib.lists.concatMap (d: d.buildInputs)
                        (copyDeps ++ (lib.optionals (builtins.hasAttr "extraDependencies" drv) drv.extraDependencies)));
        nodeModules = runCommandCC "${sanitizeName packageNix.name}_node_modules"
          { buildInputs = [nodejs] ++ buildDepDep;
            fixupPhase = "true";
            doCheck = false;
            doInstallCheck = false;
            version = builtins.hashString "sha512" (lib.strings.concatStrings copyDeps); }
         ''
           echo 'unpack dependencies...'
           mkdir -p $out/lib/node_modules
           cd $out/lib
           ${linkNodeModules { dependencies = builtins.attrValues isolateDeps; }}
           ${copyNodeModules {
                dependencies = copyDeps;
           }}
           ${copyNodeModules {
                dependencies = builtins.attrValues dedupedDeps;
           }}
           chmod -R +rw node_modules
           ${copyNodeModules {
                dependencies = (lib.optionals (builtins.hasAttr "extraDependencies" drv) drv.extraDependencies);
           }}
           ${lib.optionalString ((builtins.length extraDeps) > 0) "echo 'resolving incoming transient deps of ${extraDepsStr}...'"}
           ${lib.optionalString ((builtins.length extraDeps) > 0) (flattenScript extraDepsStr)}
           ${lib.optionalString (builtins.hasAttr "nodeModulesUnpack" drv) drv.nodeModulesUnpack}
           echo 'link nodejs bins to out-dir...'
           ${linkBins}
        '';
    in stdenv.mkDerivation (drv // {
      passthru = { inherit nodeModules pkgJsonFile; };
      version = packageNix.version;
      name = sanitizeName packageNix.name;
      preUnpackBan_ = mkPhaseBan "preUnpack" drv;
      unpackBan_ = mkPhaseBan "unpackPhase" drv;
      postUnpackBan_ = mkPhaseBan "postUnpack" drv;
      preConfigureBan_ = mkPhaseBan "preConfigure" drv;
      configureBan_ = mkPhaseBan "configurePhase" drv;
      postConfigureBan_ = mkPhaseBan "postConfigure" drv;
      src = if (builtins.hasAttr "src" packageNix) then packageNix.src else gitignoreSource ./.;
      packageName = packageNix.name;
      doStrip = false;
      doFixup = false;
      doUnpack = true;
      NODE_PATH = "./node_modules";
      buildInputs = [ nodejs jq ] ++ lib.optionals (builtins.hasAttr "buildInputs" drv) drv.buildInputs;

      configurePhase = ''
        ln -s ${nodeModules}/lib/node_modules node_modules
        cat ${pkgJsonFile} > package.json
      '';
      buildPhase = ''
        runHook preBuild
       ${lib.optionalString (builtins.hasAttr "buildPhase" drv) drv.buildPhase}
       runHook postBuild
      '';
      installPhase =  ''
          runHook preInstall
          mkdir -p $out/lib/node_modules/${packageNix.name}
          cp -rfT ./ $out/lib/node_modules/${packageNix.name}
          runHook postInstall
       '';
  });
  toPackageJson = { jsnixDeps ? {}, extraDeps ? [] }:
    let
      main = if (builtins.hasAttr "main" packageNix) then packageNix else throw "package.nix is missing main attribute";
      pkgName = if (builtins.hasAttr "packageName" packageNix)
                then packageNix.packageName else packageNix.name;
      packageNixDeps = if (builtins.hasAttr "dependencies" packageNix)
                       then packageNix.dependencies
                       else {};
      extraDeps_ = lib.lists.foldr (dep: acc: { "${dep.packageName}" = dep; } // acc) {} extraDeps;
      allDeps = extraDeps_ // packageNixDeps;
      prodDeps = lib.lists.foldr
        (depName: acc: acc // {
          "${depName}" = (if ((builtins.typeOf allDeps."${depName}") == "string")
                          then allDeps."${depName}"
                          else
                            if (((builtins.typeOf allDeps."${depName}") == "set") &&
                                ((builtins.typeOf allDeps."${depName}".version) == "string"))
                          then allDeps."${depName}".version
                          else "latest");}) {} (builtins.attrNames allDeps);
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
         (packageNix.dependencies."${pkgName}"."${phase}" (pkgs_ // { inherit getNodeDep; })));
  mkExtraBuildInputs = pkgs_: {pkgName}:
     lib.optionals ((builtins.hasAttr "${pkgName}" packageNix.dependencies) &&
                    (builtins.typeOf packageNix.dependencies."${pkgName}" == "set") &&
                    (builtins.hasAttr "extraBuildInputs" packageNix.dependencies."${pkgName}"))
      (if builtins.typeOf packageNix.dependencies."${pkgName}"."extraBuildInputs" == "list"
       then
         packageNix.dependencies."${pkgName}"."extraBuildInputs"
       else
         (packageNix.dependencies."${pkgName}"."extraBuildInputs" (pkgs_ // { inherit getNodeDep; })));
  mkExtraDependencies = pkgs_: {pkgName}:
     lib.optionals ((builtins.hasAttr "${pkgName}" packageNix.dependencies) &&
                    (builtins.typeOf packageNix.dependencies."${pkgName}" == "set") &&
                    (builtins.hasAttr "extraDependencies" packageNix.dependencies."${pkgName}"))
      (if builtins.typeOf packageNix.dependencies."${pkgName}"."extraDependencies" == "list"
       then
         packageNix.dependencies."${pkgName}"."extraDependencies"
       else
         (packageNix.dependencies."${pkgName}"."extraDependencies" (pkgs_ // { inherit getNodeDep; })));
  mkUnpackScript = { dependencies ? [], extraDependencies ? [], pkgName }:
     let copyNodeDependencies =
       if ((builtins.hasAttr "${pkgName}" packageNix.dependencies) &&
           (builtins.typeOf packageNix.dependencies."${pkgName}" == "set") &&
           (builtins.hasAttr "copyNodeDependencies" packageNix.dependencies."${pkgName}") &&
           (builtins.typeOf packageNix.dependencies."${pkgName}"."copyNodeDependencies" == "bool") &&
           (packageNix.dependencies."${pkgName}"."copyNodeDependencies" == true))
       then true else false;
     in ''
      ${copyNodeModules { dependencies = dependencies ++ extraDependencies; }}
      chmod -R +rw $(pwd)
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
  goBinLink = pkgs.buildGoModule {
  pname = "bin-link";
  version = "0.0.0";
  vendorSha256 = null;
  buildInputs = [ pkgs.nodejs ];
  src = pkgs.fetchFromGitHub {
    owner = "hlolli";
    repo = "jsnix";
    rev = "a66cf91ad49833ef3d84064c1037d942c97838bb";
    sha256 = "AvDZXUSxuJa5lZ7zRdXWIDYTYfbH2VfpuHbvZBrT9f0=";
  };
  preBuild = ''
    cd go/bin-link
  '';
};
  goFlatten = pkgs.buildGoModule {
  pname = "flatten";
  version = "0.0.0";
  vendorSha256 = null;
  buildInputs = [ pkgs.nodejs ];
  src = pkgs.fetchFromGitHub {
    owner = "hlolli";
    repo = "jsnix";
    rev = "a66cf91ad49833ef3d84064c1037d942c97838bb";
    sha256 = "AvDZXUSxuJa5lZ7zRdXWIDYTYfbH2VfpuHbvZBrT9f0=";
  };
  preBuild = ''
    cd go/flatten
  '';
};
  sources = rec {
    "@gar/promisify-1.1.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_gar_slash_promisify";
      packageName = "@gar/promisify";
      version = "1.1.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@gar/promisify"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@gar/promisify"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@gar/promisify/-/promisify-1.1.2.tgz";
        sha512 = "82cpyJyKRoQoRi+14ibCeGPu0CwypgtBAdBhq1WfvagpCZNKqwXbKwXllYSMG91DhmG4jt9gN8eP6lGOtozuaw==";
      };
    };
    "@npmcli/fs-1.1.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_npmcli_slash_fs";
      packageName = "@npmcli/fs";
      version = "1.1.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@npmcli/fs"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@npmcli/fs"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@npmcli/fs/-/fs-1.1.0.tgz";
        sha512 = "VhP1qZLXcrXRIaPoqb4YA55JQxLNF3jNR4T55IdOJa3+IFJKNYHtPvtXx8slmeMavj37vCzCfrqQM1vWLsYKLA==";
      };
    };
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@npmcli/move-file"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@tootallnate/once"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "abbrev"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "agent-base"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "agentkeepalive"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "aggregate-error"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/aggregate-error/-/aggregate-error-3.1.0.tgz";
        sha512 = "4I7Td01quW/RpocfNayFdFVk1qSuoh0E7JrbRJ16nH01HhKFQ88INq9Sd+nd72zqRySlr9BmDA8xlEJ6vJMrYA==";
      };
    };
    "ansi-regex-5.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "ansi-regex";
      packageName = "ansi-regex";
      version = "5.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "ansi-regex"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "ansi-regex"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/ansi-regex/-/ansi-regex-5.0.1.tgz";
        sha512 = "quJQXlTSUGL2LH9SUXo8VwsY4soanhgo6LNSm84E1LBcE8s3O0wpdiRzyR9z/ZZJMlMWv37qOOb9pdJlMUEKFQ==";
      };
    };
    "aproba-2.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "aproba";
      packageName = "aproba";
      version = "2.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "aproba"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "aproba"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/aproba/-/aproba-2.0.0.tgz";
        sha512 = "lYe4Gx7QT+MKGbDsA+Z+he/Wtef0BiwDOlK/XkBrdfsh9J/jPPXbX0tE9x9cl27Tmu5gg3QUbUrQYa/y+KOHPQ==";
      };
    };
    "are-we-there-yet-2.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "are-we-there-yet";
      packageName = "are-we-there-yet";
      version = "2.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "are-we-there-yet"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "are-we-there-yet"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/are-we-there-yet/-/are-we-there-yet-2.0.0.tgz";
        sha512 = "Ci/qENmwHnsYo9xKIcUJN5LeDKdJ6R1Z1j9V/J5wyq8nh/mYPEpIKJbBZXtZjG04HiK7zV/p6Vs9952MrMeUIw==";
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "balanced-match"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "brace-expansion"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/brace-expansion/-/brace-expansion-1.1.11.tgz";
        sha512 = "iCuPHDFgrHX7H2vEI/5xpz07zSHB00TpugqhmYtVmMO6518mCuRMoOYFldEBl0g187ufozdaHgWKcYFb61qGiA==";
      };
    };
    "braces-3.0.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "braces";
      packageName = "braces";
      version = "3.0.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "braces"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "braces"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/braces/-/braces-3.0.2.tgz";
        sha512 = "b8um+L1RzM3WDSzvhm6gIz1yfTbBt6YTlcEKAvsmqCZZFw46z626lVj9j1yEPW33H5H+lBQpZMP1k8l+78Ha0A==";
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "builtins"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/builtins/-/builtins-1.0.3.tgz";
        sha1 = "cb94faeb61c8696451db36534e1422f94f0aee88";
      };
    };
    "cacache-15.3.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "cacache";
      packageName = "cacache";
      version = "15.3.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "cacache"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "cacache"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/cacache/-/cacache-15.3.0.tgz";
        sha512 = "VVdYzXEn+cnbXpFgWs5hTT7OScegHVmLhJIR8Ufqk3iFD6A6j5iSX1KuBTfNEv4tdJWE2PzA6IVFtcLC7fN9wQ==";
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "call-bind"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "chownr"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "clean-stack"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/clean-stack/-/clean-stack-2.2.0.tgz";
        sha512 = "4diC9HaTE+KRAMWhDhrGOECgWZxoevMc5TlkObMqNSsVU62PYzXZ/SMTjzyGAFF1YusgxGcSWTEXBhp0CPwQ1A==";
      };
    };
    "color-support-1.1.3" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "color-support";
      packageName = "color-support";
      version = "1.1.3";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "color-support"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "color-support"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/color-support/-/color-support-1.1.3.tgz";
        sha512 = "qiBjkpbMLO/HL68y+lh4q0/O1MZFj2RX6X/KmMa3+gJD3z+WwI1ZzDHysvqHGS3mP6mznPckpXmw1nI9cJjyRg==";
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "concat-map"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "config-chain"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "console-control-strings"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/console-control-strings/-/console-control-strings-1.1.0.tgz";
        sha1 = "3d7cf4464db6446ea644bf4b39507f9851008e8e";
      };
    };
    "debug-4.3.3" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "debug";
      packageName = "debug";
      version = "4.3.3";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "debug"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "debug"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/debug/-/debug-4.3.3.tgz";
        sha512 = "/zxw5+vh1Tfv+4Qn7a5nsbcJKPaSvCDhojn6FEl9vupwK2VCSDtEiEtqr8DFtzYFOdz63LBkxec7DYuc2jon6Q==";
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "decode-uri-component"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "delegates"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "depd"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/depd/-/depd-1.1.2.tgz";
        sha1 = "9bcd52e14c097763e749b274c4346ed2e560b5a9";
      };
    };
    "emoji-regex-8.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "emoji-regex";
      packageName = "emoji-regex";
      version = "8.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "emoji-regex"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "emoji-regex"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/emoji-regex/-/emoji-regex-8.0.0.tgz";
        sha512 = "MSjYzcWNOA0ewAHpz0MxpYFvwg6yjy1NG3xteoqz644VCo/RPgnr1/GGt+ic3iJTzQ8Eu3TdM14SawnVUmGE6A==";
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "err-code"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/err-code/-/err-code-2.0.3.tgz";
        sha512 = "2bmlRpNKBxT/CRmPOlyISQpNj+qSeYvcym/uT0Jx2bMOlKLtSy1ZmLuVxSEKKyor/N5yhvp/ZiG1oE3DEYMSFA==";
      };
    };
    "fill-range-7.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "fill-range";
      packageName = "fill-range";
      version = "7.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "fill-range"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "fill-range"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/fill-range/-/fill-range-7.0.1.tgz";
        sha512 = "qOo9F+dMUmC2Lcb4BbVvnKJxTPjCm+RRpe4gDuGrzkL7mEVl/djYSu2OdQ2Pa302N4oqkSg9ir6jaLWJ2USVpQ==";
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "filter-obj"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "fs-minipass"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "fs.realpath"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "function-bind"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/function-bind/-/function-bind-1.1.1.tgz";
        sha512 = "yIovAzMX49sF8Yl58fSCWJ5svSLuaibPxXQJFLmBObTuCr0Mf1KiPopGM9NiFjiYBCbfaa2Fh6breQ6ANVTI0A==";
      };
    };
    "gauge-4.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "gauge";
      packageName = "gauge";
      version = "4.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "gauge"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "gauge"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/gauge/-/gauge-4.0.0.tgz";
        sha512 = "F8sU45yQpjQjxKkm1UOAhf0U/O0aFt//Fl7hsrNVto+patMHjs7dPI9mFOGUKbhrgKm0S3EjW3scMFuQmWSROw==";
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "get-intrinsic"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "git-up"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/git-up/-/git-up-4.0.5.tgz";
        sha512 = "YUvVDg/vX3d0syBsk/CKUTib0srcQME0JyHkL5BaYdwLsiCslPWmDSi8PUMo9pXYjrryMcmsCoCgsTpSCJEQaA==";
      };
    };
    "glob-7.2.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "glob";
      packageName = "glob";
      version = "7.2.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "glob"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "glob"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/glob/-/glob-7.2.0.tgz";
        sha512 = "lmLf6gtyrPq8tTjSmrO94wBeQbFR3HbLHbuyD69wuyQkImp2hWqMGB47OX65FBkPffO641IP9jWa1z4ivqG26Q==";
      };
    };
    "graceful-fs-4.2.8" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "graceful-fs";
      packageName = "graceful-fs";
      version = "4.2.8";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "graceful-fs"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "graceful-fs"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/graceful-fs/-/graceful-fs-4.2.8.tgz";
        sha512 = "qkIilPUYcNhJpd33n0GBXTB1MMPp14TxEsEs0pTrsSVucApsYzW5V+Q8Qxhik6KU3evy+qkAAowTByymK0avdg==";
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "has"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "has-symbols"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "has-unicode"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "hosted-git-info"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "http-cache-semantics"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "http-proxy-agent"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "https-proxy-agent"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "humanize-ms"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "imurmurhash"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "indent-string"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "infer-owner"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "inflight"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "inherits"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "ini"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "ip"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/ip/-/ip-1.1.5.tgz";
        sha1 = "bdded70114290828c0a039e72ef25f5aaec4354a";
      };
    };
    "is-fullwidth-code-point-3.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "is-fullwidth-code-point";
      packageName = "is-fullwidth-code-point";
      version = "3.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "is-fullwidth-code-point"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "is-fullwidth-code-point"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/is-fullwidth-code-point/-/is-fullwidth-code-point-3.0.0.tgz";
        sha512 = "zymm5+u+sCsSWyD9qNaejV3DFvhCKclKdizYaJUuHA83RLjb7nSuGnddCHGv0hk+KY7BMAlsWeK4Ueg6EV6XQg==";
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "is-lambda"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/is-lambda/-/is-lambda-1.0.1.tgz";
        sha1 = "3d9877899e6a53efc0160504cde15f82e6f061d5";
      };
    };
    "is-number-7.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "is-number";
      packageName = "is-number";
      version = "7.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "is-number"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "is-number"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/is-number/-/is-number-7.0.0.tgz";
        sha512 = "41Cifkg6e8TylSpdtTpeLVMqvSBEVzTttHvERD741+pnZ8ANv0004MRL43QKPDlK9cGvNp6NZWZUBlbGXYxxng==";
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "is-ssh"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/is-ssh/-/is-ssh-1.3.3.tgz";
        sha512 = "NKzJmQzJfEEma3w5cJNcUMxoXfDjz0Zj0eyCalHn2E6VOwlzjZo0yuO2fcBSf8zhFuVCL/82/r5gRcoi6aEPVQ==";
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "jsonfile"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "jsonparse"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "lru-cache"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/lru-cache/-/lru-cache-6.0.0.tgz";
        sha512 = "Jo6dJ04CmSjuznwJSS3pUeWmd/H0ffTlkXXgwZi+eq1UCmqQwCh+eLsYOYCwY991i2Fah4h1BEMCx4qThGbsiA==";
      };
    };
    "make-fetch-happen-9.1.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "make-fetch-happen";
      packageName = "make-fetch-happen";
      version = "9.1.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "make-fetch-happen"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "make-fetch-happen"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/make-fetch-happen/-/make-fetch-happen-9.1.0.tgz";
        sha512 = "+zopwDy7DNknmwPQplem5lAZX/eCOzSvSNNcSKm5eVwTkOBzoktEfXsa9L23J/GIRhxRsaxzkPEhrJEpE2F4Gg==";
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "minimatch"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/minimatch/-/minimatch-3.0.4.tgz";
        sha512 = "yJHVQEhyqPLUTgt9B83PXu6W3rx4MvvHvSUvToogpwoGDOUQ+yDrR0HRot+yOCdCO7u4hX3pWft6kWBBcqh0UA==";
      };
    };
    "minipass-3.1.6" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "minipass";
      packageName = "minipass";
      version = "3.1.6";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "minipass"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "minipass"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/minipass/-/minipass-3.1.6.tgz";
        sha512 = "rty5kpw9/z8SX9dmxblFA6edItUmwJgMeYDZRrwlIVN27i8gysGbznJwUggw2V/FVqFSDdWy040ZPS811DYAqQ==";
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "minipass-collect"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/minipass-collect/-/minipass-collect-1.0.2.tgz";
        sha512 = "6T6lH0H8OG9kITm/Jm6tdooIbogG9e0tLgpY6mphXSm/A9u8Nq1ryBG+Qspiub9LjWlBPsPS3tWQ/Botq4FdxA==";
      };
    };
    "minipass-fetch-1.4.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "minipass-fetch";
      packageName = "minipass-fetch";
      version = "1.4.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "minipass-fetch"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "minipass-fetch"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/minipass-fetch/-/minipass-fetch-1.4.1.tgz";
        sha512 = "CGH1eblLq26Y15+Azk7ey4xh0J/XfJfrCox5LDJiKqI2Q2iwOLOKrlmIaODiSQS8d18jalF6y2K2ePUm0CmShw==";
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "minipass-flush"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "minipass-json-stream"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "minipass-pipeline"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "minipass-sized"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "minizlib"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/minizlib/-/minizlib-2.1.2.tgz";
        sha512 = "bAxsR8BVfj60DWXHE3u30oHzfl4G7khkSuPW+qvpd7jFRHm7dLxOjUk1EHACJ/hxLY8phGJ0YhYHZo7jil7Qdg==";
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "mkdirp"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "ms"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "negotiator"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "nopt"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "normalize-url"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "npm-package-arg"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/npm-package-arg/-/npm-package-arg-8.1.5.tgz";
        sha512 = "LhgZrg0n0VgvzVdSm1oiZworPbTxYHUJCgtsJW8mGvlDpxTM1vSJc3m5QZeUkhAHIzbz3VCHd/R4osi1L1Tg/Q==";
      };
    };
    "object-inspect-1.12.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "object-inspect";
      packageName = "object-inspect";
      version = "1.12.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "object-inspect"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "object-inspect"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/object-inspect/-/object-inspect-1.12.0.tgz";
        sha512 = "Ho2z80bVIvJloH+YzRmpZVQe87+qASmBUKZDWgx9cu+KDrX2ZDH/3tMy+gXbZETVGs2M8YdxObOh7XAtim9Y0g==";
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "once"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "once"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "optparse"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "os-homedir"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "os-tmpdir"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "osenv"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "p-map"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "parse-path"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "parse-url"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "path-is-absolute"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/path-is-absolute/-/path-is-absolute-1.0.1.tgz";
        sha1 = "174b9268735534ffbc7ace6bf53a5a9e1b5c5f5f";
      };
    };
    "picomatch-2.3.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "picomatch";
      packageName = "picomatch";
      version = "2.3.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "picomatch"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "picomatch"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/picomatch/-/picomatch-2.3.0.tgz";
        sha512 = "lY1Q/PiJGC2zOv/z391WOTD+Z02bCgsFfvxoXXf6h7kv9o+WmsmzYqrAwY63sNgOxE4xEdq0WyUnXfKeBrSvYw==";
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "promise-inflight"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "promise-retry"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "proto-list"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "protocols"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/protocols/-/protocols-1.4.8.tgz";
        sha512 = "IgjKyaUSjsROSO8/D49Ab7hP8mJgTYcqApOqdPhLoPxAplXmkp+zRvsrSQjFn5by0rhm4VH0GAUELIPpx7B1yg==";
      };
    };
    "qs-6.10.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "qs";
      packageName = "qs";
      version = "6.10.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "qs"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "qs"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/qs/-/qs-6.10.2.tgz";
        sha512 = "mSIdjzqznWgfd4pMii7sHtaYF8rx8861hBO80SraY5GT0XQibWZWJSid0avzHGkDIZLImux2S5mXO0Hfct2QCw==";
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "query-string"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/query-string/-/query-string-6.14.1.tgz";
        sha512 = "XDxAeVmpfu1/6IjyT/gXHOl+S0vQ9owggJ30hhWKdHAsNPOcasn5o9BW0eejZqL2e4vMjhAxoW3jVHcD6mbcYw==";
      };
    };
    "readable-stream-3.6.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "readable-stream";
      packageName = "readable-stream";
      version = "3.6.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "readable-stream"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "readable-stream"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/readable-stream/-/readable-stream-3.6.0.tgz";
        sha512 = "BViHy7LKeTz4oNnkcLJ+lVSL6vpiFeX6/d3oSH8zCW7UxP2onchk+vTGB143xuFjHS3deTgkKoXXymXqymiIdA==";
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "retry"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "rimraf"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/rimraf/-/rimraf-3.0.2.tgz";
        sha512 = "JZkJMZkAGFFPP2YqXZXPbMlMBgsxzE8ILs4lMIX/2o0L9UBw9O/Y3o6wFw/i9YLapcUJWwqbi3kdxIPdC62TIA==";
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "safe-buffer"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "semver"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "semver"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "set-blocking"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "side-channel"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/side-channel/-/side-channel-1.0.4.tgz";
        sha512 = "q5XPytqFEIKHkGdiMIrY10mvLRvnQh42/+GoBlFW3b2LXLE2xxJpZFdm94we0BaoV3RwJyGqg5wS7epxTv0Zvw==";
      };
    };
    "signal-exit-3.0.6" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "signal-exit";
      packageName = "signal-exit";
      version = "3.0.6";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "signal-exit"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "signal-exit"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/signal-exit/-/signal-exit-3.0.6.tgz";
        sha512 = "sDl4qMFpijcGw22U5w63KmD3cZJfBuFlVNbVMKje2keoKML7X2UzWbc4XrmEbDwg0NXJc3yv4/ox7b+JWb57kQ==";
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "slasp"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "smart-buffer"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "socks"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/socks/-/socks-2.6.1.tgz";
        sha512 = "kLQ9N5ucj8uIcxrDwjm0Jsqk06xdpBjGNQtpXy4Q8/QY2k+fY7nZH8CARy+hkbG+SGAovmzzuauCpBlb8FrnBA==";
      };
    };
    "socks-proxy-agent-6.1.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "socks-proxy-agent";
      packageName = "socks-proxy-agent";
      version = "6.1.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "socks-proxy-agent"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "socks-proxy-agent"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/socks-proxy-agent/-/socks-proxy-agent-6.1.1.tgz";
        sha512 = "t8J0kG3csjA4g6FTbsMOWws+7R7vuRC8aQ/wy3/1OWmsgwA68zs/+cExQ0koSitUDXqhufF/YJr9wtNMZHw5Ew==";
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "split-on-first"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "ssri"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "strict-uri-encode"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/strict-uri-encode/-/strict-uri-encode-2.0.0.tgz";
        sha1 = "b9c7330c7042862f6b142dc274bbcc5866ce3546";
      };
    };
    "string-width-4.2.3" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "string-width";
      packageName = "string-width";
      version = "4.2.3";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "string-width"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "string-width"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/string-width/-/string-width-4.2.3.tgz";
        sha512 = "wKyQRQpjJ0sIp62ErSZdGsjMJWsap5oRNihHhu6G7JVO/9jIB6UyevL+tXuOqrng8j/cxKTWyWUwvSTriiZz/g==";
      };
    };
    "string_decoder-1.3.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "string_decoder";
      packageName = "string_decoder";
      version = "1.3.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "string_decoder"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "string_decoder"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/string_decoder/-/string_decoder-1.3.0.tgz";
        sha512 = "hkRX8U1WjJFd8LsDJ2yQ/wWWxaopEsABU1XfkM8A+j0+85JAGppt16cr1Whg6KIbb4okU6Mql6BOj+uup/wKeA==";
      };
    };
    "strip-ansi-6.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "strip-ansi";
      packageName = "strip-ansi";
      version = "6.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "strip-ansi"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "strip-ansi"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/strip-ansi/-/strip-ansi-6.0.1.tgz";
        sha512 = "Y38VPSHcqkFrCpFnQ9vuSXmquuv5oXOKpGeT6aGrr3o3Gc9AlVa6JBfUSOCnbxGGZF+/0ooI7KrPuUSztUdU5A==";
      };
    };
    "tar-6.1.11" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "tar";
      packageName = "tar";
      version = "6.1.11";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "tar"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "tar"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/tar/-/tar-6.1.11.tgz";
        sha512 = "an/KZQzQUkZCkuoAA64hM92X0Urb6VpRhAFllDzz44U2mcD5scmT3zBc4VgVpkugF580+DQn8eAFSyoQt0tznA==";
      };
    };
    "to-regex-range-5.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "to-regex-range";
      packageName = "to-regex-range";
      version = "5.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "to-regex-range"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "to-regex-range"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/to-regex-range/-/to-regex-range-5.0.1.tgz";
        sha512 = "65P7iz6X5yEr1cwcgvQxbbIw7Uk3gOy5dIdtZ4rDveLqhrdJP+Li/Hx6tyK0NEb+2GCyneCMJiGqrADCSNk8sQ==";
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "uid-number"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "unique-filename"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "unique-slug"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "universalify"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "util-deprecate"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "validate-npm-package-name"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/validate-npm-package-name/-/validate-npm-package-name-3.0.0.tgz";
        sha1 = "5fa912d81eb7d0c74afc140de7317f0ca7df437e";
      };
    };
    "wide-align-1.1.5" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "wide-align";
      packageName = "wide-align";
      version = "1.1.5";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "wide-align"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "wide-align"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/wide-align/-/wide-align-1.1.5.tgz";
        sha512 = "eDMORYaPNZ4sQIuuYPDHdQvf4gyCF9rEEV/yPxGfwPkRodwEgiMUUXTx/dex+Me0wxx53S+NgUHaP7y3MGlDmg==";
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "wrappy"; };
      doCheck = false;
      doInstallCheck = false;
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
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "yallist"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/yallist/-/yallist-4.0.0.tgz";
        sha512 = "3wdGidZyq5PB084XLES5TpOSRA3wjXAlIWMhum2kRcv/41Sn2emQ0dycQW4uZXLejwKvg6EsvbdlVL+FYEct7A==";
      };
    };
  };
  jsnixDeps = {
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
      doFixup = false;
      doStrip = false;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "base64-js"; };
      buildScript = mkBuildScript { inherit dependencies; pkgName = "base64-js"; };
      buildPhase = ''
      source $unpackScriptPath 
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
      fixupPhase = "true";
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
      doFixup = false;
      doStrip = false;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "cachedir"; };
      buildScript = mkBuildScript { inherit dependencies; pkgName = "cachedir"; };
      buildPhase = ''
      source $unpackScriptPath 
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
      fixupPhase = "true";
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
      version = "8.3.0";
      src = fetchurl {
        url = "https://registry.npmjs.org/commander/-/commander-8.3.0.tgz";
        sha512 = "OkTL9umf+He2DZkUq8f8J9of7yL6RJKI24dVITBmNfZBmri9zYZQrKkuXiKhyfPSu8tUhnVBB1iKXevvnlR4Ww==";
      };
      buildInputs = [ nodejs python3 makeWrapper jq  ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "commander"; });
      doFixup = false;
      doStrip = false;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "commander"; };
      buildScript = mkBuildScript { inherit dependencies; pkgName = "commander"; };
      buildPhase = ''
      source $unpackScriptPath 
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
      fixupPhase = "true";
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
      doFixup = false;
      doStrip = false;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "findit"; };
      buildScript = mkBuildScript { inherit dependencies; pkgName = "findit"; };
      buildPhase = ''
      source $unpackScriptPath 
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
      fixupPhase = "true";
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "findit"; });
      meta = {
        description = "walk a directory tree recursively with events";
        license = "MIT";
        homepage = "https://github.com/substack/node-findit";
      };
    };
    fs-extra = let
      dependencies = [];
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
      doFixup = false;
      doStrip = false;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "fs-extra"; };
      buildScript = mkBuildScript { inherit dependencies; pkgName = "fs-extra"; };
      buildPhase = ''
      source $unpackScriptPath 
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
      fixupPhase = "true";
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "fs-extra"; });
      meta = {
        description = "fs-extra contains methods that aren't included in the vanilla Node.js fs package. Such as recursive mkdir, copy, and remove.";
        license = "MIT";
        homepage = "https://github.com/jprichardson/node-fs-extra";
      };
    };
    git-url-parse = let
      dependencies = [];
      extraDependencies = [] ++
            mkExtraDependencies
             (pkgs // { inherit jsnixDeps dependencies; })
             { pkgName = "git-url-parse"; };
    in
    stdenv.mkDerivation {
      inherit dependencies extraDependencies;
      name = "git-url-parse";
      packageName = "git-url-parse";
      version = "11.6.0";
      src = fetchurl {
        url = "https://registry.npmjs.org/git-url-parse/-/git-url-parse-11.6.0.tgz";
        sha512 = "WWUxvJs5HsyHL6L08wOusa/IXYtMuCAhrMmnTjQPpBU0TTHyDhnOATNH3xNQz7YOQUsqIIPTGr4xiVti1Hsk5g==";
      };
      buildInputs = [ nodejs python3 makeWrapper jq  ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "git-url-parse"; });
      doFixup = false;
      doStrip = false;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "git-url-parse"; };
      buildScript = mkBuildScript { inherit dependencies; pkgName = "git-url-parse"; };
      buildPhase = ''
      source $unpackScriptPath 
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
      fixupPhase = "true";
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "git-url-parse"; });
      meta = {
        description = "A high level git url parser for common git providers.";
        license = "MIT";
        homepage = "https://github.com/IonicaBizau/git-url-parse";
      };
    };
    micromatch = let
      dependencies = [];
      extraDependencies = [] ++
            mkExtraDependencies
             (pkgs // { inherit jsnixDeps dependencies; })
             { pkgName = "micromatch"; };
    in
    stdenv.mkDerivation {
      inherit dependencies extraDependencies;
      name = "micromatch";
      packageName = "micromatch";
      version = "4.0.4";
      src = fetchurl {
        url = "https://registry.npmjs.org/micromatch/-/micromatch-4.0.4.tgz";
        sha512 = "pRmzw/XUcwXGpD9aI9q/0XOwLNygjETJ8y0ao0wdqprrzDa4YnxLcz7fQRZr8voh8V10kGhABbNcHVk5wHgWwg==";
      };
      buildInputs = [ nodejs python3 makeWrapper jq  ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "micromatch"; });
      doFixup = false;
      doStrip = false;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "micromatch"; };
      buildScript = mkBuildScript { inherit dependencies; pkgName = "micromatch"; };
      buildPhase = ''
      source $unpackScriptPath 
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
      installScript = mkInstallScript { pkgName = "micromatch"; };
      installPhase = ''
      if [ -z "$preInstall" ]; then
        runHook preInstall
      fi
      source $installScriptPath
      if [ -z "$postInstall" ]; then
        runHook postInstall
      fi
    '';
      preInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preInstall"; pkgName = "micromatch"; });
      postInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postInstall"; pkgName = "micromatch"; });
      preBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preBuild"; pkgName = "micromatch"; });
      postBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postBuild"; pkgName = "micromatch"; });
      fixupPhase = "true";
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "micromatch"; });
      meta = {
        description = "Glob matching for javascript/node.js. A replacement and faster alternative to minimatch and multimatch.";
        license = "MIT";
        homepage = "https://github.com/micromatch/micromatch";
      };
    };
    nijs = let
      dependencies = [];
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
      doFixup = false;
      doStrip = false;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "nijs"; };
      buildScript = mkBuildScript { inherit dependencies; pkgName = "nijs"; };
      buildPhase = ''
      source $unpackScriptPath 
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
      fixupPhase = "true";
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "nijs"; });
      meta = {
        description = "An internal DSL for the Nix package manager in JavaScript";
        license = "MIT";
        homepage = "https://github.com/svanderburg/nijs#readme";
      };
    };
    npm-registry-fetch = let
      dependencies = [];
      extraDependencies = [] ++
            mkExtraDependencies
             (pkgs // { inherit jsnixDeps dependencies; })
             { pkgName = "npm-registry-fetch"; };
    in
    stdenv.mkDerivation {
      inherit dependencies extraDependencies;
      name = "npm-registry-fetch";
      packageName = "npm-registry-fetch";
      version = "12.0.0";
      src = fetchurl {
        url = "https://registry.npmjs.org/npm-registry-fetch/-/npm-registry-fetch-12.0.0.tgz";
        sha512 = "nd1I90UHoETjgWpo3GbcoM1l2S4JCUpzDcahU4x/GVCiDQ6yRiw2KyDoPVD8+MqODbPtWwHHGiyc4O5sgdEqPQ==";
      };
      buildInputs = [ nodejs python3 makeWrapper jq  ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "npm-registry-fetch"; });
      doFixup = false;
      doStrip = false;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "npm-registry-fetch"; };
      buildScript = mkBuildScript { inherit dependencies; pkgName = "npm-registry-fetch"; };
      buildPhase = ''
      source $unpackScriptPath 
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
      fixupPhase = "true";
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "npm-registry-fetch"; });
      meta = {
        description = "Fetch-based http client for use with npm registry APIs";
        license = "ISC";
        homepage = "https://github.com/npm/npm-registry-fetch#readme";
      };
    };
    npmconf = let
      dependencies = [];
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
      doFixup = false;
      doStrip = false;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "npmconf"; };
      buildScript = mkBuildScript { inherit dependencies; pkgName = "npmconf"; };
      buildPhase = ''
      source $unpackScriptPath 
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
      fixupPhase = "true";
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "npmconf"; });
      meta = {
        description = "The config module for npm circa npm@1 and npm@2";
        license = "ISC";
        homepage = "https://github.com/npm/npmconf#readme";
      };
    };
    npmlog = let
      dependencies = [];
      extraDependencies = [] ++
            mkExtraDependencies
             (pkgs // { inherit jsnixDeps dependencies; })
             { pkgName = "npmlog"; };
    in
    stdenv.mkDerivation {
      inherit dependencies extraDependencies;
      name = "npmlog";
      packageName = "npmlog";
      version = "6.0.0";
      src = fetchurl {
        url = "https://registry.npmjs.org/npmlog/-/npmlog-6.0.0.tgz";
        sha512 = "03ppFRGlsyUaQFbGC2C8QWJN/C/K7PsfyD9aQdhVKAQIH4sQBc8WASqFBP7O+Ut4d2oo5LoeoboB3cGdBZSp6Q==";
      };
      buildInputs = [ nodejs python3 makeWrapper jq  ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "npmlog"; });
      doFixup = false;
      doStrip = false;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "npmlog"; };
      buildScript = mkBuildScript { inherit dependencies; pkgName = "npmlog"; };
      buildPhase = ''
      source $unpackScriptPath 
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
      fixupPhase = "true";
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
      doFixup = false;
      doStrip = false;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "optparse"; };
      buildScript = mkBuildScript { inherit dependencies; pkgName = "optparse"; };
      buildPhase = ''
      source $unpackScriptPath 
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
      fixupPhase = "true";
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
      doFixup = false;
      doStrip = false;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "rambda"; };
      buildScript = mkBuildScript { inherit dependencies; pkgName = "rambda"; };
      buildPhase = ''
      source $unpackScriptPath 
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
      fixupPhase = "true";
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "rambda"; });
      meta = {
        description = "Lightweight and faster alternative to Ramda with included TS definitions";
        license = "MIT";
        homepage = "https://github.com/selfrefactor/rambda#readme";
      };
    };
    semver = let
      dependencies = [];
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
      doFixup = false;
      doStrip = false;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "semver"; };
      buildScript = mkBuildScript { inherit dependencies; pkgName = "semver"; };
      buildPhase = ''
      source $unpackScriptPath 
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
      fixupPhase = "true";
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
      version = "3.0.11";
      src = fetchurl {
        url = "https://registry.npmjs.org/spdx-license-ids/-/spdx-license-ids-3.0.11.tgz";
        sha512 = "Ctl2BrFiM0X3MANYgj3CkygxhRmr9mi6xhejbdO960nF6EDJApTYpn0BQnDKlnNBULKiCN1n3w9EBkHK8ZWg+g==";
      };
      buildInputs = [ nodejs python3 makeWrapper jq  ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "spdx-license-ids"; });
      doFixup = false;
      doStrip = false;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "spdx-license-ids"; };
      buildScript = mkBuildScript { inherit dependencies; pkgName = "spdx-license-ids"; };
      buildPhase = ''
      source $unpackScriptPath 
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
      fixupPhase = "true";
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "spdx-license-ids"; });
      meta = {
        description = "A list of SPDX license identifiers";
        license = "CC0-1.0";
        homepage = "https://github.com/jslicense/spdx-license-ids#readme";
      };
    };
    tar = let
      dependencies = [];
      extraDependencies = [] ++
            mkExtraDependencies
             (pkgs // { inherit jsnixDeps dependencies; })
             { pkgName = "tar"; };
    in
    stdenv.mkDerivation {
      inherit dependencies extraDependencies;
      name = "tar";
      packageName = "tar";
      version = "6.1.11";
      src = fetchurl {
        url = "https://registry.npmjs.org/tar/-/tar-6.1.11.tgz";
        sha512 = "an/KZQzQUkZCkuoAA64hM92X0Urb6VpRhAFllDzz44U2mcD5scmT3zBc4VgVpkugF580+DQn8eAFSyoQt0tznA==";
      };
      buildInputs = [ nodejs python3 makeWrapper jq  ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "tar"; });
      doFixup = false;
      doStrip = false;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "tar"; };
      buildScript = mkBuildScript { inherit dependencies; pkgName = "tar"; };
      buildPhase = ''
      source $unpackScriptPath 
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
      fixupPhase = "true";
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
      doFixup = false;
      doStrip = false;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "web-tree-sitter"; };
      buildScript = mkBuildScript { inherit dependencies; pkgName = "web-tree-sitter"; };
      buildPhase = ''
      source $unpackScriptPath 
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
      fixupPhase = "true";
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "web-tree-sitter"; });
      meta = {
        description = "Tree-sitter bindings for the web";
        license = "MIT";
        homepage = "https://github.com/tree-sitter/tree-sitter/tree/master/lib/binding_web";
      };
    };
  };
  dedupedDeps = {
    graceful-fs = sources."graceful-fs-4.2.8" {
      dependencies = [];
    };
    jsonfile = sources."jsonfile-6.1.0" {
      dependencies = [];
    };
    universalify = sources."universalify-2.0.0" {
      dependencies = [];
    };
    call-bind = sources."call-bind-1.0.2" {
      dependencies = [];
    };
    decode-uri-component = sources."decode-uri-component-0.2.0" {
      dependencies = [];
    };
    filter-obj = sources."filter-obj-1.1.0" {
      dependencies = [];
    };
    function-bind = sources."function-bind-1.1.1" {
      dependencies = [];
    };
    get-intrinsic = sources."get-intrinsic-1.1.1" {
      dependencies = [];
    };
    git-up = sources."git-up-4.0.5" {
      dependencies = [];
    };
    has = sources."has-1.0.3" {
      dependencies = [];
    };
    has-symbols = sources."has-symbols-1.0.2" {
      dependencies = [];
    };
    is-ssh = sources."is-ssh-1.3.3" {
      dependencies = [];
    };
    normalize-url = sources."normalize-url-6.1.0" {
      dependencies = [];
    };
    object-inspect = sources."object-inspect-1.12.0" {
      dependencies = [];
    };
    parse-path = sources."parse-path-4.0.3" {
      dependencies = [];
    };
    parse-url = sources."parse-url-6.0.0" {
      dependencies = [];
    };
    protocols = sources."protocols-1.4.8" {
      dependencies = [];
    };
    qs = sources."qs-6.10.2" {
      dependencies = [];
    };
    query-string = sources."query-string-6.14.1" {
      dependencies = [];
    };
    side-channel = sources."side-channel-1.0.4" {
      dependencies = [];
    };
    split-on-first = sources."split-on-first-1.1.0" {
      dependencies = [];
    };
    strict-uri-encode = sources."strict-uri-encode-2.0.0" {
      dependencies = [];
    };
    braces = sources."braces-3.0.2" {
      dependencies = [];
    };
    fill-range = sources."fill-range-7.0.1" {
      dependencies = [];
    };
    is-number = sources."is-number-7.0.0" {
      dependencies = [];
    };
    picomatch = sources."picomatch-2.3.0" {
      dependencies = [];
    };
    to-regex-range = sources."to-regex-range-5.0.1" {
      dependencies = [];
    };
    slasp = sources."slasp-0.0.4" {
      dependencies = [];
    };
    "@gar/promisify" = sources."@gar/promisify-1.1.2" {
      dependencies = [];
    };
    "@npmcli/fs" = sources."@npmcli/fs-1.1.0" {
      dependencies = [];
    };
    "@npmcli/move-file" = sources."@npmcli/move-file-1.1.2" {
      dependencies = [];
    };
    "@tootallnate/once" = sources."@tootallnate/once-1.1.2" {
      dependencies = [];
    };
    agent-base = sources."agent-base-6.0.2" {
      dependencies = [];
    };
    agentkeepalive = sources."agentkeepalive-4.1.4" {
      dependencies = [];
    };
    aggregate-error = sources."aggregate-error-3.1.0" {
      dependencies = [];
    };
    balanced-match = sources."balanced-match-1.0.2" {
      dependencies = [];
    };
    brace-expansion = sources."brace-expansion-1.1.11" {
      dependencies = [];
    };
    builtins = sources."builtins-1.0.3" {
      dependencies = [];
    };
    cacache = sources."cacache-15.3.0" {
      dependencies = [];
    };
    chownr = sources."chownr-2.0.0" {
      dependencies = [];
    };
    clean-stack = sources."clean-stack-2.2.0" {
      dependencies = [];
    };
    concat-map = sources."concat-map-0.0.1" {
      dependencies = [];
    };
    debug = sources."debug-4.3.3" {
      dependencies = [];
    };
    depd = sources."depd-1.1.2" {
      dependencies = [];
    };
    err-code = sources."err-code-2.0.3" {
      dependencies = [];
    };
    fs-minipass = sources."fs-minipass-2.1.0" {
      dependencies = [];
    };
    "fs.realpath" = sources."fs.realpath-1.0.0" {
      dependencies = [];
    };
    glob = sources."glob-7.2.0" {
      dependencies = [];
    };
    hosted-git-info = sources."hosted-git-info-4.0.2" {
      dependencies = [];
    };
    http-cache-semantics = sources."http-cache-semantics-4.1.0" {
      dependencies = [];
    };
    http-proxy-agent = sources."http-proxy-agent-4.0.1" {
      dependencies = [];
    };
    https-proxy-agent = sources."https-proxy-agent-5.0.0" {
      dependencies = [];
    };
    humanize-ms = sources."humanize-ms-1.2.1" {
      dependencies = [];
    };
    imurmurhash = sources."imurmurhash-0.1.4" {
      dependencies = [];
    };
    indent-string = sources."indent-string-4.0.0" {
      dependencies = [];
    };
    infer-owner = sources."infer-owner-1.0.4" {
      dependencies = [];
    };
    inflight = sources."inflight-1.0.6" {
      dependencies = [];
    };
    inherits = sources."inherits-2.0.4" {
      dependencies = [];
    };
    ip = sources."ip-1.1.5" {
      dependencies = [];
    };
    is-lambda = sources."is-lambda-1.0.1" {
      dependencies = [];
    };
    jsonparse = sources."jsonparse-1.3.1" {
      dependencies = [];
    };
    lru-cache = sources."lru-cache-6.0.0" {
      dependencies = [];
    };
    make-fetch-happen = sources."make-fetch-happen-9.1.0" {
      dependencies = [];
    };
    minimatch = sources."minimatch-3.0.4" {
      dependencies = [];
    };
    minipass-collect = sources."minipass-collect-1.0.2" {
      dependencies = [];
    };
    minipass-fetch = sources."minipass-fetch-1.4.1" {
      dependencies = [];
    };
    minipass-flush = sources."minipass-flush-1.0.5" {
      dependencies = [];
    };
    minipass-json-stream = sources."minipass-json-stream-1.0.1" {
      dependencies = [];
    };
    minipass-pipeline = sources."minipass-pipeline-1.2.4" {
      dependencies = [];
    };
    minipass-sized = sources."minipass-sized-1.0.3" {
      dependencies = [];
    };
    minizlib = sources."minizlib-2.1.2" {
      dependencies = [];
    };
    mkdirp = sources."mkdirp-1.0.4" {
      dependencies = [];
    };
    ms = sources."ms-2.1.2" {
      dependencies = [];
    };
    negotiator = sources."negotiator-0.6.2" {
      dependencies = [];
    };
    npm-package-arg = sources."npm-package-arg-8.1.5" {
      dependencies = [];
    };
    once = sources."once-1.4.0" {
      dependencies = [];
    };
    p-map = sources."p-map-4.0.0" {
      dependencies = [];
    };
    path-is-absolute = sources."path-is-absolute-1.0.1" {
      dependencies = [];
    };
    promise-inflight = sources."promise-inflight-1.0.1" {
      dependencies = [];
    };
    promise-retry = sources."promise-retry-2.0.1" {
      dependencies = [];
    };
    retry = sources."retry-0.12.0" {
      dependencies = [];
    };
    rimraf = sources."rimraf-3.0.2" {
      dependencies = [];
    };
    smart-buffer = sources."smart-buffer-4.2.0" {
      dependencies = [];
    };
    socks = sources."socks-2.6.1" {
      dependencies = [];
    };
    socks-proxy-agent = sources."socks-proxy-agent-6.1.1" {
      dependencies = [];
    };
    ssri = sources."ssri-8.0.1" {
      dependencies = [];
    };
    unique-filename = sources."unique-filename-1.1.1" {
      dependencies = [];
    };
    unique-slug = sources."unique-slug-2.0.2" {
      dependencies = [];
    };
    validate-npm-package-name = sources."validate-npm-package-name-3.0.0" {
      dependencies = [];
    };
    wrappy = sources."wrappy-1.0.2" {
      dependencies = [];
    };
    yallist = sources."yallist-4.0.0" {
      dependencies = [];
    };
    abbrev = sources."abbrev-1.1.1" {
      dependencies = [];
    };
    config-chain = sources."config-chain-1.1.13" {
      dependencies = [];
    };
    ini = sources."ini-1.3.8" {
      dependencies = [];
    };
    nopt = sources."nopt-3.0.6" {
      dependencies = [];
    };
    os-homedir = sources."os-homedir-1.0.2" {
      dependencies = [];
    };
    os-tmpdir = sources."os-tmpdir-1.0.2" {
      dependencies = [];
    };
    osenv = sources."osenv-0.1.5" {
      dependencies = [];
    };
    proto-list = sources."proto-list-1.2.4" {
      dependencies = [];
    };
    safe-buffer = sources."safe-buffer-5.2.1" {
      dependencies = [];
    };
    uid-number = sources."uid-number-0.0.5" {
      dependencies = [];
    };
    ansi-regex = sources."ansi-regex-5.0.1" {
      dependencies = [];
    };
    aproba = sources."aproba-2.0.0" {
      dependencies = [];
    };
    are-we-there-yet = sources."are-we-there-yet-2.0.0" {
      dependencies = [];
    };
    color-support = sources."color-support-1.1.3" {
      dependencies = [];
    };
    console-control-strings = sources."console-control-strings-1.1.0" {
      dependencies = [];
    };
    delegates = sources."delegates-1.0.0" {
      dependencies = [];
    };
    emoji-regex = sources."emoji-regex-8.0.0" {
      dependencies = [];
    };
    gauge = sources."gauge-4.0.0" {
      dependencies = [];
    };
    has-unicode = sources."has-unicode-2.0.1" {
      dependencies = [];
    };
    is-fullwidth-code-point = sources."is-fullwidth-code-point-3.0.0" {
      dependencies = [];
    };
    readable-stream = sources."readable-stream-3.6.0" {
      dependencies = [];
    };
    set-blocking = sources."set-blocking-2.0.0" {
      dependencies = [];
    };
    signal-exit = sources."signal-exit-3.0.6" {
      dependencies = [];
    };
    string-width = sources."string-width-4.2.3" {
      dependencies = [];
    };
    string_decoder = sources."string_decoder-1.3.0" {
      dependencies = [];
    };
    strip-ansi = sources."strip-ansi-6.0.1" {
      dependencies = [];
    };
    util-deprecate = sources."util-deprecate-1.0.2" {
      dependencies = [];
    };
    wide-align = sources."wide-align-1.1.5" {
      dependencies = [];
    };
    minipass = sources."minipass-3.1.6" {
      dependencies = [];
    };
  };
  isolateDeps = {};
in
jsnixDeps // (if builtins.hasAttr "packageDerivation" packageNix then {
  "${packageNix.name}" = jsnixDrvOverrides {
    inherit dedupedDeps jsnixDeps isolateDeps;
    drv_ = packageNix.packageDerivation;
  };
} else {})