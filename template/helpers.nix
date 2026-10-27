{ strings }:
let
  b = builtins;

  replaceFirst = text: needle: replacement:
    let
      index = strings.findFrom needle text 0;
    in
      if index == null
      then text
      else b.substring 0 index text + replacement + b.substring (index + b.stringLength needle) (b.stringLength text - index - b.stringLength needle) text;

  quotedContent = text:
    let
      length = b.stringLength text;
      findQuote = offset:
        if offset >= length
        then null
        else
          let
            c = b.substring offset 1 text;
          in
            if c == "\"" || c == "'" then offset else findQuote (offset + 1);
      quoteIndex = findQuote 0;
    in
      if quoteIndex == null
      then null
      else
        let
          quote = b.substring quoteIndex 1 text;
          closeIndex = strings.findFrom quote text (quoteIndex + 1);
        in
          if closeIndex == null
          then null
          else {
            inherit quoteIndex closeIndex quote;
          };

  replaceQuoted = text: replacement:
    let
      quoted = quotedContent text;
    in
      if quoted == null
      then text
      else
        b.substring 0 (quoted.quoteIndex + 1) text
        + replacement
        + b.substring quoted.closeIndex (b.stringLength text - quoted.closeIndex) text;

  replaceBetween = text: replacement: start: end:
    let
      startIndex = strings.findFrom start text 0;
    in
      if startIndex == null
      then text
      else
        let
          contentStart = startIndex + b.stringLength start;
          endIndex = strings.findFrom end text contentStart;
        in
          if endIndex == null
          then text
          else
            b.substring 0 contentStart text
            + replacement
            + b.substring endIndex (b.stringLength text - endIndex) text;

  replaceValue = text: replacement:
    let
      equals = strings.findFrom "=" text 0;
      colon = strings.findFrom ":" text 0;
      candidates = b.filter (x: x != null) [ equals colon ];
      separator = if candidates == [] then null else b.head (b.sort (a: c: a < c) candidates);
    in
      if separator == null
      then text
      else
        let
          valueStart = strings.firstNonSpace text (separator + 1);
          rest = b.substring valueStart (b.stringLength text - valueStart) text;
          endOffset =
            let
              semicolon = strings.findFrom ";" rest 0;
              comma = strings.findFrom "," rest 0;
              newline = strings.findFrom "\n" rest 0;
              found = b.filter (x: x != null) [ semicolon comma newline ];
            in
              if found == [] then b.stringLength rest else b.head (b.sort (a: c: a < c) found);
          valueEnd = valueStart + endOffset;
        in
          b.substring 0 valueStart text
          + replacement
          + b.substring valueEnd (b.stringLength text - valueEnd) text;

  isHexDigit = c:
    (c >= "0" && c <= "9") || (c >= "a" && c <= "f") || (c >= "A" && c <= "F");

  colorEnd = text: start:
    let
      length = b.stringLength text;
      available = length - start;
      count =
        if available >= 8 && matchesHex (b.substring start 8 text) 8
        then 8
        else if available >= 6 && matchesHex (b.substring start 6 text) 6
        then 6
        else if available >= 3 && matchesHex (b.substring start 3 text) 3
        then 3
        else 0;
    in
      if count == 0 then null else start + count;

  matchesHex = text: count:
    let
      go = offset:
        if offset >= count
        then true
        else if isHexDigit (b.substring offset 1 text)
        then go (offset + 1)
        else false;
    in
      go 0;

  replaceColor = text: replacement:
    let
      length = b.stringLength text;
      find = offset:
        if offset >= length
        then null
        else if b.substring offset 1 text == "#"
        then
          let
            end = colorEnd text (offset + 1);
          in
            if end == null then find (offset + 1) else offset
        else find (offset + 1);
      index = find 0;
    in
      if index == null
      then text
      else
        let
          end = colorEnd text (index + 1);
        in
          b.substring 0 index text
          + replacement
          + b.substring end (b.stringLength text - end) text;
in {
  inherit replaceFirst replaceQuoted replaceBetween replaceValue replaceColor;
}
