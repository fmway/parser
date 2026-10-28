let
  b = builtins;

  isSpace = c: c == " " || c == "\n" || c == "\t" || c == "\r";

  min = a: c: if a < c then a else c;

  # The characters that mean something to the regex engine.
  regexSpecial = c:
    c == "\\" || c == "." || c == "[" || c == "]" || c == "(" || c == ")"
    || c == "{" || c == "}" || c == "*" || c == "+" || c == "?" || c == "|"
    || c == "^" || c == "$";

  # The characters of a string, one by one.
  chars = text:
    let
      length = b.stringLength text;
    in
      b.genList (i: b.substring i 1 text) length;

  # The text of a string, with the characters that mean something to the
  # regex engine escaped, so that it can be used as a pattern.
  escapeRegex = text:
    b.concatStringsSep ""
      (b.map (c: if regexSpecial c then "\\" + c else c) (chars text));

  # Is the index even? `builtins.mod` does not exist, so the remainder
  # is worked out with a division.
  even = i: i - 2 * (b.div i 2) == 0;

  # Every place where `needle` occurs in `text`.
  #
  # The regex engine does the search, in one pass over the text, so the
  # cost does not grow with the number of calls and no stack is used.
  # A search that walks the text one character at a time uses one stack
  # frame per character and overflows the stack on a long file.
  occurrences = needle: text:
    let
      parts = b.split "(${escapeRegex needle})" text;
      count = b.length parts;
      step = acc: i:
        let
          item = b.elemAt parts i;
        in
          if even i
          then acc // { offset = acc.offset + b.stringLength item; }
          else
            let
              matched = b.concatStringsSep "" item;
            in {
              offset = acc.offset + b.stringLength matched;
              found = acc.found ++ [ acc.offset ];
            };
      res = b.foldl' step { offset = 0; found = []; } (b.genList (x: x) count);
    in
      res.found;

  # The first place where `needle` occurs at or after `start`.
  findFrom = needle: haystack: start:
    if b.stringLength needle == 0
    then null
    else
      let
        found = occurrences needle haystack;
        pick = xs:
          if xs == []
          then null
          else if b.head xs >= start
          then b.head xs
          else pick (b.tail xs);
      in
        pick found;

  # The last place where `needle` occurs at or before `before`.
  lastIndexOf = needle: haystack: before:
    if b.stringLength needle == 0
    then null
    else
      let
        found = occurrences needle haystack;
        limit = min before (b.stringLength haystack - b.stringLength needle);
      pick = xs:
        if xs == []
        then null
        else
          let
            first = b.head xs;
            rest = b.tail xs;
          in
            if rest == []
            then (if first <= limit then first else null)
            else
              let
                later = pick rest;
              in
                if later != null
                then later
                else if first <= limit
                then first
                else null;
    in
      pick found;

  # The first non-space at or after `start`. Computed with a single
  # regular expression, so a long run of spaces no longer overflows the
  # stack.
  firstNonSpace = text: start:
    let
      length = b.stringLength text;
      sub = b.substring start (length - start) text;
      m = b.match "^([ \t\r\n]*)(.*)$" sub;
      spaces = if m == null then "" else b.head m;
    in
      start + b.stringLength spaces;

  # The first index after the last non-space before `end`. Computed with
  # a single regular expression.
  lastNonSpace = text: end:
    let
      sub = b.substring 0 end text;
      m = b.match "^(.*[^ \t\r\n])[ \t\r\n]*$" sub;
    in
      if m == null
      then 0
      else b.stringLength (b.head m);

  trim = text:
    let
      length = b.stringLength text;
      start = firstNonSpace text 0;
      end = lastNonSpace text length;
    in
      if start >= end then "" else b.substring start (end - start) text;

  # The start of the line that holds `offset`.
  #
  # The search uses the stack-safe `lastIndexOf`, so a long line no
  # longer overflows the stack.
  lineStart = text: offset:
    let
      length = b.stringLength text;
      pos = min (offset - 1) (length - 1);
      nl = lastIndexOf "\n" text pos;
    in
      if nl == null then 0 else nl + 1;

  # The end of the line that holds `offset`: the place of the line
  # break that ends it, or the end of the text.
  lineEnd = text: offset:
    let
      length = b.stringLength text;
      nl = findFrom "\n" text offset;
    in
      if nl == null then length else nl;
in {
  inherit
    isSpace
    min
    escapeRegex
    occurrences
    findFrom
    lastIndexOf
    firstNonSpace
    lastNonSpace
    trim
    lineStart
    lineEnd
    ;
}
