# The runtime of the scripts of sed.
#
# It runs a script over a text and gives back the text that the script
# produced.
#
# The state of a run is
#
#   { pattern; hold; lineNo; frames; ranges; substituted; output; ... }
#
# where `pattern` is the pattern space and `hold` the hold space. The
# `frames` are the blocks that the run is in, the innermost one first,
# and the `ranges` hold the state of the ranges of the addresses.
#
# The run is driven by a worklist, so that the depth of the stack of
# Nix does not depend on the length of the text.

let
  b = builtins;
  regex = import ./regex.nix;

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  # The lines of a text, and whether the last one ends with a line
  # break.
  #
  # A line break at the end of the text does not make another line, and
  # a text that is empty has no lines at all.
  #
  # `builtins.split` puts the text and the matches in turn, so the
  # matches are left out.
  lines = text:
    let
      parts = b.split "\n" text;
      count = b.length parts;
      even = i: i - (i / 2) * 2 == 0;
      texts = b.filter (x: x != null) (
        b.genList (i: if even i then b.elemAt parts i else null) count
      );
      length = b.stringLength text;
      lastChomped = length > 0 && b.substring (length - 1) 1 text == "\n";
    in
      if text == "" then
        { lines = []; inherit lastChomped; }
      else if count > 1 && b.elemAt parts (count - 1) == ""
      then { lines = b.genList (i: b.elemAt texts i) (b.length texts - 1); lastChomped = true; }
      else { lines = texts; inherit lastChomped; };

  # The places of the labels of a list of commands.
  labelsOf = commands:
    let
      res = b.foldl' (acc: cmd:
        if cmd.cmd == ":" && !(b.hasAttr cmd.label acc.labels)
        then {
          labels = acc.labels // { ${cmd.label} = acc.count; };
          count = acc.count + 1;
        }
        else { labels = acc.labels; count = acc.count + 1; }
      ) { labels = {}; count = 0; } commands;
    in
      res.labels;

  # Is the character one that a terminal shows?
  printable = c: c >= " " && c != "\x7f";

  # The text as the `l` command shows it.
  #
  # The characters that are not shown as they are are shown as an
  # escape: a backslash for the ones that have one, and the number of
  # the character in octal for the others.
  listText = text:
    let
      go = i: out:
        let
          c = b.substring i 1 text;
        in
          if c == "" then out
          else if c == "\\" then go (i + 1) (out ++ [ "\\\\" ])
          else if c == "\t" then go (i + 1) (out ++ [ "\\t" ])
          else if c == "\r" then go (i + 1) (out ++ [ "\\r" ])
          else if c == "\n" then go (i + 1) (out ++ [ "\\n" ])
          else if printable c then go (i + 1) (out ++ [ c ])
          else go (i + 1) (out ++ [ ("\\" + (pad3 (regex.ord c))) ]);
      # The number of a character in octal, with three digits.
      pad3 = n:
        let
          digits = "01234567";
          high = b.substring (n / 64) 1 digits;
          mid = b.substring (mod (n / 8) 8) 1 digits;
          low = b.substring (mod n 8) 1 digits;
        in
          high + mid + low;
    in
      b.concatStringsSep "" (go 0 []);

  # ------------------------------------------------------------------
  # Addresses
  # ------------------------------------------------------------------

  # Does an address match the current line?
  #
  # The addresses of a range are not matched here, they are matched by
  # the range itself.
  addrMatch = addr: st:
    if addr.type == "line" then
      st.lineNo == addr.n
    else if addr.type == "last" then
      st.lineNo == st.total
    else if addr.type == "regex" then
      (regex.match addr.program st.pattern) != null
    else if addr.type == "step" then
      # The line of the first address, and every step-th line after it.
      st.lineNo >= lineNoOf addr.first
      && mod (st.lineNo - lineNoOf addr.first) addr.step == 0
    else true;

  # The rest of a division, the way Nix divides.
  mod = x: y: x - y * (x / y);

  # The number of the line that an address stands for.
  lineNoOf = addr:
    if addr.type == "line" then addr.n
    else if addr.type == "last" then -1
    else 0;

  # The address of a command, with the state of the ranges.
  #
  # The result says whether the command is to be run, and what the
  # state of the run is afterwards.
  checkAddr = cmd: st:
    let
      addr = cmd.addr;
      # A `!` after the address means that the command is run when the
      # address does not match.
      negate = cmd.negate or false;
      # The result of the check, with the `!` taken into account.
      done = res:
        if negate then { run = !res.run; st = res.st; } else res;
    in
      if addr == null then done { run = true; inherit st; }
      else if addr.type != "range" then
        done (if addrMatch addr st then { run = true; inherit st; } else { run = false; inherit st; })
      else
        done (
        let
          key = toString cmd.id;
          state = st.ranges.${key} or { active = false; left = 0; };
          put = new: s: s // { ranges = s.ranges // { ${key} = new; }; };
          # The line where the range starts.
          startOk =
            if addr.from.type == "line" && addr.from.n == 0
            then st.lineNo == 1
            else addrMatch addr.from st;
          # The line where the range ends.
          endOk = addrMatch addr.to st;
        in
          if (addr.relative or null) != null then
            # `addr1,+N`: the range is the line of the first address
            # and the N lines after it.
            if state.active then
              if state.left > 0 then
                { run = true; st = put (state // { left = state.left - 1; }) st; }
              else
                { run = false; st = put { active = false; left = 0; } st; }
            else if startOk then
              { run = true; st = put { active = true; left = addr.relative; } st; }
            else { run = false; inherit st; }
          else if state.active then
            # `addr1,addr2`: the range goes on until the second address
            # matches.
            if endOk
            then { run = true; st = put { active = false; left = 0; } st; }
            else { run = true; inherit st; }
          else if startOk then
            # The range starts here. The second address is looked for
            # from the next line on, unless the range starts at the
            # line 0, which is before the first line.
            let
              endsNow = addr.from.type == "line" && addr.from.n == 0 && endOk;
            in
              if endsNow
              then { run = true; st = put { active = false; left = 0; } st; }
              else { run = true; st = put { active = true; left = 0; } st; }
          else { run = false; inherit st; }
        );

  # ------------------------------------------------------------------
  # The substitution
  # ------------------------------------------------------------------

  # The matches of a pattern in a text.
  #
  # At most `limit` matches are looked for; a limit of null means that
  # all of them are.
  matchesOf = program: text: limit:
    let
      go = pos: found:
        let
          m = regex.matchFrom program text pos;
        in
          if m == null then found
          else if limit != null && b.length found >= limit then found
          else
            let
              next = if m.end > m.start then m.end else m.start + 1;
            in
              go next (found ++ [ m ]);
    in
      go 0 [];

  # The text of a replacement, for a match.
  replacementText = cmd: text: m:
    b.concatStringsSep "" (
      b.map (part:
        if part.type == "text" then
          part.text
        else if part.type == "match" then
          b.substring m.start (m.end - m.start) text
        else
          let
            g = b.elemAt m.groups (part.index - 1);
          in
            if g == null then "" else b.substring g.start (g.end - g.start) text
      ) cmd.replacement
    );

  # The text with the matches replaced.
  #
  # The way GNU sed does it: the matches are looked for one by one,
  # and every match is counted, except a match that is empty and that
  # comes right after another match. The match that reaches the number
  # of the occurrence is replaced, and the ones before it are copied
  # as they are. When the `g` flag is there, the search goes on after
  # every match that was replaced.
  substitute = cmd: text:
    let
      flags = cmd.flags;
      # The number of the match that is replaced.
      number = if flags.occurrence != null then flags.occurrence else 1;
      length = b.stringLength text;
      matches = matchesOf cmd.pattern text null;

      # The loop over the matches.
      go = ms: count: lastEnd: start: acc: replaced:
        if ms == [] then
          { text = acc + (b.substring start (length - start) text); inherit replaced; }
        else
          let
            m = b.elemAt ms 0;
            rest = b.tail ms;
            offset = m.start;
            matched = m.end - m.start;
            # The text before the match.
            before = if start < offset then b.substring start (offset - start) text else "";
            # A match that is empty and that comes right after another
            # match is not counted.
            countable = matched > 0 || count == 0 || offset > lastEnd;
            newCount = if countable then count + 1 else count;
          in
            if countable && newCount >= number then
              let
                acc' = acc + before + (replacementText cmd text m);
              in
                if flags.g then
                  go rest newCount m.end m.end acc' true
                else
                  {
                    text = acc' + (b.substring m.end (length - m.end) text);
                    replaced = true;
                  }
            else
              # The match is not replaced. An empty match takes one
              # character with it, unless there is nothing left.
              let
                skip =
                  if matched > 0 then matched
                  else if start < length then 1
                  else null;
              in
                if skip == null then
                  { text = acc + before; inherit replaced; }
                else
                  go rest newCount m.end (offset + skip)
                    (acc + before + (b.substring offset skip text))
                    replaced;
    in
      let
        res = go matches 0 0 0 "" false;
      in
        if !res.replaced then null
        else { text = res.text; matched = true; };

  # ------------------------------------------------------------------
  # The run
  # ------------------------------------------------------------------

  # The commands that are run, and the state of the run.
  run = { script, text, quiet ? false }:
    let
      allLines = lines text;

      # The frame of the whole script.
      topFrame = {
        commands = script.commands;
        pc = 0;
        labels = labelsOf script.commands;
      };

      # Does the line at a place end with a line break?
      #
      # Only the last line of the text can be without one.
      chompedAt = i: i < b.length allLines.lines - 1 || allLines.lastChomped;

      init = {
        key = 0;
        lines = allLines.lines;
        total = b.length allLines.lines;
        lineIndex = 0;
        lineNo = 0;
        pattern = "";
        hold = "";
        # Whether the line in the pattern space ends with a line
        # break. The output does not have one either when it does not.
        chomped = true;
        frames = [ topFrame ];
        ranges = {};
        substituted = false;
        output = [];
        before = [];
        after = [];
        cycle = "start";
        done = false;
        jumped = false;
        quiet = quiet;
      };

      # Does the text end with a line break?
      endsWithBreak = t:
        b.stringLength t > 0 && b.substring (b.stringLength t - 1) 1 t == "\n";

      # The output of a text that ends with a line break.
      #
      # When what was printed before did not end with a line break, one
      # is put in front, the way GNU sed does.
      put = t: st:
        let
          last = if st.output == [] then "" else b.elemAt st.output (b.length st.output - 1);
          break = if st.output != [] && !(endsWithBreak last) then "\n" else "";
        in
          st // { output = st.output ++ [ (break + t) ]; };

      # The output of the pattern space.
      #
      # The line break at the end of it is only there when the line it
      # came from had one.
      putPattern = st:
        let
          last = if st.output == [] then "" else b.elemAt st.output (b.length st.output - 1);
          break = if st.output != [] && !(endsWithBreak last) then "\n" else "";
          t = if st.chomped then st.pattern + "\n" else st.pattern;
        in
          st // { output = st.output ++ [ (break + t) ]; };

      # Move on to the next command.
      advance = st:
        let
          f = b.head st.frames;
        in
          st // {
            frames = [ (f // { pc = f.pc + 1; }) ] ++ b.tail st.frames;
            jumped = false;
          };

      # Read the next line and start the cycle.
      startCycle = st:
        if st.lineIndex >= st.total then
          st // { done = true; }
        else
          st // {
            lineIndex = st.lineIndex + 1;
            lineNo = st.lineNo + 1;
            pattern = b.elemAt st.lines st.lineIndex;
            chomped = chompedAt st.lineIndex;
            before = [];
            after = [];
            substituted = false;
            cycle = "run";
            frames = [ topFrame ];
          };

      # The end of the cycle: the pattern space is printed and the
      # next line is read.
      endCycle = st:
        (printCycle st) // { before = []; after = []; cycle = "start"; };

      # What the end of a cycle prints: the text that was put in front
      # of the pattern space, the pattern space itself, and the text
      # that was put after it.
      printCycle = st:
        let
          st1 = b.foldl' (a: t: put t a) st st.before;
          st2 = if st.quiet then st1 else putPattern st1;
        in
          b.foldl' (a: t: put t a) st2 st.after;

      # The end of the run.
      quit = st: st // { done = true; cycle = "quit"; };

      # The text of the pattern space up to the first line break.
      upToNewline = text:
        let
          parts = b.split "\n" text;
        in
          b.elemAt parts 0;

      # A command that is run.
      execCommand = st: cmd:
        let
          c = cmd.cmd;
        in
          if c == "s" then
            let
              res = substitute cmd st.pattern;
            in
              if res == null then st
              else
                let
                  st1 = st // { pattern = res.text; substituted = true; };
                in
                  if cmd.flags.p then put (res.text + "\n") st1 else st1
          else if c == "y" then
            st // {
              pattern = transliterate cmd st.pattern;
            }
          else if c == "d" then
            # The pattern space is dropped and the next line is read.
            st // { cycle = "start"; pattern = ""; }
          else if c == "p" then
            put (st.pattern + "\n") st
          else if c == "P" then
            put (upToNewline st.pattern + "\n") st
          else if c == "=" then
            put ((toString st.lineNo) + "\n") st
          else if c == "l" then
            put ((listText st.pattern) + "$\n") st
          else if c == "L" then
            put ((listText st.pattern) + "$\n") st
          else if c == "n" then
            # The pattern space is printed and the next line is read
            # into it. When there is no next line, the run ends.
            if st.lineIndex >= st.total then quit st
            else
              let
                st1 = if st.quiet then st else putPattern st;
              in
                st1 // {
                  lineIndex = st.lineIndex + 1;
                  lineNo = st.lineNo + 1;
                  pattern = b.elemAt st.lines st.lineIndex;
                  chomped = chompedAt st.lineIndex;
                }
          else if c == "N" then
            # The next line is added to the pattern space.
            if st.lineIndex >= st.total then quit st
            else
              st // {
                lineIndex = st.lineIndex + 1;
                lineNo = st.lineNo + 1;
                pattern = st.pattern + "\n" + (b.elemAt st.lines st.lineIndex);
                chomped = chompedAt st.lineIndex;
              }
          else if c == "q" then
            # The pattern space is printed and the run ends.
            (printCycle st) // { done = true; }
          else if c == "Q" then
            st // { done = true; }
          else if c == "h" then
            st // { hold = st.pattern; }
          else if c == "H" then
            st // { hold = st.hold + "\n" + st.pattern; }
          else if c == "g" then
            st // { pattern = st.hold; }
          else if c == "G" then
            st // { pattern = st.pattern + "\n" + st.hold; }
          else if c == "x" then
            st // { pattern = st.hold; hold = st.pattern; }
          else if c == "z" then
            # The pattern space is emptied.
            st // { pattern = ""; }
          else if c == "a" then
            st // { after = st.after ++ [ (cmd.text + "\n") ]; }
          else if c == "i" then
            st // { before = st.before ++ [ (cmd.text + "\n") ]; }
          else if c == "c" then
            # The pattern space is replaced and the cycle ends. The
            # text is a whole line, so it ends with a line break.
            st // { pattern = cmd.text; chomped = true; cycle = "print"; }
          else if c == "b" || c == "t" || c == "T" then
            jump st cmd c
          else if c == ":" then
            st
          else if c == "block" then
            # The block is run in a frame of its own, and the command
            # that holds it is done.
            let
              parent = b.head st.frames;
            in
              st // {
                frames = [
                  {
                    commands = cmd.commands;
                    pc = 0;
                    labels = labelsOf cmd.commands;
                  }
                ] ++ [ (parent // { pc = parent.pc + 1; }) ] ++ b.tail st.frames;
              }
          else st;

      # A jump to a label.
      #
      # The label is looked for in the block that the run is in. When
      # it is not there, the run goes on after the whole script.
      jump = st: cmd: c:
        let
          frame = b.head st.frames;
          # The `t` command jumps when a substitution happened since
          # the last time it was used.
          go =
            if c == "b" then true
            else if c == "t" then st.substituted
            else ! st.substituted;
          # The label is looked for in the block.
          target =
            if cmd.label == null then null
            else if b.hasAttr cmd.label frame.labels then frame.labels.${cmd.label}
            else null;
        in
          if !go then
            st // { substituted = if c == "b" then st.substituted else false; }
          else if target == null then
            # The label is not in this block: the run goes on after the
            # whole script.
            if cmd.label == null then
              st // { jumped = true; frames = [ (frame // { pc = b.length frame.commands; }) ] ++ b.tail st.frames; }
            else
              st // { jumped = true; frames = [ (frame // { pc = b.length frame.commands; }) ] ++ b.tail st.frames; }
          else
            st // {
              jumped = true;
              substituted = false;
              frames = [ (frame // { pc = target; }) ] ++ b.tail st.frames;
            };

      # The text with the characters of one translated.
      transliterate = cmd: text:
        let
          go = i: out:
            let
              c = b.substring i 1 text;
            in
              if c == "" then out
              else
                let
                  index = indexOfChar cmd.from c;
                in
                  if index == null then go (i + 1) (out ++ [ c ])
                  else go (i + 1) (out ++ [ (b.elemAt cmd.to index) ]);
          indexOfChar = chars: c:
            let
              go2 = j:
                if j >= b.length chars then null
                else if b.elemAt chars j == c then j
                else go2 (j + 1);
            in
              go2 0;
        in
          b.concatStringsSep "" (go 0 []);

      # One step of the run.
      step = st:
        if st.done then st
        else if st.cycle == "start" then startCycle st
        else if st.cycle == "print" then endCycle st
        else if st.cycle == "quit" then st
        else
          let
            frame = b.head st.frames;
            cmd =
              if frame.pc >= b.length frame.commands then null
              else b.elemAt frame.commands frame.pc;
          in
            if cmd == null then
              # The end of the innermost block.
              if b.length st.frames <= 1 then endCycle st
              else st // { frames = b.tail st.frames; }
            else
              let
                addrRes = checkAddr cmd st;
              in
                if !addrRes.run then advance addrRes.st
                else
                let
                  st1 = execCommand addrRes.st cmd;
                in
                  if st1.jumped then
                    # The command jumped somewhere else, so the place
                    # is not moved on.
                    st1 // { jumped = false; }
                  else if b.length st1.frames > b.length addrRes.st.frames then
                    # A block was entered, and the command that holds
                    # it is done already.
                    st1
                  else advance st1;

      work = b.genericClosure {
        startSet = [ init ];
        operator = st:
          if st.done then []
          else [ ((step st) // { key = st.key + 1; }) ];
      };
      last = b.foldl' (a: s: s) init work;
    in
      b.concatStringsSep "" last.output;
in {
  run = run;
  modules = {
    inherit lines matchesOf substitute addrMatch labelsOf listText;
  };
}
