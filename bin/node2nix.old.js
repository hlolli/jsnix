#!/usr/bin/env node

var fs = require("fs");
var path = require("path");
var optparse = require("optparse");
var node2nix = require("../lib/node2nix.js");
var Registry = require("../lib/Registry.js").Registry;

/* Define command-line options */

var switches = [
  ["-h", "--help", "Shows help sections"],
  ["-v", "--version", "Shows version"],
  [
    "-i",
    "--input FILE",
    "Specifies a path to a JSON file containing an object with package settings or an array of dependencies (defaults to: package.json)",
  ],
  [
    "-o",
    "--output FILE",
    "Path to a Nix expression representing a registry of Node.js packages (defaults to: node-packages.nix)",
  ],
  [
    "-c",
    "--composition FILE",
    "Path to a Nix composition expression allowing someone to deploy the generated Nix packages from the command-line (defaults to: default.nix)",
  ],
  [
    "-e",
    "--node-env FILE",
    "Path to the Nix expression implementing functions that builds NPM packages (defaults to: node-env.nix)",
  ],
  [
    "-l",
    "--lock FILE",
    "Path to the package-lock.json file that pinpoints the variants of all dependencies",
  ],
  [
    "-d",
    "--development",
    "Specifies whether to do a development (non-production) deployment for a package.json deployment (false by default)",
  ],
  [
    "-4",
    "--nodejs-4",
    "Provides all settings to generate expression for usage with Node.js 4.x (default is: Node.js 12.x)",
  ],
  [
    "-6",
    "--nodejs-6",
    "Provides all settings to generate expression for usage with Node.js 6.x (default is: Node.js 12.x)",
  ],
  [
    "-8",
    "--nodejs-8",
    "Provides all settings to generate expression for usage with Node.js 8.x (default is: Node.js 12.x)",
  ],
  [
    "-10",
    "--nodejs-10",
    "Provides all settings to generate expression for usage with Node.js 10.x (default is: Node.js 12.x)",
  ],
  [
    "-12",
    "--nodejs-12",
    "Provides all settings to generate expression for usage with Node.js 12.x (default is: Node.js 12.x)",
  ],
  [
    "-13",
    "--nodejs-13",
    "Provides all settings to generate expression for usage with Node.js 13.x (default is: Node.js 12.x)",
  ],
  [
    "-14",
    "--nodejs-14",
    "Provides all settings to generate expression for usage with Node.js 14.x (default is: Node.js 12.x)",
  ],
  [
    "--supplement-input FILE",
    "A supplement package JSON file that are passed as build inputs to all packages defined in the input JSON file",
  ],
  [
    "--supplement-output FILE",
    "Path to a Nix expression representing a supplementing set of Nix packages provided as inputs to a project (defaults to: supplement.nix)",
  ],
  [
    "--include-peer-dependencies",
    "Specifies whether to include peer dependencies. In npm 2.x, this is the default. (false by default)",
  ],
  [
    "--no-flatten",
    "Simulate pre-npm 3.x isolated dependency structure. (false by default)",
  ],
  [
    "--pkg-name NAME",
    "Specifies the name of the Node.js package to use from Nixpkgs (defaults to: nodejs)",
  ],
  [
    "--registry URL",
    "URL referring to the NPM packages registry. It defaults to the official NPM one, but can be overridden to support private registries",
  ],
  ["--registry-scope SCOPE", "scoped package"],
  [
    "--registry-auth-token TOKEN",
    "An optional token to access private NPM registry",
  ],
  [
    "--use-impure-npm-cache",
    "Specifies that node2nix expression generator should cache the packages fetched from npm. Should only be used while configuring new dependencies.",
  ],
  [
    "--no-bypass-cache",
    "Specifies that package builds do not need to bypass the content addressable cache (required for NPM 5.x)",
  ],
  [
    "--no-copy-node-env",
    "Do not create a copy of the Nix expression that builds NPM packages",
  ],
  [
    "--use-fetchgit-private",
    "Use fetchGitPrivate instead of fetchgit in the generated Nix expressions",
  ],
  [
    "--strip-optional-dependencies",
    "Strips the optional dependencies from the regular dependencies in the NPM registry",
  ],
];

var parser = new optparse.OptionParser(switches);

/* Set some variables and their default values */

var help = false;
var version = false;
var production = true;
var includePeerDependencies = false;
var flatten = true;
var inputJSON = "package.json";
var outputNix = "node-packages.nix";
var compositionNix = "default.nix";
var supplementJSON;
var supplementNix = "supplement.nix";
var nodeEnvNix = "node-env.nix";
var lockJSON;
var registries = [];
var nodePackage = "nodejs-12_x";
var useImpureNpmCache = false;
var noCopyNodeEnv = false;
var bypassCache = true;
var useFetchGitPrivate = false;
var stripOptionalDependencies = false;
var executable;

/* Define process rules for option parameters */

parser.on("help", function (arg, value) {
  help = true;
});

parser.on("version", function (arg, value) {
  version = true;
});

parser.on("input", function (arg, value) {
  inputJSON = value;
});

