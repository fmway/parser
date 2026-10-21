# The tags of the core schema, and the handlers of the tags.
#
# The core schema is the set of tags that YAML itself defines: !!str,
# !!int, !!float, !!bool and !!null. A tag of the core schema says what
# the content of a node has to look like, and a content that does not
# fit is an error: the tag is recognised, and a node with a recognised
# tag and content that does not satisfy it is not valid, and cannot be
# turned into a value (see section 3.3.3 of the specification).
#
# A tag that nobody knows is a different thing: the tag is then
# unavailable, and the content of the node is kept as the text it is
# (see section 3.3.4).
#
# A caller may give a handler for every tag, and the handlers of the
# caller are looked up first, so that a caller may say what a tag of
# the core schema means as well. A caller that says what a tag means is
# then responsible for the content of the nodes that carry it.

{ scalars }:

let
  b = builtins;

  # The prefix that the secondary tag handle stands for. A tag of the
  # core schema may be written either as "!!int" or, once the handle
  # has been resolved, as "tag:yaml.org,2002:int".
  yamlPrefix = "tag:yaml.org,2002:";

  # The short name of a tag.
  shortOf = tag:
    if b.substring 0 (b.stringLength yamlPrefix) tag == yamlPrefix
    then "!!" + b.substring (b.stringLength yamlPrefix) (b.stringLength tag - b.stringLength yamlPrefix) tag
    else tag;

  # The tags of the core schema.
  #
  # Each of them says what the content of a node has to look like, and
  # what the type of it is called. The ones that accept any content say
  # nothing about it.
  coreTags = {
    "!!str" = {
      accepts = _: true;
      type = "a string";
    };
    "!!int" = {
      accepts = text:
        b.match "[-+]?[0-9]+" text != null
        || b.match "0x[0-9a-fA-F]+" text != null
        || b.match "0o[0-7]+" text != null;
      type = "an integer";
    };
    "!!float" = {
      accepts = text:
        b.match "[-+]?([0-9]+\\.[0-9]*|\\.[0-9]+)([eE][-+]?[0-9]+)?" text != null
        || b.match "[-+]?[0-9]+" text != null;
      type = "a float";
    };
    "!!bool" = {
      accepts = text:
        text == "true" || text == "True" || text == "TRUE"
        || text == "false" || text == "False" || text == "FALSE";
      type = "a boolean";
    };
    "!!null" = {
      accepts = _: true;
      type = "a null";
    };
  };

  # The handlers of the tags of the core schema: the value of a node
  # with one of them is the content of the node, read as the type of
  # the tag.
  coreHandlers = {
    "!!str" = text: text;
    "!!int" = text: scalars.asInt text;
    "!!float" = text: scalars.asFloat text;
    "!!bool" = text: scalars.asBool text;
    "!!null" = text: null;
  };

in rec {
  inherit coreTags coreHandlers shortOf;

  # The failure of a tag handler.
  #
  # A handler that does not like the content of a node gives this
  # back, and the parser reports it as an error of the document, with
  # the place where the node is:
  #
  #   "!isfoo" = text: if text == "foo" then true else yaml.failWith "not foo";
  #
  # The handler is called while the document is parsed, so that a
  # failure is reported right away, and not when the value is looked at
  # (which may be never: Nix is lazy).
  failWith = msg: { __yamlTagFailure = msg; };

  # Is the value the failure of a tag handler?
  isFailure = value: value ? __yamlTagFailure;

  # Call the handler of a tag, and say what it says.
  #
  # The result is [value, failure]:
  #
  #   value   :: what the handler gave back, or null when it failed
  #   failure :: the message of the failure, or null when it did not
  #
  # A handler that throws is a failure as well: Nix has no way of
  # catching a throw and keeping its message, so the message of such a
  # failure is a general one.
  call = h: tag: text:
    let
      res = b.tryEval (h text);
    in
      if ! res.success
      then [ null "the handler of the tag '${tag}' failed" ]
      else if isFailure res.value
      then [ null res.value.__yamlTagFailure ]
      else [ res.value null ];

  # The handlers of the tags.
  #
  # The tags of the caller are put over the ones of the core schema, so
  # that a caller may say what "!int" means as well.
  #
  # The result is a function that takes the name of a tag and gives
  # back its handler, or null when there is none.
  handlers = tags:
    let
      all =
        if tags == null
        then coreHandlers
        else if ! b.isAttrs tags
        then throw "yaml: the tags must be an attribute set of handlers"
        else b.foldl'
          (acc: name: acc // { ${name} = tags.${name}; })
          coreHandlers
          (b.attrNames tags);

      lookup = tag:
        if all ? ${tag} then all.${tag}
        else if all ? ${shortOf tag} then all.${shortOf tag}
        else null;
    in
      tag:
        let
          h = lookup tag;
        in
          if h == null then null else h;

  # Does the caller have a handler for the tag?
  #
  # The tag is looked up by its full name and then by its short one.
  known = tags: tag: name:
    tags != null
    && b.isAttrs tags
    && (tags ? ${tag} || tags ? ${name});

  # Does the content of a node fit the tag it carries?
  #
  # The result is null when it does, and a message when it does not.
  # A tag that is not one of the core schema always fits: nobody knows
  # what it means, and the content of the node is kept as the text it
  # is.
  check = tags: tag: text:
    let
      # The constraint of the tag, if the tag is one of the core
      # schema. The tag is looked up by its full name first, and then by
      # its short one.
      rule = coreTags.${tag} or null;
      name = if rule != null then tag else shortOf tag;
      rule' = if rule != null then rule else coreTags.${name} or null;
    in
      if rule' == null then null
      # A caller that says what the tag means is responsible for the
      # content of the nodes that carry it.
      else if tags != { } && known tags tag name then null
      else if (rule'.accepts text) then null
      else "'${text}' is not ${rule'.type}";
}
