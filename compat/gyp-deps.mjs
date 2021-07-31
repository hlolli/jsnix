import * as R from "rambda";
// avoid overly common missing native gyp dependencies,
// if a top level dep has any of a given key in its
// set of dependencies, the additional information will be
// automatically appended to the derivation

const knownNativeGypDeps = {
  canvas: {
    buildInputs: ["cairo", "pango", "pkg-config", "pixman", "pcre"],
    darwinBuildInputs: ["darwin.apple_sdk.frameworks.CoreText"],
  },
};

const generateBuildInputsString = (allDepNames) => {
  const allKnownDeps = R.keys(knownNativeGypDeps);
  let additionalBuildDeps = [];
  for (const dep of allKnownDeps) {
    if (allDepNames.includes(dep)) {
      additionalBuildDeps = R.concat(
        additionalBuildDeps,
        knownNativeGypDeps[dep].buildInputs || []
      );
    }
  }
  additionalBuildDeps = R.uniq(additionalBuildDeps);
  if (R.isEmpty(additionalBuildDeps)) {
    return "";
  } else {
    return additionalBuildDeps
      .map((n) => (n.startsWith("pkgs.") ? n : `pkgs.${n}`))
      .join(" ");
  }
};

const generateDarwinBuildInputsString = (allDepNames) => {
  const allKnownDeps = R.keys(knownNativeGypDeps);
  let additionalBuildDeps = [];
  for (const dep of allKnownDeps) {
    if (allDepNames.includes(dep)) {
      additionalBuildDeps = R.concat(
        additionalBuildDeps,
        knownNativeGypDeps[dep].darwinBuildInputs || []
      );
    }
  }
  additionalBuildDeps = R.uniq(additionalBuildDeps);
  if (R.isEmpty(additionalBuildDeps)) {
    return "";
  } else {
    return additionalBuildDeps
      .map((n) => (n.startsWith("pkgs.") ? n : `pkgs.${n}`))
      .join(" ");
  }
};

export const resolveExtraGypInputs = (allDepNames) => {
  return {
    buildInputs: generateBuildInputsString(allDepNames),
    darwinBuildInputs: generateDarwinBuildInputsString(allDepNames),
  };
};
