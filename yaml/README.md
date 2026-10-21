# YAML 1.2 parser

A YAML 1.2 parser written in pure Nix, built on top of
[nix-parsec](../README.md).

```nix
let
  yaml = import ./yaml;
in
yaml.parse { } "key: value"
# => { key = "value"; }
```

A document that cannot be parsed is an error, and `parse` throws it
with a message that says what went wrong:

```console
$ nix eval --impure --json --expr '(import ./yaml).parse { } "a: 1\na: 2\n"'
error:
       … while parsing a YAML document
       …
       error: yaml.mapping
         1| a: 1
         2| a: 2
           | ^ duplicate key 'a'
```

The parser needs `nix-parsec`, and fetches it from the published source
of that repository at a fixed revision, so it works without a checkout
of it and without flakes.

Working on the parser itself is easier with the combinators of the
checkout at hand. Setting `NIX_PARSEC_LOCAL` to the directory of a
checkout makes the parser use that instead of fetching it:

```console
$ NIX_PARSEC_LOCAL=$PWD nix eval --impure --json --expr \
    '(import ./yaml).safeParse {} "a: 1\n"'
```

## Usage

The parser is exposed through `yaml/default.nix`:

```nix
{
  yaml = import ./yaml;
}
```

### `parse`

Parses a single document and gives it back. A document that cannot be
parsed is thrown as an error.

It takes the options and the document:

```nix
yaml.parse { } "a: 1\nb: two\n"
# => { a = 1; b = "two"; }

yaml.parse { enableAnchors = true; } "a: &x v\nb: *x\n"
# => { a = "v"; b = "v"; }
```

`parseDefault` is the same with the default options.

```nix
yaml.parseDefault "a: 1\nb: two\n"
# => { a = 1; b = "two"; }
```

### `safeParse`

Parses a single document and gives back whether it worked, rather than
throwing when it did not.

```nix
yaml.safeParse { } "a: 1\nb: two\n"
# => { type = "success"; value = { a = 1; b = "two"; }; }

yaml.safeParse { } "a: 1\na: 2\n"
# => { type = "error"; value = { context = "yaml.mapping"; msg = "duplicate key 'a'"; offset = 5; line = 2; col = 0; }; }
```

Options:

| Option | Default | Meaning |
| --- | --- | --- |
| `enableAnchors` | `false` | Allow `&name` and `*name` |
| `tags` | `null` | The handlers of the tags |
| `enableMergeKeys` | `false` | Honour the `<<` merge key |

```nix
yaml.safeParse { enableAnchors = true; } "- &a x\n- *a"
# => { type = "success"; value = [ "x" "x" ]; }
```

### Anchors, aliases and tags

The properties of a node (an anchor `&a` and a tag `!t`) belong to the
node they are written in front of. In a block mapping there is one
exception: the properties that are on the same line as the first key
belong to that key, so an alias can refer to it.

```nix
yaml.safeParse { enableAnchors = true; } "&a a: &b b\n*b : *a"
# => { type = "success"; value = { a = "b"; b = "a"; }; }
```

The properties of a node may be on lines of their own, as long as those
lines are indented deeper than the block they are in. They then belong
to the collection that follows them.

When the anchors are not enabled, an `&a` and a `*a` are ordinary
text, and so is a `!t` when the tags are not enabled:

```nix
yaml.safeParse { } "a: &x test\nb: *x\n"
# => { type = "success"; value = { a = "&x test"; b = "*x"; }; }
```

### Tags

The tags of a document say what its nodes are. The `tags` option holds
a handler for every tag the caller understands: the handler is given
the text of the node and gives back the value of it.

```nix
yaml.safeParse {
  tags = {
    "!shout" = text: "shouted: ${text}";
  };
} "!shout hello\n"
# => { type = "success"; value = "shouted: hello"; }
```

The option is null by default, and then there are no tags at all: a
`!t` is the ordinary text it looks like.

```nix
yaml.safeParse { } "!shout hello\n"
# => { type = "success"; value = "!shout hello"; }
```

An attribute set turns the tags on, even an empty one. The tags of the
core schema (`!!str`, `!!int`, `!!float`, `!!bool` and `!!null`) are
part of YAML itself, and they are understood whenever the tags are on.
A caller who wants another meaning for one of them says so, and the
caller's meaning is used.

```nix
yaml.safeParse { tags = { }; } "!!int 42\n"
# => { type = "success"; value = 42; }

yaml.safeParse { tags = { "!shout" = text: text; }; } "!!int 42\n"
# => { type = "success"; value = 42; }
```

The handlers of the core schema are exported as `yaml.coreTags`, for a
caller who wants to start from them.

```nix
yaml.safeParse { tags = yaml.coreTags; } "!!int 42\n"
# => { type = "success"; value = 42; }
```

A tag of the core schema says what the content of a node has to look
like, and a content that does not fit is an error: the tag is
recognised, and a node with a recognised tag and content that does not
satisfy it is not valid, and cannot be turned into a value (see section
3.3.3 of the specification).

