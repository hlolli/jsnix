import nijs from "nijs";
import semverMajor from "semver/functions/major.js";
import semverSort from "semver/functions/sort.js";
import semverSatisfies from "semver/functions/satisfies.js";
import * as R from "rambda";
import { Package } from "./Package.mjs";
import { Sources } from "./sources/index.mjs";

// essential for developing local packages
const gitignoreSource = `
    (import (fetchFromGitHub {
      owner = "hercules-ci";
      repo = "gitignore.nix";
      rev = "5b9e0ff9d3b551234b4f3eb3983744fa354b17f1";
      sha256 = "o/BdVjNwcB6jOmzZjOH703BesSkkS5O7ej3xhyO8hAY=";
    }) { inherit lib; }).gitignoreSource`;

const getNodeDep = `packageName: dependencies:
    (let depList = if ((builtins.typeOf dependencies) == "set")
                  then (builtins.attrValues dependencies)
                  else dependencies;
    in (builtins.head
        (builtins.filter (p: p.packageName == packageName) depList)))`;

const copyNodeModulesExpr = `{dependencies ? [] }:
    (lib.lists.foldr (dep: acc:
      let pkgName = if (builtins.hasAttr "packageName" dep)
                    then dep.packageName else dep.name;
      in
      acc + ''
      if [[ ! -f "node_modules/\${pkgName}" && \\
            ! -d "node_modules/\${pkgName}" && \\
            ! -L "node_modules/\${pkgName}" && \\
            ! -e "node_modules/\${pkgName}" ]]
     then
       mkdir -p "node_modules/\${pkgName}"
       cp -rLT "\${dep}/lib/node_modules/\${pkgName}" "node_modules/\${pkgName}"
       chmod -R +rw "node_modules/\${pkgName}"
     fi
     '')
     "" dependencies)`;

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

// \${lib.optionalString (builtins.hasAttr "dependencies" dep)
//   "(cd node_modules/\${pkgName}; \${copyNodeModules { inherit (dep) dependencies; }})"}

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
    \${copyNodeModules { inherit dependencies; }} ''`;

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
         (packageNix.dependencies."\${pkgName}"."\${phase}" (pkgs_ // { inherit getNodeDep copyNodeModules; })))`);

const mkExtraBuildInputs = new nijs.NixValue(`pkgs_: {pkgName}:
     lib.optionals ((builtins.hasAttr "\${pkgName}" packageNix.dependencies) &&
                    (builtins.typeOf packageNix.dependencies."\${pkgName}" == "set") &&
                    (builtins.hasAttr "extraBuildInputs" packageNix.dependencies."\${pkgName}"))
      (if builtins.typeOf packageNix.dependencies."\${pkgName}"."extraBuildInputs" == "list"
       then
         packageNix.dependencies."\${pkgName}"."extraBuildInputs"
       else
         (packageNix.dependencies."\${pkgName}"."extraBuildInputs" (pkgs_ // { inherit getNodeDep copyNodeModules; })))`);

const mkExtraDependencies = new nijs.NixValue(`pkgs_: {pkgName}:
     lib.optionals ((builtins.hasAttr "\${pkgName}" packageNix.dependencies) &&
                    (builtins.typeOf packageNix.dependencies."\${pkgName}" == "set") &&
                    (builtins.hasAttr "extraDependencies" packageNix.dependencies."\${pkgName}"))
      (if builtins.typeOf packageNix.dependencies."\${pkgName}"."extraDependencies" == "list"
       then
         packageNix.dependencies."\${pkgName}"."extraDependencies"
       else
         (packageNix.dependencies."\${pkgName}"."extraDependencies" (pkgs_ // { inherit getNodeDep copyNodeModules; })))`);

