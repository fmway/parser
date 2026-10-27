# fmway/parser

A collection of parsers written in pure Nix: YAML 1.2, Nix, and templates.
Built on top of [nix-parsec](https://github.com/kanwren/nix-parsec).

> [!WARNING]
> Most of the code was LLM-generated. Stability is not guaranteed.

## Parsers

- `lib.yaml` — YAML 1.2 parser (`yaml/`)
- `lib.nix` — Nix parser and evaluator (`nix/`)
- `lib.template` — template engine (`template/`)

## Usage

With flakes:

```nix
{
  inputs.parser.url = "github:fmway/parser";
  outputs = { self, parser, ... }: {
    # parser.lib.yaml, parser.lib.nix, parser.lib.template
  };
}
```

Without flakes:

```nix
let
  parser = import ./.;
  yaml = parser.lib.yaml;
in
yaml.parse { } "key: value"
```

## Tests

```console
nix eval --impure --json --expr 'import ./yaml/tests.nix { }' --apply 't: t.summary'
nix-instantiate --eval --strict -E '(import ./nix/tests.nix).summary'
```

## Examples

Runnable examples live in `examples/yaml*/` (see their `parse.sh`).

## Dependency

`nix-parsec` is fetched at a fixed revision through `deps.nix`
