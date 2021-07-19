import nijs from "nijs";
import { Package } from "./Package.mjs";
import { Sources } from "./sources/index.mjs";

// essential for developing local packages
const gitignoreSource = `
    (import (fetchFromGitHub {
      owner = "hercules-ci";
      repo = "gitignore.nix";
      rev = "211907489e9f198594c0eb0ca9256a1949c9d412";
      sha256 = "sha256-qHu3uZ/o9jBHiA3MEKHJ06k7w4heOhA+4HCSIvflRxo=";
    }) { inherit lib; }).gitignoreSource`;

const getNodeDep = `packageName: dependencies:
    (let depList = if ((builtins.typeOf dependencies) == "set")
                  then (builtins.attrValues dependencies)
                  else dependencies;
    in (builtins.head
        (builtins.filter (p: p.packageName == packageName) depList)))`;

const linkNodeModulesExpr = `{dependencies ? [], extraDependencies ? []}:
    (lib.lists.foldr (dep: acc:
      let pkgName = if (builtins.hasAttr "packageName" dep)
                    then dep.packageName else dep.name;
      in (acc + (lib.optionalString
      ((lib.findSingle (px: px.packageName == dep.packageName) "none" "found" extraDependencies) == "none")
      ''
      if [[ ! -f "node_modules/\${pkgName}" && \\
            ! -d "node_modules/\${pkgName}" && \\
            ! -L "node_modules/\${pkgName}" && \\
            ! -e "node_modules/\${pkgName}" ]]
     then
       mkdir -p "node_modules/\${pkgName}"
       ln -s "\${dep}/lib/node_modules/\${pkgName}"/* "node_modules/\${pkgName}"
       \${lib.optionalString (builtins.hasAttr "dependencies" dep)
         ''
         rm -rf "node_modules/\${pkgName}/node_modules"
         (cd node_modules/\${dep.packageName}; \${linkNodeModules { inherit (dep) dependencies; inherit extraDependencies;}})
         ''}
     fi
     '')))
     "" dependencies)`;

const copyNodeModulesExpr = `{dependencies ? [], extraDependencies ? []}:
    (lib.lists.foldr (dep: acc:
      let pkgName = if (builtins.hasAttr "packageName" dep)
                    then dep.packageName else dep.name;
      in (acc + (lib.optionalString
      ((lib.findSingle (px: px.packageName == dep.packageName) "none" "found" extraDependencies) == "none")
      ''
      if [[ ! -f "node_modules/\${pkgName}" && \\
            ! -d "node_modules/\${pkgName}" && \\
            ! -L "node_modules/\${pkgName}" && \\
            ! -e "node_modules/\${pkgName}" ]]
     then
       mkdir -p "node_modules/\${pkgName}"
       cp -rLT "\${dep}/lib/node_modules/\${pkgName}" "node_modules/\${pkgName}"
       chmod -R +rw "node_modules/\${pkgName}"
       \${lib.optionalString (builtins.hasAttr "dependencies" dep)
         "(cd node_modules/\${dep.packageName}; \${linkNodeModules { inherit (dep) dependencies; inherit extraDependencies; }})"}
     fi
     '')))
     "" dependencies)`;

const transitiveDepUnpackPhase = `{dependencies ? [], pkgName}: ''
     unpackFile "$src";
     # not ideal, but some perms are fubar
     chmod -R +777 . || true
     packageDir="$(find . -maxdepth 1 -type d | tail -1)"
     cd "$packageDir"
   ''`;

const transitiveDepInstallPhase = `{dependencies ? [], pkgName}: ''
    export packageDir="$(pwd)"
    mkdir -p $out/lib/node_modules/\${pkgName}
    cd $out/lib/node_modules/\${pkgName}
    cp -rfT "$packageDir" "$(pwd)"
    mkdir -p node_modules
    \${linkNodeModules { inherit dependencies; }} ''`;

const mkPhaseBan = new nijs.NixValue(`phaseName: usrDrv:
      if (builtins.hasAttr phaseName usrDrv) then
      throw "jsnix error: using \${phaseName} isn't supported at this time"
      else  ""`);

const mkPhase = new nijs.NixValue(`pkgs_: {phase, pkgName}:
     lib.optionalString ((builtins.hasAttr "\${pkgName}" packageNix.dependencies) &&
                         (builtins.typeOf packageNix.dependencies."\${pkgName}" == "set") &&
                         (builtins.hasAttr "\${phase}" packageNix.dependencies."\${pkgName}"))
      (if builtins.typeOf packageNix.dependencies."\${pkgName}"."\${phase}" == "string"
       then
         packageNix.dependencies."\${pkgName}"."\${phase}"
       else
         (packageNix.dependencies."\${pkgName}"."\${phase}" (pkgs_ // { inherit getNodeDep copyNodeModules linkNodeModules; })))`);

