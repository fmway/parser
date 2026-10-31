let
  utils = import ../utils;
  nix = import ../nix;
  strings = import ./string.nix;
  errors = import ./error.nix;
  parser = import ./parser.nix { nixParser = nix.parser; inherit strings; };
  render = import ./render.nix { inherit nix errors; };
  commentParser = import ./comment-parser.nix {
    nixParser = nix.parser;
    inherit strings;
  };
  helpers = import ./helpers.nix { inherit strings render; };
  commentRender = import ./comment-render.nix {
    inherit commentParser helpers nix render errors strings;
    stringsPath = toString ./string.nix;
    helpersPath = toString ./helpers.nix;
  };

  b = builtins;

  # Report that a template could not be parsed.
  #
  # The message is added to the error as a trace, so that the caller
  # sees that the template was being parsed when it went wrong. The
  # throw is inside a function, because the context is added to an
  # error that is already being thrown, and not to one that is raised
  # while the arguments of a call are evaluated.
  fail = msg: b.addErrorContext "while parsing a template" (b.throw msg);

  resolve = args: {
    text =
      args.text or (b.readFile (args.file or (throw "template: expected `text` or `file`")));
    cwd =
      args.cwd or (dirOf (args.file or (b.unsafeGetAttrPos "text" args).file));
  };

  v1 = let
    parse = args: let
      r = resolve args;
      parsed = parser.safeParse {
        prefix = args.prefix or null;
        postfix = args.postfix or null;
        text = r.text;
      };
    in
      if parsed.type == "error" then
        throw (errors.errorMessage r.text parsed.value)
      else parsed.value;

    eval = args: let
      r = resolve args;
      parsed = parse args;
      scope = args.scope or {};
    in render.renderSegments parsed.text parsed.segments r.cwd scope;
  in {
    inherit parse eval;
    safeParse = args:
      parser.safeParse {
        prefix = args.prefix or null;
        postfix = args.postfix or null;
        inherit (resolve args) text;
      };
    mkScript = utils.mkScript "gen-template.sh" eval;
  };

  v2 = let
    safeParse = args:
      commentParser.safeParse {
        text = (resolve args).text;
        commentStyle = args.commentStyle or "auto";
      };

    parse = args: let
      r = resolve args;
      parsed = safeParse args;
    in
      if parsed.type == "error" then
        fail (errors.errorMessage r.text parsed.value)
      else parsed.value;

    eval = args: let
      r = resolve args;
      scope = args.scope or {};
      interpolated =
        if args.interpolation or null == null then r.text
        else v1.eval {
          prefix = args.interpolation.prefix or null;
          postfix = args.interpolation.postfix or null;
          inherit (r) text cwd;
          inherit scope;
        };
      parsed = parse {
        text = interpolated;
        commentStyle = args.commentStyle or "auto";
      };
    in commentRender.renderTemplate parsed r.cwd scope;
  in {
    inherit safeParse parse eval;
    mkScript = utils.mkScript "gen-template.sh" eval;
  };
in {
  inherit (v2) parse eval safeParse;
  inherit strings parser render commentParser helpers commentRender errors v1 v2;
}
