import cachedir from "cachedir";
import log from "npmlog";
import nijs from "nijs";
import npmFetch from "npm-registry-fetch";
import npmconf from "npmconf";
import path from "path";
import semver from "semver";
import { Source } from "./Source.mjs";
import { getBodyLens } from "./common.mjs";
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
      selectedRegistry.url +
      "/" +
      dependencyName_.replace("/", "%2F").replace(/^npm:/, "");

    log.enableProgress();

    const npmFetchOpts = {
      log: {
        http: (data1, data2, data3) =>
          log.showProgress(data1 + " " + data2 + "\n"),
      },
    };

    if (selectedRegistry.authToken) {
      npmFetchOpts.token = selectedRegistry.authToken;
    }
    const cachePolicy = R.pathOr("always", ["opt", "cache"], this.jsnixConfig);

    if (!cachePolicy) {
      npmFetchOpts.preferOnline = true;
    } else if (cachePolicy === "verify") {
      npmFetchOpts.preferOffline = true;
    } else {
      npmFetchOpts.offline = true;
    }

    const cacheDir = cachedir("jsnix");

    npmFetchOpts.cache = cacheDir;

    let data;
    try {
      data = await npmFetch.json(url, npmFetchOpts);
    } catch (error) {
      // only possible in offline mode, try again as online
      if (error.code === "ENOTCACHED") {
        data = await npmFetch.json(
          url,
          R.mergeAll([npmFetchOpts, { preferOnline: true, offline: false }])
        );
      }
      !data && console.error(error);
    }

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

    // sometimes npm respondes with higher version than exists in cache
    // let's rule that one out
    if (!resolvedVersion) {
      try {
        const data2 = await npmFetch.json(
          url,
          R.mergeAll([npmFetchOpts, { preferOnline: true, offline: false }])
        );
        const versionIdentifiers2 = Object.keys(data2.versions);
        const version2 = semver.validRange(this.versionSpec, true)
          ? this.versionSpec
          : data["dist-tags"][this.versionSpec];
        resolvedVersion = semver.maxSatisfying(
          versionIdentifiers2,
          version2,
          true
        );
        if (resolvedVersion2) {
          data = data2;
        }
      } catch {}
    }

    // if (data._id === "iconv-lite") {
    //   console.log("versionIds", versionIdentifiers);
    //   console.log("versionSpec", this.versionSpec);
    //   console.log("data", data._id);
    //   console.log("version", version);
    //   console.log("resolvedVersion", resolvedVersion);
    //   console.log("OK", Object.keys(this));
    //   console.log("OK2", Object.keys(this.parent));
    //   console.log("OK3", Object.keys(this.parent.source));
    // }

    if (!resolvedVersion && version.includes(".")) {
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

    if (!this.config) {
      this.config = {};
    }

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

    if (this.config && this.config.dist && this.config.dist.integrity) {
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
