// foamy-kit 0.15.2 a486adf34e8569034bd7500f3cc4826b6c46195b76f7c255c61a2d18468e792d — do not edit; change foamy-kit and run sync
import QtQuick
import QtQuick.Controls as Controls
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// A single-line text field that never lets Qt read the clipboard itself.
//
// Qt's TextField reads the whole clipboard on every change, so a huge or
// hostile clipboard can stall the shell. Paste (Ctrl+V, the context menu,
// middle-click) runs clipboard.sh instead: bounded to 16 KiB, NUL-free, one
// line, 2 s deadline, and late results never overwrite newer typing.
//
//   SafeTextField {
//     width: parent.width
//     text: root.query
//     placeholderText: FoamyI18n.t("Search")
//     translate: FoamyI18n.t                 // context menu labels
//     onTextEdited: root.query = text
//     onAccepted: root.search()
//     onKeyPressed: function(event) { if (event.key === Qt.Key_Down) { list.focus(); event.accepted = true } }
//   }
//
// Styled once (foamy radius, control fill and border); callers set size and
// alignment, never background. `quiet: true` is for text edited in place
// (an editor's title that reads as text): no fill or border at rest, the
// usual field under the pointer or the cursor and with the focus. clipboardScript resolves relative to this
// file (kit/clipboard.sh by default) unless absolute. A field that hides
// gives up the focus (keys never edit hidden text), which ends the edit:
// editingFinished. If it had the keys, they go to the nearest key home that
// shows (FoamyClickAway's `foamyKeyHome`: a popup's key catcher, a settings
// page), so the panel's keys work at once; without one, to the nearest
// focus scope.
//
// Secrets (API tokens, passwords): `masked: true`, set at creation.
//
//   SafeTextField {
//     masked: true
//     placeholderText: FoamyI18n.t("API token")
//     Accessible.name: FoamyI18n.t("API token")
//     onTextEdited: root.tokenDraft = secretText
//     onAccepted: root.saveToken(secretText)
//   }
//
// Styled runs (Quick Add tokens, syntax): `runs` is an array of
// {text, color} whose texts, joined, equal `text`. The field then draws each
// run in its colour exactly over its own glyphs: the same font, each run
// placed where the editor puts its first character and on the editor's
// baseline (a Latin run next to CJK text sits where the editor draws it,
// not on its own shorter font's line), so they stay aligned while the field
// scrolls. The caret shows as usual. A run whose `color` is missing or not
// a colour Qt knows ("bogus") takes the field's colour.
//
//   SafeTextField {
//     text: root.query
//     runs: QuickAdd.runs(root.query)        // [{text: "Buy ", color: …}, {text: "#home", color: …}]
//     onTextEdited: root.query = text
//   }
//
// Plain text instead whenever the runs don't describe the text exactly
// (texts that don't join to `text`, a stale array during an edit, before
// the caller updates it), the editor lays a run out other than one piece
// (mixed directions, letters that join across runs), text is selected
// (a run cut at the selection would lose its shaping), or an input method
// is composing (its preedit shows in the editor only): `runsShown` says
// which. A masked field ignores runs.
//
// Masked contract:
// - The editor holds only the mask, one • (U+2022) per code point of the
//   value, so Qt still places the caret, selection and clicks on the dots.
//   `text` is that mask string, never the value; `secretText` is the value
//   (read-only; "" when not masked). clear() empties both.
// - Typing, Backspace/Delete, Ctrl+Backspace/Ctrl+Delete (to the start/end:
//   the mask is one word), arrows, Home/End, Shift selection, Ctrl+A, mouse
//   selection and paste (the same bounded clipboard.sh path) edit the value;
//   maximumLength counts its UTF-16 units, as in normal mode. textEdited
//   fires on every change of the value, accepted on Enter.
// - Copy, cut, undo and redo do nothing (menu entries disabled, shortcuts
//   swallowed); nothing is written to the clipboard or the primary
//   selection (the editor is read-only and selects nothing itself), nor to
//   logs. Input methods are off (read-only editor, hidden-text hints).
//   Accessibility reports a password edit whose value is the mask; the
//   field's Accessible.name is its description too (Qt hides a password
//   edit's name). Without a name, the description is the field's own
//   Accessible.description, else its placeholder, as in normal mode.
// - Only the field writes the editor: assigning `text`, or a change made by
//   an assistive tool, clears the field. Changing `masked` after creation
//   clears it too (nothing typed in one mode shows in the other).

