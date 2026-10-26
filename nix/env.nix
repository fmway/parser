{
  # Environment helpers
  empty = { };
  extend = env: name: value: env // { ${name} = value; };
  extendMany = env: bindings: 
    let
      go = acc: bs:
        if bs == [] then acc
        else 
          let b = builtins.head bs; rest = builtins.tail bs;
          in go (acc // { ${b.name} = b.value; }) rest;
    in go env bindings;
}
