# YAML node properties: anchors, aliases and tags.
#
# These are opt-in features, controlled by the parser options:
#
#   enableAnchors :: Bool   -- allow "&name" and "*name"
#   tags          :: AttrSet -- the handlers of the tags; the tags are
#                               allowed when the map is not empty
#
# Anchors and aliases are resolved eagerly: when an alias is encountered
# the referenced node is looked up and substituted directly. This means
# recursive structures are not supported, but everything else is.
#
# Tags are recorded on the node as `tag` and applied when the document
# is converted to its final representation.

{ state, spaces, scalars, tags }:

with state;

let
  b = builtins;

  # The characters allowed in an anchor name.
  #
  # An anchor name may hold any character except whitespace and the flow
  # indicators, so that a non-ASCII name is allowed too.
  isAnchorChar = c:
    c != " "
    && c != "\t"
    && c != "\n"
    && c != "\r"
    && c != ","
    && c != "["
    && c != "]"
    && c != "{"
    && c != "}";

  # The characters allowed in a tag.
  isTagChar = c:
    (c >= "a" && c <= "z")
    || (c >= "A" && c <= "Z")
    || (c >= "0" && c <= "9")
    || c == "-"
    || c == "_"
    || c == "."
    || c == ":"
    || c == "/"
    || c == "\\"
    || c == "%"
    || c == "!";

  # The options controlling the opt-in features.
  opts = s: s.opts or {};

  anchorsEnabled = s: (opts s).enableAnchors or false;

  # The tags are understood when the caller gave a map of handlers for
  # them. The map is null by default, and then there are no tags at
  # all: "!foo bar" is the plain text it looks like.
  tagsEnabled = s: b.isAttrs ((opts s).tags or null);

