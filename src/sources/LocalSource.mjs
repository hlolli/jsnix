import fs from "fs";
import nijs from "nijs";
import path from "path";
import { Source } from "./Source.mjs";
import { getBodyLens } from "./common.mjs";

/**
 * Prevent (potentially) harmful filesystem lookups
 */
function pathIsInScope(dir) {
  const parent = path.resolve("./");
  const relative = path.relative(parent, dir);
  return relative && !relative.startsWith("..") && !path.isAbsolute(relative);
}

export class LocalSource extends Source {
  constructor(baseDir, dependencyName, outputDir, versionSpec) {
    super();
    this.outputDir = outputDir;
  }

  composeSourcePath(resolvedPath) {
    let srcPath =
      resolvedPath.substr(0, 5) === "file:"
        ? resolvedPath.substr(5)
        : resolvedPath;

    const first = this.versionSpec.substr(0, 1);

    if (first === "~" || first === "/") {
      // Path is absolute
      return this.versionSpec;
    } else {
      // Compose path relative to the output directory
      var absoluteOutputDir = path.resolve(this.outputDir);
      var absoluteSrcPath = path.resolve(absoluteOutputDir, srcPath);
      srcPath = path.relative(absoluteOutputDir, absoluteSrcPath);

      if (srcPath.substr(0, 1) !== ".") {
        srcPath = "./" + srcPath; // If a path does not start with a . prefix it, so that it is a valid path in the Nix language
      }

      return srcPath;
    }
  }

  async fetch() {
    if (
      this.isTransitive ||
      this.parent.isTransitive ||
      !pathIsInScope(this.baseDir)
    ) {
      return undefined;
    }

    process.stderr.write(
      "fetching local directory: " +
        this.versionSpec +
        " from " +
        this.baseDir +
        "\n"
    );

    const resolvedPath = path.resolve(this.baseDir, this.versionSpec);
    this.srcPath = this.composeSourcePath(resolvedPath);
    const packageJSON = fs.readFileSync(
      path.join(resolvedPath, "package.json"),
      { encoding: "utf-8" }
    );

    this.config = JSON.parse(packageJSON);
    this.identifier = this.config.name + "-" + this.versionSpec;
    this.baseDir = resolvedPath;
  }

  toNixAST() {
    const ast = this.toNixAST.call(this);
    const lens = getBodyLens(ast);

    if (this.srcPath === "./") {
      lens.src = new nijs.NixFile({ value: "./." }); // ./ is not valid in the Nix expression language
    } else if (this.srcPath === "..") {
      lens.src = new nijs.NixFile({ value: "./.." }); // .. is not valid in the Nix expression language
    } else {
      lens.src = new nijs.NixFile({ value: this.srcPath });
    }

    return ast;
  }
}