const mkUnpackScript =
  new nijs.NixValue(`{ dependencies ? [], extraDependencies ? [], pkgName }:
     let copyNodeDependencies =
       if ((builtins.hasAttr "\${pkgName}" packageNix.dependencies) &&
           (builtins.typeOf packageNix.dependencies."\${pkgName}" == "set") &&
           (builtins.hasAttr "copyNodeDependencies" packageNix.dependencies."\${pkgName}") &&
           (builtins.typeOf packageNix.dependencies."\${pkgName}"."copyNodeDependencies" == "bool") &&
           (packageNix.dependencies."\${pkgName}"."copyNodeDependencies" == true))
       then true else false;
     in ''
      \${copyNodeModules { dependencies = dependencies ++ extraDependencies; }}
      chmod -R +rw $(pwd)
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
      npm --offline config set node_gyp \${nodejs}/lib/node_modules/npm/node_modules/node-gyp/bin/node-gyp.js
      npm --offline config set omit dev
      NODE_PATH="$(pwd)/node_modules:$NODE_PATH" \\
      npm --offline --nodedir=\${nodeSources} --location="$(pwd)" \\
          \${extraNpmFlags} "--production" "--preserve-symlinks" \\
          rebuild --build-from-source
      runHook postBuild
    ''`);

const mkInstallScript = new nijs.NixValue(`{ pkgName }: ''
      runHook preInstall
      export packageDir="$(pwd)"
      mkdir -p $out/lib/node_modules/\${pkgName}
      cd $out/lib/node_modules/\${pkgName}
      cp -rfT "$packageDir" "$(pwd)"
      if [[ -d "$out/lib/node_modules/\${pkgName}/bin" ]]
      then
         mkdir -p $out/bin
         ln -s "$out/lib/node_modules/\${pkgName}/bin"/* $out/bin
      fi
      cd $out/lib/node_modules/\${pkgName}
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
}`);

const goBinLink = new nijs.NixValue(`pkgs.buildGoModule {
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
}`);

// const goBinLink = new nijs.NixValue(`pkgs.buildGoModule {
//   pname = "bin-link";
//   version = "0.0.1";
//   vendorSha256 = null;
//   src = /Users/hlodversigurdsson/forks/jsnix/go/bin-link;
//   preBuild = ''
//     ls
//     mkdir -p go
//     mv bin* go
//     chmod -R +rw .
//     mv vendor go
//     mv go.mod go
//     mkdir -p .git
//     cd go
//   '';
// }`);

// const goFlatten = new nijs.NixValue(`pkgs.buildGoModule {
//   pname = "flatten";
//   version = "0.0.0";
//   vendorSha256 = null;
//   src = /Users/hlodversigurdsson/forks/jsnix/go/flatten;
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

const linkBins = new nijs.NixValue(`''
    \${goBinLink}/bin/bin-link
''`);

const flattenScript = new nijs.NixValue(
  `args: '' \${goFlatten}/bin/flatten \${args}''`
);

const toPackageJson = new nijs.NixValue(`{ jsnixDeps ? {}, extraDeps ? [] }:
    let
      main = if (builtins.hasAttr "main" packageNix) then packageNix else throw "package.nix is missing main attribute";
      pkgName = if (builtins.hasAttr "packageName" packageNix)
                then packageNix.packageName else packageNix.name;
      packageNixDeps = if (builtins.hasAttr "dependencies" packageNix)
                       then packageNix.dependencies
                       else {};
      extraDeps_ = lib.lists.foldr (dep: acc: { "\${dep.packageName}" = dep; } // acc) {} extraDeps;
      allDeps = extraDeps_ // packageNixDeps;
      prodDeps = lib.lists.foldr
        (depName: acc: acc // {
          "\${depName}" = (if ((builtins.typeOf allDeps."\${depName}") == "string")
                          then allDeps."\${depName}"
                          else
                            if (((builtins.typeOf allDeps."\${depName}") == "set") &&
                                ((builtins.typeOf allDeps."\${depName}".version) == "string"))
                          then allDeps."\${depName}".version
                          else "latest");}) {} (builtins.attrNames allDeps);
      safePkgNix = lib.lists.foldr (key: acc:
        if ((builtins.typeOf packageNix."\${key}") != "lambda")
        then (acc // { "\${key}" =  packageNix."\${key}"; })
        else acc)
        {} (builtins.attrNames packageNix);
    in lib.strings.escapeNixString
      (builtins.toJSON (safePkgNix // { dependencies = prodDeps; name = pkgName; }))`);

