# YAML block collections: mappings and sequences.
#
# Block context is indentation-sensitive, so the parser works with the
# concept of an "indent level" (a column) and decides what to parse by
# looking ahead at the content.
#
# The central idea:
#
#   blockMapping :: Int -> YamlParser Node
#
# parses a mapping whose keys are at column `indent`. Similarly,
# blockSequence parses a sequence whose entries are at column `indent`.
#
# To tell a mapping from a scalar we need to look at the *whole* logical
# key: a plain scalar in block context cannot contain ": ", so if we find
# a ": " (or ":" at end of line) before the end of the first line, the
# node is a mapping.
#
# Two shapes need extra care:
#
#   - "compact" notation, where a nested collection starts on the same
#     line as its parent ("- key: value")
#   - values that continue on the following lines, where the indent of
#     the value is not known until we look at the next line
#
# The `node` parser is passed in, since block and flow contexts are
# mutually recursive.

{ state, spaces, scalars, anchors }:

with state;

let
  b = builtins;
  concat = b.concatStringsSep "";

  # ------------------------------------------------------------------
  # Look-ahead helpers
  # ------------------------------------------------------------------

  # Does the content at `s` start a block sequence entry? That is, is the
  # next character '-' followed by a space or a tab (or the end of the
  # line)?
  atSequenceEntry = s:
    s.len >= 1
    && b.substring s.offset 1 s.str == "-"
    && (s.len == 1
         || b.substring (s.offset + 1) 1 s.str == " "
         || b.substring (s.offset + 1) 1 s.str == "\t"
         || b.substring (s.offset + 1) 1 s.str == "\n"
         || b.substring (s.offset + 1) 1 s.str == "\r");

  # The indentation of the content at `s`.
  #
  # The properties of a node (an anchor or a tag) do not shift the
  # indentation of the node: a mapping whose first key is introduced by
  # a tag starts at the indentation of its line, not at the column of
  # the key. The state records how wide the properties are, so that
  # they can be taken into account.
  effectiveIndent = s:
    let
      col = columnAt s.str s.offset;
      width = s.propsWidth or 0;
      line = s.propsLine or (-1);
    in
      if line >= 0 && lineStartOf s.str s.offset == line
      then col - width
      else col;

  # Does the content at `s` start an explicit key ("?")? The '?' is only
  # an indicator when it is followed by a space or the end of the line.
  atExplicitKey = s:
    s.len >= 1
    && b.substring s.offset 1 s.str == "?"
    && (s.len == 1
        || b.substring (s.offset + 1) 1 s.str == " "
        || b.substring (s.offset + 1) 1 s.str == "\n"
        || b.substring (s.offset + 1) 1 s.str == "\r");

  # Find a "key:" indicator on the current line.
  #
  # Returns the offset of the ':' if the current line contains a mapping
  # key, or null otherwise. Only the first line of the node is examined:
  # a plain scalar never spans lines in block context when used as a
  # key, and a mapping's key is always on the first line.
  #
  # Quoted scalars are skipped over so that '"a: b": c' is detected
  # correctly. A ':' only counts as an indicator when it is followed by a
  # space or the end of the line.
  #
  # The name of an alias may end in a colon, which is then part of the
  # name and not an indicator, so the name is skipped over.
  # The number of mapping indicators on the current line.
  #
  # A ':' is an indicator when a space or a tab follows it. A quoted
  # The mapping indicators on the current line.
  #
  # A ':' is an indicator when a space or a tab follows it. A quoted
  # scalar may hold one, and so may the name of an anchor, so both are
  # stepped over.
  #
  # The result is the list of the offsets of the indicators, in the
  # order in which they appear on the line. The offsets are what an
  # error about a line needs: it has to point at the indicator that
  # made the line a mistake.
  keyColonOffsets = s:
    let
      str = s.str;
      # Only the line that the state is on is looked at.
      le = scalars.nextLineAt str s.offset (s.offset + s.len);
      max = if le > s.offset + s.len then s.offset + s.len else le;
      at = i: b.substring i 1 str;

      # The end of the name of an anchor that starts at `i`.
      nameEnd = i:
        let
          go = j:
            if j >= max then j
            else if anchors.isAnchorChar (at j) then go (j + 1)
            else j;
        in go (i + 1);

      go = i: acc: q:
        if i >= max then acc
        else let c = at i; in
          if q == "\""
          then if c == "\\" then go (i + 2) acc "\""
               else if c == "\"" then go (i + 1) acc null
               else go (i + 1) acc "\""
          else if q == "'"
          then if c == "'" then go (i + 1) acc null
               else go (i + 1) acc "'"
          else if c == "\"" then go (i + 1) acc "\""
          else if c == "'" then go (i + 1) acc "'"
          else if c == "&" then
            # The name of an anchor may hold a colon, which is then
            # part of the name and not an indicator.
            go (nameEnd i) acc null
          else if c == "#" then acc
          else if c == ":" then
            (if i + 1 >= max then acc ++ [ i ]
             else let nc = at (i + 1); in
               if nc == " " || nc == "\t" then go (i + 1) (acc ++ [ i ]) null
               else go (i + 1) acc null)
          else go (i + 1) acc null;
    in go s.offset [] null;

  # The number of mapping indicators on the current line.
  countKeyColons = s: b.length (keyColonOffsets s);

  findKeyColon = s:
    let
      str = s.str;
      max = s.offset + s.len;

      # Whether a '*' at the start of the line is an alias. When the
      # anchors are not enabled it is an ordinary character, and the
      # colon that follows it is a key indicator like any other.
      aliasAt = i:
        i == s.offset && (anchors.anchorsEnabled s);

      # The end of an alias name that starts at `i`.
      aliasEnd = i:
        let
          go = j:
            if j >= max then j
            else if anchors.isAnchorChar (b.substring j 1 str) then go (j + 1)
            else j;
        in go (i + 1);

      go = i: inQuote:
        if i >= max then null
        else let c = b.substring i 1 str; in
          if inQuote == "\""
            then if c == "\\" then go (i + 2) "\""
                 else if c == "\"" then go (i + 1) null
                 else go (i + 1) "\""
            else if inQuote == "'"
              then if c == "'" then
                     (if i + 1 < max && b.substring (i + 1) 1 str == "'"
                       then go (i + 2) "'"
                       else go (i + 1) null)
                   else go (i + 1) "'"
              else if c == "\"" && i == s.offset then go (i + 1) "\""
              else if c == "'" && i == s.offset then go (i + 1) "'"
              else if c == "*" && (aliasAt i) then
                # An alias: its name may hold a colon, which is not an
                # indicator.
                go (aliasEnd i) null
              else if c == "#" then
                # A comment starts: no key indicator after it.
                (if i > s.offset && b.substring (i - 1) 1 str == " " then null else go (i + 1) null)
              else if c == "\n" || c == "\r" then null
              else if c == ":" then
                (if i + 1 >= max then i
                 else let nc = b.substring (i + 1) 1 str; in
                   if nc == " " || nc == "\t" || nc == "\n" || nc == "\r" then i
                   else go (i + 1) null)
              else go (i + 1) null;
    in go s.offset null;

