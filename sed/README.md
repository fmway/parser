# sed

A parser and a runtime for the scripts of GNU sed, written in pure Nix.

<!--{% code.examples.sed-quickstart %}-->
```nix
let
  sed = import ./sed;
in sed "s/foo/bar/" "a foo line"
# => "a bar line"
```
<!--{% end %}-->

## Usage

The parser is exposed through `sed/default.nix`:

```nix
{
  sed = import ./sed;
}
```

### The command

The module is called the way the command of sed is used: the script
first, and the text after it.

<!--{% code.examples.sed-simple %}-->
```nix
sed "s/foo/bar/" "a foo line"
# => "a bar line"
```
<!--{% end %}-->

The options can be given as well, in front of the script:

<!--{% code.examples.sed-param-quiet %}-->
```nix
sed { quiet = true; } "s/foo/bar/" "a foo line"
# => ""
```
<!--{% end %}-->

### `run`

Runs a script over a text and gives back the text that the script
produced.

<!--{% code.examples.sed-run-simple %}-->
```nix
sed.run { } "s/foo/bar/" "a foo line"
# => "a bar line"
```
<!--{% end %}-->

The options are:

| Option | Default | Meaning |
| --- | --- | --- |
| `extended_regex` | `false` | The regular expressions are the extended ones of POSIX, and not the basic ones with the extensions of GNU (the `-r` option of sed) |
| `quiet` | `false` | Do not print the pattern space at the end of every cycle (the `-n` option of sed) |
| `scripts` | `[]` | More scripts, which are put in front of the script (the `-e` option of sed) |

The text is a string. A line break at the end of the text does not make
another line, the way it does not for sed itself.

### `parse` and `safeParse`

`parse` gives back the script as a tree of commands, and `safeParse` gives
back whether it worked.

<!--{% code.examples.sed-safe-parse-quickstart %}-->
```nix
sed.safeParse { } "s/foo/bar/"
# => { type = "success"; value = { type = "script"; commands = [ ... ]; }; }

sed.safeParse { } "s/foo/bar"
# => { type = "error"; value = { col = 0; line = 1; msg = "unterminated `s' command"; offset = 0; }; }
```
<!--{% end %}-->

`parse` throws the error instead of giving it back, with a message that
says what went wrong and where:

```console
$ nix eval --impure --expr '(import ./sed).parse { } "s/foo/bar"'
error:
       … while parsing a sed script
       …
       error: sed.script
         1| s/foo/bar
          | ^ unterminated `s' command
```

### `errorMessage`

Builds the message of an error, for the callers that want to show it
themselves:

```nix
sed.errorMessage "s/foo/bar" res.value
```

### `apply`

Runs a script that was parsed before, over a text. This is the way to
run the same script over many texts, since the script is only parsed
once.

<!--{% code.examples.sed-apply-quickstart %}-->
```nix
let
  script = sed.parse { } "s/foo/bar/";
in sed.apply { } script "a foo line"
# => "a bar line"
```
<!--{% end %}-->
### `regex`

The regular expressions of sed, for the callers that want them:

```nix
sed.regex.compile { pattern = "foo"; }
sed.regex.match program text
```

## The script

A script is a list of commands. Every command has an address, the letter
of the command, and what the command needs:

```nix
{ addr; cmd = "s"; pattern; replacement; flags; }
{ addr; cmd = "y"; from; to; }
{ addr; cmd = "a"; text; }
{ addr; cmd = "b"; label; }
{ addr; cmd = ":"; label; }
{ addr; cmd = "block"; commands; }
{ addr; cmd = "d"; }
```

The address is one of these, or null when the command has none:

```nix
{ type = "line";  n; }        -- the line n
{ type = "last"; }            -- the last line
{ type = "regex"; program; }  -- the lines the pattern matches
{ type = "step";  first; step; }   -- the line of the address, and every step-th line after it
{ type = "range"; from; to; }       -- `addr1,addr2`
{ type = "range"; from; relative; } -- `addr1,+N`
```

### The commands

