import fs from "fs";
import fsPromise from "fs/promises";
import { remove } from "fs-extra";
import child_process from "child_process";
import path from "path";
import os from "os";
import { fileURLToPath } from "url";
import Parser from "../wasm/tree-sitter.cjs";
import * as R from "rambda";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const fileExists = async (path) =>
  !!(await fsPromise.stat(path).catch((e) => false));

function treeToJson(treeCursor, context = { out: {} }, treePath = []) {
  const {
    nodeType,
    nodeText,
    nodeIsNamed,
    startPosition,
    endPosition,
    startIndex,
    endIndex,
  } = treeCursor;

  // console.log({
  //   treePath,
  //   nodeType,
  //   nodeText,
  //   nodeIsNamed,
  //   startPosition,
  //   endPosition,
  //   startIndex,
  //   endIndex,
  // });

  switch (nodeType) {
    case "ERROR": {
      return "error";
      break;
    }
    case "source_expression":
    case "select":
    case "attrset": {
      if (treeCursor.gotoFirstChild()) {
        return treeToJson(treeCursor, context, treePath);
      }
      break;
    }

    case "app":
    case "function":
    case ";": {
      if (treeCursor.gotoParent() && treeCursor.gotoNextSibling()) {
        return treeToJson(treeCursor, context, R.dropLast(1, treePath));
      }
      // if (treeCursor.gotoNextSibling()) {
      //   return treeToJson(treeCursor, context, treePath);
      // } else
      break;
    }
    case "spath":
    case "}": {
      if (treeCursor.gotoParent() && treeCursor.gotoNextSibling()) {
        return treeToJson(
          treeCursor,
          context,
          nodeType === "spath" ? R.dropLast(1, treePath) : treePath
        );
      }
      break;
    }

    case "comment":
    case "formals":
    case ":":
    case "{": {
      if (treeCursor.gotoNextSibling()) {
        return treeToJson(treeCursor, context, treePath);
      }
      break;
    }
    case "bind": {
      const ctx = R.pipe(R.assoc("isBinding", true))(context);
      if (treeCursor.gotoFirstChild()) {
        return treeToJson(treeCursor, ctx, treePath);
      }
      break;
    }
    case "attrpath": {
      if (treeCursor.nodeText === "packageDerivation") {
        if (treeCursor.gotoParent() && treeCursor.gotoNextSibling()) {
          return treeToJson(treeCursor, context, R.dropLast(1, treePath));
        }
      }
      const tp = R.pipe(
        R.when(
          () => context.isBinding,
          (c) => R.append((treeCursor.nodeText || "").replace(/"/g, ""), c)
        )
      )(treePath);
      const ctx = R.pipe(R.assoc("isBinding", false))(context);
      if (treeCursor.gotoNextSibling()) {
        return treeToJson(treeCursor, ctx, tp);
      }
      break;
    }

    case "identifier":
    case "string":
    case "list":
    case "indented_string": {
      const tp = R.pipe(
        R.when(
          () => context.isBinding,
          (c) =>
            R.append(
              JSON.parse(
                nodeType === "list"
                  ? `"'${treeCursor.nodeText}'"`
                  : treeCursor.nodeText
              ),
              c
            )
        )
      )(treePath);
      const ctx = R.pipe(
        R.when(R.prop("isAssigning"), (c) =>
          R.assocPath(
            ["out"].concat(tp),
            nodeType === "list"
              ? `"'${treeCursor.nodeText}'"` // FIXME
              : nodeType === "indented_string"
              ? treeCursor.nodeText.replace(/''/g, "").replace(/\n/g, "").trim()
              : JSON.parse(treeCursor.nodeText),
            c
          )
        ),
        R.assoc("isBinding", false),
        R.assoc("isAssigning", false)
      )(context);
      if (treeCursor.gotoNextSibling()) {
        return treeToJson(treeCursor, ctx, tp);
      }
      break;
    }
    case "=": {
      const ctx = R.pipe(
        R.assoc("isBinding", false),
        R.assoc("isAssigning", true)
      )(context);

      if (treeCursor.gotoNextSibling()) {
        return treeToJson(treeCursor, ctx, treePath);
      }
      break;
    }
  }

  return context.out;
}
async function initParser() {
  await Parser.init();
  const parser = new Parser();
  const Nix = await Parser.Language.load(
    path.resolve(__dirname, "../wasm/tree-sitter-nix.wasm")
  );
  parser.setLanguage(Nix);
  return parser;
}

async function evalNixExpr(pathFrom, outsJson = false) {
  const suffix = outsJson ? " --json" : " ";
  return new Promise(async (resolve) => {
    child_process.exec(
      `nix eval ${suffix} -f "${pathFrom}"`,
      (err, stdout, stderr) => {
        resolve([
          (stdout || "")
            .replace(/[^\"]<LAMBDA>/g, '"<LAMBDA>"')
            .replace(/\\\\/g, "\\"),
          stderr,
        ]);
      }
    );
  });
}

export async function fromString(jsonString) {
  let parser;
  try {
    parser = await initParser();
  } catch (error) {
    console.error("Error while initializing wasm", error);
    process.exit(1);
  }

  const tree = parser.parse(jsonString);
  const json = treeToJson(tree.rootNode.walk());
  return json;
}

export async function fromFile(userPath) {
  const tmpPath = path.join(os.tmpdir(), "package.nix.tmp");
  if (fileExists(tmpPath)) {
    try {
      await remove(tmpPath);
    } catch (error) {}
  }

  const srcPath = userPath || path.resolve("./package.nix");
  if (!fs.existsSync(srcPath)) {
    throw new Error(`File not found ${srcPath.toString()}`);
    process.exit(1);
  }

  const [srcJsonRaw1, err1] = await evalNixExpr(srcPath, false);

  await fsPromise.writeFile(tmpPath, srcJsonRaw1);
  const [srcJsonRaw2, err2] = await evalNixExpr(tmpPath, true);
  const json = JSON.parse(srcJsonRaw2);
  return json;
}
