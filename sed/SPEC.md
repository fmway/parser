# SPEC: the sed module

## Overview

The module parses the scripts of GNU sed and runs them over a text. It
is written in pure Nix and has no dependency at all: it does not use
`nix-parsec` and nothing else from outside itself.

The behaviour follows GNU sed 4.10, and the expectations of the tests
were made with it.

## The interface

```nix
(import ./sed) scriptText text
  # the same as (import ./sed).run { } scriptText text

(import ./sed).safeParse { extended_regex ? false; } scriptText
  # => { type = "success"; value = <script>; }
  #    { type = "error";   value = { msg; offset; line; col; }; }

(import ./sed).parse { extended_regex ? false; } scriptText
  # => <script>, and the error is thrown when there is one

(import ./sed).run { extended_regex ? false; quiet ? false; scripts ? []; }
  scriptText text
  # => the text that the script produced

(import ./sed).apply { quiet ? false; } script text
  # => the text that the script produced, with a script that was parsed
  #    before

(import ./sed).errorMessage scriptText error
  # => the message of an error
```

## The script

A script is a list of commands, and the commands are separated by `;` or
by a line break. A `#` that is the first character of a command starts a
comment that goes to the end of the line.

### The addresses

| Address | Meaning |
| --- | --- |
| `n` | The line `n` |
| `$` | The last line |
| `/re/` | The lines the pattern matches |
| `n~step` | The line `n`, and every `step`-th line after it |
| `addr1,addr2` | From the line `addr1` to the line `addr2`, both of them |
| `addr1,+n` | The line `addr1` and the `n` lines after it |
| `0,/re/` | From the first line to the line the pattern matches |

The second address of a range is looked for from the line after the
first one, except when the range starts at the line 0, which is before
the first line.

A `!` after an address means that the command is run when the address
does *not* match.

### The commands

| Command | Meaning |
| --- | --- |
| `s/re/repl/flags` | Replace the first match of `re` by `repl` |
| `y/from/to/` | Replace the characters of `from` by the characters of `to` |
| `d` | Delete the pattern space and start the next cycle |
| `p` | Print the pattern space |
| `P` | Print the pattern space up to the first line break |
| `=` | Print the number of the line |
| `n` | Print the pattern space, then read the next line into it |
| `N` | Add the next line to the pattern space |
| `q` | Print the pattern space and stop |
| `Q` | Stop without printing the pattern space |
| `a text` | Print the text after the pattern space |
| `i text` | Print the text before the pattern space |
| `c text` | Replace the pattern space by the text and end the cycle |
| `h`, `H` | Copy the pattern space into the hold space, or add it to it |
| `g`, `G` | Copy the hold space into the pattern space, or add it to it |
| `x` | Swap the pattern space and the hold space |
| `b label` | Jump to the label |
| `t label` | Jump to the label when a substitution happened since the last time |
| `T label` | Jump to the label when no substitution happened since the last time |
| `: label` | Define a label |
| `l`, `L` | Print the pattern space, with the characters that are not shown as they are |
| `z` | Empty the pattern space |
| `{ ... }` | A group of commands |

### The text of `a`, `i` and `c`

The text is either the rest of the line, without the blanks in front of
it, or the lines that follow a backslash. In the second form every line
but the last ends with a backslash, and the blanks of the lines are kept.

### The flags of `s`

| Flag | Meaning |
| --- | --- |
| `g` | Replace every match, and not only the first one |
| `p` | Print the pattern space when a substitution happened |
| `I` | The case does not matter |
| `M` | The `^` and the `$` match at the line breaks of the pattern space |
| a number | Replace that match, and not the first one |

## The regular expressions

The engine understands the basic regular expressions of POSIX with the
extensions of GNU sed, and the extended regular expressions of POSIX.

| Syntax | Meaning |
| --- | --- |
| `.` | Any character but a line break |
| `[...]` | A character class; a `^` in front turns it the other way around, a `]` right after the `[` is an ordinary character, and `[[:alpha:]]` and the other named classes are understood |
| `*` | Nothing or more of the thing before it |
| `\+` | One or more of the thing before it (in the extended dialect: `+`) |
| `\?` | Nothing or one of the thing before it (in the extended dialect: `?`) |
| `\{n,m\}` | Between `n` and `m` of the thing before it (in the extended dialect: `{n,m}`) |
| `\(...\)` | A group (in the extended dialect: `(...)`) |
| `\|` | An alternation (in the extended dialect: `|`) |
| `^`, `$` | The start and the end of the text |
| `\<`, `\>` | The start and the end of a word |
| `\b`, `\B` | The border of a word, and not the border of a word |
| `\w`, `\W`, `\s`, `\S` | A word character and its opposite, a blank and its opposite |
| `` \` ``, `\'` | The start and the end of the text |
| `\1` to `\9` | The group that was matched |
| `\n`, `\t`, `\r` | A line break, a tab, a carriage return |
| `\cX` | The character that `X` stands for, less 64 |

A match is the leftmost one that is also the longest one, and the groups
are the longest ones that fit the match. This is the rule of POSIX, and
it is the rule that GNU sed follows.

## The run

The run goes over the lines of the text, one at a time. Every line
becomes the pattern space, the script is run, and the pattern space is
printed at the end of the cycle, unless the `quiet` option is there.

The `n` command prints the pattern space before it reads the next line,
the way GNU sed does. The `N` command does not.

The `t` and the `T` commands remember whether a substitution happened
since the last time they were used, and the flag is set again at the
start of every cycle.

A jump to a label that is not in the block the run is in goes to the end
of the script.

A label ends at the `;` or at the end of the line, and the blanks around
it are not part of it.

The `n` command prints the pattern space before it reads the next line
into it, and the `N` command does not print anything. This is what GNU
sed does.

The `z` command empties the pattern space, whatever it holds.

An empty match at the end of the line is not replaced, and an empty match
that comes right after another match is not counted. This is the way GNU
sed counts the matches, and it is what the number behind the last
delimiter of the `s` command counts.

The pattern space keeps the line break of the line it came from: the
output does not end with a line break when the text does not end with
one. The commands that print something always end their output with a
line break, and a line break is put in front of them when what was
printed before did not end with one. This is the way GNU sed does it.

## Errors

- A script that cannot be parsed is an error, with the place of the
  mistake in it.
- A pattern that is not a regular expression is an error, with the place
  of the mistake in the pattern.
- The commands that read or write files, the ones that run a shell, and
  the one that prints the name of the file are not there, and a script
  that uses them is refused.
