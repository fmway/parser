{
  # thunk helper
  mkThunk = env: expr: { __thunk = true; inherit env expr; };
  isThunk = v: builtins.isAttrs v && builtins.hasAttr "__thunk" v && v.__thunk == true;
}
