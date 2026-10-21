#! /bin/sh

cd "$(dirname "$0")"

# The documents are parsed and written to stdout as JSON, so that they
# can be read without a Nix library.
nix eval --impure --json --expr '
  let
    yaml = import ../../yaml/default.nix;
  in
  yaml.safeParseStream { enableAnchors = true; tags = { }; }
    (builtins.readFile ./sample.yaml)
'
