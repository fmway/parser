{
  inherit (import (fetchTarball {
    url = "https://github.com/kanwren/nix-parsec/archive/master.tar.gz";
    sha256 = "sha256-/HrG0UPGnI5VdkhrNrpDiM2+nhdL6lD/bqyGtYv0QDE=";
  })) parsec lexer;
}
