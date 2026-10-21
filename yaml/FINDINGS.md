# Parser performance: what the profile says

Measured on `nix eval` of a 10 000-entry block mapping
(`k1: value` ... `k10000: value`).

## Baseline

| Workload | CPU | Memory |
| --- | --- | --- |
| map 10 000 entries | 1.13 s | 162 MB |
| map 40 000 entries | 5.2 s | 650 MB |
| seq 10 000 entries | 0.6 s | 92 MB |
| seq 40 000 entries | 2.4 s | 368 MB |

Both are linear in the number of entries. A hand-written minimal parser
for the same shape takes 0.19 s, so roughly 5× is on the table.

## The profile is flat

`perf record -g` over the 10 000-entry mapping, about 4 800 samples:

| Self time | Symbol | Meaning |
| --- | --- | --- |
| 12.90 % | `ExprVar::eval` | looking a variable up |
| 9.05 % | `EvalState::callFunction` | calling a function |
| 7.59 % | `ExprCall::eval` | calling a Nix function |
| 4.83 % | `ExprSelect::eval` | `a.b` |
| 4.83 % | `EvalState::evalBool` | `&&`, `||`, `==` |
| 3.78 % | `Bindings::get` | environment lookup |
| 3.58 % | `ExprLet::eval` | a `let` |
| 2.72 % | `ExprVar::maybeThunk` | reading a variable |
| 2.56 % | `ExprOpEq::eval` | `==` |
| 2.39 % | `EvalState::eqValues` | comparing two values |
| 2.35 % | `__adjust_heap` | a sorted container (genericClosure) |
| 2.35 % | `GC_malloc_kind` | the garbage collector |
| 2.16 % | `ExprIf::eval` | an `if` |
| 2.07 % | `Value::type` | the type of a value |
| 1.78 % | `EvalState::allocValue` | allocating |
| 1.52 % | `forceAttrs` | forcing an attribute set |

Nothing dominates. The cost is spread over the ordinary work of
evaluating Nix: looking up a variable, calling a function, testing a
condition.

## What that rules out

* `prim_genericClosure` is 0.47 % of the self time. It is not the
  problem, and replacing it with an explicit worklist does not help:
  the explicit loop needs one stack frame per entry and overflows.
* `prim_substring` is 0.74 %. Scanning the input character by character
  is not the problem.
* `prim_foldlStrict` is 0.16 %. The list operations are not the problem.
* `b.groupBy` (the duplicate-key check) measures 0.07 s for 10 000
  entries on its own.

Every part of the parser measures cheap on its own. The whole is five
times the sum of its parts, because the cost is per *Nix evaluation
step*, not per *operation*.

## Where the steps go

`perf script` counts the frames in the samples:

| Frames | Symbol |
| --- | --- |
| 124 175 | `ExprCall::eval` |
| 80 629 | `ExprLet::eval` |
| 35 644 | `EvalState::evalBool` |
| 25 075 | `ExprOpNot::eval` |
| 23 476 | `prim_isList` |
| 6 114 | `prim_genericClosure` |

So the parser spends its time calling Nix functions, in `let`
bindings, in `if` conditions, and in `!` and `&&`/`||`. The single
biggest lever is therefore **fewer Nix function calls per entry**.

## What that means for a redesign

The parser does about 13 separate helper calls per mapping entry. Each
one is a Nix function call, and each costs an environment lookup, an
argument match, and a thunk. The helpers are:

