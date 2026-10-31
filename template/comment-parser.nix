{ nixParser, strings }:
let
  b = builtins;
  inherit (import ../utils) min;

  markerKinds = [
    { type = "inline"; open = "{<"; close = ">}"; }
    { type = "next"; open = "{#"; close = "#}"; }
    { type = "block"; open = "{%"; close = "%}"; }
  ];

  kindFor = open:
    let
      found = b.filter (kind: kind.open == open) markerKinds;
    in
      if found == [] then null else b.head found;

  allSpace = text:
    # The text is searched for a character that is not a space, and the
    # search does not use the stack, so that a long text does not
    # overflow it.
    b.length (b.split "([^ \t\r\n])" text) == 1;

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
        context = "template.v2";
        line = location.line;
        column = location.column;
        col = location.column - 1;
      };

  # ------------------------------------------------------------------
  # The places where a marker starts
  #
  # The regex engine finds them in one pass over the text. The old
  # search walked the text one character at a time, which used one
  # stack frame per character and overflowed the stack on a long file.
  # ------------------------------------------------------------------
  findMarkers = text:
    let
      parts = b.split "(\\{#|\\{%|\\{<)" text;
      count = b.length parts;
      step = acc: i:
        let
          item = b.elemAt parts i;
        in
          if i - 2 * (b.div i 2) == 0
          then acc // { offset = acc.offset + b.stringLength item; }
          else
            let
              matched = b.concatStringsSep "" item;
            in {
              offset = acc.offset + b.stringLength matched;
              markers = acc.markers ++ [ { offset = acc.offset; open = matched; } ];
            };
      res = b.foldl' step { offset = 0; markers = []; } (b.genList (x: x) count);
    in
      res.markers;

  # ------------------------------------------------------------------
  # The Nix expression of every marker
  #
  # The expression of a marker does not depend on the comment style, so
  # it is parsed once for every marker and then used by every style.
  # The old code parsed the expression again for every style it tried,
  # which was the bulk of the work.
  # ------------------------------------------------------------------
  parseMarkers = index: markers:
    let
      text = index.text;
    in
    b.foldl' (acc: marker:
      let
        kind = kindFor marker.open;
        markerEnd = marker.offset + b.stringLength marker.open;
        fragment = b.substring markerEnd (b.stringLength text - markerEnd) text;
        parsed = nixParser.safeParseUntil {
          terminator = kind.close;
          text = fragment;
        };
        # The line that the marker is on is worked out here, and not
        # in the scan of a comment style, so that it is worked out once
        # for the marker and not once for every style that is tried.
        lineStart = index.start marker.offset;
      in
        if parsed.type == "error"
        then acc ++ [ {
          inherit marker kind lineStart;
          failed = true;
          error = parsed.value;
        } ]
        else acc ++ [ {
          inherit marker kind lineStart;
          failed = false;
          expression = parsed.value.expression;
          ast = parsed.value.ast;
          consumed = parsed.value.consumed;
          expressionOffset = parsed.value.expressionOffset;
          expressionLength = parsed.value.expressionLength;
        } ]
    ) [] markers;

  # ------------------------------------------------------------------
  # The comment that holds a marker
  #
  # The comment has to be on the same line as the marker, with nothing
  # but spaces between them. The search for it is kept inside the line,
  # so it costs the length of the line and not the length of the text.
  # ------------------------------------------------------------------
  wrapperStart = index: commentStyle: parsed:
    let
      text = index.text;
      markerIndex = parsed.marker.offset;
      open = commentStyle.open;
      openLength = b.stringLength open;
      line = parsed.lineStart;
      before = b.substring line (markerIndex - line) text;
      relative = strings.lastIndexOf open before (b.stringLength before - openLength);
    in
      if relative == null
      then null
      else
        let
          between = b.substring (relative + openLength) (b.stringLength before - relative - openLength) before;
        in
          if allSpace between then line + relative else null;

  # The directive a marker stands for.
  mkDirective = text: commentStyle: parsed: wrapper:
    let
      marker = parsed.marker;
      kind = parsed.kind;
      markerEnd = marker.offset + b.stringLength marker.open;
      terminatorEnd = markerEnd + parsed.consumed;
      close = commentStyle.close;
      closeStart = terminatorEnd;
      closeLength = b.stringLength close;
      closeMatches = closeLength == 0 || (
        closeStart + closeLength <= b.stringLength text
        && b.substring closeStart closeLength text == close
      );
    in
      if !closeMatches
      then {
        error = errorValue text terminatorEnd
          "comment marker is missing the closing comment delimiter" {};
      }
      else
        let
          wrapperEnd = if closeLength == 0 then terminatorEnd else closeStart + closeLength;
          expression = strings.trim parsed.expression;
          directiveType =
            if kind.type == "inline" then "inline"
            else if kind.type == "next" then if expression == "ignore" then "rawNext" else "next"
            else if expression == "end" then "blockEnd"
            else if expression == "ignore" then "rawBlock"
            else "blockOpen";
        in {
          type = directiveType;
          markerType = kind.type;
          wrapperStart = wrapper;
          wrapperEnd = wrapperEnd;
          markerStart = marker.offset;
          markerEnd = terminatorEnd;
          expression = expression;
          expressionStart = markerEnd + parsed.expressionOffset;
          expressionEnd = markerEnd + parsed.expressionOffset + parsed.expressionLength;
          ast = parsed.ast;
        };

  # ------------------------------------------------------------------
  # The scan
  #
  # The loop is a fold over the markers, and not a recursion, so the
  # number of markers does not affect the depth of the stack.
  # ------------------------------------------------------------------
  scan = index: commentStyle: parsedMarkers:
    let
      text = index.text;
      step = acc: parsed:
        if acc.failed
        then acc
        else if parsed.marker.offset < acc.skipUntil
        then acc
        else
          let
            wrapper = wrapperStart index commentStyle parsed;
          in
            if wrapper == null
            then acc // {
              skipUntil = parsed.marker.offset + b.stringLength parsed.marker.open;
            }
            else if parsed.failed
            then {
              failed = true;
              directives = acc.directives;
              skipUntil = acc.skipUntil;
              error = errorValue text
                (parsed.marker.offset + b.stringLength parsed.marker.open + (parsed.error.offset or 0))
                (parsed.error.message or "invalid Nix expression") parsed.error;
            }
            else
              let
                directive = mkDirective text commentStyle parsed wrapper;
              in
                if directive ? error
                then {
                  failed = true;
                  directives = acc.directives;
                  skipUntil = acc.skipUntil;
                  error = directive.error;
                }
                else {
                  failed = false;
                  directives = acc.directives ++ [ directive ];
                  skipUntil = directive.wrapperEnd;
                };
      res = b.foldl' step {
        failed = false;
        error = null;
        directives = [];
        skipUntil = 0;
      } parsedMarkers;
    in
      if res.failed
      then { type = "error"; error = res.error; }
      else { type = "success"; directives = res.directives; };

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

  # ------------------------------------------------------------------
  # Pairing the block markers
  #
  # The loop is a fold over the directives, and not a recursion.
  # ------------------------------------------------------------------
  pairDirectives = index: directives:
    let
      text = index.text;
      step = acc: directive:
        if acc.error != null
        then acc
        else if directive.type == "blockEnd"
        then (
          if acc.stack == []
          then acc // {
            error = errorValue text directive.wrapperStart "unexpected block end marker" {};
          }
          else
            let
              open = b.head acc.stack;
              stackRest = b.tail acc.stack;
              openingLineEnd = index.end open.wrapperEnd;
              bodyStart = if openingLineEnd < b.stringLength text then openingLineEnd + 1 else openingLineEnd;
              bodyEnd = index.start directive.wrapperStart;
              completed = open // {
                end = directive;
                inherit bodyStart bodyEnd;
              };
              added = addNode stackRest acc.roots completed;
            in {
              stack = added.stack;
              roots = added.roots;
              error = null;
            }
        )
        else if directive.type == "blockOpen" || directive.type == "rawBlock"
        then {
          stack = acc.stack ++ [ (directive // {
            children = [];
            end = null;
            bodyStart = null;
            bodyEnd = null;
          }) ];
          roots = acc.roots;
          error = null;
        }
        else
          let
            added = addNode acc.stack acc.roots directive;
          in {
            stack = added.stack;
            roots = added.roots;
            error = null;
          };
      res = b.foldl' step { stack = []; roots = []; error = null; } directives;
    in
      if res.error != null
      then { type = "error"; error = res.error; }
      else if res.stack != []
      then {
        type = "error";
        error = errorValue text (b.head res.stack).wrapperStart "unterminated block transform" {};
      }
      else {
        type = "success";
        roots = res.roots;
      };

  collectEdits = index: node: depth:
    let
      text = index.text;
    in
    if node.type == "blockOpen" || node.type == "rawBlock"
    then
      let
        emptyBody = node.bodyStart >= node.bodyEnd;
        targetStart = node.bodyStart;
        targetEnd =
          if emptyBody
          then node.bodyStart
          else (if node.bodyEnd > node.bodyStart && b.substring (node.bodyEnd - 1) 1 text == "\n" then node.bodyEnd - 1 else node.bodyEnd);
      in [ {
        type = node.type;
        inherit targetStart targetEnd;
        expression = node.expression;
        ast = node.ast;
        expressionStart = node.expressionStart;
        inherit depth;
      } ] ++ b.concatMap (child: collectEdits index child (depth + 1)) node.children
    else if node.type == "inline"
    then
      let
        lineStart = index.start node.wrapperStart;
        trimmedEnd = strings.lastNonSpaceIn text lineStart node.wrapperStart;
        targetEnd = if trimmedEnd < lineStart then lineStart else trimmedEnd;
      in [ {
        type = "inline";
        targetStart = lineStart;
        inherit targetEnd;
        expression = node.expression;
        ast = node.ast;
        expressionStart = node.expressionStart;
        inherit depth;
      } ]
    else if node.type == "nextChain"
    then
      let
        last = b.elemAt node.directives (b.length node.directives - 1);
        nextStart = min (b.stringLength text) ((index.end last.wrapperEnd) + 1);
      in [ {
        type = "nextChain";
        asts = node.asts;
        expressions = b.map (d: d.expression) node.directives;
        expressionStarts = b.map (d: d.expressionStart) node.directives;
        targetStart = nextStart;
        targetEnd = index.end nextStart;
        inherit depth;
      } ]
    else if node.type == "next"
    then
      let
        nextStart = min (b.stringLength text) ((index.end node.wrapperEnd) + 1);
      in [ {
        type = "next";
        targetStart = nextStart;
        targetEnd = index.end nextStart;
        expression = node.expression;
        ast = node.ast;
        expressionStart = node.expressionStart;
        inherit depth;
      } ]
    else if node.type == "rawNext"
    then
      let
        nextStart = min (b.stringLength text) ((index.end node.wrapperEnd) + 1);
      in [ {
        type = "rawNext";
        targetStart = nextStart;
        targetEnd = index.end nextStart;
        expression = node.expression;
        ast = node.ast;
        expressionStart = node.expressionStart;
        inherit depth;
      } ]
    else [];

  knownCommentStyles = [
    { open = "# "; close = ""; }
    { open = "// "; close = ""; }
    { open = "-- "; close = ""; }
    { open = "; "; close = ""; }
    { open = "/* "; close = " */"; }
    { open = "<!--"; close = "-->"; }
  ];

  # The style whose first directive comes first.
  #
  # The scan of the text with the style is given back with it, so that
  # the scan of the style that is picked is not done a second time.
  pickStyle = index: parsedMarkers: styles:
    let
      candidates = b.map (style:
        let
          scanned = scan index style parsedMarkers;
        in
          if scanned.type == "success" && scanned.directives != []
          then {
            inherit style scanned;
            index = (b.head scanned.directives).markerStart;
          }
          else null
      ) styles;
      present = b.filter (x: x != null) candidates;
    in
      if present == []
      then null
      else (b.head (b.sort (a: c: a.index < c.index) present));

  defaultCommentStyle = { open = "# "; close = ""; };

  inferCommentStyle = text:
    let
      index = strings.lineIndex text;
      markers = findMarkers text;
      parsedMarkers = parseMarkers index markers;
    in
      inferCommentStyleOf index parsedMarkers;

  inferCommentStyleOf = index: parsedMarkers:
    let
      style = pickStyle index parsedMarkers knownCommentStyles;
    in
      if style == null then defaultCommentStyle else style.style;

  resolveCommentStyleOf = index: parsedMarkers: requested:
    if requested == null || requested == "auto"
    then inferCommentStyleOf index parsedMarkers
    else if b.isAttrs requested
    then requested
    else defaultCommentStyle;

  resolveCommentStyle = text: requested:
    let
      index = strings.lineIndex text;
    in
      resolveCommentStyleOf index (parseMarkers index (findMarkers text)) requested;

  makeNextChain = chain:
    if b.length chain == 1
    then b.head chain
    else {
      type = "nextChain";
      directives = chain;
      wrapperStart = (b.elemAt chain (b.length chain - 1)).wrapperStart;
      wrapperEnd = (b.elemAt chain (b.length chain - 1)).wrapperEnd;
      markerStart = (b.head chain).markerStart;
      markerEnd = (b.elemAt chain (b.length chain - 1)).markerEnd;
      asts = b.map (d: d.ast) chain;
    };

  adjacentNext = index: a: c:
    index.start c.markerStart
    == index.end a.wrapperEnd + 1;

  # ------------------------------------------------------------------
  # Grouping the markers that follow each other
  #
  # The loop is a fold over the directives, and not a recursion.
  # ------------------------------------------------------------------
  groupNextChains = index: directives:
    let
      step = acc: directive:
        let
          chain = acc.chain;
          last = if chain == [] then null else b.elemAt chain (b.length chain - 1);
        in
          if chain == []
          then
            if directive.type == "next"
            then acc // { chain = [ directive ]; }
            else acc // { chain = []; done = acc.done ++ [ directive ]; }
          else if directive.type == "next" && adjacentNext index last directive
          then acc // { chain = chain ++ [ directive ]; }
          else if directive.type == "next"
          then {
            chain = [ directive ];
            done = acc.done ++ [ (makeNextChain chain) ];
          }
          else {
            chain = [];
            done = acc.done ++ [ (makeNextChain chain) ] ++ [ directive ];
          };
      res = b.foldl' step { chain = []; done = []; } directives;
    in
      if res.chain == [] then res.done else res.done ++ [ (makeNextChain res.chain) ];

  safeParse = { text, commentStyle ? "auto" }:
    if !b.isString text
    then {
      type = "error";
      value = errorValue "" 0 "text must be a string" {};
    }
    else
      let
        # The index of the lines of the text is made once, and every
        # search for a line uses it, so that no search walks over the
        # text again.
        index = strings.lineIndex text;
        markers = findMarkers text;
        parsedMarkers = parseMarkers index markers;
        # The style is looked for only when it is not asked for, and
        # the scan that comes with it is the scan that is used.
        picked =
          if commentStyle == null || commentStyle == "auto"
          then pickStyle index parsedMarkers knownCommentStyles
          else null;
        resolved =
          if picked != null
          then picked.style
          else if b.isAttrs commentStyle
          then commentStyle
          else defaultCommentStyle;
      in
        if !b.isAttrs resolved || !b.isString resolved.open || resolved.open == ""
        then {
          type = "error";
          value = errorValue text 0 "commentStyle.open must be a non-empty string" {};
        }
        else if !b.isString resolved.close
        then {
          type = "error";
          value = errorValue text 0 "commentStyle.close must be a string" {};
        }
        else
          let
            scanned =
              if picked != null
              then picked.scanned
              else scan index resolved parsedMarkers;
          in
            if scanned.type == "error"
            then { type = "error"; value = scanned.error; }
            else
              let
                grouped = groupNextChains index scanned.directives;
                paired = pairDirectives index grouped;
              in
                if paired.type == "error"
                then { type = "error"; value = paired.error; }
                else {
                  type = "success";
                  value = {
                    type = "comment-template";
                    inherit text index;
                    commentStyle = resolved;
                    directives = grouped;
                    roots = paired.roots;
                  };
                };
in {
  inherit safeParse collectEdits inferCommentStyle resolveCommentStyle;
}
