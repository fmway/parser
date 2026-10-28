{
  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.xz";
    fmway-lib.url = "github:fmway/lib";
    fmway-lib.inputs.nixpkgs.follows = "nixpkgs";
    parser.url = "path:../";
  };

  outputs = inputs: let
    lib = inputs.fmway-lib.lib.extend (self: super: inputs.parser.lib);
    code = import ./code.nix { inherit lib inputs; };
    systems = [ "aarch64-darwin" "aarch64-linux" "x86_64-linux" ];
    eachSystem = lib.genAttrs systems;
    eval = file: lib.template.v2.eval {
      inherit file;
      scope = { inherit lib code; self = inputs.parser; };
      cwd = inputs.parser.outPath;
    };

    parseAllReadme = prefix: dir: let
      r = builtins.readDir dir;
    in builtins.concatMap (name: let p = if prefix == "" then name else "${prefix}/${name}"; in
      if r.${name} == "directory" then
        parseAllReadme p "${dir}/${name}"
      else if lib.toLower name == "readme.md" then
        [{ to = p; generated = eval "${dir}/${name}"; }]
      else []
    ) (builtins.attrNames r);
    readmes = parseAllReadme "" inputs.parser;
  in {
    # TODO: add ci tests
    apps = eachSystem (system: let
      pkgs = inputs.nixpkgs.legacyPackages.${system};
    in {
      update-readme = {
        type = "app";
        program = let
          pkg = pkgs.writeShellApplication {
            name = "update-readme";
            text = lib.concatMapStringsSep "" ({ to, generated }: let
              source = pkgs.writeText "source" generated;
            in /* sh */ ''
              cat "${source}" > "${to}"
            '') readmes;
          };
        in "${pkg}/bin/update-readme";
      };
    });
  };
}
