import cachedir from "cachedir";
import log from "npmlog";
import nijs from "nijs";
import npmFetch from "npm-registry-fetch";
import npmconf from "npmconf";
import path from "path";
import semver from "semver";
import { Source } from "./Source.js";
import { getBodyLens } from "./common.js";
import * as R from "rambda";

export class NPMRegistrySource extends Source {
  constructor(baseDir, dependencyName, versionSpec, registries) {
    super();
    this.dependencyName = dependencyName;
    this.versionSpec = versionSpec;
    this.registries = registries;
    this.baseDir = path.join(baseDir, dependencyName);
  }

  async fetch() {
    const selectedRegistry = this.registries[0];
    let npmProtocolPath;

    if (this.versionSpec.startsWith("npm:")) {
      const npmProtocolVersion = this.versionSpec
        .replace(/npm:@?/i, "")
        .match(/@(.*)/i);

      npmProtocolPath = this.versionSpec.replace("npm:", "");

      if (
        npmProtocolVersion &&
        Array.isArray(npmProtocolVersion) &&
        npmProtocolVersion.length > 1
      ) {
        this.versionSpec = npmProtocolVersion[1];
        npmProtocolPath = npmProtocolPath.replace(npmProtocolVersion[0], "");
      }
      this.npmProtocolPath = npmProtocolPath;
    }

    /* For a scoped package, determine from which registry it needs to be obtained */
    if (this.dependencyName.startsWith("@")) {
      const scope = this.dependencyName.slice(
        0,
        this.dependencyName.indexOf("/")
      );
      const found = this.registries.find((registry) => {
        return registry.scope == scope;
      });

      if (found) {
        selectedRegistry = found;
      }
    }

    /* Fetch package.json from the registry using the dependency name and version specification */
    const dependencyName_ = npmProtocolPath
      ? npmProtocolPath
      : this.dependencyName;
    const url =
      selectedRegistry.url + "/" + dependencyName_.replace("/", "%2F"); // Escape / to make scoped packages work

    const npmFetchOpts = { log };

    if (selectedRegistry.authToken) {
      npmFetchOpts.token = selectedRegistry.authToken;
    }

    npmFetchOpts.cache = process.env["jsnix"] || cachedir("node2nix");

    const data = await npmFetch.json(url, npmFetchOpts);

    if (data == undefined || data.versions === undefined) {
      console.error(
        "Error fetching package: " + this.dependencyName + " from NPM registry!"
      );
      process.exit(1);
    }

    const versionIdentifiers = Object.keys(data.versions);
    const version = semver.validRange(this.versionSpec, true)
      ? this.versionSpec
      : data["dist-tags"][this.versionSpec];
    let resolvedVersion = semver.maxSatisfying(
      versionIdentifiers,
      version,
      true
    );

    if (!resolvedVersion) {
      console.error(
        "Cannot resolve version: " +
          this.dependencyName +
          "@" +
          version +
          " of " +
          versionIdentifiers.join(" ") +
          " " +
          "\n falling back to highest lexical version : " +
          versionIdentifiers[versionIdentifiers.length - 1]
      );

      let parent = this.parent;
      const dependencyChain = [];
      while (parent) {
        dependencyChain.push(parent.name + "@" + parent.versionSpec);
        parent = parent.parent;
      }
      console.error(R.reverse(dependencyChain).join(" -> "));
      resolvedVersion = versionIdentifiers[versionIdentifiers.length - 1];
    }

    this.config = data.versions[resolvedVersion];

    this.config.name = this.npmProtocolPath
      ? this.dependencyName
      : this.config.name;

    this.identifier = this.config.name + "-" + this.config.version;

    if (
      this.config &&
      this.config.optionalDependencies !== undefined &&
      this.config.dependencies !== undefined
    ) {
      /*
       * The NPM registry has a weird oddity -- if a package has
       * optionalDependencies, then these dependencies are added
       * to the regular dependencies as well. We must deduct them
       * so that we only work with the mandatory dependencies.
       * Otherwise, certain builds may fail, because optional
       * dependencies can be broken.
       *
       * I'm actually quite curious to learn about the rationale
       * of this from the NPM developers.
       */

      for (var dependencyName in this.config.optionalDependencies) {
        delete this.config.dependencies[dependencyName];
      }
    }

    // prevent infinite loop when a package depends on itself
    delete (this.config.dependencies || {})[this.config.name];
    if (this.config.dist.integrity) {
      try {
        this.convertIntegrityStringToNixHash(this.config.dist.integrity);
      } catch (error) {
        console.error(error);
        process.exit(1);
      }
    } else {
      this.hashType = "sha1";
      this.sha1 = this.config.dist.shasum; // SHA1 hashes are in hexadecimal notation which we can just adopt verbatim
    }
  }

  toNixAST() {
    const ast = super.toNixAST.call(this);
    const lens = getBodyLens(ast);

    const paramExpr = {
      url: this.config.dist.tarball,
    };

    switch (this.hashType) {
      case "sha1":
        paramExpr.sha1 = this.sha1;
        break;
      case "sha512":
        paramExpr.sha512 = this.sha512;
        break;
    }

    lens.src = new nijs.NixFunInvocation({
      funExpr: new nijs.NixExpression("fetchurl"),
      paramExpr: paramExpr,
    });

    return ast;
  }
}
