{
  style = import ./style.nix;
  mkScript = name: fn: pkgs: x:
    pkgs.writeScript name /* bash */ ''
      #!${pkgs.lib.getExe pkgs.bash}

      output="''${1:-/dev/stdout}"
      cat ${pkgs.writeText "source" (fn x)} > $output
    '';

  min = a: c: if a < c then a else c;
  max = a: c: if a > c then a else c;
  mod = x: y: x - y * (x / y);

  reverseList = xs: let
    lastIndex =  builtins.length xs - 1;
  in builtins.genList (n: builtins.elemAt xs (lastIndex - n)) (lastIndex + 1);

  fix = f: let s = f s; in s;

  do = f: x: if f ? __functor || builtins.isFunction f then f x else f;
}
