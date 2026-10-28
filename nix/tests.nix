# Tests for nix-parsec/nix

let
  nix = import ./default.nix;
  b = builtins;
in rec {
  tests = [
    # arithmetic and operators
    { name = "add"; expr = "1+2"; expected = 3; }
    { name = "sub"; expr = "5-2"; expected = 3; }
    { name = "mul"; expr = "3*4"; expected = 12; }
    { name = "div"; expr = "8 / 2"; expected = 4; }
    { name = "precedence"; expr = "1 + 2 * 3"; expected = 7; }
    { name = "string-concat"; expr = "\"a\" + \"b\""; expected = "ab"; }
    { name = "string-int-concat"; expr = "\"n=\" + \"1\""; expected = "n=1"; }
    { name = "list-concat"; expr = "[1] ++ [2 3]"; expected = [1 2 3]; }
    { name = "attr-merge"; expr = "({ a = 1; } // { b = 2; })"; expected = { a = 1; b = 2; }; }

    # variables, scope, builtins
    { name = "scope-fn"; type = "attrs"; input = { scope.foo = _: "foo"; text = "foo 3"; }; expected = "foo"; }
    { name = "scope-var"; type = "attrs"; input = { scope.x = 5; text = "x + 1"; }; expected = 6; }
    { name = "builtin-override"; type = "attrs"; input = { scope.builtins = b // { map = _: 42; }; text = "map [ 1 ]"; }; expected = 42; }
    { name = "builtin-override-add"; type = "attrs"; input = { scope.builtins = b // { add = left: right: (left.__add or b.add) left right; }; text = "{ id = 10; __add = self: adder: self.id + (adder.id or adder); } + 5"; }; expected = 15; }
    { name = "builtin-override-add-lazy"; type = "attrs"; input = { scope.builtins = b // { add = left: right: (left.__add or b.add) left right; }; text = "{ id = 10; boom = throw \"e\"; __add = self: adder: self.id + (adder.id or adder); } + 5"; }; expected = 15; }
    { name = "builtin-override-sub"; type = "attrs"; input = { scope.builtins = b // { sub = left: right: (left.__sub or b.sub) left right; }; text = "{ id = 10; __sub = self: other: self.id - other; } - 4"; }; expected = 6; }
    { name = "builtin-self-ref"; type = "attrs"; input = { scope.builtins = { foo = 1; }; text = "builtins.builtins.foo"; }; expected = 1; }
    { name = "builtin-call"; expr = "builtins.concatStringsSep \",\" [\"a\" \"b\"]"; expected = "a,b"; }
    { name = "undefined-var"; expr = "nope"; expectThrow = "undefined variable 'nope'"; }
    { name = "global-builtin"; expr = "map (x: x + 1) [ 1 2 ]"; expected = [ 2 3 ]; }
    { name = "global-builtin-shadow-let"; expr = "let map = 1; in map"; expected = 1; }
    { name = "global-builtin-beats-with"; expr = "with { map = 1; }; map (x: x + 1) [ 1 ]"; expected = [ 2 ]; }
    { name = "global-builtin-shadow-lambda"; expr = "let toString = x: \"s\"; in toString 1"; expected = "s"; }
    { name = "non-global-builtin-undefined"; expr = "functionArgs"; expectThrow = "undefined variable 'functionArgs'"; }
    { name = "undefined-dead-branch"; expr = "if false then nope else 1"; expectThrow = "undefined variable 'nope'"; }
    { name = "undefined-unused-let"; expr = "let x = nope; in 1"; expectThrow = "undefined variable 'nope'"; }
    { name = "undefined-lambda-body"; expr = "let f = x: nope; in 1"; expectThrow = "undefined variable 'nope'"; }
    { name = "undefined-nested-attr"; expr = "let x = { a = nope; }; in 1"; expectThrow = "undefined variable 'nope'"; }
    { name = "undefined-not-catchable"; expr = "builtins.tryEval (nope)"; expectThrow = "undefined variable 'nope'"; }
    { name = "lazy-value-dead-branch"; expr = "if false then (builtins.throw \"boom\") else 1"; expected = 1; }
    { name = "lazy-value-unused-let"; expr = "let x = builtins.throw \"boom\"; in 1"; expected = 1; }
    { name = "lazy-value-unused-attr"; expr = "let x = { a = builtins.throw \"boom\"; }; in 1"; expected = 1; }
    { name = "undefined-dynamic-attr"; expr = "let x = { \${nope} = 1; }; in 1"; expectThrow = "undefined variable 'nope'"; }
    { name = "undefined-dynamic-path"; expr = "let x = { a.\${nope} = 1; }; in 1"; expectThrow = "undefined variable 'nope'"; }
    { name = "undefined-rec-inherit"; expr = "let x = rec { inherit nope; }; in 1"; expectThrow = "undefined variable 'nope'"; }
    { name = "with-defers-undefined"; expr = "let x = with {}; nope; in 1"; expected = 1; }
    { name = "with-runtime-undefined"; expr = "with {}; nope"; expectThrow = "undefined variable 'nope'"; }
    { name = "with-env-lazy"; expr = "with (throw \"e\"); 1"; expected = 1; }
    { name = "with-env-missing-var-throw"; expr = "with (throw \"e\"); x"; expectThrow = true; }
    { name = "with-nonset-lookup-throw"; expr = "with 1; x"; expectThrow = true; }
    { name = "store-dir"; expr = "__storeDir"; expected = b.storeDir; }
    # let / rec / with / if
    { name = "let"; expr = "let x = 10; in x * 2"; expected = 20; }
    { name = "let-shadow"; expr = "let x = 1; in let x = 2; in x"; expected = 2; }
    { name = "let-lazy"; expr = "let x = 1; y = throw \"boom\"; in x"; expected = 1; }
    { name = "memo-trace-once"; expr = "let f = builtins.trace \"t\" 1; in [ f f f ]"; expected = [ 1 1 1 ]; }
    { name = "memo-shared-value"; expr = "let f = builtins.trace \"t\" (x: x); in [ f ] == [ f ]"; expected = true; }
    { name = "memo-throw-once"; expr = "let f = throw \"boom\"; in [ f ]"; expectThrow = true; }
    { name = "rec"; expr = "rec { x = 1; y = x + 1; }.y"; expected = 2; }
    { name = "with"; expr = "with {x = 9;}; x"; expected = 9; }
    { name = "with-let-wins"; expr = "let x = 1; in with { x = 2; }; x"; expected = 1; }
    { name = "with-nested"; expr = "with { x = 2; }; with { x = 3; }; x"; expected = 3; }
    { name = "with-inner-let-wins"; expr = "with { x = 1; }; let x = 2; in with { x = 3; }; x"; expected = 2; }
    { name = "with-lexical-lambda"; expr = "(x: with { x = 2; }; x) 1"; expected = 1; }
    { name = "if-true"; expr = "if true then 5 else 6"; expected = 5; }
    { name = "if-false"; expr = "if false then 5 else 6"; expected = 6; }
    { name = "if-nested"; expr = "if true then (if false then 1 else 2) else 3"; expected = 2; }
    { name = "legacy-let"; expr = "let { a = 1; body = a; }"; expected = 1; }
    { name = "legacy-let-missing-body-throw"; expr = "let { a = 1; }"; expectThrow = true; }
    { name = "legacy-let-in-list"; expr = "[ let { body = 1; } 2 ]"; expected = [ 1 2 ]; }

    # attr / list
    { name = "attr-access"; expr = "{ x = 7; }.x"; expected = 7; }
    { name = "let-attr"; expr = "let s = { a = 3; }; in s.a"; expected = 3; }
    { name = "list-length"; expr = "builtins.length [1 2 3]"; expected = 3; }
    { name = "high-expr-operand-throw"; expr = "[ if true then 1 else 2 ]"; expectThrow = true; }
    { name = "high-expr-paren"; expr = "[ (if true then 1 else 2) ]"; expected = [ 1 ]; }
    { name = "or-let-default-throw"; expr = "let a = { b = 1; }; in a.b or let x = 1; in x"; expectThrow = true; }
    { name = "attr-value"; expr = "let s = { a = 3; b = 4; }; in s.a + s.b"; expected = 7; }

    # lambdas
    { name = "lambda-ident"; expr = "let f = x: x + 1; in f 4"; expected = 5; }
    { name = "lambda-immediate"; expr = "(x: x * 2) 5"; expected = 10; }
    { name = "lambda-pattern-default"; expr = "let f = { a, b ? 10 }: a + b; in f { a = 5; }"; expected = 15; }
    { name = "lambda-pattern-override"; expr = "let f = { a, b ? 10 }: a + b; in f { a = 5; b = 1; }"; expected = 6; }
    { name = "lambda-at-post"; expr = "let f = args@{ a, ... }: a; in f { a = 7; z = 1; }"; expected = 7; }
    { name = "lambda-at-pre"; expr = "let f = { a, ... }@args: args.a; in f { a = 3; }"; expected = 3; }
    { name = "lambda-curried"; expr = "let f = x: y: x + y; in f 2 3"; expected = 5; }
    { name = "lambda-map"; expr = "builtins.map (x: x * 2) [1 2 3]"; expected = [2 4 6]; }
    { name = "lambda-filter"; expr = "builtins.filter (x: x > 2) [1 2 3 4]"; expected = [3 4]; }
    { name = "lambda-fold"; expr = "builtins.foldl' (a: b: a + b) 0 [1 2 3]"; expected = 6; }
    { name = "lambda-missing-arg"; expr = "let f = { a }: a; in f { b = 1; }"; expectThrow = true; }
    { name = "lambda-missing-required"; expr = "let f = { a }: 1; in f {}"; expectThrow = true; }
    { name = "pattern-duplicate"; expr = "let f = { a, a }: a; in f { a = 1; }"; expectThrow = true; }
    { name = "pattern-at-duplicate-post"; expr = "let f = { a }@a: a; in f { a = 1; }"; expectThrow = true; }
    { name = "pattern-at-duplicate-pre"; expr = "let f = a@{ a }: a; in f { a = 1; }"; expectThrow = true; }
    { name = "pattern-duplicate-default"; expr = "let f = { a ? 1, a ? 2 }: a; in 1"; expectThrow = true; }
    { name = "lambda-default-dep"; expr = "let f = { a, b ? a + 1 }: b; in f { a = 1; }"; expected = 2; }
    { name = "lambda-default-at"; expr = "let f = args@{ a, b ? args.a + 1 }: b; in f { a = 1; }"; expected = 2; }
    { name = "lambda-default-lazy"; expr = "let f = { a ? throw \"x\" }: 1; in f {}"; expected = 1; }
    { name = "lambda-default-lazy-used"; expr = "let f = { a ? throw \"x\" }: a; in f {}"; expectThrow = true; }
    { name = "formals-trailing-comma"; expr = "({ a, b, }: a + b) { a = 1; b = 2; }"; expected = 3; }
    { name = "formals-ellipsis-end"; expr = "({ a, ... }: a) { a = 1; b = 2; }"; expected = 1; }
    { name = "formals-ellipsis-middle-throw"; expr = "({ a, ..., b }: 1) { a = 1; b = 2; }"; expectThrow = true; }
    { name = "formals-ellipsis-leading-throw"; expr = "({ ..., a }: 1) { a = 1; }"; expectThrow = true; }
    { name = "formals-ellipsis-multiple-throw"; expr = "({ ..., ... }: 1) {}"; expectThrow = true; }
    { name = "formals-ellipsis-trailing-comma-throw"; expr = "({ a, ..., }: 1) { a = 1; }"; expectThrow = true; }
    { name = "lambda-functor"; expr = "let f = { __functor = self: x: x + 1; }; in f 2"; expected = 3; }

    # comparison, boolean, unary
    { name = "cmp-gt"; expr = "3 > 2"; expected = true; }
    { name = "cmp-lt"; expr = "1 < 2"; expected = true; }
    { name = "cmp-eq"; expr = "1 == 1"; expected = true; }
    { name = "cmp-neq"; expr = "1 != 2"; expected = true; }
    { name = "cmp-le"; expr = "2 <= 2"; expected = true; }
    { name = "cmp-ge"; expr = "3 >= 2"; expected = true; }
    { name = "cmp-float-int"; expr = "1 < 2.0"; expected = true; }
    { name = "cmp-list"; expr = "[1] < [2]"; expected = true; }
    { name = "cmp-list-prefix"; expr = "[1 2] < [1 3]"; expected = true; }
    { name = "cmp-list-eq"; expr = "[1] <= [1]"; expected = true; }
    { name = "cmp-list-lazy"; expr = "[1] < [2 (throw \"boom\")]"; expected = true; }
    { name = "bool-and"; expr = "true && false"; expected = false; }
    { name = "bool-or"; expr = "true || false"; expected = true; }
    { name = "bool-not"; expr = "!true"; expected = false; }
    { name = "bool-impl"; expr = "false -> true"; expected = true; }
    { name = "neg"; expr = "-5 + 8"; expected = 3; }
    { name = "neg-vs-hasattr"; expr = "-1 ? a"; expected = false; }
    { name = "not-vs-hasattr"; expr = "!true ? a"; expected = true; }
    { name = "not-vs-cmp"; expr = "!true == false"; expected = true; }
    { name = "short-circuit-and"; expr = "false && throw \"boom\""; expected = false; }
    { name = "short-circuit-or"; expr = "true || throw \"boom\""; expected = true; }
    { name = "short-circuit-impl"; expr = "false -> throw \"boom\""; expected = true; }
    { name = "bool-shadow-let"; expr = "let true = 1; in true"; expected = 1; }
    { name = "bool-shadow-false"; expr = "let false = 1; in false"; expected = 1; }
    { name = "bool-shadow-null"; expr = "let null = 1; in null"; expected = 1; }
    { name = "bool-shadow-type"; expr = "let true = 1; in builtins.typeOf true"; expected = "int"; }
    { name = "bool-literal-beats-with"; expr = "with { true = 1; }; builtins.typeOf true"; expected = "bool"; }
    { name = "bool-attr-name"; expr = "{ true = 1; }.true"; expected = 1; }
    { name = "bool-shadow-rec"; expr = "rec { true = 1; b = true; }.b"; expected = 1; }
    { name = "bool-shadow-lambda"; expr = "({ true }: true) { true = 5; }"; expected = 5; }
    { name = "bool-and-rhs-nonbool"; expr = "true && 1"; expectThrow = true; }
    { name = "bool-or-rhs-nonbool"; expr = "false || 1"; expectThrow = true; }
    { name = "bool-impl-rhs-nonbool"; expr = "true -> 1"; expectThrow = true; }
    { name = "bool-and-lhs-nonbool"; expr = "1 && true"; expectThrow = true; }
    { name = "bool-or-lhs-nonbool"; expr = "1 || true"; expectThrow = true; }
    { name = "bool-impl-lhs-nonbool"; expr = "1 -> true"; expectThrow = true; }
    { name = "precedence-cmp"; expr = "1 + 2 * 3 == 7"; expected = true; }
    { name = "cmp-rel-eq"; expr = "1 < 2 == true"; expected = true; }
    { name = "cmp-eq-rel"; expr = "1 == 2 < 3"; expected = false; }
    { name = "cmp-rel-chain-throw"; expr = "1 < 2 < 3"; expectThrow = true; }
    { name = "cmp-eq-chain-throw"; expr = "true == true == true"; expectThrow = true; }
    { name = "define-lambda"; expr = "let f = x: x * x; in f (f 2)"; expected = 16; }
    { name = "comment-in-string"; expr = "\"a/*b*/c\""; expected = "a/*b*/c"; }

    # equality of functions
    { name = "eq-fn-top-false"; expr = "let f = x: x; in f == f"; expected = false; }
    { name = "eq-fn-list-same"; expr = "let f = x: x; in [ f ] == [ f ]"; expected = true; }
    { name = "eq-fn-list-diff"; expr = "let f = x: x; g = x: x; in [ f ] == [ g ]"; expected = false; }
    { name = "eq-fn-attr-same"; expr = "let f = x: x; in { a = f; } == { a = f; }"; expected = true; }
    { name = "eq-fn-attr-diff"; expr = "let f = x: x; g = x: x; in { a = f; } == { a = g; }"; expected = false; }
    { name = "eq-fn-nested"; expr = "let f = x: x; in { a = { b = [ f ]; }; } == { a = { b = [ f ]; }; }"; expected = true; }
    { name = "eq-fn-inline-diff"; expr = "[ (x: x) ] == [ (x: x) ]"; expected = false; }
    { name = "eq-fn-alias"; expr = "let f = x: x; g = f; in [ f ] == [ g ]"; expected = true; }
    { name = "eq-str-list"; expr = "let x = \"a\"; in [ x ] == [ \"a\" ]"; expected = true; }
    { name = "eq-fn-neq"; expr = "let f = x: x; in f != f"; expected = true; }

    # string interpolation
    { name = "string-interp-var"; expr = "let x = \"world\"; in \"hello \${x}\""; expected = "hello world"; }
    { name = "string-interp-expr"; expr = "\"sum=\${toString (2 * 3)}!\""; expected = "sum=6!"; }
    { name = "string-interp-nested"; expr = "\"\${\"in\${\"ner\"}\"}\""; expected = "inner"; }
    { name = "string-escape-dollar"; expr = "\"a\\\${b}\""; expected = "a\${b}"; }
    { name = "string-interp-int-throw"; expr = "let x = 1; in \"\${x}\""; expectThrow = true; }
    { name = "string-interp-null-throw"; expr = "let x = null; in \"\${x}\""; expectThrow = true; }
    { name = "string-interp-bool-throw"; expr = "let x = true; in \"\${x}\""; expectThrow = true; }
    { name = "string-interp-float-throw"; expr = "let x = 1.5; in \"\${x}\""; expectThrow = true; }
    { name = "string-interp-set-tostring"; expr = "let x = { __toString = self: \"x\"; }; in \"\${x}\""; expected = "x"; }
    { name = "string-plus-outpath"; expr = "\"a\" + { outPath = \"o\"; }"; expected = "ao"; }
    { name = "string-plus-tostring"; expr = "\"a\" + { __toString = self: \"o\"; }"; expected = "ao"; }
    { name = "string-plus-int-throw"; expr = "\"a\" + 1"; expectThrow = true; }
    { name = "string-interp-set-outpath"; expr = "let x = { outPath = \"o\"; }; in \"\${x}\""; expected = "o"; }

    # inherit
    { name = "inherit-attr"; expr = "let x = 5; in { inherit x; }.x"; expected = 5; }
    { name = "inherit-from"; expr = "let s = { a = 1; b = 2; }; in { inherit (s) a b; }.b"; expected = 2; }
    { name = "attr-or-name"; expr = "{ or = 1; }.or"; expected = 1; }
    { name = "attr-or-dynamic"; expr = "{ or = 1; }.\${ \"or\" }"; expected = 1; }
    { name = "attr-or-nested"; expr = "{ a.or = 1; }.a.or"; expected = 1; }
    { name = "attr-or-inherit"; expr = "let or = 1; in { inherit or; }.or"; expected = 1; }
    { name = "let-or-binding"; expr = "let or = 1; in 2"; expected = 2; }
    { name = "or-as-variable-throw"; expr = "let or = 1; in or"; expectThrow = true; }
    { name = "inherit-let"; expr = "let x = 3; in let inherit x; in x + 1"; expected = 4; }
    { name = "inherit-from-let"; expr = "let s = { a = 3; }; in let inherit (s) a; in a"; expected = 3; }
    { name = "inherit-rec-outer"; expr = "let x = 5; in (rec { inherit x; }).x"; expected = 5; }
    { name = "inherit-rec-from"; expr = "rec { x = { a = 1; }; inherit (x) a; }.a"; expected = 1; }
    { name = "inherit-from-quoted"; expr = "let x = { \"a b\" = 1; }; in { inherit (x) \"a b\"; }"; expected = { "a b" = 1; }; }
    { name = "inherit-from-static-dynamic"; expr = "let x = { \"a b\" = 1; }; in { inherit (x) \${ \"a b\" }; }"; expected = { "a b" = 1; }; }
    { name = "inherit-plain-quoted"; expr = "let \"a b\" = 1; in { inherit \"a b\"; }"; expected = { "a b" = 1; }; }
    { name = "inherit-dynamic-throw"; expr = "let x = { a = 1; }; y = \"a\"; in { inherit (x) \${y}; }"; expectThrow = true; }

    # assert
    { name = "assert-pass"; expr = "assert 1 < 2; 42"; expected = 42; }
    { name = "assert-fail"; expr = "assert 2 < 1; 42"; expectThrow = true; }

    # comments
    { name = "comment-line"; expr = "1 + 2 # adds\n+ 3"; expected = 6; }
    { name = "comment-block"; expr = "1 + /* two */ 2"; expected = 3; }
    { name = "comment-nested-throw"; expr = "1 + /* a /* b */ c */ 2"; expectThrow = true; }

    # paths and import
    { name = "abs-path"; expr = "/tmp/foo"; expected = /tmp/foo; }
    { name = "rel-path"; type = "attrs"; input = { cwd = "/tmp"; text = "./foo"; }; expected = /tmp/foo; }
    { name = "rel-up-path"; type = "attrs"; input = { cwd = "/tmp/x"; text = "../foo"; }; expected = /tmp/foo; }
    { name = "bare-rel-path"; type = "attrs"; input = { cwd = "/tmp"; text = "foo/bar"; }; expected = /tmp/foo/bar; }
    { name = "search-path-import"; type = "attrs"; input = { scope.__nixPath = [ { prefix = ""; path = ./fixtures; } ]; text = "import <simple.nix>"; }; expected = { a = 1; b = 2; }; }
    { name = "search-path-prefix"; type = "attrs"; input = { scope.__nixPath = [ { prefix = "lib"; path = ./fixtures; } ]; text = "import <lib/simple.nix>"; }; expected = { a = 1; b = 2; }; }
    { name = "search-path-application"; type = "attrs"; input = { scope.__nixPath = [ { prefix = ""; path = ./fixtures; } ]; text = "let f = x: \"ok\"; in f <simple.nix>"; }; expected = "ok"; }
    { name = "find-file-global"; type = "attrs"; input = { scope.__nixPath = [ { prefix = ""; path = ./fixtures; } ]; text = "import (__findFile __nixPath \"simple.nix\")"; }; expected = { a = 1; b = 2; }; }
    { name = "search-path-missing-throw"; expr = "<no-such-thing>"; expectThrow = true; }
    { name = "search-path-empty-segment-throw"; type = "attrs"; input = { scope.__nixPath = [ { prefix = ""; path = ./fixtures; } ]; text = "<a//b>"; }; expectThrow = true; }
    { name = "path-interp"; type = "attrs"; input = { cwd = "/tmp"; text = "let x = \"foo\"; in ./\${x}"; }; expected = /tmp/foo; }
    { name = "path-interp-str"; type = "attrs"; input = { cwd = "/tmp"; text = "let x = \"foo\"; in toString ./\${x}"; }; expected = "/tmp/foo"; }
    { name = "path-bare-interp"; type = "attrs"; input = { cwd = "/tmp"; text = "let x = \"bar\"; in toString foo/\${x}"; }; expected = "/tmp/foo/bar"; }
    { name = "path-plus-string"; type = "attrs"; input = { cwd = "/tmp"; text = "toString (./foo + \"bar\")"; }; expected = "/tmp/foobar"; }
    { name = "path-plus-path"; type = "attrs"; input = { cwd = "/tmp"; text = "toString (./foo + ./bar)"; }; expected = "/tmp/foo/tmp/bar"; }
    { name = "path-plus-outpath"; type = "attrs"; input = { cwd = "/tmp"; text = "toString (./a + { outPath = \"o\"; })"; }; expected = "/tmp/ao"; }
    { name = "path-plus-int-throw"; type = "attrs"; input = { cwd = "/tmp"; text = "./a + 1"; }; expectThrow = true; }
    { name = "path-trailing-slash-throw"; type = "attrs"; input = { cwd = "/tmp"; text = "toString ./foo/"; }; expectThrow = true; }
    { name = "path-double-slash-throw"; type = "attrs"; input = { cwd = "/tmp"; text = "toString ./foo//bar"; }; expectThrow = true; }
    { name = "path-trailing-interp-ok"; type = "attrs"; input = { cwd = "/tmp"; text = "let x = \"\"; in toString ./foo/\${x}"; }; expected = "/tmp/foo"; }
    { name = "path-tilde-home"; expr = "toString ~/x"; expected = (b.getEnv "HOME") + "/x"; }
    { name = "path-tilde-char-throw"; expr = "toString ./a~b"; expectThrow = true; }
    { name = "path-bare-tilde-throw"; expr = "toString foo~bar/baz"; expectThrow = true; }
    { name = "path-tilde-app"; expr = "foo~/bar"; expectThrow = true; }
    { name = "path-interp-int-throw"; type = "attrs"; input = { cwd = "/tmp"; text = "let x = 1; in ./\${x}"; }; expectThrow = true; }
    { name = "path-interp-string"; type = "attrs"; input = { cwd = "/tmp"; text = "let x = toString 1; in toString ./\${x}"; }; expected = "/tmp/1"; }
    { name = "rel-path-no-cwd"; expr = "./foo"; expectThrow = true; }
    { name = "path-dot-normalised"; type = "attrs"; input = { cwd = "/tmp/xyz"; text = "toString ./."; }; expected = "/tmp/xyz"; }
    { name = "path-dotdot-normalised"; type = "attrs"; input = { cwd = "/tmp/xyz/sub"; text = "toString ./.."; }; expected = "/tmp/xyz"; }
    { name = "path-inner-dot-normalised"; type = "attrs"; input = { cwd = "/tmp/xyz"; text = "toString ./a/./b"; }; expected = "/tmp/xyz/a/b"; }
    { name = "path-inner-dotdot-normalised"; type = "attrs"; input = { cwd = "/tmp/xyz"; text = "toString ./a/../b"; }; expected = "/tmp/xyz/b"; }
    { name = "path-trailing-dot-normalised"; type = "attrs"; input = { cwd = "/tmp/xyz"; text = "toString ./sub/./."; }; expected = "/tmp/xyz/sub"; }
    { name = "path-abs-dot-normalised"; type = "attrs"; input = { cwd = "/tmp/xyz"; text = "toString /tmp/./xyz/../xyz"; }; expected = "/tmp/xyz"; }
    { name = "path-above-root-clamped"; type = "attrs"; input = { cwd = "/tmp/xyz"; text = "toString ./../../.."; }; expected = "/"; }
    { name = "import-dot-normalised"; type = "attrs"; input = { cwd = ./fixtures; text = "import ./simple.nix"; }; expected = { a = 1; b = 2; }; }
    { name = "import-inner-dot-normalised"; type = "attrs"; input = { cwd = ./fixtures; text = "import ./../fixtures/./simple.nix"; }; expected = { a = 1; b = 2; }; }
    { name = "import-fixture"; type = "attrs"; input = { text = "import ./fixtures/simple.nix"; }; expected = { a = 1; b = 2; }; }
    { name = "import-access"; type = "attrs"; input = { text = "(import ./fixtures/simple.nix).b + 1"; }; expected = 3; }

    # attribute paths
    { name = "attrpath"; expr = "{ a.b = 1; a.c = 2; }.a.c"; expected = 2; }
    { name = "attrpath-deep"; expr = "{ a.b.c = 5; }.a.b.c"; expected = 5; }
    { name = "attrpath-merge-literal"; expr = "{ a = { b = 1; }; a.c = 2; }.a.c"; expected = 2; }
    { name = "attrpath-let"; expr = "let a.b = 1; a.c = 2; in a.b + a.c"; expected = 3; }
    { name = "attrpath-let-var"; expr = "let a.b = 1; in a"; expected = { b = 1; }; }
    { name = "attrpath-duplicate"; expr = "{ a = 1; a = 2; }"; expectThrow = true; }
    { name = "attrpath-merge-empty"; expr = "{ a.b = 1; a = {}; }.a.b"; expected = 1; }
    { name = "attrpath-merge-two-literals"; expr = "{ a = { b = 1; }; a = { c = 2; }; }.a.c"; expected = 2; }
    { name = "attrpath-merge-nested"; expr = "{ a.b.c = 1; a.b = { d = 2; }; }.a.b.d"; expected = 2; }
    { name = "rec-merge-self"; expr = "{ a = rec { b = 1; }; a.d = b; }.a.d"; expected = 1; }
    { name = "rec-merge-dynamic-name"; expr = "{ a = rec { b = \"c\"; }; a.\${b} = 2; }.a.c"; expected = 2; }
    { name = "rec-merge-dynamic-outer"; expr = "let b = \"c\"; in rec { a = { b = 1; }; a.\${b} = 2; c = a.c; }"; expected = { a = { b = 1; c = 2; }; c = 2; }; }
    { name = "rec-merge-dynamic-inner"; expr = "rec { a = rec { b = \"c\"; }; a.\${b} = 2; }"; expected = { a = { b = "c"; c = 2; }; }; }
    { name = "rec-merge-chain"; expr = "{ a = rec { b = 1; }; a.c = 2; a.d = c; }.a.d"; expected = 2; }
    { name = "rec-self-dynamic-name"; expr = "rec { b = \"c\"; \${b} = 2; }.c"; expected = 2; }
    { name = "rec-dynamic-not-lexical-throw"; expr = "rec { x = \"y\"; \${x} = 2; z = y; }"; expectThrow = true; }
    { name = "rec-dynamic-literal-lexical"; expr = "rec { \${ \"x\" } = 1; y = x; }.y"; expected = 1; }
    { name = "rec-merge-right-rec-throw"; expr = "{ a = { b = 1; }; a = rec { c = b; }; }.a.b"; expectThrow = true; }
    { name = "rec-merge-nonrec-add-throw"; expr = "{ a = { b = 1; }; a = rec { c = 2; }; a.d = b; }.a.d"; expectThrow = true; }
    { name = "let-dyn-literal-ok"; expr = "let \${ \"a\" } = 1; in a"; expected = 1; }
    { name = "let-dyn-var-throw"; expr = "let b = \"c\"; \${b} = 2; in c"; expectThrow = true; }
    { name = "let-dyn-expr-throw"; expr = "let \${ \"a\" + \"b\" } = 1; in ab"; expectThrow = true; }
    { name = "merge-nonliteral-throw"; expr = "{ a = let x = { b = 1; }; in x; a.c = 2; }"; expectThrow = true; }
    { name = "merge-conflict-throw"; expr = "{ a = { b = 1; }; a = { b = 2; }; }"; expectThrow = true; }
    { name = "merge-inherit-throw"; expr = "{ a = { b = 1; }; inherit ({ c = 2; }) a; }"; expectThrow = true; }

    # or defaults and ? operator
    { name = "or-present"; expr = "{ a = 1; }.a or 9"; expected = 1; }
    { name = "or-missing"; expr = "{ a = 1; }.b or 9"; expected = 9; }
    { name = "or-non-selection-throw"; expr = "1 or 2"; expectThrow = true; }
    { name = "or-application-throw"; expr = "let f = x: x; in f 1 or 2"; expectThrow = true; }
    { name = "or-chain-literal-throw"; expr = "let a = { b = 1; }; in a.b or 2 or 3"; expectThrow = true; }
    { name = "or-chain-selection"; expr = "let a = { b = 1; }; c = { d = 2; }; in a.b or c.d or 3"; expected = 1; }
    { name = "or-deep-missing"; expr = "{ a = { b = 1; }; }.a.c or 7"; expected = 7; }
    { name = "or-precedence"; expr = "{}.x or 1 + 2"; expected = 3; }
    { name = "or-chain"; expr = "{ a.b = 1; }.a.b or 4"; expected = 1; }
    { name = "or-nonset-default"; expr = "let a = 1; in a.b or 2"; expected = 2; }
    { name = "or-existing-throw"; expr = "{ a = throw \"boom\"; }.a or 1"; expectThrow = true; }
    { name = "hasattr-true"; expr = "{ a.b = 1; } ? a.b"; expected = true; }
    { name = "hasattr-false"; expr = "{ a = 1; } ? a.b"; expected = false; }
    { name = "hasattr-simple"; expr = "{ a = 1; } ? a"; expected = true; }
    { name = "hasattr-precedence"; expr = "{ a = 1; } ? a && true"; expected = true; }

    # dynamic attribute names
    { name = "dyn-select"; expr = "let k = \"a\"; in { a = 5; }.\${k}"; expected = 5; }
    { name = "dyn-select-expr"; expr = "{ a = 5; }.\${\"a\"}"; expected = 5; }
    { name = "dyn-binding"; expr = "let k = \"x\"; in { \${k} = 7; }.x"; expected = 7; }
    { name = "dyn-binding-expr"; expr = "{ \${\"a\" + \"b\"} = 9; }.ab"; expected = 9; }
    { name = "dyn-path"; expr = "let k = \"b\"; in { a.\${k} = 3; }.a.b"; expected = 3; }
    { name = "dyn-hasattr"; expr = "let k = \"a\"; in { a = 1; } ? \${k}"; expected = true; }
    { name = "dyn-null-skip"; expr = "let k = null; in { \${k} = 1; x = 2; }"; expected = { x = 2; }; }
    { name = "dyn-null-nested"; expr = "{ a.\${null} = 1; }"; expected = { a = { }; }; }
    { name = "dyn-null-select-throw"; expr = "{ a = 1; }.\${null}"; expectThrow = true; }
    { name = "dyn-int-throw"; expr = "let k = 1; in { \${k} = 1; }"; expectThrow = true; }
    { name = "dyn-path-throw"; expr = "{ \${./examples} = 1; }"; expectThrow = true; }

    # floats and quoted attribute names
    { name = "float-add"; expr = "1.5 + 2.25"; expected = 3.75; }
    { name = "float-mul"; expr = "2.0 * 3.5"; expected = 7.0; }
    { name = "float-exp"; expr = "1.5e2"; expected = 150.0; }
    { name = "float-trailing-dot"; expr = "1."; expected = 1.0; }
    { name = "float-leading-dot"; expr = ".5"; expected = 0.5; }
    { name = "float-exp-no-frac"; expr = "1.e2"; expected = 100.0; }
    { name = "int-leading-zero"; expr = "01"; expected = 1; }
    { name = "float-cmp"; expr = "1.5 < 2.5"; expected = true; }
    { name = "quoted-attr"; expr = "{ \"foo\" = 1; }.foo"; expected = 1; }
    { name = "quoted-keyword"; expr = "{ \"if\" = 2; }.\"if\""; expected = 2; }
    { name = "quoted-dotted"; expr = "{ a.\"b\" = 3; }.a.b"; expected = 3; }
    { name = "quoted-interp"; expr = "let k = \"x\"; in { \"\${k}\" = 4; }.x"; expected = 4; }

    # URI literals (deprecated in Nix, still accepted)
    { name = "uri-literal"; expr = "http://example.com"; expected = "http://example.com"; }
    { name = "uri-scheme-plus"; expr = "git+https://example.com/x"; expected = "git+https://example.com/x"; }
    { name = "uri-mailto"; expr = "mailto:a@b"; expected = "mailto:a@b"; }
    { name = "uri-not-lambda"; expr = "a:b"; expected = "a:b"; }
    { name = "uri-space-is-lambda"; expr = "(a: b) 1"; expectThrow = true; }
    { name = "uri-in-list"; expr = "[ http://a b://c ]"; expected = [ "http://a" "b://c" ]; }

    # indented strings
    { name = "indented-basic"; expr = "''\n    foo\n    bar\n  ''"; expected = "foo\nbar\n"; }
    { name = "indented-extra-indent"; expr = "''\n      foo\n    ''"; expected = "foo\n"; }
    { name = "indented-single-line"; expr = "''foo''"; expected = "foo"; }
    { name = "indented-nested"; expr = "''\n    a\n      b\n  ''"; expected = "a\n  b\n"; }
    { name = "indented-blank"; expr = "''\n    a\n\n    b\n  ''"; expected = "a\n\nb\n"; }
    { name = "indented-interp"; expr = "''\n    a \${toString 1}\n    b\n  ''"; expected = "a 1\nb\n"; }
    { name = "indented-escape-dollar"; expr = "''\n    a ''$b\n  ''"; expected = "a $b\n"; }
    { name = "indented-escape-quotes"; expr = "''\n    '''\n  ''"; expected = "''\n"; }
    { name = "indented-escape-newline"; expr = "''''\\n''"; expected = "\n"; }
    { name = "indented-escape-tab"; expr = "''''\\t''"; expected = "\t"; }
  ];
  
  run = map (t:
    let
      result =
        if t ? expectThrow then
          let
            r = b.tryEval (let v =
              if t.type or null == "attrs" then nix.eval t.input else nix.eval t.expr;
            in b.deepSeq v v);
          in if r.success then { unexpected = r.value; } else { threw = true; }
        else if t.type or null == "attrs" then nix.eval t.input
        else nix.eval t.expr;
      passed =
        if t ? expectThrow then
          (result ? threw)
        else result == t.expected;
    in { inherit (t) name; inherit passed; actual = result; expected = t.expected or null; }
  ) tests;
  
  passedCount = builtins.length (builtins.filter (x: x.passed) run);
  summary = {
    total = builtins.length run + builtins.length hostTests;
    passed = passedCount + hostPassed;
    failed = builtins.filter (x: !x.passed) run;
  };

  # Tests for the value that is handed back to the caller. It must be plain
  # Nix data: the internal thunk representation must never leak out.
  hostTests = [
    {
      name = "host-plain-attrset";
      value = nix.eval "{ yoi = null; }";
      expected = { yoi = null; };
      check = v: v == { yoi = null; };
    }
    {
      name = "host-plain-from-lambda";
      value = (nix.eval "x: { yoi = null; }") null;
      expected = { yoi = null; };
      check = v: v == { yoi = null; };
    }
    {
      name = "host-plain-nested";
      value = (nix.eval "x: { a = { b = [ 1 2 ]; }; }") null;
      expected = { a = { b = [ 1 2 ]; }; };
      check = v: v == { a = { b = [ 1 2 ]; }; };
    }
    {
      name = "host-no-thunk-marker";
      value = (nix.eval "x: { yoi = null; }") null;
      expected = true;
      check = v: !(v ? __thunk) && !(v.yoi ? __thunk);
    }
  ];

  hostRun = builtins.map (t:
    { inherit (t) name; actual = t.check t.value; passed = t.check t.value; }
  ) hostTests;

  hostPassed = builtins.length (builtins.filter (x: x.passed) hostRun);
}
