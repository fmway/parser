# SPEC: nix-parsec/nix (Nix Self-Parser/Evaluator)

## Overview

We want to evaluate Nix expressions written as strings using Nix itself, without relying on Import-From-Derivation (IFD). The goal is to parse and evaluate a subset of Nix with lazy semantics (thunks), while delegating builtins to the real `builtins` where possible ("FFI style") and allowing controlled overrides via `scope`.

This is a long-term project aiming for full support eventually, but implementation will be incremental starting from a minimal subset.

## Current Status

Implemented and covered by `tests.nix` (300 tests):

- Literals: integers (including leading zeros), floats (`1.5`, `.5`, `1.`,
  `1.5e2`, `1.e2`), booleans, `null`
- Strings: double-quoted with interpolation; indented strings (`''...''`) with
  indentation stripping and `''$`, `'''`, `''\n`, `''\r`, `''\t`, `''\<char>`
- Lists, attribute sets, `rec` attribute sets
- Attribute access, dynamic attributes (`${e}`, including null-skip in
  bindings), quoted attribute names, attribute paths with merging
  (`a.b = v;`; literal-set merging is recursive and `rec` scope is preserved;
  `inherit` never merges; dynamically named rec attributes are not visible as
  variables), `inherit`, `inherit (e) names` (quoted and statically
  interpolated names are allowed)
- `let ... in` (dynamic names only as literal strings, e.g. `${"a"}`), legacy
  `let { ... }`, `with` (lexical bindings win, inner frame wins, the `with`
  expression is only forced on lookup), `if ... then ... else`,
  `assert cond; body`
- Functions: identifier lambdas, currying, patterns with defaults and `...`,
  `@` bindings, defaults referring to other arguments, `__functor`
- Operators: `.`, `?`, unary `-`, `!`, `*`, `/`, `+`, `-`, `++`, `//`,
  `<`, `<=`, `>`, `>=`, `==`, `!=`, `&&`, `||`, `->`
- `or` defaults (only after an attribute selection), `?` attribute tests
- Paths (`/abs`, `./rel`, `../rel`, `~/home`, bare `foo/bar`), path
  interpolation (`./${e}`), path concatenation, search paths (`<nixpkgs>`),
  URI literals, and `import`
- Interpolation coercion matching Nix (strings/paths/`outPath`/`__toString`)
- Line (`#`) and block (`/* ... */`, not nested) comments
- Thunks are memoized: a value is evaluated once, and two references to the
  same binding denote the same value
- Equality follows Nix's rules: functions are never equal at the top level,
  but two elements of a collection that come from the same binding are equal