```nix
yaml.safeParse { tags = { }; } "a: !!int ctx\n"
# => { type = "error"; value = { context = "yaml.tag"; msg = "'ctx' is not an integer"; ...; }; }
```

A tag that nobody knows is a different thing: the tag is then
unavailable, and the content of the node is kept as the text it is (see
section 3.3.4 of the specification). A caller that says what a tag
means is responsible for the content of the nodes that carry it.

### A handler that says no

A handler that does not like the content of a node gives `yaml.failWith`
back, and the parser reports it as an error of the document, with the
place where the node is.

```nix
yaml.safeParse {
  tags = {
    "!isfoo" = text: if text == "foo" then true else yaml.failWith "the value is not foo";
  };
} "a: !isfoo bar\n"
# => { type = "error"; value = { context = "yaml.tag"; msg = "the value is not foo"; ...; }; }
```

The handler is called while the document is parsed, and not when the
value is looked at. That matters: Nix is lazy, so a handler that gave
back a failure would never be noticed, and the value might never be
asked for at all. A handler that throws is an error as well, though
the message of such a failure is a general one, since Nix has no way of
catching a throw and keeping its message.

A tag is looked up by its full name and then by its short one, so a tag
that a `%TAG` directive gives a prefix to is found by the name the
prefix makes.

```nix
yaml.safeParse {
  tags = {
    "tag:example.com,2000:app/thing" = text: "shouted: ${text}";
  };
} "%TAG !p! tag:example.com,2000:app/\n--- !p!thing hello\n"
# => { type = "success"; value = "shouted: hello"; }
```

The handlers are for the text of a scalar. A tag on a collection is not
looked at.

### `safeParseStream`

Parses a stream of documents and returns them as a list.

```nix
yaml.safeParseStream { } "---\na: 1\n---\nb: 2\n"
# => { type = "success"; value = [ { a = 1; } { b = 2; } ]; }
```

### Errors

On failure the result of `safeParse` and `safeParseStream` is

```nix
{
  type = "error";
  value = {
    context = "...";   # the part of the grammar that failed
    msg = "...";       # what went wrong
    offset = 42;       # the character offset in the input
    line = 3;          # the number of the line the offset is on
    col = 5;           # the number of characters in front of it
  };
}
```

The offset is the character that the error is about: the key of a
duplicate key, the `*` of an alias, the `#` of a comment, and so on.
The line and the column are worked out from it, and are only there to
save the reader of the error the trouble of working them out again.

`parse` throws the error instead of giving it back. The message says
what went wrong and where it went wrong: the number of the line, the
line before it, the line it is on, the line after it, and a mark under
the character, the way Nix itself points at the place in an expression
that it does not like.

```console
$ nix eval --impure --json --expr '(import ./yaml).parse { } "a: 1\nb: 2\nb: 3\n"'
error:
       … while parsing a YAML document
       …
       error: yaml.mapping
         2| b: 2
         3| b: 3
           | ^ duplicate key 'b'
```

The message is coloured: the context in red, the mark in red and the
message in magenta. The mark lines up with the text even when the line
holds a tab, because a tab is as wide as the space up to the next
multiple of eight, which is what a terminal does with it.

`errorMessage` builds that message from a document and an error, for
callers that want to show it themselves:

```nix
yaml.errorMessage "a: 1\nb: 2\nb: 3\n" res.value
```

## Values

The document is converted to Nix-native values:

| YAML | Nix |
| --- | --- |
| Mapping | Attribute set |
| Sequence | List |
| `null`, `~`, empty | `null` |
| `true` / `false` | Boolean |
| Integer | Integer |
| Float | Float |
| Anything else | String |

Mapping keys are always converted to strings, so the key `null` becomes
the string `"null"`. Note that attribute sets are unordered, so the order
of the keys in a mapping is not preserved, and a mapping with duplicate
keys is an error.

The YAML specification requires the keys of a mapping to be unique: "YAML
insists they MUST be unique", so a duplicate key is reported as an
error.

```nix
yaml.parse { } "a: 1\na: 2"
# => { type = "error";
#      value = { context = "yaml.mapping"; msg = "duplicate key 'a'"; offset = 5; line = 2; col = 0; }; }
```

The keys are compared by their text, because that is the name the
attribute gets in the Nix value: two keys with the same text would
collapse into a single attribute and one of them would be lost. A plain
`a` and a quoted `"a"` are therefore duplicates, while `1` and `0x1` are
not: they have different texts and become different attributes, even
though the specification considers the two scalars equal.

Scalar types follow the YAML 1.2 *core schema*. In particular `yes`,
`no`, `on` and `off` are plain strings, not booleans, and timestamps
are strings.

## Supported syntax

- Block mappings and sequences, including nested and "compact"
  notation (`- key: value`)
- Flow mappings and sequences (`{a: 1}`, `[1, 2]`)
- Plain, single-quoted and double-quoted scalars, including multi-line
  scalars
- Block scalars: literal (`|`) and folded (`>`), with the chomping
  (`-`, `+`) and explicit indentation indicators
