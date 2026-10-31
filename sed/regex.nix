# The regular expression engine of the sed module.
#
# It understands the two dialects that sed scripts are written in:
#
#   - the basic regular expressions of POSIX, with the extensions that
#     GNU sed adds to them (`\+`, `\?`, `\|`, `\{n,m\}`, `\w`, `\b`,
#     `\<`, `\>`, `` \` ``, `\'` and the back references)
#   - the extended regular expressions of POSIX, which is the dialect
#     that the `-r` option of sed selects
#
# The engine is written from scratch and does not use `builtins.match`:
# the regular expressions of Nix are the plain ones of POSIX, they have
# to match the whole text, they know none of the extensions of GNU sed,
# and they have no flags.
#
# A pattern is parsed into a small tree and the tree is compiled into a
# flat list of instructions. The instructions are run by a backtracking
# virtual machine whose backtrack stack is explicit, so that the depth
# of the Nix stack does not depend on the length of the text.
#
# The machine looks for the leftmost match that is also the longest one,
# the way POSIX says, and it picks the longest of the groups when two
# matches are the same length, the way POSIX says as well.

let
  b = builtins;

  # ------------------------------------------------------------------
  # Characters
  # ------------------------------------------------------------------

  # The letters, and where they are in the ASCII order.
  alphaUpper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
  alphaLower = "abcdefghijklmnopqrstuvwxyz";
  upperList = b.genList (i: b.substring i 1 alphaUpper) 26;
  lowerList = b.genList (i: b.substring i 1 alphaLower) 26;
  upperIndex = b.listToAttrs (b.genList (i: {
    name = b.elemAt upperList i;
    value = i;
  }) 26);
  lowerIndex = b.listToAttrs (b.genList (i: {
    name = b.elemAt lowerList i;
    value = i;
  }) 26);

  isDigit = c: c >= "0" && c <= "9";
  isAlpha = c: (c >= "a" && c <= "z") || (c >= "A" && c <= "Z");
  isWord = c: isAlpha c || isDigit c || c == "_";

  # The character of a code point, and the code point of a character.
  #
  # Nix has no builtins for either, so they are made here. The code
  # point zero is left out, since a Nix string cannot hold it.
  hexDigits = [ "0" "1" "2" "3" "4" "5" "6" "7" "8" "9" "a" "b" "c" "d" "e" "f" ];
  hex2 = n:
    (b.elemAt hexDigits (n / 16)) + (b.elemAt hexDigits (n - (n / 16) * 16));
  chr = n: b.fromJSON ("\"\\u00" + hex2 n + "\"");

  asciiChars = b.genList (i: chr (i + 1)) 127;
  asciiIndex = b.listToAttrs (b.genList (i: {
    name = b.elemAt asciiChars i;
    value = i + 1;
  }) 127);
  ord = c: if b.hasAttr c asciiIndex then asciiIndex.${c} else 63;

  # The other case of a character, and of a text.
  lowerChar = c: if b.hasAttr c upperIndex then b.elemAt lowerList upperIndex.${c} else c;
  upperChar = c: if b.hasAttr c lowerIndex then b.elemAt upperList lowerIndex.${c} else c;
  lowerText = t: b.replaceStrings upperList lowerList t;

  # ------------------------------------------------------------------
  # Character classes
  # ------------------------------------------------------------------

  # A range of characters, from one to the other. A range of one
  # character is that character.
  range = from: to: { inherit from to; };
  chars = text: b.map (c: { from = c; to = c; }) (b.genList (i: b.substring i 1 text) (b.stringLength text));

  # The vertical tab and the form feed. Nix has no escape for them,
  # so they are made from their number.
  vtab = b.fromJSON "\"\\u000b\"";
  formfeed = b.fromJSON "\"\\u000c\"";

  # The classes that POSIX names. They are made of ranges, so that the
  # compiler only has to know about ranges.
  posixClasses = {
    alpha = [ (range "a" "z") (range "A" "Z") ];
    digit = [ (range "0" "9") ];
    alnum = [ (range "a" "z") (range "A" "Z") (range "0" "9") ];
    upper = [ (range "A" "Z") ];
    lower = [ (range "a" "z") ];
    space = chars " \t\n\r" ++ [ { from = vtab; to = vtab; } { from = formfeed; to = formfeed; } ];
    blank = chars " \t";
    punct = [ (range "!" "/") (range ":" "@") (range "[" "`") (range "{" "~") ];
    print = [ (range " " "~") ];
    graph = [ (range "!" "~") ];
    cntrl = [ (range (chr 1) (chr 31)) (range (chr 127) (chr 127)) ];
    xdigit = [ (range "0" "9") (range "a" "f") (range "A" "F") ];
  };

  # The characters of a range, one by one.
  charsOfRange = r:
    let
      from = ord r.from;
      to = ord r.to;
      n = if to >= from then to - from + 1 else 0;
    in
      b.genList (i: chr (from + i)) n;

  # The characters that are not in a set of ranges.
  outsideOf = ranges:
    let
      inside = b.foldl' (acc: r: acc ++ (charsOfRange r)) [] ranges;
    in
      b.filter (c: !(b.elem c inside)) asciiChars;

  # ------------------------------------------------------------------
  # The parser of a pattern
  # ------------------------------------------------------------------
  #
  # The pattern is parsed into a tree of these nodes:
  #
  #   { t = "seq";  items; }      -- a sequence of things
  #   { t = "alt";  branches; }   -- an alternation
  #   { t = "rep";  body; min; max; }
  #   { t = "group"; index; body; }
  #   { t = "char"; c; }
  #   { t = "any"; }
  #   { t = "class"; negated; items; }   -- items are ranges
  #   { t = "bol"; } { t = "eol"; }
  #   { t = "bow"; } { t = "eow"; }
  #   { t = "bword"; } { t = "nobound"; }
  #   { t = "bufStart"; } { t = "bufEnd"; }
  #   { t = "backref"; index; }
  #
  # The state of the parser holds the pattern, the place it is at, the
  # dialect, the number of the groups that were opened and whether a
  # `^` at this place is an anchor (it is only an anchor at the start of
  # a branch, or right after a `(` or a `|`).

  ok = value: next: { ok = true; inherit value next; };
  bad = msg: offset: { ok = false; inherit msg offset; };

  lit = c: { t = "char"; inherit c; };

  # Is the `$` at this place an anchor?
  #
  # It is when it is at the end of the branch, which is decided by
  # looking at the character that follows it.
  eolAt = st:
    let
      len = b.stringLength st.s;
      j = st.i + 1;
      c = if j < len then b.substring j 1 st.s else "";
      ere = st.flavor == "ere";
    in
      if j >= len then true
      else if ere && (c == ")" || c == "|") then true
      else if !ere && (b.substring j 2 st.s == "\\|" || b.substring j 2 st.s == "\\)") then true
      else false;

  # The element at a place of a list, with another one in its place.
  setAt = i: v: list:
    b.genList (j: if j == i then v else b.elemAt list j) (b.length list);

  # Give the groups their numbers.
  #
  # The groups are numbered in the order in which they open, and that
  # is the order in which they are in the tree: a group comes before
  # the groups that are in it.
  numberGroups = ast: counter:
    if ast.t == "seq" then
      let
        go = items: i: c:
          if i >= b.length items then { ast = { t = "seq"; inherit items; }; count = c; }
          else
            let
              r = numberGroups (b.elemAt items i) c;
            in
              go (setAt i r.ast items) (i + 1) r.count;
      in
        go ast.items 0 counter
    else if ast.t == "alt" then
      let
        go = branches: i: c:
          if i >= b.length branches then { ast = { t = "alt"; inherit branches; }; count = c; }
          else
            let
              r = numberGroups (b.elemAt branches i) c;
            in
              go (setAt i r.ast branches) (i + 1) r.count;
      in
        go ast.branches 0 counter
    else if ast.t == "rep" then
      let
        r = numberGroups ast.body counter;
      in
        { ast = ast // { body = r.ast; }; count = r.count; }
    else if ast.t == "group" then
      let
        index = counter + 1;
        r = numberGroups ast.body index;
      in
        { ast = ast // { inherit index; body = r.ast; }; count = r.count; }
    else { ast = ast; count = counter; };

  # The back references of a tree.
  backrefs = ast:
    if ast.t == "seq" then b.concatLists (b.map backrefs ast.items)
    else if ast.t == "alt" then b.concatLists (b.map backrefs ast.branches)
    else if ast.t == "rep" then backrefs ast.body
    else if ast.t == "group" then backrefs ast.body
    else if ast.t == "backref" then [ ast.index ]
    else [];

  # The whole pattern.
  parsePattern = flavor: s:
    let
      st = { inherit s flavor; i = 0; groups = 0; depth = 0; bolOk = true; };
      res = parseAlt st;
    in
      if !res.ok then res
      else if res.next != b.stringLength s then bad "unexpected character in pattern" res.next
      else
        let
          numbered = numberGroups res.value 0;
          unknown = b.filter (i: i > numbered.count) (backrefs numbered.ast);
        in
          if unknown != [] then bad "invalid back reference" 0
          else ok numbered.ast res.next;

  # An alternation: branches that are separated by `|` (in the extended
  # dialect) or by `\|` (in the basic one).
  parseAlt = st:
    let
      first = parseConcat st;
      sepLen = if st.flavor == "ere" then 1 else 2;
      sep = if st.flavor == "ere" then "|" else "\\|";
      go = branches: next:
        if b.substring next sepLen st.s != sep
        then ok { t = "alt"; inherit branches; } next
        else
          let
            rest = parseConcat (st // { i = next + sepLen; bolOk = true; });
          in
            if !rest.ok then rest
            else go (branches ++ [ rest.value ]) rest.next;
    in
      if !first.ok then first
      else go [ first.value ] first.next;

  # A sequence of things, up to the end of the branch.
  parseConcat = st:
    let
      go = items: i: bolOk:
        let
          r = parseRepeat (st // { inherit i bolOk; });
        in
          if !r.ok then r
          else if r.value == null then ok { t = "seq"; inherit items; } i
          else go (items ++ [ r.value ]) r.next false;
    in
      go [] st.i st.bolOk;

  # A thing, and the number of times it may be repeated.
  parseRepeat = st:
    let
      atom = parseAtom st;
    in
      if !atom.ok then atom
      else if atom.value == null then ok null st.i
      else
        let
          q = parseQuantifier (st // { i = atom.next; });
        in
          if !q.ok then q
          else if q.value == null then ok atom.value atom.next
          else ok {
            t = "rep";
            body = atom.value;
            min = q.value.min;
            max = q.value.max;
          } q.next;

  # The number of times a thing may be repeated.
  parseQuantifier = st:
    let
      len = b.stringLength st.s;
      ere = st.flavor == "ere";
      c = if st.i < len then b.substring st.i 1 st.s else "";
      take2 = b.substring st.i 2 st.s;
    in
      if c == "*" then ok { min = 0; max = null; } (st.i + 1)
      else if ere && c == "+" then ok { min = 1; max = null; } (st.i + 1)
      else if !ere && take2 == "\\+" then ok { min = 1; max = null; } (st.i + 2)
      else if ere && c == "?" then ok { min = 0; max = 1; } (st.i + 1)
      else if !ere && take2 == "\\?" then ok { min = 0; max = 1; } (st.i + 2)
      else if (ere && c == "{") || (!ere && take2 == "\\{") then parseInterval st
      else ok null st.i;

  # An interval, such as `\{2,3\}` in the basic dialect and `{2,3}` in
  # the extended one.
  #
  # Something that only looks like an interval is not one, and is then
  # an ordinary character.
  parseInterval = st:
    let
      len = b.stringLength st.s;
      ere = st.flavor == "ere";
      openLen = if ere then 1 else 2;
      closeLen = if ere then 1 else 2;
      start = st.i + openLen;
      scanDigits = j: if j < len && isDigit (b.substring j 1 st.s) then scanDigits (j + 1) else j;
      minEnd = scanDigits start;
      minText = b.substring start (minEnd - start) st.s;
      hasComma = minEnd < len && b.substring minEnd 1 st.s == ",";
      maxStart = if hasComma then minEnd + 1 else minEnd;
      maxEnd = scanDigits maxStart;
      maxText = b.substring maxStart (maxEnd - maxStart) st.s;
      close = if ere then "}" else "\\}";
    in
      if minText == "" then ok null st.i
      else if b.substring maxEnd closeLen st.s != close then ok null st.i
      else if hasComma && maxText == "" then ok { min = b.fromJSON minText; max = null; } (maxEnd + closeLen)
      else if hasComma then ok { min = b.fromJSON minText; max = b.fromJSON maxText; } (maxEnd + closeLen)
      else ok { min = b.fromJSON minText; max = b.fromJSON minText; } (maxEnd + closeLen);

  # One thing.
  parseAtom = st:
    let
      len = b.stringLength st.s;
      ere = st.flavor == "ere";
      c = if st.i < len then b.substring st.i 1 st.s else "";
    in
      if st.i >= len then ok null st.i
      else if c == "\\" then parseEscape st
      else if c == "[" then parseBracket st
      else if c == "." then ok { t = "any"; } (st.i + 1)
      else if c == "(" then if ere then parseGroup st else ok (lit c) (st.i + 1)
      else if c == ")" then if ere then ok null st.i else ok (lit c) (st.i + 1)
      else if c == "|" then if ere then ok null st.i else ok (lit c) (st.i + 1)
      else if c == "^" then if st.bolOk then ok { t = "bol"; } (st.i + 1) else ok (lit c) (st.i + 1)
      else if c == "$" then if eolAt st then ok { t = "eol"; } (st.i + 1) else ok (lit c) (st.i + 1)
      else if c == "*" then ok (lit c) (st.i + 1)
      else if c == "+" then if ere then ok null st.i else ok (lit c) (st.i + 1)
      else if c == "?" then if ere then ok null st.i else ok (lit c) (st.i + 1)
      else if c == "{" then if ere then parseIntervalOrChar st else ok (lit c) (st.i + 1)
      else if c == "}" then ok (lit c) (st.i + 1)
      else ok (lit c) (st.i + 1);

  # The `{` of the extended dialect: an interval when it is one, and an
  # ordinary character otherwise.
  parseIntervalOrChar = st:
    let
      r = parseInterval st;
    in
      if !r.ok then r
      else if r.value == null then ok (lit "{") (st.i + 1)
      else r;

  # A group: `\(...\)` in the basic dialect, `(...)` in the extended one.
  parseGroup = st:
    let
      ere = st.flavor == "ere";
      openLen = if ere then 1 else 2;
      closeLen = if ere then 1 else 2;
      close = if ere then ")" else "\\)";
      index = st.groups + 1;
      body = parseAlt (st // { i = st.i + openLen; groups = index; depth = st.depth + 1; bolOk = true; });
    in
      if !body.ok then body
      else if b.substring body.next closeLen st.s != close then bad "unmatched (" st.i
      else ok { t = "group"; inherit index; body = body.value; } (body.next + closeLen);

  # An escape.
  parseEscape = st:
    let
      len = b.stringLength st.s;
      ere = st.flavor == "ere";
      j = st.i + 1;
      c = if j < len then b.substring j 1 st.s else "";
      word = [ (range "a" "z") (range "A" "Z") (range "0" "9") (range "_" "_") ];
      space = posixClasses.space;
    in
      if j >= len then bad "trailing backslash" st.i
      else if c == "(" then if ere then bad "invalid group" st.i else parseGroup st
      else if c == ")" then
        if ere then bad "unmatched )" st.i
        # In the basic dialect the group ends at `\)`, and that ends
        # the branch that is in it.
        else if st.depth > 0 then ok null st.i
        else ok (lit ")") (j + 1)      else if c == "|" then if ere then bad "invalid alternation" st.i else ok null st.i
      else if c == "w" then ok { t = "class"; negated = false; items = word; } (j + 1)
      else if c == "W" then ok { t = "class"; negated = true; items = word; } (j + 1)
      else if c == "s" then ok { t = "class"; negated = false; items = space; } (j + 1)
      else if c == "S" then ok { t = "class"; negated = true; items = space; } (j + 1)
      else if c == "b" then ok { t = "bword"; } (j + 1)
      else if c == "B" then ok { t = "nobound"; } (j + 1)
      else if c == "<" then ok { t = "bow"; } (j + 1)
      else if c == ">" then ok { t = "eow"; } (j + 1)
      else if c == "`" then ok { t = "bufStart"; } (j + 1)
      else if c == "'" then ok { t = "bufEnd"; } (j + 1)
      else if c == "n" then ok (lit "\n") (j + 1)
      else if c == "t" then ok (lit "\t") (j + 1)
      else if c == "r" then ok (lit "\r") (j + 1)
      else if c == "c" then
        if j + 1 >= len then bad "trailing backslash" st.i
        else ok (lit (chr (ord (b.substring (j + 1) 1 st.s)) - 64)) (j + 2)
      else if isDigit c && c != "0" then
        let
          index = b.fromJSON c;
        in
          ok { t = "backref"; inherit index; } (j + 1)
      else ok (lit c) (j + 1);

  # A bracket expression: `[...]`.
  #
  # The `^` right after the `[` makes the class the other way around, a
  # `]` right after it is an ordinary character, and a backslash is an
  # ordinary character as well, the way POSIX says.
  parseBracket = st:
    let
      len = b.stringLength st.s;
      j = st.i + 1;
      negated = j < len && b.substring j 1 st.s == "^";
      start = if negated then j + 1 else j;
      # A `]` right after the `[` is an ordinary character, and the
      # class goes on after it.
      firstIsClose = start < len && b.substring start 1 st.s == "]";
      itemStart = start;

      # One item of the class: a character, a range or a named class.
      #
      # The result holds the items of the class and the place after
      # them, since a named class is made of more than one item.
      item = i:
        let
          c = b.substring i 1 st.s;
          named = b.substring i 2 st.s == "[:";
          namedEnd =
            let
              go = k: if k >= len then null
                     else if b.substring k 2 st.s == ":]" then k
                     else go (k + 1);
            in go (i + 2);
        in
          if named && namedEnd != null then
            let
              name = b.substring (i + 2) (namedEnd - i - 2) st.s;
              negatedName = b.substring 0 1 name == "^";
              realName = if negatedName then b.substring 1 (b.stringLength name - 1) name else name;
            in
              if !(b.hasAttr realName posixClasses) then bad "unknown character class" i
              else if negatedName
              then {
                ok = true;
                items = [ { outside = posixClasses.${realName}; } ];
                next = namedEnd + 2;
              }
              else {
                ok = true;
                items = posixClasses.${realName};
                next = namedEnd + 2;
              }
          else
            let
              hasRange = i + 2 < len
                && b.substring (i + 1) 1 st.s == "-"
                && b.substring (i + 2) 1 st.s != "]";
            in
              if hasRange
              then {
                ok = true;
                items = [ { from = c; to = b.substring (i + 2) 1 st.s; } ];
                next = i + 3;
              }
              else { ok = true; items = [ { from = c; to = c; } ]; next = i + 1; };

      loop = items: i: first:
        if i >= len then bad "unterminated character class" st.i
        else
          let
            c = b.substring i 1 st.s;
          in
            if c == "]" && ! first then
              ok { t = "class"; inherit negated items; } (i + 1)
            else
              let
                r = item i;
              in
                if !r.ok then r
                else loop (items ++ r.items) r.next false;
    in
      loop [] itemStart firstIsClose;

  # ------------------------------------------------------------------
  # The compiler
  # ------------------------------------------------------------------
  #
  # The tree is compiled into a flat list of instructions:
  #
  #   0  char     { c; }           -- the character c
  #   1  any                       -- any character but a line break
  #   2  class    { negated; table; }
  #   3  split    { first; second; }
  #   4  jmp      { target; }
  #   5  save     { slot; }        -- the start of a group
  #   6  saveEnd  { slot; }        -- the end of a group
  #   7  match
  #   8  bol                      -- the start of the text
  #   9  eol                      -- the end of the text
  #   10 bow                      -- the start of a word
  #   11 eow                      -- the end of a word
  #   12 nobound                  -- not the border of a word
  #   13 bword                    -- the border of a word
  #   14 backref  { index; }
  #   15 bufStart
  #   16 bufEnd

  opChar = 0;
  opAny = 1;
  opClass = 2;
  opSplit = 3;
  opJmp = 4;
  opSave = 5;
  opSaveEnd = 6;
  opMatch = 7;
  opBol = 8;
  opEol = 9;
  opBow = 10;
  opEow = 11;
  opNobound = 12;
  opBword = 13;
  opBackref = 14;
  opBufStart = 15;
  opBufEnd = 16;
  opFail = 17;

  # The number of instructions that a node takes.
  sizeOf = ast:
    if ast.t == "seq" then b.foldl' (a: x: a + sizeOf x) 0 ast.items
    else if ast.t == "alt" then
      let
        n = b.length ast.branches;
      in
        if n == 1 then sizeOf (b.elemAt ast.branches 0)
        else 2 * n + b.foldl' (a: x: a + sizeOf x) 0 ast.branches
    else if ast.t == "rep" then sizeOfRep ast
    else if ast.t == "group" then 2 + sizeOf ast.body
    else 1;

  sizeOfRep = ast:
    let
      body = sizeOf ast.body;
      min = ast.min;
      max = ast.max;
    in
      if min == 0 && max == null then 2 + body
      else if min == 0 && max == 1 then 1 + body
      else if min == 1 && max == null then 1 + body
      else if max == null then min * body + 1 + body
      else min * body + (max - min) * (1 + body);

  # The table of a class: the characters that are in it are the keys.
  #
  # A class that is the other way around holds the characters that are
  # not in it, and the machine turns the test around.
  #
  # The letters are both cases when the match does not care about the
  # case, since the text that is matched is in lower case then.
  classTable = icase: items:
    b.listToAttrs (
      b.foldl' (acc: it:
        let
          cs =
            if b.hasAttr "outside" it
            then outsideOf it.outside
            else charsOfRange it;
          all = if icase then cs ++ (b.map lowerChar cs) ++ (b.map upperChar cs) else cs;
        in
          acc ++ (b.map (c: { name = c; value = true; }) all)
      ) [] items
    );

  # The compiler.
  #
  # The instructions are collected at the front of a list, since a list
  # is cheapest to grow there. The count in the accumulator is the
  # number of instructions that were emitted, and it is the place that
  # the next instruction will have.
  emit = icase: ast: acc:
    let
      put = instr: a: a // { rev = [ instr ] ++ a.rev; count = a.count + 1; };
      # The place that this node starts at.
      base = acc.count;
    in
      if ast.t == "seq" then
        let
          go = items: i: a:
            if i >= b.length items then a
            else go items (i + 1) (emit icase (b.elemAt items i) a);
        in
          go ast.items 0 acc
    else if ast.t == "alt" then
      let
        n = b.length ast.branches;
        sizes = b.map sizeOf ast.branches;
        # The place of every branch, and the place of the end.
        #
        # A branch that is not the last one is followed by a jump to
        # the end, so that the next branch is only tried when the
        # branch does not match. The branches come after the place
        # where a branch that does not match gives up, so that the last
        # branch falls through to the end.
        contrib = j: (b.elemAt sizes j) + (if j < n - 1 then 1 else 0);
        bases = b.genList (k:
          base + n + 1 + b.foldl' (a: j: a + contrib j) 0 (b.genList (j: j) k)
        ) n;
        endIdx = base + n + 1 + b.foldl' (a: j: a + contrib j) 0 (b.genList (j: j) n);
        # The splits: the first branch is tried first, and the second
        # is the branch that comes after it. The last one gives up.
        splits = b.genList (k: {
          op = opSplit;
          first = b.elemAt bases k;
          second = if k < n - 1 then base + k + 1 else base + n;
        }) n;
        goBranches = k: a:
          if k >= n then a
          else
            let
              a1 = emit icase (b.elemAt ast.branches k) a;
              a2 = if k < n - 1 then put { op = opJmp; target = endIdx; } a1 else a1;
            in
              goBranches (k + 1) a2;
      in
        if n == 1 then
          # An alternation of one branch is that branch.
          emit icase (b.elemAt ast.branches 0) acc
        else
          # The splits, then the place where the alternation gives up,
          # and then the branches.
          goBranches 0
            (put { op = opFail; } (b.foldl' (a: s: put s a) acc splits))
      else if ast.t == "rep" then
        let
          body = ast.body;
          bodySize = sizeOf body;
          min = ast.min;
          max = ast.max;
          # One copy of the body.
          once = a: emit icase body a;
          # The body, as many times as it has to be.
          mandatory = k: a: if k <= 0 then a else mandatory (k - 1) (once a);
          # A copy of the body that may be left out.
          optional = a:
            let
              splitIdx = a.count;
              bodyIdx = splitIdx + 1;
              endIdx = bodyIdx + bodySize;
            in
              once (put { op = opSplit; first = bodyIdx; second = endIdx; } a);
        in
          if min == 0 && max == null then
            # x*: the body again and again, or stop.
            let
              loopIdx = acc.count;
              bodyIdx = loopIdx + 1;
              # The end is after the jump back to the loop.
              endIdx = bodyIdx + bodySize + 1;
              a1 = emit icase body (put { op = opSplit; first = bodyIdx; second = endIdx; } acc);
            in
              put { op = opJmp; target = loopIdx; } a1
          else if min == 0 && max == 1 then
            # x?: the body, or nothing.
            let
              splitIdx = acc.count;
              bodyIdx = splitIdx + 1;
              endIdx = bodyIdx + bodySize;
            in
              once (put { op = opSplit; first = bodyIdx; second = endIdx; } acc)
          else if min == 1 && max == null then
            # x+: the body, and then the body again and again.
            let
              bodyIdx = acc.count;
              a1 = emit icase body acc;
              a2 = put { op = opSplit; first = bodyIdx; second = a1.count + 1; } a1;
            in
              a2
          else if max == null then
            # x{n,}: the body n times, and then again and again.
            let
              a1 = mandatory min acc;
              bodyIdx = a1.count;
              a2 = emit icase body a1;
              a3 = put { op = opSplit; first = bodyIdx; second = a2.count + 1; } a2;
            in
              a3
          else
            # x{n,m}: the body n times, and then up to m-n times more.
            let
              a1 = mandatory min acc;
              optionals = k: a: if k <= 0 then a else optionals (k - 1) (optional a);
            in
              optionals (max - min) a1
      else if ast.t == "group" then
        let
          a1 = put { op = opSave; slot = ast.index; } acc;
          a2 = emit icase ast.body a1;
          a3 = put { op = opSaveEnd; slot = ast.index; } a2;
        in
          a3
      else if ast.t == "char" then
        put { op = opChar; c = if icase then lowerChar ast.c else ast.c; } acc
      else if ast.t == "any" then put { op = opAny; } acc
      else if ast.t == "class" then
        put {
          op = opClass;
          negated = ast.negated;
          table = classTable icase ast.items;
        } acc
      else if ast.t == "bol" then put { op = opBol; } acc
      else if ast.t == "eol" then put { op = opEol; } acc
      else if ast.t == "bow" then put { op = opBow; } acc
      else if ast.t == "eow" then put { op = opEow; } acc
      else if ast.t == "bword" then put { op = opBword; } acc
      else if ast.t == "nobound" then put { op = opNobound; } acc
      else if ast.t == "bufStart" then put { op = opBufStart; } acc
      else if ast.t == "bufEnd" then put { op = opBufEnd; } acc
      else if ast.t == "backref" then put { op = opBackref; index = ast.index; } acc
      else throw "sed.regex: unknown node '${ast.t}'";

  # ------------------------------------------------------------------
  # The machine
  # ------------------------------------------------------------------

  emptySlots = [ null null null null null null null null null null ];

  # The element at a place of a list, with another one in its place.
  replaceAt = i: v: list:
    b.genList (j: if j == i then v else b.elemAt list j) (b.length list);

  # Is one match better than another one?
  #
  # A match that is longer is better. When two matches are the same
  # length, the one whose first group is the longer is the better one,
  # and when that group is the same length too, the next group decides.
  # This is the rule of POSIX.
  better = c1: c2:
    if c2 == null then true
    else if c1.end != c2.end then c1.end > c2.end
    else compareGroups c1.slots c2.slots > 0;

  compareGroups = s1: s2:
    let
      go = i:
        if i >= 10 then 0
        else
          let
            g1 = b.elemAt s1 i;
            g2 = b.elemAt s2 i;
            l1 = if g1 == null then -1 else g1.end - g1.start;
            l2 = if g2 == null then -1 else g2.end - g2.start;
          in
            if l1 != l2 then (if l1 > l2 then 1 else -1) else go (i + 1);
    in
      go 1;

  # One step of the machine.
  #
  # The state of the machine is
  #
  #   { pc; sp; slots; stack; best; done; result; }
  #
  # `pc` is the place of the instruction, `sp` the place in the text,
  # `slots` the groups that were matched, `stack` the places that are
  # still to be tried and `best` the longest match that was found.
  vmStep = program: subject: mode: mstart: st:
    let
      len = b.stringLength subject;
      instr = if st.pc >= program.count then null else program.byIndex.${toString st.pc};
      at = sp: b.substring sp 1 subject;
      # The instruction after the current one.
      cont = s: s // { pc = s.pc + 1; };
      # Take the next place that is to be tried, and give up when there
      # is none.
      back = s:
        if s.stack == [] then
          s // {
            done = true;
            result = s.best;
          }
        else
          let
            frame = b.head s.stack;
            rest = b.tail s.stack;
          in
            # A place that is further along than the longest match that
            # was found cannot make a longer one, so it is left out.
            if frame.sp > (if s.best == null then len else s.best.end)
            then back (s // { stack = rest; })
            else (frame // { stack = rest; best = s.best; done = false; result = null; });
      op = if instr == null then -1 else instr.op;
    in
      if op == opChar then
        if st.sp < len && at st.sp == instr.c then cont (st // { sp = st.sp + 1; }) else back st
      else if op == opAny then
        if st.sp < len && at st.sp != "\n" then cont (st // { sp = st.sp + 1; }) else back st
      else if op == opClass then
        if st.sp < len && (b.hasAttr (at st.sp) instr.table) != instr.negated
        then cont (st // { sp = st.sp + 1; })
        else back st
      else if op == opSplit then
        let
          frame = { pc = instr.second; sp = st.sp; slots = st.slots; };
        in
          st // { pc = instr.first; stack = [ frame ] ++ st.stack; }
      else if op == opJmp then
        st // { pc = instr.target; }
      else if op == opSave then
        cont (st // { slots = replaceAt instr.slot { start = st.sp; end = null; } st.slots; })
      else if op == opSaveEnd then
        let
          slot = instr.slot;
          old = b.elemAt st.slots slot;
        in
          cont (st // { slots = replaceAt slot { start = old.start; end = st.sp; } st.slots; })
      else if op == opMatch then
        let
          candidate = {
            start = mstart;
            end = st.sp;
            slots = replaceAt 0 { start = mstart; end = st.sp; } st.slots;
          };
        in
          if mode == "first" then
            st // { done = true; result = candidate; }
          else
            let
              s = if better candidate st.best then st // { best = candidate; } else st;
            in
              # The match is the last instruction, so the machine goes
              # on with the places that are still to be tried, to see
              # whether there is a longer one.
              back s
      else if op == opBol then
        if st.sp == 0 || (program.multiline && at (st.sp - 1) == "\n")
        then cont st
        else back st
      else if op == opEol then
        if st.sp == len || (program.multiline && at st.sp == "\n")
        then cont st
        else back st
      else if op == opBow then
        if st.sp == 0 || !(isWord (at (st.sp - 1)))
        then cont st
        else back st
      else if op == opEow then
        if st.sp == len || !(isWord (at st.sp))
        then cont st
        else back st
      else if op == opBword then
        let
          before = st.sp > 0 && isWord (at (st.sp - 1));
          after = st.sp < len && isWord (at st.sp);
        in
          if before != after then cont st else back st
      else if op == opNobound then
        let
          before = st.sp > 0 && isWord (at (st.sp - 1));
          after = st.sp < len && isWord (at st.sp);
        in
          if before == after then cont st else back st
      else if op == opBackref then
        let
          slot = b.elemAt st.slots instr.index;
        in
          if slot == null then cont st
          else
            let
              text = b.substring slot.start (slot.end - slot.start) subject;
              size = b.stringLength text;
            in
              if st.sp + size <= len && b.substring st.sp size subject == text
              then cont (st // { sp = st.sp + size; })
              else back st
      else if op == opBufStart then
        if st.sp == 0 then cont st else back st
      else if op == opBufEnd then
        if st.sp == len then cont st else back st
      else if op == opFail then
        # The place where an alternation gives up: the machine goes on
        # with the places that are still to be tried.
        back st
      else back st;

  # Run the machine from a place in the text.
  #
  # In the `first` mode it stops at the first match it finds, in the
  # `longest` mode it looks for the longest one and keeps it.
  runVm = program: subject: start: mode:
    let
      init = {
        key = 0;
        pc = 0;
        sp = start;
        slots = emptySlots;
        stack = [];
        best = null;
        done = false;
        result = null;
      };
      work = b.genericClosure {
        startSet = [ init ];
        operator = s:
          if s.done then []
          # The key is what orders the places that are visited, so it
          # has to grow with every step.
          else [ ((vmStep program subject mode start s) // { key = s.key + 1; }) ];
      };
      last = b.foldl' (a: s: s) init work;
    in
      if last.done then last.result else null;

  # The pattern of `builtins.split` that finds a character.
  #
  # A character that means something to the regular expressions of Nix
  # is put in a bracket expression, where it means nothing. The
  # character is put in a group, because `builtins.split` gives the
  # groups of a match back, and not the match itself.
  regexSpecial = c:
    c == "\\" || c == "." || c == "[" || c == "]" || c == "(" || c == ")"
    || c == "{" || c == "}" || c == "*" || c == "+" || c == "?" || c == "|"
    || c == "^" || c == "$";
  splitPattern = c:
    "(" + (if regexSpecial c then "[" + c + "]" else c) + ")";

  # The places where a match may start.
  #
  # When the pattern starts with a character, the match has to start
  # with that character, so the other places are not even looked at.
  startPlaces = program: subject: from:
    let
      len = b.stringLength subject;
      prefix = program.prefix;
    in
      if prefix == null then
        b.genList (i: i + from) (len + 1 - from)
      else
        let
          parts = b.split (splitPattern prefix) subject;
          found = b.foldl' (acc: part:
            if b.isString part
            then acc // { offset = acc.offset + b.stringLength part; }
            else acc // {
              offset = acc.offset + b.stringLength (b.concatStringsSep "" part);
              places = if acc.offset >= from then acc.places ++ [ acc.offset ] else acc.places;
            }
          ) { offset = 0; places = []; } parts;
        in
          found.places;

  # ------------------------------------------------------------------
  # The public interface
  # ------------------------------------------------------------------

  # Compile a pattern.
  #
  # The result is either
  #
  #   { type = "success"; value = <the program>; }
  #   { type = "error";   value = { msg; offset; }; }
  #
  # The dialect of the pattern is the basic one of POSIX, with the
  # extensions of GNU sed, unless `extended_regex` is there, which
  # makes it the extended one.
  compile = { pattern, extended_regex ? false, icase ? false, multiline ? false }:
    let
      flavor = if extended_regex then "ere" else "bre";
      parsed = parsePattern flavor pattern;
    in
      if !parsed.ok
      then { type = "error"; value = { msg = parsed.msg; offset = parsed.offset; }; }
      else
        let
          emitted = emit icase parsed.value { rev = []; count = 0; };
          # The instructions, in the order they are run, and the
          # instruction that ends the program.
          code = (b.foldl' (acc: i: [ i ] ++ acc) [] emitted.rev) ++ [ { op = opMatch; } ];
          byIndex = b.listToAttrs (b.genList (i: {
            name = toString i;
            value = b.elemAt code i;
          }) (b.length code));
        in
          {
            type = "success";
            value = {
              count = b.length code;
              inherit byIndex;
              inherit icase multiline;
              # The character that a match has to start with, when the
              # pattern says so.
              prefix =
                if emitted.count > 0 && (b.elemAt code 0).op == opChar
                then (b.elemAt code 0).c
                else null;
            };
          };

  # Find the first match of a program in a text.
  #
  # The result is null when there is none, and otherwise
  #
  #   { start; end; groups = [ { start; end; } ... ]; }
  #
  # The groups are the nine groups of the pattern, and a group that did
  # not match is null.
  match = program: subject: matchFrom program subject 0;

  # Find the first match of a program in a text, from a place on.
  matchFrom = program: subject: from:
    let
      text = if program.icase then lowerText subject else subject;
      places = startPlaces program text from;
      # The place where the match starts.
      found = b.foldl' (acc: p:
        if acc != null then acc
        else
          let
            res = runVm program text p "first";
          in
            if res == null then null else { start = p; end = res.end; slots = res.slots; }
      ) null places;
    in
      if found == null then null
      else
        let
          # The longest match at that place.
          longest = runVm program text found.start "longest";
          use = if longest == null then found else longest;
        in
          {
            start = use.start;
            end = use.end;
            groups = b.genList (i: b.elemAt use.slots (i + 1)) 9;
          };
in {
  compile = compile;
  match = match;
  matchFrom = matchFrom;

  # The code of a character, for the callers that need it.
  ord = ord;

  # The pieces of the engine, for the callers that want them.
  modules = {
    parsePattern = parsePattern;
    emit = emit;
    runVm = runVm;
  };
}
