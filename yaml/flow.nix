# YAML flow collections: [a, b] and {a: 1, b: 2}.
#
# In flow context indentation is not significant, but line breaks and
# comments may appear between tokens. A flow collection may therefore
# span multiple lines.
#
# The node parser is passed in rather than defined here, so that the
# caller decides how a node is interpreted. This keeps flow.nix free of
# dependencies on the block parser and breaks the import cycle between
# the two.

{ state, spaces, scalars, anchors }:

with state;

let
  b = builtins;

  # In flow context, whitespace (including line breaks) and comments may
  # separate tokens.
  flowSpace = spaces.flowSpace;
in rec {
  

  # ------------------------------------------------------------------
  # Flow collections
  # ------------------------------------------------------------------

  # A flow sequence: [a, b, c]
  flowSeq = node: s:
    let
      s1 = b.elemAt (stringY "[" s) 1;
      s2 = b.elemAt (flowSpace s1) 1;

      # An entry, or the closing bracket.
      #
      # An entry may be a single-pair mapping, as in "[a: 1]". The key is
      # parsed as a node; when it is followed by a ':' the entry is a
      # mapping of that one pair.
      entry = st:
        let
          st1 = b.elemAt (flowSpace st) 1;
          # A '?' only starts an explicit key when it is followed by a
          # space or the end of the line; otherwise it is part of a
          # plain scalar.
          isExplicitKey =
            b.substring st1.offset 1 st1.str == "?"
            && (st1.len == 1
                 || b.substring (st1.offset + 1) 1 st1.str == " "
                 || b.substring (st1.offset + 1) 1 st1.str == "\n"
                 || b.substring (st1.offset + 1) 1 st1.str == "\r");
        in if isAtEnd st1
          then failWith "yaml.flow" "unterminated flow sequence" st1
          else if b.substring st1.offset 1 st1.str == "]"
            then [null st1]
            # A document marker ends a document, so it may not be part
            # of a flow collection.
            else if atDocMarkerAt st1.str st1.offset st1.len
              then failWith "yaml.flow" "a document marker is not allowed in a flow collection" st1
            else if b.substring st1.offset 1 st1.str == ","
              # An empty entry: "[, a]" and "[a, b, , ]". The
              # specification allows an empty entry only where it
              # stands for the value of a single-pair mapping, which
              # is handled below.
              then failWith "yaml.flow" "unexpected ',' in flow sequence" st1
            else if isExplicitKey
              then
                # An explicit key: "? key : value". The entry is a
                # single-pair mapping.
                let
                  st2 = b.elemAt (flowSpace (st1 // { offset = st1.offset + 1; len = st1.len - 1; })) 1;
                  kres = node st2;
                in if failed kres
                  then kres
                  else let
                    k = b.elemAt kres 0;
                    st3 = b.elemAt (flowSpace (b.elemAt kres 1)) 1;
                  in if ! (isAtEnd st3) && b.substring st3.offset 1 st3.str == ":"
                    then
                      let
                        st4 = st3 // { offset = st3.offset + 1; len = st3.len - 1; };
                        st5 = b.elemAt (flowSpace st4) 1;
                        vres =
                          if isAtEnd st5 || b.substring st5.offset 1 st5.str == "]"
                          then [null st5]
                          else node st5;
                      in if failed vres
                        then vres
                        else [
                          {
                            type = "map";
                            entries = [ { k = k; v = b.elemAt vres 0; } ];
                          }
                          (b.elemAt vres 1)
                        ]
                    else [
                      {
                        type = "map";
                        entries = [ { k = k; v = null; } ];
                      }
                      st3
                    ]
              else
                let
                  res = node st1;
                in if failed res
                  then res
                  else let
                    v = b.elemAt res 0;
                    st2 = b.elemAt res 1;
                    st3 = b.elemAt (flowSpace st2) 1;
                  in if ! (isAtEnd st3)
                       && b.substring st3.offset 1 st3.str == ":"
                       # The ':' of a single-pair mapping has to be on
                       # the same line as its key. One that follows a
                       # line break would make an implicit key of more
                       # than one line, which the specification does not
                       # allow in flow context; such a key needs a '?'.
                       && lineStartOf st3.str st3.offset == lineStartOf st2.str st2.offset
                    then
                      # A single-pair mapping: "key: value".
                      let
                        st4 = st3 // { offset = st3.offset + 1; len = st3.len - 1; };
                        st5 = b.elemAt (flowSpace st4) 1;
                        vres =
                          if isAtEnd st5 || b.substring st5.offset 1 st5.str == "]"
                          then [null st5]
                          else node st5;
                      in if failed vres
                        then vres
                        else [
                          {
                            type = "map";
                            entries = [ { k = v; v = b.elemAt vres 0; } ];
                          }
                          (b.elemAt vres 1)
                        ]
                    else [ v st2 ];

      # Collect the entries. The loop runs over a worklist rather than by
      # recursion, so that a long flow sequence does not overflow the
      # stack; see `blocks.blockMapping`.
      go = st:
        let
          work = b.genericClosure {
            startSet = [ { key = 0; stop = false; state = st; } ];
            operator = st:
              if st.stop
              then []
              else let
                res = entry st.state;
              in if failed res
                then [ { key = st.key + 1; stop = true; state = st.state; error = res; } ]
                else let
                  v = b.elemAt res 0;
                  st1 = b.elemAt res 1;
                in if v == null
                  # The closing bracket.
                  then [ { key = st.key + 1; stop = true; state = st1; } ]
                  else let
                    st2 = b.elemAt (flowSpace st1) 1;
                  in if isAtEnd st2
                    then [ { key = st.key + 1; stop = true; state = st2; error = failWith "yaml.flow" "unterminated flow sequence" st2; } ]
                    else let c = b.substring st2.offset 1 st2.str; in
                      if c == ","
                        then [ {
                          key = st.key + 1;
                          stop = false;
                          state = b.elemAt (flowSpace (st2 // { offset = st2.offset + 1; len = st2.len - 1; })) 1;
                          value = v;
                        } ]
                        else if c == "]"
                          then [ { key = st.key + 1; stop = true; state = st2; value = v; } ]
                          else [ {
                            key = st.key + 1;
                            stop = true;
                            state = st2;
                            error = failWith "yaml.flow" "expected ',' or ']' in flow sequence" st2;
                          } ];
          };
          values = valuesOf work;
          last = lastOf { state = st; } work;
        in
          if last ? error
          then last.error
          else [ values last.state ];
    in
    let
      st2 = b.elemAt (flowSpace s1) 1;
      res = go st2;
    in if failed res
      then res
      else let
        items = b.elemAt res 0;
        st = b.elemAt res 1;
        st3 = b.elemAt (flowSpace st) 1;
      in if isAtEnd st3
        then failWith "yaml.flow" "unterminated flow sequence" st3
        else if b.substring st3.offset 1 st3.str == "]"
          then [{ type = "seq"; inherit items; } (st3 // { offset = st3.offset + 1; len = st3.len - 1; })]
          else failWith "yaml.flow" "expected ']' in flow sequence" st3;

  # A flow mapping: {a: 1, b: 2}
  flowMap = node: s:
    let
      s1 = b.elemAt (stringY "{" s) 1;
      s2 = b.elemAt (flowSpace s1) 1;

      # A key: a scalar, or a flow collection used as a complex key.
      #
      # A key may carry an anchor or a tag, which are handled here, so
      # that they are not part of its text.
      flowKey = st:
        let
          content = _: s:
            let
              c = b.substring s.offset 1 s.str;
            in
              if c == "\"" || c == "'"
              then scalars.quotedNode null false s
              else if c == "[" || c == "{"
                then node s
                else if c == ":"
                  # An empty key: the properties are all there is.
                  then [ { type = "scalar"; text = ""; quoted = true; } s ]
                  else scalars.plainFlowNode s;
        in anchors.withProperties content null spaces.flowSpace st;

      # Parse "key: value", "key" or "key:".
      #
      # The result is [key, value, state, keyOffset].
      pair = st:
        let
          st1 = b.elemAt (flowSpace st) 1;
          # A '?' only starts an explicit key when it is followed by a
          # space or the end of the line; otherwise it is part of a
          # plain scalar.
          isExplicitKey =
            b.substring st1.offset 1 st1.str == "?"
            && (st1.len == 1
                 || b.substring (st1.offset + 1) 1 st1.str == " "
                 || b.substring (st1.offset + 1) 1 st1.str == "\n"
                 || b.substring (st1.offset + 1) 1 st1.str == "\r");
        in if isAtEnd st1
          then failWith "yaml.flow" "unterminated flow mapping" st1
          # A document marker ends a document, so it may not be part
          # of a flow collection.
          else if atDocMarkerAt st1.str st1.offset st1.len
            then failWith "yaml.flow" "a document marker is not allowed in a flow collection" st1
          else let c = b.substring st1.offset 1 st1.str; in
            if c == "}"
              then [null null st1 st1.offset]
              else if isExplicitKey
                then
                  # An explicit key: "? key : value"
                  let
                    st2 = b.elemAt (flowSpace (st1 // { offset = st1.offset + 1; len = st1.len - 1; })) 1;
                    kres = flowKey st2;
                  in if failed kres
                    then kres
                    else let
                      k = b.elemAt kres 0;
                      st2 = b.elemAt kres 1;
                      st3 = b.elemAt (flowSpace st2) 1;
                    in if ! (isAtEnd st3)
                         && b.substring st3.offset 1 st3.str == ":"
                         # As in a flow sequence: the ':' of an implicit
                         # key has to be on the line of the key.
                         && lineStartOf st3.str st3.offset == lineStartOf st2.str st2.offset
                      then let
                        st4 = st3 // { offset = st3.offset + 1; len = st3.len - 1; };
                        st5 = b.elemAt (flowSpace st4) 1;
                        vres = if isAtEnd st5 || b.substring st5.offset 1 st5.str == "}"
                          then [null st5]
                          else node st5;
                      in if failed vres
                        then vres
                        else [(k) (b.elemAt vres 0) (b.elemAt vres 1) st2.offset]
                      else [(k) null st3 st2.offset]
                else
                  let
                    kres = flowKey st1;
                  in if failed kres
                    then kres
                    else let
                      k = b.elemAt kres 0;
                      st2 = b.elemAt kres 1;
                      st3 = b.elemAt (flowSpace st2) 1;
                    in if isAtEnd st3
                      then [(k) null st3 st1.offset]
                      else if b.substring st3.offset 1 st3.str == ":"
                        then let
                          st4 = st3 // { offset = st3.offset + 1; len = st3.len - 1; };
                          st5 = b.elemAt (flowSpace st4) 1;
                          vres = if isAtEnd st5 || b.substring st5.offset 1 st5.str == "}"
                            then [null st5]
                            else node st5;
                        in if failed vres
                          then vres
                          else [(k) (b.elemAt vres 0) (b.elemAt vres 1) st1.offset]
                        else [(k) null st3 st1.offset];

      # Collect the entries. The loop runs over a worklist rather than by
      # recursion, so that a long flow mapping does not overflow the
      # stack; see `blocks.blockMapping`.
      go = st:
        let
          work = b.genericClosure {
            startSet = [ { key = 0; stop = false; state = st; } ];
            operator = st:
              if st.stop
              then []
              else let
                res = pair st.state;
              in if failed res
                then [ { key = st.key + 1; stop = true; state = st.state; error = res; } ]
                else let
                  k = b.elemAt res 0;
                  v = b.elemAt res 1;
                  st1 = b.elemAt res 2;
                in if k == null
                  # The closing brace.
                  then [ { key = st.key + 1; stop = true; state = st1; } ]
                  else let
                    st2 = b.elemAt (flowSpace st1) 1;
                  in if isAtEnd st2
                    then [ { key = st.key + 1; stop = true; state = st2; error = failWith "yaml.flow" "unterminated flow mapping" st2; } ]
                    else let c = b.substring st2.offset 1 st2.str; in
                      if c == ","
                        then [ {
                          key = st.key + 1;
                          stop = false;
                          state = b.elemAt (flowSpace (st2 // { offset = st2.offset + 1; len = st2.len - 1; })) 1;
                          value = { inherit k v; offset = b.elemAt res 3; };
                        } ]
                        else if c == "}"
                          then [ { key = st.key + 1; stop = true; state = st2; value = { inherit k v; offset = b.elemAt res 3; }; } ]
                          else [ {
                            key = st.key + 1;
                            stop = true;
                            state = st2;
                            error = failWith "yaml.flow" "expected ',' or '}' in flow mapping" st2;
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
            then failWith "yaml.flow" "duplicate key '${dup.name}'" (st // { offset = dup.offset; })
            else if badMerge != null && badMerge.offset != null
              then failWith "yaml.flow" "the value of a merge key must be a mapping or a sequence of mappings" (st // { offset = badMerge.offset; })
              else [ values last.state ];
    in
    let
      st2 = b.elemAt (flowSpace s1) 1;
      res = go st2;
    in if failed res
      then res
      else let
        entries = b.elemAt res 0;
        st = b.elemAt res 1;
        st3 = b.elemAt (flowSpace st) 1;
      in if isAtEnd st3
        then failWith "yaml.flow" "unterminated flow mapping" st3
        else if b.substring st3.offset 1 st3.str == "}"
          then [{ type = "map"; inherit entries; } (st3 // { offset = st3.offset + 1; len = st3.len - 1; })]
          else failWith "yaml.flow" "expected '}' in flow mapping" st3;
}
