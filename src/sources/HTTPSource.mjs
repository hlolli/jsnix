import crypto from "crypto";
import http from "http";
import https from "https";
import nijs from "nijs";
import path from "path";
import tar from "tar";
import url from "url";
import zlib from "zlib";
import { getBodyLens } from "./common.mjs";
import { Source } from "./Source.mjs";

export class HTTPSource extends Source {
  constructor(baseDir, dependencyName, versionSpec) {
    super();
    this.identifier = dependencyName + "-" + versionSpec;
    this.baseDir = path.join(baseDir, dependencyName);
  }

  async fetch() {
    const parsedUrl = url.parse(this.versionSpec);
    let client;

    switch (parsedUrl.protocol) {
      case "http:":
        client = http;
        break;
      case "https:":
        client = https;
        break;
      default:
        console.error("Unsupported protocol: " + parsedUrl.protocol);
        process.exit(1);
    }

    await new Promise((resolve, reject) => {
      /* Request the package from the given URL */
      const request = client.get(parsedUrl.href, async (res) => {
        if (res.statusCode >= 300 && res.statusCode <= 308) {
          // If a redirect has been encountered => do the same operation with the target URL
          if (!res.headers.location) {
            console.error(
              "Bad HTTP response while GETting " +
                parsedUrl.href +
                " Redirect with no Location header"
            );
            process.exit(1);
          } else {
            this.versionSpec = res.headers.location;
            await this.fetch();
          }
        } else {
          // Otherwise extract the package.json and compute the corresponding hash
          this.url = parsedUrl.href;
          process.stderr.write("fetching: " + this.url + "\n");

          const gunzip = zlib.createGunzip();

          gunzip.on("error", (err) => {
            reject("Error while gunzipping: " + err);
          });

          const tarParser = new tar.Parse();

          tarParser.on("error", function (err) {
            reject("Error while untarring: " + err);
          });

          tarParser.on("entry", (entry) => {
            if (entry.path.match(/^[^/]*\/package\.json$/)) {
              // Search for a file named package.json in the tar file
              var packageJSON = "";

              entry.on("data", (chunk) => {
                packageJSON += chunk;
              });

              entry.on("end", () => {
                this.config = JSON.parse(packageJSON);
              });
            } else {
              // For other files, simply skip them. We need these dummy callbacks because there is some kind of quirk in the API that terminates the program.
              entry.on("data", () => {});
              entry.on("end", () => {});
            }
          });

          var computeHash = crypto.createHash("sha256");

          /* Pipe gunzipped data to the tar parser */
          gunzip.pipe(tarParser).on("finish", () => {
            resolve(); // Everything finished
          });

          res.on("data", (chunk) => {
            /* Retrieve data from the HTTP connection and feed it to the gunzip and hash streams */
            gunzip.write(chunk);
            computeHash.update(chunk);
          });
          res.on("end", () => {
            gunzip.end();

            this.hashType = "sha256";
            this.sha256 = computeHash.digest("hex");
          });

          res.on("error", (err) => {
            reject("Error with retrieving file from HTTP connection: " + err);
          });
        }
      });
      request.on("error", function (err) {
        reject("Error while GETting " + this.url + ": " + err);
      });
    }).catch((error) => {
      console.error(error);
      process.exit(1);
    });
  }

  toNixAST = function () {
    const ast = this.toNixAST.call(this);
    const lens = getBodyLens(ast);

    const paramExpr = {
      name:
        path.basename(this.config.name) + "-" + this.config.version + ".tar.gz",
      url: this.url,
    };

    switch (this.hashType) {
      case "sha256":
        paramExpr["sha256"] = this.sha256;
        break;
      case "sha512":
        paramExpr["sha512"] = this.sha512;
        break;
      case "sha1":
        paramExpr["sha1"] = this.sha1;
        break;
      default:
        throw "Unknown hash type: " + this.hashType;
    }

    lens.src = new nijs.NixFunInvocation({
      funExpr: new nijs.NixExpression("fetchurl"),
      paramExpr: paramExpr,
    });

    return ast;
  };
}
