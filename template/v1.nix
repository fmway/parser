{ parser, render, errors }:
let
  b = builtins;

  parse = args:
    let
      parsed = parser.safeParse {
        prefix = args.prefix;
        postfix = args.postfix;
        text = args.text;
      };
    in
      if parsed.type == "error"
      then throw (errors.errorMessage args.text parsed.value)
      else parsed.value;

  eval = args:
    let
      parsed = parse args;
      cwd = args.cwd or (dirOf (b.unsafeGetAttrPos "text" args).file);
      scope = args.scope or {};
    in
      render.renderSegments parsed.segments cwd scope;
in {
  inherit parse eval;
  safeParse = parser.safeParse;
}
