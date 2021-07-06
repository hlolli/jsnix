export const getBodyLens = (ast) =>
  ast.argSpec !== undefined ? ast.body.paramExpr : ast;
