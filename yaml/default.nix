# YAML 1.2 parser built on nix-parsec.
#
# Usage:
#
#   let
#     yaml = import ./yaml;
#   in
#   yaml.safeParse { } "key: value"
#
# The result is either
#
#   { type = "success"; value = <the document>; }
#   { type = "error";   value = { context; msg; offset; }; }
#
# The document is converted to Nix-native values:
#
#   - a mapping becomes an attribute set (keys are converted to strings)
#   - a sequence becomes a list
#   - a scalar becomes a string, integer, float, boolean or null
#
# Note that attribute sets are unordered and cannot have duplicate keys,
# so a mapping with duplicate keys is an error.

let
  parsec = (import ../deps.nix).parsec;
  style = import ../utils/style.nix;
  stringMultiply = str: size:
    b.concatStringsSep "" (b.genList (_: str) size);

  state = import ./state.nix { inherit parsec; };
  spaces = import ./spaces.nix { inherit state; };
  scalars = import ./scalars.nix { inherit state spaces; };
  tags = import ./tags.nix { inherit scalars; };
  anchors = import ./anchors.nix { inherit state spaces scalars tags; };
  flow = import ./flow.nix { inherit state spaces scalars anchors; };
  blocks = import ./blocks.nix { inherit state spaces scalars anchors; };
  nodes = import ./nodes.nix { inherit state spaces scalars blocks anchors; flowMod = flow; };
  docs = import ./docs.nix { inherit state spaces scalars blocks nodes; };

  b = builtins;

  # ------------------------------------------------------------------
  # Node -> Nix value
  # ------------------------------------------------------------------

  # The tags of the core schema, and the handlers of the tags.
  #
  # The core schema is part of YAML itself, so its tags are
  # understood when the caller asks for any tag at all. A caller that
  # wants another meaning for one of them says so, and the caller's
  # meaning is used.
  #
  # The `!!binary` tag is left out: its content is base64 encoded
  # binary data, which a Nix string cannot hold, so the text is kept
  # as it is. That is also the canonical representation of the tag.
  coreTags = tags.coreHandlers;

  # The failure of a tag handler.
  #
  # A handler that does not like the content of a node gives this
  # back, and the parser reports it as an error of the document, with
  # the place where the node is:
  #
  #   "!isfoo" = text: if text == "foo" then true else yaml.failWith "not foo";
  failWith = tags.failWith;

  # The handlers of the tags.
  #
  # A handler is given the text of the scalar and gives back the value
  # of the node. A tag that has no handler keeps the text, the way a
  # processor that does not know a tag would treat it.
  #
  # The tags of the caller are looked up by their full name
  # ("tag:example.com,2000:app/foo") and then by their short one
  # ("!foo"). The tags of the core schema are under the caller's, so
  # that a caller who adds a tag of their own does not have to repeat
  # the ones of the core schema.
  #
  # The result is a function that takes the name of a tag and gives
  # back its handler, or null when there is none.
  tagHandlers = tags.handlers;

  # Apply a tag to a scalar's raw text.
  applyTag = handlers: tag: text:
    let
      h = if tag == null then null else handlers tag;
    in
      if h == null then text else h text;

  # Whether an entry is the merge key.
  #
  # The merge key is a plain scalar whose text is exactly "<<". A quoted
  # "<<" is an ordinary key, and so is a key that merely starts with
  # "<<".
  isMergeKey = e:
    e.k.type == "scalar"
    && ! (e.k.quoted or false)
    && e.k.text == "<<";

  # The entries that a merge key brings in.
  #
  # The value of a merge key is a mapping, or a sequence of mappings. The
  # entries of a sequence are taken in order, and the first one that has
  # a key wins over the ones after it.
  #
  # The result is null when the value is not of that shape.
  mergeEntries = e:
    let
      one = m:
        if m.type == "map"
        then m.entries
        else null;
      fromSeq = s:
        let
          go = i: acc:
            if i >= b.length s.items
            then acc
            else
              let
                m = one (b.elemAt s.items i);
              in
                if m == null
                then null
                else go (i + 1) (acc ++ m);
        in go 0 [];
    in
      if e.v.type == "map"
      then one e.v
      else if e.v.type == "seq"
      then fromSeq e.v
      else null;

  # Convert a parsed node into a Nix value.
  #
  # The merge key is not honoured here; use `toValueWithMerge` for that.
  toValue = node: toValueWith coreTags false node;

  # Convert a parsed node into a Nix value, honouring the merge key
  # when the flag says so.
  #
  # The merge key is a construct of YAML 1.1 that YAML 1.2 left out of
  # its core schema, so it is off by default.
  toValueWithMerge = merge: node: toValueWith coreTags merge node;

  # Convert a parsed node into a Nix value, with the handlers of the
  # tags and the flag for the merge key.
  #
  # The handlers are a map of the tags of the document: the text of a
  # node with a tag is given to the handler of that tag, and what the
  # handler gives back is the value of the node. The tags of the core
  # schema are understood as well, unless the map says otherwise.
  toValueWith = handlers: merge: node:
    convert (tagHandlers handlers) merge node;

  # Convert a parsed node into a Nix value.
  #
  # The handlers are a function that takes the name of a tag and gives
  # back its handler. It is worked out once and passed on, so that the
  # conversion of a whole document does not work it out again for every
  # node.
  convert = handlers: merge: node:
    if ! (b.isAttrs node)
    then null
    else if node.type == "scalar"
    then
      let
        tag = node.tag or null;
      in
        if tag != null
        # A node that the parser gave a value has one already: the
        # handler of the tag was called while the document was parsed,
        # so that a failure of the handler could be reported with the
        # place where the node is.
        then if node ? tagValue then node.tagValue
          else applyTag handlers tag node.text
        else if node.quoted then node.text
        else scalars.resolvePlain node.text
    else if node.type == "seq"
    then b.map (convert handlers merge) node.items
    else if node.type == "map"
    then
      let
        # The entries that the merge keys bring in, and the ones that
        # the mapping itself holds.
        merges = if merge then b.filter isMergeKey node.entries else [];
        merged =
          if merges == []
          then []
          else
            let
              go = i: acc:
                if i >= b.length merges
                then acc
                else
                  let
                    m = mergeEntries (b.elemAt merges i);
                  in
                    if m == null
                    then null
                    else go (i + 1) (acc ++ m);
              r = go 0 [];
            in
              # The parser has already made sure that the value of a
              # merge key is a mapping, or a sequence of mappings, so this
              # cannot fail.
              if r == null
              then []
              else r;
        # When the merge key is not honoured it is an ordinary key, and
        # stays in the mapping.
        own = if merge
              then b.filter (e: ! (isMergeKey e)) node.entries
              else node.entries;
        # The mapping's own entries come first, so that a key that it
        # holds itself wins over one that a merge brought in. The merged
        # entries follow in the order they were merged in, so that the
        # first of them wins over the ones after it.
        entries = b.map (e: {
          name = keyToString e.k;
          value = convert handlers merge e.v;
        }) (own ++ merged);
      in b.listToAttrs entries
    else throw "yaml: unknown node type '${node.type}'";

  # A mapping key is always converted to a string. The *text* of the key
  # is used, so that a key such as "null" keeps its spelling instead of
  # becoming the empty string.
  keyToString = key:
    if key.type == "scalar"
    then key.text
    else throw "yaml: mapping keys must be scalars";

  # ------------------------------------------------------------------
  # Entry points
  # ------------------------------------------------------------------

  # Report that a document could not be parsed.
  #
  # The message is added to the error as a trace, so that the caller
  # sees that the document was being parsed when it went wrong. The throw
  # is inside a function, because the context is added to an error that
  # is already being thrown, and not to one that is raised while the
  # arguments of a call are evaluated.
  fail = msg:
    b.addErrorContext "while parsing a YAML document" (b.throw msg);

  # The error of a document that could not be parsed, as a message.
  #
  # The message says what went wrong, and shows where it went wrong:
  # the number of the line, the lines around it, and a mark under the
  # character, the way Nix itself points at the place in an expression
  # that it does not like.
  #
  # The error holds the offset of the character it is about, together
  # with the line and the column of that character, so the message only
  # has to find the lines around it.
  errorMessage = str: e:
    let
      offset = e.offset or 0;
      len = b.stringLength str;

      # The line and the column of the error.
      #
      # The error holds them when it comes from the parser. An error
      # that was made up by hand may not, and then they are worked out
      # from the offset.
      pos =
        if e ? line && e ? col
        then { line = e.line; col = e.col; }
        else state.positionAt str offset;
      line = pos.line;
      col = pos.col;

      # The lines of the document.
      #
      # The document is split into its lines in one go, which is much
      # cheaper than walking it a character at a time.
      lines = state.splitAt "[\n]" str;

      # The line the error is on, and the lines around it.
      here = b.elemAt lines (line - 1);
      prev = if line > 1 then b.elemAt lines (line - 2) else null;
      next = if line < b.length lines then b.elemAt lines line else null;

      # The lines to show: the one before, the one the error is on, and
      # the one after.
      #
      # Only one line on each side is shown, so that the message stays
      # short. A line that is empty at the end of the document says
      # nothing, so it is left out. When the error is at the end of the
      # input, the line it falls on is empty, and the line before it
      # takes its place, since that is where the document went wrong.
      atEnd = offset >= len && here == "";
      shown =
        if atEnd && prev != null
        then [ { no = line - 1; text = prev; } ]
             ++ (if next == null || next == "" then [] else [ { no = line + 1; text = next; } ])
        else
          (if prev == null then [] else [ { no = line - 1; text = prev; } ])
          ++ [ { no = line; text = here; } ]
          ++ (if next == null || next == "" then [] else [ { no = line + 1; text = next; } ]);
      # The line the mark goes under. It is the line the error is on,
      # unless that line is empty, in which case it is the line before.
      shownAt = if atEnd && prev != null then line - 1 else line;

      getDigit = i: b.stringLength (toString i);

      # The width of the column the line numbers are shown in.
      #
      # The numbers are put in a column, so that the marks under them
      # line up. The column is as wide as the largest number that is
      # shown, plus one space.
      numWidth = getDigit ((b.elemAt shown (b.length shown - 1)).no) + 1;

      # The column the text of a line starts in.
      start = numWidth + 2;

      # The mark under the character, with the tabs before it widened so
      # that the two line up.
      mark =
        let
          # The line the mark goes under, and the column it is at.
          text = if atEnd && prev != null then prev else here;
          markCol = if atEnd && prev != null then b.stringLength text else col;

          # The width of the text in front of the mark, as it is shown.
          #
          # A tab is shown as the room up to the next multiple of
          # eight, which is what a terminal does with it, so that the
          # mark lines up with the text.
          width =
            let
              go = ps: w:
                if ps == [] then w
                else
                  let
                    p = b.elemAt ps 0;
                    rest = b.tail ps;
                    # The column the text ends in.
                    w' = w + b.stringLength p;
                  in
                    if rest == []
                    then w'
                    # A tab goes up to the next multiple of eight.
                    else go rest (w' + (8 - (w' - (w' / 8) * 8)));
            in go (state.splitAt "[\t]" (b.substring 0 markCol text)) start;
        in
          stringMultiply " " (width - start) + "${style.red "^"} ${style.magenta e.msg}";

      # The lines, with their numbers.
      show = l:
        let
          no = toString l.no;
        in
          stringMultiply " " (numWidth - getDigit no) + no + "| " + l.text;
    in
      "${style.red e.context}\n"
      # The mark goes under the line the error is on, so the lines are
      # shown one by one and the mark is put in after the right one.
      + b.concatStringsSep "\n" (
          b.map
            (l: show l + (if l.no == shownAt then "\n" + stringMultiply " " numWidth + "| " + mark else ""))
            shown
        );
  # Parse a YAML string.
  #
  # The result is either
  #
  #   { type = "success"; value = <the document>; }
  #   { type = "error";   value = { context; msg; offset; }; }
  #
  # Options:
  #   enableAnchors   :: Bool   -- allow "&name" and "*name" (default: false)
  #   tags            :: AttrSet -- the handlers of the tags (default: null)
  #   enableMergeKeys :: Bool   -- honour the "<<" merge key (default: false)
  safeParse = { enableAnchors ? false, tags ? null, enableMergeKeys ? false }: str:
    let
      s = state.mkState str {
        inherit enableAnchors enableMergeKeys;
        inherit tags;
      };
      res = docs.stream s;
      toValue' = convert (tagHandlers tags) enableMergeKeys;
    in if tags != null && ! b.isAttrs tags
      then throw "yaml: the tags must be an attribute set of handlers"
      else if state.failed res
      then { type = "error"; value = res; }
      else
        let
          docs' = b.elemAt res 0;
        in
          if b.length docs' == 0
          then { type = "success"; value = null; }
          else if b.length docs' == 1
          then { type = "success"; value = toValue' (b.elemAt docs' 0); }
          else
            { type = "success"; value = b.map toValue' docs'; };

  # Parse a YAML string and return the list of documents it contains.
  safeParseStream = { enableAnchors ? false, tags ? null, enableMergeKeys ? false }: str:
    let
      s = state.mkState str {
        inherit enableAnchors enableMergeKeys;
        inherit tags;
      };
      res = docs.stream s;
      toValue' = convert (tagHandlers tags) enableMergeKeys;
    in if tags != null && ! b.isAttrs tags
      then throw "yaml: the tags must be an attribute set of handlers"
      else if state.failed res
      then { type = "error"; value = res; }
      else { type = "success"; value = b.map toValue' (b.elemAt res 0); };

  # Parse a single YAML document, and give it back.
  #
  # It takes the options and the document, or just the document, in which
  # case the default options are used. The default options are no
  # anchors, no tags and no merge keys.
  #
  # The result is the document itself. A document that cannot be parsed
  # is thrown as an error, with a message that says what went wrong and
  # where, and with a trace that says the document was being parsed.
  parse = opts: str:
    let
      res = safeParse opts str;
    in
      if res.type == "error"
      then fail (errorMessage str res.value)
      else res.value;

  # Parse a single YAML document with the default options.
  parseDefault = str: parse { } str;

in {
  inherit safeParse safeParseStream parse parseDefault toValue toValueWithMerge toValueWith errorMessage;

  # The tags of the core schema, and the handlers of the tags.
  #
  # The core schema is understood on its own, so a caller who wants the
  # tags of the core schema and one of their own says:
  #
  #   tags = yaml.coreTags // { "!date" = text: ...; }
  #
  # A caller who only wants a tag of their own may leave the core
  # schema out: it is understood anyway when the map is not empty.
  inherit coreTags tagHandlers failWith;

  # The underlying modules, exposed for reuse.
  modules = {
    inherit state spaces scalars anchors flow blocks nodes docs;
  };
}
