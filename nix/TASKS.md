# TASKS: nix-parsec/nix

## Phase 0: Project Setup
- [x] Create `./nix/` directory
- [x] Create `SPEC.md`
- [x] Create `PRD.md`
- [x] Create `TASKS.md`
- [x] Create base file structure (default.nix, ast.nix, builtins.nix, parser.nix, eval.nix, tests.nix)
- [x] Add basic README in nix/ if helpful

## Phase 1: Lexer & Parser Foundation
- [x] Design Nix AST node types (lit, var, app, lambda, let/rec, attrset, list, op, if, with, inherit, import, string interpolation, etc.)
- [x] Extend/reuse parsec + lexer patterns from repo
- [x] Implement lexer for Nix tokens (numbers, strings, identifiers, operators, keywords)
- [x] Implement parser for minimal subset: numbers, strings, booleans, null, identifiers
- [x] Line comments (`#`) and nested block comments (`/* ... */`)
- [x] Add parser tests

## Phase 2: Environment & Thunks
- [x] Design thunk representation (`{ __thunk = true; env; expr; }` or similar)
- [x] Implement `force` / evaluation helpers
- [x] Implement environment model (scoping for vars/lets/recs)
- [x] Handle scope passing (top-level vars)
- [x] Implement undefined variable detection: throw `"undefined variable '$name'"`
- [x] Track builtin availability and `scope.builtins` override

## Phase 3: Evaluator Core (Minimal)
- [x] Literals (int, float, bool, null, string)
- [x] Variable lookup with correct scoping
- [x] Operator `+` with string concat rule: if left is string -> `__concatStringsSep "" [(thunk x)(thunk y)]` else `__add`
- [x] Operators `-`, `/`, `*` -> `__sub`, `__div`, `__mul`
- [x] Operator `++` -> `__concatLists`
- [x] Operator `//` -> `thunk x // thunk y` (preserve laziness)
- [x] `let ... in ...`
- [x] Attribute sets (basic)
- [x] Lists (basic)
- [x] Function application/lambdas (minimal)
- [x] Ensure lazy evaluation (no eager translation of vars)

## Phase 4: Builtins Bridge (FFI)
- [x] Bridge core builtins without reimplementation
- [x] Handle `builtins.*` access
- [x] Support `scope.builtins` override
- [x] Pass thunks correctly, force when needed
- [x] Special handling for operators as specified
- [x] Test builtin calls

## Phase 5: Path Resolution & Import
- [x] API: string form vs attrset form
- [x] cwd inference via `builtins.unsafeGetAttrPos "text" args` for attrset form
- [x] Relative paths `./`, `../` not supported in string form (throw with guidance)
- [x] Path literals: `/abs`, `./rel`, `../rel`, `~/home`, bare `foo/bar`
- [x] Path interpolation (`./${e}`, `foo/${e}`) and path concatenation
- [x] `import` via builtin `import` with cwd awareness
- [x] Document IFD behavior (user responsibility)

## Phase 6: Expand to More Features (Incremental)
- [x] Conditionals `if ... then ... else ...`
- [x] `with` expressions
- [x] `rec` attribute sets
- [x] Inherit / inherit (from)
- [x] String interpolation
- [x] Function patterns with defaults/`@`
- [x] More operators and precedence (`==`, `!=`, `<`, `<=`, `>`, `>=`, `&&`, `||`, `!`, `->`, unary `-`, left/right associativity)
- [x] Attribute access, dynamic attrs
- [x] Attribute paths in bindings (`a.b.c = v;`) with recursive merging
- [x] `or` defaults (`e.attr or default`)
- [x] `?` operator (`e ? a.b`)
- [x] Dynamic attribute names (`${expr} = v;`, `a.${expr}`)
- [x] Quoted attribute names (`"foo" = v;`, `a."b"`)
- [x] Floats (`1.5`, `.5`, `1.`, `1.5e2`, `1.e2`)
- [x] Indented strings (`''...''`) with indentation stripping and escapes
- [x] `assert`
- [x] Pattern defaults referring to other arguments / `@`, with lazy evaluation
- [x] `__functor` application
- [x] `with` scoping chain (lexical wins, inner frame wins)
- [x] Operator precedence corrections (`!` vs `?`/`++`/`//`)
- [x] Dynamic null attribute names (skip binding)
- [x] String/path interpolation coercion matching Nix
- [x] Search path literals (`<nixpkgs>`, `<nixpkgs/lib>`) resolved via `__nixPath`
- [x] `__findFile` as a global
- [x] Legacy `let { ... }` expressions
- [x] URI literals (`http://example.com`)
- [x] `or` restricted to attribute selections
- [x] High-level expressions (`if`, `assert`, `let`, `with`) only in expression position
- [x] Pattern ellipsis placement rules (trailing only, no trailing comma after `...`)
- [x] Inherit names may be quoted or statically interpolated
- [x] Thunk memoization (values evaluated once, shared between references)
- [x] Nix-compatible equality semantics for functions in collections
- [x] Differential testing against real Nix
- [ ] Try to reach broader compatibility over time

## Phase 7: Testing & Validation
- [x] Create `tests.nix` with basic tests
- [x] Compare against real Nix: `left = ...; right = (import ./nix).eval "..."; left == right`
- [x] Test scope examples from problem
- [x] Test undefined variable errors
- [x] Test operator semantics exactly as specified
- [x] Test laziness cases (`let-lazy`, short-circuit `&&`/`||`)
- [x] Test builtin override via `scope.builtins`
- [x] Test lambdas (ident, pattern/defaults, `@`, currying, builtin HOFs)
- [x] Test string interpolation, inherit, assert
- [x] Test paths and `import`
- [x] Test attribute paths, `or`, `?`, dynamic attrs
- [x] 300 tests passing

## Phase 8: Polish & Documentation
- [x] Update SPEC/PRD/TASKS as needed
- [x] Add usage examples in nix/README or comments
- [x] Error messages polish (Nix-style where sensible)
- [x] Clean up code structure
- [x] Ensure extensible for full support
