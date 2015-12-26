{ map, zip, concat-map } = require \prelude-ls
{ is-expression } = require \esutils .ast
statementify = require \./es-statementify
{
  import-compilerspace-macro
  multiple-statements
} = require \./import-macro

# Any static identifier is prefixed with `:`, like `(. Math :random)`
is-static-identifier = (node) -> node.type is \Identifier and node.name[0] is \:

# Returns true if this is computed.
fix-identifier = (node) ->
  if is-static-identifier node
    node.name .= slice 1
    false
  else
    true

filter-identifier = (node) ->
  fix-identifier node
  node

chained-binary-expr = (type, operator) ->
  macro = (...args) ->
    env = this
    switch
    | args.length is 1 => env.compile args.0
    | args.length is 2
      type : type
      operator : operator
      left  : env.compile args.0
      right : env.compile args.1
    | arguments.length > 2
      [ head, ...rest ] = args
      macro.call do
        env
        macro.call env, env.compile head
        macro.apply env, rest
    | otherwise =>
      throw Error "binary expression macro `#operator` unexpectedly called \
                   with no arguments"

  (...args) ->
    env = this
    if args.length is 1
      throw Error "Chained binary expression `#operator` unexpectedly called \
                   with 1 argument"
    else
      macro.apply env, arguments

unary-expr = (operator) ->

  (arg) ->
    { compile } = env = this

    type : \UnaryExpression
    operator : operator
    prefix : true
    argument : compile arg

n-ary-expr = (operator) ->
  n-ary = chained-binary-expr \BinaryExpression operator
  unary = unary-expr operator
  (...args) ->
    env = this
    ( switch args.length | 0 => null
                         | 1 => unary
                         | _ => n-ary
    ).apply env, arguments

update-expression = (operator, {type}) ->
  unless operator in <[ ++ -- ]>
    throw Error "Illegal update expression operator #operator"
  is-prefix = ( type is \prefix )
  (...arg) ->
    { compile } = env = this
    if arg.length isnt 1
      throw Error "Expected `++` expression to get exactly 1 argument but \
                   got #{arguments.length}"
    type : \UpdateExpression
    operator : operator
    prefix : is-prefix
    argument : compile arg.0

quote = (...args) ->
  env = this
  if args.length > 1
    throw Error "Too many arguments to quote; \
                 expected 1 but got #{args.length}"

  it = args.0

  if it then env.compile-to-quote it
  else
    # Compile as if empty list
    env.compile-to-quote do
      { type : \list values : [] location : "returned from macro" }

optionally-implicit-block-statement = ({compile, compile-many}, body) ->
  switch body.length
  | 1 =>
    body-compiled = compile body.0
    if body-compiled.type is \BlockStatement then return body-compiled
    fallthrough # "else"
  | _ =>
    type : \BlockStatement
    body : compile-many body .map statementify

# Here's a helper that extracts the common parts to macros for
# FunctionExpressions and FunctionDeclarations since they're so similar.
function-type = (type) ->
  (...args) ->
    { compile, compile-many } = env = this
    # The first optional atom argument gives the id that should be attached to
    # the function expression.  The next argument is the function's argument
    # list.  All further arguments are statements for the body.

    var id, params

    arg1 = args.shift!

    if arg1.type is \atom
      id := type : \Identifier name : arg1.value
      params := args.shift! .values .map compile
    else
      # Let's assume it's a list then
      id := null
      params := arg1.values .map compile

    type : type
    id : id
    params : params
    body : optionally-implicit-block-statement env, args

