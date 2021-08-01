import fs from "fs";
import path from "path";
import semver from "semver";
import nijs from "nijs";
import * as R from "rambda";
import * as GypDepsCompat from "../compat/gyp-deps.mjs";
import { Source } from "./sources/Source.mjs";
import { GitSource } from "./sources/GitSource.mjs";
import { HTTPSource } from "./sources/HTTPSource.mjs";
import { NPMRegistrySource } from "./sources/NPMRegistrySource.mjs";
import { LocalSource } from "./sources/LocalSource.mjs";
import { resolveCompat } from "../compat/index.mjs";

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
    const compat = resolveCompat({
      name,
      versionSpec,
      pkgJsonResolutions: jsnixConfig.resolutions,
    });
    this.name = compat.name;
    this.versionSpec = compat.versionSpec;
    this.sourcesCache = sourcesCache;

    this.isTransitive = isTransitive;
    const newSrc = new Source(baseDir, compat.name, compat.versionSpec);
    newSrc.jsnixConfig = jsnixConfig;

    this.source = newSrc.constructSource.call(
      newSrc,
      parent,
      isTransitive,
      jsnixConfig.registries,
      path.resolve("."),
      jsnixConfig.outputDir,
      compat.name,
      compat.versionSpec,
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
          // If we found a dependency with the same name, see if the version fits
          semver.satisfies(dependency.source.config.version, versionSpec, true)
        ) {
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

  getDepth(pkg) {
    let depth = 0;
    while (pkg.parent) {
      depth += 1;
      pkg = pkg.parent;
    }
    return depth;
  }

  bundleDependency(dependencyName, pkg) {
    this.requiredDependencies[dependencyName] = pkg;

    // flatten
    if (this.parent && dependencyName === this.parent.name) {
      return undefined;
    } else if (
      this.parent &&
      !this.parent.providedDependencies[dependencyName] &&
      !this.parent.requiredDependencies[dependencyName] &&
      dependencyName !== this.parent.name
    ) {
      this.parent.bundleDependency(dependencyName, pkg);
    } else {
      pkg.parent = this;
      this.providedDependencies[dependencyName] = pkg;
    }
  }

  async bundleDependencies(resolvedDependencies, dependencies) {
    if (dependencies) {
      for (const dependencyName in dependencies) {
        const versionSpec = dependencies[dependencyName];
        const parentDependency = this.findMatchingProvidedDependencyByParent(
          dependencyName,
          versionSpec
        );

        if (this.isBundledDependency(dependencyName)) {
          delete this.requiredDependencies[dependencyName];
        } else if (parentDependency === null) {
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
        } else {
          this.requiredDependencies[dependencyName] = parentDependency; // If there is a parent package that provides the requested dependency -> use it
        }
      }
    }
  }

  async resolveDependencies() {
    // var self = this;
    const resolvedDependencies = {};

    if (this.source.config && this.source.config.dependencies) {
      await this.bundleDependencies(
        resolvedDependencies,
        this.source.config.dependencies
      );
    }

    await this.bundleDependencies(
      resolvedDependencies,
      this.source.config.peerDependencies
    );

    // if (!this.isTransitive) {
    //   await this.bundleDependencies(
    //     resolvedDependencies,
    //     this.source.config.devDependencies
    //   );
    //   await this.bundleDependencies(
    //     resolvedDependencies,
    //     this.source.config.peerDependencies
    //   );
    // }

    for (const dependencyName in resolvedDependencies) {
      const dependency = resolvedDependencies[dependencyName];
      dependency.resolveDependencies &&
        (await dependency.resolveDependencies());
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
      if (!dependency.source.identifier) return [];
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
      return [];
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
    const gypBuildDeps = GypDepsCompat.resolveExtraGypInputs(
      R.append(
        this.source.config.name,
        Object.keys(this.providedDependencies || {})
      )
    );
    const gypPatches = GypDepsCompat.resolveSubstitutes(
      this.source.config.name
    );
    const gypExtraUnpack = GypDepsCompat.resolveExtraUnpack(
      this.source.config.name
    );

    ast.dependencies = new nijs.NixInherit();
    ast.extraDependencies = new nijs.NixInherit();
    ast.buildInputs = new nijs.NixValue(
      `[ nodejs python3 makeWrapper jq ${gypBuildDeps.buildInputs} ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ${gypBuildDeps.darwinBuildInputs}]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "${this.source.config.name}"; })`
    );
    ast.dontStrip = new nijs.NixValue("true"); // it's just too slow atm with node_modules
    // ast.preUnpackBan_ = new nijs.NixValue(`mkPhaseBan "preUnpack" drv`);
    // ast.unpackBan_ = new nijs.NixValue(`mkPhaseBan "unpackPhase" drv`);
    // ast.postUnpackBan_ = new nijs.NixValue(`mkPhaseBan "postUnpack" drv`);
    // ast.preConfigureBan_ = new nijs.NixValue(`mkPhaseBan "preConfigure" drv`);
    // ast.configureBan_ = new nijs.NixValue(`mkPhaseBan "configurePhase" drv`);
    // ast.postConfigureBan_ = new nijs.NixValue(`mkPhaseBan "postConfigure" drv`);

    ast.NODE_OPTIONS = new nijs.NixValue('"--preserve-symlinks"');
    ast.passAsFile = new nijs.NixValue(
      `[ "unpackScript" "configureScript" "buildScript" "installScript" ]`
    );
    ast.unpackScript = new nijs.NixValue(
      `mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "${this.source.config.name}"; }`
    );
    ast.configureScript = new nijs.NixValue(`mkConfigureScript {}`);
    ast.buildScript = new nijs.NixValue(
      `mkBuildScript { inherit dependencies; pkgName = "${this.source.config.name}"; }`
    );

    ast.buildPhase = new nijs.NixValue(`''
      source $unpackScriptPath ${gypExtraUnpack}
      source $configureScriptPath
      runHook preBuild
      if [ -z "$preBuild" ]; then
        runHook preInstall
      fi
      source $buildScriptPath
      if [ -z "$postBuild" ]; then
        runHook postBuild
      fi
    ''`);

    ast.patchPhase = new nijs.NixValue(`''
      if [ -z "$prePatch" ]; then
        runHook prePatch
      fi
      ${gypPatches}
      if [ -z "$postPatch" ]; then
        runHook postPatch
      fi
    ''`);

    ast.installScript = new nijs.NixValue(
      `mkInstallScript { pkgName = "${this.source.config.name}"; }`
    );
    ast.installPhase = new nijs.NixValue(`''
      if [ -z "$preInstall" ]; then
        runHook preInstall
      fi
      source $installScriptPath
      if [ -z "$postInstall" ]; then
        runHook postInstall
      fi
    ''`);
    ast.preInstall = new nijs.NixValue(
      `(mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preInstall"; pkgName = "${this.source.config.name}"; })`
    );
    ast.postInstall = new nijs.NixValue(
      `(mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postInstall"; pkgName = "${this.source.config.name}"; })`
    );
    ast.preBuild = new nijs.NixValue(
      `(mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preBuild"; pkgName = "${this.source.config.name}"; })`
    );
    ast.postBuild = new nijs.NixValue(
      `(mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postBuild"; pkgName = "${this.source.config.name}"; })`
    );
    ast.doInstallCheck = true;
    ast.installCheckPhase = new nijs.NixValue(
      `(mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "${this.source.config.name}"; })`
    );
    // ast.depsBuildBuild = new nijs.NixValue("builtins.attrValues dependencies");
    ast.meta = {
      description: this.source.config.description,
      license: this.source.config.license,
      homepage,
    };
    return ast;
  }
}
