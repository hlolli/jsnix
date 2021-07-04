import fs from "fs";
import path from "path";
import { Command } from "commander";
import * as nix2json from "../src/nix-to-json.js";

const program = new Command();

const pkgJson = fs.readFileSync(path.resolve("./package.json"), {
  encoding: "utf-8",
});

program.version(pkgJson.version);

program
  .option(
    "-j, --json [path]",
    "print package.nix to stdout as parsed to package.json"
  )
  .action(async ({ json }) => await nix2json.fromFile(json));

const options = program.opts();

async function main() {
  await program.parseAsync(process.argv);
}

(async () => await main())();
