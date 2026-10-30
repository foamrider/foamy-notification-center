// foamy-kit 0.3.2 c959bcc318627747dc9e5d7f148e48403516c36c17556e9ae3a63f12daf651b5 — do not edit; change foamy-kit and run sync
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

  signal committed(string value)

  implicitWidth: FoamyStyle.popupWidth - FoamyStyle.padding * 2
  implicitHeight: column.implicitHeight

  function show() {
    field.text = value            // the internal editor, never `value`
    dirty = false
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
      visible: root.errorText !== ""
      width: parent.width
      text: root.errorText
      textFormat: Text.PlainText
      horizontalAlignment: Text.AlignLeft
      wrapMode: Text.WordWrap
      color: FoamyPalette.onSurface(FoamyPalette.error)
      font.family: FoamyStyle.fontFamily
      font.pixelSize: FoamyStyle.font.caption
      Accessible.role: Accessible.AlertMessage
      Accessible.name: root.errorText
    }
  }
}
