# PRD: nix-parsec/nix (Nix Self-Parser/Evaluator)

## Problem Statement

Users want to evaluate Nix expressions as strings without using Import-From-Derivation (IFD). IFD is often avoided in hermetic builds and by community preference. Example of IFD: `import (builtins.toFile "eval.nix" "1 + 2")`. A self-hosted evaluator in Nix avoids writing derivation-backed files just to evaluate expressions.

## Goals

1. Provide `eval` API as specified:
   - `(import ./nix).eval "nix expr"` 
   - `(import ./nix).eval { text, cwd?, scope? }`
2. Avoid IFD by design (evaluation happens in pure Nix).
3. Lazy evaluation with thunks (don't eagerly translate vars).
4. Operator semantics exactly as specified.
5. Builtins accessible via FFI (call existing builtins), with `scope.builtins` override.
6. Support `scope` for top-level variables.
7. Throw `"undefined variable '$name'"` for unresolvable vars not in allowed sets.
8. Full Nix support eventually, incremental implementation starting minimal.
9. Validate behavior against real Nix where possible.

## Non-Goals

1. Drop-in 100% compatible replacement on first release
2. Reimplementing builtins from scratch
3. Perfect performance matching nix
4. Supporting every esoteric Nix feature immediately

## User Stories

- As a user, I want to eval small Nix expressions as strings without IFD.
- As a user, I want to inject custom variables via `scope`.
- As a user, I want to override builtins via `scope.builtins`.
- As a user, I want to evaluate relative imports by passing `cwd` in attrset form.
- As a user, I want lazy behavior consistent with Nix.

## Requirements

### Functional
- [x] API shape matches spec
- [x] String concatenation via `__concatStringsSep ""` when left operand is string
- [x] Numeric ops via `__add/__sub/__div/__mul` as specified
- [x] List concat via `__concatLists`
- [x] Attr update via `//` on thunks
- [x] Builtin FFI
- [x] Scope support + builtin override
- [x] Undefined variable detection with exact message format
- [x] Relative path limitation respected in string form
- [x] cwd inference via `unsafeGetAttrPos` in attrset form

### Non-Functional
- [x] Pure Nix (no IFD)
- [x] Lazy/thunk-based where possible
- [x] Extensible architecture for incremental full support
- [x] Clear errors (parse errors include line/column; wording differs from Nix)
- [x] Works with existing parsec/lexer patterns in repo

## Acceptance Criteria

1. `let r = (import ./nix).eval "1 + 2"; in r == 3` works
2. String concat: `(import ./nix).eval "\"a\" + \"b\"" == "ab"` (or equivalent)
3. Scope vars work: `(import ./nix).eval { scope.foo = _: "foo"; text = "foo 3"; }` gives `"foo"` (as specified)
4. Builtin override via `scope.builtins` works
5. Undefined var throws `"undefined variable 'x'"`
6. Lazy evaluation preserved (no unnecessary forcing)
7. Comparison style works: `left == right` where left is normal Nix, right is via eval

## Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Full Nix semantics impossible quickly | High | Incremental subset, test against real Nix continuously |
| Thunk model bugs causing eager eval or infinite recursion | High | Careful thunk/force design, test laziness cases |
| Builtin FFI breaks on some builtins | High | Wrap with forcing, test builtins incrementally |
| Relative import resolution confusion | Med | Enforce rules from spec, document clearly |
| Performance too slow | Med | Acceptable for small expressions initially |

## Success Metrics

- Can eval basic arithmetic/strings/lets without IFD
- Operator semantics match exactly
- Scope/builtins work as specified
- Passes comparison tests vs real Nix for supported subset
- Clean extension path for full support

## Release Plan

Start with minimal subset (literals, vars, basic ops, lets), then expand: functions, attrs, lists, conditionals, with/rec, imports, more builtins. Full support is the end goal but delivered incrementally.