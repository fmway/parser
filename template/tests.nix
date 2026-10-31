# Tests for the template parsers.

let
  template = import ./default.nix;
  b = builtins;

  # The escape character that starts a colour.
  #
  # Nix has no escape for it in a string, so it is read from JSON.
  esc = b.fromJSON "\"\\u001b\"";

  stripColors = s:
    b.replaceStrings [ "${esc}[31m" "${esc}[35m" "${esc}[0m" ] [ "" "" "" ] s;

  # The message of the error of a template that could not be parsed.
  #
  # The message is made by hand, and not caught from the error, because
  # Nix has no way of catching an error and keeping its message.
  parseMessage = version: args:
    let
      parsed = version.safeParse args;
    in
      if parsed.type == "error"
      then stripColors (template.errors.errorMessage args.text parsed.value)
      else null;

  # The message of the error of an expression that could not be evaluated.
  evaluationMessage = context: expression: offset: text:
    stripColors (template.errors.errorMessage text
      (template.errors.evaluationError context expression offset));

  # The templates that are evaluated.
  evalCases = [
    {
      name = "v1: the value of an interpolation";
      version = "v1";
      args = { prefix = "{{"; postfix = "}}"; text = "hello {{ name }}!"; scope.name = "world"; };
      expected = "hello world!";
    }
    {
      name = "v2: the text in front of an inline marker";
      version = "v2";
      args = { text = "bg = #000 # {< replace_color \"#fff\" >}\n"; };
      expected = "bg = #fff # {< replace_color \"#fff\" >}\n";
    }
    {
      name = "v2: the line after a marker";
      version = "v2";
      args = { text = "# {# replace_color \"#fff\" #}\nbg = #000\n"; };
      expected = "# {# replace_color \"#fff\" #}\nbg = #fff\n";
    }
    {
      name = "v2: the body of a block";
      version = "v2";
      args = { text = "# {% replace_color \"#fff\" %}\nbg = #000\n# {% end %}\n"; };
      expected = "# {% replace_color \"#fff\" %}\nbg = #fff\n# {% end %}\n";
    }
    {
      name = "v2: the marker of a comment style that is asked for";
      version = "v2";
      args = { text = "bg = #000 // {< replace_color \"#fff\" >}\n"; commentStyle = { open = "// "; close = ""; }; };
      expected = "bg = #fff // {< replace_color \"#fff\" >}\n";
    }
  ];

  # The templates that cannot be parsed.
  #
  # The message of the error has to name the place in the template that
  # went wrong, and it has to say what went wrong there.
  parseCases = [
    {
      name = "v1: the postfix of an interpolation is missing";
      version = "v1";
      args = { prefix = "{{"; postfix = "}}"; text = "{{ 1 + }}"; };
      expected = "template.v1\n 1| {{ 1 + }}\n  |      ^ expected string '}}'";
    }
    {
      name = "v1: the prefix is not given";
      version = "v1";
      args = { text = "x"; };
      expected = "template.v1\n 1| x\n  | ^ prefix must be a non-empty string";
    }
    {
      name = "v2: the block is not closed";
      version = "v2";
      args = { text = "a = 1 # {% upper %}\nb = 2\n"; };
      expected = "template.v2\n 1| a = 1 # {% upper %}\n  |       ^ unterminated block transform\n 2| b = 2";
    }
    {
      name = "v2: the marker is not closed";
      version = "v2";
      args = { text = "# {# 1 + #}\n"; };
      expected = "template.v2\n 1| # {# 1 + #}\n  |        ^ expected string '#}'";
    }
    {
      name = "v2: the block is closed without being opened";
      version = "v2";
      args = { text = "# {% end %}\n"; };
      expected = "template.v2\n 1| # {% end %}\n  | ^ unexpected block end marker";
    }
  ];

  # The expressions that cannot be evaluated.
  #
  # The message of the error has to name the expression that went
  # wrong, and it has to point at it in the template.
  evaluationCases = [
    {
      name = "v1: the expression of an interpolation";
      context = "template.v1";
      expression = "unknown";
      offset = 3;
      text = "{{ unknown }}";
      expected = "template.v1\n 1| {{ unknown }}\n  |    ^ error while evaluating 'unknown'";
    }
    {
      name = "v2: the expression of a marker";
      context = "template.v2";
      expression = "unknown";
      offset = 5;
      text = "# {# unknown #}\nsome text";
      expected = "template.v2\n 1| # {# unknown #}\n  |      ^ error while evaluating 'unknown'\n 2| some text";
    }
  ];

  # The templates whose evaluation fails.
  throwCases = [
    {
      name = "v1: the expression of an interpolation cannot be evaluated";
      version = "v1";
      args = { prefix = "{{"; postfix = "}}"; text = "{{ unknown }}"; };
    }
    {
      name = "v2: the expression of a marker cannot be evaluated";
      version = "v2";
      args = { text = "# {# unknown #}\nsome text"; };
    }
  ];

  runEval = c:
    let
      actual = template.${c.version}.eval c.args;
    in {
      inherit (c) name;
      inherit actual;
      expected = c.expected;
      ok = actual == c.expected;
    };

  runParse = c:
    let
      version = template.${c.version};
      parsed = version.safeParse c.args;
      actual = parseMessage version c.args;
    in {
      inherit (c) name;
      inherit actual;
      expected = c.expected;
      ok = parsed.type == "error" && actual == c.expected;
    };

  runEvaluation = c:
    let
      actual = evaluationMessage c.context c.expression c.offset c.text;
    in {
      inherit (c) name;
      inherit actual;
      expected = c.expected;
      ok = actual == c.expected;
    };

  runThrow = c:
    let
      result = b.tryEval (template.${c.version}.eval c.args);
    in {
      inherit (c) name;
      actual = result.success;
      expected = false;
      ok = !result.success;
    };

  evalResults = b.map runEval evalCases;
  parseResults = b.map runParse parseCases;
  evaluationResults = b.map runEvaluation evaluationCases;
  throwResults = b.map runThrow throwCases;

  allResults = evalResults ++ parseResults ++ evaluationResults ++ throwResults;
  failures = b.filter (r: !r.ok) allResults;
in {
  summary = {
    total = b.length allResults;
    passed = b.length (b.filter (r: r.ok) allResults);
    failed = failures;
  };
}
