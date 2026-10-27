{ nixParser, strings }:
let
  b = builtins;

  markerKinds = [
    { type = "inline"; open = "{<"; close = ">}"; }
    { type = "next"; open = "{#"; close = "#}"; }
    { type = "block"; open = "{%"; close = "%}"; }
  ];

  allSpace = text:
    let
      length = b.stringLength text;
      go = offset:
        if offset >= length
        then true
        else if strings.isSpace (b.substring offset 1 text)
        then go (offset + 1)
        else false;
    in
      go 0;

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
        line = location.line;
        column = location.column;
        col = location.column - 1;
      };

  findNextMarker = text: start:
    let
      candidates = b.map (kind:
        let
          index = strings.findFrom kind.open text start;
        in
          if index == null then null else {
            inherit index kind;
          }
      ) markerKinds;
      present = b.filter (x: x != null) candidates;
    in
      if present == []
      then null
      else
        let
          sorted = b.sort (a: c: a.index < c.index) present;
        in
          b.head sorted;

  wrapperStart = text: commentStyle: markerIndex:
    let
      open = commentStyle.open;
      openLength = b.stringLength open;
      index = strings.lastIndexOf open text (markerIndex - 1);
    in
      if index == null
      then null
      else
        let
          between = b.substring (index + openLength) (markerIndex - index - openLength) text;
        in
          if allSpace between && strings.findFrom "\n" between 0 == null
          then index
          else null;

  parseDirective = text: commentStyle: candidate:
    let
      markerIndex = candidate.index;
      marker = candidate.kind;
      markerEnd = markerIndex + b.stringLength marker.open;
      start = wrapperStart text commentStyle markerIndex;
    in
      if start == null
      then null
      else
        let
          fragment = b.substring markerEnd (b.stringLength text - markerEnd) text;
          parsed = nixParser.safeParseUntil {
            terminator = marker.close;
            text = fragment;
          };
        in
          if parsed.type == "error"
          then {
            type = "error";
            error = errorValue text (markerEnd + (parsed.value.offset or 0))
              (parsed.value.message or "invalid Nix expression") parsed.value;
          }
          else
            let
              value = parsed.value;
              terminatorEnd = markerEnd + value.consumed;
              close = commentStyle.close;
              closeStart = strings.firstNonSpace text terminatorEnd;
              closeLength = b.stringLength close;
              closeMatches = closeLength == 0 || (
                closeStart + closeLength <= b.stringLength text
                && b.substring closeStart closeLength text == close
              );
            in
              if !closeMatches
              then {
                type = "error";
                error = errorValue text terminatorEnd
                  "comment marker is missing the closing comment delimiter" {};
              }
              else
                let
                  wrapperEnd = if closeLength == 0 then terminatorEnd else closeStart + closeLength;
                  expression = strings.trim value.expression;
                  directiveType =
                    if marker.type == "inline" then "inline"
                    else if marker.type == "next" then if expression == "ignore" then "rawNext" else "next"
                    else if expression == "end" then "blockEnd"
                    else if expression == "ignore" then "rawBlock"
                    else "blockOpen";
                in {
                  type = "success";
                  value = {
                    type = directiveType;
                    markerType = marker.type;
                    wrapperStart = start;
                    wrapperEnd = wrapperEnd;
                    markerStart = markerIndex;
                    markerEnd = terminatorEnd;
                    expression = expression;
                    expressionStart = markerEnd + value.expressionOffset;
                    expressionEnd = markerEnd + value.expressionOffset + value.expressionLength;
                    ast = value.ast;
                  };
                };

  scan = text: commentStyle: offset:
    let
      candidate = findNextMarker text offset;
    in
      if candidate == null
      then {
        type = "success";
        directives = [];
      }
      else
        let
          parsed = parseDirective text commentStyle candidate;
        in
          if parsed != null && parsed.type == "error"
          then parsed
          else if parsed == null
          then scan text commentStyle (candidate.index + b.stringLength candidate.kind.open)
          else
            let
              rest = scan text commentStyle parsed.value.wrapperEnd;
            in
              if rest.type == "error"
              then rest
              else {
                type = "success";
                directives = [ parsed.value ] ++ rest.directives;
              };

  addNode = stack: roots: node:
    if stack == []
    then {
      stack = stack;
      roots = roots ++ [ node ];
    }
    else
      let
        parent = b.head stack;
        updated = parent // {
          children = parent.children ++ [ node ];
        };
      in {
        stack = b.tail stack ++ [ updated ];
        roots = roots;
      };

  pairDirectives = text: directives:
    let
      go = stack: roots: remaining:
        if remaining == []
        then {
          type = "success";
          stack = stack;
          roots = roots;
        }
        else
          let
            directive = b.head remaining;
            rest = b.tail remaining;
          in
            if directive.type == "blockEnd"
            then (
              if stack == []
              then {
                type = "error";
                error = errorValue text directive.wrapperStart "unexpected block end marker" {};
              }
              else
                let
                  open = b.head stack;
                  stackRest = b.tail stack;
                  openingLineEnd = strings.lineEnd text open.wrapperEnd;
                  bodyStart = if openingLineEnd < b.stringLength text then openingLineEnd + 1 else openingLineEnd;
                  bodyEnd = strings.lineStart text directive.wrapperStart;
                  completed = open // {
                    end = directive;
                    inherit bodyStart bodyEnd;
                  };
                  added = addNode stackRest roots completed;
                in
                  go added.stack added.roots rest
            )
            else if directive.type == "blockOpen" || directive.type == "rawBlock"
            then (
              let
                node = directive // {
                  children = [];
                  end = null;
                  bodyStart = null;
                  bodyEnd = null;
                };
              in
                go (stack ++ [ node ]) roots rest
            )
            else (
              let
                added = addNode stack roots directive;
              in
                go added.stack added.roots rest
            );
      result = go [] [] directives;
    in
      if result.type == "error"
      then result
      else if result.stack != []
      then {
        type = "error";
        error = errorValue text (b.head result.stack).wrapperStart "unterminated block transform" {};
      }
      else {
        type = "success";
        roots = result.roots;
      };

  collectEdits = text: node: depth:
    if node.type == "blockOpen" || node.type == "rawBlock"
    then [ {
      type = node.type;
      targetStart = node.bodyStart;
      targetEnd = node.bodyEnd;
      expression = node.expression;
      ast = node.ast;
      inherit depth;
    } ] ++ b.concatMap (child: collectEdits text child (depth + 1)) node.children
    else if node.type == "inline"
    then [ {
      type = "inline";
      targetStart = strings.lineStart text node.wrapperStart;
      targetEnd = node.wrapperStart;
      expression = node.expression;
      ast = node.ast;
      inherit depth;
    } ]
    else if node.type == "next"
    then
      let
        nextStart = strings.min (b.stringLength text) ((strings.lineEnd text node.wrapperEnd) + 1);
      in [ {
        type = "next";
        targetStart = nextStart;
        targetEnd = strings.lineEnd text nextStart;
        expression = node.expression;
        ast = node.ast;
        inherit depth;
      } ]
    else if node.type == "rawNext"
    then
      let
        nextStart = strings.min (b.stringLength text) ((strings.lineEnd text node.wrapperEnd) + 1);
      in [ {
        type = "rawNext";
        targetStart = nextStart;
        targetEnd = strings.lineEnd text nextStart;
        expression = node.expression;
        ast = node.ast;
        inherit depth;
      } ]
    else [];

  safeParse = { text, commentStyle }:
    if !b.isString text
    then {
      type = "error";
      value = errorValue "" 0 "text must be a string" {};
    }
    else if !b.isAttrs commentStyle || !b.isString commentStyle.open || commentStyle.open == ""
    then {
      type = "error";
      value = errorValue text 0 "commentStyle.open must be a non-empty string" {};
    }
    else if !b.isString commentStyle.close
    then {
      type = "error";
      value = errorValue text 0 "commentStyle.close must be a string" {};
    }
    else
      let
        scanned = scan text commentStyle 0;
      in
        if scanned.type == "error"
        then scanned
        else
          let
            paired = pairDirectives text scanned.directives;
          in
            if paired.type == "error"
            then paired
            else {
              type = "success";
              value = {
                type = "comment-template";
                inherit text commentStyle;
                directives = scanned.directives;
                roots = paired.roots;
              };
            };
in {
  inherit safeParse collectEdits;
}
