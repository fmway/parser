{ commentParser, commentRender, v1, errors }:
let
  b = builtins;

  resolve = args:
    let
      text =
        if args ? text
        then args.text
        else if args ? file
        then b.readFile args.file
        else throw "template.v2: expected `text` or `file`";
      cwd =
        args.cwd or (
          if args ? file
          then dirOf args.file
          else dirOf (b.unsafeGetAttrPos "text" args).file
        );
    in { inherit text cwd; };

  safeParse = args:
    let
      r = resolve args;
    in
      commentParser.safeParse {
        text = r.text;
        commentStyle = args.commentStyle;
      };

  parse = args:
    let
      r = resolve args;
      parsed = safeParse args;
    in
      if parsed.type == "error"
      then throw (errors.errorMessage r.text parsed.value)
      else parsed.value;

  eval = args:
    let
      r = resolve args;
      interpolation = args.interpolation;
      cwd = args.cwd or r.cwd;
      scope = args.scope or {};
      interpolated =
        if interpolation == null
        then r.text
        else v1.eval {
          prefix = interpolation.prefix;
          postfix = interpolation.postfix;
          text = r.text;
          inherit cwd scope;
        };
      parsed = parse {
        text = interpolated;
        commentStyle = args.commentStyle;
      };
    in
      commentRender.renderTemplate parsed cwd scope;
in {
  inherit safeParse parse eval;
}
