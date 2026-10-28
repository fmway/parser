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

v2 comment-driven transforms are different: on a 300-line file with 100 blocks,
the new implementation took about 0.745s, while the previous IFD/regex parser
took about 0.271s. v2 pays for evaluating expressions with the self-hosted Nix
evaluator. The trade-off is no IFD and structured diagnostics, not raw speed.

On the YAML README (16 markers, real code examples) the three approaches measure
(hyperfine, 5 runs, cold eval cache):

- self-hosted (`useNixParser = true`): 2.289 s ± 0.039 s
- IFD (`useNixParser = false`): 2.264 s ± 0.066 s
- previous IFD/regex parser (`github:fmway/lib`): 1.313 s ± 0.024 s

The self-hosted and IFD paths now agree on output; IFD avoids the self-hosted
evaluator's overhead on trivial expressions but both are still dominated by
evaluating the embedded code examples. The previous parser stays faster because
it batches all markers into a single generated file (one import), whereas this
implementation evaluates one marker at a time; batching here overflows the
stack on inputs of this size.

## Notes

- Delimiters are literal strings, not regular expressions.
- Embedded expressions are full Nix expressions and are not sandboxed.
- The framework does not create store files, but an embedded expression may still
  use `import` or IFD.
EOF
