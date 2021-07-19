{ pkgs, buildGoModule }:

buildGoModule rec {
  pname = "flatten";
  version = "0.0.0";
  vendorSha256 = "sha256-pQpattmS9VmO3ZIQUFn66az8GSmB4IvYhTTCFn6SUmo="; # pkgs.lib.fakeSha256;
  src = /Users/hlodversigurdsson/forks/jsnix/go;
  preBuild = ''
    mkdir -p go
    mv flatten* go
    mv go.mod go
    mkdir -p .git
    cd go
  '';

}