Known limitations are documented in [`README.md`](README.md#limitations).
The most notable ones:

- `builtins.functionArgs` returns `{}` for evaluator-created pattern lambdas.
- Evaluator errors are `throw`-based, so `builtins.tryEval` catches some errors
  that real Nix does not (undefined variable, type errors, etc.).
- Parse errors include line/column and the most relevant expectation, but the
  wording differs from Nix's parser.

## API

```nix
(import ./nix).eval str        # Eval :: String -> Any
(import ./nix).eval {         # Eval :: { text; cwd?; scope?; } -> Any
  text,
  cwd ? (dirOf (builtins.unsafeGetAttrPos "text" args).file),
  scope ? {},
} @ args
```

- When called as a function of a string, relative paths (`./`, `../`) are **not supported** (relative to "current file" is ambiguous). User must use the attrset form with `cwd` if relative path resolution is needed.
- `scope` contains top-level variables available during evaluation (can override builtins).
- If `scope.builtins` is set, it overrides the builtins provided by the evaluator.

## Evaluation Model

- **Lazy evaluation (thunks)**: Evaluation must be lazy like Nix. Variables are not eagerly translated/resolved into values unless forced. Represent values as thunks when appropriate (`{ __thunk = true; ... }`) and force on demand.
- **Memoization**: A thunk caches its value, so it is evaluated at most once. This keeps side effects (`builtins.trace`) single-shot and lets two references to the same binding denote the same value.
- **FFI to builtins**: Do not reimplement builtins. Call them as-is where possible, passing thunks/values appropriately and forcing when required.
- **Scope precedence**: Lookup order is lexical environment (lambda arguments,
  `let`, `rec`), the `builtins` name, `scope`, the `true`/`false`/`null`
  literal fallback, `__nixPath`/`__storeDir`/`__findFile`, the curated global
  builtins (`map`, `toString`, `import`, `throw`, ...), then active `with`
  frames (innermost first). Lexical bindings always beat `with`; literals and
  global builtins beat `with` too. Other builtins are only available through
  `builtins.*`.
- **Static name resolution**: Names are resolved before evaluation, so an
  unknown name is an error even in a branch that is never taken. This matches
  Nix, where an unknown name is a compile-time error rather than a lazily
  forced value. Only references under `with` are deferred to run time.
  `__curPos` is not supported.
- **Undefined variables**: If a name is not found by the lookup above, throw
  `"undefined variable 'name'"`.

## Operators

Behavior as specified (lazy/thunk-preserving):

| Op | Behavior |
|---|---|
| `x + y` | If type of `x` is string -> call `__concatStringsSep "" [(thunk x) (thunk y)]`. Else call `__add (thunk x) (thunk y)`. |
| `x - y` | `__sub (thunk x) (thunk y)` |
| `x / y` | `__div (thunk x) (thunk y)` |
| `x * y` | `__mul (thunk x) (thunk y)` |
| `x ++ y` | `__concatLists [(thunk x) (thunk y)]` |
| `x // y` | `thunk x // thunk y` (Nix update/merge) |

Note: The evaluator should prefer using the real builtin operations where they exist naturally (`builtins.add`, `builtins.sub`, etc.) or the underscored forms as specified. Be careful about forcing: arguments should remain thunked until the operation requires forcing.

## Builtins

- Curated builtins are available globally (FFI); everything is also accessible
  via `builtins.*`. 
- If `scope.builtins` exists, it overrides builtins.
- `import` should go through builtin `import` behaviorally, but path resolution needs to consider `cwd` (especially for relative paths in attrset form). Using `import` on existing files is not IFD; forcing IFD is up to the user calling code.
- All builtins accessible via `builtins.*` should be bridged without reimplementation where feasible.

## Paths & Relative Resolution

- String form: `eval "..."` - relative paths (`./`, `../`) not supported.
- Attrset form: `eval { text, cwd, scope }` - if relative path appears and resolution is needed, use `cwd` (defaulting to dir of file containing `text` via `builtins.unsafeGetAttrPos "text" args`).
- Absolute paths and store paths follow normal Nix semantics where possible.

## AST

The parser will produce an AST. Structure to be defined as we go (keep simple and extensible). Document node types in code/comments.

## Scoping

- Support `let ... in ...`
- Support `rec { ... }`
- Support `with ...; ...` (advanced feature - implement later if needed, but plan for it)
- Support function arguments/patterns (minimal first, expand over time)
- Attribute sets, lists, strings (including interpolation), numbers, booleans, null
- Inherit
- Dynamic attrs where reasonable

## Errors

- Undefined variable: `"undefined variable '$name'"`
- Parse errors: use Nix-style messages where practical
- Evaluation errors: follow Nix behavior where possible

## Testing Philosophy

- Compare against real Nix evaluation where feasible: `left = 1 + 2; right = nix.eval "1+2"; left == right`
- Start minimal, add tests incrementally
- Focus on thunk/laziness behavior
- Test operator semantics exactly as specified

## Non-Goals (initially)

- Perfect compatibility with every Nix edge case on day 1
- Reimplementing complex builtins
- Handling all exotic syntax immediately - grow incrementally

## References
- This repo: parsec.nix, lexer.nix (parser combinator foundation)
- Nix language semantics (builtins)