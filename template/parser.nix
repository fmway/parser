{ nixParser, strings }:
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

  errorValue = text: offset: message: details:
    let
      location = lineColumn text offset;
    in
      details // {
        inherit message offset;
        # The context of the parser of Nix is not shown, the error is
        # in the template and not in a Nix file.
        context = "template.v1";
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

        # Every place where the prefix is, found in one pass over the
        # text. The loop that follows is a fold over them, and not a
        # recursion, so the number of interpolations does not affect
        # the depth of the stack.
        positions = strings.occurrences prefix text;

        step = acc: position:
          if acc.error != null
          then acc
          else if position < acc.offset
          then acc
          else
            let
              literal =
                if position > acc.offset
                then [ {
                  type = "literal";
                  text = b.substring acc.offset (position - acc.offset) text;
                  start = acc.offset;
                  end = position;
                } ]
                else [];
              expressionStart = position + prefixLength;
              fragment = b.substring expressionStart (textLength - expressionStart) text;
              parsed = nixParser.safeParseUntil {
                terminator = postfix;
                text = fragment;
              };
            in
              if parsed.type == "error"
              then {
                segments = acc.segments;
                offset = acc.offset;
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
                    start = position;
                    end = placeholderEnd;
                    expressionStart = expressionStart + value.expressionOffset;
                    expressionEnd = expressionStart + value.expressionOffset + value.expressionLength;
                  };
                in {
                  segments = acc.segments ++ literal ++ [ interpolation ];
                  offset = placeholderEnd;
                  error = null;
                };

        res = b.foldl' step {
          segments = [];
          offset = 0;
          error = null;
        } positions;
      in
        if res.error != null
        then {
          type = "error";
          value = res.error;
        }
        else {
          type = "success";
          value = {
            type = "template";
            inherit prefix postfix text;
            segments = res.segments ++ (
              if res.offset < textLength
              then [ {
                type = "literal";
                text = b.substring res.offset (textLength - res.offset) text;
                start = res.offset;
                end = textLength;
              } ]
              else []
            );
            start = 0;
            end = textLength;
          };
        };
in {
  inherit safeParse;
}
