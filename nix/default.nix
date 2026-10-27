let
  # Entry point for nix self-evaluator
  parsec = (import ../deps.nix).parsec;
  lexerMod = (import ../deps.nix).lexer;
  
  ast = import ./ast.nix;
  util = import ./util.nix;
  env = import ./env.nix;
  builtinsBridge = import ./builtins.nix;
  parserMod = import ./parser.nix { inherit parsec ast; lexer = lexerMod; };
  evalMod = import ./eval.nix { inherit util env builtinsBridge; parser = parserMod; };
  
  eval = expr:
    if builtins.isString expr
    then evalMod.evalString { text = expr; }
    else if builtins.isAttrs expr
    then 
      let
        args = expr;
        text = args.text;
        cwd = args.cwd or (dirOf (builtins.unsafeGetAttrPos "text" args).file);
        scope = args.scope or {};
      in evalMod.evalString { inherit text cwd scope; }
    else throw "eval expects string or attrset";

  evalAst = args:
    if builtins.isAttrs args
    then
      let
        ast = args.ast;
        cwd = args.cwd or (dirOf (builtins.unsafeGetAttrPos "ast" args).file);
        scope = args.scope or {};
      in evalMod.evalAst { inherit ast cwd scope; }
    else throw "evalAst expects attrset";

  evalAstSafe = args:
    if builtins.isAttrs args
    then
      let
        ast = args.ast;
        cwd = args.cwd or (dirOf (builtins.unsafeGetAttrPos "ast" args).file);
        scope = args.scope or {};
      in evalMod.evalAstSafe { inherit ast cwd scope; }
    else throw "evalAstSafe expects attrset";
in {
  inherit eval evalAst evalAstSafe parsec;
  lexer = lexerMod;
  parser = parserMod;
  ast = ast;
}