in rec {
  inherit isAnchorChar isTagChar anchorsEnabled tagsEnabled;

  # ------------------------------------------------------------------
  # Anchors
  # ------------------------------------------------------------------

  # Parse "&name".
  anchorName = s:
    let
      str = s.str;
      maxEnd = s.offset + s.len;
      go = i:
        if i >= maxEnd then i
        else if isAnchorChar (b.substring i 1 str) then go (i + 1)
        else i;
      end = go (s.offset + 1);
      name = b.substring (s.offset + 1) (end - s.offset - 1) str;
    in if name == ""
      then failWith "yaml.anchor" "expected an anchor name after '&'" s
      else [name (s // { offset = end; len = s.len - (end - s.offset); })];

  # Parse "*name" and return the node it refers to.
  alias = s:
    let
      str = s.str;
      maxEnd = s.offset + s.len;
      go = i:
        if i >= maxEnd then i
        else if isAnchorChar (b.substring i 1 str) then go (i + 1)
        else i;
      end = go (s.offset + 1);
      name = b.substring (s.offset + 1) (end - s.offset - 1) str;
      in if name == ""
        then failWith "yaml.alias" "expected an alias name after '*'" s
        else if ! (s.anchors ? ${name})
          # The anchor is not known. Note that an anchor may refer to an
          # empty node, so the presence of the name is checked, not its
          # value.
          then failWith "yaml.alias" "unknown alias '*${name}'" s
          else let
            node = lookupAnchor name s;
          in [node (s // { offset = end; len = s.len - (end - s.offset); })];

  # ------------------------------------------------------------------
  # Tags
  # ------------------------------------------------------------------

  # Parse "!tag". Handles "!!tag", "!tag", "!handle!tag" and "!<verbatim>".
  tagName = s:
    let
      str = s.str;
      maxEnd = s.offset + s.len;

      # A verbatim tag: "!<...>".
      verbatim =
        let
          isVerbatim = s.len >= 2 && (b.substring (s.offset + 1) 1 str) == "<";
          go = i:
            if i >= maxEnd then null
            else if (b.substring i 1 str) == ">" then i else go (i + 1);
          end = go (s.offset + 2);
        in if ! isVerbatim
          then null
          else if end == null
            then failWith "yaml.tag" "unterminated verbatim tag" s
            else [
              (b.substring (s.offset + 2) (end - s.offset - 2) str)
              (s // { offset = end + 1; len = s.len - end - 1 + s.offset; })
            ];

      # The name of the tag. The leading '!' is not part of it, so that
      # "!!str" gives the name "!!str" and "!foo" gives "!foo".
      go = i:
        if i >= maxEnd then i
        else if isTagChar (b.substring i 1 str) then go (i + 1)
        else i;
      end = go (s.offset + 1);
      name = b.substring s.offset (end - s.offset) str;

      # Resolve a tag handle to the tag it stands for.
      #
      # A handle is "!!" or "!name!", and it stands for the prefix that
      # was given for it in a %TAG directive. A tag that does not start
      # with a handle is a local tag and is left alone.
      #
      # The result is an attribute set with a `tag` attribute, or a
      # failure. A bare string cannot be used to tell the two apart,
      # because the resolved tag is itself a string.
      resolve = name:
        let
          handles = s.tagHandles or {};

          # The position of the second '!' of a named handle.
          named =
            let
              go2 = i:
                if i >= b.stringLength name then null
                else if b.substring i 1 name == "!" then i else go2 (i + 1);
            in go2 1;

          handle =
            if b.substring 0 2 name == "!!"
            then "!!"
            else if named == null then "!"
            else b.substring 0 (named + 1) name;

          suffix =
            if handle == null
            then ""
            else b.substring (b.stringLength handle) (b.stringLength name - b.stringLength handle) name;
        in
          if handles ? ${handle}
          then { tag = handles.${handle} + suffix; }
          else if named == null
            # The primary handle "!" needs no %TAG directive of its own;
            # a tag that does not name a handle is a local tag, and is
            # left alone.
            then { tag = name; }
            # A named handle that no %TAG directive defines is an error.
            else failWith "yaml.tag" "undefined tag handle '${handle}'" s;
    in
      if verbatim != null
      then verbatim
      else if name == "!"
        # A lone '!' is the non-specific tag: it asks for the default
        # schema, which is what the core schema does anyway.
        then [ name (s // { offset = end; len = s.len - (end - s.offset); }) ]
      else
        let
          res = resolve name;
        in
          if res ? tag
          then [ res.tag (s // { offset = end; len = s.len - (end - s.offset); }) ]
          else res;

  # ------------------------------------------------------------------
  # Properties
  # ------------------------------------------------------------------

  # Parse the properties that precede a node: "&anchor" and "!tag".
  #
  # The result is [props, state]:
  #
  #   props :: a list of { kind; name; line; offset; }, one entry for
  #           each property, in the order they were found
  #   state :: the state positioned after the properties
  #
  # `crossLines` says whether a line break may separate the properties
  # from each other. In block context it may: the properties of a node
  # are all the properties that precede it, even when they are on
  # separate lines.
  properties = skip: crossLines: st:
    let
      # The whitespace in front of the next property.
      skipProp = st':
        if crossLines
        then b.elemAt (spaces.skipToContent st') 1
        else b.elemAt (skip st') 1;

      go = st': acc:
        let
          st1 = skipProp st';
          c = b.substring st1.offset 1 st1.str;
          isAnchor = (c == "&") && (anchorsEnabled st1);
          isTag = (c == "!") && (tagsEnabled st1);
        in
          if isAnchor
          then let
            res = anchorName st1;
          in
            if failed res
            then res
            else go (b.elemAt res 1) (acc ++ [ {
              kind = "anchor";
              name = b.elemAt res 0;
              line = lineStartOf st1.str st1.offset;
              offset = st1.offset;
            } ])
          else if isTag
          then let
            res = tagName st1;
          in
            if failed res
            then res
            else go (b.elemAt res 1) (acc ++ [ {
              kind = "tag";
              name = b.elemAt res 0;
              line = lineStartOf st1.str st1.offset;
              offset = st1.offset;
            } ])
          else [acc st1];
    in
      go st [];

  # Apply the properties to a node: attach the tag to it and register
  # the anchor, so that later aliases can find it.
  #
  # The result is [node, state].
  #
  # Only the last tag and the last anchor are used: a node may have
  # only one of each.
  applyProperties = props: node: st:
    let
      anchor = b.foldl' (acc: p: if p.kind == "anchor" then p.name else acc) null props;
      tag = b.foldl' (acc: p: if p.kind == "tag" then p.name else acc) null props;
      # The property that holds the tag, so that an error about the
      # content of the node can point at the tag.
      tagProp = b.foldl' (acc: p: if p.kind == "tag" then p else acc) null props;
      # The content of the node, for the check of the tag.
      content =
        if node == null then ""
        else if node.type == "scalar" then node.text
        else null;
      # Does the content fit the tag?
      #
      # A tag of the core schema says what the content has to look
      # like, and a content that does not fit is an error: the tag is
      # recognised, and a node with a recognised tag and content that
      # does not satisfy it is not valid, and cannot be turned into a
      # value (see section 3.3.3 of the specification).
      problem =
        if tag == null || content == null then null
        else tags.check (opts st).tags tag content;
      # The value of the node, when the tag gives one.
      #
      # The handler of the tag is called while the document is parsed,
      # so that a handler that does not like the content of the node is
      # reported right away, and with the place where the node is. The
      # value it gives is kept on the node, so that the handler is not
      # called twice.
      #
      # A tag that nobody knows has no handler: the content of the node
      # is then kept as the text it is.
      handlers' = tags.handlers (opts st).tags;
      handler = if tag == null then null else handlers' tag;
      tagged =
        if handler == null then [ null null ]
        else tags.call handler tag content;
      value = b.elemAt tagged 0;
      failure = b.elemAt tagged 1;
      # The node, with its tag and the value that the tag gave.
      n =
        if tag == null then node
        else
          let
            # An empty node cannot carry a tag, so a tagged empty node
            # becomes an empty scalar.
            base =
              if node == null
              then { type = "scalar"; text = ""; quoted = true; }
              else node;
          in
            base // { inherit tag; }
              // (if handler == null then { } else { tagValue = value; });
    in
      if problem != null
      then failWith "yaml.tag" problem (stateAt st tagProp.offset)
      else if failure != null
      then failWith "yaml.tag" failure (stateAt st tagProp.offset)
      else if anchor == null
      then [n st]
      else [n (defineAnchor anchor n st)];

  # ------------------------------------------------------------------
  # Combined handling
  # ------------------------------------------------------------------

  # Parse a node that may be preceded by properties: "&anchor", "!tag"
  # and "*alias".
  #
  # The node parser is passed in, so that this module does not depend on
  # the block/flow parsers. It is called as `node indent state`, where
  # `indent` is the indentation of the enclosing block.
  #
  #   :: (Int -> YamlParser Node) -> YamlParser Node
  withProperties = node: indent: skip: s:
    let
      # The properties of this node.
      pres = properties skip false s;
    in
      if failed pres
      then pres
      else let
        props = b.elemAt pres 0;
        st = b.elemAt pres 1;

        # The width of the properties, and the line they are on.
        #
        # The properties do not shift the indentation of the node they
        # belong to: a mapping whose first key is introduced by a tag
        # starts at the indentation of the line, not at the column of
        # the key. The width is needed to work that out.
        propsInfo =
          let
            ls = lineStartOf s.str s.offset;
            sameLine = ls == lineStartOf s.str st.offset;
          in {
            propsWidth = if sameLine then st.offset - s.offset else 0;
            propsLine = ls;
          };

        # The node itself, once the properties have been consumed.
        #
        # The state records whether the node is an alias: the name of an
        # alias may end in a colon, which is then the mapping indicator
        # that follows the key.
        parseNode = st:
          let
            c = b.substring st.offset 1 st.str;
          in
            if c == "*" && (anchorsEnabled st)
            then
              # An alias stands alone; it cannot have further properties.
              let
                ares = alias st;
              in
                if failed ares
                then ares
                else [ (b.elemAt ares 0) ((b.elemAt ares 1) // { isAlias = true; }) ]
            else if isAtEnd st || c == "," || c == "]" || c == "}"
              then
                # An empty node: the properties are all there is.
                [ { type = "scalar"; text = ""; quoted = true; } (st // { isAlias = false; }) ]
            else node indent (st // { isAlias = false; });
      in
        let
          nres = parseNode (st // propsInfo);
        in
          if failed nres
          then nres
          # An alias stands for a whole node, so there is nothing for a
          # property to attach to: "&name *other" is not a node that the
          # anchor names. The error is about the alias, so it points at
          # the '*' that starts it.
          else if props != [] && (b.elemAt nres 1).isAlias or false
          then failWith "yaml.alias" "an alias may not carry a property" (stateAt (b.elemAt nres 1) st.offset)
          else applyProperties props (b.elemAt nres 0) (b.elemAt nres 1);
}
