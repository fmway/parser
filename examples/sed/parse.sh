#! /bin/sh

cd "$(dirname "$0")"

# The script is run over the text, and the result is written to stdout,
# so that it can be read without a Nix library.
#
# The module is called the way the command of sed is used: the script
# first, and the text after it.
nix eval --impure --raw --expr '
  let
    sed = import ../../sed/default.nix;
  in
  sed (builtins.readFile ./script.sed) (builtins.readFile ./sample.txt)
'
