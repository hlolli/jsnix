import fs from "fs";
import path from "path";
import { Command } from "commander";
import * as nix2json from "../src/nix-to-json.mjs";
import { generatePackageJson } from "../src/generate-package-json.mjs";
import jsnix from "../src/jsnix.mjs";

const program = new Command();

program.usage("command [options]");

const install = new Command("install");

install.usage("[path]");

install.argument("[path]");

install.option("--no-cache", "ignore the cache and fetch every single package");

install.option("--cache <mode>", "verify", "always");

install.option("--revalidate-cache", "revalidate the cache if old");

install.description(
  "Resolves the dependencies in package.nix and (re)generates package-lock.nix"
);

install.alias("i");

install.action(
  async (packageNixPath = "./package.nix", opt) =>
    // console.log(opt) ||
    // process.exit(1) ||
    await jsnix({
      ...(await nix2json.fromFile(packageNixPath)),
      outputDir: path.dirname(path.resolve("./", packageNixPath)),
      baseDir: path.dirname(path.resolve("./", packageNixPath)),
      opt,
    })
);

const debug = new Command("debug");

const pkgJsonCommand = new Command("package-json");

const pkgNix = fs.readFileSync(path.resolve("./package.nix"), {
  encoding: "utf-8",
});

program.addCommand(install);
program.addCommand(debug);
program.addCommand(pkgJsonCommand);

debug
  .command(
    "-j, --json [path]",
    "print package.nix to stdout as parsed to package.json"
  )
  .action(async ({ json }) => await nix2json.fromFile(json));

const options = program.opts();

async function main() {
  const pkgJson = await nix2json.fromString(pkgNix);

  pkgJsonCommand.action((opts) =>
    console.log(JSON.stringify(generatePackageJson(pkgJson), null, 2))
  );

  program.version(pkgJson.version);

  const result = await program.parseAsync(process.argv);
}

(async () => await main())();
