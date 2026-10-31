# A parser and a runtime for the scripts of sed.
#
# Usage:
#
#   let
#     sed = import ./sed;
#   in
#   sed "s/foo/bar/" "a foo line\n"
#
# The script is parsed into a tree of commands, and the tree is run
# over the text.
#
# The module does not use anything from outside itself: it has no
# dependency at all.

let
  b = builtins;

  script = import ./script.nix;
  exec = import ./exec.nix;
  regex = import ./regex.nix;
  error = import ../template/error.nix;

  # The line and the column of a place in a text.
  positionAt = text: offset:
    let
      len = b.stringLength text;
      off = if offset < 0 then 0 else if offset > len then len else offset;
      parts = b.split "[\n]" (b.substring 0 off text);
    in
      {
        line = (b.length parts + 1) / 2;
        col = b.stringLength (b.elemAt parts (b.length parts - 1));
      };

  # The message of an error of a script.
  errorMessage = text: err:
    error.errorMessage text (err // { context = "sed.script"; });

  # Parse a script.
  #
  # The result is either
  #
  #   { type = "success"; value = <the script>; }
  #   { type = "error";   value = { msg; offset; line; col; }; }
  safeParse = { extended_regex ? false }: text:
    let
      res = script.safeParse { inherit extended_regex; } text;
    in
      if res.type == "error" then
        let
          pos = positionAt text res.value.offset;
        in
        {
          type = "error";
          value = res.value // { inherit (pos) line col; };
        }
      else res;

  # Parse a script and give it back.
  #
  # A script that cannot be parsed is thrown as an error, with a
  # message that says what went wrong and where.
  parse = args: text:
    let
      res = safeParse args text;
    in
      if res.type == "error" then
        b.addErrorContext "while parsing a sed script" (b.throw (errorMessage text res.value))
      else res.value;

  # Run a script over a text.
  #
  # The options are
  #
  #   extended_regex :: Bool  -- the regular expressions are the
  #                              extended ones of POSIX, and not the
  #                              basic ones with the extensions of GNU
  #                              (the `-r` option of sed)
  #   quiet  :: Bool           -- do not print the pattern space at the
  #                                end of every cycle (the `-n` option)
  #   scripts :: [ String ]     -- more scripts, which are put in front
  #                                of the script (the `-e` option)
  run = { extended_regex ? false, quiet ? false, scripts ? [] }: text: input:
    let
      all = b.concatStringsSep "\n" scripts;
      scriptText = if all == "" then text else all + "\n" + text;
      parsed = parse { inherit extended_regex; } scriptText;
    in
      exec.run { script = parsed; text = input; inherit quiet; };

  # Run a script that was parsed before, over a text.
  #
  # This is the way to run the same script over many texts, since the
  # script is only parsed once.
  apply = { quiet ? false }: script: text:
    exec.run { inherit script quiet; text = text; };

in {
  # The way the command of sed is used: `sed script text`.
  #
  # It is the same as `run { } script text`, with the default options.
  # The options can be given as well: `sed { quiet = true; } script text`.
  __functor = self: x: if b.isAttrs x then self.run x else self.run { } x;

  inherit parse safeParse run apply errorMessage;

  # The regular expressions of sed, for the callers that want them.
  regex = {
    compile = regex.compile;
    match = regex.match;
    matchFrom = regex.matchFrom;
  };

  # The pieces of the module, for the callers that want them.
  modules = {
    inherit script exec;
  };
}
