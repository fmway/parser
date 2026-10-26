# nix-parsec/nix

A Nix expression **parser and evaluator written in Nix itself**.

It parses a Nix expression from a string and evaluates it inside the Nix
evaluator, so no derivation has to be built just to evaluate code. In other
words, it avoids Import-From-Derivation (IFD) for string evaluation:

```nix
# The usual IFD approach:
#   import (builtins.toFile "expr.nix" "1 + 2")

# With this project:
(import ./nix).eval "1 + 2"
# => 3
```

The parser combinators come from the surrounding [`nix-parsec`](../README.md)
library (`parsec.nix`, `lexer.nix`). Builtins are not reimplemented; they are
called through the real `builtins` set ("FFI style"), and can be overridden via
`scope.builtins`.

> **Status:** experimental. The supported subset is useful and tested against
> real Nix, but this is not yet a 100% drop-in Nix evaluator. See
> [Limitations](#limitations).

## Quick start

```nix
let
  nix = import ./nix;
in
{
  arithmetic = nix.eval "1 + 2 * 3";              # 7
  strings    = nix.eval "\"a\" + \"b\"";          # "ab"
  functions  = nix.eval "let f = x: x * x; in f 5"; # 25
}
```

## API

`import ./nix` returns an attribute set:

| Attribute | Description |
| --- | --- |
| `eval` | Parse and evaluate a Nix expression. String or attrset form. |
| `parsec` | The underlying parser combinators. |
| `lexer` | Lexer combinators built on `parsec`. |
| `parser` | The Nix expression parser (`parser.parse`). |
| `ast` | AST constructors used by the parser. |

### `eval` — string form

```nix
(import ./nix).eval "1 + 2"
# => 3
```

Evaluation is pure Nix. Relative paths (`./`, `../`, bare `foo/bar`) have no
meaning in this form, so they throw; use the attrset form with `cwd` instead.

Absolute paths and `~/...` work as usual (`~` uses `$HOME`).

### `eval` — attrset form

```nix
(import ./nix).eval {
  text = "(import ./fixtures/simple.nix).b + 1";
  # cwd is inferred from the file that contains `text`
}
# => 3
```

Supported attributes:

| Attribute | Default | Description |
| --- | --- | --- |
| `text` | required | The Nix expression source. |
| `cwd` | directory of the file containing `text` (via `builtins.unsafeGetAttrPos`) | Base directory for relative paths and `import`. |
| `scope` | `{}` | Extra top-level variables available to the expression. |

All other arguments are ignored.

```nix
(import ./nix).eval {
  text = "import ./foo.nix";
  cwd = /some/directory;
}

(import ./nix).eval {
  text = "x + 1";
  scope.x = 5;
}
# => 6
```

### Overriding builtins

If `scope.builtins` is present, it replaces the builtins set used by the
evaluator:

```nix
(import ./nix).eval {
  text = "foo";
  scope.builtins = builtins // { foo = 42; };
}
# => 42
```

### Evaluating a function from `scope`

`scope` values can be functions, because application delegates to the real Nix
evaluator:

```nix
(import ./nix).eval {
  text = "foo 3";
  scope.foo = _: "foo";
}
# => "foo"
```

## Supported language

### Literals and strings

- Integers and floats: `42`, `01`, `1.5`, `.5`, `1.`, `1.5e2`, `1.e2`
- Booleans and `null`
- Double-quoted strings with interpolation: `"hello ${name}"`
- Indented strings: `''...''`, including indentation stripping and
  `''$`, `'''`, `''\n`, `''\t`, `''\r`, `''\<char>` escapes
- Lists: `[ 1 2 3 ]`
- Paths: `/abs`, `./rel`, `../rel`, `~/home`, `foo/bar`
  - Path interpolation is supported: `./${name}`, `foo/${name}`.
  - Path concatenation: `./foo + "bar"` yields a path.
  - As in Nix, `8/2` is a relative path; write `8 / 2` for division.
- Search paths: `<nixpkgs>`, `<nixpkgs/lib>`, resolved through `__nixPath`
- URI literals (deprecated in Nix, still accepted): `http://example.com`

### Operators

| Precedence (tight → loose) | Operators |
| --- | --- |
| postfix | `.` attribute selection, `or` default |
| application | `f x` |
| unary | unary `-` |
| attribute test | `?` |
| multiplicative | `*`, `/` |
| additive | `+`, `-` |
| list concat | `++` |
| logical not | `!` |
| update | `//` |
| relational | `<`, `<=`, `>`, `>=` |
| equality | `==`, `!=` |
| boolean | `&&`, &#124;&#124;, `->` |

`&&`, `||`, and `->` short-circuit. Comparisons force their operands. `+`
concatenates strings when the left operand is a string, concatenates paths when
the left operand is a path, otherwise adds numbers. Relational and equality
operators do not chain: `1 < 2 < 3` is a syntax error.

### Bindings and scoping

- `let ... in ...` (recursive, lazily)
- Legacy `let { ... }` (the `body` attribute is the result)
- Attribute sets and `rec` attribute sets
- `inherit x;`, `inherit (expr) a b;`
  - Plain `inherit x;` resolves in the enclosing scope, even inside `rec`.
  - `inherit (expr)` evaluates `expr` in the current scope, so it can refer to
    sibling `rec` bindings.
  - Inherited names may be quoted or statically interpolated
    (`inherit "a b";`); names that need evaluation are rejected with
    `dynamic attributes not allowed in inherit`.
- Attribute paths with merging: `{ a.b = 1; a.c = 2; }`
  - Duplicate bindings merge when both sides are literal attribute sets (or
    path-created sets), recursively; otherwise they are an error.
  - Adding to a `rec` set (`a.d = b;`) evaluates the new binding in that rec
    scope, and `rec` sets merged with other sets keep their recursive scope.
  - Dynamically named attributes are part of the resulting set but are not
    visible as variables in the `rec` scope (`rec { x = "y"; ${x} = 2; z = y; }`
    errors on `y`).
  - `inherit` bindings never merge with another definition of the same name.
- Dynamic attribute names: `{ ${expr} = v; }`, `a.${expr}`
  - A dynamic name that evaluates to `null` skips that binding
    (`{ ${null} = 1; x = 2; }` is `{ x = 2; }`), while other non-string names
    are an error.
  - In `let`, only literal-string dynamic names are allowed (`${"a"}`);
    names that require evaluation are rejected with `dynamic attributes not
    allowed in let`.
- `true`, `false`, and `null` are ordinary identifiers with a literal
  fallback: lexical bindings ((let), (rec), lambda arguments, `scope`) can
  shadow them, but `with` frames cannot.
- Quoted attribute names: `{ "if" = 1; }."if"`
- `with expr; body`
- `if cond then a else b`
- `assert cond; body`
- `or` defaults: `attrs.missing or fallback`
- `?`: `attrs ? a.b`
- `import`: routed through the real builtin, honouring `cwd`

### Functions

- Identifier lambdas: `x: x + 1`
- Currying: `x: y: x + y`
- Patterns with defaults and ellipsis:
  `{ a, b ? 10, ... }: a + b`
- `@` bindings, both forms:
  - `args@{ a, ... }: args.a`
  - `{ a, ... }@args: args.a`
- Actual application and higher-order builtins such as `builtins.map`,
  `builtins.filter`, and `builtins.foldl'` work because functions are handed to
  the real Nix evaluator.

### Comments

- Line comments: `# ...`
- Block comments: `/* ... */` (they do not nest)

## Semantics notes

- **Laziness.** Variables, `let` bindings, list elements, and attribute values
  are represented as thunks and only forced when needed.
- **Memoization.** A thunk caches its value: forcing it twice evaluates it
  once. Side effects such as `builtins.trace` therefore happen once, and two
  references to the same binding denote the same value.
- **Boundary forcing.** `eval` unwraps internal thunks in the result so callers
  receive plain Nix data. Unwrapping of nested collection elements happens on
  demand (`builtins.map`/`mapAttrs` are lazy). Functions are returned as
  functions, and the value they return is plain data as well.
- **Builtins.** Builtins are the real ones (or `scope.builtins`). Arguments
  cross the FFI boundary in the plain Nix representation, because real builtins
  cannot understand the internal thunk representation. The conversion stays
  lazy: a member of an attribute set is only forced when it is read, so
  overriding a builtin keeps Nix's laziness.
- **Undefined variables.** A name is looked up in this order: lexical
  environment (`let`, `rec`, lambda arguments), the `builtins` name itself,
  `scope`, `true`/`false`/`null`, `__nixPath`/`__storeDir`/`__findFile`, the
  curated global builtins (`map`, `toString`, `import`, `throw`, ...), then
  active `with` frames (innermost first). Other builtins are only reachable
  through `builtins.*`. A name not found throws `"undefined variable 'name'"`.
  Names are resolved statically, before evaluation, so an unknown name is an
  error even in a branch that is never taken (`if false then nope else 1`
  fails). This matches Nix, where an unknown name is a compile-time error
  rather than a value that is forced lazily. Only references under `with` are
  deferred to run time, because `with` may introduce the name.
  `__curPos` is not supported.
- **`with` scoping.** `with` frames are kept as a separate chain. Lexical
  bindings always win over every `with`, and an inner `with` wins over an outer
  one, matching Nix. `with` no longer merges attributes into the lexical
  environment. The `with` expression itself is only evaluated when a name is
  looked up in it.
- **Function arguments.** Pattern defaults may refer to other arguments, to the
  `@` binding, and are evaluated lazily in the function's scope. Missing
  required arguments and unexpected arguments are checked at call time.
- **Interpolation coercion.** `"${v}"` accepts strings, paths (copied to the
  store), and sets with `outPath`/`__toString`; numbers, booleans, and `null`
  are errors. Path interpolation (`./${v}`) is stricter: paths are used
  directly and only strings, paths, and `outPath`/`__toString` sets are
  accepted.
- **`or` defaults.** `a.b or c` checks the attribute chain. If a selected value
  does not exist (including when an intermediate value is not an attribute
  set), `c` is evaluated. Errors raised while forcing an existing value are not
  swallowed. The `or` keyword is only valid after an attribute selection.
- **Equality.** `==` follows Nix's rules. Two functions are never equal when
  compared directly (`f == f` is `false`), but inside a list or attribute set
  two elements that come from the same binding are equal, even when they are
  functions (`[ f ] == [ f ]` is `true`).

## Paths and `import`

- String form (`eval "..."`) has no cwd. Relative paths throw:
  `"relative path './foo' requires a cwd (use the attribute-set form of eval)"`.
- Attrset form uses `cwd`, defaulting to the directory of the file containing
  the `text` argument.
- Paths are normalised the way Nix does it: `.` segments are dropped and `..`
  segments remove the previous one, so `./.` is the current directory and
  `./a/../b` is `b`. Going above the root is clamped to the root.
- `import` uses the real builtin. Importing a regular file does not require a
  derivation.

## Limitations

- Performance is acceptable for small expressions but not tuned for large ones.
- `builtins.functionArgs` returns `{}` for pattern lambdas created by the
  evaluator. They are real Nix functions, so `builtins.isFunction` and
  `builtins.typeOf` report them correctly, but Nix functions cannot carry the
  argument metadata that `functionArgs` needs.
- All evaluator errors are raised with `throw`. Consequently,
  `builtins.tryEval` catches evaluator errors that real Nix would not catch
  (undefined variable, missing attribute, type/coercion errors, division by
  zero). User-level `throw` and `assert` behave like Nix. This is a limitation
  of using Nix itself as the implementation language.
- `__curPos` is not supported (the parser does not retain source positions);
  `__nixPath` and `__storeDir` are provided. `__curPos` references are reported
  as undefined variables.
- Parse errors include a line/column and the most relevant expectation, but the
  wording is not identical to Nix's parser.
- Not every builtin interaction and not every Nix edge case is covered. Full
  compatibility is an ongoing goal.

## Testing

The test suite compares mostly against expected values, with some cases
mirroring real Nix evaluations:

```sh
nix-instantiate --eval --strict -E '(import ./nix/tests.nix).summary'
```

Expected output:

```nix
{ failed = [ ]; passed = 300; total = 300; }
```

Individual results, including `actual`/`expected` for failures, are available
from `(import ./nix/tests.nix).run`.

## Project layout

| File | Purpose |
| --- | --- |
| `default.nix` | Public entry point; exports `eval`, `parsec`, `lexer`, `parser`, `ast`. |
| `parser.nix` | Nix grammar: expressions, operators, bindings, strings, paths. |
| `ast.nix` | AST constructors. |
| `eval.nix` | Lazy evaluator, thunks, forcing, operator semantics, path resolution. |
| `env.nix` | Environment operations. |
| `util.nix` | Thunk helpers. |
| `builtins.nix` | Builtins FFI bridge and `scope.builtins` override. |
| `tests.nix` | Test suite and summary. |
| `fixtures/` | Small files used by `import` tests. |
| `SPEC.md` | Behavioural specification. |
| `PRD.md` | Goals and requirements. |
| `TASKS.md` | Implementation checklist and progress. |

The combinator foundation lives one directory up in `../parsec.nix` and
`../lexer.nix`.

## License

See [`../LICENSE`](../LICENSE).