| Command | Meaning |
| --- | --- |
| `s/pattern/replacement/flags` | Replace the pattern by the replacement |
| `y/from/to/` | Replace the characters of `from` by the characters of `to` |
| `d` | Delete the pattern space and start the next cycle |
| `p` | Print the pattern space |
| `P` | Print the pattern space up to the first line break |
| `=` | Print the number of the line |
| `n` | Print the pattern space and read the next line into it |
| `N` | Add the next line to the pattern space |
| `q` | Print the pattern space and stop |
| `Q` | Stop without printing the pattern space |
| `a text` | Print the text after the pattern space |
| `i text` | Print the text before the pattern space |
| `c text` | Replace the pattern space by the text |
| `h` | Copy the pattern space into the hold space |
| `H` | Add the pattern space to the hold space |
| `g` | Copy the hold space into the pattern space |
| `G` | Add the hold space to the pattern space |
| `x` | Swap the pattern space and the hold space |
| `b label` | Jump to the label |
| `t label` | Jump to the label when a substitution happened |
| `T label` | Jump to the label when no substitution happened |
| `: label` | Define a label |
| `l` | Print the pattern space, with the characters that are not shown as they are |
| `L` | The same, over more than one line |
| `z` | Empty the pattern space |
| `{ ... }` | A group of commands |
| `# ...` | A comment |

The flags of the `s` command are `g` (replace every match), `p` (print
the line when a substitution happened), `I` (the case does not matter) and
`M` (the `^` and the `$` match at the line breaks inside the pattern
space). A number is the number of the match that is replaced, so
`s/a/b/2` replaces the second match.

## The regular expressions

The engine is written from scratch. It knows the two dialects that sed
uses:

- the basic regular expressions of POSIX, with the extensions that GNU
  sed adds to them: `\+`, `\?`, `\|`, `\{n,m\}`, `\w`, `\W`, `\s`, `\S`,
  `\b`, `\B`, `\<`, `\>`, `` \` ``, `\'` and the back references `\1` to
  `\9`;
- the extended regular expressions of POSIX, which the `extended_regex`
  option turns on.

The engine is not the one of Nix: `builtins.match` needs the whole text
to match, it knows none of the extensions of GNU, and it has no flags.

A match is the leftmost one that is also the longest one, the way POSIX
says, and the groups are the longest ones that fit the match, the way
POSIX says as well.

## Notes on GNU sed

A few things that GNU sed does are surprising, and they are followed here
as well:

- The `n` command prints the pattern space before it reads the next line
  into it. The `N` command does not print anything.
- The `z` command empties the pattern space, whatever the pattern space
  holds.
- A label ends at the `;` or at the end of the line, so
  `b skip; s/a/A/; :skip` jumps over the substitution.
- A number behind the last delimiter of the `s` command is the number of
  the match that is replaced, so `s/a/b/2` replaces the second match.
- An empty match at the end of the line is not replaced, so
  `s/x*/-/g` does not put a `-` at the end of the line.
- A line that is printed at the end of a cycle keeps the line break of
  the line it came from: the output does not end with a line break when
  the text does not end with one.

## Limits

- The commands that read or write files (`r`, `R`, `w`, `W`), the ones
  that run a shell (`e`) and the one that prints the name of the file
  (`F`) are not there. A script that uses them is refused with a
  message that says so.
- The address `\cRE` is not there either. GNU sed 4.10 does not have it
  either.
- The `[[:^alpha:]]` classes, which are the classes of POSIX with a `^`
  in them, are understood, but GNU sed refuses them.
- The engine is much slower than the one of GNU sed, since it is written
  in Nix. It is meant for the scripts that go over a file that is not
  very big.

## Tests

<!--{% code.examples.sed-tests %}-->
```sh
nix eval --impure --json --expr 'import ./sed/tests.nix { }' \
  --apply 't: t.summary'
# => { failed = 0; passed = 134; total = 134; }
```
<!--{% end %}-->

The expectations of the tests are the ones of GNU sed, which was used to
make them. The tests do not run sed itself, so that they give the same
result everywhere.

## Structure

| File | Contents |
| --- | --- |
| `default.nix` | The public interface |
| `script.nix` | The parser of the scripts |
| `regex.nix` | The engine of the regular expressions |
| `exec.nix` | The runtime of the scripts |
| `tests.nix` | The test suite |

## License

See [`../LICENSE`](../LICENSE).
