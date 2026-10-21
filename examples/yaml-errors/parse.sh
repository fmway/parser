#! /bin/sh

cd "$(dirname "$0")"

# The three errors are written to stdout as JSON, so that they can be
# read without a Nix library.
nix eval --impure --json --expr '
  let
    yaml = import ../../yaml/default.nix;
  in
  {
    duplicate = yaml.safeParse {} "a: 1\na: 2\n";
    unclosed = yaml.safeParse {} "a: [1, 2\n";
    tab = yaml.safeParse {} "a:\n\tb: 1\n";
  }
'
