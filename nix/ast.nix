# AST node constructors
{
  mkLit = v: { type = "lit"; value = v; };
  mkVar = name: { type = "var"; name = name; };
  mkApp = fn: arg: { type = "app"; inherit fn arg; };
  mkLambda = param: body: { type = "lambda"; inherit param body; };
  mkLet = bindings: body: { type = "let"; inherit bindings body; };
  mkRec = bindings: body: { type = "rec"; inherit bindings body; };
  mkAttrSet = bindings: { type = "attrs"; bindings = bindings; recursive = false; };
  mkRecAttrSet = bindings: { type = "attrs"; bindings = bindings; recursive = true; };
  mkList = elems: { type = "list"; elems = elems; };
  mkBinOp = op: left: right: { type = "binop"; inherit op left right; };
  mkIf = cond: t: e: { type = "if"; cond = cond; thenBranch = t; elseBranch = e; };
  mkWith = env: body: { type = "with"; env = env; body = body; };
  mkInherit = from: names: { type = "inherit"; inherit from names; };
  mkString = parts: { type = "string"; inherit parts; }; # parts can be strings or exprs for interpolation
  mkPath = parts:
    { type = "path"; parts = if builtins.isString parts then [parts] else parts; };
  mkSearchPath = name: { type = "searchPath"; inherit name; };
  mkImport = path: { type = "import"; inherit path; };

  # Assign a unique id to every node of an expression tree.
  #
  # Nix compares the expressions behind two values when it decides whether
  # they are equal, and two syntactically identical expressions are still
  # different. Since Nix has no pointer comparison for attribute sets, the
  # tree is annotated with a unique id per node (its path in the tree).
  #
  # The ids are only used for comparison; they never end up in a result.
  annotate = expr:
    let
      b = builtins;

      # Walk a node, assigning ids of the form "0", "0.1", "0.1.2", ...
      go = path: node:
        if b.isAttrs node && node ? type
        then node // { __id = b.concatStringsSep "." (b.genList (i: toString (b.elemAt path i)) (b.length path)); }
        else node;

      walkExpr = path: node:
        if !(b.isAttrs node && node ? type) then node
        else
          let
            id = b.concatStringsSep "." (b.genList (i: toString (b.elemAt path i)) (b.length path));
            base = node // { __id = id; };
            t = node.type;
          in
            if t == "app" then base // {
              fn = walkExpr (path ++ [ 0 ]) node.fn;
              arg = walkExpr (path ++ [ 1 ]) node.arg;
            }
            else if t == "binop" then base // {
              left = walkExpr (path ++ [ 0 ]) node.left;
              right = walkExpr (path ++ [ 1 ]) node.right;
            }
            else if t == "lambda" then base // {
              body = walkExpr (path ++ [ 0 ]) node.body;
            }
            else if t == "let" || t == "rec" then base // {
              bindings = walkBindings (path ++ [ 0 ]) node.bindings;
              body = walkExpr (path ++ [ 1 ]) node.body;
            }
            else if t == "attrs" then base // {
              bindings = walkBindings (path ++ [ 0 ]) node.bindings;
            }
            else if t == "list" then base // {
              elems = b.genList (i: walkExpr (path ++ [ i ]) (b.elemAt node.elems i)) (b.length node.elems);
            }
            else if t == "if" then base // {
              cond = walkExpr (path ++ [ 0 ]) node.cond;
              thenBranch = walkExpr (path ++ [ 1 ]) node.thenBranch;
              elseBranch = walkExpr (path ++ [ 2 ]) node.elseBranch;
            }
            else if t == "with" then base // {
              env = walkExpr (path ++ [ 0 ]) node.env;
              body = walkExpr (path ++ [ 1 ]) node.body;
            }
            else if t == "hasattr" then base // {
              base = walkExpr (path ++ [ 0 ]) node.base;
            }
            else if t == "or" then base // {
              sel = walkExpr (path ++ [ 0 ]) node.sel;
              default = walkExpr (path ++ [ 1 ]) node.default;
            }
            else if t == "assert" then base // {
              cond = walkExpr (path ++ [ 0 ]) node.cond;
              body = walkExpr (path ++ [ 1 ]) node.body;
            }
            else base;

      walkBindings = path: bindings:
        b.genList
          (i:
            let
              binding = b.elemAt bindings i;
              bpath = path ++ [ i ];
            in
              binding // {
                path = b.genList (j: (b.elemAt binding.path j) // {
                  __id = b.concatStringsSep "." (b.genList (k: toString (b.elemAt bpath k)) (b.length bpath))
                    + "." + toString j;
                }) (b.length binding.path);
                value = walkExpr (bpath ++ [ 0 ]) binding.value;
              })
          (b.length bindings);
    in walkExpr [ ] expr;
}
