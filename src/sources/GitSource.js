import base64js from "base64-js";
import child_process from "child_process";
import findit from "findit";
import fs from "fs-extra";
import nijs from "nijs";
import os from "os";
import path from "path";
import gitUrlParse from "git-url-parse";
import { Source } from "./Source.js";
import { getBodyLens } from "./common.js";

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
    console.log("checking", this.versionSpec, "identifier", this.identifier);

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

    const filesToDelete = [];
    const dirsToDelete = [];
    const tmpDir = path.join(
      os.tmpdir(),
      "node2nix-git-checkout-" + this.dependencyName.replace("/", "_slash_")
    );

    if (await fs.pathExists(tmpDir)) {
      await fs.remove(tmpDir);
    }
    await fs.mkdir(tmpDir);

    const cleanUp = async () => {
      for (const f of filesToDelete) {
        if (await fs.pathExists(f)) {
          await fs.remove(f);
        }
      }

      for (const d of dirsToDelete) {
        if (await fs.pathExists(d)) {
          await fs.remove(d);
        }
      }
      if (await fs.pathExists(tmpDir)) {
        await fs.remove(tmpDir);
      }
    };

    process.stderr.write("Cloning git repository: " + this.url + "\n");

    await new Promise((resolve, reject) => {
      const gitClone = child_process.spawn("git", ["clone", this.url], {
        cwd: tmpDir,
        stdio: "inherit",
      });
      gitClone.on("close", (code) => {
        if (code == 0) {
          resolve();
        } else {
          reject("git clone exited with status: " + code);
        }
      });
    }).catch(async (error) => {
      await cleanUp();
      console.error(error);
      process.exit(1);
    });

    const repositoryDir = await new Promise((resolve, reject) => {
      const finder = findit(tmpDir);
      finder.on("directory", (dir, stat) => {
        if (dir != tmpDir) {
          finder.stop();
          resolve(dir);
        }
      });

      finder.on("end", () => {
        reject("Cannot find a checkout directory in the temp folder");
      });
      finder.on("error", (err) => {
        reject(err);
      });
    }).catch(async (error) => {
      await cleanUp();
      console.error(error);
      process.exit(1);
    });

    const branch = !commitIsh ? "HEAD" : commitIsh;

    process.stderr.write("Parsing the revision of commitish: " + branch + "\n");

    /* Check whether the given commitish corresponds to a hash */
    await new Promise((resolve, reject) => {
      const gitRevParse = child_process.spawn("git", ["rev-parse", branch], {
        cwd: repositoryDir,
      });

      gitRevParse.stdout.on("data", (data) => {
        this.rev += data;
      });
      gitRevParse.stderr.on("data", (data) => {
        process.stderr.write(data);
      });
      gitRevParse.on("close", (code) => {
        if (code !== 0) this.rev = ""; // If git rev-parse fails, we consider the commitIsh a branch/tag.
        resolve();
      });
    });

    if (!this.rev) {
      /* Some powerusers like Sindre Sorhus have renamed master to main, so let's give the default branch a try */
      await new Promise((resolve, reject) => {
        const gitRevParse = child_process.spawn("git", ["rev-parse", "HEAD"], {
          cwd: repositoryDir,
        });

        gitRevParse.stdout.on("data", (data) => {
          this.rev += data;
        });
        gitRevParse.stderr.on("data", (data) => {
          process.stderr.write(data);
        });
        gitRevParse.on("close", (code) => {
          resolve();
        });
      });
    }

    if (!this.rev) {
      cleanUp();
      console.warn(`Couldn't resolve specified git revision from ${this.url}`);
      process.exit(1);
    }

    /* When we have resolved a revision, do a checkout of it */
    this.rev = this.rev.substr(0, this.rev.length - 1);

    process.stderr.write("Checking out revision: " + this.rev + "\n");

    /* Check out the corresponding revision */
    await new Promise((resolve, reject) => {
      const gitCheckout = child_process.spawn("git", ["checkout", this.rev], {
        cwd: repositoryDir,
        stdio: "inherit",
      });

      gitCheckout.on("close", function (code) {
        if (code === 0) {
          resolve();
        } else {
          reject("git checkout exited with status: " + code);
        }
      });
    }).catch(async (error) => {
      await cleanUp();
      console.error(error);
      process.exit(1);
    });

    /* Initialize all sub modules */
    process.stderr.write("Initializing git sub modules\n");

    await new Promise((resolve, reject) => {
      const gitSubmoduleUpdate = child_process.spawn(
        "git",
        ["submodule", "update", "--init", "--recursive"],
        {
          cwd: repositoryDir,
          stdio: "inherit",
        }
      );

      gitSubmoduleUpdate.on("close", (code) => {
        if (code == 0) {
          resolve();
        } else {
          reject("git submodule exited with status: " + code);
        }
      });
    }).catch(async (error) => {
      await cleanUp();
      console.error(error);
      process.exit(1);
    });

    try {
      this.config = JSON.parse(
        await fs.readFile(path.join(repositoryDir, "package.json"))
      );
    } catch (error) {
      await cleanUp();
      console.error(`Couldn't parse package.json ${error}`);
      process.exit(1);
    }

    await new Promise((resolve, reject) => {
      const finder = findit(repositoryDir);
      finder.on("directory", (dir, stat) => {
        const base = path.basename(dir);
        if (base == ".git") {
          dirsToDelete.push(dir);
        }
      });
      finder.on("file", (file, stat) => {
        const base = path.basename(file);
        if (base == ".git") {
          filesToDelete.push(file);
        }
      });
      finder.on("end", () => {
        resolve();
      });
      finder.on("error", (err) => {
        reject(err);
      });
    }).catch(async (error) => {
      await cleanUp();
      console.error(error);
      process.exit(1);
    });

    try {
      this.config = JSON.parse(
        fs.readFileSync(path.join(repositoryDir, "package.json"))
      );
    } catch (error) {
      await cleanUp();
      console.error(`Couldn't parse package.json ${error}`);
      process.exit(1);
    }

    await new Promise((resolve, reject) => {
      const nixHash = child_process.spawn("nix-hash", [
        "--type",
        "sha256",
        repositoryDir,
      ]);

      nixHash.stdout.on("data", (data) => {
        this.hash += data;
      });
      nixHash.stderr.on("data", (data) => {
        process.stderr.write(data);
      });
      nixHash.on("close", (code) => {
        if (code == 0) {
          resolve();
        } else {
          reject("nix-hash exited with status: " + code);
        }
      });
    }).catch(async (error) => {
      await cleanUp();
      console.error(error);
      process.exit(1);
    });
  }

  toNixAST() {
    const ast = super.toNixAST.call(this);
    const lens = getBodyLens(ast);

    lens.src = new nijs.NixFunInvocation({
      funExpr: new nijs.NixExpression("fetchgit"),
      paramExpr: {
        url: this.url,
        rev: this.rev,
        sha256: this.hash.substr(0, this.hash.length - 1),
      },
    });

    return ast;
  }
}