parser.on("output", function (arg, value) {
  outputNix = value;
});

parser.on("composition", function (arg, value) {
  compositionNix = value;
});

parser.on("supplement-input", function (arg, value) {
  supplementJSON = value;
});

parser.on("supplement-output", function (arg, value) {
  supplementNix = value;
});

parser.on("node-env", function (arg, value) {
  nodeEnvNix = value;
});

parser.on("lock", function (arg, value) {
  if (value) {
    lockJSON = value;
  } else {
    lockJSON = "package-lock.json";
  }
});

parser.on("development", function (arg, value) {
  production = false;
});

parser.on("nodejs-4", function (arg, value) {
  flatten = false;
  nodePackage = "nodejs-4_x";
  byPassCache = false;
});

parser.on("nodejs-6", function (arg, value) {
  flatten = true;
  nodePackage = "nodejs-6_x";
  byPassCache = false;
});

parser.on("nodejs-8", function (arg, value) {
  flatten = true;
  nodePackage = "nodejs-8_x";
  bypassCache = true;
});

parser.on("nodejs-10", function (arg, value) {
  flatten = true;
  nodePackage = "nodejs-10_x";
  bypassCache = true;
});

parser.on("nodejs-12", function (arg, value) {
  flatten = true;
  nodePackage = "nodejs-12_x";
  bypassCache = true;
});

parser.on("nodejs-13", function (arg, value) {
  flatten = true;
  nodePackage = "nodejs-13_x";
  bypassCache = true;
});

parser.on("nodejs-14", function (arg, value) {
  flatten = true;
  nodePackage = "nodejs-14_x";
  bypassCache = true;
});

parser.on("include-peer-dependencies", function (arg, value) {
  includePeerDependencies = true;
});

parser.on("no-flatten", function (arg, value) {
  flatten = false;
});

parser.on("pkg-name", function (arg, value) {
  nodePackage = value;
});

var registryIndex = -1;
parser.on("registry", function (arg, value) {
  registries.push(new Registry(value));
  registryIndex++;
});

parser.on("registry-auth-token", function (arg, value) {
  registries[registryIndex].authToken = value;
});

parser.on("registry-scope", function (arg, value) {
  registries[registryIndex].scope = value;
});

parser.on("use-impure-npm-cache", function (arg, value) {
  useImpureNpmCache = true;
});

parser.on("no-bypass-cache", function (arg, value) {
  bypassCache = false;
});

parser.on("no-copy-node-env", function (arg, value) {
  noCopyNodeEnv = true;
});

parser.on("use-fetchgit-private", function (arg, value) {
  useFetchGitPrivate = true;
});

parser.on("strip-optional-dependencies", function (arg, value) {
  stripOptionalDependencies = true;
});

/* Define process rules for non-option parameters */

parser.on(1, function (opt) {
  executable = opt;
});

/* Do the actual command-line parsing */

parser.parse(process.argv);

/* Display the help, if it has been requested */

if (help) {
  function displayTab(len, maxlen) {
    for (var i = 0; i < maxlen - len; i++) {
      process.stdout.write(" ");
    }
  }

  process.stdout.write("Usage: " + executable + " [OPTION]\n\n");

  process.stdout.write(
    "Generates a set of Nix expressions from a NPM package's package.json\n"
  );
  process.stdout.write(
    "configuration or a collection.json configuration containing a set of NPM\n"
  );
  process.stdout.write(
    "dependency specifiers so that the packages can be deployed with Nix instead\n"
  );
  process.stdout.write("of NPM.\n\n");

  process.stdout.write("Options:\n");

  var maxlen = 30;

  for (var i = 0; i < switches.length; i++) {
    var currentSwitch = switches[i];

    process.stdout.write("  ");

    if (currentSwitch.length == 3) {
      process.stdout.write(currentSwitch[0] + ", " + currentSwitch[1]);
      displayTab(currentSwitch[0].length + 2 + currentSwitch[1].length, maxlen);
      process.stdout.write(currentSwitch[2]);
    } else {
      process.stdout.write(currentSwitch[0]);
      displayTab(currentSwitch[0].length, maxlen);
      process.stdout.write(currentSwitch[1]);
    }

    process.stdout.write("\n");
  }

  process.exit(0);
}

/* Display the version, if it has been requested */

if (version) {
  var version = JSON.parse(
    fs.readFileSync(path.join(__dirname, "..", "package.json"))
  ).version;

  process.stdout.write("node2nix " + version + "\n");
  process.exit(0);
}

if (registries.length == 0) {
  registries.push(new Registry("https://registry.npmjs.org"));
}

/* Perform the NPM to Nix conversion */
node2nix.npmToNix(
  inputJSON,
  outputNix,
  compositionNix,
  nodeEnvNix,
  lockJSON,
  supplementJSON,
  supplementNix,
  production,
  includePeerDependencies,
  flatten,
  nodePackage,
  registries,
  noCopyNodeEnv,
  useImpureNpmCache,
  bypassCache,
  useFetchGitPrivate,
  stripOptionalDependencies,
  function (err) {
    if (err) {
      // process.stderr.write(err + "\n");
      throw new Error(err);
      process.exit(1);
    } else {
      process.exit(0);
    }
  }
);

