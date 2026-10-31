# The test suite of the sed module.
#
# The expectations are the ones of GNU sed, which was used to make them.
# The suite does not run sed itself, so that it gives the same result
# everywhere.
#
# Usage:
#
#   nix eval --impure --json --expr 'import ./sed/tests.nix { }' \
#     --apply 't: t.summary'
{ sed ? import ./default.nix }:
let
  b = builtins;

  # The text that most of the cases run over.
  text = "foo bar\nbaz qux\nfoo again\nlast line\n";

  # The cases: a script and what it gives.
  cases = [
    { script = "s/foo/bar/"; expected = "bar bar\nbaz qux\nbar again\nlast line\n"; }
    { script = "s/foo/bar/g"; expected = "bar bar\nbaz qux\nbar again\nlast line\n"; }
    { script = "s/o/0/g"; expected = "f00 bar\nbaz qux\nf00 again\nlast line\n"; }
    { script = "s/^/>/"; expected = ">foo bar\n>baz qux\n>foo again\n>last line\n"; }
    { script = "s/$/</"; expected = "foo bar<\nbaz qux<\nfoo again<\nlast line<\n"; }
    { script = "s/\\(a\\)\\(b\\)/\\2\\1/"; expected = "foo bar\nbaz qux\nfoo again\nlast line\n"; }
    { script = "s/\\(a\\|b\\)/X/"; expected = "foo Xar\nXaz qux\nfoo Xgain\nlXst line\n"; }
    { script = "s/[abc]/X/g"; expected = "foo XXr\nXXz qux\nfoo XgXin\nlXst line\n"; }
    { script = "s/[^abc]/X/g"; expected = "XXXXbaX\nbaXXXXX\nXXXXaXaXX\nXaXXXXXXX\n"; }
    { script = "s/[[:digit:]]/N/g"; expected = "foo bar\nbaz qux\nfoo again\nlast line\n"; }
    { script = "s/\\w\\+/W/g"; expected = "W W\nW W\nW W\nW W\n"; }
    { script = "s/\\bfoo\\b/X/"; expected = "X bar\nbaz qux\nX again\nlast line\n"; }
    { script = "s/a\\{2\\}/X/"; expected = "foo bar\nbaz qux\nfoo again\nlast line\n"; }
    { script = "s/a\\{2,3\\}/X/g"; expected = "foo bar\nbaz qux\nfoo again\nlast line\n"; }
    { script = "s/a\\{2,\\}/X/g"; expected = "foo bar\nbaz qux\nfoo again\nlast line\n"; }
    { script = "s/./X/3"; expected = "foX bar\nbaX qux\nfoX again\nlaXt line\n"; }
    { script = "s/x*/-/g"; expected = "-f-o-o- -b-a-r-\n-b-a-z- -q-u-\n-f-o-o- -a-g-a-i-n-\n-l-a-s-t- -l-i-n-e-\n"; }
    { script = "s/a/b/I"; expected = "foo bbr\nbbz qux\nfoo bgain\nlbst line\n"; }
    { script = "s/A/b/I"; expected = "foo bbr\nbbz qux\nfoo bgain\nlbst line\n"; }
    { script = "s/a/b/gp"; expected = "foo bbr\nfoo bbr\nbbz qux\nbbz qux\nfoo bgbin\nfoo bgbin\nlbst line\nlbst line\n"; }
    { script = "s/a/b/p"; expected = "foo bbr\nfoo bbr\nbbz qux\nbbz qux\nfoo bgain\nfoo bgain\nlbst line\nlbst line\n"; }
    { script = "s/a/b/2"; expected = "foo bar\nbaz qux\nfoo agbin\nlast line\n"; }
    { script = "s/a/b/3"; expected = "foo bar\nbaz qux\nfoo again\nlast line\n"; }
    { script = "s/\\(a\\)/\\1\\1/"; expected = "foo baar\nbaaz qux\nfoo aagain\nlaast line\n"; }
    { script = "s/\\(a\\)/&-&/"; expected = "foo ba-ar\nba-az qux\nfoo a-again\nla-ast line\n"; }
    { script = "s/\\//X/g"; expected = "foo bar\nbaz qux\nfoo again\nlast line\n"; }
    { script = "s/./\\n/g"; expected = "\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n"; }
    { script = "y/abc/xyz/"; expected = "foo yxr\nyxz qux\nfoo xgxin\nlxst line\n"; }
    { script = "p"; expected = "foo bar\nfoo bar\nbaz qux\nbaz qux\nfoo again\nfoo again\nlast line\nlast line\n"; }
    { script = "d"; expected = ""; }
    { script = "P"; expected = "foo bar\nfoo bar\nbaz qux\nbaz qux\nfoo again\nfoo again\nlast line\nlast line\n"; }
    { script = "="; expected = "1\nfoo bar\n2\nbaz qux\n3\nfoo again\n4\nlast line\n"; }
    { script = "n"; expected = "foo bar\nbaz qux\nfoo again\nlast line\n"; }
    { script = "N"; expected = "foo bar\nbaz qux\nfoo again\nlast line\n"; }
    { script = "N;s/\\n/-/"; expected = "foo bar-baz qux\nfoo again-last line\n"; }
    { script = "q"; expected = "foo bar\n"; }
    { script = "Q"; expected = ""; }
    { script = "h;G"; expected = "foo bar\nfoo bar\nbaz qux\nbaz qux\nfoo again\nfoo again\nlast line\nlast line\n"; }
    { script = "H;g"; expected = "\nfoo bar\n\nfoo bar\nbaz qux\n\nfoo bar\nbaz qux\nfoo again\n\nfoo bar\nbaz qux\nfoo again\nlast line\n"; }
    { script = "x"; expected = "\nfoo bar\nbaz qux\nfoo again\n"; }
    { script = "z"; expected = "\n\n\n\n"; }
    { script = "l"; expected = "foo bar$\nfoo bar\nbaz qux$\nbaz qux\nfoo again$\nfoo again\nlast line$\nlast line\n"; }
    { script = "2p"; expected = "foo bar\nbaz qux\nbaz qux\nfoo again\nlast line\n"; }
    { script = "$p"; expected = "foo bar\nbaz qux\nfoo again\nlast line\nlast line\n"; }
    { script = "/b/p"; expected = "foo bar\nfoo bar\nbaz qux\nbaz qux\nfoo again\nlast line\n"; }
    { script = "/b/d"; expected = "foo again\nlast line\n"; }
    { script = "1,2p"; expected = "foo bar\nfoo bar\nbaz qux\nbaz qux\nfoo again\nlast line\n"; }
    { script = "1,$p"; expected = "foo bar\nfoo bar\nbaz qux\nbaz qux\nfoo again\nfoo again\nlast line\nlast line\n"; }
    { script = "2,+2p"; expected = "foo bar\nbaz qux\nbaz qux\nfoo again\nfoo again\nlast line\nlast line\n"; }
    { script = "0,/b/p"; expected = "foo bar\nfoo bar\nbaz qux\nfoo again\nlast line\n"; }
    { script = "1~2p"; expected = "foo bar\nfoo bar\nbaz qux\nfoo again\nfoo again\nlast line\n"; }
    { script = "/b/,/d/p"; expected = "foo bar\nfoo bar\nbaz qux\nbaz qux\nfoo again\nfoo again\nlast line\nlast line\n"; }
    { script = "/b/{s/b/B/;p}"; expected = "foo Bar\nfoo Bar\nBaz qux\nBaz qux\nfoo again\nlast line\n"; }
    { script = "{s/a/A/}"; expected = "foo bAr\nbAz qux\nfoo Again\nlAst line\n"; }
    { script = "/b/b skip; s/a/A/; :skip"; expected = "foo bar\nbaz qux\nfoo Again\nlAst line\n"; }
    { script = "/b/t skip; s/a/A/; :skip"; expected = "foo bAr\nbAz qux\nfoo Again\nlAst line\n"; }
    { script = "/b/T skip; s/a/A/; :skip"; expected = "foo bar\nbaz qux\nfoo Again\nlAst line\n"; }
    { script = "s/a/A/;t end;d; :end"; expected = "foo bAr\nbAz qux\nfoo Again\nlAst line\n"; }
    { script = "s/a/b/; s/b/c/"; expected = "foo cbr\ncbz qux\nfoo cgain\nlcst line\n"; }
    { script = "/a/s/a/A/"; expected = "foo bAr\nbAz qux\nfoo Again\nlAst line\n"; }
    { script = "s/a/A/;/b/s/b/B/"; expected = "foo BAr\nBAz qux\nfoo Again\nlAst line\n"; }
    { script = "s,a,b,"; expected = "foo bbr\nbbz qux\nfoo bgain\nlbst line\n"; }
    { script = "s|a|b|"; expected = "foo bbr\nbbz qux\nfoo bgain\nlbst line\n"; }
    { script = "s/o/0/2g"; expected = "fo0 bar\nbaz qux\nfo0 again\nlast line\n"; }
    { script = "s/o/0/g2"; expected = "fo0 bar\nbaz qux\nfo0 again\nlast line\n"; }
    { script = "s/^\\(.*\\)foo/\\1bar/"; expected = "bar bar\nbaz qux\nbar again\nlast line\n"; }
    { script = "s/foo\\(.*\\)bar/\\1baz/"; expected = " baz\nbaz qux\nfoo again\nlast line\n"; }
    { script = "s/[a-z]\\+/X/"; expected = "X bar\nX qux\nX again\nX line\n"; }
    { script = "s/[^[:space:]]/X/g"; expected = "XXX XXX\nXXX XXX\nXXX XXXXX\nXXXX XXXX\n"; }
    { script = "s/.*/X/"; expected = "X\nX\nX\nX\n"; }
    { script = "s/.*/X/g"; expected = "X\nX\nX\nX\n"; }
    { script = "s/o*//g"; expected = "f bar\nbaz qux\nf again\nlast line\n"; }
    { script = "s/\\(o*\\)/\\1X/"; expected = "Xfoo bar\nXbaz qux\nXfoo again\nXlast line\n"; }
    { script = "/foo/s/bar/baz/"; expected = "foo baz\nbaz qux\nfoo again\nlast line\n"; }
    { script = "/foo/,/qux/s/o/0/"; expected = "f0o bar\nbaz qux\nf0o again\nlast line\n"; }
    { script = "2,3{s/o/0/}"; expected = "foo bar\nbaz qux\nf0o again\nlast line\n"; }
    { script = "s/[[:upper:]]/L/g"; expected = "foo bar\nbaz qux\nfoo again\nlast line\n"; }
    { script = "s/[[:punct:]]/P/g"; expected = "foo bar\nbaz qux\nfoo again\nlast line\n"; }
    { script = "s/./&/g"; expected = "foo bar\nbaz qux\nfoo again\nlast line\n"; }
    { script = "y/abc/123/"; expected = "foo 21r\n21z qux\nfoo 1g1in\nl1st line\n"; }
    { script = "y/a/b/"; expected = "foo bbr\nbbz qux\nfoo bgbin\nlbst line\n"; }
    { script = "/./d"; expected = ""; }
    { script = "/./!d"; expected = "foo bar\nbaz qux\nfoo again\nlast line\n"; }
    { script = "p"; expected = "foo bar\nfoo bar\nbaz qux\nbaz qux\nfoo again\nfoo again\nlast line\nlast line\n"; }
    { script = "/foo/!{p}"; expected = "foo bar\nbaz qux\nbaz qux\nfoo again\nlast line\nlast line\n"; }
    { script = "s/[^[:space:]]/X/g"; expected = "XXX XXX\nXXX XXX\nXXX XXXXX\nXXXX XXXX\n"; }
    { script = "s/[[:space:]]/_/g"; expected = "foo_bar\nbaz_qux\nfoo_again\nlast_line\n"; }
    {
      script = "a\\
text";
      input = "one\n";
      expected = "one\ntext\n";
    }
    {
      script = "i\\
text";
      input = "one\n";
      expected = "text\none\n";
    }
    {
      script = "c\\
text";
      input = "one\n";
      expected = "text\n";
    }
    {
      script = "a\\
one\\
two";
      input = "x\n";
      expected = "x\none\ntwo\n";
    }
    {
      script = "1!d";
      input = "one\ntwo\n";
      expected = "one\n";
    }
    {
      script = "/a/!d";
      input = "a\nb\n";
      expected = "a\n";
    }
    {
      script = "s/a/b/";
      input = "a\nb\n";
      expected = "";
      quiet = true;
    }
    {
      script = "s/(a)(b)/\\2\\1/";
      input = "ab\n";
      expected = "ba\n";
      extended_regex = true;
    }
    {
      script = "s/a+/X/";
      input = "aaa\n";
      expected = "X\n";
      extended_regex = true;
    }
    {
      script = "s/a|bb/X/";
      input = "bb\n";
      expected = "X\n";
      extended_regex = true;
    }
    {
      script = "a\\
text";
      input = "one\n";
      expected = "one\ntext\n";
    }
    {
      script = "i\\
text";
      input = "one\n";
      expected = "text\none\n";
    }
    {
      script = "c\\
text";
      input = "one\n";
      expected = "text\n";
    }
    {
      script = "a\\
one\\
two";
      input = "x\n";
      expected = "x\none\ntwo\n";
    }
    {
      script = "1!d";
      input = "one\ntwo\n";
      expected = "one\n";
    }
    {
      script = "/a/!d";
      input = "a\nb\n";
      expected = "a\n";
    }
    {
      script = "s/a/b/";
      input = "a\nb\n";
      expected = "";
      quiet = true;
    }
    {
      script = "s/(a)(b)/\\2\\1/";
      input = "ab\n";
      expected = "ba\n";
      extended_regex = true;
    }
    {
      script = "s/a+/X/";
      input = "aaa\n";
      expected = "X\n";
      extended_regex = true;
    }
    {
      script = "s/a|bb/X/";
      input = "bb\n";
      expected = "X\n";
      extended_regex = true;
    }
    {
      script = "l";
      input = b.fromJSON "\"a\\u0001b\\n\"";
      expected = "a\\001b$\n";
      quiet = true;
    }
    {
      script = "N;l";
      input = "a\nb\n";
      expected = "a\\nb$\n";
      quiet = true;
    }
    {
      script = "s/a/b/";
      input = "a";
      expected = "b";
    }
    {
      script = "p";
      input = "a";
      expected = "a\na";
    }
    {
      script = "p";
      input = "a\nb";
      expected = "a\na\nb\nb";
    }
    {
      script = "=";
      input = "a";
      expected = "1\na";
    }
    {
      script = "c\\
x";
      input = "a";
      expected = "x\n";
    }
    {
      script = "q";
      input = "a\nb";
      expected = "a\n";
    }
    {
      script = "";
      input = "";
      expected = "";
    }
  ];

  # The cases with a text of their own.
  otherCases = [
    {
      script = "s/a/b/";
      input = "a\nb\nc\n";
      expected = "b\nb\nc\n";
    }
    {
      script = "s/^/> /";
      input = "one\ntwo\n";
      expected = "> one\n> two\n";
    }
    {
      script = "s/$/ <END/";
      input = "one\ntwo\n";
      expected = "one <END\ntwo <END\n";
    }
    {
      script = "3q";
      input = "one\ntwo\nthree\nfour\n";
      expected = "one\ntwo\nthree\n";
    }
    {
      script = "1!d";
      input = "one\ntwo\n";
      expected = "one\n";
    }
  ];

  # The scripts that cannot be parsed.
  errors = [
    { script = "s/a"; msg = "unterminated `s' command"; }
    { script = "s/a/b"; msg = "unterminated `s' command"; }
    { script = "Z"; msg = "unknown command: 'Z'"; }
    { script = "s/a/b/xy"; msg = "unknown option to 's': 'x'"; }
    { script = "{"; msg = "unterminated `{'"; }
    { script = "s/a/b/w"; msg = "the 'w' option of 's' is not supported"; }
    { script = "d}"; msg = "extra characters after command"; }
    { script = "}"; msg = "unexpected `}'"; }
    { script = "y/abc/xy/"; msg = "'y' command strings have different lengths"; }
  ];

  # The result of a case.
  run = c:
    let
      res = sed.safeParse { } c.script;
    in
      if res.type == "error" then
        { ok = false; actual = res.value.msg; inherit (c) script; }
      else
        let
          input = c.input or text;
          quiet = c.quiet or false;
          extended_regex = c.extended_regex or false;
          out = sed.run { inherit quiet extended_regex; } c.script input;
        in
          {
            inherit (c) script;
            ok = out == c.expected;
            expected = c.expected;
            actual = out;
          };

  # The cases that use the module the way the command of sed is used.
  commandCases = [
    { script = "s/a/b/"; input = "a b\n"; expected = "b b\n"; }
    { script = "s/o/0/g"; input = "foo\n"; expected = "f00\n"; }
    { script = "/b/d"; input = "a\nb\n"; expected = "a\n"; }
    { script = "p"; input = "a\n"; expected = "a\na\n"; }
  ];

  # The result of a case that uses the module the way the command of sed
  # is used.
  runCommand = c:
    let
      out = sed c.script c.input;
    in
      {
        inherit (c) script;
        ok = out == c.expected;
        expected = c.expected;
        actual = out;
      };

  results = b.map run (cases ++ otherCases) ++ b.map runCommand commandCases;

  errorResults = b.map (c:
    let
      res = sed.safeParse { } c.script;
    in
      {
        inherit (c) script;
        ok = res.type == "error" && res.value.msg == c.msg;
        expected = c.msg;
        actual = if res.type == "error" then res.value.msg else null;
      }
  ) errors;

  all = results ++ errorResults;
  failures = b.filter (r: !r.ok) all;
in {
  summary = {
    total = b.length all;
    passed = b.length (b.filter (r: r.ok) all);
    failed = b.length failures;
  };
  inherit failures;
  report = b.map (r: {
    script = r.script or null;
    ok = r.ok;
    expected = r.expected or null;
    actual = r.actual or null;
  }) all;
}
