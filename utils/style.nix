let
  esc = builtins.fromJSON "\"\\u001b\"";
  reset = "${esc}[0m";
  mkColor = i: {
    __toString = self: "${esc}[${toString i}m";
    __functor = self: text: "${self}${text}${reset}";
  };
  mkColorFull = i: rec {
    inherit (fg) __toString __functor bright;
    fg = mkColor (i + 30) // { bright = mkColor (i + 40); };
    bg = mkColor (i + 90) // { bright = mkColor (i + 100); };
  };
  imap0 = f: list: builtins.genList (n: f n (builtins.elemAt list n)) (builtins.length list);

  s = builtins.listToAttrs (imap0 (i: color: {
    name = color;
    value = mkColorFull i;
  }) [ "black" "red" "green" "yellow" "blue" "magenta" "cyan" "white"]) // {
    purple = s.magenta;
    bold = mkColor 1;
    dim = mkColor 2;
    italic = mkColor 3;
    underline = mkColor 4;
    invert = mkColor 7;
    strikethrough = mkColor 9;
    inherit reset esc;
  };
in s
