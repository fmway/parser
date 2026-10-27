{ nixParser }:
let
  b = builtins;

  lineColumn = text: offset:
    let
      before = b.substring 0 offset text;
      lines = b.filter b.isString (b.split "\n" before);
    in {
      line = b.length lines;
      column = b.stringLength (b.elemAt lines (b.length lines - 1)) + 1;
    };

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

  errorValue = text: offset: message: details:
    let
      location = lineColumn text offset;
    in
      details // {
        inherit message offset;
        line = location.line;
        column = location.column;
        col = location.column - 1;
      };

  safeParse = { prefix, postfix, text }:
    if !b.isString prefix || prefix == ""
    then {
      type = "error";
      value = errorValue text 0 "prefix must be a non-empty string" {};
    }
    else if !b.isString postfix || postfix == ""
    then {
      type = "error";
      value = errorValue text 0 "postfix must be a non-empty string" {};
    }
    else if b.substring 0 1 postfix == " " || b.substring 0 1 postfix == "\n" || b.substring 0 1 postfix == "\t" || b.substring 0 1 postfix == "\r"
    then {
      type = "error";
      value = errorValue text 0 "postfix must not start with whitespace" {};
    }
    else
      let
        prefixLength = b.stringLength prefix;
        textLength = b.stringLength text;

        parseFrom = offset:
          let
            prefixIndex = findFrom prefix text offset;
          in
            if prefixIndex == null
            then {
              segments =
                if offset < textLength
                then [ {
                  type = "literal";
                  text = b.substring offset (textLength - offset) text;
                  start = offset;
                  end = textLength;
                } ]
                else [];
              end = textLength;
            }
            else
              let
                literal =
                  if prefixIndex > offset
                  then [ {
                    type = "literal";
                    text = b.substring offset (prefixIndex - offset) text;
                    start = offset;
                    end = prefixIndex;
                  } ]
                  else [];
                expressionStart = prefixIndex + prefixLength;
                fragment = b.substring expressionStart (textLength - expressionStart) text;
                parsed = nixParser.safeParseUntil {
                  terminator = postfix;
                  text = fragment;
                };
              in
                if parsed.type == "error"
                then {
                  error = errorValue text (expressionStart + (parsed.value.offset or 0))
                    (parsed.value.message or "invalid Nix expression") parsed.value;
                }
                else
                  let
                    value = parsed.value;
                    placeholderEnd = expressionStart + value.consumed;
                    interpolation = {
                      type = "interpolation";
                      expression = value.expression;
                      ast = value.ast;
                      start = prefixIndex;
                      end = placeholderEnd;
                      expressionStart = expressionStart + value.expressionOffset;
                      expressionEnd = expressionStart + value.expressionOffset + value.expressionLength;
                    };
                    rest = parseFrom placeholderEnd;
                  in
                    if rest ? error
                    then rest
                    else {
                      segments = literal ++ [ interpolation ] ++ rest.segments;
                      end = rest.end;
                    };
          in
            let
              parsed = parseFrom 0;
            in
              if parsed ? error
              then {
                type = "error";
                value = parsed.error;
              }
              else {
                type = "success";
                value = {
                  type = "template";
                  inherit prefix postfix text;
                  segments = parsed.segments;
                  start = 0;
                  end = textLength;
                };
              };
in {
  inherit safeParse;
}
