import slasp from "slasp";
import nijs from "nijs";
import { inherit } from "nijs/lib/ast/util/inherit.js";
import { Package } from "./Package.js";
import { Sources } from "./sources/index.js";

const linkNodeModulesExpr = `{dependencies ? []}:
    (lib.lists.foldr (dep: acc: acc + "mkdir -p node_modules/\${dep.packageName};
     ln -s \${dep}/lib/node_modules/\${dep.packageName}/* node_modules/\${dep.packageName};")
     "" dependencies)`;

const copyNodeModulesExpr = `{dependencies ? []}:
    (lib.lists.foldr (dep: acc: acc + "mkdir -p node_modules/\${dep.packageName};
     cp -rT \${dep}/lib/node_modules/\${dep.packageName} node_modules/\${dep.packageName};")
     "" dependencies)`;

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
        "... ": undefined,
        // nodeEnv: undefined,
        // "nix-gitignore": undefined,
        // globalBuildInputs: [],
      },
      body: new nijs.NixLet({
        value: {
          // buildNodePackage:
          packageNix: new nijs.NixImport(
            new nijs.NixFile({ value: "./package.nix" })
          ),
          linkNodeModules: new nijs.NixValue(linkNodeModulesExpr),
          copyNodeModules: new nijs.NixValue(copyNodeModulesExpr),

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
        this.packages[dependencyName] = new Package(
          jsnixConfig,
          undefined,
          dependencyName,
          dependencies[dependencyName],
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
                  nixjsDeps: new nijs.NixInherit(),
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
