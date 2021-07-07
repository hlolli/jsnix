import { archivedPackages } from "./archived.mjs";
import { resolutions } from "./resolutions.mjs";
import semver from "semver";
import * as R from "rambda";

const allCompatabilityPkgs = R.mergeAll([archivedPackages, resolutions]);
const allCompatabilityPkgsNames = R.reduce(
  (acc, val) => R.assoc(val.split(/@|#/)[0], val)(acc),
  {}
)(R.keys(allCompatabilityPkgs));

export const resolveCompat = ({ versionSpec, name }) => {
  if (allCompatabilityPkgsNames[name]) {
    const maybeCompat = allCompatabilityPkgsNames[name];
    const badCompatVer = maybeCompat.split("@")[1];
    console.log(
      "SATISFI",
      (versionSpec || "").replace(/^\^/, ""),
      badCompatVer,
      semver.satisfies(
        (versionSpec || "").replace(/^\^/, ""),
        badCompatVer,
        true
      )
    );
    if (
      badCompatVer === "*" ||
      badCompatVer === versionSpec ||
      semver.satisfies(
        (versionSpec || "").replace(/^\^/, ""),
        badCompatVer,
        true
      )
    ) {
      const compat = allCompatabilityPkgs[maybeCompat];
      const [compatName, compatVer] = compat.split("@");
      return { versionSpec: compatVer, name: compatName };
    } else {
      return { versionSpec, name };
    }
  } else {
    return { versionSpec, name };
  }
};
