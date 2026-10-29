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

By default expressions are evaluated with the self-hosted Nix evaluator
(`useNixParser = true`), which needs no IFD. Set `useNixParser = false` to
evaluate them with the host evaluator through a generated file instead, which
is faster on large templates at the cost of IFD:

```nix
template.v2.eval {
  file = ./README.md;
  scope.code = import ./dev/code.nix;
  useNixParser = false;
}
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

- new v1: about 0.83s (hyperfine)
- previous [fmway.parse.v1](https://github.com/fmway/lib/blob/35f1a61d31c3b63f6602a3ca31c3ac0c262fa65a/lib/fmway/parser/parse.nix): about 1.15s (hyperfine)

The previous implementation is slower mainly because it rescans the whole document
with regexes and materializes/imports a generated Nix file (IFD). The new
implementation parses into an AST and evaluates it directly.

For very small templates the difference is negligible.

v2 comment-driven transforms work in the same shape: the markers are found in
one pass over the text, the lines of the text are indexed once, and all the
expressions go into one generated file that is imported once.

On the YAML README (492 lines, 32 markers, real code examples) the three
approaches measure the same, because most of the time goes into evaluating
the embedded code examples (about 1.2 s of the 1.35 s):

- self-hosted (`useNixParser = true`): about 1.33 s
- IFD (`useNixParser = false`): about 1.34 s
- previous IFD/regex parser (`github:fmway/lib`): about 1.35 s

With the code examples replaced by cheap ones, so that only the parsing and
the rendering are measured, the new parser is twice as fast:

- self-hosted: about 0.12 s
- IFD: about 0.11 s
- previous IFD/regex parser: about 0.24 s

On a 300-line file with 100 blocks all three measure about 0.24 s.

The new parser also grows better: on a file ten times the size of the YAML
README the previous parser fails with "stack overflow (possible infinite
recursion)", while the new parser takes about 1.9 s.

## Notes

- Delimiters are literal strings, not regular expressions.
- Embedded expressions are full Nix expressions and are not sandboxed.
- The framework does not create store files, but an embedded expression may still
  use `import` or IFD.
EOF
