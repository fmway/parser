{ strings, render }:
let
  b = builtins;
  inherit (import ../utils) fix mod;

  isSpaces = x: x == "" || x == " " || x == "\t" || x == "\n";
  lastChar = s: if s == "" then s else b.substring (b.stringLength s - 1) 1 s;
  firstChar= s: if s == "" then s else b.substring 0 1 s;

  quotedContent = text: let
    length = b.stringLength text;
    findQuote = offset:
      if offset >= length then null
      else let c = b.substring offset 1 text; in
        if c == "\"" || c == "'" then offset else findQuote (offset + 1);
    quoteIndex = findQuote 0;
  in
    if quoteIndex == null then null
    else let
      quote = b.substring quoteIndex 1 text;
      closeIndex = strings.findFrom quote text (quoteIndex + 1);
    in
      if closeIndex == null then null
      else { inherit quoteIndex closeIndex quote; };

  replaceBuilder = regex: replacement: text: let
    tokens = b.split "(${regex})" text;
    l = b.length tokens;
    lastI = l - 1;
  in 
    b.concatStringsSep ""
    (b.genList (i: let token = b.elemAt tokens i; prev = b.elemAt tokens (i - 1); next = b.elemAt tokens (i + 1); in
      if b.isList token then
        if (i == 0 || isSpaces (lastChar prev)) && (i == lastI || isSpaces (firstChar next)) then
          render.renderValue replacement
        else b.elemAt token 0
      else token
    ) l);

in fix (s: {
  rq = s.replace_quoted;
  replace_quoted = replacement: text: let
    quoted = quotedContent text;
  in
    if quoted == null then
      text
    else
      b.substring 0 (quoted.quoteIndex + 1) text
      + render.renderValue replacement
      + b.substring quoted.closeIndex (b.stringLength text - quoted.closeIndex) text;

  rbet = s.replace_between;
  replace_between = start: end: replacement: text: let
    startIndex = strings.findFrom start text 0;
  in
    if startIndex == null then
      text
    else let
      contentStart = startIndex + b.stringLength start;
      endIndex = strings.findFrom end text contentStart;
    in
      if endIndex == null then
        text
      else
        b.substring 0 contentStart text
        + render.renderValue replacement
        + b.substring endIndex (b.stringLength text - endIndex) text;

  rin = s.replace_in;
  replace_in = delimiter: s.replace_between delimiter delimiter;

  rv = s.replace_value;
  replace_value = replacement: text: let
    equals = strings.findFrom "=" text 0;
    colon = strings.findFrom ":" text 0;
    candidates = b.filter (x: x != null) [ equals colon ];
    separator = if candidates == [] then null else b.head (b.sort (a: c: a < c) candidates);
  in
    if separator == null then
      text
    else let
      valueStart = strings.firstNonSpace text (separator + 1);
      rest = b.substring valueStart (b.stringLength text - valueStart) text;
      endOffset = let
        semicolon = strings.findFrom ";" rest 0;
        comma = strings.findFrom "," rest 0;
        newline = strings.findFrom "\n" rest 0;
        found = b.filter (x: x != null) [ semicolon comma newline ];
      in if found == [] then b.stringLength rest else b.head (b.sort (a: c: a < c) found);
        valueEnd = valueStart + endOffset;
    in
      b.substring 0 valueStart text
      + render.renderValue replacement
      + b.substring valueEnd (b.stringLength text - valueEnd) text;

  rr = s.replace_re;
  replace_re = re: replacement: text: let
    m = b.match "^(.*)(${re})(.*)$" text;
    l = b.length m - 2;
  in
    if isNull m then text
    else
      b.elemAt m 0
    + b.replaceStrings
        (b.genList (i: (if i >= l then "\\" else "$") + toString (l - 1 - mod i l)) (l * 2))
        (b.genList (i: b.elemAt m (l - mod i l)) (l * 2))
        (render.renderValue replacement)
    + b.elemAt m (l + 1);

  rnum = s.replace_number;
  replace_number = replaceBuilder "-?[[:digit:]]+([.][[:digit:]]+)?";

  rcol = s.replace_color;
  replace_color = replaceBuilder "#([0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3})";
})
