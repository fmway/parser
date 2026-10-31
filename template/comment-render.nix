{ commentParser, helpers, nix, render, errors, strings, stringsPath, helpersPath }:
let
  b = builtins;
  inherit (import ../utils) do;

  scopeFor = scope: context:
    helpers // scope // { inherit context; };

  adjustmentFor = edit: adjustments:
    b.foldl' (total: adjustment:
      if adjustment.offset >= edit.targetStart && adjustment.offset < edit.targetEnd
      then total + adjustment.delta
      else total
    ) 0 adjustments;

  transformValue = ast: expression: current: cwd: scope: location: text:
    # The value of the expression is computed inside the parentheses,
    # so that the error of the evaluation is raised inside of them and
    # the context of the template is shown with it.
    builtins.addErrorContext (errors.errorMessage text
      (errors.evaluationError "template.v2" expression location)
    ) (render.renderValue (do (nix.evalAst { inherit ast cwd; scope = scopeFor scope current; }) current));

  applyEdit = text: scope: cwd: adjustments: edit: let
    adjustedEnd = edit.targetEnd + adjustmentFor edit adjustments;
    current =
      if adjustedEnd < edit.targetStart then ""
      else b.substring edit.targetStart (adjustedEnd - edit.targetStart) text;
    replacement =
      if edit.type == "rawBlock" || edit.type == "rawNext" then current
      else if edit.type == "nextChain" then
        let
          go = i: ctx:
            if i >= b.length edit.asts then ctx
            else let
              ast = b.elemAt edit.asts i;
              expression = b.elemAt edit.expressions i;
              location = b.elemAt edit.expressionStarts i;
              next = transformValue ast expression ctx cwd scope location text;
            in go (i + 1) next;
        in go 0 current
      else transformValue edit.ast edit.expression current cwd scope edit.expressionStart text;
    finalReplacement =
      if edit.type == "blockOpen" && current == "" && replacement != "" && !(b.substring (b.stringLength replacement - 1) 1 replacement == "\n") then
        replacement + "\n"
      else replacement;
    updated =
      b.substring 0 edit.targetStart text
      + finalReplacement
      + b.substring adjustedEnd (b.stringLength text - adjustedEnd) text;
    originalLength = edit.targetEnd - edit.targetStart;
    delta = b.stringLength finalReplacement - originalLength;
  in {
    text = updated;
    adjustments = adjustments ++ [{
      offset = edit.targetStart;
      inherit delta;
    }];
  };

  renderTemplate = ast: cwd: scope: let
    edits = b.concatMap (node: commentParser.collectEdits ast.index node 0) ast.roots;
    sorted = b.sort (a: c:
      if a.targetStart != c.targetStart then
        a.targetStart > c.targetStart
      else a.depth > c.depth
    ) edits;
    result = b.foldl' (state: edit:
      applyEdit state.text scope cwd state.adjustments edit
    ) {
      text = ast.text;
      adjustments = [];
    } sorted;
  in result.text;
in {
  inherit renderTemplate;
}
