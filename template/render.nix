{ nix }:
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

  renderSegments = segments: cwd: scope:
    b.concatStringsSep "" (b.map (segment:
      if segment.type == "literal"
      then segment.text
      else renderValue (nix.evalAst {
        ast = segment.ast;
        inherit cwd scope;
      })
    ) segments);
in {
  inherit renderValue renderSegments;
}
