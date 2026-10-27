let
  nix = import ../nix;
  strings = import ./string.nix;
  errors = import ./error.nix {};
  parser = import ./parser.nix { nixParser = nix.parser; };
  render = import ./render.nix { inherit nix; };
  commentParser = import ./comment-parser.nix {
    nixParser = nix.parser;
    inherit strings;
  };
  helpers = import ./helpers.nix { inherit strings; };
  commentRender = import ./comment-render.nix {
    inherit commentParser helpers nix render;
  };

  b = builtins;

  resolve = args: {
    text =
      args.text or (b.readFile (args.file or (throw "template: expected `text` or `file`")));
    cwd =
      args.cwd or (dirOf (args.file or (b.unsafeGetAttrPos "text" args).file));
  };

  v1 = let
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
  };

  v2 = let
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
  };
in {
  inherit (v2) parse eval safeParse;
  inherit strings parser render commentParser helpers commentRender errors v1 v2;
}
