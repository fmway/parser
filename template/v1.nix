{ parser, render, errors }:
let
  b = builtins;

  resolve = args:
    let
      text =
        if args ? text
        then args.text
        else if args ? file
        then b.readFile args.file
        else throw "template.v1: expected `text` or `file`";
      cwd =
        args.cwd or (
          if args ? file
          then dirOf args.file
          else dirOf (b.unsafeGetAttrPos "text" args).file
        );
    in { inherit text cwd; };

  parse = args:
    let
      r = resolve args;
      parsed = parser.safeParse {
        prefix = args.prefix;
        postfix = args.postfix;
        text = r.text;
      };
    in
      if parsed.type == "error"
      then throw (errors.errorMessage r.text parsed.value)
      else parsed.value;

  eval = args:
    let
      r = resolve args;
      parsed = parse args;
      cwd = args.cwd or r.cwd;
      scope = args.scope or {};
    in
      render.renderSegments parsed.segments cwd scope;
in {
  inherit parse eval;
  safeParse = args:
    let
      r = resolve args;
    in
      parser.safeParse {
        prefix = args.prefix;
        postfix = args.postfix;
        text = r.text;
      };
}
