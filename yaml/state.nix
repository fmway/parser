# Core state-threading layer for the YAML parser.
#
# The parser is a monad over a state record:
#
#   type YamlParser a = YamlState -> Either YamlError (a, YamlState)
#
# YamlState is:
#   {
#     str     :: String   -- the full input
#     offset  :: Int      -- current absolute offset
#     len     :: Int      -- number of characters remaining
#     anchors :: AttrSet  -- anchor name -> node
#   }
#
# Indentation is not tracked incrementally. It is derived on demand from
# the current offset by looking back at the beginning of the current line.
# That keeps the state small and avoids the classic bug of forgetting to
# update a counter on every consuming primitive.
#
# The combinators here mirror the ones in parsec.nix (bind, fmap, many,
# sepBy, ...) but operate on this state type. The character-level
# primitives are reused from parsec.nix through `liftP`.
#
# Only the handful of combinators that the parser actually uses are
# kept; the rest of parsec.nix has no counterpart here.

{ parsec }:

let
  b = builtins;

in rec {
  # The pieces of a string that was split at a separator.
  #
  # `builtins.split` puts the text between the separators and the
  # groups of the separator in one list, one after the other, so the
  # text is at the even positions.
  splitAt = sep: str:
    let
      parts = b.split sep str;
      even = i: i - (i / 2) * 2 == 0;
    in
      b.filter (x: x != null)
        (b.genList (i: if even i then b.elemAt parts i else null) (b.length parts));

  # The line and the column of an offset in the document.
  #
  # The line is the number of the line the offset is on, counting from
  # one, and the column is the number of characters in front of the
  # offset on that line.
  #
  # Both are worked out with the builtins that scan a string in one go,
  # so that they cost little even for a large document.
  positionAt = str: offset:
    let
      len = b.stringLength str;
      off = if offset < 0 then 0 else if offset > len then len else offset;
      # The text in front of the offset, split at the line breaks.
      parts = b.split "[\n]" (b.substring 0 off str);
      # The text of the line the offset is on: what is left after the
      # last line break.
      last = b.elemAt parts (b.length parts - 1);
    in {
      line = (b.length parts + 1) / 2;
      col = b.stringLength last;
    };

  # Did the raw result of a parser fail? A success is a two-element list
  # [value, state]; a failure is an attribute set describing the error.
  failed = res: ! b.isList res;

  # Build an error value carrying the current position.
  #
  # The line and the column are worked out only when they are asked
  # for: a parser fails many times while it looks for the shape of a
  # document, and most of those failures are never reported.
  errAt = s: ctx: msg:
    let
      p = positionAt s.str s.offset;
    in {
      context = ctx;
      inherit msg;
      offset = s.offset;
      line = p.line;
      col = p.col;
    };

  # A copy of the state `s`, moved to the given offset.
  stateAt = s: offset: s // {
    offset = offset;
    len = s.len - (offset - s.offset);
  };

  # ------------------------------------------------------------------
  # State
  # ------------------------------------------------------------------

  # The tag handles that the specification defines by itself. A %TAG
  # directive may redefine the secondary one, but not the primary one.
  defaultTags = {
    "!" = "!";
    "!!" = "tag:yaml.org,2002:";
  };

  mkState = str: opts: {
    inherit str;
    offset = 0;
    len = b.stringLength str;
    anchors = {};
    # The tag handles that the document defines. A %TAG directive adds
    # to them; they say what a handle such as "!e!" stands for.
    tagHandles = defaultTags;
    inherit opts;
    # The width of the properties (an anchor or a tag) that precede the
    # node, and the line they are on. The properties do not shift the
    # indentation of the node they belong to, so the width is needed to
    # work it out.
    propsWidth = 0;
    propsLine = -1;
    # The line that the cursor is on, when it is known. Working it out
    # means walking the input backwards, so it is worth keeping.
    contentLine = -1;
  };

  # Run a parser over a string.
  #   :: YamlParser a -> String -> AttrSet -> Either Error (a)
  defineAnchor = name: node: s: s // { anchors = s.anchors // { ${name} = node; }; };

  # Look up an anchor.
  lookupAnchor = name: s: s.anchors.${name} or null;

  # ------------------------------------------------------------------
  # Pure string utilities
  #
  # These work directly on the raw string so that they can be used for
  # look-ahead without consuming input.
  # ------------------------------------------------------------------

  # Offset of the first character of the line containing `offset`.
  lineStartOf = str: offset:
    let
      go = i:
        if i <= 0 then 0
        else if b.substring (i - 1) 1 str == "\n" then i
        else go (i - 1);
    in if offset <= 0 then 0 else go offset;

  # Does the line that holds `offset` indent with a tab?
  #
  # A tab may not be used to indent a node: the indentation of a
  # collection is counted in spaces, so a tab would have to be counted
  # as some number of columns, and the specification does not allow
  # that. A tab that comes after the indentation has begun is
  # ordinary white space.
  tabIndent = str: offset:
    let
      ls = lineStartOf str offset;
      go = i:
        if i >= offset then false
        else if b.substring i 1 str == "\t" then true
        else if b.substring i 1 str == " " then go (i + 1)
        else false;
    in go ls;

  # The offset of the tab that indents the line, when there is one.
  #
  # It is the tab that makes the line a mistake, so that is the place
  # the error is about.
  tabAt = str: offset:
    let
      ls = lineStartOf str offset;
      go = i:
        if i >= offset then null
        else if b.substring i 1 str == "\t" then i
        else if b.substring i 1 str == " " then go (i + 1)
        else null;
    in go ls;

  # Are all the characters in str[from..to) spaces or tabs?
  nextContentLine = str: from: end:
    let
      len = b.stringLength str;
      lim = if end > len then len else end;
      go = i: ls: blanks:
        if i >= lim then null
        else let
          # End of the current line.
          j =
            let g = k:
              if k >= lim then lim
              else let c = b.substring k 1 str; in
                if c == "\n" || c == "\r" then k else g (k + 1);
            in g i;
          # First non-space character of the line.
          k =
            let g = m:
              if m >= j then j
              else let c = b.substring m 1 str; in
                if c == " " || c == "\t" then g (m + 1) else m;
            in g i;
          nextStart =
            if j >= lim then lim
            else if b.substring j 1 str == "\r"
              then (if j + 1 < lim && b.substring (j + 1) 1 str == "\n" then j + 2 else j + 1)
              else j + 1;
        in
          if k >= j then go nextStart nextStart (blanks + 1)
          else if b.substring k 1 str == "#" then go nextStart nextStart blanks
          else { offset = k; indent = k - ls; contentEnd = j; inherit blanks; };
    in go from (lineStartOf str from) 0;

  # Like `nextContentLine`, but a comment line is not skipped: it ends
  # the search, and is reported as { comment = true; }. A plain scalar
  # cannot reach across a comment, because the comment ends the line it
  # sits on.
  #
  # Blank lines are still skipped, since they may legitimately sit in
  # the middle of a multi-line scalar.
  nextContentLineOrComment = str: from: end:
    let
      len = b.stringLength str;
      lim = if end > len then len else end;
      go = i: ls: blanks:
        if i >= lim then null
        else let
          j =
            let g = k:
              if k >= lim then lim
              else let c = b.substring k 1 str; in
                if c == "\n" || c == "\r" then k else g (k + 1);
            in g i;
          k =
            let g = m:
              if m >= j then j
              else let c = b.substring m 1 str; in
                if c == " " || c == "\t" then g (m + 1) else m;
            in g i;
          nextStart =
            if j >= lim then lim
            else if b.substring j 1 str == "\r"
              then (if j + 1 < lim && b.substring (j + 1) 1 str == "\n" then j + 2 else j + 1)
              else j + 1;
        in
          if k >= j then go nextStart nextStart (blanks + 1)
          else if b.substring k 1 str == "#" then { comment = true; indent = k - ls; }
          else { offset = k; indent = k - ls; contentEnd = j; inherit blanks; };
    in go from (lineStartOf str from) 0;

  # The indentation of the line containing `offset`, i.e. the number of
  # leading spaces. Returns null when the line is blank.
  columnAt = str: offset: offset - lineStartOf str offset;

  # ------------------------------------------------------------------
  # Document markers
  # ------------------------------------------------------------------

  # Does a document marker ("---" or "...") start at `offset` in `str`?
  # `avail` is the number of characters available from `offset`.
  atDocMarkerAt = str: offset: avail:
    avail >= 3
    && (b.substring offset 3 str == "---" || b.substring offset 3 str == "...")
    && (avail == 3
         || b.substring (offset + 3) 1 str == " "
         || b.substring (offset + 3) 1 str == "\t"
         || b.substring (offset + 3) 1 str == "\n"
         || b.substring (offset + 3) 1 str == "\r");

  # Does the content at `s` start a document marker? Such a line ends
  # the current collection rather than being part of it.
  atDocMarker = s: atDocMarkerAt s.str s.offset s.len;

  # ------------------------------------------------------------------
  # Errors
  # ------------------------------------------------------------------
  failWith = ctx: msg: s: errAt s ctx msg;

  # ------------------------------------------------------------------
  # Mapping keys
  # ------------------------------------------------------------------

  # Find a duplicated key among the entries of a mapping.
  #
  # The YAML specification requires the keys of a mapping to be unique:
  # "YAML insists they MUST be unique", so a duplicate is an error.
  #
  # The keys are compared by their text, because that is the name the
  # attribute gets in the Nix value: two entries with the same text
  # would collapse into a single attribute and one of them would be
  # lost. Keys that are not scalars are not compared, since they cannot
  # become an attribute name anyway.
  #
  # Returns null when the keys are unique, and otherwise an attribute
  # set with the text of the duplicated key and the offset of its second
  # occurrence.
  duplicateKey = entries:
    let
      keyText = e: if e.k.type == "scalar" then e.k.text else null;
      scalars = b.filter (e: keyText e != null) entries;
      groups = b.groupBy keyText scalars;
      dups = b.filter (name: b.length (groups.${name}) > 1) (b.attrNames groups);
    in
      if dups == []
      then null
      else
        let
          name = b.elemAt dups 0;
          group = groups.${name};
        in {
          inherit name;
          offset = (b.elemAt group 1).offset;
        };

  # Is an entry the merge key?
  #
  # The merge key is a plain scalar whose text is exactly "<<". A quoted
  # "<<" is an ordinary key, and so is a key that merely starts with
  # "<<".
  isMergeKey = e:
    e.k.type == "scalar"
    && ! (e.k.quoted or false)
    && e.k.text == "<<";

  # Whether the merge key is to be honoured. It is off by default,
  # because the merge key is a construct of YAML 1.1 that YAML 1.2 left
  # out of its core schema.
  mergeKeysEnabled = s: (s.opts or {}).enableMergeKeys or false;

  # Check the value of a merge key.
  #
  # The value must be a mapping, or a sequence of mappings; anything else
  # is a mistake. The check is made while the document is parsed, so that
  # it is reported like any other error of the document rather than
  # being thrown later.
  #
  # Returns null when the value is of that shape, and otherwise an
  # attribute set with the offset of the merge key.
  badMerge = e:
    let
      isMap = m: m.type == "map";
      ok =
        if isMap e.v
        then true
        else if e.v.type == "seq"
        then b.all (m: isMap m) e.v.items
        else false;
    in
      if ! (isMergeKey e) || ok
      then null
      else { offset = e.offset or null; };

  # ------------------------------------------------------------------
  # Core combinators
  #
  # A parser is a function from a state to either a failure or a
  # two-element list [value, newState].
  #
  # `bindY` takes a continuation that receives both the parsed value and
  # the new state, and returns a parser result directly.
  # ------------------------------------------------------------------

  bindY = parser: f: s:
    let res1 = parser s;
    in if failed res1
      then res1
      else f (b.elemAt res1 0) (b.elemAt res1 1);

  # ------------------------------------------------------------------
  # Stack-safe iteration
  #
  # Nix does not optimise tail calls, so a recursive loop consumes one
  # stack frame per iteration and overflows on long inputs. These helpers
  # express such loops as a `builtins.genericClosure` worklist instead,
  # which keeps the stack depth constant no matter how long the input is.
  #
  # A worklist element must stay small: it holds the state to try next
  # and at most one produced value. Accumulating a growing list inside
  # the element would build a chain of thunks as deep as the input, and
  # forcing it at the end would overflow the stack all the same. So the
  # values are collected afterwards, by folding over the worklist.
  # ------------------------------------------------------------------

  # Run a loop until it stops.
  #
  #   step :: { ... } -> { ...; value?; stop; error? }
  #
  # `step` sets `stop` to true to end the loop, and may set `error` to
  # report a failure. `init` is the first worklist element. The result
  # is the list of worklist elements, in order.
  #
  # The element that stops the loop is part of the result: it carries the
  # final state and, if the loop failed, the error. The operator only
  # looks at the *previous* element's `stop` flag, so that stopping
  # element is still produced.
  lastOf = init: work: b.foldl' (a: st: st) init work;

  # The values produced by a worklist, in order. Elements without a
  # `value` attribute did not produce one and are skipped.
  valuesOf = work:
    b.map (e: e.value) (b.filter (e: e ? value) work);

  # Zero or more repetitions. Stops when the inner parser fails or stops
  # making progress.

  # ------------------------------------------------------------------
  # Annotations
  # ------------------------------------------------------------------

  annotateY = f: parser: s:
    let res = parser s;
    in if failed res then f res else res;

  # ------------------------------------------------------------------
  # Lifting parsec.nix primitives
  # ------------------------------------------------------------------

  # Run a parsec.nix parser against the current position. parsec's
  # primitives only need (str, offset, len), so we hand them a derived
  # triple and project the result back into our state.
  liftP = parser: s:
    let
      derived = [s.str s.offset s.len];
      res = parser derived;
    in if failed res
      then res
      else let
        v = b.elemAt res 0;
        newOffset = b.elemAt res 1;
        newLen = b.elemAt res 2;
      in [v (s // { offset = newOffset; len = newLen; })];

  # ------------------------------------------------------------------
  # Character-level primitives
  #
  # These all take a state and return a result list, so they can be
  # used directly. The `*Y` variants that end in `Y` are *parsers* and
  # can be passed to `bindY` and friends.
  # ------------------------------------------------------------------

  stringY = str: s:
    let res = liftP (parsec.string str) s;
    in if failed res
      then annotateY (_: errAt s "yaml.string" "expected '${str}'") res
      else res;

  # Consume a literal string, returning true on success.
  isAtEnd = s: s.len == 0;
  takeY = n: s:
    if s.len < n
    then failWith "yaml.take" "unexpected end of input" s
    else [
      (b.substring s.offset n s.str)
      (s // { offset = s.offset + n; len = s.len - n; })
    ];

  # ------------------------------------------------------------------
  # Helpers used by other modules
  # ------------------------------------------------------------------

  # Is the character at the current position equal to `c`?
  atCharY = c: s: s.len >= 1 && b.substring s.offset 1 s.str == c;

  # Consume a single character equal to `c`, or fail.
}
