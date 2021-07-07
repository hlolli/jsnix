import * as R from "rambda";

export function generatePackageJson(opts) {
  const removableKeys = ["outputDir", "baseDir", "packageDerivation"];
  const { dependencies = [] } = opts;
  const dependenciesInSpec = {};

  for (const dependencyName in dependencies) {
    const depData = dependencies[dependencyName];
    const version =
      (typeof depData === "string" ? depData : depData["version"]) || "latest";
    dependenciesInSpec[dependencyName] = version;
  }
  const pkgJson = R.pipe(
    R.assoc("dependencies", dependenciesInSpec),
    R.omit(removableKeys)
  )(opts);

  return pkgJson;
}
