{ commentParser, helpers, nix, render, errors, strings, stringsPath, helpersPath }:
let
  b = builtins;
  inherit (import ../utils) reverseList;

  # ------------------------------------------------------------------
  # The file that holds the expressions of the edits
  #
  # All the expressions go into one file, and the file is imported
  # once, and not once for every expression. The old parser works in
  # the same way, and a file for every expression costs a write to the
  # store and a read of it for every expression.
  #
  # Every expression is a function of the text that it works on, so
  # that the text can be given to it when the edit is done, and not
  # when the file is imported.
  # ------------------------------------------------------------------
  exprFile = expressions:
    let
      count = b.length expressions;
      body = b.concatStringsSep "\n" (b.genList (i:
        let
          expr = b.elemAt expressions i;
        in
          ''
            expr-${toString i} = context:
              with helpersFor context;
              (let v = ${expr}; in if builtins.isFunction v then v context else v);
          ''
      ) count);
    in
      ''
        var: with var;
        let
          strings = import "${stringsPath}";
          helpers = import "${helpersPath}" { inherit strings; };
          helpersFor = context: {
            replace_quoted = replacement: helpers.replaceQuoted context replacement;
            replace_between = replacement: start: end: helpers.replaceBetween context replacement start end;
            replace_in = replacement: delimiter: helpers.replaceBetween context replacement delimiter delimiter;
            replace_value = replacement: helpers.replaceValue context replacement;
            replace_color = replacement: helpers.replaceColor context replacement;
            replace_many = functions: builtins.foldl' (value: function: function value) context functions;
            rq = replace_quoted;
            rbet = replace_between;
            rin = replace_in;
            rv = replace_value;
            rcol = replace_color;
            rm = replace_many;
          };
        in {
          ${body}
        }
      '';

  # The expressions of the edits, and the place of every edit in them.
  #
  # The edits are sorted from the end of the text to its start, and
  # every expression of an edit is given a number of its own.
  #
  # The edits are folded over in the reverse order and turned around at
  # the end, so that the work does not grow with the number of the
  # edits.
  indexExpressions = edits:
    let
      step = acc: edit:
        let
          first = b.length acc.expressions;
          own =
            if edit.type == "nextChain"
            then edit.expressions
            else [ edit.expression ];
          expressionNames = b.genList (i: "expr-${toString (first + i)}") (b.length own);
        in {
          expressions = own ++ acc.expressions;
          names = expressionNames ++ acc.names;
          edits = [ (edit // { inherit expressionNames; }) ] ++ acc.edits;
        };
      res = b.foldl' step { expressions = []; names = []; edits = []; } edits;
    in {
      expressions = reverseList res.expressions;
      names = reverseList res.names;
      edits = reverseList res.edits;
    };

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
      edits = b.concatMap (node: commentParser.collectEdits ast.index node 0) ast.roots;
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

  transformValueIFD = name: current: cwd: scope: location: text: exprs:
    builtins.addErrorContext (errors.errorMessage text {
      offset = location;
      msg = "";
      context = "template";
    }) (
      let
        evaluated = exprs.${name} current;
        value =
          if b.isFunction evaluated
          then evaluated current
          else if b.isAttrs evaluated && evaluated ? __functor && b.isFunction evaluated.__functor
          then evaluated.__functor evaluated current
          else evaluated;
      in
        render.renderValue value
    );

  applyEditIFD = text: scope: cwd: adjustments: edit: exprs:
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
              if i >= b.length edit.expressionNames
              then ctx
              else
                let
                  name = b.elemAt edit.expressionNames i;
                  location = b.elemAt edit.expressionStarts i;
                  next = transformValueIFD name ctx cwd scope location text exprs;
                in
                  go (i + 1) next;
          in
            go 0 current
        else transformValueIFD (b.head edit.expressionNames) current cwd scope edit.expressionStart text exprs;
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

  renderTemplateIFD = ast: cwd: scope:
    let
      edits = b.concatMap (node: commentParser.collectEdits ast.index node 0) ast.roots;
      sorted = b.sort (a: c:
        if a.targetStart != c.targetStart
        then a.targetStart > c.targetStart
        else a.depth > c.depth
      ) edits;
      indexed = indexExpressions sorted;
      file = b.toFile "template-exprs.nix" (exprFile indexed.expressions);
      exprs = import file ({ cwd = cwd; } // scope);
      result = b.foldl' (state: edit:
        applyEditIFD state.text scope cwd state.adjustments edit exprs
      ) {
        text = ast.text;
        adjustments = [];
      } indexed.edits;
    in
      result.text;
in {
  inherit renderTemplate renderTemplateIFD;
}
