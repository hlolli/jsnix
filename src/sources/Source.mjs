import base64js from "base64-js";
import gitUrlParse from "git-url-parse";
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
    isTransitive,
    registries,
    baseDir,
    outputDir,
    dependencyName,
    versionSpec,
    sourceTypes
  ) {
    this.isTransitive = isTransitive;

    // Assign modules here, to prevent cycles in the include process
    this.GitSource = sourceTypes.GitSource;
    this.HTTPSource = sourceTypes.HTTPSource;
    this.LocalSource = sourceTypes.LocalSource;
    this.NPMRegistrySource = sourceTypes.NPMRegistrySource;

    this.parent = parent;

    const parsedVersionSpec = semver.validRange(versionSpec, true);

    let parsedUrl;

    if (
      !versionSpec ||
      typeof versionSpec !== "string" ||
      !versionSpec.trim() ||
      versionSpec.trim() === "@"
    ) {
      parsedUrl = url.parse(versionSpec);
    } else {
      try {
        parsedUrl = gitUrlParse(versionSpec);
      } catch (error) {
        parsedUrl = url.parse("*");
      }
    }

    if (
      !parsedVersionSpec &&
      parsedUrl.protocol !== "file" &&
      parsedUrl.source !== "file"
    ) {
      // If the version is a GitHub repository, compose the corresponding Git URL and do a Git checkout
      const gitSrc = new this.GitSource(baseDir, dependencyName, versionSpec);
      Object.keys(this).forEach((k) => {
        gitSrc[k] = this[k];
      });
      return gitSrc;
    } else if (parsedUrl.resource === "file" || parsedUrl.source === "file") {
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
    return this.isTransitive
      ? new nijs.NixFunction({
          argSpec: { dependencies: [] },
          body: new nijs.NixFunInvocation({
            funExpr: new nijs.NixExpression("stdenv.mkDerivation"),
            paramExpr: {
              name: pkgName, // Escape characters from scoped package names that aren't allowed
              packageName: this.config.name,
              version: this.config.version,
              extraDependencies: [],
              buildInputs: [
                new nijs.NixExpression("jq"),
                new nijs.NixExpression("nodejs"),
              ],
              NODE_OPTIONS: new nijs.NixValue('"--preserve-symlinks"'),
              unpackPhase: new nijs.NixValue(
                `transitiveDepUnpackPhase { inherit dependencies; pkgName = "${this.config.name}"; }`
              ),

              patchPhase: new nijs.NixValue(`''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                ${
                  this.config.name.startsWith("node-gyp")
                    ? `if [ -f "bin/node-gyp.js" ]; then
                       substituteInPlace bin/node-gyp.js \\
                         --replace 'open(output_filename' 'open(re.sub(r".*/nix/store/", "/nix/store/", output_filename)' || true
                       fi
                       if [ -f "gyp/pylib/gyp/generator/make.py" ]; then
                       substituteInPlace "gyp/pylib/gyp/generator/make.py" \\
                         --replace 'open(output_filename' 'open(re.sub(r".*/nix/store/", "/nix/store/", output_filename)' || true
                       fi
                    `
                    : ""
                }
              ''`),
              configurePhase: "true",
              buildPhase: "true", // dont build transitive deps
              installPhase: new nijs.NixValue(
                `transitiveDepInstallPhase { inherit dependencies; pkgName = "${this.config.name}"; }`
              ),
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