- Comments
- Multiple documents, separated by `---` and terminated by `...`
- Directives: `%YAML 1.2` and `%TAG`
- Anchors (`&a`), aliases (`*a`) and tags (`!!str`, `!local`) when
  enabled
- Merge keys (`<<`) when `enableMergeKeys` is set

The following are not implemented:

- Custom tag resolution (`!!set`, `!!omap` and friends are treated as
  ordinary tags)
- Recursive anchors

## Known limitations

A few constructs are parsed, but not quite the way the specification
describes them:

- The `%` escapes in a tag name are not decoded, so `!e!tag%21` is a
  tag of its own instead of the tag `!e!tag!`.

## Merge keys

A key whose text is `<<` is a merge key. Its value is a mapping, or a
sequence of mappings, whose entries are brought into the mapping that
holds the merge key:

```nix
yaml.safeParse { enableAnchors = true; enableMergeKeys = true; } ''
base: &base
  a: 1
  c: 3
child:
  <<: *base
  c: 9
''
# => { base = { a = 1; c = 3; }; child = { a = 1; c = 9; }; }
```

A key that the mapping holds itself wins over one that a merge brought
in, and the first mapping of a sequence wins over the ones after it.
The merge key itself does not appear in the result.

This is the merge key of YAML 1.1, which YAML 1.2 left out of its
[core schema]. The core schema of YAML 1.2 has no merge key, and the
specification does not mention it at all; the behaviour here is the one
that [PyYAML] and [go-yaml] use, and it is offered because so many
documents in the wild use it.

It is off by default, since it is not part of YAML 1.2. Without
`enableMergeKeys` a `<<` is an ordinary key, and the mapping that holds
it keeps it:

```nix
yaml.safeParse { enableAnchors = true; } ''
base: &base
  a: 1
child:
  <<: *base
''
# => { base = { a = 1; }; child = { "<<" = { a = 1; }; }; }
```

[core schema]: https://yaml.org/spec/1.2.2/#103-core-schema
[PyYAML]: https://pyyaml.org/wiki/PyYAMLDocumentation
[go-yaml]: https://github.com/go-yaml/yaml

## Limits

Nix does not optimise tail calls, so a recursive parser loop uses one
stack frame per iteration and eventually overflows the stack. The loops
that collect the entries of a mapping or a sequence are therefore driven
by a worklist (`builtins.genericClosure`) instead of by recursion, so
the number of entries in a collection does not affect the stack depth.
The time and the memory used by a document are linear in its size.

Nesting is different: a collection inside a collection is parsed by a
recursive call, so the depth of the nesting is limited by the stack.
With the default `max-call-depth` of 10000 this allows roughly 575
levels of nested block mappings and of nested flow collections, and 2000
levels of nested block sequences. A document that nests deeper than that
fails with a Nix stack overflow.

A mapping entry costs about thirteen Nix function calls, and that is
where the time goes: a profile of the parser shows the time going into
the evaluation of Nix itself, into looking variables up, into entering
`let` scopes, and into calling functions, and not into any one part of
the parser. `FINDINGS.md` has the measurements, and what has been tried
and what it bought.

## Structure

The parser is split into modules, each of which handles one part of the
grammar:

| Module | Contents |
| --- | --- |
| `state.nix` | The parser monad, the state, and the character-level primitives |
| `spaces.nix` | Whitespace, comments and line breaks |
| `scalars.nix` | The four scalar styles and the type resolution |
| `flow.nix` | Flow collections |
| `blocks.nix` | Block collections |
| `anchors.nix` | Anchors, aliases and tags |
| `nodes.nix` | Ties the block and flow parsers together |
| `docs.nix` | Documents, directives and streams |
| `default.nix` | The public interface |

The parser is a monad over a state that holds the input string, the
current offset and the anchor table:

```nix
type YamlParser a = YamlState -> Either YamlError (a, YamlState)
```

Indentation is not tracked incrementally. It is derived on demand from
the current offset by looking back at the beginning of the current line,
which keeps the state small and avoids the classic bug of forgetting to
update a counter in every consuming primitive.

## Tests

```nix
nix eval --impure --json --expr \
  'import ./yaml/tests.nix { }' --apply 't: t.summary'
# => { total = 155; passed = 155; failed = 0; }
```

The built-in tests cover the basics, the examples from chapter 2 of the
YAML 1.2 specification, and the errors the parser rejects.

The parser can also be run against the
[yaml-test-suite](https://github.com/yaml/yaml-test-suite), which is not
bundled with this repository. Pass the path to a checkout of its `data`
branch:

```nix
nix eval --impure --json --expr \
  'import ./yaml/tests.nix {
     yamlTestSuite = /path/to/yaml-test-suite-data;
   }' --apply 't: t.summary'
```

All 231 cases of the yaml-test-suite that have a reference value pass.
The other 102 cases have none: 80 of them are documents that should be
rejected, and the rest are compared by their events. 76 of the 80 are
rejected as well.
