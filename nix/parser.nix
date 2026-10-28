{ parsec, lexer, ast }:
with parsec;
let
  mkParser = terminator:
    let
      b = builtins;
  wsChar = c: c == " " || c == "\n" || c == "\t" || c == "\r";

  # Whitespace and comments.
  #
  # This is a single parser instead of `lexer.space`, which would try three
  # alternatives (spaces, line comment, block comment) for every token. Here
  # the next character decides what to do, so only one parser runs.
  #
  # Like `lexer.space` it may consume nothing.
  notAt = parser: ps:
    let
      res = parser ps;
      offset = b.elemAt ps 1;
      len = b.elemAt ps 2;
    in
      if failed res
      then [null offset len]
      else {
        context = "nix.parser.notAt";
        msg = "unexpected reserved input";
        offset = offset;
      };

  terminatorParser =
    if terminator == null then parsec.fail else parsec.string terminator;

  lineComment = parsec.bind (notAt terminatorParser) (_:
    lexer.skipLineComment "#");

  blockComment = parsec.bind (notAt terminatorParser) (_:
    parsec.skipThen (parsec.string "/*") (parsec.skipTill parsec.anyChar (parsec.string "*/")));

  spaceChunk = parsec.alt
    (parsec.skipWhile1 wsChar)
    (parsec.alt lineComment blockComment);

  spaces = parsec.skipMany spaceChunk;
  lexeme = lexer.lexeme spaces;
  symbol = lexer.symbol spaces;
  
  # The character classes.
  #
  # These are written out as comparisons, and not as regular
  # expressions: a regular expression has to be compiled every time it
  # is used, and these are used for every character of every token.
  isDigit = c: c >= "0" && c <= "9";
  isLower = c: c >= "a" && c <= "z";
  isUpper = c: c >= "A" && c <= "Z";
  isAlpha = c: isLower c || isUpper c;
  isIdStart = c: isAlpha c || c == "_";
  isIdChar = c: isAlpha c || isDigit c || c == "_" || c == "'" || c == "-";
  isUriSchemeStart = c: isAlpha c;
  isUriSchemeChar = c: isAlpha c || isDigit c || c == "+" || c == "." || c == "-";
  isUriBodyChar = c:
    isAlpha c || isDigit c
    || c == "%" || c == "/" || c == "?" || c == ":" || c == "@" || c == "&"
    || c == "=" || c == "+" || c == "$" || c == "," || c == "_" || c == "."
    || c == "!" || c == "~" || c == "*" || c == "'" || c == "-";
  
  # Extract all nodes of a parsec error tree. Each node may carry an offset,
  # a message, and a context label.
  flattenErrors = e:
    if b.isAttrs e then
      [{
        off = e.offset or null;
        msg = e.msg or null;
        ctx = e.context or null;
      }] ++ (if e ? error then flattenErrors e.error else [])
    else if b.isList e then b.concatMap flattenErrors e
    else [{ off = null; msg = null; ctx = null; }];
  
  # Render a parsec error as a Nix-style message with a line and column.
  errorDetails = text: e:
    let
      entries = flattenErrors e;
      msgs = b.filter (x: x.msg != null) entries;
      pool = if msgs != [] then msgs else entries;
      offs = b.filter (x: x != null) (b.map (x: x.off) pool);
      off0 =
        if offs == [] then null
        else b.foldl' (a: c: if c > a then c else a) (b.head offs) offs;
      atOff = if off0 == null then pool else b.filter (x: x.off == off0) pool;
      pick = if atOff == [] then pool else atOff;
      msg0 =
        if pick == [] then "unexpected input"
        else
          let x = b.head pick;
          in if x.msg != null then x.msg
             else if x.ctx != null then "unexpected ${x.ctx}"
             else "unexpected input";
      off0' = if off0 == null then 0 else off0;
      off = if off0' > b.stringLength text then b.stringLength text else off0';
      found =
        if off >= b.stringLength text then "end of input"
        else "'${b.substring off 1 text}'";
      msg =
        if msg0 == "expected one of these to succeed" then "expected expression"
        else if msg0 == "expected end of input" then "expected end of input, but found ${found}"
        else msg0;
    in {
      inherit off msg;
    };

  formatError = text: e:
    let
      details = errorDetails text e;
      off = details.off;
      before = b.substring 0 off text;
      lines = b.filter b.isString (b.split "\n" before);
      line = b.length lines;
      col = b.stringLength (b.elemAt lines (line - 1)) + 1;
    in "parse error at line ${toString line}, column ${toString col}: ${details.msg}";
  
  # number (integer or float)
  digitValue = c: b.fromJSON c;
  parseInt = s:
    b.foldl' (acc: c: acc * 10 + digitValue c) 0
      (b.genList (i: b.substring i 1 s) (b.stringLength s));
  
  integer = fmap (s: ast.mkLit (parseInt s)) (takeWhile1 isDigit);
  
  exponentPart = bind (satisfy (c: c == "e" || c == "E")) (e:
    bind (optional (satisfy (c: c == "+" || c == "-"))) (sign:
      bind (takeWhile1 isDigit) (ds:
        pure (e + (if sign == [] then "" else b.head sign) + ds)
      )
    )
  );
  
  mkFloat = intPart: fracPart: expPart:
    let
      intPart' = if intPart == "" then "0" else intPart;
      fracPart' = if fracPart == "" then "0" else fracPart;
      expPart' = if expPart == [] then "" else b.head expPart;
    in ast.mkLit (b.fromJSON (intPart' + "." + fracPart' + expPart'));
  
  floatWithInt = bind (takeWhile1 isDigit) (intPart:
    bind (parsec.string ".") (_:
      bind (takeWhile isDigit) (fracPart:
        fmap (expPart: mkFloat intPart fracPart expPart) (optional exponentPart)
      )
    )
  );
  
  floatLeadingDot = bind (parsec.string ".") (_:
    bind (takeWhile1 isDigit) (fracPart:
      fmap (expPart: mkFloat "" fracPart expPart) (optional exponentPart)
    )
  );
  
  float = alt floatWithInt floatLeadingDot;
  
  number = lexeme (alt float integer);
  
  # URI literal (deprecated but still accepted by Nix), e.g. `http://x`
  uriScheme = bind (satisfy isUriSchemeStart) (first:
    fmap (rest: first + rest) (takeWhile isUriSchemeChar)
  );
  
  uriLit = lexeme (bind uriScheme (scheme:
    bind (parsec.string ":") (_:
      fmap (body: ast.mkLit (scheme + ":" + body)) (takeWhile1 isUriBodyChar)
    )
  ));
  
  # path literal (relative/absolute), optionally with interpolation
  isPathChar = c: isAlpha c || isDigit c || c == "." || c == "_" || c == "/" || c == "+" || c == "-";
  isPathSegmentChar = c: isPathChar c && c != "/";
  
  pathPiece = alt
    (fmap (e: { interp = e; }) interpolated)
    (fmap (s: s) (takeWhile1 isPathChar));
  
  prefixedPath = prefix: bind (parsec.string prefix) (_:
    fmap (parts: ast.mkPath ([prefix] ++ parts)) (many pathPiece)
  );
  
  absolutePath = bind (parsec.string "/") (_:
    bind (alt (fmap (c: c) (satisfy isPathSegmentChar))
              (fmap (e: { interp = e; }) interpolated)) (first:
      fmap (rest: ast.mkPath ([ "/" first ] ++ rest)) (many pathPiece)
    )
  );
  
  pathLit = lexeme (alt
    (prefixedPath "./")
    (alt
      (prefixedPath "../")
      (alt
        (prefixedPath "~/")
        absolutePath
      )
    )
  );
  
  barePathSegment = alt
    (fmap (e: { interp = e; }) interpolated)
    (fmap (s: s) (takeWhile1 isPathSegmentChar));
  
  # bare relative path such as `foo/bar` (must contain a slash)
  barePath = lexeme (bind (takeWhile1 isPathSegmentChar) (first:
    bind (many1 (skipThen (parsec.string "/") barePathSegment)) (rest:
      pure (ast.mkPath ([first] ++ b.concatMap (s: [ "/" s ]) rest))
    )
  ));
  
  # search path literal such as <nixpkgs> or <nixpkgs/lib>
  searchPathName = bind (takeWhile1 isPathSegmentChar) (first:
    bind (many (skipThen (parsec.string "/") (takeWhile1 isPathSegmentChar))) (rest:
      pure (b.concatStringsSep "/" ([first] ++ rest))
    )
  );
  
  searchPath = lexeme (bind (parsec.string "<") (_:
    bind searchPathName (name:
      bind (parsec.string ">") (_: pure (ast.mkSearchPath name))
    )
  ));
  
  # string literal with interpolation: "text ${expr} more"
  interpolated = skipThen (parsec.string "\${")
    (thenSkip (skipThen spaces expr) (parsec.string "}"));
  
  stringPart = alt
    (fmap (e: { interp = e; }) interpolated)
    (fmap (s: s) lexer.charLit);
  
  stringLit = lexeme (bind (parsec.string "\"") (_:
    bind (parsec.manyTill stringPart (parsec.string "\"")) (parts:
      pure (ast.mkString parts)
    )
  ));
  
  # Indented strings: strip common indentation on the raw source first, then
  # resolve escapes and interpolation.
  indentedEnd = skipThen (parsec.string "''")
    (notFollowedBy (satisfy (c: c == "'" || c == "$" || c == "\\")));
  
  indentedRawUnit = alt
    (fmap (_: "'''") (parsec.string "'''"))
    (alt
      (fmap (_: "''$") (parsec.string "''$"))
      (alt
        (bind (parsec.string "''\\") (p: fmap (c: p + c) anyChar))
        (fmap (c: c) anyChar)
      )
    );
  
  indentedRaw = bind (parsec.string "''") (_:
    bind (manyTill indentedRawUnit indentedEnd) (units:
      pure (b.concatStringsSep "" units)
    )
  );
  
  allWhitespace = s: b.match "[ \t]*" s != null;
  
  leadingWhitespace = s:
    let m = b.match "([ \t]*).*" s;
    in if m == null then 0 else b.stringLength (b.head m);
  
  stripIndent = raw:
    let
      lines0 = b.filter b.isString (b.split "\n" raw);
      lines =
        if lines0 != [] && allWhitespace (b.head lines0)
        then b.tail lines0
        else lines0;
      indents = b.map (l: if allWhitespace l then null else leadingWhitespace l) lines;
      nonNull = b.filter (x: x != null) indents;
      minIndent =
        if nonNull == [] then 0
        else b.foldl' (a: c: if c < a then c else a) (b.head nonNull) nonNull;
      stripLine = l:
        if allWhitespace l then ""
        else
          let n = b.stringLength l;
          in if n <= minIndent then "" else b.substring minIndent (n - minIndent) l;
    in b.concatStringsSep "\n" (b.map stripLine lines);
  
  indentedEscapeChar = c:
    if c == "n" then "\n"
    else if c == "r" then "\r"
    else if c == "t" then "\t"
    else c;
  
  indentedInnerPart = alt
    (fmap (e: { interp = e; }) interpolated)
    (alt
      (fmap (_: "''") (parsec.string "'''"))
      (alt
        (fmap (_: "$") (parsec.string "''$"))
        (alt
          (bind (parsec.string "''\\") (_: fmap indentedEscapeChar anyChar))
          (fmap (c: c) anyChar)
        )
      )
    );
  
  reverseList = xs: b.foldl' (acc: x: [x] ++ acc) [] xs;
  
  mergeStringParts = parts:
    let
      step = acc: p:
        if b.isString p then
          (if acc != [] && b.isString (b.head acc)
           then [(b.head acc + p)] ++ b.tail acc
           else [p] ++ acc)
        else [p] ++ acc;
    in reverseList (b.foldl' step [] parts);
  
  indentedString = lexeme (bind indentedRaw (raw:
    let
      stripped = stripIndent raw;
      res = runParser (thenSkip (many indentedInnerPart) eof) stripped;
    in if res.type == "error" then fail
       else pure (ast.mkString (mergeStringParts res.value))
  ));
  
  # Keywords that may never be parsed as identifiers
  reserved = [
    "if" "then" "else" "assert" "with" "let" "in" "rec" "inherit" "or"
  ];
  
  identRaw = lexeme (bind (satisfy isIdStart) (c1:
    bind (takeWhile isIdChar) (rest:
      bind (notFollowedBy (bind (parsec.string ":") (_: satisfy isUriBodyChar))) (_:
        pure (c1 + rest)
      )
    )
  ));

  # identifier; `or` is only usable as an attribute name, not as a variable
  ident = bind identRaw (s:
    if b.elem s reserved then fail else pure (ast.mkVar s)
  );
  
  # keywords
  boolOrNull = alt 
    (label "true" (fmap (_: ast.mkLit true) (symbol "true")))
    (alt (label "false" (fmap (_: ast.mkLit false) (symbol "false")))
         (label "null" (fmap (_: ast.mkLit null) (symbol "null"))));
  
  # bindings: `path.to.name = expr;`, `inherit names;`, `inherit (expr) names;`
  attrName = bind identRaw (s:
    if !(b.elem s reserved) || s == "or" then pure s else fail
  );
  
  dynamicName = lexeme (skipThen (parsec.string "\${")
    (thenSkip (skipThen spaces expr) (parsec.string "}")));
  
  dynamicComponent = e:
    if e.type == "string" && b.all (p: b.isString p) e.parts
    then { static = b.concatStringsSep "" e.parts; }
    else { dynamic = e; };
  
  attrComponent = alt
    (fmap (n: { static = n; }) attrName)
    (alt
      (fmap dynamicComponent dynamicName)
      (bind stringLit (s:
        let
          hasInterp = b.any (p: b.isAttrs p && p ? interp) s.parts;
          text = b.concatStringsSep "" (b.map (p: if b.isString p then p else "") s.parts);
        in pure (if hasInterp then { dynamic = s; } else { static = text; })
      ))
    );
  
  attrPath = bind attrComponent (first:
    fmap (rest: [first] ++ rest) (many (skipThen (symbol ".") attrComponent))
  );
  
  assignment = bind attrPath (path:
    skipThen (symbol "=") (bind expr (val:
      skipThen (symbol ";") (pure [{ inherit path; value = val; }])
    ))
  );
  
  inheritBinding = bind (symbol "inherit") (_:
    bind (optional (between (symbol "(") (symbol ")") expr)) (fromList:
      bind (many attrComponent) (components:
        skipThen (symbol ";") (pure (b.map (c:
          if !(c ? static) then throw "dynamic attributes not allowed in inherit"
          else {
            path = [{ static = c.static; }];
            outer = fromList == [];
            isInherit = true;
            value =
              if fromList == []
              then ast.mkVar c.static
              else ast.mkBinOp "." (b.head fromList) (ast.mkLit c.static);
          }
        ) components))
      )
    )
  );
  
  binding = alt inheritBinding assignment;
  
  bindingList = fmap b.concatLists (many binding);
  
  # let expression
  letExpr = bind (symbol "let") (_:
    bind bindingList (bindings:
      skipThen (symbol "in") (fmap (body: ast.mkLet bindings body) expr)
    )
  );
  
  # assert cond; body
  assertExpr = bind (symbol "assert") (_:
    bind (skipThen spaces expr) (cond:
      skipThen (symbol ";") (bind expr (body:
        pure { type = "assert"; inherit cond body; }
      ))
    )
  );
  
  # if
  ifExpr = parsec.bind (symbol "if") (_: 
    parsec.bind expr (cond:
      parsec.skipThen (symbol "then") (
        parsec.bind expr (t:
          parsec.skipThen (symbol "else") (
            parsec.bind expr (e: parsec.pure { type = "if"; cond = cond; thenBranch = t; elseBranch = e; })
          )
        )
      )
    )
  );
  
  # with
  withExpr = bind (symbol "with") (_: bind expr (withEnv: skipThen (symbol ";") (bind expr (body: pure (ast.mkWith withEnv body)))));
  
  # rec attrset
  recAttrExpr = bind (symbol "rec") (_: bind (symbol "{") (_:
    bind bindingList (bindings:
      skipThen (symbol "}") (pure (ast.mkRecAttrSet bindings))
    )
  ));
  
  # parenthesised expression
  parenExpr = between (symbol "(") (symbol ")") expr;
  
  # legacy `let { ... }` is an atomic expression
  oldLetExpr = bind (symbol "let") (_: bind (symbol "{") (_:
    bind bindingList (bindings:
      skipThen (symbol "}") (pure (ast.mkBinOp "." (ast.mkRecAttrSet bindings) (ast.mkLit "body")))
    )
  ));
  
  # atoms
  atom = choice [
    recAttrExpr parenExpr oldLetExpr
    uriLit pathLit barePath searchPath indentedString stringLit number ident
  ];
  
  # operators with precedence
  chainl = p: op: bind p (first:
    let go = acc:
          alt (bind op (o: bind p (r: go (ast.mkBinOp o acc r)))) (pure acc);
    in go first
  );
  
  chainr = p: op: bind p (first:
    alt (bind op (o: bind (chainr p op) (r: pure (ast.mkBinOp o first r))))
        (pure first)
  );
  
  opAddSub = alt (fmap (_: "+") (symbol "+")) (fmap (_: "-") (symbol "-"));
  opMulDiv = alt (fmap (_: "*") (symbol "*")) (fmap (_: "/") (symbol "/"));
  opRel = alt
    (fmap (_: "<=") (symbol "<="))
    (alt (fmap (_: ">=") (symbol ">="))
    (alt (fmap (_: "<") (symbol "<"))
         (fmap (_: ">") (symbol ">"))));
  opEq = alt
    (fmap (_: "!=") (symbol "!="))
    (fmap (_: "==") (symbol "=="));
  
  addSub = chainl mulDiv opAddSub;
  mulDiv = chainl hasAttrExpr opMulDiv;
  concatLists = chainl addSub (fmap (_: "++") (symbol "++"));
  # `!` binds looser than arithmetic/`++` but tighter than `//`
  notExpr = alt
    (bind (symbol "!") (_: fmap (e: ast.mkBinOp "!" e (ast.mkLit null)) notExpr))
    concatLists;
  update = chainl notExpr (fmap (_: "//") (symbol "//"));
  # Relational operators bind tighter than (in)equality. Both are
  # non-associative, so `a < b < c` and `a == b == c` are syntax errors.
  relExpr = bind update (l:
    alt (bind opRel (o: bind update (r: pure (ast.mkBinOp o l r)))) (pure l));
  cmpExpr = bind relExpr (l:
    alt (bind opEq (o: bind relExpr (r: pure (ast.mkBinOp o l r)))) (pure l));
  andExpr = chainr cmpExpr (fmap (_: "&&") (symbol "&&"));
  orExpr = chainr andExpr (fmap (_: "||") (symbol "||"));
  implExpr = chainr orExpr (fmap (_: "->") (symbol "->"));
  
  # list
  listExpr = bind (symbol "[") (_:
    bind (many postfix) (elems:
      skipThen (symbol "]") (pure (ast.mkList elems))
    )
  );
  
  # attrset
  attrExpr = bind (symbol "{") (_:
    bind bindingList (bindings:
      skipThen (symbol "}") (pure (ast.mkAttrSet bindings))
    )
  );
  
  # primary: attribute set, list, or atom
  primary = alt attrExpr (alt listExpr atom);
  
  # postfix attribute selection and `or` default (binds tighter than application)
  postfix = bind primary (e:
    let go = st:
          alt (bind (symbol ".") (_: bind attrComponent (c:
            go {
              hasSel = true;
              expr = ast.mkBinOp "." st.expr
                (if c ? static then ast.mkLit c.static else c.dynamic);
            }
          ))) (pure st);
        stP = go { hasSel = false; expr = e; };
    in bind stP (st:
      if !st.hasSel then pure st.expr
      else let sel = st.expr; in
        alt (bind (symbol "or") (_: fmap (d: { type = "or"; sel = sel; default = d; }) postfix))
            (pure sel)
    )
  );
  
  # application (space separated, folds left)
  app = bind postfix (first:
    let go = acc:
          alt (bind postfix (a: go (ast.mkApp acc a)))
              (pure acc);
    in go first
  );
  
  # unary minus binds tighter than `?` and multiplication
  negExpr = alt
    (bind (symbol "-") (_: fmap (e: ast.mkBinOp "neg" e (ast.mkLit null)) negExpr))
    app;
  
  # `expr ? attr.path`
  hasAttrExpr = bind negExpr (e:
    alt (bind (symbol "?") (_: bind attrPath (path:
      pure { type = "hasattr"; base = e; inherit path; }
    ))) (pure e)
  );

  # lambda parameters: identifier or { a, b ? default, ... } [@ name]
  patternEntry = bind ident (name:
    let n = if builtins.isAttrs name then name.name else name;
    in alt (bind (symbol "?") (_: fmap (d: { name = n; default = d; }) expr))
           (pure { name = n; })
  );
  
  patternBody = alt
    (bind (symbol "...") (_: pure { ellipsis = true; entries = [ ]; }))
    (bind (sepBy patternEntry (symbol ",")) (entries:
      bind (optional (symbol ",")) (comma:
        alt
          (bind (symbol "...") (_:
            if entries == [] || comma == [] then fail
            else pure { ellipsis = true; inherit entries; }
          ))
          (if entries == [ ] && comma != [ ] then fail
           else pure { ellipsis = false; inherit entries; })
      )
    ));
  
  patternParam = between (symbol "{") (symbol "}") patternBody;
  
  # { pattern } @ name : body
  patternLambdaPost = bind patternParam (p:
    bind (optional (bind (symbol "@") (_: ident))) (atList:
      skipThen (symbol ":") (bind expr (body:
        pure {
          type = "lambda";
          pattern = p;
          argName = if atList == [] then null else (b.head atList).name;
          inherit body;
        })
      )
    )
  );
  
  # name @ { pattern } : body
  patternLambdaPre = bind ident (name:
    skipThen (symbol "@") (bind patternParam (p:
      skipThen (symbol ":") (bind expr (body:
        pure { type = "lambda"; pattern = p; argName = name.name; inherit body; })
      ))
    ))
  ;
  
  # name : body
  identLambda = bind ident (name:
    skipThen (symbol ":") (bind expr (body:
      pure (ast.mkLambda name.name body)
    ))
  );
  
  lambda = alt patternLambdaPost (alt patternLambdaPre identLambda);
  
  fullExpr = alt ifExpr (alt assertExpr (alt letExpr (alt withExpr implExpr)));
  expr = alt lambda fullExpr;
    in {
      formatError = formatError;
      parse = text:
        let
          res = runParser (thenSkip (skipThen spaces expr) eof) text;
        in
          if res.type == "error"
          then throw (formatError text res.value)
          else ast.annotate res.value;

      safeParseUntil = { text }:
        let
          invalid = message: {
            context = "nix.parser.safeParseUntil";
            inherit message;
            offset = 0;
          };
          invalidTerminator =
            if !b.isString terminator || terminator == ""
            then invalid "terminator must be a non-empty string"
            else if wsChar (b.substring 0 1 terminator)
            then invalid "terminator must not start with whitespace"
            else null;
        in
          if invalidTerminator != null then {
            type = "error";
            value = invalidTerminator;
          }
          else
            let
              expressionParser = parsec.bind spaces (_:
                parsec.bind (withMatch expr) (matched:
                  let
                    expression = b.elemAt matched 0;
                    expressionAst = b.elemAt matched 1;
                  in
                    parsec.bind (parsec.string terminator) (_:
                      parsec.pure {
                        inherit expression;
                        ast = expressionAst;
                      }
                    )
                )
              );
              res = expressionParser [text 0 (b.stringLength text)];
            in
              if failed res then
                let
                  details = errorDetails text res;
                in {
                  type = "error";
                  value = res // {
                    offset = details.off;
                    message = details.msg;
                  };
                }
              else
                let
                  parsed = b.elemAt res 0;
                  consumed = b.elemAt res 1;
                  expressionLength = b.stringLength parsed.expression;
                in {
                  type = "success";
                  value = {
                    ast = ast.annotate parsed.ast;
                    expression = parsed.expression;
                    expressionOffset = consumed - expressionLength - b.stringLength terminator;
                    expressionLength = expressionLength;
                    inherit consumed;
                  };
                };
    };

  defaultParser = mkParser null;
in
  defaultParser // {
    safeParseUntil = { terminator, text }:
      (mkParser terminator).safeParseUntil { inherit text; };

    parseUntil = { terminator, text }:
      let
        p = mkParser terminator;
        res = p.safeParseUntil { inherit text; };
      in
        if res.type == "error"
        then throw (p.formatError text res.value)
        else res.value.ast;
  }
