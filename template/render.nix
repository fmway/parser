{ nix, errors }:
let
  b = builtins;

  renderValue = value:
    if b.isString value
    then value
    else if b.isPath value
    then b.toString value
    else if b.isInt value || b.isFloat value || b.isBool value || value == null
    then b.toString value
    else if b.isList value
    then b.toJSON value
    else if b.isAttrs value
    then if value ? __toString then b.toString value else b.toJSON value
    else b.toString value;

  renderSegments = text: segments: cwd: scope:
    b.concatStringsSep "" (b.map (segment:
      if segment.type == "literal"
      then segment.text
      else
        builtins.addErrorContext (errors.errorMessage text
          (errors.evaluationError "template.v1" segment.expression segment.expressionStart)
        ) (renderValue (nix.evalAst {
          ast = segment.ast;
          inherit cwd scope;
        }))
    ) segments);
in {
  inherit renderValue renderSegments;
}
