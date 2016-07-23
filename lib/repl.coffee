{Task, Emitter} = require 'atom'

Spinner = require './load-widget'
ReplTextEditor = require './repl-text-editor'
ReplHistory = require './repl-history'
LocalReplProcess = require './process/local-repl-process'
RemoteReplProcess = require './process/remote-repl-process'
SelfHostedProcess = require './process/self-hosted-process'
replHelpText = ";; This Clojure REPL is divided into two areas, top and bottom, delimited by a line of dashes. The top area shows code that's been executed in the REPL, standard out from running code, and the results of executed expressions. The bottom area allows Clojure code to be entered. The code can be executed by pressing shift+enter.\n\n;; Try it now by typing (+ 1 1) in the bottom section and pressing shift+enter.\n\n;; Working in another Clojure file and sending forms to the REPL is the most efficient way to work. Use the following key bindings to send code to the REPL. See the settings for more keybindings.\n\n;; ctrl-alt-, then b - execute block. Finds the block of Clojure code your cursor is in and executes that.\n\n;; Try it now. Put your cursor inside this block and press ctrl and comma together,\n;; release, then press b.\n(+ 2 3)\n\n;; ctrl-alt-, s - Executes the selection. Sends the selected text to the REPL.\n\n;; Try it now. Select these three lines and press ctrl and comma together,\n;; release, then press s.\n(println \"hello 1\")\n(println \"hello 2\")\n(println \"hello 3\")\n\n;; You can disable this help text in the settings.\n"

# temporary usage of copy of Atom Ink Tree view
TreeView = require './tree-view'

# Temporary performance helpers

startTime = ->
  window.performance.now()

logElapsed = (name, start)->
  elapsed = window.performance.now()-start
  console.log(name + " " + elapsed.toFixed() + " ms")


module.exports =

