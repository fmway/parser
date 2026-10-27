{ commentParser, commentRender, v1, errors }:
let
  b = builtins;

  safeParse = args:
    commentParser.safeParse {
      text = args.text;
      commentStyle = args.commentStyle;
    };

  parse = args:
    let
      parsed = safeParse args;
    in
      if parsed.type == "error"
      then throw (errors.errorMessage args.text parsed.value)
      else parsed.value;

  eval = args:
    let
      interpolation = args.interpolation;
      cwd = args.cwd or (dirOf (b.unsafeGetAttrPos "text" args).file);
      scope = args.scope or {};
      interpolated =
        if interpolation == null
        then args.text
        else v1.eval {
          prefix = interpolation.prefix;
          postfix = interpolation.postfix;
          text = args.text;
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