const mkExtraBuildInputs = new nijs.NixValue(`pkgs_: {pkgName}:
     lib.optionals ((builtins.hasAttr "\${pkgName}" packageNix.dependencies) &&
                    (builtins.typeOf packageNix.dependencies."\${pkgName}" == "set") &&
                    (builtins.hasAttr "extraBuildInputs" packageNix.dependencies."\${pkgName}"))
      (if builtins.typeOf packageNix.dependencies."\${pkgName}"."extraBuildInputs" == "list"
       then
         packageNix.dependencies."\${pkgName}"."extraBuildInputs"
       else
         (packageNix.dependencies."\${pkgName}"."extraBuildInputs" (pkgs_ // { inherit getNodeDep copyNodeModules linkNodeModules; })))`);

const mkExtraDependencies = new nijs.NixValue(`pkgs_: {pkgName}:
     lib.optionals ((builtins.hasAttr "\${pkgName}" packageNix.dependencies) &&
                    (builtins.typeOf packageNix.dependencies."\${pkgName}" == "set") &&
                    (builtins.hasAttr "extraDependencies" packageNix.dependencies."\${pkgName}"))
      (if builtins.typeOf packageNix.dependencies."\${pkgName}"."extraDependencies" == "list"
       then
         packageNix.dependencies."\${pkgName}"."extraDependencies"
       else
         (packageNix.dependencies."\${pkgName}"."extraDependencies" (pkgs_ // { inherit getNodeDep copyNodeModules linkNodeModules; })))`);

const mkUnpackScript = new nijs.NixValue(`{ dependencies ? [], extraDependencies ? [], pkgName }:
     let copyNodeDependencies =
       if ((builtins.hasAttr "\${pkgName}" packageNix.dependencies) &&
           (builtins.typeOf packageNix.dependencies."\${pkgName}" == "set") &&
           (builtins.hasAttr "copyNodeDependencies" packageNix.dependencies."\${pkgName}") &&
           (builtins.typeOf packageNix.dependencies."\${pkgName}"."copyNodeDependencies" == "bool") &&
           (packageNix.dependencies."\${pkgName}"."copyNodeDependencies" == true))
       then true else false;
     in ''
      \${(if copyNodeDependencies then copyNodeModules else linkNodeModules) { inherit dependencies extraDependencies; }}
      chmod -R +rw $(pwd)
    ''`);

const mkConfigureScript = new nijs.NixValue(`{}: ''
    \${flattenScript}
''`);

const mkBuildScript = new nijs.NixValue(`{ dependencies ? [], pkgName }:
    let extraNpmFlags =
      if ((builtins.hasAttr "\${pkgName}" packageNix.dependencies) &&
          (builtins.typeOf packageNix.dependencies."\${pkgName}" == "set") &&
          (builtins.hasAttr "npmFlags" packageNix.dependencies."\${pkgName}") &&
          (builtins.typeOf packageNix.dependencies."\${pkgName}"."npmFlags" == "string"))
      then packageNix.dependencies."\${pkgName}"."npmFlags" else "";
    in ''
      runHook preBuild
      export HOME=$TMPDIR
      NODE_PATH="$(pwd)/node_modules:$NODE_PATH" \\
      npm --offline --no-bin-links --nodedir=\${nodeSources} \\
          \${extraNpmFlags} "--production" "--preserve-symlinks" \\
          rebuild
      runHook postBuild
    ''`);

const mkInstallScript = new nijs.NixValue(`{ pkgName }: ''
      runHook preInstall
      export packageDir="$(pwd)"
      mkdir -p $dev/lib/node_modules/\${pkgName}
      mkdir -p $out/lib/node_modules/\${pkgName}
      cd $dev/lib/node_modules/\${pkgName}
      cp -rfT "$packageDir" "$(pwd)"
      if [[ -d "$dev/lib/node_modules/\${pkgName}/bin" ]]
      then
         mkdir -p $dev/bin
         ln -s "$dev/lib/node_modules/\${pkgName}/bin"/* $dev/bin
      fi
      cd $out/lib/node_modules/\${pkgName}
      cp -rfT "$packageDir" "$(pwd)"
      cat package.json | jq ".peerDependencies // {} | keys" | sed -n 's/.*"\\(.*\\)".*/\\1/p' | while read peerDep; do
        rm -rf node_modules/"$peerDep"
      done
      cat package.json | jq ".devDependencies // {} | keys" | sed -n 's/.*"\\(.*\\)".*/\\1/p' | while read devDep; do
        rm -rf node_modules/"$devDep"
      done
      runHook postInstall
    ''`);

