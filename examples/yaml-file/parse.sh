#! /bin/sh

cd "$(dirname "$0")"

# The configuration is parsed and written to stdout as JSON, so that it
# can be read without a Nix library.
nix eval --impure --json --expr '
  let
    yaml = import ../../yaml/default.nix;
  in
  yaml.safeParse { enableAnchors = true; tags = { }; }
    (builtins.readFile ./config.yaml)
'
