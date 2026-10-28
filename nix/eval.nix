{ parser, builtinsBridge }:
let
  b = builtins;

  # Create a thunk that memoizes its value.
  #
  # The forced value is bound in a `let` *around* the attribute set, so the
  # host Nix evaluator caches it: forcing the same thunk twice yields the
  # very same value (pointer-identical), exactly like Nix's own thunks.
  # This makes `trace`/`throw` side effects happen once and keeps function
  # values comparable by identity.
  mkThunk = env: expr:
    let
      innerEnv = env // {
        __scope = env.__scope or {};
        __builtins = env.__builtins or b;
      };
      v = evalExpr expr innerEnv;
    in {
      __thunk = true;
      inherit env expr;
      value = v;
    };

  # Force a value to weak head normal form: unwrap nested thunks.
  force = v: env: bb:
    if b.isAttrs v && v ? __thunk
    then force v.value env bb
    else v;

  # Convert a value into something the host Nix evaluator understands.
  #
  # Real Nix has no thunks: the members of an attribute set are values. Our
  # internal representation keeps them as thunks, so a plain attribute set
  # would leak the internal representation to a builtin (or to the caller).
  #
  # The conversion stays lazy:
  #
  #  * A thunk becomes its memoised value. The host forces it when it is
  #    read, so nothing is evaluated before it is needed.
  #  * `builtins.mapAttrs` keeps the members of an attribute set
  #    unevaluated, so only the member that is read gets forced.
  toForeign = v: env: bb:
    if b.isAttrs v && v ? __thunk
    then toForeign v.value env bb
    else if b.isList v
    then b.map (x: toForeign x env bb) v
    else if b.isAttrs v
    then b.mapAttrs (_: x: toForeign x env bb) v
    else v;

  # Force a value deeply. Used at the public boundary and when passing
  # arguments to foreign (real Nix) builtins, which cannot understand our
  # thunk representation.
  deepForce = v: env: bb:
    let fv = force v env bb;
    in
      if b.isList fv then b.map (x: deepForce x env bb) fv
      else if b.isAttrs fv && !(fv ? __thunk)
      then b.mapAttrs (_: x: deepForce x env bb) fv
      else fv;

  getType = v: env: bb:
    let fv = force v env bb;
    in
      if b.isString fv then "string"
      else if b.isInt fv then "int"
      else if b.isFloat fv then "float"
      else if b.isList fv then "list"
      else if b.isAttrs fv then "attrs"
      else if b.isBool fv then "bool"
      else if b.isPath fv then "path"
      else if fv == null then "null"
      else "other";

  safeToString = v: env: bb:
    let fv = deepForce v env bb;
    in
      if b.isString fv then fv
      else if b.isInt fv || b.isFloat fv || b.isBool fv || fv == null then b.toString fv
      else if b.isPath fv then b.toString fv
      else "<${b.typeOf fv}>";

  # Structural equality following Nix's rules.
  #
  #  * Two functions are never equal when compared directly (`f == f` is
  #    false in Nix).
  #  * Inside a list or attribute set, function elements are equal when they
  #    denote the same value. Because thunks are memoised, two references to
  #    the same binding yield the very same function value, which Nix
  #    recognises through its own list comparison.
  #  * Everything else is compared the way Nix compares it.
  eqValues = v1: v2: env: bb:
    let
      isThunk = x: b.isAttrs x && x ? __thunk;

      # Do the two values denote the same function? Nix compares functions by
      # identity, which its list comparison exposes: two identical function
      # values compare equal, two distinct ones do not.
      # Resolve a value to the cell it originates from. Variable references
      # are followed to the binding they name, so that two references to the
      # same binding resolve to the same cell.
      #
      # Nix compares the elements of a collection by that cell: two elements
      # that come from the same binding are equal (even when they are
      # functions), while elements from different bindings are not.
      cellOf = z:
        let
          go = cur: seen:
            if !(b.isAttrs cur && cur ? __thunk) then cur
            else if (cur.expr.type or "") == "lambda" then cur
            else if (cur.expr.type or "") == "var"
            then
              (let
                name = cur.expr.name;
                next = if cur.env ? ${name} then cur.env.${name} else null;
               in if next == null || b.elem next seen then cur
                  else go next (seen ++ [ next ]))
            else cur;
        in go z [ z ];

      # Are the two values the same function? Nix compares functions by
      # identity inside collections.
      sameFn = x: y:
        let
          cx = cellOf x;
          cy = cellOf y;
        in cx == cy;

      # `inCollection` selects Nix's collection rule: there, function
      # elements are equal when they denote the same value. At the top level
      # Nix never considers two functions equal.
      go = inCollection: x: y:
        let
          vx = force x env bb;
          vy = force y env bb;
          isFn = z: b.isFunction z;
        in
          if isFn vx && isFn vy then
            (if inCollection then sameFn x y else false)
          else if b.isList vx && b.isList vy then
            if b.length vx != b.length vy then false
            else b.all (i: go true (b.elemAt vx i) (b.elemAt vy i)) (b.genList (i: i) (b.length vx))
          else if b.isAttrs vx && b.isAttrs vy && !(vx ? __thunk) && !(vy ? __thunk) then
            let
              kx = b.attrNames vx;
              ky = b.attrNames vy;
            in if b.length kx != b.length ky then false
               else b.all (k: vx ? ${k} && vy ? ${k} && go true vx.${k} vy.${k}) kx
          else vx == vy;
    in go false v1 v2;

  requireBool = v:
    if b.isBool v then v
    else throw "expected a Boolean but found a ${b.typeOf v}";

  # Names that Nix exposes in the global (base) scope. Everything else is
  # only reachable through `builtins` (or an injected `scope`).
  globalBuiltinNames = [
    "abort" "baseNameOf" "break" "derivation" "derivationStrict" "dirOf"
    "fetchGit" "fetchMercurial" "fetchTarball" "fetchTree" "fromTOML"
    "import" "isNull" "map" "placeholder" "removeAttrs" "scopedImport"
    "throw" "toString"
  ];
  specialGlobalNames = [ "__findFile" "__nixPath" "__storeDir" ];

  baseNames = scope:
    globalBuiltinNames
    ++ specialGlobalNames
    ++ [ "builtins" "true" "false" "null" ]
    ++ (if b.isAttrs scope then b.attrNames scope else []);

  # Nix resolves free variables statically before evaluation: an undefined
  # variable is an error even in an unforced branch/binding, unless the
  # reference is under a `with` (which defers resolution until run time).
  # Dynamic attribute names are evaluated in the scope of the set being
  # extended (which may be a nested `rec`); their resolution is deferred to
  # evaluation here.
  checkPathMessage = names: hasWith: path:
    b.foldl' (acc: c:
      if acc != null then acc
      else if c ? static then null
      else checkExprMessage names hasWith c.dynamic
    ) null path;

  boundNames = bindings:
    b.concatMap (x:
      if x.path == [] then []
      else let c = b.head x.path; in if c ? static then [ c.static ] else []
    ) bindings;

  checkBindingsMessage = names: hasWith: recursive: bindings:
    let
      inner = if recursive then names ++ boundNames bindings else names;
      firstStatic = x:
        if x.path == [] then null
        else let c = b.head x.path; in if c ? static then c.static else null;
      isRecSet = x:
        x.path != [] && b.length x.path == 1
        && (x.value.type or "") == "attrs" && (x.value.recursive or false);
      firstFor = k: b.head (b.filter (y: firstStatic y == k) bindings);
      recKeys = b.concatMap (x:
        if firstStatic x != null && isRecSet (firstFor (firstStatic x))
        then [ (firstStatic x) ] else []
      ) bindings;
      recScope = k:
        let
          own = b.concatMap (x:
            if firstStatic x == k && b.length x.path == 1
               && (x.value.type or "") == "attrs"
            then boundNames x.value.bindings
            else []
          ) bindings;
          added = b.concatMap (x:
            if firstStatic x == k && b.length x.path > 1
            then
              let c = b.elemAt x.path 1;
              in if c ? static then [ c.static ] else []
            else []
          ) bindings;
        in own ++ added;
      scopeFor = x:
        let k = firstStatic x;
        in if k != null && b.length x.path > 1 && b.elem k recKeys
           then names ++ recScope k
           else inner;
    in
      b.foldl' (acc: x:
        if acc != null then acc
        else
          let
            scope = scopeFor x;
            checkName = checkPathMessage scope hasWith x.path;
            checkValue =
              if (x.outer or false)
              then
                (if (x.value.type or "") == "var"
                 then checkExprMessage names hasWith x.value
                 else checkExprMessage scope hasWith x.value)
              else checkExprMessage scope hasWith x.value;
          in
            if checkName != null then checkName
            else if checkValue != null then checkValue
            else null
      ) null bindings;

  checkExprMessage = names: hasWith: expr:
    let
      t = expr.type or "";
      check = checkExprMessage names hasWith;
      andMsg = a: c: if a != null then a else c;
    in
      if t == "var" then
        (if b.elem expr.name names || hasWith then null
         else "undefined variable '${expr.name}'")
      else if t == "lit" then null
      else if t == "string" then
        b.foldl' (acc: p: if acc != null then acc else if b.isString p then null else check p.interp) null expr.parts
      else if t == "path" then
        b.foldl' (acc: p: if acc != null then acc else if b.isString p then null else check p.interp) null expr.parts
      else if t == "searchPath" then null
      else if t == "list" then
        b.foldl' (acc: e: if acc != null then acc else check e) null expr.elems
      else if t == "attrs" then
        checkBindingsMessage names hasWith (expr.recursive or false) expr.bindings
      else if t == "let" then
        andMsg (checkBindingsMessage names hasWith true expr.bindings)
               (checkExprMessage (names ++ boundNames expr.bindings) hasWith expr.body)
      else if t == "lambda" then
        if expr ? pattern
        then
          let
            entries = expr.pattern.entries;
            argNames = b.map (e: e.name) entries
              ++ (if (expr.argName or null) == null then [] else [ expr.argName ]);
            counts = b.foldl' (acc: n: acc // { ${n} = (acc.${n} or 0) + 1; }) {} argNames;
            dups = b.filter (n: counts.${n} > 1) argNames;
            inner = names ++ argNames;
          in
            if dups != [] then "duplicate formal function argument '${b.head dups}'"
            else
              andMsg (b.foldl' (acc: e: if acc != null then acc else if e ? default then checkExprMessage inner hasWith e.default else null) null entries)
                     (checkExprMessage inner hasWith expr.body)
        else checkExprMessage (names ++ [ expr.param ]) hasWith expr.body
      else if t == "binop" then andMsg (check expr.left) (check expr.right)
      else if t == "app" then andMsg (check expr.fn) (check expr.arg)
      else if t == "if" then andMsg (check expr.cond) (andMsg (check expr.thenBranch) (check expr.elseBranch))
      else if t == "assert" then andMsg (check expr.cond) (check expr.body)
      else if t == "with" then
        andMsg (check expr.env) (checkExprMessage names true expr.body)
      else if t == "or" then andMsg (check expr.sel) (check expr.default)
      else if t == "hasattr" then andMsg (check expr.base) (checkPathMessage names hasWith expr.path)
      else null;

  evalBinOp = op: left: right: env: bb:
    let
      fl = force (evalExpr left env) env bb;
      fr = force (evalExpr right env) env bb;
      lt = getType fl env bb;
      rt = getType fr env bb;
    in
      if op == "+"
      then
        if lt == "string"
        then fl + coerceString (deepForce fr env bb)
        else if lt == "path" then
          (if b.isPath fr then fl + fr
           else fl + coercePathPart (deepForce fr env bb))
        else
          (if ((lt == "int" || lt == "float") && (rt == "int" || rt == "float")) || (lt == "attrs" && fl ? __add)
           then bb.add (toForeign fl env bb) (toForeign fr env bb)
           else throw (if !(lt == "int" || lt == "float" || (lt == "attrs" && fl ? __add)) then "expected a number but found a ${lt}: ${safeToString fl env bb}" else "expected a number but found a ${rt}: ${safeToString fr env bb}"))
      else if op == "-" then
        (if ((lt == "int" || lt == "float") && (rt == "int" || rt == "float")) || (lt == "attrs" && fl ? __sub)
         then bb.sub (toForeign fl env bb) (toForeign fr env bb)
         else throw (if !(lt == "int" || lt == "float" || (lt == "attrs" && fl ? __sub)) then "expected a number but found a ${lt}: ${safeToString fl env bb}" else "expected a number but found a ${rt}: ${safeToString fr env bb}"))
      else if op == "/" then
        (if ((lt == "int" || lt == "float") && (rt == "int" || rt == "float")) || (lt == "attrs" && fl ? __div)
         then bb.div (toForeign fl env bb) (toForeign fr env bb)
         else throw (if !(lt == "int" || lt == "float" || (lt == "attrs" && fl ? __div)) then "expected a number but found a ${lt}: ${safeToString fl env bb}" else "expected a number but found a ${rt}: ${safeToString fr env bb}"))
      else if op == "*" then
        (if ((lt == "int" || lt == "float") && (rt == "int" || rt == "float")) || (lt == "attrs" && fl ? __mul)
         then bb.mul (toForeign fl env bb) (toForeign fr env bb)
         else throw (if !(lt == "int" || lt == "float" || (lt == "attrs" && fl ? __mul)) then "expected a number but found a ${lt}: ${safeToString fl env bb}" else "expected a number but found a ${rt}: ${safeToString fr env bb}"))
      else if op == "++" then
        (if lt == "list" && rt == "list"
         then bb.concatLists [ (toForeign fl env bb) (toForeign fr env bb) ]
         else throw "expected a list but found a ${if lt != "list" then lt else rt}")
      else if op == "//" then
        (if b.isAttrs fl && b.isAttrs fr
         then fl // fr
         else throw "expected an attribute set but found a ${if !b.isAttrs fl then lt else rt}")
      else if op == "==" then eqValues fl fr env bb
      else if op == "!=" then !(eqValues fl fr env bb)
      else if op == "<" then
        (if (lt == rt) || ((lt == "int" || lt == "float") && (rt == "int" || rt == "float")) then deepForce fl env bb < deepForce fr env bb
         else throw "cannot compare a ${lt} with a ${rt}")
      else if op == ">" then
        (if (lt == rt) || ((lt == "int" || lt == "float") && (rt == "int" || rt == "float")) then deepForce fl env bb > deepForce fr env bb
         else throw "cannot compare a ${lt} with a ${rt}")
      else if op == "<=" then
        (if (lt == rt) || ((lt == "int" || lt == "float") && (rt == "int" || rt == "float")) then deepForce fl env bb <= deepForce fr env bb
         else throw "cannot compare a ${lt} with a ${rt}")
      else if op == ">=" then
        (if (lt == rt) || ((lt == "int" || lt == "float") && (rt == "int" || rt == "float")) then deepForce fl env bb >= deepForce fr env bb
         else throw "cannot compare a ${lt} with a ${rt}")
      else if op == "!" then !fl
      else if op == "neg" then -fl
      else throw "unsupported operator '${op}'";

  # Build the bindings (as thunks) for an attribute set / let.
  # `outerEnv` is the lexical scope; `bindEnv` is the (possibly recursive)
  # scope used for ordinary assignments. `inherit` bindings always resolve in
  # `outerEnv`. Bindings may use attribute paths (`a.b.c = v;`), which are
  # merged into nested attribute sets.
  isLeaf = v: b.isAttrs v && v ? __thunk;
  
  # String interpolation coercion: strings pass through, paths are copied to
  # the store, and sets are coerced via `outPath`/`__toString`. Other types
  # are rejected, as in Nix.
  coerceString = v:
    if b.isString v then v
    else if b.isPath v || b.isAttrs v then "${v}"
    else throw "cannot coerce a ${b.typeOf v} to a string";
  
  # Path interpolation coercion is stricter: no int/bool/null, and paths
  # are used directly rather than copied to the store.
  coercePathPart = v:
    if b.isString v then v
    else if b.isPath v || b.isAttrs v then b.toString v
    else throw "cannot coerce a ${b.typeOf v} to a string";
  
  # Resolve an attribute-path component. A dynamic null name means the
  # binding is skipped; other non-string values are an error.
  componentName = env: bb: c:
    if c ? static then c.static
    else
      let v = force (evalExpr c.dynamic env) env bb;
      in if b.isString v then v
         else if v == null then null
         else throw "expected a string but found ${b.typeOf v}: ${b.toString v}";
  
  # Resolve the key of `x.y` / `x.${e}` selection (null is not allowed).
  selectionKey = env: bb: rhs:
    let
      key =
        if b.isAttrs rhs && rhs.type == "lit"
        then rhs.value
        else force (evalExpr rhs env) env bb;
    in
      if b.isString key then key
      else throw "expected a string but found ${b.typeOf key}: ${b.toString key}";
  
  # A pending binding: the expression plus how it should be evaluated.
  # It is turned into a memoizing thunk once the final environment is known.
  mkLeafFor = outerEnv: bindEnv: x:
    {
      expr = x.value;
      outer = x.outer or false;
      inheritFlag = x.isInherit or false;
      env0 = if x.outer or false then outerEnv else bindEnv;
    };

  # Materialise a pending binding into a thunk bound to `e`.
  materialize = l: e: (mkThunk e l.expr) // {
    outer = l.outer;
    inheritFlag = l.inheritFlag;
  };

  # Replace the expression of an existing thunk. The thunk has to be rebuilt
  # (rather than patched) because its value is memoised against the original
  # expression.
  rebuildThunk = th: newExpr: (mkThunk th.env newExpr) // {
    outer = th.outer or false;
    inheritFlag = th.inheritFlag or false;
  };

  isSyntacticSet = th:
    th ? __thunk && (let t = th.expr.type or ""; in t == "attrs" || t == "rec");

  isSyntacticLeaf = l:
    let t = l.expr.type or ""; in t == "attrs" || t == "rec";

  mergeBindings = outerEnv: nameEnv: bindEnv: bb: acc: bindings:
    b.foldl' (acc: x:
      mergePath outerEnv nameEnv bindEnv bb acc x.path (mkLeafFor outerEnv bindEnv x)
    ) acc bindings;

  mergePath = outerEnv: nameEnv: bindEnv: bb: acc: path: leaf:
    let
      go = acc: path: leafEnv: nameEnv:
        if path == []
        then materialize leaf leafEnv
        else
          let
            k = componentName nameEnv bb (b.head path);
            rest = b.tail path;
            existing = if k == null then null else if acc ? ${k} then acc.${k} else null;
            existingIsThunk = existing != null && isLeaf existing;
            existingIsSyntacticSet = existingIsThunk && isSyntacticSet existing;
            mergeableExisting =
              existing != null &&
              ((b.isAttrs existing && !(existing ? __thunk)) || existingIsSyntacticSet);
            existingIsRec = existingIsSyntacticSet && (existing.expr.recursive or false);
          in
            if k == null then acc
            else if existing == null then
              (if rest == [] then acc // { ${k} = materialize leaf leafEnv; }
               else acc // { ${k} = go {} rest leafEnv nameEnv; })
            else if rest == [] then
              (if (leaf.inheritFlag) || (existing.inheritFlag or false)
               then throw "attribute '${k}' is already defined"
               else if existingIsRec then
                 (if isSyntacticLeaf leaf
                  then acc // {
                    ${k} = existing // {
                      expr = existing.expr // {
                        bindings = existing.expr.bindings ++ leaf.expr.bindings;
                      };
                    };
                  }
                  else throw "attribute '${k}' is already defined")
               else if isSyntacticLeaf leaf && mergeableExisting
               then
                 (let
                    overrideEnv = leafEnv;
                    leafIsRec = (leaf.expr.recursive or false);
                    newPart =
                      if leafIsRec
                      then mergeBindings outerEnv recEnv recEnv bb {} leaf.expr.bindings
                      else {};
                    recEnv = overrideEnv // newPart;
                    exSet = force existing nameEnv bb;
                  in
                    if !b.isAttrs exSet then throw "attribute '${k}' already has a non-set value"
                    else acc // {
                      ${k} =
                        mergeBindings outerEnv
                          (if leafIsRec then recEnv else overrideEnv)
                          (if leafIsRec then recEnv else overrideEnv)
                          bb exSet leaf.expr.bindings;
                    })
               else throw "attribute '${k}' is already defined")
            else if existingIsRec then
              (if leaf.inheritFlag
               then throw "attribute '${k}' is already defined"
               else acc // {
                 ${k} = rebuildThunk existing (existing.expr // {
                   bindings = existing.expr.bindings ++ [{
                     path = rest;
                     value = leaf.expr;
                     outer = leaf.outer;
                     isInherit = leaf.inheritFlag;
                   }];
                 });
               })
            else if !mergeableExisting then throw "attribute '${k}' is already defined"
            else if existingIsThunk then
              (let
                 fv = force existing nameEnv bb;
                 childEnv = if existingIsRec then existing.env else leafEnv;
                 childNameEnv = if existingIsRec then existing.env else nameEnv;
               in if b.isAttrs fv then acc // { ${k} = go fv rest childEnv childNameEnv; }
                  else throw "attribute '${k}' already has a non-set value")
            else acc // { ${k} = go existing rest leafEnv nameEnv; };
    in go acc path leaf.env0 nameEnv;

  
  mkBindings = outerEnv: bindEnv: bb: bindings:
    mergeBindings outerEnv bindEnv bindEnv bb {} bindings;

  # Walk an attribute-selection chain without forcing the final value.
  # Returns { ok = false; } when the chain is missing (so `or` can use its
  # default) and { ok = true; value = ...; } otherwise. Errors raised while
  # forcing an existing value are not swallowed.
  selectOpt = env: bb: e:
    if e.type == "binop" && e.op == "." then
      let r = selectOpt env bb e.left;
      in if !r.ok then r
         else
           let
             v = force r.value env bb;
             k = selectionKey env bb e.right;
           in if b.isAttrs v && b.hasAttr k v
              then { ok = true; value = b.getAttr k v; }
              else { ok = false; }
    else { ok = true; value = evalExpr e env; };
  
  # Search `with` frames, innermost first. Lexical bindings are checked
  # before this, so `let`/`rec`/lambda variables always win over `with`.
  withLookup = env: bb: name:
    let
      go = frames:
        if frames == [] then { found = false; }
        else
          let frame = force (b.head frames) env bb;
          in if b.isAttrs frame
             then
               (if frame ? ${name}
                then { found = true; value = frame.${name}; }
                else go (b.tail frames))
             else throw "expected a set but found a ${b.typeOf frame}: ${b.toString frame}";
    in go (env.__with or []);
  
  evalExpr = expr: env:
    let
      scope = env.__scope or {};
      bb = env.__builtins or (builtinsBridge.getBuiltins scope);
    in
      if expr.type == "lit" then expr.value
      else if expr.type == "searchPath" then
        let
          scope = env.__scope or {};
          bb = env.__builtins or (builtinsBridge.getBuiltins scope);
          nixPath = if scope ? __nixPath then scope.__nixPath else bb.nixPath or [];
        in (bb.findFile or b.findFile) nixPath expr.name
      else if expr.type == "path" then
        let
          template = b.concatStringsSep "" (b.map (part:
            if b.isString part then part else "#"
          ) expr.parts);
          templateLen = b.stringLength template;
          hasTrailingSlash =
            templateLen > 0 && b.substring (templateLen - 1) 1 template == "/";
        in
          if hasTrailingSlash then throw "path has a trailing slash"
          else if b.match ".*//.*" template != null
          then throw "syntax error in path '${template}': empty path segment"
          else
        let
          p = b.concatStringsSep "" (b.map (part:
            if b.isAttrs part
            then coercePathPart (deepForce (evalExpr part.interp env) env bb)
            else part
          ) expr.parts);
          cwd = env.__cwd or null;
          # Adding a path to a path normalises it: `.` segments are dropped
          # and `..` segments remove the previous one, exactly as Nix does.
          # The working directory is turned into a string first, because
          # `path + string` concatenates without a separator.
          cwdStr = if cwd == null then null else b.toString cwd;
          full =
            if b.substring 0 1 p == "/" then p
            else if b.substring 0 2 p == "~/" then
              (b.getEnv "HOME") + b.substring 1 (b.stringLength p - 1) p
            else if cwd == null
            then throw "relative path '${p}' requires a cwd (use the attribute-set form of eval)"
            else cwdStr + "/" + p;
        in /. + full
      else if expr.type == "string" then
        b.concatStringsSep "" (b.map (part:
          if b.isAttrs part
          then coerceString (deepForce (evalExpr part.interp env) env bb)
          else part
        ) expr.parts)
      else if expr.type == "var" then
        let name = expr.name;
        in
          if env ? ${name} then env.${name}
          else if name == "builtins" then bb
          else if scope ? ${name} then scope.${name}
          else if name == "true" then true
          else if name == "false" then false
          else if name == "null" then null
          else if name == "__nixPath" then
            (if scope ? __nixPath then scope.__nixPath else bb.nixPath or [])
          else if name == "__storeDir" then
            (if scope ? __storeDir then scope.__storeDir else bb.storeDir or "/nix/store")
          else if name == "__findFile" then (bb.findFile or b.findFile)
          else if b.elem name globalBuiltinNames && bb ? ${name} then bb.${name}
          else
            let w = withLookup env bb name;
            in if w.found then w.value
            else throw "undefined variable '${name}'"
      else if expr.type == "let" then
        # NOTE: non-recursive let is approximated as recursive (Nix `let` is
        # actually recursive), so bindings may refer to each other lazily.
        let
          allStatic = b.all (x: b.all (c: c ? static) x.path) expr.bindings;
          newEnv =
            if !allStatic then throw "dynamic attributes not allowed in let"
            else env // (mkBindings env newEnv bb expr.bindings);
        in evalExpr expr.body newEnv
      else if expr.type == "list" then
        b.map (e: mkThunk env e) expr.elems
      else if expr.type == "attrs" then
        if expr.recursive or false
        then
          let
            staticBindings = b.filter (x: x.path != [ ] && ((b.head x.path) ? static)) expr.bindings;
            staticEnv = env // (mergeBindings env env staticEnv bb {} staticBindings);
            finalSet = mergeBindings env staticEnv staticEnv bb {} expr.bindings;
          in finalSet
        else mkBindings env env bb expr.bindings
      else if expr.type == "if" then
        let cond = force (evalExpr expr.cond env) env bb;
        in if cond then evalExpr expr.thenBranch env else evalExpr expr.elseBranch env
      else if expr.type == "assert" then
        let cond = force (evalExpr expr.cond env) env bb;
        in if cond then evalExpr expr.body env else throw "assertion failed"
      else if expr.type == "with" then
        evalExpr expr.body (env // {
          __with = [ (mkThunk env expr.env) ] ++ (env.__with or []);
        })
      else if expr.type == "lambda" then
        let
          # The result of a call is forced deeply, so that callers (including
          # the host Nix evaluator) receive plain data instead of the internal
          # thunk representation.
          fn = arg:
            let
              result =
                if expr ? pattern then
                  let
                    pat = expr.pattern;
                    entries = pat.entries;
                    names = b.map (e: e.name) entries;
                    argBinds =
                      if (expr.argName or null) != null
                      then { ${expr.argName} = arg; }
                      else {};
                    isProvided = e: b.isAttrs arg && arg ? ${e.name};
                    missing = b.filter (e: !(isProvided e) && !(e ? default)) entries;
                    binds = b.listToAttrs (b.map (e: {
                      name = e.name;
                      value =
                        if isProvided e then arg.${e.name}
                        else if e ? default
                        then mkThunk scopeForDefaults e.default
                        else throw "function argument '${e.name}' is missing";
                    }) entries);
                    scopeForDefaults = env // argBinds // binds;
                    extra =
                      if b.isAttrs arg
                      then b.attrNames (b.removeAttrs arg names)
                      else [];
                  in
                    if !b.isAttrs arg then throw "function expects an attribute set"
                    else if missing != []
                    then throw "function argument '${(b.head missing).name}' is missing"
                    else if !pat.ellipsis && extra != []
                    then throw "function found unexpected argument '${b.head extra}'"
                    else evalExpr expr.body scopeForDefaults
                else evalExpr expr.body (env // { ${expr.param} = arg; });
            in deepForce result env bb;
        in fn
      else if expr.type == "or" then
        let attempt = selectOpt env bb expr.sel;
        in if attempt.ok then force attempt.value env bb
           else evalExpr expr.default env
      else if expr.type == "hasattr" then
        let
          walk = v: path:
            if path == [] then true
            else
              let k = componentName env bb (b.head path);
              in if k == null then throw "expected a string but found null: null"
                 else if b.isAttrs v && b.hasAttr k v
                 then walk (force (b.getAttr k v) env bb) (b.tail path)
                 else false;
          base = force (evalExpr expr.base env) env bb;
        in walk base expr.path
      else if expr.type == "binop" then
        if expr.op == "."
        then
          let
            leftVal = force (evalExpr expr.left env) env bb;
            k = selectionKey env bb expr.right;
          in
            if b.isAttrs leftVal && b.hasAttr k leftVal
            then force (b.getAttr k leftVal) env bb
            else throw "attribute '${k}' missing"
        else if expr.op == "&&" then
          let l = requireBool (force (evalExpr expr.left env) env bb);
          in if l then requireBool (force (evalExpr expr.right env) env bb) else false
        else if expr.op == "||" then
          let l = requireBool (force (evalExpr expr.left env) env bb);
          in if l then true else requireBool (force (evalExpr expr.right env) env bb)
        else if expr.op == "->" then
          let l = requireBool (force (evalExpr expr.left env) env bb);
          in if l then requireBool (force (evalExpr expr.right env) env bb) else true
        else evalBinOp expr.op expr.left expr.right env bb
      else if expr.type == "app" then
        let
          fn = force (evalExpr expr.fn env) env bb;
          arg = deepForce (evalExpr expr.arg env) env bb;
          apply = f: a: deepForce (f a) env bb;
        in
          if b.isFunction fn then apply fn arg
          else if b.isAttrs fn && fn ? __functor then
            let f = force fn.__functor env bb;
            in if b.isFunction f then apply f fn arg
               else throw "attempt to call something which is not a function"
          else throw "attempt to call something which is not a function"
      else throw "cannot evaluate node of type '${expr.type or "unknown"}'";

  evalAst = { ast, cwd ? null, scope ? {} }:
    let
      bb = builtinsBridge.getBuiltins scope;
      checked = checkExprMessage (baseNames scope) false ast;
      topEnv = { __scope = scope; __cwd = cwd; __builtins = bb; };
    in
      if checked != null then throw checked
      else deepForce (evalExpr ast topEnv) topEnv bb;

  evalAstSafe = { ast, cwd ? null, scope ? {} }:
    let
      bb = builtinsBridge.getBuiltins scope;
      checked = checkExprMessage (baseNames scope) false ast;
    in
      if checked != null then {
        success = false;
        value = false;
        message = checked;
      }
      else
        let
          topEnv = { __scope = scope; __cwd = cwd; __builtins = bb; };
          result = b.tryEval (deepForce (evalExpr ast topEnv) topEnv bb);
        in
          if result.success then {
            success = true;
            value = result.value;
            message = null;
          } else {
            success = false;
            value = false;
            message = "evaluation failed";
          };

  eval = { text, cwd ? null, scope ? {} }:
    evalAst {
      ast = parser.parse text;
      inherit cwd scope;
    };
in {
  evalString = eval;
  inherit evalAst evalAstSafe evalExpr force deepForce evalBinOp getType;
}
