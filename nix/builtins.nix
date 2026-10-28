# Builtins bridge (FFI style)
let
  b = builtins;
in {
  # Get builtins, allow override via scope.builtins
  getBuiltins = scope:
    if scope ? builtins && b.isAttrs scope.builtins
    then
      let u = scope.builtins;
      in
        if u ? builtins then u
        else
          let u' = u // { builtins = u'; };
          in u'
    else b;
    
  # Check if name is a builtin
  isBuiltinName = builtinsSet: name: builtinsSet ? ${name};
}
