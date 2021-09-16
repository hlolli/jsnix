jsnix
========

jsnix is a hacky hammer where the goal is to make complex modern nodejs modules management "just work" with nix.
It uses nomenclature from nodejs for not particular reason, other than to make it easier to understand for non-nix users.
The important addition to jsnix is the ability to tap into the build and patch any misbehaving dependency.
Other goals are:

* workspaces support
* build-time package resolution of workspace modules (think yarn workspaces install vs lerna install)
* top-level node application support (e.g. you need tsc/prettier executables in your environment)
* built-in compatability patches (some community hacks are inherently incompatible with nix, example: resolve-from and resolve-cwd)

## install

`user profile`

```nix
nix-env -f https://github.com/hlolli/jsnix/archive/master.tar.gz -i
```

`flake`

```nix
inputs = {
  ....
  jsnix.url = "github:hlolli/jsnix";
  jsnix.inputs.nixpkgs.follows = "nixpkgs";
  ...
};
```

## quick start

```nix
# make a package.nix
{
  dependencies = {
    hello-world-npm = "1.1.1";
  };
}
```

```sh
# generate the importable nix-expression (by default package-lock.nix)
$ jsnix install
```

```nix
# import the package and pass pkgs (ex. in overlay file) and profit
final: prev: {
    hello-world-npm = (import ./package-lock.nix prev).hello-world-npm;
}
```

```nix
# or shell.nix
{ pkgs ? import <nixpkgs> {} }:

let myNodePackages = (import ./package-lock.nix prev);
    hello-world-npm = myNodePackages.hello-world-npm;
in pkgs.mkShell {
  buildInputs = [
    hello-world-npm
  ];
}
```

When installed, jsnix will read the "bin" field of package.json and symlink it to $out/bin.

```sh
$ hello-world-npm
Hello World NPM
```

## package.nix

The package.nix file is a kind of mirror of the traditional package.json. The file itself is evaluated with nix and exported
to package.json (when building a new node project) and all extra fields declared in package.nix will be included in package.json.

Example:

```nix
{
  name = "my-module";
  main = "index.js";
  bin = {
    my-module = "./bin.js";
  };
}
```


becomes

```json
{
  "name": "my-module",
  "main": "index.js",
  "bin": {
    "my-module": "./bin.js"
  }
}
```

In jsnix the purpose of package.nix can be split in two categories.

One category is the consumption of node packages, where you just want to use a node package which already exists.
Which means 9/10 you are dealing with pre-compiled node modules. In rare cases, the module will get build on npm install hook,
which is commonly the case with node-gyp. That almost always forces one to either include extra build dependencies and-or
custom patching to support the package build. Other than that, with jsnix's opinionated and aggressive approach to include all transient
dependencies (which equates to hundred if not thousands of derivations generated), the requested module should work out of the box
(most of the time). The quickstart example above is one example of this.

The other category of package.nix is to build and publish a new js package. A special attribute is used to declare a new node package
as nix-derivation; `packageDerivation`, which gets passed all of pkgs along with other helpful attributes. A care must be taken
to include the required fields of any node package like name, main and version.

License
=======
The contents of this package is available under the
[MIT license](http://opensource.org/licenses/MIT)

Acknowledgements
================
This package started out as a fork of [node2nix](https://github.com/svanderburg/node2nix)
In turn, node2nix is based on ideas and principles pioneered in
[npm2nix](http://github.com/NixOS/npm2nix).
