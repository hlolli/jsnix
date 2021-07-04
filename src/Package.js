import fs from "fs";
import path from "path";
import semver from "semver";
import slasp from "slasp";
import nijs from "nijs";
import { Source } from "./sources/Source.js";
import { GitSource } from "./sources/GitSource.js";
import { HTTPSource } from "./sources/HTTPSource.js";
import { NPMRegistrySource } from "./sources/NPMRegistrySource.js";
import { LocalSource } from "./sources/LocalSource.js";

export class Package extends nijs.NixASTNode {
  constructor(
    jsnixConfig,
    parent,
    name,
    versionSpec,
    baseDir,
    sourcesCache,
    isTransitive
  ) {
    super();
    this.jsnixConfig = jsnixConfig;
    this.parent = parent;
    this.name = name;
    this.versionSpec = versionSpec;
    this.sourcesCache = sourcesCache;

    this.isTransitive = isTransitive;
    const newSrc = new Source(baseDir, name, versionSpec);

    this.source = newSrc.constructSource.call(
      newSrc,
      parent,
      jsnixConfig.registries,
      path.resolve("."),
      jsnixConfig.outputDir,
      name,
      versionSpec,
      { GitSource, HTTPSource, NPMRegistrySource, LocalSource }
    );

    this.requiredDependencies = {};
    this.providedDependencies = {};
  }

  findMatchingProvidedDependencyByParent(name, versionSpec) {
    if (!this.parent) {
      // If there is no parent, then we can also not provide a dependency
      return null;
    } else {
      var dependency = this.parent.providedDependencies[name];

      if (dependency === undefined) {
        return this.parent.findMatchingProvidedDependencyByParent(
          name,
          versionSpec
        ); // If the parent does not provide the dependency, try the parent's parent
      }
      if (!dependency || !dependency.source || !dependency.source.config) {
        // If we have encountered a bundled dependency with the same name, consider it a conflict
        // (is not a perfect resolution, but does not result in an error)
        return null;
      } else {
        if (
          semver.satisfies(dependency.source.config.version, versionSpec, true)
        ) {
          // If we found a dependency with the same name, see if the version fits
          return dependency;
        } else {
          return null; // If there is a version mismatch, then a conflicting version has been encountered
        }
      }
    }
  }
  isBundledDependency(dependencyName) {
    // Check the bundledDependencies option
    if (Array.isArray(this.source.config.bundledDependencies)) {
      for (let i = 0; i < this.source.config.bundledDependencies.length; i++) {
        if (dependencyName == this.source.config.bundledDependencies[i])
          return true;
      }
    }

    // Check the bundleDependencies option
    if (Array.isArray(this.source.config.bundleDependencies)) {
      for (let i = 0; i < this.source.config.bundleDependencies.length; i++) {
        if (dependencyName == this.source.config.bundleDependencies[i])
          return true;
      }
    }

    return false;
  }

  bundleDependency(dependencyName, pkg) {
    this.requiredDependencies[dependencyName] = pkg;
    // flatten
    if (
      this.parent &&
      !this.parent.providedDependencies[dependencyName] &&
      !this.parent.requiredDependencies[dependencyName]
    ) {
      this.parent.bundleDependency(dependencyName, pkg);
    } else {
      pkg.parent = this;
      this.providedDependencies[dependencyName] = pkg;
    }
  }

  async bundleDependencies(resolvedDependencies, dependencies) {
    if (dependencies) {
      // var self = this;
      for (const dependencyName in dependencies) {
        const versionSpec = dependencies[dependencyName];
        const parentDependency = this.findMatchingProvidedDependencyByParent(
          dependencyName,
          versionSpec
        );

        if (this.isBundledDependency(dependencyName)) {
          delete this.requiredDependencies[dependencyName];
        } else if (!parentDependency) {
          const pkg = new Package(
            this.jsnixConfig,
            this,
            dependencyName,
            versionSpec,
            this.source.baseDir,
            this.sourcesCache,
            true
          );
          await pkg.source.fetch();
          this.sourcesCache.addSource(pkg.source);
          this.bundleDependency(dependencyName, pkg);
          resolvedDependencies[dependencyName] = pkg;

          // slasp.sequence(
          //     [
          //       function (callback) {
          //         pkg.source.fetch(callback);
          //       },

          //       function (callback) {
          //         self.sourcesCache.addSource(pkg.source);
          //         self.bundleDependency(dependencyName, pkg);
          //         resolvedDependencies[dependencyName] = pkg;
          //         callback();
          //       },
          //     ],
          //     callback
          //   );
        } else {
          this.requiredDependencies[dependencyName] = parentDependency; // If there is a parent package that provides the requested dependency -> use it
        }
      }
    }
  }

  async resolveDependencies() {
    // var self = this;
    const resolvedDependencies = {};

    await this.bundleDependencies(
      resolvedDependencies,
      this.source.config.dependencies
    );

    await this.bundleDependencies(
      resolvedDependencies,
      this.source.config.devDependencies
    );

    await this.bundleDependencies(
      resolvedDependencies,
      this.source.config.peerDependencies
    );

    for (const dependencyName in resolvedDependencies) {
      const dependency = resolvedDependencies[dependencyName];
      await dependency.resolveDependencies();
    }

    return resolvedDependencies;
  }

  generateDependencyAST() {
    // var self = this;
    const dependencies = [];
    for (const dependencyName of Object.keys(
      this.providedDependencies
    ).sort()) {
      const dependency = this.providedDependencies[dependencyName];

      // For each dependency, refer to the source attribute set that defines it
      const ref = new nijs.NixFunInvocation({
        funExpr: new nijs.NixAttrReference({
          attrSetExpr: new nijs.NixExpression("sources"),
          refExpr: dependency.source.identifier,
        }),
        paramExpr: { dependencies: [] },
      });

      const transitiveDependencies = dependency.generateDependencyAST();
      const dependencyExpr = ref;

      if (transitiveDependencies) {
        ref.paramExpr.dependencies = ref.paramExpr.dependencies.concat(
          transitiveDependencies
        );
      }
      dependencies.push(dependencyExpr);
    }

    if (dependencies.length == 0) {
      return undefined;
    } else {
      return dependencies;
    }
  }

  toNixAST() {
    let homepage = "";

    if (
      typeof this.source.config.homepage == "string" &&
      this.source.config.homepage
    ) {
      homepage = this.source.config.homepage;
    }

    const ast = this.source.toNixAST();
    ast.dependencies = this.generateDependencyAST();
    ast.buildInputs = new nijs.NixExpression("globalBuildInputs");
    ast.meta = {
      description: this.source.config.description,
      license: this.source.config.license,
      homepage,
    };
    return ast;
  }
}
