{ commentParser, helpers, nix, render, errors }:
let
  b = builtins;

  helperScope = context: {
    replace_quoted = replacement: helpers.replaceQuoted context replacement;
    replace_between = replacement: start: end: helpers.replaceBetween context replacement start end;
    replace_in = replacement: delimiter: helpers.replaceBetween context replacement delimiter delimiter;
    replace_value = replacement: helpers.replaceValue context replacement;
    replace_color = replacement: helpers.replaceColor context replacement;
    replace_many = functions: b.foldl' (value: function: function value) context functions;
    rq = replacement: helpers.replaceQuoted context replacement;
    rbet = replacement: start: end: helpers.replaceBetween context replacement start end;
    rin = replacement: delimiter: helpers.replaceBetween context replacement delimiter delimiter;
    rv = replacement: helpers.replaceValue context replacement;
    rcol = replacement: helpers.replaceColor context replacement;
    rm = functions: b.foldl' (value: function: function value) context functions;
  };

  scopeFor = scope: context:
    helperScope context // scope // { inherit context; };

  adjustmentFor = edit: adjustments:
    b.foldl' (total: adjustment:
      if adjustment.offset >= edit.targetStart && adjustment.offset < edit.targetEnd
      then total + adjustment.delta
      else total
    ) 0 adjustments;

  transformValue = ast: current: cwd: scope: location: text:
    builtins.addErrorContext (errors.errorMessage text {
      offset = location;
      msg = "";
      context = "template";
    }) (
      let
        evaluated = nix.evalAst {
          ast = ast;
          inherit cwd;
          scope = scopeFor scope current;
        };
        value =
          if b.isFunction evaluated
          then evaluated current
          else if b.isAttrs evaluated && evaluated ? __functor && b.isFunction evaluated.__functor
          then evaluated.__functor evaluated current
          else evaluated;
      in
        render.renderValue value
    );

  reverseList = xs: b.foldl' (acc: x: [ x ] ++ acc) [] xs;

  applyEdit = text: scope: cwd: adjustments: edit:
    let
      adjustedEnd = edit.targetEnd + adjustmentFor edit adjustments;
      current =
        if adjustedEnd < edit.targetStart
        then ""
        else b.substring edit.targetStart (adjustedEnd - edit.targetStart) text;
      replacement =
        if edit.type == "rawBlock" || edit.type == "rawNext"
        then current
        else if edit.type == "nextChain"
        then
          let
            go = i: ctx:
              if i >= b.length edit.asts
              then ctx
              else
                let
                  ast = b.elemAt edit.asts i;
                  location = b.elemAt edit.expressionStarts i;
                  next = transformValue ast ctx cwd scope location text;
                in
                  go (i + 1) next;
          in
            go 0 current
        else transformValue edit.ast current cwd scope edit.expressionStart text;
      finalReplacement =
        if edit.type == "blockOpen" && current == "" && replacement != "" && !(b.substring (b.stringLength replacement - 1) 1 replacement == "\n")
        then replacement + "\n"
        else replacement;
      updated =
        b.substring 0 edit.targetStart text
        + finalReplacement
        + b.substring adjustedEnd (b.stringLength text - adjustedEnd) text;
      originalLength = edit.targetEnd - edit.targetStart;
      delta = b.stringLength finalReplacement - originalLength;
    in {
      text = updated;
      adjustments = adjustments ++ [ {
        offset = edit.targetStart;
        inherit delta;
      } ];
    };

  renderTemplate = ast: cwd: scope:
    let
      edits = b.concatMap (node: commentParser.collectEdits ast.text node 0) ast.roots;
      sorted = b.sort (a: c:
        if a.targetStart != c.targetStart
        then a.targetStart > c.targetStart
        else a.depth > c.depth
      ) edits;
      result = b.foldl' (state: edit:
        applyEdit state.text scope cwd state.adjustments edit
      ) {
        text = ast.text;
        adjustments = [];
      } sorted;
    in
      result.text;
in {
  inherit renderTemplate;
}
