rec {
  name = "jsnix";
  version = "0.0.0-alpha1";
  description = ''
    Toolkit for making javascript package management fun again with the power of nix
  '';
  homepage = "https://github.com/hlolli/jsnix";
  type = "module";
  author = {
    name = "Hlöðver Sigurðsson";
    email = "hlolli@gmail.com";
  };
  bin = {
    jsnix = "bin/jsnix";
  };
  main = "./src/jsnix.mjs";
  dependencies = {
    base64-js = "1.5.x";
    cachedir = { version = "2.3.x"; };
    commander = "8.x";
    findit = "2.0.x";
    fs-extra = "10.x";
    git-url-parse = "11.6.x";
    micromatch = "^4.0.4";
    nijs = "0.0.25";
    npm-registry-fetch = "12.0.x";
    npmconf = "2.1.x";
    npmlog = "6.0.x";
    optparse = "1.0.x";
    rambda = "^6.9.0";
    semver = "7.3.x";
    spdx-license-ids = "3.0.x";
    tar = "6.1.x";
    web-tree-sitter = "0.19.4";
  };

  resolutions = {
    "mkdirp@*" = "mkdirp@1.0.4";
  };

  packageDerivation = { lib, nodeModules, ... }@pkgs: {
    name = "jsnix";
    nativeBuildInputs = with pkgs; [
      makeWrapper
    ];
    dontStrip = true;

    postInstall = ''
      mkdir -p $out/bin
      makeWrapper '${pkgs.nodejs}/bin/node' "$out/bin/jsnix" \
        --prefix NODE_PATH : "${nodeModules}/lib/node_modules" \
        --add-flags "$out/lib/node_modules/jsnix/bin/jsnix.mjs"
    '';
  };
  repository = {
    type = "git";
    url = "https://github.com/hlolli/jsnix";
  };
  license = "MIT";
}
