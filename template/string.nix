let
  b = builtins;

  isSpace = c: c == " " || c == "\n" || c == "\t" || c == "\r";

  min = a: c: if a < c then a else c;

  findFrom = needle: haystack: start:
    let
      needleLength = b.stringLength needle;
      haystackLength = b.stringLength haystack;
      go = offset:
        if offset + needleLength > haystackLength
        then null
        else if b.substring offset needleLength haystack == needle
        then offset
        else go (offset + 1);
    in
      if needleLength == 0 || start > haystackLength
      then null
      else go start;

  lastIndexOf = needle: haystack: before:
    let
      needleLength = b.stringLength needle;
      haystackLength = b.stringLength haystack;
      go = offset:
        if offset < 0
        then null
        else if b.substring offset needleLength haystack == needle
        then offset
        else go (offset - 1);
    in
      if needleLength == 0 || before < 0
      then null
      else go (min before (haystackLength - needleLength));

  firstNonSpace = text: start:
    let
      length = b.stringLength text;
      go = offset:
        if offset >= length
        then length
        else if isSpace (b.substring offset 1 text)
        then go (offset + 1)
        else offset;
    in
      go start;

  lastNonSpace = text: end:
    let
      go = offset:
        if offset < 0
        then 0
        else if isSpace (b.substring offset 1 text)
        then go (offset - 1)
        else offset + 1;
    in
      go (end - 1);

  trim = text:
    let
      length = b.stringLength text;
      start = firstNonSpace text 0;
      end = lastNonSpace text length;
    in
      if start >= end then "" else b.substring start (end - start) text;

  lineStart = text: offset:
    let
      newline = lastIndexOf "\n" text (offset - 1);
    in
      if newline == null then 0 else newline + 1;

  lineEnd = text: offset:
    let
      length = b.stringLength text;
      newline = findFrom "\n" text offset;
    in
      if newline == null then length else newline;
in {
  inherit isSpace min findFrom lastIndexOf firstNonSpace lastNonSpace trim lineStart lineEnd;
}