1. `skipToContent` (the mapping loop)
2. `effectiveIndent` → `columnAt` → `lineStartOf`
3. `skipSpaces` (before the key)
4. `properties` → `skipSpaces` (the key's properties)
5. `plainNode` → `scanPlain` (the key)
6. `skipSpaces` (before the colon)
7. `skipSpaces` (after the colon)
8. `inlineValue` → `skipToContent`
9. `findKeyColon`
10. `plainNode` → `scanPlain` (the value)
11. `collect` → `skipRestOfLine` → `nextContentLineOrComment`
12. `splitProps` → `lineStartOf`
13. `contentState` → `lineStartOf`

A redesign that works the line of a node out once, and that gives
`scanPlain` the colon position so that `findKeyColon` does not have to
look for it again, could plausibly halve the work.

## The cost of the optional features

The parser has three options that are off by default: anchors, tags and
merge keys. What they cost, on a mapping of 40 000 entries with a
distinct key each:

| Options | CPU | Memory |
| --- | --- | --- |
| none | 4.93 – 5.03 s | 636 MB |
| `enableAnchors` | 4.97 – 5.10 s | 636 MB |
| `tags` | 5.06 – 5.13 s | 636 MB |
| `enableAnchors`, `enableMergeKeys` | 5.23 – 5.28 s | 644 MB |
| all three | 5.20 – 5.38 s | 644 MB |

Anchors and tags cost nothing to speak of: the work they ask for is
only done when a document uses them. The merge key costs about 4 % of
the time and 1 % of the memory even when the document has no merge key
in it, because every mapping is then looked over for one.

## Tracking the line of the cursor in the state

The state of the parser holds the offset of the cursor. An error says
where it went wrong, and an error message says it in lines and
columns, so the line of the cursor is worth knowing.

Two fields were added to the state to hold it (`line` and `lineStart`),
and the measurement is:

| State | CPU (10 000 entries) |
| --- | --- |
| without the fields | 1.226 s (median) |
| with the fields | 1.225 s (median) |

The fields themselves are free: the state is copied on every character
that is read, but a copy of an attribute set with nine attributes
costs about as much as a copy of one with eleven.

Keeping the fields *right* is not free, though. The line only changes
when the text that is read holds a line break, so the fields have to be
worked out at every place where the cursor moves: about thirty of them
are spread over the modules. A missed one shows up as a wrong line
number in an error message, and not as a wrong parse, which makes it
the kind of mistake that is easy to miss.

The line does not have to be tracked at all. The number of the line of
an offset is the number of line breaks in front of it, and the text of
the line is what is left after the last one:

    builtins.split "[\n]" (builtins.substring 0 offset str)

Both are work that the builtins do in one go, so they cost a fraction
of a millisecond even for a document of a few hundred kilobytes, and
they are only done when an error is reported. The error message is
built from that, so it does not have to walk the document either.

The state keeps the line of the *cursor*; the error is often about a
place that the cursor has already passed, as a duplicate key is: the
key that is named twice is the second one, and the cursor is at the end
of the mapping by then. The line of such a place cannot be read off the
state, whatever the state holds, so it has to be worked out from the
offset either way.

The result: the line and the column of an error are worked out when
the error is made, and the state is left as it was.

## What the tags cost

The tags are off by default: the option is null, and then a `!t` is
ordinary text. Turning them on has two costs, and they are of two
kinds.

The cost of *looking* for the tags is paid by every document, because
the parser has to look for a `!` in front of every node. The cost of
*having* the tags is only paid by the nodes that carry one.

Measured on a mapping of 10 000 entries (`k0: value` ... `k9999:
value`), with the runs interleaved so that the machine is in the same
state for both:

| Document | Tags off | Tags on | |
| --- | --- | --- | --- |
| no tags in it | 1.207 s | 1.222 s | +1 % |
| a tag on every value | 1.567 s | 1.997 s | +27 % |

The memory follows the time: the values of the parse take 77 MB with
the tags off and 99 MB with them on, for the document with a tag on
every value.

Of the second row, a fifth is the check that the content of a node
fits the tag it carries, which is what makes `!!int ctx` an error
instead of a string:

| | CPU |
| --- | --- |
| the tags on, with the check | 1.980 s |
| the tags on, without the check | 1.918 s |

The check is a few lookups in a table, and it is done for every node
that carries a tag. It cannot be cheaper than that without giving up
the place where the error is reported.

## What was tried, and what it bought

Every change was measured by running the old and the new tree alternately
on the same input and comparing the medians, because a single run on a
busy machine says nothing.

| Change | Result |
| --- | --- |
| `skipSpacesTo`: the state itself, without the list around it | about 1 % |
| `skipToContent` uses it, and the check for a space is written out | included above |
| `scanPlain` split into one for block context and one for flow | about 1 % |
| the line of a node worked out once, for `splitProps`, `contentState` and the sequence check | about 1 % |
| the error holds the line and the column, worked out when the error is made | nothing |
| the message built from the line and the column, instead of walking the document | nothing on a document that parses; the message is quicker |
| `failed` written as `! b.isList` at the hot sites | nothing |
| `failed` written as `(res.context or null) != null` | nothing |
| `findKeyColon` and `countKeyColons` merged into one scan | nothing, and it costs memory |
| a regular expression instead of a character scan | slower |
| a line vector, built once with `builtins.split` | 1.4× on the scan, nothing overall |
| the state forced at every step, to break a chain of thunks | nothing |
| an explicit worklist instead of `builtins.genericClosure` | overflows the stack |
| inlining the chain of helpers into one function per entry | not tried; it is the redesign above |

The changes that were kept are worth about 2 % together. The rest were
reverted, because a change that does not pay for the complexity it
adds is not worth having.

## Measurements that were wrong along the way

Recorded so that they are not repeated:

* A benchmark that read its size from `builtins.getEnv` got a *string*,
  so `builtins.genList` failed and the parse never ran. Every "0.03 s"
  from that harness was a crash, not a fast parse. The harness has to
  use a literal, or convert the value.
* Stubbing a function to see what it cost changes the control flow, so
  it measures the work that disappeared rather than the work that was
  done. A stub of `plainNode` appeared to take the parser from 1.1 s to
  0.07 s; it did not, it took out a whole branch of the parser with
  it.
* An explicit recursive worklist overflows the stack, because Nix does
  not optimise tail calls.
* The machine has other work on it. A load average of 8 on 8 cores
  turned a 5 % difference into noise, and the first results of every
  comparison were meaningless until the machine was quiet.
* `jj` and `git` in the same tree interfere: a `git checkout` in the
  middle of a comparison threw away the change that was being measured,
  and the commit that was made afterwards described a change that was
  not in it. Always look at what the commit actually contains.
