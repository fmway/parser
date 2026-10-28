# Test runner for the YAML parser.
#
# The cases come from the yaml-test-suite, which is a collection of YAML
# documents together with their expected JSON representation. Each case
# lives in its own directory and contains:
#
#   in.yaml    -- the input
#   in.json    -- the expected output (as JSON)
#
# The suite is not bundled with this repository, so the path to it can be
# given with the `yamlTestSuite` argument. If it is not available, only
# the built-in tests below are run.
#
# Usage:
#
#   nix-build yaml/tests.nix
#
#   nix eval --impure --json --expr \
#     'import ./yaml/tests.nix { }' --apply 't: t.summary'
#
# or, to get a list of the failing cases:
#
#   nix eval --impure --json --expr \
#     'import ./yaml/tests.nix { }' --apply 't: t.failures'

{ yamlTestSuite ? null
, yaml ? import ./default.nix
}:

let
  b = builtins;

  # ------------------------------------------------------------------
  # Built-in tests
  # ------------------------------------------------------------------

  builtinCases = [
    { name = "simple mapping"; input = "key: value"; expected = { key = "value"; }; }
    { name = "simple sequence"; input = "- a\n- b"; expected = [ "a" "b" ]; }
    { name = "nested mapping"; input = "a:\n  b: c"; expected = { a = { b = "c"; }; }; }
    {
      name = "sequence of mappings";
      input = "- name: a\n  x: 1\n- name: b\n  x: 2";
      expected = [ { name = "a"; x = 1; } { name = "b"; x = 2; } ];
    }
    { name = "integers"; input = "a: 1\nb: -2\nc: +3"; expected = { a = 1; b = -2; c = 3; }; }
    { name = "floats"; input = "a: 1.5\nb: -0.25"; expected = { a = 1.5; b = -0.25; }; }
    { name = "booleans"; input = "a: true\nb: false"; expected = { a = true; b = false; }; }
    { name = "nulls"; input = "a: null\nb: ~\nc:"; expected = { a = null; b = null; c = null; }; }
    { name = "quoted strings stay strings"; input = "a: 'true'\nb: \"123\""; expected = { a = "true"; b = "123"; }; }
    { name = "flow sequence"; input = "[1, 2, 3]"; expected = [ 1 2 3 ]; }
    { name = "flow mapping"; input = "{ a: 1, b: 2 }"; expected = { a = 1; b = 2; }; }
    { name = "comments"; input = "# a comment\nkey: value # trailing"; expected = { key = "value"; }; }
    {
      name = "literal block scalar";
      input = "a: |\n  line1\n  line2\n";
      expected = { a = "line1\nline2\n"; };
    }
    {
      name = "literal block scalar, stripped";
      input = "a: |-\n  line1\n  line2\n";
      expected = { a = "line1\nline2"; };
    }
    {
      name = "folded block scalar";
      input = "a: >\n  line1\n  line2\n";
      expected = { a = "line1 line2\n"; };
    }
    {
      name = "double quoted escapes";
      input = "a: \"x\\ty\\n\"";
      expected = { a = "x\ty\n"; };
    }
    { name = "single quoted escape"; input = "a: 'it''s'"; expected = { a = "it's"; }; }
    { name = "empty document"; input = ""; expected = null; }
    { name = "document with marker"; input = "---\nkey: value"; expected = { key = "value"; }; }
    { name = "hex and octal"; input = "a: 0xC\nb: 0o14"; expected = { a = 12; b = 12; }; }

    # ----------------------------------------------------------------
    # Examples from chapter 2 of the YAML 1.2 specification
    # ----------------------------------------------------------------

    {
      name = "spec 2.1 sequence of scalars";
      input = "- Mark McGwire\n- Sammy Sosa\n- Ken Griffey\n";
      expected = [ "Mark McGwire" "Sammy Sosa" "Ken Griffey" ];
    }
    {
      name = "spec 2.2 mapping scalars to scalars";
      input = "hr:  65    # Home runs\navg: 0.278 # Batting average\nrbi: 147   # Runs Batted In\n";
      expected = { avg = 0.278; hr = 65; rbi = 147; };
    }
    {
      name = "spec 2.3 mapping scalars to sequences";
      input = "american:\n- Boston Red Sox\n- Detroit Tigers\n- New York Yankees\nnational:\n- New York Mets\n- Chicago Cubs\n- Atlanta Braves\n";
      expected = {
        american = [ "Boston Red Sox" "Detroit Tigers" "New York Yankees" ];
        national = [ "New York Mets" "Chicago Cubs" "Atlanta Braves" ];
      };
    }
    {
      name = "spec 2.4 sequence of mappings";
      input = "-\n  name: Mark McGwire\n  hr:   65\n  avg:  0.278\n-\n  name: Sammy Sosa\n  hr:   63\n  avg:  0.288\n";
      expected = [
        { avg = 0.278; hr = 65; name = "Mark McGwire"; }
        { avg = 0.288; hr = 63; name = "Sammy Sosa"; }
      ];
    }
    {
      name = "spec 2.5 sequence of sequences";
      input = "- [name        , hr, avg  ]\n- [Mark McGwire, 65, 0.278]\n- [Sammy Sosa  , 63, 0.288]\n";
      expected = [
        [ "name" "hr" "avg" ]
        [ "Mark McGwire" 65 0.278 ]
        [ "Sammy Sosa" 63 0.288 ]
      ];
    }
    {
      name = "spec 2.6 mapping of mappings";
      input = "Mark McGwire: {hr: 65, avg: 0.278}\nSammy Sosa: {\n    hr: 63,\n    avg: 0.288,\n }\n";
      expected = {
        "Mark McGwire" = { avg = 0.278; hr = 65; };
        "Sammy Sosa" = { avg = 0.288; hr = 63; };
      };
    }
    {
      name = "spec 2.7 two documents in a stream";
      input = "# Ranking of 1998 home runs\n---\n- Mark McGwire\n- Sammy Sosa\n- Ken Griffey\n\n# Team ranking\n---\n- Chicago Cubs\n- St Louis Cardinals\n";
      expected = [
        [ "Mark McGwire" "Sammy Sosa" "Ken Griffey" ]
        [ "Chicago Cubs" "St Louis Cardinals" ]
      ];
      multipleDocuments = true;
    }
    {
      name = "spec 2.8 play by play from a game";
      input = "---\ntime: 20:03:20\nplayer: Sammy Sosa\naction: strike (miss)\n...\n---\ntime: 20:03:47\nplayer: Sammy Sosa\naction: grand slam\n...\n";
      expected = [
        { action = "strike (miss)"; player = "Sammy Sosa"; time = "20:03:20"; }
        { action = "grand slam"; player = "Sammy Sosa"; time = "20:03:47"; }
      ];
      multipleDocuments = true;
    }
    {
      name = "spec 2.12 compact nested mapping";
      input = "---\n# Products purchased\n- item    : Super Hoop\n  quantity: 1\n- item    : Basketball\n  quantity: 4\n- item    : Big Shoes\n  quantity: 1\n";
      expected = [
        { item = "Super Hoop"; quantity = 1; }
        { item = "Basketball"; quantity = 4; }
        { item = "Big Shoes"; quantity = 1; }
      ];
    }
    {
      name = "spec 2.13 in literals newlines are preserved";
      input = "# ASCII Art\n--- |\n  \\//||\\/||\n  // ||  ||__\n";
      expected = "\\//||\\/||\n// ||  ||__\n";
    }
    {
      name = "spec 2.14 in the folded scalars newlines become spaces";
      input = "--- >\n  Mark McGwire's\n  year was crippled\n  by a knee injury.\n";
      expected = "Mark McGwire's year was crippled by a knee injury.\n";
    }
    {
      name = "spec 2.15 folded newlines are preserved for more indented and blank lines";
      input = "--- >\n Sammy Sosa completed another\n fine season with great stats.\n\n   63 Home Runs\n   0.288 Batting Average\n\n What a year!\n";
      expected = "Sammy Sosa completed another fine season with great stats.\n\n  63 Home Runs\n  0.288 Batting Average\n\nWhat a year!\n";
    }
    {
      name = "spec 2.16 indentation determines scope";
      input = "name: Mark McGwire\naccomplishment: >\n  Mark set a major league\n  home run record in 1998.\nstats: |\n  65 Home Runs\n  0.288 Batting Average\n";
      expected = {
        accomplishment = "Mark set a major league home run record in 1998.\n";
        name = "Mark McGwire";
        stats = "65 Home Runs\n0.288 Batting Average\n";
      };
    }
    {
      name = "spec 2.17 quoted scalars";
      input = "unicode: \"Sosa did fine.\\u263A\"\ncontrol: \"\\b1998\\t1999\\t2000\\n\"\nhex esc: \"\\x0d\\x0a is \\r\\n\"\n\nsingle: '\"Howdy!\" he cried.'\nquoted: ' # Not a ''comment''.'\ntie-fighter: '|\\-*-/|'\n";
      expected = {
        control = (builtins.fromJSON "\"\\b1998\\t1999\\t2000\\n\"");
        "hex esc" = "\r\n is \r\n";
        quoted = " # Not a 'comment'.";
        single = "\"Howdy!\" he cried.";
        "tie-fighter" = "|\\-*-/|";
        unicode = "Sosa did fine." + (builtins.fromJSON "\"\\u263A\"");
      };
    }
    {
      name = "spec 2.18 multi-line flow scalars";
      input = "plain:\n  This unquoted scalar\n  spans many lines.\n\nquoted: \"So does this\n  quoted scalar.\\n\"\n";
      expected = {
        plain = "This unquoted scalar spans many lines.";
        quoted = "So does this quoted scalar.\n";
      };
    }
    {
      name = "spec 2.19 integers";
      input = "canonical: 12345\ndecimal: +12345\noctal: 0o14\nhexadecimal: 0xC\n";
      expected = { canonical = 12345; decimal = 12345; hexadecimal = 12; octal = 12; };
    }
    {
      name = "spec 2.21 miscellaneous";
      input = "null:\nbooleans: [ true, false ]\nstring: '012345'\n";
      expected = { booleans = [ true false ]; null = null; string = "012345"; };
    }
    {
      name = "spec 2.22 timestamps";
      input = "canonical: 2001-12-15T02:59:43.1Z\niso8601: 2001-12-14t21:59:43.10-05:00\nspaced: 2001-12-14 21:59:43.10 -5\ndate: 2002-12-14\n";
      expected = {
        canonical = "2001-12-15T02:59:43.1Z";
        date = "2002-12-14";
        iso8601 = "2001-12-14t21:59:43.10-05:00";
        spaced = "2001-12-14 21:59:43.10 -5";
      };
    }
    {
      name = "nested mapping with increasing indentation";
      input = "  k:\n    k:\n      v\n";
      expected = { k = { k = "v"; }; };
    }
    {
      name = "a mapping entry without a colon is an error";
      input = "    k:\n    v\n";
      expectError = true;
    }
    {
      name = "duplicate keys in a block mapping are an error";
      input = "a: 1\na: 2\n";
      expectError = true;
    }
    {
      name = "duplicate keys in a flow mapping are an error";
      input = "{a: 1, a: 2}";
      expectError = true;
    }
    {
      name = "a plain and a quoted key with the same text are duplicates";
      input = "a: 1\n\"a\": 2\n";
      expectError = true;
    }
    {
      name = "a %YAML directive without a document is an error";
      input = "%YAML 1.2\n";
      expectError = true;
    }
    {
      name = "a %YAML directive followed by an empty document is an error";
      input = "%YAML 1.2\n...\n";
      expectError = true;
    }
    {
      name = "two %YAML directives for one document are an error";
      input = "%YAML 1.2\n%YAML 1.2\n--- a\n";
      expectError = true;
    }
    {
      name = "a tag handle does not apply to the next document";
      input = "%TAG !p! !my-\n--- !p!a x\n--- !p!b y\n";
      options = { tags = { }; };
      expectError = true;
    }
    {
      name = "an undefined tag handle is an error";
      input = "--- !p!a x\n";
      options = { tags = { }; };
      expectError = true;
    }
    {
      name = "a merge key brings in the entries of another mapping";
      input = "base: &b\n  a: 1\n  c: 3\nchild:\n  <<: *b\n";
      options = { enableAnchors = true; enableMergeKeys = true; };
      expected = {
        base = { a = 1; c = 3; };
        child = { a = 1; c = 3; };
      };
    }
    {
      name = "a key of the mapping itself wins over a merged one";
      input = "base: &b\n  a: 1\n  c: 3\nchild:\n  <<: *b\n  c: 9\n";
      options = { enableAnchors = true; enableMergeKeys = true; };
      expected = {
        base = { a = 1; c = 3; };
        child = { a = 1; c = 9; };
      };
    }
    {
      name = "a merge key may bring in a sequence of mappings";
      input = "l: &l { x: 0 }\nr: &r { x: 9 }\nchild:\n  <<: [*l, *r]\n";
      options = { enableAnchors = true; enableMergeKeys = true; };
      expected = {
        l = { x = 0; };
        r = { x = 9; };
        child = { x = 0; };
      };
    }
    {
      name = "the first of a sequence of mappings wins";
      input = "l: &l { x: 0 }\nr: &r { x: 9 }\nchild:\n  <<: [*r, *l]\n";
      options = { enableAnchors = true; enableMergeKeys = true; };
      expected = {
        l = { x = 0; };
        r = { x = 9; };
        child = { x = 9; };
      };
    }
    {
      name = "a merge key may be used in flow style";
      input = "b: &b { a: 1, c: 3 }\nch: { <<: *b, c: 9 }\n";
      options = { enableAnchors = true; enableMergeKeys = true; };
      expected = {
        b = { a = 1; c = 3; };
        ch = { a = 1; c = 9; };
      };
    }
    {
      name = "a quoted << is an ordinary key";
      input = "q:\n  \"<<\": 1\n";
      expected = { q = { "<<" = 1; }; };
    }
    {
      name = "a merge key whose value is not a mapping is an error";
      input = "x:\n  <<: 5\n";
      options = { enableAnchors = true; enableMergeKeys = true; };
      expectError = true;
    }
    {
      name = "a merge key whose value is a sequence of non-mappings is an error";
      input = "x:\n  <<: [1, 2]\n";
      options = { enableAnchors = true; enableMergeKeys = true; };
      expectError = true;
    }
    {
      name = "a merge key in flow style whose value is not a mapping is an error";
      input = "x: { <<: 5 }\n";
      options = { enableAnchors = true; enableMergeKeys = true; };
      expectError = true;
    }
    {
      name = "a merge key is an ordinary key unless it is enabled";
      input = "base: &b\n  a: 1\nchild:\n  <<: *b\n";
      options = { enableAnchors = true; };
      expected = {
        base = { a = 1; };
        child = { "<<" = { a = 1; }; };
      };
    }
    {
      name = "an empty entry in a flow sequence is an error";
      input = "[, a]\n";
      expectError = true;
    }
    {
      name = "a block sequence entry in flow context is an error";
      input = "[-]\n";
      expectError = true;
    }
    {
      name = "a hyphen inside a flow scalar is not an entry";
      input = "[a-b, -c]\n";
      expected = [ "a-b" "-c" ];
    }
    {
      name = "a block sequence may not start on the line of its key";
      input = "key: - a\n     - b\n";
      expectError = true;
    }
    {
      name = "a block sequence may start on the line of a sequence entry";
      input = "- - a\n  - b\n";
      expected = [ [ "a" "b" ] ];
    }
    {
      name = "a plain scalar does not continue across a comment";
      input = "word1 # c\nword2\n";
      expectError = true;
    }
    {
      name = "a document after one without a marker is an error";
      input = "[a]\n]\n";
      expectError = true;
    }
    {
      name = "a space-only line fixes the indentation of a block scalar";
      input = "k: |\n   \n  text\n";
      expectError = true;
    }
    {
      name = "a folded block scalar ends at a less indented line";
      input = "k: >\n \n  \n   \n text\n";
      expectError = true;
    }
    {
      name = "an implicit key in flow may not span a line break";
      input = "[ key\n  : value ]\n";
      expectError = true;
    }
    {
      name = "an explicit key in flow may span a line break";
      input = "[? key\n : value ]\n";
      expected = [ { key = "value"; } ];
    }
    {
      name = "a document after a marked one still needs a marker";
      input = "---\n[a]\n]\n";
      expectError = true;
    }
    {
      name = "a document may follow an explicit end marker";
      input = "---\na\n...\n---\nb\n";
      multipleDocuments = true;
      expected = [ "a" "b" ];
    }
    {
      name = "content after a document end marker is an error";
      input = "---\nk: v\n... invalid\n";
      expectError = true;
    }
    {
      name = "a comment may follow a document end marker";
      input = "---\nk: v\n... # ok\n---\nj\n";
      multipleDocuments = true;
      expected = [ { k = "v"; } "j" ];
    }
    {
      name = "a comment must be separated from the value";
      input = "k: \"v\"# c\n";
      expectError = true;
    }
    {
      name = "a plain scalar may hold a hash that is not a comment";
      input = "k: v# c\n";
      expected = { k = "v# c"; };
    }
    {
      name = "a quoted scalar may not reach across a document marker";
      input = "---\n\"\n---\n\"\n";
      expectError = true;
    }
    {
      name = "a quoted scalar may span several lines";
      input = "---\n\"one\ntwo\"\n";
      expected = "one two";
    }
    {
      name = "a double-quoted key may not span lines";
      input = "\"one\ntwo\": 1\n";
      expectError = true;
    }
    {
      name = "a single-quoted key may not span lines either";
      input = "'one\ntwo': 1\n";
      expectError = true;
    }
    {
      name = "a quoted key on one line is fine";
      input = "\"one\": 1\n";
      expected = { one = 1; };
    }
    {
      name = "a tag may not be followed by a comma in block context";
      input = "- !!str, x\n";
      options = { tags = { }; };
      expectError = true;
    }
    {
      name = "a tag may be followed by a flow collection directly";
      input = "- !!str[1]\n";
      options = { tags = { }; };
      expected = [ [ 1 ] ];
    }
    {
      name = "an anchor may not be applied to an alias";
      input = "key1: &a value\nkey2: &b *a\n";
      options = { enableAnchors = true; };
      expectError = true;
    }
    {
      name = "an anchored alias is not a valid implicit key";
      input = "key1: &alias value1\n&b *alias : value2\n";
      options = { enableAnchors = true; };
      expectError = true;
    }
    {
      name = "a bare alias is a valid key";
      input = "&a: key: &a value\nfoo:\n  *a:\n";
      options = { enableAnchors = true; };
      expected = { foo = "key"; key = "value"; };
    }
    {
      name = "properties that introduce a sequence must be indented";
      input = "---\nseq:\n&anchor\n- a\n- b\n";
      options = { enableAnchors = true; };
      expectError = true;
    }
    {
      name = "one space of indentation is enough for them";
      input = "---\nseq:\n &anchor\n- a\n- b\n";
      options = { enableAnchors = true; };
      expected = { seq = [ "a" "b" ]; };
    }
    {
      name = "a properties line may introduce a sequence at the top";
      input = "&sequence\n- a\n";
      options = { enableAnchors = true; };
      expected = [ "a" ];
    }
    {
      name = "a comment after a flow collection needs white space";
      input = "---\n[ a ] # x\n";
      expected = [ "a" ];
    }
    {
      name = "a comment glued to a flow collection is an error";
      input = "---\n[ a ]# x\n";
      expectError = true;
    }
    {
      name = "a comment glued to a comma in flow is an error";
      input = "---\n[ a, b]# x\n";
      expectError = true;
    }
    {
      name = "a comma may follow a comment inside a flow sequence";
      input = "---\n[ w1\n# c\n, w2]\n";
      expected = [ "w1" "w2" ];
    }
    {
      name = "a plain scalar does not reach across a comment in flow";
      input = "key: [ w1\n# c\n  w2 ]\n";
      expectError = true;
    }
    {
      name = "a hash inside a plain scalar is not a comment";
      input = "- http://example.com/a#b\n";
      expected = [ "http://example.com/a#b" ];
    }
    {
      name = "a comment cannot settle the indentation of a block scalar";
      input = "k: >\n \n  \n   \n # c\n";
      expectError = true;
    }
    {
      name = "a comment after the content of a block scalar is fine";
      input = "--- >\nline1\n# c\nline3\n";
      expected = "line1 # c line3\n";
    }
    {
      name = "a comment on the header line needs white space";
      input = "k: ># c\n  v\n";
      expectError = true;
    }
    {
      name = "a comment after the header needs white space";
      input = "k: > # c\n  v\n";
      expected = { k = "v\n"; };
    }
    {
      name = "a directive after a document has to follow its end";
      input = "---\nscalar1 # c\n%YAML 1.2\n---\nscalar2\n";
      expectError = true;
    }
    {
      name = "a directive after an end marker is an ordinary one";
      input = "---\na\n...\n%YAML 1.2\n---\nb\n";
      multipleDocuments = true;
      expected = [ "a" "b" ];
    }
    {
      name = "a directive at the start of a stream is an ordinary one";
      input = "%YAML 1.2\n---\na\n";
      expected = "a";
    }
    {
      name = "a key may not be indented with a tab";
      input = "---\na:\n\tb:\n\t\tc: value\n";
      expectError = true;
    }
    {
      name = "a tab after the indentation is ordinary white space";
      input = "a:\tb\n";
      expected = { a = "b"; };
    }
    {
      name = "a comment on a continuation line ends the scalar";
      input = "---\nplain: a\n       b # c\n       d\n";
      expectError = true;
    }
    {
      name = "a comment on the last line of a scalar is fine";
      input = "a: b # c\n";
      expected = { a = "b"; };
    }
    {
      name = "a line holds one key and one value";
      input = "a: b: c: d\n";
      expectError = true;
    }
    {
      name = "a value may be a mapping on the same line";
      input = "a: b: c\n";
      expected = { a = { b = "c"; }; };
    }
    {
      name = "the name of an anchor may hold a colon";
      input = "&a: key: &a value\n";
      options = { enableAnchors = true; };
      expected = { key = "value"; };
    }
    {
      name = "a document marker is not allowed in a flow collection";
      input = "[\n--- ,\n...\n]\n";
      expectError = true;
    }
    {
      name = "a document marker is not allowed in a flow mapping either";
      input = "{\n--- ,\n}\n";
      expectError = true;
    }
    {
      name = "a flow collection after a document marker is fine";
      input = "---\n[a]\n";
      expected = [ "a" ];
    }
    {
      name = "a property may not introduce a sequence on its own line";
      input = "&anchor - x\n";
      options = { enableAnchors = true; };
      expectError = true;
    }
    {
      name = "a property on its own line introduces a sequence";
      input = "&anchor\n- x\n";
      options = { enableAnchors = true; };
      expected = [ "x" ];
    }
    {
      name = "a document whose node is a sequence is an ordinary one";
      input = "- x\n";
      expected = [ "x" ];
    }
    {
      name = "a block mapping may not start on the line of the marker";
      input = "--- &a k: v\n";
      options = { enableAnchors = true; };
      expectError = true;
    }
    {
      name = "a marker's properties may introduce a mapping below";
      input = "--- &a\n  k: v\n";
      options = { enableAnchors = true; };
      expected = { k = "v"; };
    }
    {
      name = "a marker may hold a flow collection on its own line";
      input = "--- [1, 2]\n";
      expected = [ 1 2 ];
    }
    {
      name = "a marker may hold a scalar on its own line";
      input = "--- k: v\n";
      expectError = true;
    }
    {
      name = "a %TAG directive gives a handle a prefix";
      input = "%TAG !p! !my-\n--- !p!a x\n";
      options = { tags = { }; };
      expected = "x";
    }
    {
      name = "a long sequence does not overflow the stack";
      input = (b.concatStringsSep "\n" (b.genList (i: "- x") 3000)) + "\n";
      expected = b.genList (i: "x") 3000;
    }
    {
      name = "a long mapping does not overflow the stack";
      input = (b.concatStringsSep "\n" (b.genList (i: "k${toString i}: v") 3000)) + "\n";
      expected = b.listToAttrs (b.genList (i: { name = "k${toString i}"; value = "v"; }) 3000);
    }
    {
      name = "an explicit key with a value";
      input = "? a\n: b\n";
      expected = { a = "b"; };
    }
    {
      name = "an explicit key without a value";
      input = "? a\n? b\n";
      expected = { a = null; b = null; };
    }
    {
      name = "an unknown tag leaves the text alone";
      input = "!local foo\n";
      options = { tags = { }; };
      expected = "foo";
    }
    {
      name = "the handler of a tag is used";
      input = "!shout hello\n";
      options = { tags = { "!shout" = text: "shouted: ${text}"; }; };
      expected = "shouted: hello";
    }
    {
      name = "the tags of the core schema are understood when a tag of one's own is given";
      input = "!!int 42\n";
      options = { tags = { "!shout" = text: "shouted: ${text}"; }; };
      expected = 42;
    }
    {
      name = "the handler of a tag may be chosen by its full name";
      input = "%TAG !p! tag:example.com,2000:app/\n--- !p!thing hello\n";
      options = { tags = { "tag:example.com,2000:app/thing" = text: "shouted: ${text}"; }; };
      expected = "shouted: hello";
    }
    {
      name = "the tags are parsed when the map of the handlers is empty";
      input = "!shout hello\n";
      options = { tags = { }; };
      expected = "hello";
    }
    {
      name = "there are no tags when the tags are null";
      input = "!shout hello\n";
      options = { tags = null; };
      expected = "!shout hello";
    }
    {
      name = "there are no tags when the option is left out";
      input = "!shout hello\n";
      expected = "!shout hello";
    }
    {
      # A tag of the core schema says what the content has to look
      # like. A content that does not fit is an error: the tag is
      # recognised, and a node with a recognised tag and content that
      # does not satisfy it is not valid (section 3.3.3 of the
      # specification).
      name = "an integer tag on a content that is not an integer is an error";
      input = "a: !!int ctx\n";
      options = { tags = { }; };
      errorMsg = "'ctx' is not an integer";
      expectError = true;
    }
    {
      name = "an integer tag on a float is an error";
      input = "a: !!int 3.0\n";
      options = { tags = { }; };
      errorMsg = "'3.0' is not an integer";
      expectError = true;
    }
    {
      name = "a float tag on a content that is not a float is an error";
      input = "a: !!float ctx\n";
      options = { tags = { }; };
      errorMsg = "'ctx' is not a float";
      expectError = true;
    }
    {
      name = "a boolean tag on a content that is not a boolean is an error";
      input = "a: !!bool ctx\n";
      options = { tags = { }; };
      errorMsg = "'ctx' is not a boolean";
      expectError = true;
    }
    {
      name = "a string tag takes any content";
      input = "a: !!str 42\n";
      options = { tags = { }; };
      expected = { a = "42"; };
    }
    {
      # A caller that says what a tag means is responsible for the
      # content of the nodes that carry it.
      name = "a caller that says what a tag means decides about the content";
      input = "a: !!int ctx\n";
      options = { tags = { "!!int" = text: "int: ${text}"; }; };
      expected = { a = "int: ctx"; };
    }
    {
      # The handler of a tag may refuse the content of a node. It says
      # so with `failWith`, and the error is reported while the
      # document is parsed, so that it does not wait for the value to
      # be looked at (which may be never).
      name = "the handler of a tag may refuse the content of a node";
      input = "a: !isfoo foo\n";
      options = { tags = { "!isfoo" = text: if text == "foo" then true else yaml.failWith "the value is not foo"; }; };
      expected = { a = true; };
    }
    {
      name = "a handler that refuses the content is an error";
      input = "a: !isfoo bar\n";
      options = { tags = { "!isfoo" = text: if text == "foo" then true else yaml.failWith "the value is not foo"; }; };
      errorMsg = "the value is not foo";
      expectError = true;
    }
    {
      name = "a handler that throws is an error";
      input = "a: !boom x\n";
      options = { tags = { "!boom" = text: throw "the handler fell over"; }; };
      errorMsg = "the handler of the tag '!boom' failed";
      expectError = true;
    }
    {
      name = "a single-pair mapping in a flow sequence";
      input = "[a: 1, b]\n";
      expected = [ { a = 1; } "b" ];
    }
    {
      name = "a document marker ends a document";
      input = "--- a\n--- b\n";
      multipleDocuments = true;
      expected = [ "a" "b" ];
    }
    {
      name = "a stream of comments has no documents";
      input = "# only a comment\n";
      multipleDocuments = true;
      expected = [ ];
    }
  ];

  runBuiltin = c:
    let
      options = c.options or { };
      res =
        if c.multipleDocuments or false
        then yaml.safeParseStream options c.input
        else yaml.safeParse options c.input;
      actual = if res.type == "success" then res.value else null;
    in {
      inherit (c) name;
      inherit actual;
      expected = c.expected or null;
      ok =
        if c.expectError or false
        then res.type == "error"
          && ((c.errorMsg or null) == null || res.value.msg == c.errorMsg)
        else res.type == "success" && actual == c.expected;
    };

  builtinResults = b.map runBuiltin builtinCases;

  # ------------------------------------------------------------------
  # The entry point that throws
  # ------------------------------------------------------------------

  # `parse` gives back the document itself, and throws it when the
  # document is not valid. The tests catch the error, since a test that
  # fails should say so rather than stop the run.
  parseCases = [
    {
      name = "parse gives back the document";
      input = "a: 1\nb: two\n";
      expected = { a = 1; b = "two"; };
    }
    {
      name = "parse throws when the document is not valid";
      input = "a: 1\na: 2\n";
      expectError = true;
    }
    {
      name = "parse of an empty document is null";
      input = "";
      expected = null;
    }
    {
      name = "parse takes the options";
      input = "a: &x v\nb: *x\n";
      options = { enableAnchors = true; };
      expected = { a = "v"; b = "v"; };
    }
    {
      name = "parse without the options does not allow anchors";
      input = "a: &x v\nb: *x\n";
      expected = { a = "&x v"; b = "*x"; };
    }
  ];

  runParse = c:
    let
      opts = c.options or { };
      res = b.tryEval (yaml.parse opts c.input);
    in {
      inherit (c) name;
      actual = if res.success then res.value else null;
      expected = c.expected or null;
      ok =
        if c.expectError or false
        then ! res.success
        else res.success && res.value == c.expected;
    };

  # The message of an error says where it went wrong: the number of the
  # line, the line before it, the line it is on, the line after it,
  # and a mark under the character.
  #
  # The message is coloured, so the colours are taken out before it is
  # compared. The colours themselves are checked by a test of their own.
  #
  # The error of the document is the one the parser gives, so that the
  # place the message points at is the place the parser found.
  messageCases = [
    {
      name = "the error shows the line it is on and the one before it";
      str = "a: 1\nb: 2\nb: 3\n";
      error = { context = "yaml.mapping"; msg = "duplicate key 'b'"; offset = 10; };
      expected = "yaml.mapping\n 2| b: 2\n 3| b: 3\n  | ^ duplicate key 'b'";
    }
    {
      name = "the error shows the line after it as well";
      str = "a: 1\nb: 2\nc: 3\nc: 4\nd: 5\n";
      error = { context = "yaml.mapping"; msg = "duplicate key 'c'"; offset = 15; };
      expected = "yaml.mapping\n 3| c: 3\n 4| c: 4\n  | ^ duplicate key 'c'\n 5| d: 5";
    }
    {
      name = "the error points at the end of the input";
      str = "a: 1\nb: [2\n";
      error = { context = "yaml.flow"; msg = "unterminated flow sequence"; offset = 11; };
      expected = "yaml.flow\n 2| b: [2\n  |      ^ unterminated flow sequence";
    }
    {
      name = "the error keeps the indentation of the line";
      str = "root:\n  child: 1\n  child: 2\n";
      error = { context = "yaml.mapping"; msg = "duplicate key 'child'"; offset = 19; };
      expected = "yaml.mapping\n 2|   child: 1\n 3|   child: 2\n  |   ^ duplicate key 'child'";
    }
    {
      # The mark goes under the line the error is on, and not under the
      # last line that is shown.
      name = "the mark goes under the line the error is on";
      str = "a: true\nb: true\nc: true\nb: true\ne: true\n";
      error = { context = "yaml.mapping"; msg = "duplicate key 'b'"; offset = 24; };
      expected = "yaml.mapping\n 3| c: true\n 4| b: true\n  | ^ duplicate key 'b'\n 5| e: true";
    }
    {
      # The mark goes under the character the error is about, and not
      # under the start of the line.
      name = "the mark goes under the character the error is about";
      str = "a: b: c: d\n";
      error = { context = "yaml.mapping"; msg = "expected a comment after the value"; offset = 4; };
      expected = "yaml.mapping\n 1| a: b: c: d\n  |     ^ expected a comment after the value";
    }
    {
      # A tab is as wide as the space up to the next multiple of eight,
      # so that the mark lines up with the text.
      name = "the mark lines up with a tab in the line";
      str = "a: \"x\ty\n";
      error = { context = "yaml.scalar"; msg = "unterminated double-quoted scalar"; offset = 8; };
      expected = "yaml.scalar\n 1| a: \"x\ty\n  |              ^ unterminated double-quoted scalar";
    }
  ];

  # The colours of the message: the context in red, the mark in red and
  # the message in magenta.
  colorCase = {
    name = "the message is coloured";
    str = "a: 1\nb: 2\nb: 3\n";
  };

  # The escape character that starts a colour.
  #
  # Nix has no escape for it in a string, so it is read from JSON.
  esc = b.fromJSON "\"\\u001b\"";

  stripColors = s:
    b.replaceStrings [ "${esc}[31m" "${esc}[35m" "${esc}[0m" ] [ "" "" "" ] s;

  runMessage = c:
    let
      parsed = yaml.safeParse { } c.str;
      actual = stripColors (yaml.errorMessage c.str parsed.value);
    in {
      inherit (c) name;
      inherit actual;
      inherit (c) expected;
      ok =
        parsed.type == "error"
        && parsed.value.context == c.error.context
        && parsed.value.msg == c.error.msg
        && parsed.value.offset == c.error.offset
        && actual == c.expected;
    };

  runColor = c:
    let
      parsed = yaml.safeParse { } c.str;
      msg = yaml.errorMessage c.str parsed.value;
    in {
      inherit (c) name;
      actual = msg;
      expected = msg;
      ok = parsed.type == "error"
        && b.replaceStrings [ "${esc}[31m" ] [ "" ] msg != msg
        && b.replaceStrings [ "${esc}[35m" ] [ "" ] msg != msg;
    };

  messageResults = b.map runMessage messageCases;

  colorResults = [ (runColor colorCase) ];

  parseResults = b.map runParse parseCases;

  # ------------------------------------------------------------------
  # yaml-test-suite cases
  # ------------------------------------------------------------------

  # The suite directories are named with a four character code.
  caseDirs =
    if yamlTestSuite == null then [] else
      b.attrNames (b.readDir yamlTestSuite);

  readCase = dir:
    let
      inYaml = yamlTestSuite + "/${dir}/in.yaml";
      inJson = yamlTestSuite + "/${dir}/in.json";
      hasYaml = b.pathExists inYaml;
      hasJson = b.pathExists inJson;
      input = if hasYaml then b.readFile inYaml else "";
      expected =
        if hasJson
        then b.fromJSON (b.readFile inJson)
        else null;
    in {
      inherit dir input expected hasJson hasYaml;
    };

  # The expected JSON is compared against the parsed document. Since
  # attribute sets are unordered, the comparison is done on the JSON
  # representation of both sides.
  toComparable = v: b.toJSON v;

  # A case passes if it parses to the expected value either with the
  # default options or with tags and anchors enabled.
  runSuite = c:
    let
      plain = yaml.safeParse { } c.input;
      fancy = yaml.safeParse { tags = { }; enableAnchors = true; } c.input;
      matches = res: res.type == "success"
        && c.hasJson
        && toComparable res.value == toComparable c.expected;
    in {
      inherit (c) dir;
      actual = if plain.type == "success" then plain.value else null;
      expected = c.expected;
      ok = matches plain || matches fancy;
      error = if plain.type == "error" then plain.value.msg else null;
    };

  suiteResults = b.map runSuite (
    b.filter (c: c.hasYaml) (b.map readCase caseDirs)
  );

  # ------------------------------------------------------------------
  # Summary
  # ------------------------------------------------------------------

  allResults = builtinResults ++ parseResults ++ messageResults ++ colorResults ++ suiteResults;

  failures = b.filter (r: ! r.ok) allResults;

  summary = {
    total = b.length allResults;
    passed = b.length (b.filter (r: r.ok) allResults);
    failed = b.length failures;
  };

in {
  inherit summary failures builtinResults suiteResults;

  # A short report, useful when running the tests by hand.
  report = b.map (r: {
    inherit (r) name;
    ok = r.ok or false;
    dir = r.dir or null;
    error = r.error or null;
    expected = r.expected or null;
    actual = r.actual or null;
  }) allResults;
}
