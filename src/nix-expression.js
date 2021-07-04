import slasp from "slasp";
import nijs from "nijs";
import { inherit } from "nijs/lib/ast/util/inherit.js";
import { Package } from "./Package.js";
import { Sources } from "./sources/index.js";

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
        nodejs: undefined,
        nodeEnv: undefined,
        fetchurl: undefined,
        fetchgit: undefined,
        "nix-gitignore": undefined,
        stdenv: undefined,
        lib: undefined,
        globalBuildInputs: [],
      },
      body: new nijs.NixLet({
        value: {
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

      packagesExpr[identifier] = new nijs.NixFunInvocation({
        funExpr: new nijs.NixAttrReference({
          attrSetExpr: new nijs.NixExpression("nodeEnv"),
          refExpr: new nijs.NixExpression("buildNodePackage"),
        }),
        paramExpr: pkg,
      });
    }

    // Attach sub expression to the function body
    ast.body.body = new nijs.NixMergeAttrs({
      left: new nijs.NixExpression("sources"),
      right: packagesExpr,
    });

    return ast;
  }
}
