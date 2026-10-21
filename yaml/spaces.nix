# YAML whitespace, line breaks and comments.
#
# Line breaks: \n, \r\n, \r.
# Comments:    '#' up to (but not including) the next line break.
#
# In block context indentation (leading spaces) is significant, so the
# helpers here distinguish between:
#   - skipSpaces    : spaces and tabs only
#   - skipToContent : whitespace, comments and blank lines, landing on the
#                     first character of actual content

{ state }:

with state;

let
  b = builtins;

  isSpaceChar = c: c == " " || c == "\t";
  isBreakChar = c: c == "\n" || c == "\r";

in rec {
  inherit isSpaceChar isBreakChar;

  # A single line break, consuming "\r\n" as one. This is a parser, so it
  # can be passed to `bindY` and friends.
  sBreak = s:
    if s.len >= 2 && b.substring s.offset 2 s.str == "\r\n"
      then takeY 2 s
      else if s.len >= 1 && isBreakChar (b.substring s.offset 1 s.str)
        then takeY 1 s
        else failWith "yaml.break" "expected a line break" s;

  # The same, but returning the new state directly.
  sBreakTo = s: b.elemAt (sBreak s) 1;

  # A comment: '#' plus everything up to the next line break (the break
  # itself is not consumed).
  sComment = s:
    if s.len >= 1 && b.substring s.offset 1 s.str == "#"
      then let
        str = s.str;
        len = b.stringLength str;
        go = i:
          if i >= len then i
          else if isBreakChar (b.substring i 1 str) then i
          else go (i + 1);
        end = go s.offset;
        n = end - s.offset;
      in [null (s // { offset = end; len = s.len - n; })]
      else failWith "yaml.comment" "expected '#'" s;

  # Consume spaces and tabs.
  skipSpaces = s:
    let
      str = s.str;
      len = b.stringLength str;
      go = i:
        if i >= len || !isSpaceChar (b.substring i 1 str) then i
        else go (i + 1);
      end = go s.offset;
      n = end - s.offset;
    in [null (s // { offset = end; len = s.len - n; })];

  # The state after the spaces, without the list that `skipSpaces`
  # wraps it in. The parser asks for the white space very often, and
  # every Nix function call costs.
  skipSpacesTo = s:
    let
      str = s.str;
      len = b.stringLength str;
      # The check for a space is written out, because it runs for every
      # character of every run of white space, and a call costs more
      # than the two comparisons it saves.
      go = i:
        if i >= len then i
        else let c = b.substring i 1 str; in
          if c == " " || c == "\t" then go (i + 1) else i;
      end = go s.offset;
      n = end - s.offset;
    in s // { offset = end; len = s.len - n; };

  # Consume trailing spaces, an optional comment and the line break.
  # Used to finish a line once its content has been parsed. If there is
  # no line break (at the end of the input) this simply stops.
  skipRestOfLine = s:
    let
      s1 = b.elemAt (skipSpaces s) 1;
      s2 = if atCharY "#" s1
        then b.elemAt (sComment s1) 1
        else s1;
    in if isAtEnd s2
      then [null s2]
      else if isBreakChar (b.substring s2.offset 1 s2.str)
        then [null (b.elemAt (sBreak s2) 1)]
        else [null s2];

  # Skip whitespace, comments and blank lines until the first character of
  # real content. The result is positioned at that character.
  skipToContent = s:
    let
      go = s':
        let
          s1 = skipSpacesTo s';
        in if isAtEnd s1
          then [null s1]
          else let
            c = b.substring s1.offset 1 s1.str;
          in if isBreakChar c
            then go (b.elemAt (sBreak s1) 1)
            else if c == "#"
              then go (b.elemAt (sComment s1) 1)
              else [null s1];
    in go s;

  # Skip the white space in a flow collection: spaces, line breaks and
  # comments. A line break is allowed inside a flow collection, so it
  # does not end the collection.
  #
  # A comment has to be separated from the token in front of it, the
  # same as anywhere else, so "[a]# x" and "[a, b,c# x" are mistakes. The
  # search stops at such a '#' instead of skipping it, which leaves it
  # for the caller to report: it is neither white space nor content.
  flowSpace = s:
    let
      go = s':
        let
          s1 = b.elemAt (skipSpaces s') 1;
        in if isAtEnd s1
          then [null s1]
          else let c = b.substring s1.offset 1 s1.str; in
            if isBreakChar c
              then go (b.elemAt (sBreak s1) 1)
              else if c == "#"
                then
                  if s1.offset > 0
                     && b.substring (s1.offset - 1) 1 s1.str != " "
                     && b.substring (s1.offset - 1) 1 s1.str != "\t"
                     && b.substring (s1.offset - 1) 1 s1.str != "\n"
                     && b.substring (s1.offset - 1) 1 s1.str != "\r"
                  then [null s1]
                  else go (b.elemAt (sComment s1) 1)
              else [null s1];
    in go s;

  # Like `skipToContent`, but a '#' that follows a character directly,
  # with no white space in between, is not a comment: a comment has to
  # be separated from what precedes it. So '"value"# x' is an error
  # while '"value" # x' is a value followed by a comment.
  #
  # A '#' at the start of a line is a comment, as always.
  skipToContentStrict = s:
    let
      go = s':
        let
          s1 = b.elemAt (skipSpaces s') 1;
        in if isAtEnd s1
          then [null s1]
          else let
            c = b.substring s1.offset 1 s1.str;
          in if isBreakChar c
            then go (b.elemAt (sBreak s1) 1)
            else if c == "#"
              then
                if s1.offset > 0
                   && b.substring (s1.offset - 1) 1 s1.str != " "
                   && b.substring (s1.offset - 1) 1 s1.str != "\t"
                   && b.substring (s1.offset - 1) 1 s1.str != "\n"
                   && b.substring (s1.offset - 1) 1 s1.str != "\r"
                then failWith "yaml.comment" "a comment must be preceded by white space" s1
                else go (b.elemAt (sComment s1) 1)
              else [null s1];
    in go s;

  # Consume a single line break if there is one, else succeed without
  # consuming anything.
  optionalBreak = s:
    if isAtEnd s
      then [null s]
      else let c = b.substring s.offset 1 s.str;
      in if isBreakChar c
        then [null (b.elemAt (sBreak s) 1)]
        else [null s];
}
