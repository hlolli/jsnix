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
  jsnixDrvOverrides = { drv_, jsnixDeps}:
    let drv = drv_ (pkgs // { inherit nodejs copyNodeModules gitignoreSource jsnixDeps nodeModules getNodeDep; });
        skipUnpackFor = if (builtins.hasAttr "skipUnpackFor" drv)
                        then drv.skipUnpackFor else [];
        copyUnpackFor = if (builtins.hasAttr "copyUnpackFor" drv)
                        then drv.copyUnpackFor else [];
        pkgJsonFile = runCommand "package.json" { buildInputs = [jq]; } ''
          echo ${toPackageJson { inherit jsnixDeps; extraDeps = (if (builtins.hasAttr "extraDependencies" drv) then drv.extraDependencies else []); }} > $out
          cat <<< $(cat $out | jq) > $out
        '';
         copyDeps = (builtins.map
                      (dep: jsnixDeps."${dep}")
                      (builtins.attrNames packageNix.dependencies));
         copyDepsStr = builtins.concatStringsSep " " (builtins.map (dep: if (builtins.hasAttr "packageName" dep) then dep.packageName else dep.name) copyDeps);
         extraDepsStr = builtins.concatStringsSep " " (builtins.map (dep: if (builtins.hasAttr "packageName" dep) then dep.packageName else dep.name)
                                                        (lib.optionals (builtins.hasAttr "extraDependencies" drv) drv.extraDependencies));
         buildDepDep = lib.lists.unique (lib.lists.concatMap (d: d.buildInputs)
                        (copyDeps ++ (lib.optionals (builtins.hasAttr "extraDependencies" drv) drv.extraDependencies)));
         nodeModules = runCommandCC "${sanitizeName packageNix.name}_node_modules"
           { buildInputs = buildDepDep;
             fixupPhase = "true";
             doCheck = false;
             doInstallCheck = false;
             version = builtins.hashString "sha512" (lib.strings.concatStrings copyDeps); }
         ''
           echo 'unpack, dedupe and flatten dependencies...'
           mkdir -p $out/lib/node_modules
           cd $out/lib
           ${copyNodeModules {
                dependencies = copyDeps;
           }}
           chmod -R +rw node_modules
           ${flattenScript copyDepsStr}
           ${copyNodeModules {
                dependencies = (lib.optionals (builtins.hasAttr "extraDependencies" drv) drv.extraDependencies);
           }}
           ${flattenScript extraDepsStr}
           ${lib.optionalString (builtins.hasAttr "nodeModulesUnpack" drv) drv.nodeModulesUnpack}
           echo 'fixup and link bin...'
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
         (packageNix.dependencies."${pkgName}"."${phase}" (pkgs_ // { inherit getNodeDep copyNodeModules; })));
  mkExtraBuildInputs = pkgs_: {pkgName}:
     lib.optionals ((builtins.hasAttr "${pkgName}" packageNix.dependencies) &&
                    (builtins.typeOf packageNix.dependencies."${pkgName}" == "set") &&
                    (builtins.hasAttr "extraBuildInputs" packageNix.dependencies."${pkgName}"))
      (if builtins.typeOf packageNix.dependencies."${pkgName}"."extraBuildInputs" == "list"
       then
         packageNix.dependencies."${pkgName}"."extraBuildInputs"
       else
         (packageNix.dependencies."${pkgName}"."extraBuildInputs" (pkgs_ // { inherit getNodeDep copyNodeModules; })));
  mkExtraDependencies = pkgs_: {pkgName}:
     lib.optionals ((builtins.hasAttr "${pkgName}" packageNix.dependencies) &&
                    (builtins.typeOf packageNix.dependencies."${pkgName}" == "set") &&
                    (builtins.hasAttr "extraDependencies" packageNix.dependencies."${pkgName}"))
      (if builtins.typeOf packageNix.dependencies."${pkgName}"."extraDependencies" == "list"
       then
         packageNix.dependencies."${pkgName}"."extraDependencies"
       else
         (packageNix.dependencies."${pkgName}"."extraDependencies" (pkgs_ // { inherit getNodeDep copyNodeModules; })));
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
  goFlatten = pkgs.buildGoModule {
  pname = "flatten";
  version = "0.0.0";
  vendorSha256 = null;
  src = pkgs.fetchFromGitHub {
    owner = "hlolli";
    repo = "jsnix";
    rev = "3ab0e891b6957fdab7d1ae8ceef482c8f5bebee8";
    sha256 = "SAl2B1S71bvUSraFMgDrPCx4c3cF9RAl0duspjgqz+4=";
  };
  preBuild = ''
    cd go/flatten
  '';
};
  goBinLink = pkgs.buildGoModule {
  pname = "bin-link";
  version = "0.0.0";
  vendorSha256 = null;
  src = pkgs.fetchFromGitHub {
    owner = "hlolli";
    repo = "jsnix";
    rev = "5408f77872b7a1b9f865c1c68ea104cd95441743";
    sha256 = "inUZm4XTqeeDDXIA8qMcvuqWlStJWoGvXv/BCD3gYEs=";
  };
  preBuild = ''
    cd go/bin-link
  '';
};
  sources = rec {};
  jsnixDeps = sources // {
    hello-world-npm = let
      dependencies = [];
      extraDependencies = [] ++
        mkExtraDependencies
           (pkgs // { inherit jsnixDeps dependencies; })
            { pkgName = "hello-world-npm"; };
    in
    stdenv.mkDerivation {
      inherit dependencies extraDependencies;
      name = "hello-world-npm";
      packageName = "hello-world-npm";
      version = "1.1.1";
      src = fetchurl {
        url = "https://registry.npmjs.org/hello-world-npm/-/hello-world-npm-1.1.1.tgz";
        sha1 = "250830ef0008b437ed93e6be599934b9ad0b9308";
      };
      buildInputs = [ nodejs python3 makeWrapper jq  ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "hello-world-npm"; });
      doFixup = false;
      doStrip = false;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "hello-world-npm"; };
      buildScript = mkBuildScript { inherit dependencies; pkgName = "hello-world-npm"; };
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
      installScript = mkInstallScript { pkgName = "hello-world-npm"; };
      installPhase = ''
      if [ -z "$preInstall" ]; then
        runHook preInstall
      fi
      source $installScriptPath
      if [ -z "$postInstall" ]; then
        runHook postInstall
      fi
    '';
      preInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preInstall"; pkgName = "hello-world-npm"; });
      postInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postInstall"; pkgName = "hello-world-npm"; });
      preBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preBuild"; pkgName = "hello-world-npm"; });
      postBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postBuild"; pkgName = "hello-world-npm"; });
      fixupPhase = "true";
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "hello-world-npm"; });
      meta = {
        description = "Hello World NPM example";
        license = "MIT";
        homepage = "https://github.com/rms1000watt/hello-world-npm#readme";
      };
    };
  };
in
jsnixDeps // (if builtins.hasAttr "packageDerivation" packageNix then {
  "${packageNix.name}" = jsnixDrvOverrides {
    inherit jsnixDeps;
    drv_ = packageNix.packageDerivation;
  };
} else {})