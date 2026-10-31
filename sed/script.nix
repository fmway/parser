# The parser of the scripts of sed.
#
# It turns the text of a script into a tree of commands:
#
#   { type = "script"; commands = [ ... ]; }
#
# Every command is an attribute set with the address it has, the letter
# of the command and what the command needs:
#
#   { addr; cmd = "s"; pattern; replacement; flags; }
#   { addr; cmd = "y"; from; to; }
#   { addr; cmd = "a"; text; }
#   { addr; cmd = "b"; label; }
#   { addr; cmd = ":"; label; }
#   { addr; cmd = "block"; commands; }
#   { addr; cmd = "d"; }
#
# The address is one of these, or null when the command has none:
#
#   { type = "line";  n; }
#   { type = "last"; }
#   { type = "regex"; program; }
#   { type = "step";  first; step; }
#   { type = "range"; from; to; }        -- `addr1,addr2`
#   { type = "range"; from; relative; } -- `addr1,+N`
#
# The regular expressions of the addresses and of the `s` command are
# compiled while the script is parsed, so that a pattern that is wrong
# is reported as a mistake of the script.

let
  b = builtins;
  regex = import ./regex.nix;

  # ------------------------------------------------------------------
  # The scanner
  # ------------------------------------------------------------------
  #
  # The state of the scanner is
  #
  #   { s; i; extended; }
  #
  # where `s` is the text of the script, `i` is the place the scanner
  # is at and `extended` tells whether the regular expressions are the
  # extended ones.

  ok = value: next: { ok = true; inherit value next; };
  bad = msg: offset: { ok = false; inherit msg offset; };

  charAt = s: i: if i < b.stringLength s then b.substring i 1 s else "";
  at = st: i: charAt st.s i;
  blank = c: c == " " || c == "\t";

  skipBlanks = st: i:
    let
      go = j: if j < b.stringLength st.s && blank (at st j) then go (j + 1) else j;
    in
      go i;

  # The place of the line break that ends the line, or the end of the
  # text when there is none.
  eolIndex = st: i:
    let
      go = j: if j >= b.stringLength st.s then j else if at st j == "\n" then j else go (j + 1);
    in
      go i;

  # The text without the blanks at its front and at its back.
  trim = text:
    let
      len = b.stringLength text;
      front = skipBlanks { s = text; } 0;
      back = len - skipBlanks { s = text; } 0;
    in
      if front >= back then "" else b.substring front (back - front) text;

  # The place where a part that ends at a delimiter ends.
  #
  # A backslash escapes the character after it, and a `]` inside a
  # bracket expression is an ordinary character. The `]` right after
  # the `[` is an ordinary character as well, and the expression goes
  # on after it.
  scanPart = st: delim: start:
    let
      go = i: state:
        let
          c = at st i;
        in
          if c == "" then null
          else if state == "first" then go (i + 1) "in"
          else if state == "in" then (if c == "]" then go (i + 1) "out" else go (i + 1) "in")
          else if c == "\\" then go (i + 2) "out"
          else if c == "[" then go (i + 1) "first"
          else if c == delim then i
          else go (i + 1) "out";
    in
      go start "out";

  # ------------------------------------------------------------------
  # Addresses
  # ------------------------------------------------------------------

  isDigit = c: c >= "0" && c <= "9";
  isAlnum = c: isDigit c || (c >= "a" && c <= "z") || (c >= "A" && c <= "Z");

  # The number that starts at a place.
  scanNumber = st: i:
    let
      go = j: if j < b.stringLength st.s && isDigit (at st j) then go (j + 1) else j;
    in
      go i;

  # An address: the number of a line, the last line, or a regular
  # expression.
  parseAddress = st: i:
    let
      c = at st i;
    in
      if c == "" then ok null i
      else if isDigit c then
        let
          j = scanNumber st i;
          n = b.fromJSON (b.substring i (j - i) st.s);
        in
          # A step: `2~3`
          if at st j == "~" then
            let
              k = scanNumber st (j + 1);
            in
              if k == j + 1 then ok { type = "line"; inherit n; } j
              else ok {
                type = "step";
                first = { type = "line"; inherit n; };
                step = b.fromJSON (b.substring (j + 1) (k - j - 1) st.s);
              } k
          else ok { type = "line"; inherit n; } j
      else if c == "$" then ok { type = "last"; } (i + 1)
      else if c == "/" then
        let
          end = scanPart st "/" (i + 1);
        in
          if end == null then bad "unterminated address" i
          else
            let
              pattern = b.substring (i + 1) (end - i - 1) st.s;
              compiled = regex.compile { pattern = pattern; extended_regex = st.extended; };
            in
              if compiled.type == "error" then bad compiled.value.msg i
              else ok { type = "regex"; program = compiled.value; } (end + 1)
      else ok null i;

  # A range: `addr1,addr2` or `addr1,+N`.
  parseRange = st: i: first:
    let
      c = at st i;
    in
      if c == "," then
        let
          after = i + 1;
        in
          if at st after == "+" then
            # `addr1,+N`: the range is the line of the first address
            # and the N lines after it.
            let
              j = scanNumber st (after + 1);
              n = if j > after + 1 then b.fromJSON (b.substring (after + 1) (j - after - 1) st.s) else 1;
            in
              ok { type = "range"; from = first; relative = n; } j
          else
            let
              r = parseAddress st after;
            in
              if !r.ok then r
              else if r.value == null then bad "expected an address after ','" i
              else ok { type = "range"; from = first; to = r.value; } r.next
      else if c == "+" then
        let
          j = scanNumber st (i + 1);
          n = if j > i + 1 then b.fromJSON (b.substring (i + 1) (j - i - 1) st.s) else 1;
        in
          ok { type = "range"; from = first; relative = n; } j
      else ok first i;

  # ------------------------------------------------------------------
  # Commands
  # ------------------------------------------------------------------

  # The commands that are only a letter.
  simpleCommands = [ "d" "p" "P" "=" "n" "N" "q" "Q" "h" "H" "g" "G" "x" "l" "L" "z" ];

  # A command, with the address it has.
  parseCommand = st: i:
    let
      addrRes = parseAddress st i;
    in
      if !addrRes.ok then addrRes
      else
        let
          addr = addrRes.value;
          rangeRes =
            if addr == null then ok null addrRes.next
            else parseRange st addrRes.next addr;
        in
          if !rangeRes.ok then rangeRes
          else
            let
              a = rangeRes.value;
              # Behind an address there may be blanks.
              k = if a == null then rangeRes.next else skipBlanks st rangeRes.next;
              # A `!` after the address means that the command is run
              # when the address does not match.
              negated = at st k == "!";
              k' = if negated then k + 1 else k;
              cmdRes = parseBody st k' a;
            in
              if !cmdRes.ok then cmdRes
              # A `!` after the address means that the command is run
              # when the address does not match.
              else if negated then ok (cmdRes.value // { negate = true; }) cmdRes.next
              else cmdRes;

  # The command itself.
  parseBody = st: i: addr:
    let
      c = at st i;
    in
      if c == "" then bad "unexpected end of script" i
      else if c == "{" then parseBlock st i addr
      else if c == "s" then parseSubstitute st i addr
      else if c == "y" then parseTransliterate st i addr
      else if c == "a" || c == "i" || c == "c" then parseText st i addr c
      else if c == "b" || c == "t" || c == "T" then parseBranch st i addr c
      else if c == ":" then parseLabel st i addr
      else if b.elem c simpleCommands then ok { inherit addr; cmd = c; } (i + 1)
      else bad ("unknown command: '" + c + "'") i;

  # A block: `{ ... }`
  parseBlock = st: i: addr:
    let
      loop = commands: j:
        let
          k = skipBlanks st j;
          c = at st k;
        in
          if c == "" then bad "unterminated `{'" i
          else if c == "}" then ok { inherit addr; cmd = "block"; inherit commands; } (k + 1)
          else if c == "\n" then loop commands (k + 1)
          else if c == "#" then loop commands (eolIndex st k + 1)
          else
            let
              cmd = parseCommand st k;
            in
              if !cmd.ok then cmd
              else
                let
                  after = skipBlanks st cmd.next;
                  c2 = at st after;
                in
                  if c2 == ";" then loop (commands ++ [ cmd.value ]) (after + 1)
                  else if c2 == "\n" then loop (commands ++ [ cmd.value ]) (after + 1)
                  else if c2 == "}" then loop (commands ++ [ cmd.value ]) after
                  else bad "extra characters after command" after;
    in
      loop [] (i + 1);

  # `s/pattern/replacement/flags`
  parseSubstitute = st: i: addr:
    let
      delim = at st (i + 1);
    in
      if delim == "" || delim == "\n" || blank delim || isAlnum delim || delim == "\\"
      then bad "unterminated `s' command" i
      else
        let
          patternEnd = scanPart st delim (i + 2);
        in
          if patternEnd == null then bad "unterminated `s' command" i
          else
            let
              pattern = b.substring (i + 2) (patternEnd - i - 2) st.s;
              replStart = patternEnd + 1;
              replEnd = scanPart st delim replStart;
            in
              if replEnd == null then bad "unterminated `s' command" i
              else
                let
                  replacement = b.substring replStart (replEnd - replStart) st.s;
                  flagsRes = parseFlags st (replEnd + 1);
                in
                  if !flagsRes.ok then flagsRes
                  else
                    let
                      flags = flagsRes.value;
                      # The pattern is compiled with the flags of the
                      # command, so that the `I` and the `M` flags are
                      # known when it is.
                      compiled = regex.compile {
                        pattern = pattern;
                        extended_regex = st.extended;
                        icase = flags.I;
                        multiline = flags.M;
                      };
                    in
                      if compiled.type == "error" then bad compiled.value.msg i
                      else ok {
                        inherit addr;
                        cmd = "s";
                        pattern = compiled.value;
                        replacement = parseReplacement replacement;
                        inherit flags;
                      } flagsRes.next;

  # The parts of a replacement.
  #
  # A part is either some text, the whole match (`&`) or a group
  # (`\1` to `\9`).
  parseReplacement = text:
    let
      go = i: parts:
        let
          c = charAt text i;
        in
          if c == "" then parts
          else if c == "&" then go (i + 1) (parts ++ [ { type = "match"; } ])
          else if c == "\\" then
            let
              d = charAt text (i + 1);
            in
              if d == "" then parts ++ [ { type = "text"; text = "\\"; } ]
              else if d == "n" then go (i + 2) (parts ++ [ { type = "text"; text = "\n"; } ])
              else if d == "t" then go (i + 2) (parts ++ [ { type = "text"; text = "\t"; } ])
              else if d == "r" then go (i + 2) (parts ++ [ { type = "text"; text = "\r"; } ])
              else if d >= "1" && d <= "9" then go (i + 2) (parts ++ [ { type = "group"; index = b.fromJSON d; } ])
              # A line break behind a backslash is nothing.
              else if d == "\n" then go (i + 2) parts
              else go (i + 2) (parts ++ [ { type = "text"; text = d; } ])
          else go (i + 1) (parts ++ [ { type = "text"; text = c; } ]);
    in
      go 0 [];

  # The flags of the `s` command.
  parseFlags = st: i:
    let
      go = j: flags:
        let
          c = charAt st.s j;
        in
          if c == "" then ok flags j
          else if c == " " || c == "\t" then
            # What is behind the flags is ignored.
            ok flags (eolIndex st j)
          else if c == ";" || c == "\n" || c == "}" then
            # The command ends here.
            ok flags j
          else if c == "g" then
            if flags.g then bad "multiple 'g' options to 's' command" j
            else go (j + 1) (flags // { g = true; })
          else if c == "p" then go (j + 1) (flags // { p = true; })
          else if c == "I" then go (j + 1) (flags // { I = true; })
          else if c == "M" then go (j + 1) (flags // { M = true; })
          else if c == "w" then bad "the 'w' option of 's' is not supported" j
          else if c == "e" then bad "the 'e' option of 's' is not supported" j
          else if isDigit c then
            let
              k = scanNumber st j;
              n = b.fromJSON (b.substring j (k - j) st.s);
            in
              if flags.occurrence != null then bad "multiple occurrence options to 's' command" j
              else go k (flags // { occurrence = n; })
          else bad ("unknown option to 's': '" + c + "'") j;
    in
      go i { g = false; p = false; I = false; M = false; occurrence = null; };

  # `y/from/to/`
  parseTransliterate = st: i: addr:
    let
      delim = at st (i + 1);
    in
      if delim == "" || delim == "\n" || blank delim || isAlnum delim || delim == "\\"
      then bad "unterminated `y' command" i
      else
        let
          fromEnd = scanPart st delim (i + 2);
        in
          if fromEnd == null then bad "unterminated `y' command" i
          else
            let
              from = b.substring (i + 2) (fromEnd - i - 2) st.s;
              toStart = fromEnd + 1;
              toEnd = scanPart st delim toStart;
            in
              if toEnd == null then bad "unterminated `y' command" i
              else
                let
                  to = b.substring toStart (toEnd - toStart) st.s;
                  fromChars = unescapeChars from;
                  toChars = unescapeChars to;
                in
                  if b.length fromChars != b.length toChars
                  then bad "'y' command strings have different lengths" i
                  else ok {
                    inherit addr;
                    cmd = "y";
                    from = fromChars;
                    to = toChars;
                  } (toEnd + 1);

  # The characters of a text, without the backslashes that escape them.
  unescapeChars = text:
    let
      go = i: chars:
        let
          c = charAt text i;
        in
          if c == "" then chars
          else if c == "\\" then
            let
              d = charAt text (i + 1);
            in
              if d == "" then chars ++ [ "\\" ]
              else if d == "n" then go (i + 2) (chars ++ [ "\n" ])
              else if d == "t" then go (i + 2) (chars ++ [ "\t" ])
              else if d == "r" then go (i + 2) (chars ++ [ "\r" ])
              else go (i + 2) (chars ++ [ d ])
          else go (i + 1) (chars ++ [ c ]);
    in
      go 0 [];

  # `a text`, `i text` and `c text`.
  #
  # The text is either the rest of the line, or the lines that follow
  # a backslash. In the second form every line but the last ends with a
  # backslash, and the text keeps the blanks that are in front of it.
  parseText = st: i: addr: cmd:
    let
      c = at st (i + 1);
    in
      if c == "\\" then
        let
          collect = j: lines:
            let
              e = eolIndex st j;
              line = b.substring j (e - j) st.s;
              hasBackslash = b.stringLength line > 0 && b.substring (e - 1) 1 st.s == "\\";
            in
              if e >= b.stringLength st.s then
                ok { text = b.concatStringsSep "\n" (lines ++ [ line ]); } e
              else if hasBackslash then
                collect (e + 1) (lines ++ [ (b.substring 0 (b.stringLength line - 1) line) ])
              else
                ok { text = b.concatStringsSep "\n" (lines ++ [ line ]); } (e + 1);
        in
          if at st (i + 2) != "\n" then bad "expected a line break after '\\'" (i + 1)
          else
            let
              r = collect (i + 3) [];
            in
              if !r.ok then r
              else ok { inherit addr cmd; text = r.value.text; } r.next
      else
        let
          e = eolIndex st (i + 1);
          text = b.substring (i + 1) (e - i - 1) st.s;
        in
          ok { inherit addr cmd; text = trim text; } e;

  # The label of a `b`, `t` or `T` command, or of a `:` command.
  #
  # The label ends at the `;` or at the end of the line, and the
  # blanks around it are not part of it.
  readLabel = st: i:
    let
      go = j:
        let
          c = charAt st.s j;
        in
          if c == "" || c == ";" || c == "\n" then j else go (j + 1);
      end = go i;
      text = b.substring i (end - i) st.s;
      len = b.stringLength text;
      front = skipBlanks { s = text; } 0;
      back = len - skipBlanks { s = text; } 0;
    in
      {
        label = if front >= back then "" else b.substring front (back - front) text;
        next = i + 1 + back;
      };

  # `b label`, `t label` and `T label`
  parseBranch = st: i: addr: cmd:
    let
      l = readLabel st (i + 1);
    in
      ok {
        inherit addr cmd;
        label = if l.label == "" then null else l.label;
      } l.next;

  # `: label`
  parseLabel = st: i: addr:
    let
      l = readLabel st (i + 1);
    in
      if l.label == "" then bad "empty label" i
      else ok { inherit addr; cmd = ":"; label = l.label; } l.next;

  # ------------------------------------------------------------------
  # The whole script
  # ------------------------------------------------------------------

  # Give the commands their numbers.
  #
  # The numbers tell the commands apart, so that the state of a range
  # can be kept for the command that has it.
  numberCommands = ast: counter:
    if ast.type == "script" || ast.type == "block" then
      let
        go = commands: i: c:
          if i >= b.length commands then { commands = commands; count = c; }
          else
            let
              cmd = b.elemAt commands i;
              r =
                if cmd.cmd == "block"
                then
                  let
                    inner = numberCommands { type = "block"; commands = cmd.commands; } (c + 1);
                  in {
                    cmd = cmd // { id = c; commands = inner.ast.commands; };
                    count = inner.count;
                  }
                else { cmd = cmd // { id = c; }; count = c + 1; };
            in
              go (b.genList (j: if j == i then r.cmd else b.elemAt commands j) (b.length commands)) (i + 1) r.count;
      in
        let
          r = go ast.commands 0 counter;
        in
          { ast = ast // { commands = r.commands; }; count = r.count; }
    else { ast = ast; count = counter; };

  parseScript = extended: s:
    let
      st = { inherit s extended; i = 0; };
      loop = commands: i:
        let
          k = skipBlanks st i;
          c = at st k;
        in
          if c == "" then ok { type = "script"; inherit commands; } k
          else if c == "\n" then loop commands (k + 1)
          else if c == "#" then
            # A comment goes to the end of the line.
            let
              e = eolIndex st k;
            in
              loop commands (if e < b.stringLength s then e + 1 else e)
          else if c == "}" then bad "unexpected `}'" k
          else
            let
              cmd = parseCommand st k;
            in
              if !cmd.ok then cmd
              else
                let
                  after = skipBlanks st cmd.next;
                  c2 = at st after;
                in
                  if c2 == ";" then loop (commands ++ [ cmd.value ]) (after + 1)
                  else if c2 == "\n" then loop (commands ++ [ cmd.value ]) (after + 1)
                  else if c2 == "" then ok { type = "script"; commands = commands ++ [ cmd.value ]; } after
                  else bad "extra characters after command" after;
    in
      loop [] 0;
in {
  # Parse a script.
  #
  # The result is either
  #
  #   { type = "success"; value = <the script>; }
  #   { type = "error";   value = { msg; offset; }; }
  safeParse = { extended_regex ? false }: s:
    let
      res = parseScript extended_regex s;
    in
      if !res.ok
      then { type = "error"; value = { msg = res.msg; offset = res.offset; }; }
      else { type = "success"; value = (numberCommands res.value 0).ast; };

  # The pieces of the parser, for the callers that want them.
  modules = {
    parseScript = parseScript;
    parseAddress = parseAddress;
    parseReplacement = parseReplacement;
    parseFlags = parseFlags;
  };
}
