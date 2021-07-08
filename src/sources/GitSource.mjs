import base64js from "base64-js";
import child_process from "child_process";
import findit from "findit";
import fs from "fs-extra";
import nijs from "nijs";
import os from "os";
import path from "path";
import gitUrlParse from "git-url-parse";
import { Source } from "./Source.mjs";
import { getBodyLens } from "./common.mjs";

export class GitSource extends Source {
  constructor(baseDir, dependencyName, versionSpec) {
    super();
    this.rev = "";
    this.hash = "";
    this.identifier =
      (dependencyName || "") + (versionSpec ? "-" + versionSpec : "");
    this.baseDir = path.join(baseDir, dependencyName);
  }

  // composeGitURL(baseURL, parsedUrl) {
  //   const hashComponent = parsedUrl.hash || "";
  //   return baseURL + "/" + parsedUrl.host + parsedUrl.path + hashComponent;
  // }

  async fetch() {
    // console.log("checking", this.versionSpec, "identifier", this.identifier);

    if (!this.versionSpec.includes(":")) {
      this.versionSpec = "github:" + this.versionSpec;
    }

    const parsedUrl = gitUrlParse(this.versionSpec);

    /* Compose the commitIsh out of the hash suffix, if applicable */
    const commitIsh = parsedUrl.hash;

    delete parsedUrl.hash;

    const providerFixup = {
      github: "github.com",
      git: "github.com",
    };

    if (parsedUrl.pathname.includes("/tarball")) {
      parsedUrl.pathname = parsedUrl.pathname.replace(/\/tarball.*/, "");
    }

    /* Compose a Git URL out of the parsed object */
    this.url = `https://${providerFixup[parsedUrl.source] || parsedUrl.source}${
      parsedUrl.pathname
    }`;

    if (!this.url.endsWith(".git")) {
      this.url += ".git";
    }

    if (this.versionSpec.startsWith("git://")) {
      this.versionSpec = this.url;
    }

    const gitData = await new Promise((resolve, reject) => {
      let unparsedJson = "";
      let errOut = "";
      const requestedRev = commitIsh ? `--rev ${commitIsh}` : "";

      const gitPrefetch = child_process.spawn("nix-shell", [
        "-p",
        "nix-prefetch-git",
        "--command",
        `nix-prefetch-git ${this.url} --quiet ${requestedRev}`,
      ]);
      gitPrefetch.stdout.on("data", (data) => {
        unparsedJson += data;
      });
      gitPrefetch.stderr.on("data", (data) => {
        errOut += data;
      });
      gitPrefetch.on("close", (code) => {
        if (code == 0) {
          try {
            resolve(JSON.parse(unparsedJson));
          } catch (error) {
            reject(error);
          }
        } else {
          reject("git clone exited with status: " + code, errOut);
        }
      });
    }).catch(async (error) => {
      console.error(error);
      process.exit(1);
    });

    this.hash = gitData.sha256;
    this.rev = gitData.rev;
    if (fs.existsSync(path.join(gitData.path, "package.json"))) {
      this.config = JSON.parse(
        fs.readFileSync(path.join(gitData.path, "package.json"), {
          encoding: "utf-8",
        })
      );
    } else {
      this.config = { name: this.identifier };
    }
  }

  toNixAST() {
    const ast = super.toNixAST.call(this);
    const lens = getBodyLens(ast);

    lens.src = new nijs.NixFunInvocation({
      funExpr: new nijs.NixExpression("fetchgit"),
      paramExpr: {
        url: this.url,
        rev: this.rev,
        sha256: this.hash,
      },
    });

    return ast;
  }
}