in rec {
  inherit atSequenceEntry findKeyColon countKeyColons;

  # ------------------------------------------------------------------
  # Block mapping
  # ------------------------------------------------------------------

  # A block mapping whose keys are at column `indent`.
  #
  # Each entry is "key: value" on a line indented exactly `indent`.
  # The value may be:
  #   - empty (null)
  #   - on the same line (a scalar or a flow collection)
  #   - a nested block collection on following lines, indented further
  blockMapping = node: indent: s:
    let
      # Parse one entry: "key: value". The key is a plain or quoted
      # scalar, or a flow collection used as a complex key.
      entry = st:
        let
          # The key. A key may carry an anchor or a tag, which are
          # handled here, so that they are not part of its text.
          key = st1:
            let
              # The content of the key, once its properties are gone.
              content = _: s:
                let
                  c = b.substring s.offset 1 s.str;
                in
                  if c == "\"" || c == "'"
                  then scalars.quotedNode indent true s
                  else if c == "[" || c == "{"
                    then node.flow 0 s
                    else scalars.plainNode true indent s;
            in anchors.withProperties content indent spaces.skipSpaces st1;

          res = key st;

          isExplicitKey = atExplicitKey st;

          # An explicit key and its value.
          #
          # The key is a node: it is on the same line as the '?', or on
          # the lines below when the '?' stands alone. The value follows
          # a ':' on a line of its own, or it is empty.
          explicitEntry =
            let
              # The state after the '?'.
              st1 = st // { offset = st.offset + 1; len = st.len - 1; };
              st2 = spaces.skipSpacesTo st1;
              keyRes =
                if isAtEnd st2
                || b.substring st2.offset 1 st2.str == "\n"
                || b.substring st2.offset 1 st2.str == "\r"
                then
                  # The key is on the lines below.
                  blockValue node indent true st2
                else
                  # The key is on the same line.
                  inlineValue node indent true st2;
            in if failed keyRes
              then keyRes
              else let
                k = b.elemAt keyRes 0;
                st3 = b.elemAt keyRes 1;
                st4 = b.elemAt (spaces.skipToContent st3) 1;
              in if isAtEnd st4 || b.substring st4.offset 1 st4.str != ":"
                then
                  # The key has no value.
                  [(k) null st3]
                else
                  let
                    st5 = st4 // { offset = st4.offset + 1; len = st4.len - 1; };
                    st6 = spaces.skipSpacesTo st5;
                  in if isAtEnd st6
                    then [(k) null st6]
                    else if b.substring st6.offset 1 st6.str == "\n"
                           || b.substring st6.offset 1 st6.str == "\r"
                      then
                        # The value is on the lines below.
                        let
                          vres = blockValue node indent true st6;
                        in if failed vres
                          then vres
                          else [(k) (b.elemAt vres 0) (b.elemAt vres 1)]
                      else
                        # The value is on the same line.
                        let
                          vres = inlineValue node indent true st6;
                        in if failed vres
                          then vres
                          else [(k) (b.elemAt vres 0) (b.elemAt vres 1)];
        in if isExplicitKey
          then explicitEntry
          else if failed res
            then res
            else let
              k = b.elemAt res 0;
              st1 = b.elemAt res 1;
              # Skip spaces before the ':'
              st2 = spaces.skipSpacesTo st1;
            in if isAtEnd st2 || b.substring st2.offset 1 st2.str != ":"
              then
                if st1.isAlias or false
                then
                  # The key is an alias whose name ends in a colon, so
                  # the colon is the mapping indicator and there is no
                  # value.
                  [(k) null st2]
                else failWith "yaml.mapping" "expected ':' after mapping key" st2
              else let
                st3 = st2 // { offset = st2.offset + 1; len = st2.len - 1; };
                # Skip spaces after the ':'
                st4 = spaces.skipSpacesTo st3;
              in if isAtEnd st4
                then [(k) null st4]
                else if b.substring st4.offset 1 st4.str == "#"
                  # A comment follows the ':', so the value is on one of
                  # the following lines.
                  then
                    let
                      vres = blockValue node indent true st4;
                    in if failed vres
                      then vres
                      else [(k) (b.elemAt vres 0) (b.elemAt vres 1)]
                else if b.substring st4.offset 1 st4.str == "\n"
                       || b.substring st4.offset 1 st4.str == "\r"
                  then
                    # The value is on the following lines.
                    let
                      vres = blockValue node indent true st4;
                    in if failed vres
                      then vres
                      else [(k) (b.elemAt vres 0) (b.elemAt vres 1)]
                  else
                    # The value is on the same line.
                    let
                      vres = inlineValue node indent false st4;
                    in if failed vres
                      then vres
                      else [(k) (b.elemAt vres 0) (b.elemAt vres 1)];

      # Collect entries until the indentation drops below `indent`.
      #
      # The loop runs over a worklist rather than by recursion: Nix does
      # not optimise tail calls, so a recursive loop would use one stack
      # frame per entry and overflow on a long mapping.
      #
      # The worklist is written out here instead of using `state.iterate`,
      # because every extra function call costs a stack frame, and the
      # nesting of collections multiplies them: a document that nests a
      # few hundred levels deep would overflow the stack sooner.
      go = st:
        let
          work = b.genericClosure {
            startSet = [ { key = 0; stop = false; state = st; } ];
            operator = st:
              if st.stop then []
              else let
                st1 = b.elemAt (spaces.skipToContent st.state) 1;
                ind = effectiveIndent st1;
              in
                if isAtEnd st1 || atDocMarker st1 || ind < indent
                then [ { key = st.key + 1; stop = true; state = st1; } ]
                else if ind > indent
                  then [ { key = st.key + 1; stop = true; state = st1; error = failWith "yaml.mapping" "unexpected indentation in mapping" st1; } ]
                  # A key may not be indented with a tab. The
                  # indentation of a collection is counted in spaces,
                  # so a tab cannot be part of it. The error is about
                  # the tab, so it points at the tab itself.
                  else if tabIndent st1.str st1.offset
                    then let
                      tab = tabAt st1.str st1.offset;
                    in [ {
                      key = st.key + 1;
                      stop = true;
                      state = st1;
                      error = failWith "yaml.mapping" "a key may not be indented with a tab"
                        (if tab == null then st1 else stateAt st1 tab);
                    } ]
                  else let res = entry st1; in
                    if failed res
                    then [ { key = st.key + 1; stop = true; state = st1; error = res; } ]
                    else let
                      # The entry is followed by the rest of its line,
                      # which may hold a comment. A '#' that follows
                      # the value directly is not one: a comment has to
                      # be separated from what precedes it.
                      after = b.elemAt res 2;
                      sr = spaces.skipToContentStrict after;
                    in if failed sr
                      then [ { key = st.key + 1; stop = true; state = st1; error = sr; } ]
                      else [ {
                        key = st.key + 1;
                        stop = false;
                        state = b.elemAt sr 1;
                        value = { k = b.elemAt res 0; v = b.elemAt res 1; offset = st1.offset; };
                      } ];
          };
          values = valuesOf work;
          last = lastOf { state = st; } work;
          dup = duplicateKey values;
          # The value of a merge key has to be a mapping, or a sequence
          # of mappings. The check is only made when the merge key is
          # to be honoured.
          badMerge =
            if ! (state.mergeKeysEnabled st)
            then null
            else
              let
                bs = b.filter (e: state.badMerge e != null) values;
              in
                if bs == [] then null else b.elemAt bs 0;
        in
          if last ? error
          then last.error
          else if dup != null
            then failWith "yaml.mapping" "duplicate key '${dup.name}'" (st // { offset = dup.offset; })
            else if badMerge != null && badMerge.offset != null
              then failWith "yaml.mapping" "the value of a merge key must be a mapping or a sequence of mappings" (st // { offset = badMerge.offset; })
            else [ values last.state ];
    in
    bindY spaces.skipToContent (_: st1:
      let
        res = go st1;
      in if failed res
        then res
        else let
          entries = b.elemAt res 0;
          st = b.elemAt res 1;
        in [{ type = "map"; inherit entries; } st]) s;

  # ------------------------------------------------------------------
  # Block sequence
  # ------------------------------------------------------------------

  # A block sequence whose entries are at column `indent`.
  blockSequence = node: indent: s:
    let
      # One entry: "- value". The value may be on the same line or on
      # following lines indented further than `indent`.
      entry = st:
        let
          st1 = st // { offset = st.offset + 1; len = st.len - 1; };
          st2 = spaces.skipSpacesTo st1;
        in if isAtEnd st2
          then failWith "yaml.sequence" "expected a value after '-'" st2
          else if b.substring st2.offset 1 st2.str == "#"
            # A comment follows the '-', so the value is on one of the
            # following lines.
            then
              let
                vres = blockValue node indent false st2;
              in
                (if failed vres
                 then vres
                 else [(b.elemAt vres 0) (b.elemAt vres 1)])
          else if b.substring st2.offset 1 st2.str == "\n"
                 || b.substring st2.offset 1 st2.str == "\r"
            then
              # The value is on the following lines.
              let
                vres = blockValue node indent false st2;
              in if failed vres
                then vres
                else [(b.elemAt vres 0) (b.elemAt vres 1)]
            else
              # The value is on the same line. It may itself be a block
              # collection in "compact" notation ("- - a" or "- k: v").
              let
                vres = inlineValue node indent true st2;
              in if failed vres
                then vres
                else [(b.elemAt vres 0) (b.elemAt vres 1)];

      # Collect the entries of the sequence. The loop runs over a
      # worklist rather than by recursion: Nix does not optimise tail
      # calls, so a recursive loop would use one stack frame per entry
      # and overflow on a long sequence.
      #
      # The worklist is written out here rather than through
      # `state.iterate`, to keep the number of stack frames per nesting
      # level down; see `blockMapping`.
      go = st:
        let
          work = b.genericClosure {
            startSet = [ { key = 0; stop = false; state = st; } ];
            operator = st:
              if st.stop then []
              else let
                st1 = b.elemAt (spaces.skipToContent st.state) 1;
                ind = effectiveIndent st1;
              in
                if isAtEnd st1 || atDocMarker st1 || ind < indent
                then [ { key = st.key + 1; stop = true; state = st1; } ]
                else if ind > indent
                  then [ { key = st.key + 1; stop = true; state = st1; error = failWith "yaml.sequence" "unexpected indentation in sequence" st1; } ]
                  else if ! (atSequenceEntry st1)
                    then [ { key = st.key + 1; stop = true; state = st1; } ]
                    else let res = entry st1; in
                      if failed res
                      then [ { key = st.key + 1; stop = true; state = st1; error = res; } ]
                      else [ { key = st.key + 1; stop = false; state = b.elemAt res 1; value = b.elemAt res 0; } ];
          };
          values = valuesOf work;
          last = lastOf { state = st; } work;
        in
          if last ? error
          then last.error
          else [ values last.state ];
    in
    bindY spaces.skipToContent (_: st1:
      let
        res = go st1;
      in if failed res
        then res
        else let
          items = b.elemAt res 0;
          st = b.elemAt res 1;
        in [{ type = "seq"; inherit items; } st]) s;

  # ------------------------------------------------------------------
  # Values
  # ------------------------------------------------------------------

  # A value that appears on the same line as its key or '-'.
  #
  # This may be:
  #   - a flow collection
  #   - a scalar
  #   - a block collection in "compact" notation, e.g. "key: {a: 1}"
  #     or "- key: value"
  #
  # The value may also carry properties, in which case the content
  # after them may be on the lines below.
  #
  # `indent` is the indent of the enclosing collection.
  inlineValue = node: indent: compactOk: s:
    let
      st1 = b.elemAt (spaces.skipToContent s) 1;
      c = b.substring st1.offset 1 st1.str;
    in if c == "&" || c == "*" || c == "!"
      then
        # The value has properties. The content after them may be a
        # scalar or a nested collection, and it may be on the lines
        # below, so the whole node parser is used here.
        let
          # The properties of the value.
          pres = blockProperties indent st1;
        in if failed pres
          then pres
          else let
            props = b.elemAt pres 0;
            after = b.elemAt pres 1;
            # The line the value starts on.
            startLine = lineStartOf st1.str st1.offset;
          in
            if isAtEnd after
            then
              # An empty value. The properties, if any, belong to it.
              anchors.applyProperties props null after
            else if lineStartOf after.str after.offset == startLine
              then
                # The content is on the same line as the key.
                blockContent node indent indent true props after
              else
                # The content is on the lines below the key.
                blockValue node indent true s
      else if c == "[" || c == "{"
        then node.flow 0 s
        else if c == "\"" || c == "'"
          then scalars.quotedNode indent false s
          else if c == "|" || c == ">"
            then scalars.blockNode indent s
            else if atSequenceEntry st1
              then
                # Compact notation: a nested block sequence starting on
                # this line. It is only allowed where the specification
                # allows it, that is after a sequence entry ("- - a")
                # and after the ':' of an explicit key (": - a"). A
                # mapping value introduced by "key:" has to start on one
                # of the lines below, so "key: - a" is an error.
                if compactOk
                then blockSequence node (effectiveIndent st1) st1
                else failWith "yaml.block" "a block sequence cannot start on the line of its mapping key" st1
              else if findKeyColon st1 == null
                then scalars.plainNode false indent st1
                else
                  # Compact notation: a nested block mapping starting on
                  # this line. Its indent is the column of this line's
                  # content.
                  #
                  # A line holds one key and one value, so it may not
                  # hold more than one indicator: "a: b: c: d" is a
                  # mistake, while "a: b: c" is a mapping whose value is
                  # a mapping. The name of an anchor may hold a colon
                  # without it counting, so "&a: b: c" is still one
                  # indicator.
                  #
                  # The second indicator is the one that made the line
                  # a mistake, so the error points at it.
                  let
                    colons = keyColonOffsets st1;
                  in
                    if b.length colons > 1
                    then failWith "yaml.mapping" "expected a comment after the value"
                      (stateAt st1 (b.elemAt colons 0))
                    else blockMapping node (effectiveIndent st1) st1;

  # A value that appears on the lines after its key or '-'.
  #
  # The value must be indented strictly further than `indent`, with one
  # exception: a block sequence may be at the same indentation as the
  # key it belongs to (an "indentless sequence").
  blockValue = node: indent: allowIndentless: s:
    let
      st1 = b.elemAt (spaces.skipToContent s) 1;
      # The properties of the value. They may be on the key's line or
      # on a line of their own.
      pres = blockProperties indent st1;
    in if failed pres
      then pres
      else let
        props = b.elemAt pres 0;
        after = b.elemAt pres 1;
        sp = splitProps props after;
      in if isAtEnd after
        then
          # An empty value. The properties, if any, belong to it.
          anchors.applyProperties props null after
        else
          # A line of properties that stands on its own introduces the
          # value that follows it, so it has to be indented deeper than
          # the key it belongs to. At the same indentation there is
          # nothing for it to introduce, and a block sequence that
          # follows at that level is not a value of this key:
          #
          #   seq:      # the key is at column 0
          #   &anchor   # at column 0 as well, so this goes nowhere
          #   - a
          #
          # Indenting it by even one space makes it a value, as in
          # "seq:\n &anchor\n- a", which is what the specification
          # asks for.
          let
            firstProp = b.head props;
            orphan =
              sp.line == []
              && props != []
              && firstProp.offset - firstProp.line <= indent
              && atSequenceEntry after;
          in
            if orphan
            # The error is about the property that introduces the
            # sequence, so it points at the property itself.
            then failWith "yaml.block" "the properties that introduce a block sequence have to be indented"
              (stateAt after firstProp.offset)
            else
              let
                ind = effectiveIndent (contentState sp after);
              in
                if ind < indent
                  then anchors.applyProperties props null after
                  else if ind == indent
                    then
                      # An indentless sequence is allowed at the same
                      # indentation as the key. Anything else means that the
                      # value is empty.
                      if allowIndentless && atSequenceEntry after
                      then blockContent node indent indent true props after
                      else anchors.applyProperties props null after
                    else blockContent node indent indent true props after;

  # ------------------------------------------------------------------
  # Properties
  # ------------------------------------------------------------------

  # Parse the properties that precede a node in block context.
  #
  # The result is [props, state]:
  #
  #   props :: a list of { kind; name; line; offset; }
  #   state :: the state positioned after the properties
  #
  # A property may be on a line of its own, as long as that line is
  # indented deeper than `indent`. The first property is always taken:
  # it is on the same line as the content that precedes it.
  blockProperties = indent: st:
    let
      go = st': acc: first:
        let
          # The first property is on the same line as the content that
          # precedes it, so its state is used as it is. A property that
          # follows may be on a line of its own.
          st1 =
            if first
            then st'
            else b.elemAt (spaces.skipToContent st') 1;
          c = b.substring st1.offset 1 st1.str;
          isAnchor = (c == "&") && (anchors.anchorsEnabled st1);
          isTag = (c == "!") && (anchors.tagsEnabled st1);
        in
          if ! (isAnchor || isTag)
          then [acc st1]
          else if ! first && columnAt st1.str st1.offset <= indent
            # The property is not indented deeply enough to belong to
            # the node.
            then [acc st1]
            else
              let
                res = if isAnchor then anchors.anchorName st1 else anchors.tagName st1;
              in
                if failed res
                then res
                else go (b.elemAt res 1) (acc ++ [ {
                  kind = if isAnchor then "anchor" else "tag";
                  name = b.elemAt res 0;
                  line = lineStartOf st1.str st1.offset;
                  offset = st1.offset;
                } ]) false;
    in
      go st [] true;

  # Split the properties into the ones that are on the same line as the
  # content and the ones that are on the lines before it.
  #
  # In a block mapping the properties on the same line as the first key
  # belong to that key, and the ones before it belong to the mapping.
  #
  # The line that the content is on is worked out once here and handed
  # to `contentState`, which needs it as well: looking it up means
  # walking the input backwards, and the parser asks about the line of a
  # node more than once.
  splitProps = props: after:
    let
      contentLine = lineStartOf after.str after.offset;
    in {
      line = b.filter (p: p.line == contentLine) props;
      other = b.filter (p: p.line != contentLine) props;
      contentLine = contentLine;
    };

  # The state the content of a node is parsed from.
  #
  # The properties do not shift the indentation of the content: a
  # mapping whose first key is introduced by a tag starts at the
  # indentation of the line, not at the column of the key. The width of
  # the properties is recorded in the state, so that the indentation can
  # be worked out.
  contentState = sp: after:
    if sp.line == []
    then after // { propsWidth = 0; propsLine = -1; contentLine = sp.contentLine; }
    else after // {
      propsWidth = after.offset - (b.head sp.line).offset;
      propsLine = sp.contentLine;
      contentLine = sp.contentLine;
    };

  # ------------------------------------------------------------------
  # Block node dispatch
  # ------------------------------------------------------------------

  # Parse the content of a node in block context, with the properties
  # that precede it.
  #
  # The properties are handed to their owner:
  #
  #   - in a block mapping, the properties on the same line as the
  #     first key belong to that key, and the ones on the lines before
  #     it belong to the mapping
  #   - for any other node, all the properties belong to the node
  #
  # `props` are the properties that were parsed, and `after` is the
  # state positioned after them.
  blockContent = node: indent: scalarIndent: compactOk: props: after:
    let
      # The content after the properties.
      c = b.substring after.offset 1 after.str;

      # A property is followed by white space, by a line break, or by
      # the content itself. A ',' is not content: "- !!str, x" would
      # read as the tag "!!str" followed by the plain scalar ", x".
      glued = props != [] && c == ",";

      # Is the content a block mapping?
      # Is the content a block mapping? A flow collection is not: the
      # colons inside it are not mapping indicators.
      isMap =
        c != "[" && c != "{"
        && (atExplicitKey after || findKeyColon after != null);

      # The properties, split by the line they are on.
      sp = if props == [] then { line = []; other = []; } else splitProps props after;

      # The state the content is parsed from.
      st =
        if after.propsWidth == 0 && after.propsLine == -1
        then after
        else contentState sp after;
    in
      if isAtEnd after
      then
        # An empty node. The properties, if any, belong to it.
        anchors.applyProperties props null after
      else if glued
        then failWith "yaml.block" "a property must be separated from the node it belongs to" after
      else if isMap && sp.line != []
      then
        # The first key of the mapping takes the properties on its
        # line. The mapping is parsed from before them, so that the key
        # parser sees them.
        let
          keyStart = (stateAt after (b.head sp.line).offset) // {
            propsWidth = 0;
            propsLine = -1;
          };
          res = blockMapping node (effectiveIndent keyStart) keyStart;
        in
          (if failed res
           then res
           else
             # The properties on the lines before the mapping belong to
             # the mapping itself.
             anchors.applyProperties sp.other (b.elemAt res 0) (b.elemAt res 1))
      else
        # The node takes all the properties.
        let
          res =
            if c == "[" || c == "{"
            then node.flow indent st
            else if atSequenceEntry st
            then
              # Compact notation. A block sequence may start on the
              # same line as a sequence entry or after the ':' of an
              # explicit key, but not on the same line as the key of an
              # implicit mapping.
              if compactOk
              then blockSequence node (effectiveIndent st) st
              else failWith "yaml.block" "a block sequence cannot start on the line of its mapping key" st
            else if isMap
            then blockMapping node (effectiveIndent st) st
            else if c == "*" && (anchors.anchorsEnabled st)
              then
                # An alias stands alone: an alias stands for a whole
                # node, so there is nothing for a property to attach
                # to, and "&name *other" is not a node that the anchor
                # names. The error is about the alias, so it points at
                # the '*' that starts it.
                if props != []
                then failWith "yaml.alias" "an alias may not carry a property" (stateAt st after.offset)
                else
                  let
                    ares = anchors.alias after;
                  in
                    (if failed ares then ares else ares)
            else if c == "\"" || c == "'"
            then scalars.quotedNode scalarIndent false st
            else if c == "|" || c == ">"
            then scalars.blockNode scalarIndent st
            else scalars.plainNode false scalarIndent st;
        in
          (if failed res
           then res
           else anchors.applyProperties props (b.elemAt res 0) (b.elemAt res 1));

  # Parse a node whose content is at column `indent`.
  blockNode = node: indent: s:
    let
      st1 = b.elemAt (spaces.skipToContent s) 1;
    in if isAtEnd st1
      then [null st1]
      else if atDocMarker st1
        # A document marker: the node is empty.
        then [null st1]
      else
        let
          pres = blockProperties indent st1;
        in
          if failed pres
          then pres
          else blockContent node indent indent true (b.elemAt pres 0) (b.elemAt pres 1);

  # The node of a document, which has no enclosing block collection.
  #
  # The only difference from `blockNode` is that a block sequence may not
  # start on the line of the node: there is no sequence entry for it to
  # follow, so "&anchor - x" is not a sequence but a mistake.
  documentNode = node: indent: s:
    let
      st1 = b.elemAt (spaces.skipToContent s) 1;
    in if isAtEnd st1
      then [null st1]
      else if atDocMarker st1
        then [null st1]
      else
        let
          pres = blockProperties indent st1;
          props = b.elemAt pres 0;
          after = b.elemAt pres 1;
          # The line that the content is on, worked out once.
          contentLine = lineStartOf after.str after.offset;
        in
          if failed pres
          then pres
          # A block sequence may not start on the line of a node that
          # carries a property on that same line: there is no sequence
          # entry for it to follow, so "&anchor - x" is a mistake. A
          # property on a line of its own introduces the sequence, as
          # in "&sequence\n- a", and stays fine.
          else if props != []
               && b.foldl' (acc: p: acc || p.line == contentLine) false props
          then blockContent node indent indent false props after
          else blockContent node indent indent true props after;
}