const jsnixDrvOverrides =
  new nijs.NixValue(`{ drv_, jsnixDeps, dedupedDeps, isolateDeps }:
    let drv = drv_ (pkgs // { inherit nodejs copyNodeModules gitignoreSource jsnixDeps nodeModules getNodeDep; });
        skipUnpackFor = if (builtins.hasAttr "skipUnpackFor" drv)
                        then drv.skipUnpackFor else [];
        copyUnpackFor = if (builtins.hasAttr "copyUnpackFor" drv)
                        then drv.copyUnpackFor else [];
        pkgJsonFile = runCommand "package.json" { buildInputs = [jq]; } ''
          echo \${toPackageJson { inherit jsnixDeps; extraDeps = (if (builtins.hasAttr "extraDependencies" drv) then drv.extraDependencies else []); }} > $out
          cat <<< $(cat $out | jq) > $out
        '';
        copyDeps = builtins.attrValues jsnixDeps;
        copyDepsStr = builtins.concatStringsSep " " (builtins.map (dep: if (builtins.hasAttr "packageName" dep) then dep.packageName else dep.name) copyDeps);
        extraDeps = (builtins.map (dep: if (builtins.hasAttr "packageName" dep) then dep.packageName else dep.name)
                      (lib.optionals (builtins.hasAttr "extraDependencies" drv) drv.extraDependencies));
        extraDepsStr = builtins.concatStringsSep " " extraDeps;
        buildDepDep = lib.lists.unique (lib.lists.concatMap (d: d.buildInputs)
                        (copyDeps ++ (lib.optionals (builtins.hasAttr "extraDependencies" drv) drv.extraDependencies)));
        nodeModules = runCommandCC "\${sanitizeName packageNix.name}_node_modules"
          { buildInputs = [nodejs] ++ buildDepDep;
            fixupPhase = "true";
            doCheck = false;
            doInstallCheck = false;
            version = builtins.hashString "sha512" (lib.strings.concatStrings copyDeps); }
         ''
           echo 'unpack dependencies...'
           mkdir -p $out/lib/node_modules
           cd $out/lib
           \${linkNodeModules { dependencies = builtins.attrValues isolateDeps; }}
           \${copyNodeModules {
                dependencies = copyDeps;
           }}
           \${copyNodeModules {
                dependencies = builtins.attrValues dedupedDeps;
           }}
           chmod -R +rw node_modules
           \${copyNodeModules {
                dependencies = (lib.optionals (builtins.hasAttr "extraDependencies" drv) drv.extraDependencies);
           }}
           \${lib.optionalString ((builtins.length extraDeps) > 0) "echo 'resolving incoming transient deps of \${extraDepsStr}...'"}
           \${lib.optionalString ((builtins.length extraDeps) > 0) (flattenScript extraDepsStr)}
           \${lib.optionalString (builtins.hasAttr "nodeModulesUnpack" drv) drv.nodeModulesUnpack}
           echo 'link nodejs bins to out-dir...'
           \${linkBins}
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
        ln -s \${nodeModules}/lib/node_modules node_modules
        cat \${pkgJsonFile} > package.json
      '';
      buildPhase = ''
        runHook preBuild
       \${lib.optionalString (builtins.hasAttr "buildPhase" drv) drv.buildPhase}
       runHook postBuild
      '';
      installPhase =  ''
          runHook preInstall
          mkdir -p $out/lib/node_modules/\${packageNix.name}
          cp -rfT ./ $out/lib/node_modules/\${packageNix.name}
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
        runCommand: undefined,
        runCommandCC: undefined,
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
          copyNodeModules: new nijs.NixValue(copyNodeModulesExpr),
          linkNodeModules: new nijs.NixValue(linkNodeModulesExpr),
          gitignoreSource: new nijs.NixValue(gitignoreSource),
          transitiveDepInstallPhase: new nijs.NixValue(
            transitiveDepInstallPhase
          ),
          transitiveDepUnpackPhase: new nijs.NixValue(transitiveDepUnpackPhase),
          getNodeDep: new nijs.NixValue(getNodeDep),
          nodeSources,
          linkBins,
          flattenScript,
          sanitizeName,
          jsnixDrvOverrides,
          toPackageJson,
          mkPhaseBan,
          mkPhase,
          mkExtraBuildInputs,
          mkExtraDependencies,
          mkUnpackScript,
          mkBuildScript,
          mkInstallScript,
          goBinLink,
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
              ? dependencyName
              : dependencyName + "-" + versionSpec;

          this.packages[identifier] = new Package(
            jsnixConfig,
            undefined,
            dependencyName,
            versionSpec,
            baseDir,
            this.sourcesCache,
            false,
            false
          );
        }
      }
    } else if (dependencies && dependencies instanceof Object) {
      for (const dependencyName in dependencies) {
        const depData_ = dependencies[dependencyName];
        const depData =
          typeof depData_ === "string" ? { version: depData_ } : depData_;
        const version = depData["version"];
        const isolate = depData["isolate"] || false;

        this.packages[dependencyName] = new Package(
          jsnixConfig,
          undefined,
          dependencyName,
          version,
          baseDir,
          this.sourcesCache,
          false,
          isolate
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
      for (const srcDep in this.packages[pkgName].sourcesCache.sources) {
        if (srcDep === "undefined") {
          delete this.packages[pkgName].sourcesCache.sources[srcDep];
        }
      }
      await this.packages[pkgName].source.fetch();
      await this.packages[pkgName].resolveDependencies();
    }
  }

  toNixAST() {
    const ast = super.toNixAST.call(this);

    const packagesExpr = {};

    const isolatePkgs = {};

    const dedupedPackagesExpr = {};

    const resolvedDependencies = {};

    const allPackages = {};

    // store AST tree for further analysis
    for (const identifier in this.packages) {
      const pkg = this.packages[identifier];

      if (!pkg.isolate) {
        resolvedDependencies[pkg.name] = {
          pkg,
          pkgName: pkg.name,
          identifier,
          dependencies: pkg.generateDependencyAST(),
        };
      } else {
        isolatePkgs[pkg.name] = {
          pkg,
          pkgName: pkg.name,
          identifier,
          dependencies: pkg.generateDependencyAST(),
        };
      }
    }

    // organize all unique packages
    for (const pkgMeta of Object.entries(resolvedDependencies).sort(
      (x, y) => x[0].charCodeAt(0) - y[0].charCodeAt(0)
    )) {
      const { dependencies, pkgName, pkg } = pkgMeta[1];
      if (!allPackages[pkgName]) {
        allPackages[pkgName] = { rootVersion: pkg.versionSpec, groups: {} };
      } else {
        allPackages[pkgName]["rootVersion"] = pkg.versionSpec;
      }
      for (const dep of dependencies) {
        const refName = dep.funExpr.refExpr;
        const split = refName.split("-");
        const version = R.last(split);
        const depName = R.dropLast(1, split).join("-");

        let majorVer = version;
        try {
          majorVer = semverMajor(version);
        } catch {}

        if (!allPackages[depName]) {
          allPackages[depName] = { groups: {} };
        }

        if (!allPackages[depName].groups[majorVer]) {
          allPackages[depName].groups[majorVer] = [version];
        } else {
          allPackages[depName].groups[majorVer].push(version);
        }
      }
    }

    for (const pkgName of Object.keys(allPackages)) {
      const { groups, rootVersion } = allPackages[pkgName];
      const groupKeys = Object.keys(groups);
      if (!rootVersion && groupKeys.length === 1) {
        // dedupe to largest majorVer
        let resolved = Object.values(groups)[0][0];

        try {
          resolved = R.last(semverSort(Object.values(groups)[0]));
        } catch {}

        allPackages[pkgName] = { resolved, applied: false };
      } else if (!rootVersion && groupKeys.length > 1) {
        // pick lowest version for best compatability
        let redundantRoot = R.head(Object.values(groups)[0].sort());
        try {
          const firstGroup = groups[R.head(groupKeys.sort())];
          redundantRoot = firstGroup[0];
          redundantRoot = R.last(semverSort(firstGroup));
        } catch {}

        allPackages[pkgName] = { redundantRoot, applied: false };
      } else if (rootVersion) {
        let satisfiesRoot = false;

        if (groupKeys.length === 1) {
          const majVersion = Object.values(groups)[0][0];
          try {
            satisfiesRoot = semverSatisfies(`${majVersion}.0.0`, rootVersion);
          } catch {}
        }
        if (satisfiesRoot) {
          {
            skip: true;
          }
        } else {
          {
            keep: true;
          }
        }
      } else {
        allPackages[pkgName] = { keep: true };
      }
    }

    // apply dedupes
    for (const pkgName of Object.keys(resolvedDependencies)) {
      resolvedDependencies[pkgName].dependencies = resolvedDependencies[
        pkgName
      ].dependencies.reduce((acc, dep) => {
        const refName = dep.funExpr.refExpr;
        const split = refName.split("-");
        const version = R.last(split);
        const depName = R.dropLast(1, split).join("-");
        const action = allPackages[depName];

        if (action.skip || (action.redundantRoot && action.applied)) {
          return acc;
        }

        if (action.keep) {
          acc.push(dep);
        }

        if (action.redundantRoot === version && !action.applied) {
          dedupedPackagesExpr[depName] = dep;
          allPackages[depName].applied = true;
        }

        if (action.resolved === version && !action.applied) {
          dedupedPackagesExpr[depName] = dep;
          allPackages[depName].applied = true;
        }

        return acc;
      }, []);
    }

    // Generate sub expression for all the packages in the collection
    for (const pkgMeta of Object.values(resolvedDependencies)) {
      const { pkg, pkgName, identifier, dependencies } = pkgMeta;
      if (pkgName && identifier) {
        packagesExpr[identifier] = new nijs.NixLet({
          value: {
            dependencies,
            extraDependencies: new nijs.NixValue(`[] ++
            mkExtraDependencies
             (pkgs // { inherit jsnixDeps dependencies; })
             { pkgName = "${pkgName}"; }`),
          },
          body: new nijs.NixFunInvocation({
            funExpr: new nijs.NixExpression("stdenv.mkDerivation"),
            paramExpr: pkg,
          }),
        });
      }
    }

    const isolatePkgsExpr = {};

    // same for isolatePkgs to group them seperately (can be done more DRY)
    for (const pkgMeta of Object.values(isolatePkgs)) {
      const { pkg, pkgName, identifier, dependencies } = pkgMeta;
      if (pkgName && identifier) {
        isolatePkgsExpr[identifier] = new nijs.NixLet({
          value: {
            dependencies,
            extraDependencies: new nijs.NixValue(`[] ++
            mkExtraDependencies
             (pkgs // { inherit jsnixDeps dependencies; })
             { pkgName = "${pkgName}"; }`),
          },
          body: new nijs.NixFunInvocation({
            funExpr: new nijs.NixExpression("stdenv.mkDerivation"),
            paramExpr: pkg,
          }),
        });
      }
    }

    ast.body.value.jsnixDeps = packagesExpr;
    ast.body.value.dedupedDeps = dedupedPackagesExpr;
    ast.body.value.isolateDeps = isolatePkgsExpr;

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
              drv_: new nijs.NixExpression("packageNix.packageDerivation"),
              dedupedDeps: new nijs.NixInherit(),
              jsnixDeps: new nijs.NixInherit(),
              isolateDeps: new nijs.NixInherit(),
            },
          }),
        },
        elseExpr: {},
      }),
    });

    return ast;
  }
}