# Represents the REPL where code is executed and displayed. It is split into three
# parts. 1. The running process. 2. The nRepl connection, 3. The text editor where
# results are displayed.
class Repl
  emitter: null

  # A local or remote process
  process: null

  # The text editor where results are displayed or commands can be enterered
  replTextEditor: null

  # Keeps track of the REPL history.
  replHistory: null

  extensionsFeature: null

  constructor: (@extensionsFeature)->
    @emitter = new Emitter
    @replTextEditor = new ReplTextEditor()
    @replHistory = new ReplHistory()
    @loading = new Spinner()

    # Connect together repl text editor and history
    @replTextEditor.onHistoryBack =>
      if @running()
        @replHistory.setCurrentText(@replTextEditor.enteredText())
        @replTextEditor.setEnteredText(@replHistory.back())

    @replTextEditor.onHistoryForward =>
      if @running()
        @replHistory.setCurrentText(@replTextEditor.enteredText())
        @replTextEditor.setEnteredText(@replHistory.forward())

    @replTextEditor.onDidOpen =>
      # Display the help text when the repl opens.
      if atom.config.get("proto-repl.displayHelpText")
        @appendText(replHelpText)

    # The window was closed
    @replTextEditor.onDidClose =>
      try
        @process?.stop(@session)
        @replTextEditor = null
        @emitter.emit 'proto-repl-repl:close'
      catch error
        console.log("Warning error while closing: " + error)

  # Calls the callback after the REPL has been started
  onDidStart: (callback)->
    @emitter.on 'proto-repl-repl:start', callback

  onDidStop: (callback)->
    @emitter.on 'proto-repl-repl:stop', callback

  # Returns true if the process is running
  running: ->
    @process?.running()

  # Returns the type of the REPL that's currently running.
  # "SelfHosted", "Remote", Local"
  getType: ->
    @process?.getType()

  isSelfHosted: ->
    @getType() == "SelfHosted"

  handleReplStarted: ->
    @appendText(@process.getCurrentNs() + "=>", true)
    @emitter.emit 'proto-repl-repl:start'

  handleReplStopped: ->
    @emitter.emit 'proto-repl-repl:stop'

  # Starts the process unless it's already running.
  startProcessIfNotRunning: (projectPath)->
    if @running()
      @appendText("REPL already running")
    else
      @process = new LocalReplProcess(
        (text, waitUntilOpen=false)=>@appendText(text, waitUntilOpen))
      @process.start projectPath,
        messageHandler: (msg)=> @handleConnectionMessage(msg)
        startCallback: => @handleReplStarted()
        stopCallback: => @handleReplStopped()

  # Starts nRepl connection
  # * `options` An {Object} with following keys
  #   * `host` The {String} host name to connect (optional). Defaults to "localhost"
  #   * `port` The {Number} port number to connect
  startRemoteReplConnection: ({host, port})->
    if @running()
      @appendText("REPL already running")
    else
      @process = new RemoteReplProcess(
        (text, waitUntilOpen=false)=>@appendText(text, waitUntilOpen))
      @appendText("Starting remote REPL connection on #{host}:#{port}", true)
      connOptions =
        host: host,
        port: port,
        messageHandler: ((msg)=> @handleConnectionMessage(msg)),
        startCallback: => @handleReplStarted()
        stopCallback: => @handleReplStopped()
      @process.start(connOptions)

  startSelfHostedConnection: ->
    if @running()
      @appendText("REPL already running")
    else
      @process = new SelfHostedProcess(
        (text, waitUntilOpen=false)=>@appendText(text, waitUntilOpen))
      connOptions=
        messageHandler: ((msg)=> @handleConnectionMessage(msg)),
        startCallback: =>
          @appendText("Self Hosted REPL Started!", true)
          @handleReplStarted()
        stopCallback: => @handleReplStopped()
      @process.start connOptions

  handleConnectionMessage: (msg)->
    if msg.out
      @appendText(msg.out)
    else
      # Only print values from the regular session.
      if msg.err
        @appendText(@process.getCurrentNs() + "=> " + msg.err)
      else if msg.value
        if atom.config.get("proto-repl.autoPrettyPrint")
          @appendText(@process.getCurrentNs() + "=>\n" + protoRepl.prettyEdn(msg.value))
        else
          @appendText(@process.getCurrentNs() + "=> " + msg.value)

  # Invoked when the REPL window is closed.
  onDidClose: (callback)->
    @emitter.on 'proto-repl-repl:close', callback

  # Appends text to the display area of the text editor.
  appendText: (text, waitUntilOpen=false)->
    @replTextEditor?.appendText(text, waitUntilOpen)

  # Displays some result data inline. tree is a recursive structure expected to
  # be of the shape like the following.
  # ["text for display", {button options}, [childtree1, childtree2, ...]]
  displayInline: (editor, range, tree, error=false)->
    end = range.end.row

    # Remove the existing view if there is one
    @ink.Result.removeLines(editor, end, end)

    # Defines a recursive function that can convert the tree of values to
    # display into an Atom Ink tree view. Sub-branches are expandable.
    recurseTree = ([head, button_options, children...])=>
      if children && children.length > 0
        childViews = children.map  (x)=>
          if x instanceof Array
            recurseTree(x)
          else
            # The button options here are for the head not the child
            TreeView.leafView(x,{})
        TreeView.treeView(head, childViews, button_options)
      else
        TreeView.leafView(head, button_options || {})
    view = recurseTree(tree)

    # Add new inline view
    r = new @ink.Result editor, [end, end], content: view, error: error

    # Adding the class here lets us apply proto repl specific styles to the display.
    r.view.classList.add 'proto-repl'


  # Makes an inline displaying result handler
  # * editor - the text editor to show the inline display in
  # * range - the range of code to display the inline result next to
  # * valueToTreeFn - a function that can convert the result value into the tree
  # of content for inline display.
  makeInlineHandler: (editor, range, valueToTreeFn)->
    (result) =>
      isError = false
      if result.value
        tree = valueToTreeFn(result.value)
      else
        tree = [result.error]
        isError = true
      @displayInline(editor, range, tree, isError)

  inlineResultHandler: (result, options)->
    # Alpha support of inline results using Atom Ink.
    if @ink && options.inlineOptions && atom.config.get('proto-repl.showInlineResults')
      io = options.inlineOptions
      handler = @makeInlineHandler io.editor, io.range, (value)->
        protoRepl.ednToDisplayTree(value)

      handler(result)

  normalResultHandler: (result, options)->
    @inlineResultHandler(result, options)

  # Executes the given code string.
  # Valid options:
  # * resultHandler - a callback function to invoke with the value that was read.
  #   If this is passed in then the value will not be displayed in the REPL.
  # * displayCode - Code to display in the REPL. This can be used when the code
  # executed is wrapped in eval or other code that shouldn't be displayed to the
  # user.
  # * displayInRepl - Boolean to indicate if the result value or error should be
  # displayed in the REPL. Defaults to true.
  executeCode: (code, options={})->
    return null unless @running()

    # If a handler is supplied use that otherwise use the default.
    resultHandler = options?.resultHandler
    handler = (result)=>
      if resultHandler
        resultHandler(result, options)
      else
        @normalResultHandler(result, options)

    if options.displayCode && atom.config.get('proto-repl.displayExecutedCodeInRepl')
      @appendText(options.displayCode)

    if options.inlineOptions?
      editor = options.inlineOptions.editor
      range = options.inlineOptions.range
      # use the id for asynchronous eval/result
      spinid = @loading.startAt(editor, range)

    @process.sendCommand code, options, (result)=>
      @loading.stop(options?.inlineOptions?.editor, spinid)
      if result.value
        unless @extensionsFeature.handleReplResult(result.value)
          handler(result)
      else
        handler(result)

  # Executes the text that was entered in the entry area
  executeEnteredText: ->
    return null unless @running()
    if editor = atom.workspace.getActiveTextEditor()
      if editor == @replTextEditor.textEditor
        code = @replTextEditor.enteredText()
        @replTextEditor.clearEnteredText()
        @replHistory.setLastTextAndAddNewEntry(code)
        # Wrap code in do block so that multiple statements entered at the REPL
        # will execute all of them
        @executeCode("(do #{code})", displayCode: code)

  exit: ->
    return null unless @running()
    @appendText("Stopping REPL")
    @process.stop()
    @process = null

  interrupt: ->
    @process.interrupt()

  clear: ->
    @replTextEditor.clear()
