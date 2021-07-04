import fs from "fs";
import path from "path";
import { Command } from "commander";
import * as nix2json from "../src/nix-to-json.js";
import { jsnix } from "../src/jsnix.js";

const program = new Command();

program.usage("command [options]");

const install = new Command("install");

install.usage("[path]");

install.argument("[path]");

install.description(
  "Resolves the dependencies in package.nix and (re)generates package-lock.nix"
);

install.alias("i");

install.action(
  async (packageNixPath) =>
    await jsnix({
      ...(await nix2json.fromFile(packageNixPath)),
      outputDir: path.dirname(path.resolve("./", packageNixPath)),
      baseDir: path.dirname(path.resolve("./", packageNixPath)),
    })
);

const debug = new Command("debug");

program.addCommand(install);
program.addCommand(debug);

const pkgJson = fs.readFileSync(path.resolve("./package.json"), {
  encoding: "utf-8",
});

program.version(pkgJson.version);

// program
//   .option(
//     "i, install [path]",
//     "resolves the dependencies in package.nix and (re)generates package-lock.nix"
//   )
//   .action(async (pick) => console.log("pick", pick));

debug
  .command(
    "-j, --json [path]",
    "print package.nix to stdout as parsed to package.json"
  )
  .action(async ({ json }) => await nix2json.fromFile(json));

const options = program.opts();

async function main() {
  await program.parseAsync(process.argv);
}

(async () => await main())();
