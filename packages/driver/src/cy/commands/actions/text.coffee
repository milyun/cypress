_ = require("lodash")
$ = require("jquery")
Promise = require("bluebird")
moment = require("moment")

{ delay, waitForAnimations } = require("./utils")
$Log = require("../../../cypress/log")
$Keyboard = require("../../../cypress/keyboard")
utils = require("../../../cypress/utils")

inputEvents = "textInput input".split(" ")
textLike = "textarea,:text,[contenteditable],[type=password],[type=email],[type=number],[type=date],[type=week],[type=month],[type=time],[type=datetime],[type=datetime-local],[type=search],[type=url],[type=tel]"
dateRegex = /^\d{4}-\d{2}-\d{2}$/
monthRegex = /^\d{4}-(0\d|1[0-2])$/
weekRegex = /^\d{4}-W(0[1-9]|[1-4]\d|5[0-3])$/
timeRegex = /^([0-1]\d|2[0-3]):[0-5]\d(:[0-5]\d)?(\.[0-9]{1,3})?$/

module.exports = (Cypress, Commands) ->
  Cypress.on "test:before:run", ->
    $Keyboard.resetModifiers(@privateState("document"), @privateState("window"))

  Commands.addAll({ prevSubject: "dom" }, {
    type: (subject, chars, options = {}) ->
      ## allow the el we're typing into to be
      ## changed by options -- used by cy.clear()
      _.defaults options,
        $el: subject
        log: true
        verify: true
        force: false
        delay: 10
        release: true

      @ensureDom(options.$el)

      if options.log
        ## figure out the options which actually change the behavior of clicks
        deltaOptions = utils.filterOutOptions(options)

        table = {}

        getRow = (id, key, which) ->
          table[id] or do ->
            table[id] = (obj = {})
            modifiers = $Keyboard.activeModifiers()
            obj.modifiers = modifiers.join(", ") if modifiers.length
            if key
              obj.typed = key
              obj.which = which if which
            obj

        updateTable = (id, key, column, which, value) ->
          row = getRow(id, key, which)
          row[column] = value or "preventedDefault"

        getTableData = ->
          ## transform table object into object with zero based index as keys
          _.reduce _.values(table), (memo, value, index) ->
            memo[index + 1] = value
            memo
          , {}

        options._log = $Log.command
          message: [chars, deltaOptions]
          $el: options.$el
          consoleProps: ->
            "Typed":      chars
            "Applied To": utils.getDomElements(options.$el)
            "Options":    deltaOptions
            "table": ->
              {
                name: "Key Events Table"
                data: getTableData()
                columns: ["typed", "which", "keydown", "keypress", "textInput", "input", "keyup", "change", "modifiers"]
              }

        options._log.snapshot("before", {next: "after"})

      isBody      = options.$el.is("body")
      isTextLike  = options.$el.is(textLike)
      isDate      = options.$el.is("[type=date]")
      isTime      = options.$el.is("[type=time]")
      isMonth     = options.$el.is("[type=month]")
      isWeek      = options.$el.is("[type=week]")
      hasTabIndex = options.$el.is("[tabindex]")

      ## TODO: tabindex can't be -1
      ## TODO: can't be readonly

      isTypeableButNotAnInput = isBody or (hasTabIndex and not isTextLike)

      if not isBody and not isTextLike and not hasTabIndex
        node = utils.stringifyElement(options.$el)
        utils.throwErrByPath("type.not_on_text_field", {
          onFail: options._log
          args: { node }
        })

      if (num = options.$el.length) and num > 1
        utils.throwErrByPath("type.multiple_elements", {
          onFail: options._log
          args: { num }
        })

      if not (_.isString(chars) or _.isFinite(chars))
        utils.throwErrByPath("type.wrong_type", {
          onFail: options._log
          args: { chars }
        })

      if _.isBlank(chars)
        utils.throwErrByPath("type.empty_string", { onFail: options._log })

      if isDate and (
        not _.isString(chars) or
        not dateRegex.test(chars) or
        not moment(chars).isValid()
      )
        utils.throwErrByPath("type.invalid_date", {
          onFail: options._log
          args: { chars }
        })

      if isMonth and (
        not _.isString(chars) or
        not monthRegex.test(chars)
      )
        utils.throwErrByPath("type.invalid_month", {
          onFail: options._log
          args: { chars }
        })

      if isWeek and (
        not _.isString(chars) or
        not weekRegex.test(chars)
      )
        utils.throwErrByPath("type.invalid_week", {
          onFail: options._log
          args: { chars }
        })

      if isTime and (
        not _.isString(chars) or
        not timeRegex.test(chars)
      )
        utils.throwErrByPath("type.invalid_time", {
          onFail: options._log
          args: { chars }
        })

      options.chars = "" + chars

      type = =>
        simulateSubmitHandler = =>
          form = options.$el.parents("form")

          return if not form.length

          multipleInputsAndNoSubmitElements = (form) ->
            inputs  = form.find("input")
            submits = form.find("input[type=submit], button[type!=button]")

            inputs.length > 1 and submits.length is 0

          ## throw an error here if there are multiple form parents

          ## bail if we have multiple inputs and no submit elements
          return if multipleInputsAndNoSubmitElements(form)

          clickedDefaultButton = (button) ->
            ## find the 'default button' as per HTML spec and click it natively
            ## do not issue mousedown / mouseup since this is supposed to be synthentic
            if button.length
              button.get(0).click()
              true
            else
              false

          getDefaultButton = (form) ->
            form.find("input[type=submit], button[type!=button]").first()

          defaultButtonisDisabled = (button) ->
            button.prop("disabled")

          defaultButton = getDefaultButton(form)

          ## bail if the default button is in a 'disabled' state
          return if defaultButtonisDisabled(defaultButton)

          ## issue the click event to the 'default button' of the form
          ## we need this to be synchronous so not going through our
          ## own click command
          ## as of now, at least in Chrome, causing the click event
          ## on the button will indeed trigger the form submit event
          ## so we dont need to fire it manually anymore!
          if not clickedDefaultButton(defaultButton)
            ## if we werent able to click the default button
            ## then synchronously fire the submit event
            ## currently this is sync but if we use a waterfall
            ## promise in the submit command it will break again
            ## consider changing type to a Promise and juggle logging
            @execute("submit", {log: false, $el: form})

        dispatchChangeEvent = (id) =>
          change = document.createEvent("HTMLEvents")
          change.initEvent("change", true, false)

          dispatched = options.$el.get(0).dispatchEvent(change)

          if id and updateTable
            updateTable.call(@, id, null, "change", null, dispatched)

          return dispatched

        ## see comment in updateValue below
        typed = ""

        $Keyboard.type({
          $el:     options.$el
          chars:   options.chars
          delay:   options.delay
          release: options.release
          window:  @privateState("window")

          updateValue: (rng, key) ->
            ## date/month/week/time inputs need to only have their value updated
            ## once after all the characters are input because attemping
            ## to set a partial/invalid value results in the value being
            ## set to an empty string
            if isDate or isMonth or isWeek or isTime
              typed += key
              if typed is options.chars
                options.$el.val(options.chars)
            else
              rng.text(key, "end")

          onBeforeType: (totalKeys) =>
            ## for the total number of keys we're about to
            ## type, ensure we raise the timeout to account
            ## for the delay being added to each keystroke
            @_timeout (totalKeys * options.delay), true

          onBeforeSpecialCharAction: (id, key) ->
            ## don't apply any special char actions such as
            ## inserting new lines on {enter} or moving the
            ## caret / range on left or right movements
            if isTypeableButNotAnInput
              return false

          onBeforeEvent: (id, key, column, which) =>
            ## if we are an element which isnt text like but we have
            ## a tabindex then it can receive keyboard events but
            ## should not fire input or textInput and should not fire
            ## change events
            if column in inputEvents and isTypeableButNotAnInput
              return false

          onEvent: (id, key, column, which, value) =>
            updateTable.apply(@, arguments) if updateTable

          ## fires only when the 'value'
          ## of input/text/contenteditable
          ## changes
          onTypeChange: =>
            ## never fire any change events for contenteditable
            return if options.$el.is("[contenteditable]")

            @state "changeEvent", ->
              dispatchChangeEvent()
              @state "changeEvent", null

          onEnterPressed: (changed, id) =>
            ## dont dispatch change events or handle
            ## submit event if we've pressed enter into
            ## a textarea or contenteditable
            return if options.$el.is("textarea,[contenteditable]")

            ## if our value has changed since our
            ## element was activated we need to
            ## fire a change event immediately
            if changed
              dispatchChangeEvent(id)

            ## handle submit event handler here
            simulateSubmitHandler()

          onNoMatchingSpecialChars: (chars, allChars) =>
            if chars is "{tab}"
              utils.throwErrByPath("type.tab", { onFail: options._log })
            else
              utils.throwErrByPath("type.invalid", {
                onFail: options._log
                args: { chars, allChars }
              })

        })

      handleFocused = =>
        ## if it's the body, don't need to worry about focus
        return type() if isBody

        @execute("focused", {log: false, verify: false}).then ($focused) =>
          ## if we dont have a focused element
          ## or if we do and its not ourselves
          ## then issue the click
          if not $focused or ($focused and $focused.get(0) isnt options.$el.get(0))
            ## click the element first to simulate focus
            ## and typical user behavior in case the window
            ## is out of focus
            @execute("click", {
              $el: options.$el
              log: false
              verify: false
              _log: options._log
              force: options.force
              timeout: options.timeout
              interval: options.interval
            }).then =>
              type()
          else
            waitForAnimations(@, options.$el, options).then(type)

      handleFocused()
      .then =>
        @_timeout(delay, true)

        Promise
          .delay(delay)
          .then =>
            ## command which consume cy.type may
            ## want to handle verification themselves
            if options.verify is false
              return options.$el

            do verifyAssertions = =>
              @verifyUpcomingAssertions(options.$el, options, {
                onRetry: verifyAssertions
              })

    clear: (subject, options = {}) ->
      ## what about other types of inputs besides just text?
      ## what about the new HTML5 ones?
      _.defaults options,
        log: true
        force: false

      @ensureDom(subject)

      ## blow up if any member of the subject
      ## isnt a textarea or :text
      clear = (el, index) =>
        $el = $(el)

        if options.log
          ## figure out the options which actually change the behavior of clicks
          deltaOptions = utils.filterOutOptions(options)

          options._log = $Log.command
            message: deltaOptions
            $el: $el
            consoleProps: ->
              "Applied To": utils.getDomElements($el)
              "Elements":   $el.length
              "Options":    deltaOptions

        node = utils.stringifyElement($el)

        if not $el.is(textLike)
          word = utils.plural(subject, "contains", "is")
          utils.throwErrByPath "clear.invalid_element", {
            onFail: options._log
            args: { word, node }
          }

        @execute("type", "{selectall}{del}", {
          $el: $el
          log: false
          verify: false ## handle verification ourselves
          _log: options._log
          force: options.force
          timeout: options.timeout
          interval: options.interval
        }).then ->
          options._log.snapshot().end() if options._log

          return null

      Promise
        .resolve(subject.toArray())
        .each(clear)
        .cancellable()
        .then =>
          do verifyAssertions = =>
            @verifyUpcomingAssertions(subject, options, {
              onRetry: verifyAssertions
            })
  })
