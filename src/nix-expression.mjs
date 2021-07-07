import slasp from "slasp";
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

const getNodeDepFromList = `packageName: dependencies:
    (builtins.head
      (builtins.filter (p: p.packageName == packageName) dependencies))`;

const linkNodeModulesExpr = `{dependencies ? []}:
    (lib.lists.foldr (dep: acc: acc + ''mkdir -p "node_modules/\${dep.packageName}";
     ln -s "\${dep}/lib/node_modules/\${dep.packageName}/*" "node_modules/\${dep.packageName}"
     '')
     "" dependencies)`;

const copyNodeModulesExpr = `{dependencies ? []}:
    (lib.lists.foldr (dep: acc: acc + ''mkdir -p node_modules/\${dep.packageName};
     cp -rT "\${dep}/lib/node_modules/\${dep.packageName}" "node_modules/\${dep.packageName}"
     find "\${dep}/lib/node_modules/\${dep.packageName}" \\
       -not -path "\${dep}/lib/node_modules/\${dep.packageName}/node_modules/*" \\
       -type f -exec chmod +rw {} \\; 2>/dev/null
     '')
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

const mkPhase = new nijs.NixValue(`pkgs_: {phase, pkgName}:
     lib.optionalString ((builtins.hasAttr "\${pkgName}" packageNix.dependencies) &&
                         (builtins.typeOf packageNix.dependencies."\${pkgName}" == "set") &&
                         (builtins.hasAttr "\${phase}" packageNix.dependencies."\${pkgName}"))
      (if builtins.typeOf packageNix.dependencies."\${pkgName}"."\${phase}" == "string"
       then
         packageNix.dependencies."\${pkgName}"."\${phase}"
       else
         (packageNix.dependencies."\${pkgName}"."\${phase}" pkgs_))`);

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
          getNodeDepFromList: new nijs.NixValue(getNodeDepFromList),
          mkPhase,
          sources: this.sourcesCache,
        },
      }),
    });
  }
}

export class NixExpression extends OutputExpression {
  constructor(jsnixConfig, baseDir, dependencies) {
    super();
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
        value: { dependencies: pkg.generateDependencyAST() },
        body: new nijs.NixFunInvocation({
          funExpr: new nijs.NixExpression("stdenv.mkDerivation"),
          paramExpr: pkg,
        }),
      });
    }
    ast.body.value.nixjsDeps = new nijs.NixMergeAttrs({
      left: new nijs.NixExpression("sources"),
      right: packagesExpr,
    });

    ast.body.body = new nijs.NixMergeAttrs({
      left: new nijs.NixExpression("nixjsDeps"),
      right: new nijs.NixIf({
        ifExpr: new nijs.NixFunInvocation({
          funExpr: new nijs.NixExpression("builtins.hasAttr"),
          paramExpr: new nijs.NixExpression('"packageDerivation" packageNix'),
        }),
        thenExpr: {
          "${packageNix.name}": new nijs.NixFunInvocation({
            funExpr: new nijs.NixExpression("stdenv.mkDerivation"),
            paramExpr: new nijs.NixFunInvocation({
              funExpr: new nijs.NixExpression("packageNix.packageDerivation"),
              paramExpr: new nijs.NixMergeAttrs({
                left: new nijs.NixExpression("pkgs"),
                right: {
                  copyNodeModules: new nijs.NixInherit(),
                  linkNodeModules: new nijs.NixInherit(),
                  gitignoreSource: new nijs.NixInherit(),
                  nixjsDeps: new nijs.NixInherit(),
                  getNodeDepFromList: new nijs.NixInherit(),
                },
              }),
            }),
          }),
        },

        elseExpr: {},
      }),
    });

    return ast;
  }
}
