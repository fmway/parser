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
  v1 = import ./v1.nix { inherit parser render errors; };
  v2 = import ./v2.nix { inherit commentParser commentRender v1 errors; };
in v2 // {
  v1 = v1;
  v2 = v2;
  inherit strings parser render commentParser helpers commentRender errors;
}
