let
  b = builtins;
  style = import ../utils/style.nix;
  stringMultiply = str: size:
    b.concatStringsSep "" (b.genList (_: str) size);

  splitAt = sep: str:
    let
      parts = b.split sep str;
      even = i: i - (i / 2) * 2 == 0;
    in
      b.filter (x: x != null)
        (b.genList (i: if even i then b.elemAt parts i else null) (b.length parts));

  positionAt = str: offset:
    let
      len = b.stringLength str;
      off = if offset < 0 then 0 else if offset > len then len else offset;
      parts = b.split "[\n]" (b.substring 0 off str);
      last = b.elemAt parts (b.length parts - 1);
    in {
      line = (b.length parts + 1) / 2;
      col = b.stringLength last;
    };

  errorMessage = str: e:
    let
      offset = e.offset or 0;
      len = b.stringLength str;
      pos =
        if e ? line && e ? col
        then { line = e.line; col = e.col; }
        else positionAt str offset;
      line = pos.line;
      col = pos.col;
      lines = splitAt "[\n]" str;
      here = b.elemAt lines (line - 1);
      prev = if line > 1 then b.elemAt lines (line - 2) else null;
      next = if line < b.length lines then b.elemAt lines line else null;
      atEnd = offset >= len && here == "";
      shown =
        if atEnd && prev != null
        then [ { no = line - 1; text = prev; } ]
             ++ (if next == null || next == "" then [] else [ { no = line + 1; text = next; } ])
        else
          (if prev == null then [] else [ { no = line - 1; text = prev; } ])
          ++ [ { no = line; text = here; } ]
          ++ (if next == null || next == "" then [] else [ { no = line + 1; text = next; } ]);
      shownAt = if atEnd && prev != null then line - 1 else line;
      getDigit = i: b.stringLength (toString i);
      numWidth = getDigit ((b.elemAt shown (b.length shown - 1)).no) + 1;
      start = numWidth + 2;
      mark =
        let
          text = if atEnd && prev != null then prev else here;
          markCol = if atEnd && prev != null then b.stringLength text else col;
          width =
            let
              go = ps: w:
                if ps == [] then w
                else
                  let
                    p = b.elemAt ps 0;
                    rest = b.tail ps;
                    w' = w + b.stringLength p;
                  in
                    if rest == []
                    then w'
                    else go rest (w' + (8 - (w' - (w' / 8) * 8)));
            in go (splitAt "[\t]" (b.substring 0 markCol text)) start;
        in
          stringMultiply " " (width - start) + "${style.red "^"} ${style.magenta (e.msg or "invalid template")}";
      show = l:
        let
          no = toString l.no;
        in
          stringMultiply " " (numWidth - getDigit no) + no + "| " + l.text;
    in
      "${style.red (e.context or "template")}\n"
      + b.concatStringsSep "\n" (
          b.map
            (l: show l + (if l.no == shownAt then "\n" + stringMultiply " " numWidth + "| " + mark else ""))
            shown
        );
in {
  inherit errorMessage;
}
