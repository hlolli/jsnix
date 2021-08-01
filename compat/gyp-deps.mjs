import * as R from "rambda";
// avoid overly common missing native gyp dependencies,
// if a top level dep has any of a given key in its
// set of dependencies, the additional information will be
// automatically appended to the derivation

const gulpHax = `runCommand "gulphax" {} ''
    mkdir -p $out/bin
    cat > $out/bin/gulp <<EOF
    #! \${stdenv.shell} -e
    true
    EOF
    chmod +x $out/bin/gulp
  ''`;

const knownNativeGypDeps = {
  canvas: {
    buildInputs: [
      "pkgs.cairo",
      "pkgs.pango",
      "pkgs.pkg-config",
      "pkgs.pixman",
      "pkgs.pcre",
    ],
    darwinBuildInputs: ["pkgs.darwin.apple_sdk.frameworks.CoreText"],
  },
  typescript: { buildInputs: [`(${gulpHax})`] },
  libpq: { buildInputs: ["pkgs.postgresql"], extraUnpack: "mkdir -p build" },
  sqlite3: { substitute: { "binding.gyp": { "<(module_name)": "sqlite3" } } },
  "better-sqlite3": {
    extraUnpack: `
     (cd deps; [[ -f "sqlite3.tar.gz" ]] && tar -xvf sqlite3.tar.gz || true)
     mkdir -p build
     touch deps/locate_sqlite3.target.mk
     touch build/locate_sqlite3.target.mk
    `,
    substitute: {
      "deps/common.gypi": {
        "'sqlite3%': '": "'sqlite3%': '${pkgs.sqlitecpp.src.outPath}",
      },
    },
  },
  bufferutil: {
    extraUnpack: "mkdir -p build",
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
    return additionalBuildDeps.join(" ");
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
    return additionalBuildDeps.join(" ");
  }
};

export const resolveExtraUnpack = (thisPkg) => {
  const allKnownDeps = R.keys(knownNativeGypDeps);
  let extraUnpackString = "";

  if (
    allKnownDeps.includes(thisPkg) &&
    knownNativeGypDeps[thisPkg].extraUnpack
  ) {
    extraUnpackString += `\n${knownNativeGypDeps[thisPkg].extraUnpack}`;
  }
  return extraUnpackString;
};

export const resolveSubstitutes = (thisPkg) => {
  const allKnownDeps = R.keys(knownNativeGypDeps);
  let substitutes = "";

  if (
    allKnownDeps.includes(thisPkg) &&
    knownNativeGypDeps[thisPkg].substitute
  ) {
    const substitute = knownNativeGypDeps[thisPkg].substitute;
    for (const file of R.keys(substitute)) {
      for (const match of R.keys(substitute[file])) {
        const quote1 = match.includes("'") ? '"' : "'";
        const quote2 = substitute[file][match].includes("'") ? '"' : "'";
        substitutes += `\nsubstituteInPlace ${file} --replace ${quote1}${match}${quote1} ${quote2}${substitute[file][match]}${quote2}`;
      }
    }
  }
  return substitutes;
};

export const resolveExtraGypInputs = (allDepNames) => {
  return {
    buildInputs: generateBuildInputsString(allDepNames),
    darwinBuildInputs: generateDarwinBuildInputsString(allDepNames),
  };
};