function npmToNix(
  inputJSON,
  outputNix,
  compositionNix,
  nodeEnvNix,
  lockJSON,
  supplementJSON,
  supplementNix,
  production,
  includePeerDependencies,
  flatten,
  nodePackage,
  registries,
  noCopyNodeEnv,
  useImpureNpmCache,
  bypassCache,
  useFetchGitPrivate,
  stripOptionalDependencies,
  callback
) {
  var obj = JSON.parse(fs.readFileSync(inputJSON));
  var version = JSON.parse(
    fs.readFileSync(path.join(__dirname, "..", "package.json"))
  ).version;
  var disclaimer =
    "# This file has been generated by node2nix " +
    version +
    ". Do not edit!\n\n";
  var outputDir = path.dirname(outputNix);
  var baseDir = path.dirname(inputJSON);

  var lock;

  if (lockJSON !== undefined) {
    lock = JSON.parse(fs.readFileSync(lockJSON));
  }

  var deploymentConfig = new DeploymentConfig(
    registries,
    production,
    includePeerDependencies,
    flatten,
    nodePackage,
    outputDir,
    useImpureNpmCache,
    bypassCache,
    stripOptionalDependencies
  );
  var expr;

  var displayLockWarning = false;

  slasp.sequence(
    [
      /* Generate a Nix expression */
      function (callback) {
        if (typeof obj == "object" && obj !== null) {
          if (Array.isArray(obj)) {
            expr = new CollectionExpression(deploymentConfig, baseDir, obj);
          } else {
            // Display error if mandatory package.json attributes are not set
            if (!obj.name) {
              return callback(
                "Mandatory name attribute is missing in package.json"
              );
            } else if (!obj.version) {
              return callback(
                "Mandatory version attribute is missing in package.json"
              );
            }

            // Parse package.json
            expr = new PackageExpression(
              deploymentConfig,
              lock,
              baseDir,
              obj.name,
              baseDir
            );

            // Display a warning if we expect a lock file to be used, but the user does not specify it
            displayLockWarning =
              bypassCache &&
              !lockJSON &&
              fs.existsSync(
                path.join(
                  path.dirname(inputJSON),
                  path.basename(inputJSON, ".json")
                ) + "-lock.json"
              );
          }

          expr.resolveDependencies(callback);
        } else {
          callback(
            "The provided JSON file must consist of an object or an array"
          );
        }
      },

      /* Write the output Nix expression to the specified output file */
      function (callback) {
        fs.writeFile(
          outputNix,
          disclaimer + nijs.jsToNix(expr, true) + "\n",
          callback
        );
      },

      function (callback) {
        /* Generate the supplement Nix expression, if specified */
        if (supplementJSON) {
          var obj = JSON.parse(fs.readFileSync(supplementJSON));

          if (Array.isArray(obj)) {
            expr = new CollectionExpression(deploymentConfig, baseDir, obj);
            expr.resolveDependencies(callback);
          } else {
            callback("The supplement JSON file should be an array");
          }
        } else {
          expr = undefined;
          callback();
        }
      },

      function (callback) {
        if (expr === undefined) {
          callback();
        } else {
          /* Write the supplement Nix expression to the specified output file */
          fs.writeFile(
            supplementNix,
            disclaimer + nijs.jsToNix(expr, true) + "\n",
            callback
          );
        }
      },

      function (callback) {
        if (noCopyNodeEnv) {
          callback();
        } else {
          /* Copy the node-env.nix expression */
          copyNodeEnvExpr(nodeEnvNix, callback);
        }
      },

      /* Generate and write a Nix composition expression to the specified output file */
      // function (callback) {
      //   expr = new CompositionExpression(
      //     compositionNix,
      //     nodePackage,
      //     nodeEnvNix,
      //     outputNix,
      //     supplementNix,
      //     supplementJSON !== undefined,
      //     useFetchGitPrivate
      //   );
      //   fs.writeFile(
      //     compositionNix,
      //     disclaimer + nijs.jsToNix(expr, true) + "\n",
      //     callback
      //   );
      // },

      function (callback) {
        /* Display warnings that helps the user with some common mistakes */
        if (displayLockWarning) {
          console.log(
            "\nWARNING: A lock file exists in the repository, yet it is not used in the generation process!"
          );
          console.log("As a result, the deployment of the project may fail.");
          console.log(
            "You probably want to run node2nix with the -l option to use the lock file!"
          );
        }

        if (
          !Array.isArray(obj) &&
          fs.existsSync(path.join(baseDir, "node_modules"))
        ) {
          console.log(
            "\nWARNING: There is a node_modules/ folder in the root directory of the project!"
          );
          console.log(
            "These packages will be included in the Nix build and influence the outcome."
          );
          console.log(
            "If you don't want this to happen, then you should remove it before running any"
          );
          console.log("of the Nix commands!");
        }
        callback();
      },
    ],
    callback
  );
}
