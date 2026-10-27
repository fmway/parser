# templates

Pure-Nix templating built on `nix-parsec`. It avoids IFD in the framework itself:
templates are parsed into an AST and evaluated with `nix.evalAst`.

## v1: interpolation

```nix
let
  template = (import ./template);
in
template.v1.eval {
  prefix = "{{";
  postfix = "}}";
  text = "hello {{ name }}!";
  scope.name = "world";
}
```

`safeParse` returns `{ type = "success" | "error"; value = ...; }`.
`parse` throws a human-readable error with source context.

## v2: comment-driven transforms

```nix
let
  template = (import ./template);
in
template.v2.eval {
  text = ''
    background = "#000" # {< replace_color "#fff" >}
  '';
  commentStyle = { open = "# "; close = ""; };
  interpolation = null;
}
```

`commentStyle` is optional. When omitted, it is inferred from the first marker,
similar to Yolk. Explicit form:

```nix
commentStyle = { open = "# "; close = ""; };
```

Supported marker forms:

- `{< expr >}`: transform text before the marker on the same line.
- `{# expr #}`: transform the following line.
- `{% expr %} ... {% end %}`: transform the enclosed block.
- `{# ignore #}` and `{% ignore %} ... {% end %}`: leave content untouched.

The expression receives `context` (the selected target text) and helper functions such as
`replace_quoted`, `replace_color`, `replace_value`, `replace_between`, and `replace_many`.

## v2 and Yolk

v2 comment-driven transforms are inspired by [Yolk](https://github.com/elkowar/yolk).

## Errors

Parse errors are rendered like the YAML parser: phase, line, column, source excerpt, and
a caret under the failing character.

## Benchmark

Measured with `nix eval` on a 1000-line template containing 1000 interpolations:

- new v1: about 0.54s
- previous `fmway.parse`: about 8.83s

The previous implementation is slower mainly because it rescans the whole document
with regexes and materializes/imports a generated Nix file (IFD). The new
implementation parses into an AST and evaluates it directly.

For very small templates the difference is negligible.

v2 comment-driven transforms are different: on a 300-line file with 100 blocks,
the new implementation took about 8.93s, while the previous IFD/regex parser
took about 0.072s. v2 pays for evaluating expressions with the self-hosted Nix
evaluator. The trade-off is no IFD and structured diagnostics, not raw speed.

## Notes

- Delimiters are literal strings, not regular expressions.
- Embedded expressions are full Nix expressions and are not sandboxed.
- The framework does not create store files, but an embedded expression may still
  use `import` or IFD.
EOF