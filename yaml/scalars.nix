# YAML scalars.
#
# Four kinds of scalar are supported:
#
#   plain        : unquoted, e.g. `foo bar`
#   single-quoted: 'foo bar'  (with '' as the escape for a quote)
#   double-quoted: "foo bar"  (with backslash escapes)
#   block        : | and >    (literal and folded)
#
# Scalars are parsed into an intermediate node:
#
#   { type = "scalar"; text = "..."; quoted = Bool; }
#
# The `quoted` flag records whether the scalar was written in quotes.
# Only *plain* scalars are resolved to a non-string type, so a quoted
# "true" is the string "true" while a plain true is the boolean true.
# This matches the YAML 1.2 core schema.
#
# Resolution follows the YAML 1.2 core schema:
#
#   null  : ~ | null | Null | NULL | (empty)
#   bool  : true | True | TRUE | false | False | FALSE
#   int   : [-+]?[0-9]+ | 0o[0-7]+ | 0x[0-9a-fA-F]+
#   float : [-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?
#   string: everything else
#
# Note: the YAML 1.2 *core* schema does not treat yes/no/on/off as
# booleans (that was YAML 1.1). We keep them as strings.

{ state, spaces }:

with state;

let
  b = builtins;
  concat = b.concatStringsSep "";

  hexTable = {
    "0" = 0; "1" = 1; "2" = 2; "3" = 3; "4" = 4; "5" = 5; "6" = 6; "7" = 7;
    "8" = 8; "9" = 9;
    "a" = 10; "b" = 11; "c" = 12; "d" = 13; "e" = 14; "f" = 15;
    "A" = 10; "B" = 11; "C" = 12; "D" = 13; "E" = 14; "F" = 15;
  };

  hexVal = c: if b.hasAttr c hexTable then hexTable.${c} else -1;

  isHexDigit = c: b.hasAttr c hexTable;

  # The hexadecimal digits, for formatting a code point.
  hexDigits = "0123456789ABCDEF";

  # A four digit hexadecimal number, zero padded.
  hex4 = n:
    let
      # The remainder of a division, for non-negative integers.
      mod = x: y: x - y * b.div x y;
      digit = v: b.substring (mod v 16) 1 hexDigits;
      # The place value of the i-th digit from the right.
      place = i: if i == 0 then 1 else 16 * place (i - 1);
      # Build the digits from the most significant one down.
      go = i: acc:
        if i < 0 then acc
        else go (i - 1) (acc + digit (b.div n (place i)));
    in go 3 "";

  # Turn a Unicode code point into a string. Nix has no escape syntax for
  # this, but its JSON parser understands \uXXXX, so that is used here.
  fromCodePoint = cp:
    let
      # The JSON escape for the code point. The backslash is doubled so
      # that it survives Nix's own string parsing.
      escape = c: "\\u" + hex4 c;
      # The bounds of the basic multilingual plane, and the base of the
      # surrogate range.
      bmpLimit = 65536;
      surrogateBase = 55296;
      surrogateLow = 56320;
      surrogateSize = 1024;
    in
      if cp < bmpLimit
      then b.fromJSON ("\"" + escape cp + "\"")
      else
        # Outside the basic multilingual plane a surrogate pair is used.
        let
          v = cp - bmpLimit;
          hi = surrogateBase + b.div v surrogateSize;
          lo = surrogateLow + v - b.div v surrogateSize * surrogateSize;
        in b.fromJSON ("\"" + escape hi + escape lo + "\"");

  # ------------------------------------------------------------------
  # Pure scanning helpers
  # ------------------------------------------------------------------

  # Text of the line starting at `offset`, up to but not including the
  # line break.
  lineTextAt = str: offset: maxEnd:
    let
      len = b.stringLength str;
      go = i:
        if i >= maxEnd || i >= len then i
        else let c = b.substring i 1 str; in
          if c == "\n" || c == "\r" then i else go (i + 1);
      end = go offset;
    in b.substring offset (end - offset) str;

  # Offset of the start of the next line after `offset`.
  nextLineAt = str: offset: maxEnd:
    let
      len = b.stringLength str;
      go = i:
        if i >= maxEnd || i >= len then i
        else let c = b.substring i 1 str; in
          if c == "\n" then i + 1
          else if c == "\r" then
            (if i + 1 < len && b.substring (i + 1) 1 str == "\n" then i + 2 else i + 1)
          else go (i + 1);
    in go offset;

  # Strip trailing spaces and tabs.
  rstrip = text:
    let
      len = b.stringLength text;
      go = i:
        if i <= 0 then ""
        else let c = b.substring (i - 1) 1 text; in
          if c == " " || c == "\t" then go (i - 1) else b.substring 0 i text;
    in go len;

  # Strip leading spaces and tabs.
  lstrip = text:
    let
      len = b.stringLength text;
      go = i:
        if i >= len then ""
        else let c = b.substring i 1 text; in
          if c == " " || c == "\t" then go (i + 1) else b.substring i (len - i) text;
    in go 0;

  # Number of leading spaces of a line (a tab counts as one column).
  indentOf = text:
    let
      len = b.stringLength text;
      go = i:
        if i >= len then i
        else let c = b.substring i 1 text; in
          if c == " " || c == "\t" then go (i + 1) else i;
    in go 0;

  isBlankLine = text: rstrip text == "";

