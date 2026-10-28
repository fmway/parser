# YAML documents and streams.
#
# A stream is a sequence of documents. Each document may be preceded by
# directives ("%YAML 1.2", "%TAG ! tag:example.com,2000:app/") and
# delimited by "---" (start) and "..." (end).
#
#   stream    ::= prefix* ( doc suffix* )*
#   document  ::= directives? "---"? block-node
#
# Directives are parsed but only validated loosely: the YAML version is
# checked to be 1.x and %TAG directives are recorded in the tag table.

{ state, spaces, scalars, blocks, nodes }:

with state;

let
  b = builtins;

  # A document start marker: "---" at the start of a line.
  atDocStart = s:
    s.len >= 3
    && b.substring s.offset 3 s.str == "---"
    && (s.len == 3
         || b.substring (s.offset + 3) 1 s.str == " "
         || b.substring (s.offset + 3) 1 s.str == "\t"
         || b.substring (s.offset + 3) 1 s.str == "\n"
         || b.substring (s.offset + 3) 1 s.str == "\r");

  # A document end marker: "..." at the start of a line.
  atDocEnd = s:
    s.len >= 3
    && b.substring s.offset 3 s.str == "..."
    && (s.len == 3
         || b.substring (s.offset + 3) 1 s.str == " "
         || b.substring (s.offset + 3) 1 s.str == "\t"
         || b.substring (s.offset + 3) 1 s.str == "\n"
         || b.substring (s.offset + 3) 1 s.str == "\r");

  # A directive: "%" at the start of a line.
  atDirective = s: s.len >= 1 && b.substring s.offset 1 s.str == "%";

  # The number of white space characters in front of the text.
  indentWidth = text:
    let
      go = i:
        if i >= b.stringLength text then i
        else if spaces.isSpaceChar (b.substring i 1 text) then go (i + 1)
        else i;
    in go 0;

  # Parse a single directive line, e.g. "%YAML 1.2" or
  # "%TAG ! tag:example.com,2000:app/".
  #
  # The result is [handles, state, word, handle]:
  #
  #   handles :: the tag handles that the directive defines
  #   state  :: the state after the directive line
  #   word   :: the name of the directive
  #   handle :: the tag handle that a %TAG directive defines, or null
  #
  # Unknown directives are ignored, as the spec requires; only a
  # malformed %YAML or %TAG directive is an error.
  directive = base: s:
    let
      str = s.str;
      # The text of the directive line. Everything below works on that
      # text alone, so the offsets into it start at zero; using the
      # offset into the whole input would run past the end of the line
      # for every directive but the first.
      end = scalars.lineTextAt str s.offset (s.offset + s.len);
      rest = b.substring 1 (b.stringLength end - 1) end;
      trimmed = scalars.rstrip (scalars.lstrip rest);
      # The state after the directive line. The line break belongs to
      # the directive as well, so it is consumed here rather than being
      # left for `skipToContent`; otherwise the length of the window
      # would no longer match the offset, and the next directive would
      # be cut short.
      next = scalars.nextLineAt str s.offset (s.offset + s.len);
      after = s // {
        offset = next;
        len = s.len - (next - s.offset);
      };
      # The word after the '%': the name of the directive.
      word =
        let
          go = i:
            if i >= b.stringLength trimmed then b.substring 0 i trimmed
            else if spaces.isSpaceChar (b.substring i 1 trimmed) then b.substring 0 i trimmed
            else go (i + 1);
        in go 0;
    in
      if word == "YAML"
      then
        let
          # The version, without a trailing comment.
          versionText =
            let
              rest = b.substring 4 (b.stringLength trimmed - 4) trimmed;
              # The position of a comment: a '#' that follows a space.
              hash =
                let
                  go = i:
                    if i >= b.stringLength rest then null
                    else if b.substring i 1 rest == "#"
                      && i > 0 && b.substring (i - 1) 1 rest == " "
                      then i
                      else go (i + 1);
                in go 0;
            in
              scalars.rstrip (scalars.lstrip (if hash == null then rest else b.substring 0 hash rest));
          # The major version. A minor version that is higher than the
          # one this parser implements is only a warning, but a major
          # version other than 1 is an error.
          major =
            let
              dot =
                let
                  go = i:
                    if i >= b.stringLength versionText then null
                    else if b.substring i 1 versionText == "." then i
                    else go (i + 1);
                in go 0;
            in
              if dot == null then versionText else b.substring 0 dot versionText;

          # The offset of the version in the document.
          #
          # The error about a version that is not one points at the
          # version itself, and not at the directive that holds it.
          versionOffset =
            s.offset
            + 1
            + indentWidth rest
            + 4
            + indentWidth (b.substring 4 (b.stringLength trimmed - 4) trimmed);
        in if b.match "[0-9]+\\.[0-9]+" versionText == null
          then failWith "yaml.directive" "invalid YAML version '${versionText}'" (stateAt s versionOffset)
          else if major != "1"
            then failWith "yaml.directive" "invalid YAML version '${versionText}'" (stateAt s versionOffset)
            else [ base after "YAML" null ]
      else if word == "TAG"
      then
        let
          # "%TAG <handle> <prefix>"
          afterTag = scalars.lstrip (b.substring 3 (b.stringLength trimmed - 3) trimmed);
          h = b.substring 0 1 afterTag;
        in
          if h != "!"
          then failWith "yaml.directive" "invalid %TAG directive" s
          else
            # The handle is "!" (the primary handle), "!!" (the
            # secondary one) or "!name!" (a custom one). The rest of
            # the line is the prefix that the handle stands for.
            #
            # The handle keeps its leading and its trailing '!'; the
            # prefix starts after the white space that follows it.
            let
              # The position of the '!' that closes a named handle, or
              # null when the handle is the primary or secondary one.
              closing =
                if b.substring 0 2 afterTag == "!!" then null
                else if b.substring 1 1 afterTag == "!" then null
                else
                  let
                    go = i:
                      if i >= b.stringLength afterTag then null
                      else if b.substring i 1 afterTag == "!" then i
                      else go (i + 1);
                  in go 1;
              handle =
                if b.substring 0 2 afterTag == "!!"
                then "!!"
                else if closing == null
                  then "!"
                  else b.substring 0 (closing + 1) afterTag;
              prefix =
                if handle == "!!"
                then scalars.lstrip (b.substring 2 (b.stringLength afterTag - 2) afterTag)
                else if handle == "!"
                  then scalars.lstrip (b.substring 1 (b.stringLength afterTag - 1) afterTag)
                  else scalars.lstrip (b.substring (closing + 1) (b.stringLength afterTag - closing - 1) afterTag);
            in
              [ (base // { ${handle} = prefix; }) after "TAG" handle ]
      else
        # An unknown directive is ignored.
        [ base after word null ];

in rec {
  inherit atDocStart atDocEnd atDirective;

  # Parse the directives that precede a document.
  #
  # The result is [handles, state, seen]:
  #
  #   handles :: the tag handles that the directives define
  #   state   :: the state after the directives
  #   seen    :: whether a directive was found
  #
  # A %YAML directive may appear only once, and a tag handle may be
  # defined only once; both are errors.
  #
  # The directives of a document do not apply to the next one, so the
  # tag handles start out empty for every document.
  directives = s:
    let
      # The tag handles of this document.
      base = defaultTags;

      go = st: handles: yamlSeen: defined:
        let
          st1 = b.elemAt (spaces.skipToContent st) 1;
        in
          if isAtEnd st1 || ! (atDirective st1)
          then [handles st1 (yamlSeen || defined != {})]
          else
            let
              res = directive handles st1;
            in
              if failed res
              then res
              else
                let
                  newHandles = b.elemAt res 0;
                  word = b.elemAt res 2;
                  handle = b.elemAt res 3;
                in
                  if word == "YAML"
                  then
                    if yamlSeen
                    then failWith "yaml.directive" "duplicate %YAML directive" st1
                    else go (b.elemAt res 1) newHandles true defined
                  else if word == "TAG"
                  then
                    if defined ? ${handle}
                    then failWith "yaml.directive" "duplicate %TAG directive for handle '${handle}'" st1
                    else go (b.elemAt res 1) newHandles yamlSeen (defined // { ${handle} = true; })
                  else
                    # An unknown directive is ignored.
                    go (b.elemAt res 1) newHandles yamlSeen defined;
    in
    let
      res = go s base false {};
    in if failed res
      then res
      else [ (b.elemAt res 0) (b.elemAt res 1) (b.elemAt res 2) ];

  # Parse a single document. The state is positioned at the start of the
  # document's content (after any directives and "---" marker).
  #
  # The result is [node, state, hasMarker, ended]. The marker tells
  # whether the document was introduced by a "---": a document without
  # one that turns out to be empty is not a document at all. `ended`
  # tells whether it was closed by a "...".
  document = s:
    let
      # Skip the "---" marker if present.
      st1 = b.elemAt (spaces.skipToContent s) 1;
      hasMarker = atDocStart st1;
      st2 = if hasMarker
        then st1 // { offset = st1.offset + 3; len = st1.len - 3; }
        else st1;
      # The node may be on the line of the marker or on the next one,
      # so the content is looked for.
      st3 = b.elemAt (spaces.skipToContent st2) 1;
      # A block collection may not start on the line of the marker,
      # even when the marker carries properties of its own: there is
      # no sequence entry for it to follow. So "--- &anchor a: b" is a
      # mistake, while "--- &anchor\n  a: b" is not.
      inlineCollection =
        hasMarker
        && st3.offset < st2.offset + st2.len
        && lineStartOf st3.str st3.offset == lineStartOf st1.str st1.offset
        && (blocks.atSequenceEntry st3 || blocks.findKeyColon st3 != null);
      # The document may carry a tag or an anchor of its own, so the
      # node parser is used here rather than the block dispatcher.
      # The document has no enclosing block, so a continuation line of a
      # multi-line scalar only has to be indented at all.
      res =
        if inlineCollection
        then failWith "yaml.document" "a block collection may not start on the line of the marker" st3
        else nodes.documentNode (-1) st3;
    in if failed res
      then res
      else let
        node = b.elemAt res 0;
        st = b.elemAt res 1;
        # A comment has to be separated from what precedes it, so a '#'
        # that follows the node directly is not one. In a block mapping
        # entry this is checked where the value is parsed; a document's
        # own node has no such place, so it is checked here.
        sr = spaces.skipToContentStrict st;
      in if failed sr
        then sr
        else
        # Skip the "..." marker if present.
        let
        st3 = b.elemAt sr 1;
        ended = atDocEnd st3;
        # A document end marker may be followed by a comment, but not
        # by content: it ends the document, and what follows it on the
        # same line would otherwise start a new one. Content on a line
        # of its own is a new document, which is allowed.
        #
        # The result is the state after the marker, and the error it
        # raises, if any.
        afterEnd =
          if ended
          then let
            st4 = st3 // { offset = st3.offset + 3; len = st3.len - 3; };
            st5 = spaces.skipSpacesTo st4;
          in if ! (isAtEnd st5)
               && b.substring st5.offset 1 st5.str != "#"
               && b.substring st5.offset 1 st5.str != "\n"
               && b.substring st5.offset 1 st5.str != "\r"
            then st5
            else st4
          else st3;
        # The same, as a failure rather than as a state.
        endErr =
          if ended && afterEnd.offset != st3.offset + 3
          then failWith "yaml.document" "expected a comment after the document end marker" afterEnd
          else null;
      in
        if endErr != null
        then endErr
        else [
        node
        (if ended
          then afterEnd
          else st3)
        hasMarker
        # Whether the document was closed by an explicit "..." marker.
        # One that was may be followed by a document that leaves out
        # its "---" marker.
        ended
      ];

  # Parse a whole stream of documents.
  stream = s:
    let
      # The loop runs over a worklist rather than by recursion, so that
      # a stream with many documents does not overflow the stack; see
      # `blocks.blockMapping`.
      go = st:
        let
          work = b.genericClosure {
            startSet = [ { key = 0; stop = false; state = st; } ];
            operator = st:
              if st.stop
              then []
              else let
                st1 = b.elemAt (spaces.skipToContent st.state) 1;
              in if isAtEnd st1
                then [ { key = st.key + 1; stop = true; state = st1; } ]
                else
                  let
                    # Directives may precede each document. The tag
                    # handles of the previous document do not carry
                    # over, so they are reset before they are looked at.
                    st1' = st1 // { opts = st1.opts // { tagHandles = defaultTags; }; };
                    dres = directives st1';
                    # A directive introduces a document, so it may only
                    # follow the end of the previous one. Without a
                    # "..." the previous document has no end yet, and
                    # the directive is a mistake:
                    #
                    #   scalar1
                    #   %YAML 1.2
                    #
                    # A directive at the very start of the stream, or
                    # after a "---" or a "...", is an ordinary one.
                    stray =
                      b.elemAt dres 2
                      && st.seen or false
                      && ! (st.ended or false);
                  in if failed dres
                    then [ { key = st.key + 1; stop = true; state = st.state; error = dres; } ]
                      else if stray
                        then [ {
                          key = st.key + 1;
                          stop = true;
                          state = st.state;
                          error = failWith "yaml.directive" "a directive has to follow the end of a document" st1;
                        } ]
                      else let
                        handles = b.elemAt dres 0;
                        seen = b.elemAt dres 2;
                        st2 = (b.elemAt dres 1) // {
                          tagHandles = handles;
                          opts = (b.elemAt dres 1).opts // { inherit tagHandles; };
                        };
                        st3 = b.elemAt (spaces.skipToContent st2) 1;
                    in if isAtEnd st3
                      then
                        if seen
                        then
                          # A directive must be followed by a document.
                          [ {
                            key = st.key + 1;
                            stop = true;
                            state = st.state;
                            error = failWith "yaml.directive" "expected a document after the directives" st3;
                          } ]
                        else [ { key = st.key + 1; stop = true; state = st3; seen = st.seen or false; ended = st.ended or false; } ]
                      else
                        let
                          nres = document st3;
                        in if failed nres
                          then [ { key = st.key + 1; stop = true; state = st.state; error = nres; } ]
                          else let
                            node = b.elemAt nres 0;
                            st4 = b.elemAt nres 1;
                            hasMarker = b.elemAt nres 2;
                            ended = b.elemAt nres 3;
                          in if node == null && ! hasMarker
                            then
                              if seen
                              then
                                # A directive must be followed by a
                                # document, and an empty document
                                # without a marker is not one.
                                [ {
                                  key = st.key + 1;
                                  stop = true;
                                  state = st.state;
                                  error = failWith "yaml.directive" "expected a document after the directives" st3;
                                } ]
                              else
                                # An empty document without a marker is
                                # not a document.
                                [ { key = st.key + 1; stop = false; state = st4; seen = st.seen or false; ended = st.ended or false; } ]
                            else
                              # Only the first document of a stream may
                              # leave out its "---" marker. Every
                              # document after it has to start with the
                              # marker again, unless the previous one
                              # was closed by a "...".
                              if (st.seen or false) && ! hasMarker && ! (st.ended or false)
                              then [ {
                                key = st.key + 1;
                                stop = true;
                                state = st.state;
                                error = failWith "yaml.document" "expected '---' before a second document" st3;
                              } ]
                              else [ {
                                key = st.key + 1;
                                stop = false;
                                state = st4;
                                seen = true;
                                inherit ended;
                                value = node;
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
      res = go s;
    in if failed res
      then res
      else [ (b.elemAt res 0) (b.elemAt res 1)];
}
