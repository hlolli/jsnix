var url = require("url");
var path = require("path");
var crypto = require("crypto");
var http = require("http");
var https = require("https");
var zlib = require("zlib");
var tar = require("tar");
var nijs = require("nijs");
var Source = require("./Source.js").Source;
var inherit = require("nijs/lib/ast/util/inherit.js").inherit;

/**
 * Constructs a new HTTPSource instance.
 *
 * @class HTTPSource
 * @extends Source
 * @classdesc Represents a dependency source that is obtained by fetching a file from an external HTTP site
 *
 * @constructor
 * @param {String} baseDir Directory in which the referrer's package.json configuration resides
 * @param {String} dependencyName Name of the dependency
 * @param {String} versionSpec Version specifier of the Node.js package to fetch
 */
function HTTPSource(baseDir, dependencyName, versionSpec) {
  Source.call(this, baseDir, dependencyName, versionSpec);
  this.identifier = dependencyName + "-" + versionSpec;
  this.baseDir = path.join(baseDir, dependencyName);
}

/* HTTPSource inherits from Source */
inherit(Source, HTTPSource);

/**
 * @see Source#fetch
 */
HTTPSource.prototype.fetch = function (callback) {
  var self = this;

  /* Determine which client to use depending on the parsed protocol */
  var parsedUrl = url.parse(self.versionSpec);
  var client;

  switch (parsedUrl.protocol) {
    case "http:":
      client = http;
      break;
    case "https:":
      client = https;
      break;
    default:
      return callback("Unsupported protocol: " + parsedUrl.protocol);
  }

  /* Request the package from the given URL */

  var request = client.get(parsedUrl.href, function (res) {
    if (res.statusCode >= 300 && res.statusCode <= 308) {
      // If a redirect has been encountered => do the same operation with the target URL
      if (!res.headers.location) {
        callback(
          "Bad HTTP response while GETting " +
            parsedUrl.href +
            " Redirect with no Location header"
        );
      } else {
        self.versionSpec = res.headers.location;
        self.fetch(callback);
      }
    } else {
      // Otherwise extract the package.json and compute the corresponding hash
      self.url = parsedUrl.href;
      process.stderr.write("fetching: " + self.url + "\n");

      var gunzip = zlib.createGunzip();
      gunzip.on("error", function (err) {
        callback("Error while gunzipping: " + err);
      });

      var tarParser = new tar.Parse();

      tarParser.on("error", function (err) {
        callback("Error while untarring: " + err);
      });
      tarParser.on("entry", function (entry) {
        if (entry.path.match(/^[^/]*\/package\.json$/)) {
          // Search for a file named package.json in the tar file
          var packageJSON = "";

          entry.on("data", function (chunk) {
            packageJSON += chunk;
          });

          entry.on("end", function () {
            self.config = JSON.parse(packageJSON);
          });
        } else {
          // For other files, simply skip them. We need these dummy callbacks because there is some kind of quirk in the API that terminates the program.
          entry.on("data", function () {});
          entry.on("end", function () {});
        }
      });

      var computeHash = crypto.createHash("sha256");

      /* Pipe gunzipped data to the tar parser */
      gunzip.pipe(tarParser).on("finish", function () {
        callback(); // Everything finished
      });

      res.on("data", function (chunk) {
        /* Retrieve data from the HTTP connection and feed it to the gunzip and hash streams */
        gunzip.write(chunk);
        computeHash.update(chunk);
      });
      res.on("end", function () {
        gunzip.end();

        self.hashType = "sha256";
        self.sha256 = computeHash.digest("hex");
      });
      res.on("error", function (err) {
        callback("Error with retrieving file from HTTP connection: " + err);
      });
    }
  });
  request.on("error", function (err) {
    callback("Error while GETting " + self.url + ": " + err);
  });
};

/**
 * @see Source#convertFromLockedDependency
 */
HTTPSource.prototype.convertFromLockedDependency = function (
  dependencyObj,
  callback
) {
  this.config = {
    name: this.dependencyName,
    version: 1,
  };

  this.url = dependencyObj.version;
  try {
    this.convertIntegrityStringToNixHash(dependencyObj.integrity);
    callback();
  } catch (err) {
    callback(err);
  }
};

/**
 * @see NixASTNode#toNixAST
 */
HTTPSource.prototype.toNixAST = function () {
  var ast = Source.prototype.toNixAST.call(this);
  var lens = ast.body !== undefined ? ast.body.paramExpr : ast;

  var paramExpr = {
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

exports.HTTPSource = HTTPSource;