in rec {
  inherit lineTextAt nextLineAt rstrip lstrip indentOf isBlankLine;

  # ------------------------------------------------------------------
  # Plain scalars
  # ------------------------------------------------------------------

  # Scan a plain scalar on a single line.
  #
  #   mode = "block" : stops at ": " (key separator), " #" (comment) or EOL
  #   mode = "flow"  : additionally stops at flow indicators and at ":"
  #                    followed by a flow indicator
  #
  # Returns { text; kind; end; } where kind is one of
  #   "eol" | "colon" | "comment" | "flow" | "eof"
  scanPlain = mode: str: start: maxEnd:
    if mode == "flow"
    then scanPlainFlow str start maxEnd
    else scanPlainBlock str start maxEnd;

  # The scan of a plain scalar in block context.
  #
  # A ':' that is followed by white space ends the scalar, and so does
  # a '#' that is preceded by white space.
  scanPlainBlock = str: start: maxEnd:
    let
      len = b.stringLength str;
      limit = if start + maxEnd < len then start + maxEnd else len;
      at = i: b.substring i 1 str;
      go = i:
        if i >= limit then { end = i; kind = "eof"; }
        else let c = at i; in
          if c == "\n" || c == "\r" then { end = i; kind = "eol"; }
          else if c == "#" && i > start && (at (i - 1) == " " || at (i - 1) == "\t")
            then { end = i - 1; kind = "comment"; }
          else if c == ":"
            then let nc = if i + 1 < limit then at (i + 1) else "\n"; in
              if nc == " " || nc == "\t" || nc == "\n" || nc == "\r"
                then { end = i; kind = "colon"; }
                else go (i + 1)
          else go (i + 1);
      res = go start;
    in
      # Note: the fields are computed separately rather than merging
      # attrsets, because merging would force `res` before `raw` has been
      # derived from it.
      {
        end = res.end;
        kind = res.kind;
        text = rstrip (b.substring start (res.end - start) str);
      };

  # The scan of a plain scalar in flow context.
  #
  # A flow indicator ends the scalar as well, and so does a ':' that
  # is followed by one.
  scanPlainFlow = str: start: maxEnd:
    let
      len = b.stringLength str;
      limit = if start + maxEnd < len then start + maxEnd else len;
      at = i: b.substring i 1 str;
      go = i:
        if i >= limit then { end = i; kind = "eof"; }
        else let c = at i; in
          if c == "\n" || c == "\r" then { end = i; kind = "eol"; }
          else if c == "#" && i > start && (at (i - 1) == " " || at (i - 1) == "\t")
            then { end = i - 1; kind = "comment"; }
          else if c == "," || c == "[" || c == "]" || c == "{" || c == "}"
            then { end = i; kind = "flow"; }
          else if c == ":"
            then let nc = if i + 1 < limit then at (i + 1) else "\n"; in
              if nc == " " || nc == "\t" || nc == "\n" || nc == "\r"
                then { end = i; kind = "colon"; }
                else if nc == "," || nc == "[" || nc == "]" || nc == "{" || nc == "}"
                  then { end = i; kind = "colon"; }
                  else go (i + 1)
          else go (i + 1);
      res = go start;
    in
      {
        end = res.end;
        kind = res.kind;
        text = rstrip (b.substring start (res.end - start) str);
      };

  # A plain scalar in block context. It may span multiple lines, as long
  # as the continuation lines are indented more than `contIndent`. The
  # lines are folded together with a space.
  #
  # `contIndent` is the indentation of the block the scalar belongs to;
  # continuation lines must be indented strictly further than that.
  #
  # `isKey` says whether the scalar is being read as a mapping key. A key
  # may be followed by ": ", which is how we detect that a line holds a
  # mapping entry rather than a plain value.
  plainNode = isKey: contIndent: s:
    let
      str = s.str;
      maxEnd = s.offset + s.len;

      first = scanPlain "block" str s.offset s.len;

      # Collect the continuation lines. A continuation line must be
      # indented more than `contIndent` and must not itself look like a
      # mapping key or a sequence entry.
      #
      # Each line is recorded together with the number of blank lines
      # that preceded it, so that the lines can be folded correctly: a
      # single line break becomes a space, while blank lines become line
      # feeds.
      collect = st: acc:
        let
          nl = nextContentLineOrComment str st.offset maxEnd;
        in
          if nl == null
          then [acc st]
          else if nl.comment or false
            # A comment ends the line it sits on, so a plain scalar
            # cannot reach across it.
            then [acc st]
          else if atDocMarkerAt str nl.offset (maxEnd - nl.offset)
            # A document marker ends the scalar.
            then [acc st]
          else if nl.indent <= contIndent
            then [acc st]
            else
              let
                # The text of the continuation line. The scan stops at a
                # comment, so a comment on the line ends it rather than
                # becoming part of the scalar.
                cont = scanPlain "block" str nl.offset (nl.contentEnd - nl.offset);
                text = cont.text;
              in
                if cont.kind == "colon"
                  # A "key:" on a continuation line ends the scalar.
                  then [acc st]
                  else if cont.kind == "comment"
                    # A comment ends the line it sits on, and with it
                    # the scalar: the lines below it are not part of
                    # it. So "a\n  b # c\n  d" holds "a b", and the
                    # "d" is left over.
                    then [
                      (acc ++ [ { blanks = nl.blanks; text = text; } ])
                      (stateAt st (nextLineAt str nl.contentEnd maxEnd))
                    ]
                  else
                      # Continue after the end of this line, so that the
                      # next search starts on the following line.
                      collect
                        (stateAt st (nextLineAt str nl.contentEnd maxEnd))
                        (acc ++ [ { blanks = nl.blanks; text = text; } ]);
    in
      if first.text == "" && first.kind == "eol"
        then failWith "yaml.scalar" "expected a plain scalar" s
        else if first.kind == "colon"
        then
          # A mapping key: it ends at the ':' and is always on one line.
          if isKey
            then [ { type = "scalar"; text = first.text; quoted = false; }
                   (s // { offset = first.end; len = s.len - (first.end - s.offset); }) ]
            else failWith "yaml.scalar" "expected a plain scalar" s
        else
          let
            afterFirst = s // {
              offset = first.end;
              len = s.len - (first.end - s.offset);
            };
            # A comment ends the line it sits on, so the scalar does
            # not continue past it. Otherwise the continuation must
            # start on a following line, so skip to the end of the
            # current one first.
            cont =
              if first.kind == "comment"
              then [ [ { blanks = 0; text = first.text; } ] afterFirst ]
              else collect
                (b.elemAt (spaces.skipRestOfLine afterFirst) 1)
                [ { blanks = 0; text = first.text; } ];
          in if failed cont
            then cont
            else let
              lines = b.elemAt cont 0;
              st = b.elemAt cont 1;
            in [ { type = "scalar"; text = foldPlain lines; quoted = false; } st ];

  # A plain scalar in flow context. It may span multiple lines; a line
  # break is folded into a space.
  plainFlowNode = s:
    let
      str = s.str;
      maxEnd = s.offset + s.len;

      # A plain scalar in flow context may not start with "- ", nor
      # with a "-" that is followed by a flow indicator: both are the
      # block sequence entry indicator, which has no meaning here.
      # A "-" on its own is fine, so "[a-b]" is a scalar.
      dashNext =
        if s.len >= 2 then b.substring (s.offset + 1) 1 str else "\n";
      badDash =
        b.substring s.offset 1 str == "-"
        && (
          dashNext == " " || dashNext == "\t" || dashNext == "\n"
            || dashNext == "\r"
          || dashNext == "," || dashNext == "["
          || dashNext == "]" || dashNext == "{" || dashNext == "}"
        );

      # A '#' that is not preceded by white space is not part of a
      # scalar: it starts a comment, and a comment has to be separated
      # from what comes before it. So in "[a, b,c# x" the scalar ends at
      # the comma and the '#' is left over, which is not an entry.
      badHash =
        if isAtEnd s || b.substring s.offset 1 str != "#"
        then false
        else if s.offset == 0
          then false
          else
            let
              p = b.substring (s.offset - 1) 1 str;
            in p != " " && p != "\t" && p != "\n" && p != "\r";

      go = st: acc: breaks:
        let
          res = scanPlain "flow" str st.offset st.len;
          text = res.text;
          kind = res.kind;
          st1 = st // { offset = res.end; len = st.len - (res.end - st.offset); };
        in
          if text == "" && (kind == "eol" || kind == "eof")
            then [acc st1 breaks]
            else if kind == "eof"
              then [(concat (acc ++ [ text ])) st1 breaks]
            else if kind == "comment"
              then [(concat (acc ++ [ text ])) st1 breaks]
              else
                let
                  acc' = acc ++ [ text ];
                in if kind == "eol"
                  then
                    # A line break inside a flow scalar folds into a
                    # space, unless the next line is empty. A line that
                    # starts with a flow indicator ends the scalar.
                    let
                      nl = nextContentLineOrComment str st1.offset maxEnd;
                    in if nl == null
                      then [(concat acc') st1 breaks]
                      else if nl.comment or false
                        # A comment ends the line it sits on, so the
                        # scalar does not reach across it. What follows
                        # has to be introduced by a ',' or close the
                        # collection.
                        then [(concat acc') st1 breaks]
                      else
                        let
                          nextText = b.substring nl.offset (nl.contentEnd - nl.offset) str;
                          nextChar = b.substring nl.offset 1 str;
                        in if nextChar == "," || nextChar == "["
                             || nextChar == "]" || nextChar == "{"
                             || nextChar == "}"
                             # A ':' that follows a line break would be
                             # the indicator of an implicit key, which
                             # the specification does not allow in flow
                             # context; such a key needs a '?'.
                             || nextChar == ":"
                          then [(concat acc') st1 breaks]
                          else if isBlankLine nextText
                            then go (stateAt st1 nl.offset) (acc' ++ [ "\n" ]) (breaks + 1)
                            else go (stateAt st1 nl.offset) (acc' ++ [ " " ]) 0
                  else [(concat acc') st1 breaks];
    in if badDash
          then failWith "yaml.scalar" "a block sequence entry is not allowed in flow context" s
          else if badHash
            then failWith "yaml.scalar" "expected a plain scalar" s
          else let
            res = go s [] 0;
          in if failed res
            then res
            else let
              text = b.elemAt res 0;
            in if text == ""
              then failWith "yaml.scalar" "expected a plain scalar" s
              else [ { type = "scalar"; text = text; quoted = false; } (b.elemAt res 1) ];

  # ------------------------------------------------------------------
  # Quoted scalars
  # ------------------------------------------------------------------

  # A quoted scalar. `contIndent` is the indentation of the enclosing
  # block; continuation lines must be indented strictly further than
  # that. Pass null for flow context, where there is no such requirement.
  #
  # `isKey` says whether the scalar is being read as a mapping key. Only
  # a single-quoted key may span more than one line; the other forms of
  # key end at the end of their line.
  quotedNode = contIndent: isKey: s:
    let
      s1 = if atCharY "'" s
        then [null (s // { offset = s.offset + 1; len = s.len - 1; })]
        else if atCharY "\"" s
          then [null (s // { offset = s.offset + 1; len = s.len - 1; })]
        else failWith "yaml.scalar" "expected a quoted scalar" s;

      isDouble = atCharY "\"" s;

      # After a line break, check that the continuation line is indented
      # enough.
      #
      # A closing quote at the start of a line ends the scalar, so its
      # indentation does not matter.
      checkIndent = st:
        if contIndent == null
          then [null st]
          else let
            nl = nextContentLine st.str st.offset (st.offset + st.len);
            closer = if isDouble then "\"" else "'";
            endsScalar = nl.offset < st.offset + st.len
              && b.substring nl.offset 1 st.str == closer;
            # A document marker ends the document, so a quoted scalar
            # cannot reach across one: the scalar is unterminated.
            docMarker = nl.offset < st.offset + st.len
              && atDocMarkerAt st.str nl.offset (st.len - (nl.offset - st.offset));
          in if nl == null
            then [null st]
            else if docMarker
              then failWith "yaml.scalar" "document marker inside a quoted scalar" st
            else if endsScalar
              then [null st]
            else if nl.indent > contIndent
              then [null (st // { offset = nl.offset; len = st.len - (nl.offset - st.offset); })]
              else failWith "yaml.scalar" "quoted scalar continuation is not indented enough" st;

      # Fold the lines of a quoted scalar.
      #
      # The leading white space of a continuation line is dropped. A
      # line break between two lines of content becomes a space, while a
      # line break that is followed by an empty line becomes a line feed
      # for each empty line. The trailing white space of a line is
      # dropped, except on the last line when it holds content.
      foldQuoted = lines:
        let
          n = b.length lines;

          # Strip a line: drop the leading white space on a continuation
          # line, and the trailing white space on every line but a last
          # line that holds content.
          strip = i: t:
            let
              lead = if i == 0 then t else lstrip t;
              isLast = i == n - 1;
            in
              if isLast
              then (if rstrip lead == "" then "" else lead)
              else rstrip lead;
          stripped = b.genList (i: strip i (b.elemAt lines i)) n;

          # Fold the lines together.
          #
          # `pending` counts the empty lines that have not been folded
          # yet, and `content` says whether some content has been seen.
          #
          # An empty line that follows some content becomes a line feed,
          # an empty line that comes before it becomes a space, and the
          # empty lines at the end become a space as well.
          fold = i: out: pending: content:
            if i >= n
            then
              # The empty lines at the end of the scalar.
              if pending == 0
              then concat out
              else if content
                then concat (out ++ (if pending == 1
                  then [" "]
                  else b.genList (_: "\n") (pending - 1)))
                else concat (out ++ (if pending == 2
                  then [" "]
                  else b.genList (_: "\n") (pending - 2)))
            else let
              t = b.elemAt stripped i;
            in
              if t == ""
              then fold (i + 1) out (pending + 1) content
              else
                fold (i + 1)
                  (out ++
                    (if pending == 0
                     then (if content then [" "] else [])
                     else (if content
                       then b.genList (_: "\n") pending
                       else [" "]))
                    ++ [t])
                  0
                  true;
        in
          # A scalar on a single line is not folded at all.
          if n <= 1 then concat lines else fold 0 [] 0 false;

      # Collect the empty lines that follow a line break, and return the
      # state at the first line that holds content.
      #
      # A comment line is skipped: it is not an empty line, and it does
      # not end the scalar.
      collectEmpty = s: acc:
        let
          s1 = spaces.skipSpacesTo s;
          text = lineTextAt s.str s.offset (s.offset + s.len);
        in
          if isAtEnd s1
          then [acc s1]
          else if isBlankLine text
          then
            let
              brk2 = b.elemAt (spaces.sBreak s1) 1;
            in collectEmpty brk2 (acc ++ [ "" ])
          else if b.substring s1.offset 1 s1.str == "#"
          then
            # A comment: skip the whole line.
            let
              s2 = b.elemAt (spaces.skipRestOfLine s1) 1;
            in collectEmpty s2 acc
          else [acc s1];

      singleGo = st: lines: cur:
        if isAtEnd st
          then failWith "yaml.scalar" "unterminated single-quoted scalar" st
          else let c = b.substring st.offset 1 st.str; in
            if c == "'"
              then let
                s2 = st // { offset = st.offset + 1; len = st.len - 1; };
              in if atCharY "'" s2
                then singleGo (s2 // { offset = s2.offset + 1; len = s2.len - 1; }) lines (cur + "'")
                else [ (foldQuoted (lines ++ [cur])) s2 ]
              else if c == "\n" || c == "\r"
                then
                  # As above: a key ends at the end of its line.
                  if isKey
                  then failWith "yaml.scalar" "a mapping key may not span more than one line" st
                  else
                    let
                      brk = b.elemAt (spaces.sBreak st) 1;
                      res = checkIndent brk;
                    in if failed res
                      then res
                      else
                        let
                          res2 = collectEmpty brk [];
                        in
                          if failed res2
                          then res2
                          else singleGo (b.elemAt res2 1) (lines ++ [cur] ++ (b.elemAt res2 0)) ""
              else singleGo (st // { offset = st.offset + 1; len = st.len - 1; }) lines (cur + c);

      # Read exactly n characters, failing if there aren't enough.
      readN = n: st:
        if st.len < n
          then failWith "yaml.scalar" "unexpected end of input in escape" st
          else [
            (b.substring st.offset n st.str)
            (st // {
              offset = st.offset + n;
              len = st.len - n;
            })
          ];

      # A \xXX, \uXXXX or \UXXXXXXXX escape.
      hexEscape = n: st:
        let
          res = readN n st;
        in if failed res
          then res
          else let
            digits = b.elemAt res 0;
            st' = b.elemAt res 1;
            chars = stringChars digits;
            ok = b.foldl' (acc: c: acc && isHexDigit c) true chars;
            value = b.foldl' (acc: c: acc * 16 + hexVal c) 0 chars;
          in if ! ok
            then failWith "yaml.scalar" "invalid hex escape sequence" st
            else [ (fromCodePoint value) st' ];

      escape = st:
        let
          s2 = st // { offset = st.offset + 1; len = st.len - 1; };
          adv = s2 // { offset = s2.offset + 1; len = s2.len - 1; };
        in if isAtEnd s2
          then failWith "yaml.scalar" "unterminated escape sequence" st
          else let c = b.substring s2.offset 1 st.str; in
            if c == "n" then ["\n" adv]
            else if c == "t" then ["\t" adv]
            else if c == "r" then ["\r" adv]
            else if c == "0" then [ (fromCodePoint 0) adv]
            else if c == "a" then [ (fromCodePoint 7) adv]
            else if c == "b" then [ (fromCodePoint 8) adv]
            else if c == "v" then [ (fromCodePoint 11) adv]
            else if c == "f" then [ (fromCodePoint 12) adv]
            else if c == "e" then [ (fromCodePoint 27) adv]
            else if c == " " then [" " adv]
            else if c == "\"" then ["\"" adv]
            else if c == "/" then ["/" adv]
            else if c == "\\" then ["\\" adv]
            else if c == "N" then [ (fromCodePoint 133) adv]
            else if c == "_" then [ (fromCodePoint 160) adv]
            else if c == "L" then [ (fromCodePoint 8232) adv]
            else if c == "P" then [ (fromCodePoint 8233) adv]
            else if c == "\n" || c == "\r"
              then let brk = b.elemAt (spaces.sBreak s2) 1;
              in [null (spaces.skipSpacesTo brk)]
            else if c == "x" then hexEscape 2 adv
            else if c == "u" then hexEscape 4 adv
            else if c == "U" then hexEscape 8 adv
            else failWith "yaml.scalar" "unknown escape sequence '\\${c}'" st;

      doubleGo = st: lines: cur:
        if isAtEnd st
          then failWith "yaml.scalar" "unterminated double-quoted scalar" st
          else let c = b.substring st.offset 1 st.str; in
            if c == "\""
              then [ (foldQuoted (lines ++ [cur])) (st // { offset = st.offset + 1; len = st.len - 1; }) ]
              else if c == "\\"
                then let
                  res = escape st;
                in if failed res
                  then res
                  else let
                    text = b.elemAt res 0;
                    st' = b.elemAt res 1;
                  in if text == null
                    # A backslash followed by a line break: the line is
                    # continued, so it does not end here.
                    then doubleGo st' lines cur
                    else doubleGo st' lines (cur + text)
              else if c == "\n" || c == "\r"
                then
                  # A mapping key has to end at the end of its line. The
                  # specification allows a key of more than one line,
                  # but only when it is written as an explicit key, and
                  # a quoted scalar is never one of those.
                  if isKey
                  then failWith "yaml.scalar" "a mapping key may not span more than one line" st
                  else
                    let
                      brk = b.elemAt (spaces.sBreak st) 1;
                      res = checkIndent brk;
                    in if failed res
                      then res
                      else
                        let
                          res2 = collectEmpty brk [];
                        in
                          if failed res2
                          then res2
                          else doubleGo (b.elemAt res2 1) (lines ++ [cur] ++ (b.elemAt res2 0)) ""
              else doubleGo (st // { offset = st.offset + 1; len = st.len - 1; }) lines (cur + c);
    in
    let
      st = b.elemAt s1 1;
      res = if isDouble then doubleGo st [] "" else singleGo st [] "";
    in if failed res
      then res
      else let
        text = b.elemAt res 0;
        st' = b.elemAt res 1;
      in [ { type = "scalar"; text = text; quoted = true; } st' ];

  # ------------------------------------------------------------------
  # Block scalars (| and >)
  # ------------------------------------------------------------------

  # A block scalar: | (literal) or > (folded), with an optional chomping
  # indicator (- or +) and an optional explicit indentation indicator.
  #
  # The content indentation is the indentation of the first non-empty
  # content line, unless an explicit indicator is given (in which case
  # the indentation is relative to the parent node's indentation).
  blockNode = parentIndent: s:
    let
      style = b.substring s.offset 1 s.str;
      s1 = s // { offset = s.offset + 1; len = s.len - 1; };

      # Parse the header. YAML allows the chomping and indentation
      # indicators in either order.
      #
      # Note that Nix's `builtins.match` requires the pattern to match
      # the whole string, so the header is taken character by character.
      parseHeader = st:
        let
          # The characters of the header, up to two of them.
          headerChars =[
            (if st.len >= 1 then b.substring st.offset 1 st.str else "")
            (if st.len >= 2 then b.substring (st.offset + 1) 1 st.str else "")
          ];
          isDigit = c: c != "" && b.match "[0-9]" c != null;
          isChomp = c: c != "" && b.match "[+-]" c != null;
          c0 = b.elemAt headerChars 0;
          c1 = b.elemAt headerChars 1;

          # The indentation indicator and the chomping indicator, in
          # either order.
          digit =
            if isDigit c0 then c0
            else if isDigit c1 then c1
            else null;
          chomp =
            if isChomp c0 then c0
            else if isChomp c1 then c1
            else null;
          consumed =
            (if digit != null then b.stringLength digit else 0)
            + (if chomp != null then b.stringLength chomp else 0);
        in [{ inherit digit chomp; } (st // {
          offset = st.offset + consumed;
          len = st.len - consumed;
        })];

      # Skip the rest of the header line.
      # A comment on the line of the header has to be separated from the
      # header by white space, so "> # c" is a header followed by a
      # comment while "># c" is not a comment at all.
      afterHeader = st:
        let
          s2 = spaces.skipSpacesTo st;
        in
          if ! (isAtEnd st)
             && b.substring st.offset 1 st.str == "#"
          then failWith "yaml.scalar" "a comment must be preceded by white space" st
          else [ (b.elemAt (spaces.skipRestOfLine s2) 1) ];

      # Collect the raw content lines of the block scalar together with
      # their indentation. Stops at the first non-empty line indented
      # less than `base`.
      #
      # Empty lines are kept as empty strings, so that the folding rules
      # can turn them into line feeds.
      # A line that holds only a comment.
      isCommentLine = text:
        let
          t = lstrip text;
        in b.substring 0 1 t == "#";

      collect = st: base: explicit: contentSeen: lines:
        let
          text = lineTextAt st.str st.offset (st.offset + st.len);
          ind = indentOf text;
          blank = isBlankLine text;
          next = nextLineAt st.str st.offset (st.offset + st.len);
          st' = st // { offset = next; len = st.len - (next - st.offset); };
        in
          if isAtEnd st
          then [lines st]
          else if blank && (base == null || ind <= base)
            # An empty line: it holds no content at all.
            then collect st' base explicit contentSeen (lines ++ [ "" ])
            else if base == null
            then collect st' ind explicit true (lines ++ [ text ])
            # A comment line is not part of the scalar, so it normally
            # ends it. When the indentation was taken from lines that
            # hold only white space, and no content has been seen yet,
            # a comment that is indented less than that says that the
            # indentation was never settled, which the specification
            # does not allow.
            else if isCommentLine text && explicit == null && ! contentSeen && ind < base
              # The error is about the comment, so it points at the '#'
              # that starts it.
              then failWith "yaml.scalar" "a comment cannot fix the indentation of a block scalar"
                (stateAt st (st.offset + ind))
              else if ind < base
              then [lines st]
              else if atDocMarkerAt st.str st.offset st.len
                then [lines st]
                else collect st' base explicit true (lines ++ [ text ]);

      # Strip `base` columns of indentation from a line.
      strip = base: text: b.substring base (b.stringLength text - base) text;
    in
    let
      # Parse the header and move past it.
      hres = parseHeader s1;
    in if failed hres
      then hres
      else let
        hdr = b.elemAt hres 0;
        st1 = b.elemAt hres 1;
        # Skip the rest of the header line.
        hres2 = afterHeader st1;
      in if failed hres2
        then hres2
        else let
        st2 = b.elemAt hres2 0;
        # Find the indentation of the first non-empty content line.
        #
        # The content of a block scalar must be indented more than the
        # block that holds it, so a line that is not indented enough
        # ends the search.
# The content indentation is taken from the first line that has
        # content. A line that holds nothing at all says nothing, but a
        # line that holds only white space counts: it is more indented
        # than the block that holds the scalar, so it is content, and
        # the widest of those lines sets the indentation. A later line
        # that is indented less than that ends the scalar.
        detectBase = st:
          let
            text = lineTextAt st.str st.offset (st.offset + st.len);
            ind = indentOf text;
            next = nextLineAt st.str st.offset (st.offset + st.len);
            st' = st // { offset = next; len = st.len - (next - st.offset); };
            # The line holds nothing but white space.
            blankish = rstrip text == "";
            # The line is indented with spaces only. A tab is not
            # white space for the purpose of indentation, so a line
            # that starts with one after a space does not say how deep
            # the content sits.
            spaceIndent =
              let
                n = b.stringLength text;
              in
                if n == 0
                then 0
                else let
                  go = i:
                    if i >= n then n
                    else if b.substring i 1 text == " " then go (i + 1)
                    else i;
                in go 0;
          in
            if b.stringLength text == 0
            then
              # A truly empty line is not content; keep looking.
              (if isAtEnd st' then null else detectBase st')
            else if ind <= parentIndent
            then
              # The line is not indented enough to be content, so the
              # scalar is over.
              null
            else if blankish
            then
              let
                res = detectBase st';
              in if res == null || spaceIndent > res then spaceIndent else res
            else ind;

        explicit = if hdr.digit != null
          then parentIndent + b.fromJSON hdr.digit
          else null;
        # The base is detected before the lines are collected, so that a
        # line that holds only white space can be told apart from a more
        # indented line.
        detected = detectBase st2;
        base = if explicit != null then explicit else (if detected == null then parentIndent + 1 else detected);
        collected = collect st2 base explicit false [];
      in
        if failed collected
          then collected
          else let
            rawLines = b.elemAt collected 0;
            st' = b.elemAt collected 1;

            # Split the collected lines into the content and the empty
            # lines that trail it.
            len = b.length rawLines;
            lastContent =
              let
                go = i:
                  if i < 0 then -1
                  else if (b.elemAt rawLines i) == "" then go (i - 1)
                  else i;
              in go (len - 1);
            contentLines = b.genList (i: b.elemAt rawLines i) (lastContent + 1);
            trailingBlanks = len - lastContent - 1;

            contentLines' = b.map (strip base) contentLines;
            # The body of the scalar, without the trailing line break
            # that chomping deals with.
            body =
              if style == "|"
                then foldLiteral contentLines'
                else foldFolded base contentLines;
            # Chomping determines the trailing line breaks:
            #
            #   strip (-)  -- remove all of them
            #   clip       -- keep exactly one (the default)
            #   keep (+)   -- keep them all, including trailing empty lines
            text =
              if hdr.chomp == "-"
                then stripTrailingBreaks body
                else if hdr.chomp == "+"
                then body + concat (b.genList (_: "\n") (trailingBlanks + (if body == "" then 0 else 1)))
                else (if body == "" then "" else addTrailingBreak body);
          in [ { type = "scalar"; text = text; quoted = true; } st' ];

  # Fold the lines of a multi-line plain scalar together. A single line
  # break becomes a space; a run of blank lines becomes that many line
  # feeds.
  foldPlain = lines:
    let
      len = b.length lines;
      go = i: acc:
        if i >= len then acc
        else if i == 0
          then go 1 (b.elemAt lines 0).text
          else
            let
              cur = b.elemAt lines i;
              sep =
                if cur.blanks == 0 then " "
                else concat (b.genList (_: "\n") cur.blanks);
            in go (i + 1) (acc + sep + cur.text);
    in go 0 "";

  # A literal (|) block scalar keeps every line break. The final line
  # break is left to the chomping indicator, so it is not added here.
  foldLiteral = lines:
    let
      len = b.length lines;
      go = i: acc:
        if i >= len then acc
        else if i == len - 1
          then acc + (b.elemAt lines i)
          else go (i + 1) (acc + (b.elemAt lines i) + "\n");
    in go 0 "";

  # Remove all trailing line breaks from a string.
  stripTrailingBreaks = text:
    let
      len = b.stringLength text;
      go = i:
        if i <= 0 then ""
        else if b.substring (i - 1) 1 text == "\n" then go (i - 1)
        else b.substring 0 i text;
    in go len;

  # Add a single trailing line break, unless there already is one.
  addTrailingBreak = text:
    if text == "" then text
    else if b.substring (b.stringLength text - 1) 1 text == "\n" then text
    else text + "\n";
  # A folded (>) block scalar.
  #
  # The lines are already stripped of the block's base indentation, so
  # any remaining leading whitespace marks a "more indented" line.
  #
  # The folding rules are:
  #
  #   - a line break between two ordinary lines becomes a space
  #   - N empty lines between two lines become N line feeds, and the
  #     line break that follows them becomes a line feed as well
  #   - the line breaks around a more indented line are kept verbatim
  #     as line feeds
  foldFolded = base: lines:
    let
      len = b.length lines;

      # The text of a line, with the base indentation removed.
      textOf = line: b.substring base (b.stringLength line - base) line;

      # Walk the lines, keeping track of the number of empty lines that
      # separate two content lines.
      go = i: acc: pending: prevMore: first:
        if i >= len then acc
        else let
          line = b.elemAt lines i;
        in
          if line == ""
          then go (i + 1) acc (pending + 1) prevMore first
          else
            let
              more = indentOf line > base;
              text = textOf line;
            in
              if first
              # The empty lines in front of the content become line feeds.
              then go (i + 1) (concat (b.genList (_: "\n") pending) + text) 0 more false
              else
                let
                  sep =
                    if prevMore || more
                    # The line break around a more indented line is kept
                    # as a line feed, and the empty lines are line feeds
                    # as well.
                    then concat (b.genList (_: "\n") (pending + 1))
                    else if pending == 0
                    then " "
                    else concat (b.genList (_: "\n") pending);
                in
                go (i + 1) (acc + sep + text) 0 more false;
    in go 0 "" 0 false true;

  # The characters of a string, as a list.
  stringChars = text:
    let
      len = b.stringLength text;
      go = i: acc:
        if i >= len then acc
        else go (i + 1) (acc ++ [ (b.substring i 1 text) ]);
    in go 0 [];

  # ------------------------------------------------------------------
  # Type resolution (YAML 1.2 core schema)
  # ------------------------------------------------------------------

  # Decimal string to integer.
  decToInt = text:
    let
      len = b.stringLength text;
      start = if b.substring 0 1 text == "-" || b.substring 0 1 text == "+" then 1 else 0;
      neg = b.substring 0 1 text == "-";
      go = i: acc:
        if i >= len then acc
        else go (i + 1) (acc * 10 + (b.fromJSON (b.substring i 1 text)));
      v = go start 0;
    in if neg then -v else v;

  hexToInt = text:
    let
      body = b.substring 2 (b.stringLength text - 2) text;
      len = b.stringLength body;
      go = i: acc:
        if i >= len then acc
        else go (i + 1) (acc * 16 + hexVal (b.substring i 1 body));
    in go 0 0;

  octToInt = text:
    let
      body = b.substring 2 (b.stringLength text - 2) text;
      len = b.stringLength body;
      go = i: acc:
        if i >= len then acc
        else go (i + 1) (acc * 8 + (b.fromJSON (b.substring i 1 body)));
    in go 0 0;

  # Float text to float, normalising to a JSON-compatible form first.
  toFloat = text:
    let
      neg = b.substring 0 1 text == "-";
      body =
        if b.substring 0 1 text == "-" || b.substring 0 1 text == "+"
        then b.substring 1 (b.stringLength text - 1) text
        else text;
      body' =
        if b.substring 0 1 body == "."
        then "0" + body
        else if b.match ".*\\.$" body != null
        then body + "0"
        else body;
      v = b.fromJSON body';
    in if neg then -v else v;

  # Resolve a plain scalar to a typed value.
  #   :: String -> a
  resolvePlain = text:
    if text == "" then null
    else if text == "~" then null
    else if text == "null" || text == "Null" || text == "NULL" then null
    else if text == "true" || text == "True" || text == "TRUE" then true
    else if text == "false" || text == "False" || text == "FALSE" then false
    else if b.match "0x[0-9a-fA-F]+" text != null then hexToInt text
    else if b.match "0o[0-7]+" text != null then octToInt text
    else if b.match "[-+]?[0-9]+" text != null then decToInt text
    else if b.match "[-+]?([0-9]+\\.[0-9]*|\\.[0-9]+)([eE][-+]?[0-9]+)?" text != null
      then toFloat text
    else text;

  # ------------------------------------------------------------------
  # Explicit type conversions, used by the "!!" tags
  # ------------------------------------------------------------------

  # Interpret the text as an integer.
  asInt = text:
    if b.match "[-+]?[0-9]+" text != null then decToInt text
    else if b.match "0x[0-9a-fA-F]+" text != null then hexToInt text
    else if b.match "0o[0-7]+" text != null then octToInt text
    else throw "yaml: '${text}' is not an integer";

  # Interpret the text as a float.
  asFloat = text:
    if b.match "[-+]?([0-9]+\\.[0-9]*|\\.[0-9]+)([eE][-+]?[0-9]+)?" text != null
      then toFloat text
    else if b.match "[-+]?[0-9]+" text != null
      then (decToInt text) + 0.0
      else throw "yaml: '${text}' is not a float";

  # Interpret the text as a boolean.
  asBool = text:
    if text == "true" || text == "True" || text == "TRUE" then true
    else if text == "false" || text == "False" || text == "FALSE" then false
    else throw "yaml: '${text}' is not a boolean";

  # Interpret the text as binary data (base64).
  asBinary = text:
    let
      alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

      # The numeric value of a base64 character.
      valueOf = c:
        let
          find = i:
            if i >= b.stringLength alphabet then null
            else if b.substring i 1 alphabet == c then i
            else find (i + 1);
        in find 0;

      # The remainder of a division, for non-negative integers.
      mod = x: y: x - y * b.div x y;

      # A single byte, as a string. A null byte cannot be represented
      # in a Nix string, so it is dropped.
      byte = n:
        if n == 0 then ""
        else b.fromJSON ("\"" + fromCodePoint n + "\"");

      # Decode four base64 characters into up to three bytes.
      decode4 = c0: c1: c2: c3:
        let
          v = c:
            if c == "=" then 0
            else let
              found = valueOf c;
            in if found == null
              then throw "yaml: invalid base64 character '${c}'"
              else found;
          bits = v c0 * 262144 + v c1 * 4096 + v c2 * 64 + v c3;
          b0 = mod (b.div bits 65536) 256;
          b1 = mod (b.div bits 256) 256;
          b2 = mod bits 256;
        in
          if c1 == "=" then [ (byte b0) ]
          else if c2 == "=" then [ (byte b0) (byte b1) ]
          else [ (byte b0) (byte b1) (byte b2) ];

      chars = stringChars text;
      len = b.length chars;
      step = i:
        if i + 4 > len then []
        else decode4
          (b.elemAt chars i)
          (b.elemAt chars (i + 1))
          (b.elemAt chars (i + 2))
          (b.elemAt chars (i + 3))
          ++ step (i + 4);
    in b.concatStringsSep "" (step 0);
}
