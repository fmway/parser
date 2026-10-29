let
  b = builtins;

  isSpace = c: c == " " || c == "\n" || c == "\t" || c == "\r";

  min = a: c: if a < c then a else c;

  max = a: c: if a > c then a else c;

  # The items of the list, in the other order.
  #
  # Nix has no builtin for this, and the list is folded over, so that
  # the work does not grow with the number of the items.
  reverse = xs:
    b.foldl' (acc: x: [ x ] ++ acc) [] xs;

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

  # Every place where `needle` occurs in `text`.
  #
  # The regex engine does the search, in one pass over the text, so the
  # cost does not grow with the number of calls and no stack is used.
  # A search that walks the text one character at a time uses one stack
  # frame per character and overflows the stack on a long file.
  #
  # `b.split` gives the text and the matches in turn: the even parts
  # are the text in between the matches and the odd parts are the
  # matches themselves. The parts are folded over directly, so the list
  # is walked once and not once per part, and the offsets are collected
  # in the reverse order and turned around at the end, so that the work
  # does not grow with the number of matches either.
  occurrences = needle: text:
    let
      parts = b.split "(${escapeRegex needle})" text;
      step = acc: part:
        if b.isString part
        then {
          offset = acc.offset + b.stringLength part;
          rev = acc.rev;
        }
        else
          let
            matched = b.concatStringsSep "" part;
          in {
            offset = acc.offset + b.stringLength matched;
            rev = [ acc.offset ] ++ acc.rev;
          };
      res = b.foldl' step { offset = 0; rev = []; } parts;
    in
      reverse res.rev;

  # The first place where `needle` occurs at or after `start`.
  #
  # Only the part of the haystack that follows `start` is searched, so
  # the cost is the length of that part and not the length of the whole
  # haystack.
  findFrom = needle: haystack: start:
    if b.stringLength needle == 0
    then null
    else
      let
        length = b.stringLength haystack;
        s = max 0 (min start length);
        suffix = b.substring s (length - s) haystack;
        parts = b.split "(${escapeRegex needle})" suffix;
      in
        # `b.split` gives the text and the matches in turn, so a list
        # of one part is a text without a match in it.
        if b.length parts == 1
        then null
        else s + b.stringLength (b.head parts);

  # The last place where `needle` occurs at or before `before`.
  #
  # The text in front of the place is searched in one pass, and the
  # search does not use the stack, so that a long text does not
  # overflow it.
  lastIndexOf = needle: haystack: before:
    if b.stringLength needle == 0 || b.stringLength haystack < b.stringLength needle
    then null
    else
      let
        needleLength = b.stringLength needle;
        length = b.stringLength haystack;
        limit = max 0 (min before (length - needleLength));
        prefix = b.substring 0 (limit + needleLength) haystack;
        parts = b.split "(${escapeRegex needle})" prefix;
      in
        # The last part is the text behind the last match, so the
        # match is that much before the end of the text.
        if b.length parts == 1
        then null
        else limit - b.stringLength (b.elemAt parts (b.length parts - 1));


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
    lastNonSpaceIn text 0 end;

  # The first index after the last non-space between `start` and `end`.
  #
  # The search for the last non-space is one pass over the part of the
  # text that is looked at, and it does not use the stack, so that a
  # long text does not overflow it.
  lastNonSpaceIn = text: start: end:
    let
      sub = b.substring start (end - start) text;
      parts = b.split "([^ \t\r\n])" sub;
    in
      # The last part is the text behind the last non-space, so the
      # non-space is that much before the end of the text.
      if b.length parts == 1
      then start
      else start + (end - start) - b.stringLength (b.elemAt parts (b.length parts - 1));

  trim = text:
    let
      length = b.stringLength text;
      start = firstNonSpace text 0;
      end = lastNonSpace text length;
    in
      if start >= end then "" else b.substring start (end - start) text;

  # The items of the list, with their number.
  #
  # The items are collected in the reverse order and turned around at
  # the end, so that the work does not grow with the number of the
  # items.
  numbered = items:
    let
      step = acc: item:
        let
          index = b.elemAt acc 0;
          rest = b.elemAt acc 1;
        in
          [ (index + 1) ([ { name = toString index; value = item; } ] ++ rest) ];
      res = b.foldl' step [ 0 [] ] items;
    in
      reverse (b.elemAt res 1);

  # The index of the lines of the text.
  #
  # The index holds the place of every line break of the text. The
  # places are in a set as well, so that the line of a place can be
  # found with a search in the set, and not with a walk over the text.
  # The search is a binary search, so the number of the line breaks
  # does not make the search slower.
  #
  # The index is made once for the text. A search for a line without
  # the index walks over the text again and again, and the cost of it
  # grows with the length of the text and with the number of the
  # searches.
  lineIndex = text:
    let
      length = b.stringLength text;
      breaks = occurrences "\n" text;
      count = b.length breaks;
      byNumber = b.listToAttrs (numbered breaks);
      breakAt = i: b.getAttr (toString i) byNumber;
      # The number of the line breaks that are before the offset.
      search = offset:
        let
          go = lo: hi:
            if lo >= hi
            then lo
            else
              let
                mid = lo + (hi - lo) / 2;
              in
                if breakAt mid < offset
                then go (mid + 1) hi
                else go lo mid;
        in
          go 0 count;
    in {
      inherit text length count breakAt search;
      # The start of the line that holds the offset.
      start = offset:
        let
          n = search offset;
        in
          if n == 0 then 0 else breakAt (n - 1) + 1;
      # The end of the line that holds the offset: the place of the
      # line break that ends it, or the end of the text.
      end = offset:
        let
          n = search offset;
        in
          if n >= count then length else breakAt n;
    };

  # The start of the line that holds `offset`.
  #
  # The search for the line break is one pass over the text in front of
  # the offset, and it does not use the stack, so that a long text
  # does not overflow it.
  lineStart = text: offset:
    let
      length = b.stringLength text;
    in
      # The first line starts at the start of the text, and the place
      # of a line break is in the line that the break ends.
      if length == 0 || offset <= 0
      then 0
      else
        let
          pos = min (offset - 1) (length - 1);
          prefix = b.substring 0 (pos + 1) text;
          parts = b.split "(\n)" prefix;
          rest = b.elemAt parts (b.length parts - 1);
        in
          # The last part is the text behind the last line break, so
          # the line break is that much before the end of the text.
          (pos + 1) - b.stringLength rest;

  # The end of the line that holds `offset`: the place of the line
  # break that ends it, or the end of the text.
  #
  # The search for the line break is one pass over the text behind the
  # offset, and it does not use the stack.
  lineEnd = text: offset:
    let
      length = b.stringLength text;
      o = max 0 (min offset length);
      suffix = b.substring o (length - o) text;
      parts = b.split "(\n)" suffix;
    in
      # The first part is the text in front of the first line break.
      if b.length parts == 1
      then length
      else o + b.stringLength (b.head parts);
in {
  inherit
    isSpace
    min
    max
    reverse
    escapeRegex
    occurrences
    numbered
    lineIndex
    findFrom
    lastIndexOf
    firstNonSpace
    lastNonSpace
    lastNonSpaceIn
    trim
    lineStart
    lineEnd
    ;
}
