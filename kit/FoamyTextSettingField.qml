// foamy-kit 0.17.0 7fb174d56c0a90bc309726a6d879daf71d93f06b67972ce98e17d6b77d0d8f2a — do not edit; change foamy-kit and run sync
import QtQuick

// A free-text settings field that never fights the setting it shows: the
// text counterpart of FoamyNumberField (same draft/commit rules).
//
//   FoamyTextSettingField {
//     width: parent.width
//     label: FoamyI18n.t("Display name")
//     value: prefs.value("displayName")                       // bind it
//     validate: function(text) { return text.length <= 64 || FoamyI18n.t("Too long") }
//     onCommitted: function(v) { prefs.save("displayName", v) }
//   }
//
// Not editing: shows `value`, following external changes. Editing: keeps a
// draft. Enter or focus-out: commits a valid, changed draft once (trimmed
// unless `trim: false`); invalid → `validate`'s message, Enter keeps the
// draft, focus-out restores `value`. Hiding the field is a focus-out; shown
// again, it has no error. A destroyed field commits nothing: a page that a
// Loader unloads loses its draft. Keep a settings page loaded while it can
// show again (FoamyPopup keeps its body), or move the focus away before it
// unloads. Escape restores `value` and is consumed (the page stays).
Item {
  id: root

  property string value: ""
  property string label: ""
  property string placeholderText: ""
  property bool trim: true
  property bool hasCursor: false
  // The keys moved the cursor here (FoamyCursor.byKeys): the field's
  // border in the accent (SafeTextField.cursorByKeys).
  property bool cursorByKeys: false
  // true, or false / a message for an invalid draft.
  property var validate: null
  property string invalidText: FoamyI18n.t("That value isn't allowed.")
  property alias field: field

  readonly property bool editing: dirty
  readonly property string error: errorText
  property bool dirty: false
  property string errorText: ""
  property string lastCommitted: ""
  property bool hasCommitted: false

  // A refused paste (too large, timed out, not plain text): shown in the
  // field's error line, in place of the draft's error, and emitted for
  // callers with their own error area.
  signal pasteFailed(string message)
  signal committed(string value)

  implicitWidth: FoamyStyle.popupWidth - FoamyStyle.padding * 2
  implicitHeight: column.implicitHeight

  function show() {
    // the internal editor, never `value`
    field.text = value
    dirty = false
  }

  // Tell the field its last commit was not saved: it shows `value` again
  // (unless a newer draft is being edited) and the same input can be
  // committed again. Wire it to the save's failure, e.g.
  // FoamyPrefsQueue.onFailed: if (key === "x") field.saveFailed()
  // A call inside committed() works too (FoamyPrefsQueue reports a save it
  // refuses at once there), so it needs no Qt.callLater.
  function saveFailed() {
    lastCommitted = ""
    hasCommitted = false
    if (!dirty)
      show()
  }

  function cancelEdit() {
    show()
    errorText = ""
  }

  function problem(text) {
    if (typeof validate !== "function")
      return ""
    var verdict = validate(text)
    return verdict === true ? "" : typeof verdict === "string" && verdict !== "" ? verdict : invalidText
  }

  function commitEdit(revertInvalid) {
    if (!dirty)
      return true
    var next = trim ? field.text.trim() : field.text
    var issue = problem(next)
    if (issue !== "") {
      errorText = issue
      if (revertInvalid)
        show()
      return revertInvalid === true
    }
    errorText = ""
    var send = next !== value && !(hasCommitted && next === lastCommitted)
    if (send) {
      lastCommitted = next
      hasCommitted = true
    }
    // Settled before committed(): a saveFailed() inside it (a save that
    // FoamyPrefsQueue refuses at once) then shows `value` again.
    dirty = false
    field.text = next
    if (send)
      committed(next)
    return true
  }

  function handleKey(key) {
    if (key === Qt.Key_Escape) {
      cancelEdit()
      return true
    }
    return false
  }

  onValueChanged: {
    hasCommitted = false
    if (!dirty)
      show()
  }
  // Hiding the field ends its edit (SafeTextField drops the focus), which
  // puts an invalid draft back. Its error was about text that is gone: a
  // field shown again (a settings page opened again) starts without it.
  onVisibleChanged: if (visible)
    errorText = ""
  Component.onCompleted: show()

  Column {
    id: column
    width: parent.width
    spacing: FoamyStyle.gapSmall

    Text {
      visible: root.label !== ""
      width: parent.width
      text: root.label
      textFormat: Text.PlainText
      horizontalAlignment: Text.AlignLeft
      color: FoamyPalette.secondaryText
      font.family: FoamyStyle.fontFamily
      font.pixelSize: FoamyStyle.font.bodySmall
      font.bold: true
    }

    SafeTextField {
      id: field
      width: parent.width
      hasCursor: root.hasCursor
      cursorByKeys: root.cursorByKeys
      placeholderText: root.placeholderText
      translate: FoamyI18n.t
      horizontalAlignment: Text.AlignLeft
      Accessible.name: root.label
      onTextEdited: {
        root.dirty = true
        root.errorText = ""
      }
      // The newest news replaces the draft's error in the line (Enter with
      // the draft still invalid shows that error again).
      onPasteErrorChanged: if (pasteError !== "") {
        root.errorText = ""
        root.pasteFailed(FoamyI18n.t(pasteError))
      }
      onAccepted: root.commitEdit(false)
      onEditingFinished: if (!field.inputActiveFocus)
        root.commitEdit(true)
      onKeyPressed: function (event) {
        if (root.handleKey(event.key))
          event.accepted = true
      }
    }

    Text {
      readonly property string message: root.errorText !== "" ? root.errorText : (root.field.pasteError !== "" ? FoamyI18n.t(root.field.pasteError) : "")
      objectName: "foamyFieldError"
      visible: message !== ""
      width: parent.width
      text: message
      textFormat: Text.PlainText
      horizontalAlignment: Text.AlignLeft
      wrapMode: Text.WordWrap
      color: FoamyPalette.onSurface(FoamyPalette.error)
      font.family: FoamyStyle.fontFamily
      font.pixelSize: FoamyStyle.font.caption
      Accessible.role: Accessible.AlertMessage
      Accessible.name: message
    }
  }
}
