# The node parser: the central dispatch of the YAML grammar.
#
# A "node" is any YAML value: a scalar, a collection, an alias, or a
# tagged node. This module ties the block and flow parsers together,
# because they are mutually recursive: a block mapping may contain a
# flow collection, and a flow collection may contain nested flow
# collections.
#
# There are two levels of node parser:
#
#   raw   -- parses the node itself, without any "&anchor" / "!tag" /
#            "*alias" prefix
#   node  -- the same, but handling the optional properties first
#
# The signatures are:
#
#   raw.blockContent :: Int -> State -> Result
#   raw.flowContent  :: Int -> State -> Result
#   raw.block        :: Int -> State -> Result   (with properties)
#   raw.flow         :: Int -> State -> Result   (with properties)
#
# The flow collections take a node parser that takes only a state, since
# the indentation is not significant in flow context.

{ state, spaces, scalars, flowMod, blocks, anchors }:

let
  b = builtins;

  # The raw node parsers.
  raw = {
    # A node in flow context, with any properties handled.
    flow = indent: s:
      anchors.withProperties raw.flowContent indent spaces.flowSpace s;

    # The content of a flow node, without any properties.
    flowContent = indent: s:
      let
        c = b.substring s.offset 1 s.str;
      in if c == "["
        then flowMod.flowSeq (raw.flow indent) s
        else if c == "{"
          then flowMod.flowMap (raw.flow indent) s
          else if c == "\"" || c == "'"
            then scalars.quotedNode null false s
            else if c == "|" || c == ">"
              then scalars.blockNode indent s
              else scalars.plainFlowNode s;

    # A node in block context.
    #
    # The properties are handled by the block dispatch itself: in a
    # block mapping they may belong to the first key rather than to the
    # node, and only the dispatch can tell.
    block = indent: s:
      blocks.blockNode raw indent s;

    # The content of a block node, without any properties.
    blockContent = indent: s:
      blocks.blockNode raw indent s;
  };

in {
  # The node of a document, which has no enclosing block collection.
  documentNode = blocks.documentNode raw;
}