const nodeSources = new nijs.NixValue(`runCommand "node-sources" {} ''
    tar --no-same-owner --no-same-permissions -xf \${nodejs.src}
    mv node-* $out
  ''`);

const goFlatten = new nijs.NixValue(`pkgs.buildGoModule {
  pname = "flatten";
  version = "0.0.0";
  vendorSha256 = null;
  src = pkgs.fetchFromGitHub {
    owner = "hlolli";
    repo = "jsnix";
    rev = "a79fa8510106b692a07d79d58f65077eccc74e6c";
    sha256 = "sha256-gEe06QXUAnCsUu0wgGZpw8oCcMPhwbBzTdxJp50yODI=";
  };
  preBuild = ''
    cd go
  '';
}`);

// const goFlatten = new nijs.NixValue(`pkgs.buildGoModule {
//   pname = "flatten";
//   version = "0.0.0";
//   vendorSha256 = null;
//   src = /Users/hlodversigurdsson/forks/jsnix/go;
//   preBuild = ''
//     ls
//     mkdir -p go
//     mv flatten* go
//     chmod -R +rw .
//     mv vendor go
//     mv go.mod go
//     mkdir -p .git
//     cd go
//   '';
// }`);

const sanitizeName = new nijs.NixValue(`nm: lib.strings.sanitizeDerivationName
    (builtins.replaceStrings [ "@" "/" ] [ "_at_" "_" ] nm)`);

const flattenScript = new nijs.NixValue(`''
    \${goFlatten}/bin/flatten
''`);

const toPackageJson = new nijs.NixValue(`{ jsnixDeps ? {} }:
    let
      main = if (builtins.hasAttr "main" packageNix) then packageNix else throw "package.nix is missing main attribute";
      pkgName = if (builtins.hasAttr "packageName" packageNix)
                then packageNix.packageName else packageNix.name;
      packageNixDeps = if (builtins.hasAttr "dependencies" packageNix)
                       then packageNix.dependencies
                       else {};
      prodDeps = lib.lists.foldr
        (depName: acc: acc // {
          "\${depName}" = (if ((builtins.typeOf packageNixDeps."\${depName}") == "string")
                          then packageNixDeps."\${depName}"
                          else
                            if (((builtins.typeOf packageNixDeps."\${depName}") == "set") &&
                                ((builtins.typeOf packageNixDeps."\${depName}".version) == "string"))
                          then packageNixDeps."\${depName}".version
                          else "latest");}) {} (builtins.attrNames packageNixDeps);
      safePkgNix = lib.lists.foldr (key: acc:
        if ((builtins.typeOf packageNix."\${key}") != "lambda")
        then (acc // { "\${key}" =  packageNix."\${key}"; })
        else acc)
        {} (builtins.attrNames packageNix);
    in lib.strings.escapeNixString
      (builtins.toJSON (safePkgNix // { dependencies = prodDeps; name = pkgName; }))`);