Flickable {
  id: root

  // Match the stock UI kit while keeping native clipboard reads out of the editor.
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property string clipboardScript: "clipboard.sh"
  // Longest text the field keeps (typing and paste), like TextField.maximumLength.
  // A cut to fit never splits a surrogate pair.
  property int maximumLength: 32767
  // Password-style entry, set at creation (header: "Masked contract").
  property bool masked: false
  // The value while masked; `text` then holds only the mask.
  readonly property string secretText: masked ? mask.value : ""
  property real cornerRadius: FoamyStyle.radius
  property color selectionTint: Style.selectionFillFor(foreground, accent)
  property bool hasCursor: false
  readonly property bool _focused: editor.activeFocus
  readonly property bool _hot: editor.hovered || hasCursor
  readonly property var _borderSpec: Border.controlSpec(_focused ? "focus" : (_hot ? "hover-cursor" : "normal"), foreground, accent)
  // Quiet: text edited in place (a title that reads as text). At rest it
  // has no fill and no border; hover, the cursor or the focus show the
  // usual field. The border keeps its width, so the text never moves.
  property bool quiet: false
  readonly property bool _resting: quiet && !_focused && !_hot
  readonly property var _restingBorder: ({
      "color": "transparent",
      "widths": _borderSpec.widths,
      "gradient": {
        "colors": [],
        "angle": 0,
        "enabled": false
      }
    })
  property alias background: editor.background
  property bool editorReady: false
  // The text colour (the editor's own, unless runs are shown).
  property color color: foreground
  // Styled runs [{text, color}] (header: "Styled runs").
  property var runs: []
  // Whether the runs draw the text now (they match it, and the field is not masked).
  readonly property bool runsShown: _runPlaces.length > 0
  property alias cursorPosition: editor.cursorPosition
  property alias font: editor.font
  property alias horizontalAlignment: editor.horizontalAlignment
  // An alias, not a binding: editingFinished is emitted from the editor's
  // focus change, before a binding on activeFocus would have updated.
  readonly property alias inputActiveFocus: editor.activeFocus
  // The editor itself (tests, glyph geometry).
  readonly property Item editorItem: editor
  property alias padding: editor.padding
  property alias leftPadding: editor.leftPadding
  property int pasteCursor: 0
  property int pasteEnd: 0
  property string pasteError: ""
  property int pasteRevision: -1
  readonly property bool pasteRunning: pasteRevision >= 0 || clipboard.running
  property int pasteStart: 0
  property alias placeholderText: editor.placeholderText
  property alias placeholderTextColor: editor.placeholderTextColor
  property int revision: 0
  property alias rightPadding: editor.rightPadding
  property alias selectedTextColor: editor.selectedTextColor
  property alias selectionColor: editor.selectionColor
  property alias selectionEnd: editor.selectionEnd
  property alias selectionStart: editor.selectionStart
  property alias text: editor.text
  property var translate: function (key) {
    return key
  }

  signal keyPressed(var event)
  signal editingFinished
  signal accepted
  signal textEdited

  // The focus went into the field's own context menu: the edit goes on
  // until the menu closes without giving the focus back.
  property bool _finishAfterMenu: false

  function cancelPaste() {
    pasteRevision = -1
    clipboard.running = false
  }
  function _finishEditing() {
    cancelPaste()
    editingFinished()
  }
  // Empties the text and, when masked, the value. No textEdited: the caller
  // made the change. Setting the text also drops the editor's undo history.
  function clear() {
    // A paste still running belongs to what was cleared: its result must
    // never land (an empty field gets no text change to invalidate it).
    cancelPaste()
    revision++
    mask.value = ""
    mask.writing = true
    editor.text = ""
    mask.writing = false
  }
  function cut() {
    if (masked)
      return
    var before = editor.text
    editor.cut()
    if (editor.text !== before)
      root.textEdited()
  }

  // Late clipboard results must not overwrite typing, navigation, or a closed form.
  function finishPaste(code, output) {
    var current = enabled && visible && editor.activeFocus && pasteRevision === revision && pasteStart === editor.selectionStart && pasteEnd === editor.selectionEnd && pasteCursor === editor.cursorPosition
    pasteRevision = -1
    if (!current)
      return
    if (code !== 0) {
      pasteError = code === 124 || code === 137 ? "Clipboard paste timed out. Copy the text again." : code === 5 ? "Clipboard text is too large or contains invalid characters." : "Could not paste clipboard text. Copy plain text and try again."
      return
    }
    try {
      var value = JSON.parse(output)
      if (typeof value !== "string" || value.length > 16384)
        throw new Error("Invalid clipboard result")
      if (masked) {
        replaceMasked(pasteStart, pasteEnd, value)
        return
      }
      if (value === "" && pasteStart === pasteEnd)
        return
      // Keep maximumLength (TextInput's 32767 by default), including repeated pastes.
      value = value.slice(0, _cutAt(value, Math.max(0, root.maximumLength - editor.length + pasteEnd - pasteStart)))
      if (value === "" && pasteStart === pasteEnd)
        return
      // These fields are not file-backed. Reset the document's modified
      // marker at each boundary to prevent Qt from merging adjacent typing
      // or pastes, while retaining its native undo stack.
      editor.textDocument.modified = false
      editor.cursorSelection.text = value
      editor.cursorPosition = pasteStart + value.length
      editor.textDocument.modified = false
      root.textEdited()
    } catch (error) {
      pasteError = "Could not paste clipboard text. Copy plain text and try again."
    }
  }
  function focusInput() {
    editor.forceActiveFocus()
  }
  // Whether a typed key would pass maximumLength, as
  // QInputControl::isAcceptableInput reads it: Ctrl and Ctrl+Shift
  // combinations are shortcuts, control characters never type.
  function _overflows(event) {
    var text = event.text
    var modifiers = event.modifiers & ~Qt.KeypadModifier
    if (text === "" || modifiers === Qt.ControlModifier || modifiers === (Qt.ControlModifier | Qt.ShiftModifier))
      return false
    for (let i = 0; i < text.length; i++) {
      let code = text.charCodeAt(i)
      if (code < 0x20 || (code >= 0x7f && code < 0xa0))
        return false
    }
    var limit = maximumLength > 32767 ? 32767 : (maximumLength > 0 ? maximumLength : 0)
    return editor.length - (editor.selectionEnd - editor.selectionStart) + text.length > limit
  }
  // Where to cut `text` so it keeps at most `limit` UTF-16 units without
  // splitting a surrogate pair. No JS globals (see onMaximumLengthChanged).
  function _cutAt(text, limit) {
    if (limit >= text.length)
      return text.length
    if (limit <= 0)
      return 0
    var code = text.charCodeAt(limit - 1)
    return code >= 0xd800 && code < 0xdc00 ? limit - 1 : limit
  }
  // The masked value split into code points (a surrogate pair stays whole),
  // one per mask glyph. No JS globals (see onMaximumLengthChanged).
  function maskPoints(value) {
    var points = []
    for (let i = 0; i < value.length; i++) {
      let code = value.charCodeAt(i)
      let low = i + 1 < value.length ? value.charCodeAt(i + 1) : 0
      let pair = code >= 0xd800 && code < 0xdc00 && low >= 0xdc00 && low < 0xe000
      points.push(value.substr(i, pair ? 2 : 1))
      if (pair)
        i++
    }
    return points
  }
  // Replaces mask positions [start, end) of the masked value with `value`,
  // within maximumLength, and puts the caret after it. Returns whether the
  // value changed (textEdited then fires once).
  function replaceMasked(start, end, value) {
    var points = maskPoints(mask.value)
    var from = Math.max(0, Math.min(start, end, points.length))
    var to = Math.min(points.length, Math.max(start, end))
    var before = points.slice(0, from).join("")
    var after = points.slice(to).join("")
    var room = Math.min(32767, Math.max(0, maximumLength)) - before.length - after.length
    var added = []
    var units = 0
    var incoming = maskPoints(value)
    for (let i = 0; i < incoming.length && units + incoming[i].length <= room; i++) {
      added.push(incoming[i])
      units += incoming[i].length
    }
    if (added.length === 0 && from === to)
      return false
    mask.value = before + added.join("") + after
    mask.writing = true
    editor.remove(from, to)
    editor.insert(from, "•".repeat(added.length))
    mask.writing = false
    editor.cursorPosition = from + added.length
    root.textEdited()
    return true
  }
  // Keys in masked mode, as the native editor treats them in normal mode.
  // Returns whether the field takes `event`; with `apply`, also acts on it.
  // Everything else (Up/Down, Escape…) is left to the caller's panel.
  function maskedKey(event, apply) {
    // Never expose or move the value: copy, cut, undo and redo do nothing.
    if (event.matches(StandardKey.Copy) || event.matches(StandardKey.Cut) || event.matches(StandardKey.Undo) || event.matches(StandardKey.Redo))
      return true
    var start = editor.selectionStart
    var end = editor.selectionEnd
    var position = editor.cursorPosition
    var anchor = position === start ? end : start
    var length = editor.length
    // Arrows move visually: the mask has no direction of its own, so it runs
    // in the input method's direction.
    var reversed = length > 0 && editor.positionToRectangle(1).x < editor.positionToRectangle(0).x
    var target = -1
    var extend = false
    if (event.matches(StandardKey.SelectAll)) {
      if (apply)
        editor.selectAll()
      return true
    } else if (event.matches(StandardKey.MoveToPreviousChar) || event.matches(StandardKey.MoveToNextChar)) {
      let forward = event.matches(StandardKey.MoveToNextChar) !== reversed
      target = start !== end ? (forward ? end : start) : Math.max(0, Math.min(length, position + (forward ? 1 : -1)))
    } else if (event.matches(StandardKey.SelectPreviousChar) || event.matches(StandardKey.SelectNextChar)) {
      target = Math.max(0, Math.min(length, position + ((event.matches(StandardKey.SelectNextChar) !== reversed) ? 1 : -1)))
      extend = true
    } else if (event.matches(StandardKey.MoveToPreviousWord) || event.matches(StandardKey.MoveToNextWord)) {
      target = (event.matches(StandardKey.MoveToNextWord) !== reversed) ? length : 0
    } else if (event.matches(StandardKey.SelectPreviousWord) || event.matches(StandardKey.SelectNextWord)) {
      target = (event.matches(StandardKey.SelectNextWord) !== reversed) ? length : 0
      extend = true
    } else if (event.matches(StandardKey.MoveToStartOfLine) || event.matches(StandardKey.MoveToStartOfBlock) || event.matches(StandardKey.MoveToStartOfDocument)) {
      target = 0
    } else if (event.matches(StandardKey.MoveToEndOfLine) || event.matches(StandardKey.MoveToEndOfBlock) || event.matches(StandardKey.MoveToEndOfDocument)) {
      target = length
    } else if (event.matches(StandardKey.SelectStartOfLine) || event.matches(StandardKey.SelectStartOfBlock) || event.matches(StandardKey.SelectStartOfDocument)) {
      target = 0
      extend = true
    } else if (event.matches(StandardKey.SelectEndOfLine) || event.matches(StandardKey.SelectEndOfBlock) || event.matches(StandardKey.SelectEndOfDocument)) {
      target = length
      extend = true
    }
    if (target >= 0) {
      if (apply)
        editor.select(extend ? anchor : target, target)
      return true
    }
    var from = -1
    var to = -1
    if (event.key === Qt.Key_Backspace && !(event.modifiers & ~(Qt.ShiftModifier | Qt.KeypadModifier))) {
      from = start !== end ? start : Math.max(0, position - 1)
      to = start !== end ? end : position
    } else if (event.matches(StandardKey.Delete)) {
      from = start !== end ? start : position
      to = start !== end ? end : Math.min(length, position + 1)
    } else if (event.matches(StandardKey.DeleteStartOfWord)) {
      from = start !== end ? start : 0
      to = start !== end ? end : position
    } else if (event.matches(StandardKey.DeleteEndOfWord)) {
      from = start !== end ? start : position
      to = start !== end ? end : length
    }
    if (from >= 0) {
      if (apply)
        replaceMasked(from, to, "")
      return true
    }
    // Printable text, as QInputControl::isAcceptableInput: Ctrl and
    // Ctrl+Shift combinations are shortcuts, control characters never type.
    var text = event.text
    var modifiers = event.modifiers & ~Qt.KeypadModifier
    if (text === "" || modifiers === Qt.ControlModifier || modifiers === (Qt.ControlModifier | Qt.ShiftModifier))
      return false
    for (let i = 0; i < text.length; i++) {
      let code = text.charCodeAt(i)
      if (code < 0x20 || (code >= 0x7f && code < 0xa0))
        return false
    }
    if (apply)
      replaceMasked(start, end, text)
    return true
  }
  function redo() {
    if (masked)
      return
    // Programmatic TextEdit actions do not emit textEdited; menu edits must.
    var before = editor.text
    editor.redo()
    if (editor.text !== before)
      root.textEdited()
  }
  function requestPaste(primary) {
    if (!enabled || !visible || pasteRunning)
      return
    pasteError = ""
    pasteRevision = revision
    pasteStart = editor.selectionStart
    pasteEnd = editor.selectionEnd
    pasteCursor = editor.cursorPosition
    clipboard.command = ["bash", decodeURIComponent(Qt.resolvedUrl(clipboardScript).toString().replace(/^file:\/\//, "")), primary ? "primary" : "clipboard"]
    clipboard.running = true
  }
  function select(start, end) {
    editor.select(start, end)
  }
  function selectAll() {
    editor.selectAll()
  }
  function undo() {
    if (masked)
      return
    var before = editor.text
    editor.undo()
    if (editor.text !== before)
      root.textEdited()
  }

  // The runs, checked against the text: {text, runs: [{start, end,
  // color}]} with the empty runs dropped, or null when they don't join to
  // exactly `text`. `text` is the text they were checked against.
  readonly property var _runModel: {
    var text = editor.text
    var list = root.runs
    if (root.masked || text === "" || !Array.isArray(list) || list.length === 0 || list.length > text.length)
      return null
    var model = []
    var at = 0
    for (let i = 0; i < list.length; i++) {
      let run = list[i]
      if (!run || typeof run.text !== "string")
        return null
      if (run.text === "")
        continue
      if (text.substr(at, run.text.length) !== run.text)
        return null
      model.push({
        start: at,
        end: at + run.text.length,
        color: _runColor(run.color)
      })
      at += run.text.length
    }
    return at === text.length ? {
      text: text,
      runs: model
    } : null
  }
  // A run's colour: a color value, or a string Qt reads as one; anything
  // else (missing, "", "bogus") is the field's colour.
  function _runColor(color) {
    if (typeof color === "object" && color !== null && "r" in color)
      return color
    if (typeof color !== "string" || color === "")
      return root.color
    try {
      return Qt.color(color)
    } catch (error) {
      // Qt.color() throws on a name it doesn't know: not a caller error to
      // report per keystroke, the documented fallback applies.
      return root.color
    }
  }
  // Where the editor lays its text out: positionToRectangle() notifies
  // nothing, so _runPlaces reads this to run again when any of it changes.
  readonly property var _runLayout: [editor.width, editor.height, editor.contentWidth, editor.font, editor.leftPadding, editor.rightPadding, editor.effectiveHorizontalAlignment, editor.cursorRectangle, editor.renderType, editor.baselineOffset]
  // Where each run sits in the run layer: [{text, x, baseline, color,
  // font, renderType}], `baseline` being the editor's (see runsLayer). []
  // while text is selected, while an input method composes (the preedit is
  // laid out inside the editor's text, so the runs would hide it), and
  // when the editor lays any run out other than as one piece of its own
  // width.
  readonly property var _runPlaces: {
    var model = _runModel
    if (!model || !editorReady || editor.selectionStart !== editor.selectionEnd)
      return []
    if (editor.inputMethodComposing || editor.preeditText !== "")
      return []
    // During an edit this can run before _runModel has seen the new text:
    // a stale model may reach past the end, and the editor must never be
    // asked for a position there.
    var text = editor.text
    if (model.text !== text || text.length !== editor.length)
      return []
    var layout = _runLayout
    var origin = root.contentX + editor.leftPadding
    var places = []
    for (let i = 0; i < model.runs.length; i++) {
      let run = model.runs[i]
      let a = editor.positionToRectangle(run.start)
      let b = editor.positionToRectangle(run.end)
      let piece = text.substring(run.start, run.end)
      if (Math.abs(Math.abs(b.x - a.x) - runMetrics.advanceWidth(piece)) > 1)
        return []
      places.push({
        text: piece,
        x: Math.min(a.x, b.x) - origin,
        baseline: layout[9],
        color: run.color,
        font: layout[3],
        renderType: layout[8]
      })
    }
    return places
  }
  // Expose the native editable control, with the caller's field label.
  Accessible.ignored: true
  boundsBehavior: Flickable.StopAtBounds
  clip: true
  contentHeight: height
  contentWidth: Math.max(width, editor.contentWidth + editor.leftPadding + editor.rightPadding)
  flickableDirection: Flickable.HorizontalFlick
  implicitHeight: FoamyStyle.controlHeight
  // Explicit, so it follows LayoutMirroring: right-aligned in RTL panels
  // (an implicit alignment only follows the text's own direction).
  horizontalAlignment: TextEdit.AlignLeft
  font.family: FoamyStyle.fontFamily
  font.pixelSize: FoamyStyle.font.body
  selectionColor: selectionTint
  selectedTextColor: foreground
  // A hint: the palette's muted text, readable as a placeholder in light
  // and dark themes alike.
  placeholderTextColor: FoamyPalette.mutedText
  leftPadding: Style.spacing.controlPaddingX + Border.left(_borderSpec)
  rightPadding: Style.spacing.controlPaddingX + Border.right(_borderSpec)
  background: BorderSurface {
    color: root._resting ? "transparent" : Style.controlFill(root._focused, root._hot, root.foreground, root.accent)
    borderSpec: root._resting ? root._restingBorder : root._borderSpec
    radius: root.cornerRadius
  }

  // TextArea checks clipboard formats only. TextField reads the entire clipboard
  // even on dataChanged, so intercepting its paste shortcut is not sufficient.
  Controls.TextArea.flickable: Controls.TextArea {
    id: editor
    objectName: "safeEditor"

    // The editor is the tab stop: it carries the field's name, description
    // and role. Qt reports no name for a password edit (Qt 6.12), so a
    // masked editor gives the name as its description, which Qt keeps; drop
    // that when Qt reports the name of a password edit. Setting the
    // description stops Qt from showing the placeholder as the description,
    // so the placeholder is the fallback here.
    Accessible.name: root.Accessible.name
    Accessible.description: root.masked && root.Accessible.name !== "" ? root.Accessible.name : (root.Accessible.description !== "" ? root.Accessible.description : root.placeholderText)
    Accessible.role: Accessible.EditableText
    Accessible.passwordEdit: root.masked
    activeFocusOnTab: true
    persistentSelection: true
    // Masked: Qt neither edits nor selects (its selections fill the primary
    // selection); the field does both, and the editor holds only the mask.
    readOnly: root.masked
    selectByMouse: !root.masked
    inputMethodHints: root.masked ? Qt.ImhHiddenText | Qt.ImhSensitiveData | Qt.ImhNoPredictiveText | Qt.ImhNoAutoUppercase : Qt.ImhNone
    textFormat: TextEdit.PlainText
    // Runs draw the text over a transparent editor.
    color: root.runsShown ? "transparent" : root.color
    // Attached TextArea margins otherwise shift centered single-line glyphs.
    topPadding: 0
    bottomPadding: 0
    verticalAlignment: TextEdit.AlignVCenter
    wrapMode: TextEdit.NoWrap

    // Use our own menu so no menu action calls native paste or reads canPaste.
    Controls.ContextMenu.menu: Controls.Menu {
      id: editMenu

      objectName: "clipboardMenu"

      onClosed: if (root._finishAfterMenu) {
        root._finishAfterMenu = false
        if (!editor.activeFocus)
          root._finishEditing()
      }

      Controls.MenuItem {
        enabled: !root.masked && editor.canUndo
        text: root.translate("Undo")

        onTriggered: root.undo()
      }
      Controls.MenuItem {
        enabled: !root.masked && editor.canRedo
        text: root.translate("Redo")

        onTriggered: root.redo()
      }
      Controls.MenuSeparator {}
      Controls.MenuItem {
        enabled: !root.masked && editor.selectedText !== ""
        text: root.translate("Cut")

        onTriggered: root.cut()
      }
      Controls.MenuItem {
        enabled: !root.masked && editor.selectedText !== ""
        text: root.translate("Copy")

        onTriggered: if (!root.masked)
          editor.copy()
      }
      Controls.MenuItem {
        enabled: !root.pasteRunning
        text: root.translate("Paste")

        onTriggered: {
          editMenu.close()
          // A hidden field takes no keys, also from a menu still closing.
          if (root.visible)
            root.focusInput()
          root.requestPaste(false)
        }
      }
      Controls.MenuItem {
        text: root.translate("Select all")

        onTriggered: editor.selectAll()
      }
    }

    Keys.onPressed: function (event) {
      // Callers retain search navigation and Escape without native paste.
      event.accepted = false
      root.keyPressed(event)
      if (event.accepted)
        return
      if (event.matches(StandardKey.Paste)) {
        event.accepted = true
        root.requestPaste(false)
      } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        event.accepted = true
        root.accepted()
        root.editingFinished()
      } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
        event.accepted = true
        var backwards = event.key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier)
        nextItemInFocusChain(!backwards).forceActiveFocus(Qt.TabFocusReason)
      } else if (root.masked && root.maskedKey(event, true)) {
        event.accepted = true
      } else if (!root.masked && root._overflows(event)) {
        // At maximumLength: drop the key rather than cut the text's end.
        event.accepted = true
      }
    }
    // A read-only editor claims no shortcuts; masked mode claims the keys
    // it handles, as the native editor does in normal mode.
    Keys.onShortcutOverride: function (event) {
      if (root.masked && root.maskedKey(event, false))
        event.accepted = true
    }
    // Opening the context menu moves the focus into it. That is not the end
    // of the edit: the caller must not save or hide the field then (the
    // menu's Paste needs it shown); editingFinished waits for the menu.
    onActiveFocusChanged: if (activeFocus)
      root._finishAfterMenu = false
    else if (editMenu.visible)
      root._finishAfterMenu = true
    else
      root._finishEditing()
    onCursorPositionChanged: caret.wake()
    onCursorRectangleChanged: {
      // Initial layout can fire before the QML JavaScript context is ready.
      if (!root.editorReady)
        return
      var left = cursorRectangle.x
      var right = left + cursorRectangle.width + rightPadding
      if (left < root.contentX)
        root.contentX = Math.max(0, left)
      else if (right > root.contentX + root.width)
        root.contentX = Math.min(root.contentWidth - root.width, right - root.width)
    }
    onTextChanged: {
      // Masked, only the field writes the mask; any other write (a caller's
      // `text`, an assistive tool) may hold a value in clear, so it clears.
      if (root.masked && !mask.writing && root.editorReady)
        root.clear()
      var wanted = root.maximumLength
      var limit = wanted > 32767 ? 32767 : (wanted > 0 ? wanted : 0)
      if (length > limit)
        remove(root._cutAt(text, limit), length)
      root.revision++
      root.pasteError = ""
    }
    onTextEdited: root.textEdited()

    // The styled runs, each over its own glyphs (see _runPlaces). Clipped
    // where the editor clips its own text: the field's view inside the
    // paddings. Each run's baseline is the editor's: the editor's line is
    // as tall as its tallest font (CJK fallback), and a run in a shorter
    // font placed at the line's top would sit above the editor's glyphs.
    Item {
      id: runsLayer
      objectName: "runsLayer"
      visible: root.runsShown
      clip: true
      x: root.contentX + editor.leftPadding
      width: Math.max(0, root.width - editor.leftPadding - editor.rightPadding)
      height: editor.height

      Repeater {
        model: root._runPlaces

        Text {
          id: runText

          required property var modelData

          x: modelData.x
          y: modelData.baseline - runText.baselineOffset
          text: modelData.text
          textFormat: Text.PlainText
          color: modelData.color
          font: modelData.font
          renderType: modelData.renderType
        }
      }
    }
    FontMetrics {
      id: runMetrics
      font: editor.font
    }

    // A read-only editor draws no caret, nor does a transparent one (runs):
    // the field draws one on Qt's cursor rectangle, blinking at the
    // platform's flash time.
    Rectangle {
      id: caret

      property bool lit: true

      function wake() {
        lit = true
        if (blink.running)
          blink.restart()
      }

      objectName: "maskedCaret"
      visible: (root.masked || root.runsShown) && editor.activeFocus && lit
      x: editor.cursorRectangle.x
      y: editor.cursorRectangle.y
      width: Math.max(1, editor.cursorRectangle.width)
      height: editor.cursorRectangle.height
      color: root.color

      Timer {
        id: blink

        interval: Application.styleHints.cursorFlashTime / 2
        repeat: true
        // Only while the field shows in an active window: a hidden popup can
        // keep the editor's activeFocus, and must not wake the shell.
        running: (root.masked || root.runsShown) && editor.activeFocus && root.visible && root.Window.active && Application.styleHints.cursorFlashTime >= 2

        onRunningChanged: caret.lit = true
        onTriggered: caret.lit = !caret.lit
      }
    }

    // Masked selection by mouse: Qt's own would fill the primary selection.
    MouseArea {
      id: maskedMouse

      property int anchor: 0

      objectName: "maskedMouse"
      enabled: root.masked
      acceptedButtons: Qt.LeftButton
      anchors.fill: parent
      cursorShape: Qt.IBeamCursor
      preventStealing: true

      onDoubleClicked: editor.selectAll()
      onPositionChanged: function (mouse) {
        editor.select(anchor, editor.positionAt(mouse.x, mouse.y))
      }
      onPressed: function (mouse) {
        editor.forceActiveFocus()
        var position = editor.positionAt(mouse.x, mouse.y)
        var start = editor.selectionStart
        anchor = (mouse.modifiers & Qt.ShiftModifier) ? (editor.cursorPosition === start ? editor.selectionEnd : start) : position
        editor.select(anchor, position)
      }
    }

    // Keep left-button selection native; consume primary-selection paste.
    MouseArea {
      acceptedButtons: Qt.MiddleButton
      anchors.fill: parent

      onClicked: root.requestPaste(true)
      onPressed: function (mouse) {
        editor.forceActiveFocus()
        editor.cursorPosition = editor.positionAt(mouse.x, mouse.y)
      }
    }
  }

  // Keep the horizontal scroll inside the text. The attached TextArea
  // resizes contentWidth to the text's own width (overriding the binding
  // above), and a field given an explicit `width:` (a Column child) then
  // ended up scrolled to contentX = -leftPadding: the text sat one padding
  // too far in. Clamp whenever the geometry or the scroll changes.
  function clampScroll() {
    if (!editorReady)
      return
    var max = contentWidth > width ? contentWidth - width : 0
    if (contentX < 0)
      contentX = 0
    else if (contentX > max)
      contentX = max
  }
  onWidthChanged: clampScroll()
  onContentWidthChanged: clampScroll()
  onContentXChanged: clampScroll()
  Component.onCompleted: {
    editorReady = true
    // A `text` given at creation never becomes the masked value or shows.
    if (masked && editor.text !== "")
      clear()
    // A maximumLength lowered while the page is created, after the editor
    // took its text and before this runs (Qt completes in reverse creation
    // order: a root's or a later sibling's Component.onCompleted comes
    // first), was not applied: onMaximumLengthChanged waits for editorReady.
    var limit = maximumLength > 32767 ? 32767 : (maximumLength > 0 ? maximumLength : 0)
    if (editor.length > limit)
      editor.remove(_cutAt(editor.text, limit), editor.length)
    clampScroll()
  }
  // Nothing typed in one mode shows in the other.
  onMaskedChanged: if (editorReady)
    clear()
  // Runs when maximumLength changes after creation only, and uses no JS
  // globals: this can fire while a page is being built or torn down (a
  // settings state switch), when the global object may already be gone.
  onMaximumLengthChanged: {
    if (!editorReady)
      return
    var limit = maximumLength > 0 ? maximumLength : 0
    if (masked) {
      // Drop whole code points from the end until the value fits.
      let points = maskPoints(mask.value)
      let units = mask.value.length
      let keep = points.length
      while (units > limit)
        units -= points[--keep].length
      if (keep < points.length) {
        mask.value = points.slice(0, keep).join("")
        mask.writing = true
        editor.remove(keep, editor.length)
        mask.writing = false
      }
      return
    }
    if (editor.length > limit)
      editor.remove(_cutAt(editor.text, limit), editor.length)
  }
  Component.onDestruction: cancelPaste()
  onActiveFocusChanged: if (activeFocus)
    editor.forceActiveFocus()
  onEnabledChanged: if (!enabled)
    cancelPaste()
  onVisibleChanged: if (!visible) {
    cancelPaste()
    pasteError = ""
    // Qt keeps the active focus on a hidden item, so keys would still edit
    // text the user cannot see. Losing it ends the edit (editingFinished).
    // An open menu would give the focus back on Esc or Paste: close it first.
    var hadKeys = editor.activeFocus || editMenu.visible
    editMenu.close()
    editor.focus = false
    // The keys go where a click-away gives them, so the panel's keys (Esc,
    // arrows) work at once; without a key home they stay with the nearest
    // focus scope.
    var home = hadKeys ? _keyHome(root.parent) : null
    if (home)
      home.forceActiveFocus()
  }
  // The nearest `foamyKeyHome` above the field that shows (FoamyClickAway's
  // key home), or null. A hidden one, such as a settings page that hides
  // with the field, passes the search on.
  function _keyHome(item) {
    for (let at = item; at; at = at.parent) {
      if ("foamyKeyHome" in at && at.foamyKeyHome && at.foamyKeyHome.visible)
        return at.foamyKeyHome
    }
    return null
  }

  // Private: the masked value, and whether the field itself is writing the mask.
  QtObject {
    id: mask

    property string value: ""
    property bool writing: false
  }

  Process {
    id: clipboard

    stdout: StdioCollector {
      id: clipboardOutput
    }

    onExited: function (code) {
      root.finishPaste(code, clipboardOutput.text)
    }
    onRunningChanged: if (!running && root.pasteRevision >= 0)
      root.finishPaste(-1, "")
  }
}
