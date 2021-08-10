import { archivedPackages } from "./archived.mjs";
import { resolutions } from "./resolutions.mjs";
import semver from "semver";
import * as R from "rambda";

const mkCompatabilityPkgsNames = (kvPkgs) =>
  R.reduce(
    (acc, val) => R.assoc(R.splitAt(val.lastIndexOf("@"), val)[0], val)(acc),
    {}
  )(R.keys(kvPkgs));

const preCompatabilityPkgs = R.mergeAll([archivedPackages, resolutions]);
const preCompatabilityPkgsNames = mkCompatabilityPkgsNames(
  preCompatabilityPkgs
);

export const resolveCompat = ({
  versionSpec,
  name,
  pkgJsonResolutions = [],
}) => {
  // console.log(name);
  const allCompatabilityPkgs = R.mergeAll([
    preCompatabilityPkgs,
    pkgJsonResolutions,
  ]);
  const allCompatabilityPkgsNames = R.mergeAll([
    mkCompatabilityPkgsNames(pkgJsonResolutions),
    preCompatabilityPkgsNames,
  ]);
  if (allCompatabilityPkgsNames[name]) {
    // console.log(name, allCompatabilityPkgsNames);
    const maybeCompat = allCompatabilityPkgsNames[name];
    const badCompatVer = maybeCompat.substring(
      maybeCompat.lastIndexOf("@") + 1
    );

    // console.log(
    //   "SATISFI",
    //   name,
    //   (versionSpec || "").replace(/^\^/, ""),
    //   badCompatVer,
    //   semver.satisfies((versionSpec || "").replace(/^\^/, ""), badCompatVer)
    // );

    const compat = allCompatabilityPkgs[maybeCompat];

    const [compatName, compatVer] = R.splitAt(compat.lastIndexOf("@"), compat);
    return { versionSpec: compatVer.replace("@", ""), name: compatName };
  } else {
    return { versionSpec, name };
  }
};