const jsnixDrvOverrides = new nijs.NixValue(`{ drv, jsnixDeps ? {} }:
    let skipUnpackFor = if (builtins.hasAttr "skipUnpackFor" drv)
                        then drv.skipUnpackFor else [];
        copyUnpackFor = if (builtins.hasAttr "copyUnpackFor" drv)
                        then drv.copyUnpackFor else [];
        linkDeps = (builtins.filter
                                (p: (((lib.findSingle (px: px == p.packageName) "none" "found" skipUnpackFor) == "none") &&
                                      (lib.findSingle (px: px == p.packageName) "none" "found" copyUnpackFor) == "none"))
                              (builtins.map
                              (dep: jsnixDeps."\${dep}")
                              (builtins.attrNames packageNix.dependencies)));
         copyDeps = (builtins.filter
                                (p: (((lib.findSingle (px: px == p.packageName) "none" "found" skipUnpackFor) == "none") &&
                                      (lib.findSingle (px: px == p.packageName) "none" "found" copyUnpackFor) == "found"))
                                (builtins.map
                                    (dep: jsnixDeps."\${dep}")
                                    (builtins.attrNames packageNix.dependencies)));
         extraLinkDeps = (builtins.filter
                                (p: (((lib.findSingle (px: px == p.packageName) "none" "found" skipUnpackFor) == "none") &&
                                      (lib.findSingle (px: px == p.packageName) "none" "found" copyUnpackFor) == "none"))
                                (if (builtins.hasAttr "extraDependencies" drv) then drv.extraDependencies else []));
         extraCopyDeps = (builtins.filter
                                (p: (((lib.findSingle (px: px == p.packageName) "none" "found" skipUnpackFor) == "none") &&
                                      (lib.findSingle (px: px == p.packageName) "none" "found" copyUnpackFor) == "found"))
                                (if (builtins.hasAttr "extraDependencies" drv) then drv.extraDependencies else []));
         nodeModules = runCommand "\${sanitizeName packageNix.name}_node_modules" { buildInputs = [ nodejs ripgrep ]; } ''
           echo 'unpack, dedupe and flatten dependencies...'
           mkdir -p $out/lib/node_modules
           cd $out/lib
           \${linkNodeModules {
                dependencies = extraLinkDeps;
           }}
           \${copyNodeModules {
                dependencies = extraCopyDeps;
           }}
           \${linkNodeModules {
                dependencies = linkDeps;
                extraDependencies = (lib.optionals (builtins.hasAttr "extraDependencies" drv) drv.extraDependencies);
           }}
           \${copyNodeModules {
                dependencies = copyDeps;
                extraDependencies = (lib.optionals (builtins.hasAttr "extraDependencies" drv) drv.extraDependencies);
           }}
           chmod -R +rw node_modules
           \${flattenScript}
        '';
    in stdenv.mkDerivation (drv // {
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
      dontStrip = true;
      doUnpack = true;
      NODE_OPTIONS = "--preserve-symlinks";
      buildInputs = [ nodejs ] ++ lib.optionals (builtins.hasAttr "buildInputs" drv) drv.buildInputs;
      passAsFile = [ "unpackFlattenDedupe" ];

      unpackFlattenDedupe = ''
        mkdir -p node_modules
        chmod -R +rw node_modules
        cp -rfT \${nodeModules}/lib/node_modules node_modules
        export NODE_PATH="$(pwd)/node_modules:$NODE_PATH"
        export NODE_OPTIONS="--preserve-symlinks"
      '';
      configurePhase = ''
        source $unpackFlattenDedupePath
      '';
      buildPhase = ''
        runHook preBuild
       \${lib.optionalString (builtins.hasAttr "buildPhase" drv) drv.buildPhase}
       runHook postBuild
      '';
      installPhase = if (builtins.hasAttr "installPhase" drv) then
        ''
          runHook preInstall
            \${drv.installPhase}
          runHook postInstall
        '' else ''
          runHook preInstall
          if [[ -d "./bin" ]]
          then
            mkdir $out/bin
            ln -s ./bin/* $out/bin
          fi
          mkdir -p $out/lib/node_modules/\${packageNix.name}
          cp -rfL ./ $out/lib/node_modules/\${packageNix.name}
          runHook postInstall
       '';
  })`);

class OutputExpression extends nijs.NixASTNode {
  constructor() {
    super();
    this.sourcesCache = new Sources();
  }
  resolveDependencies(callback) {
    callback(
      "resolveDependencies() is unimplemented. Please use a prototype that inherits from OutputExpression!"
    );
  }
  toNixAST() {
    return new nijs.NixFunction({
      argSpec: {
        pkgs: undefined,
        stdenv: undefined,
        lib: undefined,
        nodejs: undefined,
        fetchurl: undefined,
        fetchgit: undefined,
        fetchFromGitHub: undefined,
        jq: undefined,
        makeWrapper: undefined,
        python3: undefined,
        ripgrep: undefined,
        runCommand: undefined,
        xcodebuild: undefined,
        "... ": undefined,
        // nodeEnv: undefined,
        // "nix-gitignore": undefined,
        // globalBuildInputs: [],
      },
      body: new nijs.NixLet({
        value: {
          packageNix: new nijs.NixImport(
            new nijs.NixFile({ value: "./package.nix" })
          ),
          linkNodeModules: new nijs.NixValue(linkNodeModulesExpr),
          copyNodeModules: new nijs.NixValue(copyNodeModulesExpr),
          gitignoreSource: new nijs.NixValue(gitignoreSource),
          transitiveDepInstallPhase: new nijs.NixValue(
            transitiveDepInstallPhase
          ),
          transitiveDepUnpackPhase: new nijs.NixValue(transitiveDepUnpackPhase),
          getNodeDep: new nijs.NixValue(getNodeDep),
          nodeSources,
          flattenScript,
          sanitizeName,
          jsnixDrvOverrides,
          toPackageJson,
          mkPhaseBan,
          mkPhase,
          mkExtraBuildInputs,
          mkExtraDependencies,
          mkUnpackScript,
          mkConfigureScript,
          mkBuildScript,
          mkInstallScript,
          goFlatten,
          sources: this.sourcesCache,
        },
      }),
    });
  }
}

