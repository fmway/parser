let
  nix = import ../nix;
  strings = import ./string.nix;
  errors = import ./error.nix {};
  parser = import ./parser.nix { nixParser = nix.parser; inherit strings; };
  render = import ./render.nix { inherit nix errors; };
  commentParser = import ./comment-parser.nix {
    nixParser = nix.parser;
    inherit strings;
  };
  helpers = import ./helpers.nix { inherit strings; };
  commentRender = import ./comment-render.nix {
    inherit commentParser helpers nix render errors strings;
    stringsPath = toString ./string.nix;
    helpersPath = toString ./helpers.nix;
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
          inherit (args) prefix postfix;
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
        scope = args.scope or {};
      in
        render.renderSegments parsed.text parsed.segments r.cwd scope;
  in {
    inherit parse eval;
    safeParse = args:
      parser.safeParse {
        inherit (args) prefix postfix;
        inherit (resolve args) text;
      };
  };

  v2 = let
    safeParse = args:
      commentParser.safeParse {
        text = (resolve args).text;
        commentStyle = args.commentStyle or "auto";
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
        scope = args.scope or {};
        useNixParser = args.useNixParser or true;
        interpolated =
          if args.interpolation or null == null
          then r.text
          else v1.eval {
            inherit (args.interpolation) postfix prefix;
            inherit (r) text cwd;
            inherit scope;
          };
        parsed = parse {
          text = interpolated;
          commentStyle = args.commentStyle or "auto";
        };
      in
        if useNixParser
        then commentRender.renderTemplate parsed r.cwd scope
        else commentRender.renderTemplateIFD parsed r.cwd scope;
  in {
    inherit safeParse parse eval;
  };
in {
  inherit (v2) parse eval safeParse;
  inherit strings parser render commentParser helpers commentRender errors v1 v2;
}
