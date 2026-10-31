// foamy-kit 0.3.4 4ebaf1a8016ef697c172fe1342ea87bad6bc83f339a103e6d5396d96a8829881 — do not edit; change foamy-kit and run sync
import QtQuick

// A free-text settings field that never fights the setting it shows: the
// text counterpart of FoamyNumberField (same draft/commit rules).
//
//   FoamyTextSettingField {
//     width: parent.width
//     label: FoamyI18n.t("Browser")
//     value: prefs.value("youtubeBrowser")                    // bind it
//     validate: function(text) { return text.length <= 64 || FoamyI18n.t("Too long") }
//     onCommitted: function(v) { prefs.save("youtubeBrowser", v) }
//   }
//
// Not editing: shows `value`, following external changes. Editing: keeps a
// draft. Enter or focus-out: commits a valid, changed draft once (trimmed
// unless `trim: false`); invalid → `validate`'s message, Enter keeps the
// draft, focus-out restores `value`. Escape restores `value` and is
// consumed (the page stays).
Item {
  id: root

  property string value: ""
  property string label: ""
  property string placeholderText: ""
  property bool trim: true
  property bool hasCursor: false
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
  // field's error line and emitted for callers with their own error area.
  signal pasteFailed(string message)
  signal committed(string value)

  implicitWidth: FoamyStyle.popupWidth - FoamyStyle.padding * 2
  implicitHeight: column.implicitHeight

  function show() {
    field.text = value            // the internal editor, never `value`
    dirty = false
  }

  // Tell the field its last commit was not saved: it shows `value` again
  // (unless a newer draft is being edited) and the same input can be
  // committed again. Wire it to the save's failure, e.g.
  // FoamyPrefsQueue.onFailed: if (key === "x") field.saveFailed()
  function saveFailed() {
    lastCommitted = ""
    hasCommitted = false
    if (!dirty) show()
  }

  function cancelEdit() {
    show()
    errorText = ""
  }

  function problem(text) {
    if (typeof validate !== "function") return ""
    var verdict = validate(text)
    return verdict === true ? "" : typeof verdict === "string" && verdict !== "" ? verdict : invalidText
  }

  function commitEdit(revertInvalid) {
    if (!dirty) return true
    var next = trim ? field.text.trim() : field.text
    var issue = problem(next)
    if (issue !== "") {
      errorText = issue
      if (revertInvalid) show()
      return revertInvalid === true
    }
    errorText = ""
    if (next !== value && !(hasCommitted && next === lastCommitted)) {
      lastCommitted = next
      hasCommitted = true
      committed(next)
    }
    dirty = false
    field.text = next
    return true
  }

  function handleKey(key) {
    if (key === Qt.Key_Escape) { cancelEdit(); return true }
    return false
  }

  onValueChanged: {
    hasCommitted = false
    if (!dirty) show()
  }
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
      placeholderText: root.placeholderText
      translate: FoamyI18n.t
      horizontalAlignment: Text.AlignLeft
      Accessible.name: root.label
      onTextEdited: { root.dirty = true; root.errorText = "" }
      onAccepted: root.commitEdit(false)
      onEditingFinished: if (!field.inputActiveFocus) root.commitEdit(true)
      onKeyPressed: function(event) { if (root.handleKey(event.key)) event.accepted = true }
    }

    Text {
      readonly property string message: root.errorText !== "" ? root.errorText : (root.field.pasteError !== "" ? FoamyI18n.t(root.field.pasteError) : "")
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