export class NixExpression extends OutputExpression {
  constructor(jsnixConfig, baseDir, dependencies) {
    super(jsnixConfig);
    this.packages = {};
    this.jsnixConfig = jsnixConfig;

    if (Array.isArray(dependencies)) {
      for (const dependenySpec of dependencies) {
        const dependency =
          typeof dependencySpec == "string"
            ? { [dependenySpec]: "latest" }
            : dependenySpec;
        for (const dependencyName in dependency) {
          const versionSpec = dependency[dependencyName];

          const identifier =
            versionSpec == "*" || versionSpec == "latest"
              ? (identifier = dependencyName)
              : (identifier = dependencyName + "-" + versionSpec);

          this.packages[identifier] = new Package(
            jsnixConfig,
            undefined,
            dependencyName,
            versionSpec,
            baseDir,
            this.sourcesCache,
            false
          );
        }
      }
    } else if (dependencies && dependencies instanceof Object) {
      for (const dependencyName in dependencies) {
        const depData = dependencies[dependencyName];
        const version =
          (typeof depData === "string" ? depData : depData["version"]) ||
          "latest";
        this.packages[dependencyName] = new Package(
          jsnixConfig,
          undefined,
          dependencyName,
          version,
          baseDir,
          this.sourcesCache,
          false
        );
      }
    } else {
      throw new Error(
        `Don't know what to do with \n${JSON.stringify(
          dependencies,
          undefined,
          2
        )}`
      );
      process.exit(1);
    }
  }

  async resolveDependencies(callback) {
    for (const pkgName in this.packages) {
      await this.packages[pkgName].source.fetch();
      await this.packages[pkgName].resolveDependencies();
    }
  }

  toNixAST() {
    const ast = super.toNixAST.call(this);

    // Generate sub expression for all the packages in the collection
    const packagesExpr = {};

    for (const identifier in this.packages) {
      const pkg = this.packages[identifier];
      packagesExpr[identifier] = new nijs.NixLet({
        value: {
          dependencies: pkg.generateDependencyAST(),
          extraDependencies: new nijs.NixValue(`[] ++
        mkExtraDependencies
           (pkgs // { inherit jsnixDeps dependencies; })
            { pkgName = "${pkg.name}"; }`),
        },
        body: new nijs.NixFunInvocation({
          funExpr: new nijs.NixExpression("stdenv.mkDerivation"),
          paramExpr: pkg,
        }),
      });
    }
    ast.body.value.jsnixDeps = new nijs.NixMergeAttrs({
      left: new nijs.NixExpression("sources"),
      right: packagesExpr,
    });

    ast.body.body = new nijs.NixMergeAttrs({
      left: new nijs.NixExpression("jsnixDeps"),
      right: new nijs.NixIf({
        ifExpr: new nijs.NixFunInvocation({
          funExpr: new nijs.NixExpression("builtins.hasAttr"),
          paramExpr: new nijs.NixExpression('"packageDerivation" packageNix'),
        }),
        thenExpr: {
          "${packageNix.name}": new nijs.NixFunInvocation({
            funExpr: new nijs.NixExpression("jsnixDrvOverrides"),
            paramExpr: {
              jsnixDeps: new nijs.NixInherit(),
              drv: new nijs.NixFunInvocation({
                funExpr: new nijs.NixExpression("packageNix.packageDerivation"),
                paramExpr: new nijs.NixMergeAttrs({
                  left: new nijs.NixExpression("pkgs"),
                  right: {
                    nodejs: new nijs.NixInherit(),
                    copyNodeModules: new nijs.NixInherit(),
                    linkNodeModules: new nijs.NixInherit(),
                    gitignoreSource: new nijs.NixInherit(),
                    jsnixDeps: new nijs.NixInherit(),
                    getNodeDep: new nijs.NixInherit(),
                  },
                }),
              }),
            },
          }),
        },

        elseExpr: {},
      }),
    });

    return ast;
  }
}