contents =
  \+ : n-ary-expr \+
  \- : n-ary-expr \-
  \* : chained-binary-expr \BinaryExpression \*
  \/ : chained-binary-expr \BinaryExpression \/
  \% : chained-binary-expr \BinaryExpression \%

  \++  : update-expression \++ type : \prefix # Synonym for below
  \++_ : update-expression \++ type : \prefix
  \_++ : update-expression \++ type : \suffix
  \--  : update-expression \-- type : \prefix # Synonym for below
  \--_ : update-expression \-- type : \prefix
  \_-- : update-expression \-- type : \suffix

  \&& : chained-binary-expr \LogicalExpression \&&
  \|| : chained-binary-expr \LogicalExpression \||
  \!  : unary-expr \!

  \< : chained-binary-expr \BinaryExpression \<
  \> : chained-binary-expr \BinaryExpression \>
  \<= : chained-binary-expr \BinaryExpression \<=
  \>= : chained-binary-expr \BinaryExpression \>=

  \delete : unary-expr \delete
  \typeof : unary-expr \typeof
  \void   : unary-expr \void
  \instanceof : chained-binary-expr \BinaryExpression \instanceof
  \in : chained-binary-expr \BinaryExpression \in

  \& : chained-binary-expr \BinaryExpression \&
  \| : chained-binary-expr \BinaryExpression \|
  \^ : chained-binary-expr \BinaryExpression \^
  \>>  : chained-binary-expr \BinaryExpression \>>
  \<<  : chained-binary-expr \BinaryExpression \<<
  \>>> : chained-binary-expr \BinaryExpression \>>>
  \~ : unary-expr \~

  \==  : chained-binary-expr \BinaryExpression \==
  \!=  : chained-binary-expr \BinaryExpression \!=
  \=== : chained-binary-expr \BinaryExpression \===
  \!== : chained-binary-expr \BinaryExpression \!==

  \=    : chained-binary-expr \AssignmentExpression \=
  \+=   : chained-binary-expr \AssignmentExpression \+=
  \-=   : chained-binary-expr \AssignmentExpression \-=
  \*=   : chained-binary-expr \AssignmentExpression \*=
  \/=   : chained-binary-expr \AssignmentExpression \/=
  \%=   : chained-binary-expr \AssignmentExpression \%=
  \>>=  : chained-binary-expr \AssignmentExpression \>>=
  \<<=  : chained-binary-expr \AssignmentExpression \<<=
  \>>>= : chained-binary-expr \AssignmentExpression \>>>=
  \&=   : chained-binary-expr \AssignmentExpression \&=
  \|=   : chained-binary-expr \AssignmentExpression \|=
  \^=   : chained-binary-expr \AssignmentExpression \^=

  \seq : (...expressions) ->
    { compile } = env = this
    type : \SequenceExpression
    expressions : expressions .map compile

  \array : (...elements) ->
    { compile } = env = this
    type : \ArrayExpression
    elements : elements.map compile

  \object : do
    check-list = (list, i) ->
      | list? and list.type is \list => list.values
      | otherwise => throw Error "Expected property #i to be a list"

    infer-name = (prefix, name, computed) ->
      if computed
        prefix
      else if typeof name.type is \Literal
        "#prefix #{name.value}"
      else
        "#prefix #{name.name}"

    compile-get-set = (i, type, [name, params, ...body]) ->
      if not name?
        throw Error "Expected #{type}ter in property #i to have a name"

      name = @compile name
      computed = fix-identifier name and typeof name.type isnt \Literal
      kind = infer-name "#{type}ter", name, computed

      if not params? or params.type isnt \list
        throw Error "Expected #{kind} in property #i to have a parameter list"

      params .= values

      # Catch this error here, to return a more sensible, helpful error message
      # than merely an InvalidAstError referencing property names from the
      # stringifier itself.
      if type is \get
        if params.length isnt 0
          throw Error "Expected #{kind} in property #i to have no parameters"
      else # type is \set
        if params.length isnt 1
          throw Error "Expected #{kind} in property #i to have exactly one \
                       parameter"
        param = params.0
        if param.type isnt \atom or param.value.0 is \:
          throw Error "Expected parameter for #{kind} in property #i to be an \
                       identifier"
        params = [
          type : \Identifier
          name : param.value
        ]

      type : \Property
      kind : type
      key : name
      computed : computed
      value :
        type : \FunctionExpression
        id : null
        params : params
        body : optionally-implicit-block-statement this, body
        expression : false

    compile-method = (i, [name, params, ...body]) ->
      if not name?
        throw Error "Expected method in property #i to have a name"

      name = @compile name
      computed = fix-identifier name and name.type isnt \Literal
      method = infer-name 'method', name, computed

      if not params? or params.type isnt \list
        throw Error "Expected #method in property #i to have a parameter \
                     list"

      params = for param, j in params.values
        if param.type isnt \atom or param.value.0 is \:
          throw Error "Expected parameter #j for #method in property #i to be \
                       an identifier"
        type : \Identifier
        name : param.value

      type : \Property
      kind : \init
      method : true
      computed : computed
      key : name
      value :
        type : \FunctionExpression
        id : null
        params : params
        body : optionally-implicit-block-statement this, body
        expression : false

    compile-list = (i, args) ->
      | args.length is 0 =>
        throw Error "Expected at least two arguments in property #i"
      | args.length is 1 =>
        name = @compile args.0
        if fix-identifier name
          throw Error "Expected name in property #i to be a symbol identifier"
        type : \Property
        kind : \init
        key : name
        value : name
        shorthand : true
      | args.length is 2 =>
        key = @compile args.0
        computed = fix-identifier key and key.type isnt \Literal
        type : \Property
        kind : \init
        computed : computed
        key : key
        value : filter-identifier @compile args.1
      # Check this before compilation and macro resolution to ensure that
      # neither can affect this, but that it can be avoided in the edge case if
      # needed with `(id get)` or `(id set)`, where `(macro id (lambda (x) x))`.
      | args.0.type is \atom and args.0.value in <[get set]> =>
        compile-get-set.call this, i, args.0.value, args[1 til]
      # Reserve this for future generator use.
      | args.0.type is \atom and args.0.value is \* =>
        throw Error "Unexpected generator method in property #i"
      | otherwise => compile-method.call this, i, args

    ->
      type : \ObjectExpression
      properties : for args, i in arguments
        compile-list.call this, i, (check-list args, i)

  \var : do
    declaration = (...args) ->
      { compile } = env = this
      if args.length > 2
        throw Error "Expected variable declaration to get 1 or 2 arguments, \
                     but got #{arguments.length}."
      type : \VariableDeclaration
      kind : "var"
      declarations : [
        type : \VariableDeclarator
        id : compile args.0
        init : if args.1 then compile args.1 else null
      ]

    declaration

  \block : (...statements) ->
    { compile-many } = env = this
    type : \BlockStatement
    body : compile-many statements .map statementify

  \switch : (discriminant, ...cases) ->
    { compile, compile-many } = env = this
    type : \SwitchStatement
    discriminant : compile discriminant
    cases : cases .map (.values)
      .map ([t, ...c]) ->
        type       : \SwitchCase
        test       : do
          t = compile t
          if t.type is \Identifier and t.name is \default
            null # emit "default:" switchcase label
          else t
        consequent : compile-many c .map statementify

  \if : (test, consequent, alternate) ->
    { compile } = env = this
    type : \IfStatement
    test       : compile test
    consequent : statementify compile consequent
    alternate :
      if alternate then statementify compile that
      else null

  \?: : (test, consequent, alternate) ->
    { compile } = env = this
    type : \ConditionalExpression
    test       : compile test
    consequent : compile consequent
    alternate  : compile alternate

  \while : (test, ...body) ->
    { compile } = env = this
    type : \WhileStatement
    test : compile test
    body : optionally-implicit-block-statement env, body

  \dowhile : (test, ...body) ->
    { compile } = env = this
    type : \DoWhileStatement
    test : compile test
    body : optionally-implicit-block-statement env, body

  \for : (init, test, update, ...body) ->
    { compile } = env = this
    type : \ForStatement
    init : compile init
    test : compile test
    update : compile update
    body : optionally-implicit-block-statement env, body

  \forin : (left, right, ...body) ->
    { compile } = env = this
    type : \ForInStatement
    left : compile left
    right : compile right
    body : optionally-implicit-block-statement env, body

  \break : (arg) ->
    { compile } = env = this
    type : \BreakStatement
    label : if arg then compile arg else null
  \continue : (arg) ->
    {compile} = env = this
    type : \ContinueStatement
    label : if arg then compile arg else null

  \label : (...args) ->
    { compile } = env = this
    if args.length not in [ 1 2 ]
      throw Error "Expected `label` macro to get 1 or 2 arguments, but got \
                   #{args.length}"
    [ label, body ] = args

    body = if body then statementify compile body
                   else type : \EmptyStatement

    type  : \LabeledStatement
    label : compile label
    body  : body

  \return : (arg) ->
    { compile } = env = this
    type : \ReturnStatement
    argument : compile arg

  \. : do
    join-members = (host, prop) ->
      property-compiled = @compile prop
      computed = fix-identifier property-compiled
      type : \MemberExpression
      computed : computed
      object   : host
      property : property-compiled

    (host) ->
      switch
      | &length is 0 => throw Error "dot called with no arguments"
      | &length is 1 => @compile host
      | &length is 2 => join-members.call this, (@compile host), &1
      | otherwise =>
        host = @compile host
        for i from 1 til &length
          host = join-members.call this, host, &[i]
        host

  \lambda : function-type \FunctionExpression

  \function : function-type \FunctionDeclaration

  \new : (...args) ->

    { compile } = env = this

    [ newTarget, ...newArgs ] = args

    if not newTarget? then throw Error "No target for `new`"
    # `newArgs` can be empty though

    type : \NewExpression
    callee : compile newTarget
    arguments : newArgs .map compile

  \debugger : (...args) ->
    if args.length
      throw Error "Expected no arguments to `debugger` statement"
    type : \DebuggerStatement

  \throw : (...args) ->

    { compile } = env = this

    if args.length isnt 1
      throw Error "Expected 1 argument to `throws`; got #{args.length}"

    type : \ThrowStatement
    argument : compile args.0

  \regex : (...args) ->

    { compile } = env = this

    if args.length not in [ 1 2 ]
      throw Error "Expected 1 or 2 arguments to `regex`; got #{args.length}"

    type : \Literal
    value : new RegExp args.0.value, args.1?value

  \try : (...args) ->

    { compile, compile-many } = env = this

    is-part = (thing, clause-name) ->
      if not (thing.type is \list) then return false
      first = thing.values.0
      (first.type is \atom) && (first.value is clause-name)

    catch-part = null
    finally-part = null
    others = []

    args.for-each ->
      if it `is-part` \catch
        if catch-part then throw Error "Duplicate `catch` clause"
        catch-part := it.values.slice 1
      else if it `is-part` \finally
        if finally-part then throw Error "Duplicate `finally` clause"
        finally-part := it.values.slice 1
      else
        others.push it

    catch-clause = if catch-part
      type : \CatchClause
      param : compile catch-part.shift!
      body : optionally-implicit-block-statement env, catch-part
    else null

    finally-clause = if finally-part
      optionally-implicit-block-statement env, finally-part
    else null

    type : \TryStatement
    block :
      type : \BlockStatement
      body : compile-many others .map statementify
    handler : catch-clause
    finalizer : finally-clause

  \macro : (...args) ->

    env = this

    compile-as-macro = (es-ast) ->

      # This hack around require makes loading macros from relative paths work.
      #
      # It was guided by LiveScript's implementation
      # https://github.com/gkz/LiveScript/blob/a7525ce6fe7d4906f5d401edf94f15fe5a6b471e/src/node.ls#L10-L18
      # which originally derives from the Coco language.
      #
      # The gist of it is to use the main module's `require` method, such that
      # the current working directory is the root relative to which packages
      # are searched.

      {main} = require
      dirname = "."
      main
        ..paths = main.constructor._node-module-paths process.cwd!
        ..filename = dirname

      root-require = main.require.bind main

      let require = root-require
        eval "(#{env.compile-to-js es-ast})"

    switch args.length
    | 1 =>
      form = args.0
      switch
      | form.type is \atom

        # Mask any macro of that name in the current scope

        import-compilerspace-macro env, form.value, null

      | otherwise

        # Attempt to compile the argument, hopefully into an object,
        # define macros from its keys

        es-ast = env.compile form

        result = compile-as-macro es-ast

        switch typeof! result
        | \Object =>
          for k, v of result
            import-compilerspace-macro env, k, v
        | \Null => fallthrough
        | \Undefined => # do nothing
        | otherwise =>
          throw Error "Invalid macro source #that (expected to get an Object, \
                       or a name argument and a Function)"
    | 2 =>
      [ name, form ] = args

      switch
      | form.type is \atom

        name = name.value
        target-name = form.value

        alias-target-macro = env.find-macro target-name

        if not alias-target-macro
          throw Error "Macro alias target `#target-name` is not defined"

        import-compilerspace-macro env, name, alias-target-macro

      | form.type is \list

        userspace-macro = form |> env.compile |> compile-as-macro

        name .= value
        import-compilerspace-macro env, name, userspace-macro

    | otherwise =>
      throw Error "Bad number of arguments to macro constructor \
                   (expected 1 or 2; got #that)"
    return null

  \quote : -> quote.apply this, arguments

  \quasiquote : do

    # Compile an AST node which is part of the body of a quasiquote.  This
    # means we have to resolve lists which first atom is `unquote` or
    # `unquote-splicing` into either an array of values or an identifier to
    # an array of values.
    qq-body = (env, ast) ->

      recurse-on = (ast-list) ->
        ast-list.values
        |> map qq-body env, _
        |> generate-concat

      unquote = ->
        if arguments.length isnt 1
          throw Error "Expected 1 argument to unquote but got #{rest.length}"

        # Unquoting should compile to just the thing separated with an array
        # wrapper.
        [ env.compile it ]

      unquote-splicing = ->
        if arguments.length isnt 1
          throw Error "Expected 1 argument to unquoteSplicing but got
                       #{rest.length}"

        # Splicing should leave it without the array wrapper so concat
        # splices it into the array it's contained in.

        type : \MemberExpression
        computed : false
        object :
          env.compile it
        property :
          type : \Identifier
          name : \values

      switch
      | ast.type is \list
        [head, ...rest] = ast.values
        switch
        | not head?
          # quote an empty list
          [ quote.call env, {
            type : \list
            values : []
            location :"returned from macro"
          } ]
        | head.type is \atom =>
          switch head.value
          | \unquote          => unquote         .apply null rest
          | \unquote-splicing => unquote-splicing.apply null rest
          | _ => [ recurse-on ast ]
        | _   => [ recurse-on ast ]

      | _ => [ quote.call env, ast ]

    generate-concat = (concattable-things) ->

      # Each quasiquote-body resolution produces SpiderMonkey AST compiled
      # values, but if there are many of them, it'll produce an array.  We'll
      # convert these into ArrayExpressions so the results are effectively
      # still compiled values.

      concattable-things
      |> map ->
        if typeof! it is \Array
          type : \ArrayExpression elements : it
        else it

      # Now each should be an array (or a literal that was
      # `unquote-splicing`ed) so they can be assumed to be good for
      # `Array::concat`.

      # We then construct a call to Array::concat with each of the now
      # quasiquote-resolved and compiled things as arguments.  That makes
      # this macro produce a concatenation of the quasiquote-resolved
      # arguments.
      |> ->
        type : \ObjectExpression
        properties : [
          * type : \Property
            kind : \init
            key :
              type : \Identifier
              name : \type
            value :
              type : \Literal
              value : \list
              raw : "\"list\""
          * type : \Property
            kind : \init
            key :
              type : \Identifier
              name : \values
            value :
              type : \CallExpression
              callee :
                type : \MemberExpression
                object :
                  type : \MemberExpression
                  object   : type : \Identifier name : \Array
                  property : type : \Identifier name : \prototype
                property   : type : \Identifier name : \concat
              arguments : it
        ]
    qq = (...args) ->

      env = this

      if args.length > 1
        throw Error "Too many arguments to quasiquote (`); \
                     expected 1, got #{args.length}"
      arg = args.0

      if arg.type is \list and arg.values.length

        first-arg = arg.values.0

        if first-arg.type is \atom and first-arg.value is \unquote
          rest = arg.values.slice 1 .0
          env.compile rest

        else
          arg.values
          |> map qq-body env, _
          |> generate-concat

      else quote.call env, arg # act like regular quote

module.exports =
  parent : null
  contents : contents
