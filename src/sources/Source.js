import base64js from "base64-js";
import url from "url";
import semver from "semver";
import nijs from "nijs";

// needed for '' multiline comments
nijs.NixValue.prototype.toNixExpr = function () {
  return this.value;
};

export class Source extends nijs.NixASTNode {
  constructor(baseDir, dependencyName, versionSpec) {
    super();
    this.baseDir = baseDir;
    this.dependencyName = dependencyName;
    this.versionSpec = versionSpec;
  }

  constructSource(
    parent,
    registries,
    baseDir,
    outputDir,
    dependencyName,
    versionSpec,
    sourceTypes
  ) {
    // Assign modules here, to prevent cycles in the include process
    this.GitSource = sourceTypes.GitSource;
    this.HTTPSource = sourceTypes.HTTPSource;
    this.LocalSource = sourceTypes.LocalSource;
    this.NPMRegistrySource = sourceTypes.NPMRegistrySource;

    this.parent = parent;
    console.log(dependencyName, versionSpec);
    const parsedVersionSpec = semver.validRange(versionSpec, true);
    const parsedUrl = url.parse(versionSpec);

    if (parsedUrl.protocol == "github:") {
      // If the version is a GitHub repository, compose the corresponding Git URL and do a Git checkout
      const gitSrc = new this.GitSource(
        baseDir,
        dependencyName,
        this.GitSource.prototype.composeGitURL(
          this,
          "git://github.com",
          parsedUrl
        )
      );
      Object.keys(this).forEach((k) => {
        gitSrc[k] = this[k];
      });
      return gitSrc;
    } else if (parsedUrl.protocol == "gist:") {
      // If the version is a GitHub gist repository, compose the corresponding Git URL and do a Git checkout
      const gitSrc = new this.GitSource(
        baseDir,
        dependencyName,
        this.GitSource.prototype.composeGitURL(
          "https://gist.github.com",
          parsedUrl
        )
      );
      Object.keys(this).forEach((k) => {
        gitSrc[k] = this[k];
      });
      return gitSrc;
    } else if (parsedUrl.protocol == "bitbucket:") {
      // If the version is a Bitbucket repository, compose the corresponding Git URL and do a Git checkout
      const gitSrc = new this.GitSource(
        baseDir,
        dependencyName,
        this.GitSource.composeGitURL("git://bitbucket.org", parsedUrl)
      );

      Object.keys(this).forEach((k) => {
        gitSrc[k] = this[k];
      });

      return gitSrc;
    } else if (parsedUrl.protocol == "gitlab:") {
      // If the version is a Gitlab repository, compose the corresponding Git URL and do a Git checkout
      const gitSrc = new this.GitSource(
        baseDir,
        dependencyName,
        this.GitSource.composeGitURL("https://gitlab.com", parsedUrl)
      );
      Object.keys(this).forEach((k) => {
        gitSrc[k] = this[k];
      });
      return gitSrc;
    } else if (
      typeof parsedUrl.protocol == "string" &&
      parsedUrl.protocol.substr(0, 3) == "git"
    ) {
      // If the version is a Git URL do a Git checkout
      const gitSrc = new this.GitSource(baseDir, dependencyName, versionSpec);
      Object.keys(this).forEach((k) => {
        gitSrc[k] = this[k];
      });
      return gitSrc;
    } else if (
      parsedUrl.protocol == "http:" ||
      parsedUrl.protocol == "https:"
    ) {
      // If the version is an HTTP URL do a download
      const httpSrc = new this.HTTPSource(baseDir, dependencyName, versionSpec);
      Object.keys(this).forEach((k) => {
        httpSrc[k] = this[k];
      });
      return httpSrc;
    } else if (
      versionSpec.match(/^[a-zA-Z0-9_\-]+\/[a-zA-Z0-9\.]+[#[a-zA-Z0-9_\-]+]?$/)
    ) {
      // If the version is a GitHub repository, compose the corresponding Git URL and do a Git checkout
      const gitSrc = new this.GitSource(
        baseDir,
        dependencyName,
        "git://github.com/" + versionSpec
      );
      Object.keys(this).forEach((k) => {
        gitSrc[k] = this[k];
      });
      return gitSrc;
    } else if (parsedUrl.protocol == "file:") {
      // If the version is a file URL, simply compose a Nix path
      const localSrc = new this.LocalSource(
        baseDir,
        dependencyName,
        outputDir,
        parsedUrl.path
      );
      Object.keys(this).forEach((k) => {
        localSrc[k] = this[k];
      });
      return localSrc;
    } else if (
      versionSpec.substr(0, 3) == "../" ||
      versionSpec.substr(0, 2) == "~/" ||
      versionSpec.substr(0, 2) == "./" ||
      versionSpec.substr(0, 1) == "/"
    ) {
      // If the version is a path, simply compose a Nix path

      const localSrc = new this.LocalSource(
        baseDir,
        dependencyName,
        outputDir,
        versionSpec
      );
      Object.keys(this).forEach((k) => {
        localSrc[k] = this[k];
      });
    } else {
      // In all other cases, just try the registry. Sometimes invalid semver ranges are encountered or a tag has been provided (e.g. 'latest', 'unstable')
      const npmSrc = new this.NPMRegistrySource(
        baseDir,
        dependencyName,
        parsedVersionSpec || versionSpec,
        registries
      );
      Object.keys(this).forEach((k) => {
        npmSrc[k] = this[k];
      });
      return npmSrc;
    }
  }

  convertIntegrityStringToNixHash(integrity) {
    if (integrity.substr(0, 5) === "sha1-") {
      const hash = base64js.toByteArray(integrity.substring(5));
      this.hashType = "sha1";
      this.sha1 = new Buffer(hash).toString("hex");
    } else if (integrity.substr(0, 7) === "sha512-") {
      this.hashType = "sha512";
      this.sha512 = integrity.substring(7);
    } else {
      throw "Unknown integrity string: " + integrity;
    }
  }

  toNixAST() {
    const pkgName = this.config.name
      .replace("@", "_at_")
      .replace("/", "_slash_");
    return this.useImpureNpmCache
      ? new nijs.NixFunction({
          argSpec: { dependencies: [] },
          body: new nijs.NixFunInvocation({
            funExpr: new nijs.NixExpression("stdenv.mkDerivation"),
            paramExpr: {
              name: pkgName, // Escape characters from scoped package names that aren't allowed
              packageName: this.config.name,
              version: this.config.version,
              buildInputs: [new nijs.NixExpression("nodejs")],
              buildPhase: "true", // dont build transitive deps
              installPhase: new nijs.NixValue(`''
                export packageDir="$(pwd)"
                mkdir -p $out/lib/node_modules/${this.config.name}
                cd $out/lib/node_modules/${this.config.name}
                cp -rfT "$packageDir" "$(pwd)"
              ''`),
            },
          }),
        })
      : {
          name: pkgName,
          packageName: this.config.name,
          version: this.config.version,
        };
  }
}
