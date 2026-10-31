{ lib, inputs, ... }: let
  code = {
    __functor = _: c: "```nix\n${lib.concatMapStringsSep "\n\n" lib.trim (lib.fmway.flat c)}\n```";
    sh = c: "```sh\n${c}```";
  };
  eval = text:
    lib.nix.eval { inherit text; scope = lib; cwd = builtins.unsafeDiscardStringContext inputs.parser; };
  run = {
    __functor = _: text: ''
      ${lib.trim text}
      # => ${output (eval text)}
    '';
    oneliner = text:
      "${text}; # ${output (eval text)}";
  };
  simple-nix-eval =
    run ''(import ./nix).eval "1 + 2"'';
  output = lib.fmway.genNix.oneliner;

  simple-sed =
    run ''sed "s/foo/bar/" "a foo line"'';
in {
  examples = {
    nix-eval-simple = code ''
      # The usual IFD approach:
      #   import (builtins.toFile "expr.nix" "1 + 2")

      # With this project:
      ${simple-nix-eval}
    '';

    nix-eval-quickstart = code ''
      let
        nix = import ./nix;
      in {
        arithmetic = ${run.oneliner ''nix.eval "1 + 2 + 3"''}
        strings    = ${run.oneliner ''nix.eval "\"a\" + \"b\""''}
        functions  = ${run.oneliner ''nix.eval "let f = x: x * x; in f 5"''}
      }
    '';

    nix-eval-from-string = code simple-nix-eval;

    nix-eval-from-attrs = code ''
      (import ./nix).eval {
        text = "(import ./nix/fixtures/simple.nix).b + 1";
        # cwd is inferred from the file that contains `text`
      }
      => ${output (eval ''
       (import ./nix).eval {
          text = "(import ./nix/fixtures/simple.nix).b + 1";
          cwd = ./.;
        } 
      '')}
    '';

    nix-eval-scope = code [
      (run ''
        (import ./nix).eval {
          text = "./foo.nix";
          cwd = /some/directory;
        }
      '')
      (run ''
        (import ./nix).eval {
          text = "x + 1";
          scope.x = 5;
        } 
      '')
    ];

    nix-eval-override-builtins = code (run ''
      (import ./nix).eval {
        text = "builtins.foo";
        scope.builtins = builtins // { foo = 42; };
      }
    '');

    nix-eval-scope-fn = code (run ''
      (import ./nix).eval {
        text = "foo 3";
        scope.foo = _: "foo";
      }
    '');

    nix-eval-tests = ''
      ```sh
      nix-instantiate --eval --strict -E '(import ./nix/tests.nix).summary'
      ```

      Expected output:
      ```nix
      ${output (eval "(import ./nix/tests.nix).summary")}
      ```'';

    simple-yaml = code [
      (run ''yaml.parse { } "a: 1\nb: two\n"'')
      (run ''yaml.parse { enableAnchors = true; } "a: &x v\nb: *x\n"'')
    ];

    yaml-parse-default = code (run ''yaml.parseDefault "a: 1\nb: two\n"'');

    yaml-safe-parse = code [
      (run ''yaml.safeParse { } "a: 1\nb: two\n"'')
      (run ''yaml.safeParse { } "a: 1\na: 2\n"'')
    ];

    yaml-safe-parse-with-options = code (run ''yaml.safeParse { enableAnchors = true; } "- &a x\n- *a"'');

    yaml-safe-parse-with-anchors = code (run ''yaml.safeParse { enableAnchors = true; } "&a a: &b b\n*b : *a"'');

    yaml-safe-parse-not-enable-anchors = code (run ''yaml.safeParse { } "a: &x test\nb: *x\n"'');

    yaml-safe-parse-with-tags = code (run ''
      yaml.safeParse {
        tags = {
          "!shout" = text: "shouted: ''${text}";
        };
      } "!shout hello\n"'');

    yaml-safe-parse-not-enable-tags = code (run ''yaml.safeParse { } "!shout hello\n"'');

    yaml-safe-parse-builtin-tags = code (run ''yaml.safeParse { tags = { }; } "!!int 42\n"'');

    yaml-safe-parse-error-by-tags = code (run ''yaml.safeParse { tags = { }; } "a: !!int ctx\n"'');

    yaml-safe-parse-custom-error-tags = code (run ''
      yaml.safeParse {
        tags = {
          "!isfoo" = text: if text == "foo" then true else yaml.failWith "the value is not foo";
        };
      } "a: !isfoo bar\n"'');

    yaml-safe-parse-directive-tags = code (run ''
      yaml.safeParse {
        tags = {
          "tag:example.com,2000:app/thing" = text: "shouted: ''${text}";
        };
      } "%TAG !p! tag:example.com,2000:app/\n--- !p!thing hello\n"'');

    yaml-simple-safe-parse-stream = code (run ''yaml.safeParseStream { } "---\na: 1\n---\nb: 2\n"'');

    yaml-safe-parse-merge-keys = code (run ''
      yaml.safeParse { enableAnchors = true; enableMergeKeys = true; } '''
        base: &base
          a: 1
          c: 3
        child:
          <<: *base
          c: 9
        ''''');

    yaml-safe-parse-not-enable-merge-keys = code (run ''
      yaml.safeParse { enableAnchors = true; } '''
        base: &base
          a: 1
        child:
          <<: *base
        ''''');

    yaml-tests = code.sh ''
      nix eval --impure --json --expr \
        'import ./yaml/tests.nix { }' --apply 't: t.summary'
      # => ${output (eval "(import ./yaml/tests.nix { }).summary")}
    '';

    sed-quickstart = code ''
      let
        sed = import ./sed;
      in ${simple-sed}
    ''; 

    sed-simple = code simple-sed;

    sed-param-quiet = code (run
      ''sed { quiet = true; } "s/foo/bar/" "a foo line"'');

    sed-run-simple = code (run
      ''sed.run { } "s/foo/bar/" "a foo line"'');

    sed-safe-parse-quickstart = code [
      ''
        sed.safeParse { } "s/foo/bar/"
        # => { type = "success"; value = { type = "script"; commands = [ ... ]; }; }
      ''
      (run ''sed.safeParse { } "s/foo/bar"'')
    ];

    sed-apply-quickstart = code (run ''
      let
        script = sed.parse { } "s/foo/bar/";
      in sed.apply { } script "a foo line"
    '');

    sed-tests = code.sh ''
      nix eval --impure --json --expr 'import ./sed/tests.nix { }' \
        --apply 't: t.summary'
      # => ${output (eval "(import ./sed/tests.nix { }).summary")}
    '';
  };
}
