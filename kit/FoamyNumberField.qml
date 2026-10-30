// foamy-kit 0.3.2 8657afad22d51e807ca0f400f8f1ba8abede910dd4c97f73432474f4c2e736c0 — do not edit; change foamy-kit and run sync
import QtQuick
import QtQuick.Layouts

// A numeric settings field that never fights the setting it shows.
//
//   FoamyNumberField {
//     width: parent.width
//     label: FoamyI18n.t("Refresh every")
//     unit: FoamyI18n.t("seconds")
//     value: prefs.value("refreshSeconds")        // bind it; the field never assigns it
//     from: 30; to: 3600; stepSize: 30
//     onCommitted: function(v) { prefs.save("refreshSeconds", v) }
//   }
//
// - Not editing: shows `value` (formatted with FoamyI18n.number), following
//   every change (another monitor's popup, the CLI).
// - Editing (focused and typed, or stepped): keeps a draft; changes to
//   `value` meanwhile don't overwrite what you type.
// - Enter or focus-out: commits only a valid, changed number (emits
//   committed(v) once); an unchanged draft just goes back to showing `value`.
//   An invalid draft shows `invalidText`; Enter keeps the draft to fix,
//   focus-out restores `value`.
// - Escape: restores `value` and stays on the page (the key is consumed, so
//   FoamySettingsPage doesn't go back). Up/Down step the
//   draft by stepSize within from..to.
// - Accepts the language's digits and decimal mark (Danish "2,5", Arabic
//   "٤٢"). RTL mirrors the row; set hasCursor from the panel's FoamyCursor.
Item {
  id: root

  property real value: 0
  property real from: 0
  property real to: 100
  property real stepSize: 1
  property int decimals: 0
  property string label: ""
  property string unit: ""
  property bool hasCursor: false
  property string invalidText: FoamyI18n.t("Enter a number from %1 to %2", [FoamyI18n.number(from, decimals), FoamyI18n.number(to, decimals)])
  property alias field: field

  readonly property bool editing: dirty
  readonly property string error: errorText
  property bool dirty: false
  property string errorText: ""
  property string lastCommitted: ""

  signal committed(real value)

  implicitWidth: FoamyStyle.popupWidth - FoamyStyle.padding * 2
  implicitHeight: column.implicitHeight

  function format(v) { return FoamyI18n.number(v, decimals) }

  // Western digits, "." decimal: from the language's digits and marks.
  function normalize(text) {
    var out = ""
    var s = String(text).trim()
    for (var i = 0; i < s.length; i++) {
      var code = s.charCodeAt(i)
      if (code >= 0x0660 && code <= 0x0669) out += String(code - 0x0660)
      else if (code >= 0x06F0 && code <= 0x06F9) out += String(code - 0x06F0)
      else if (s[i] === "," || s[i] === "٫") out += "."
      else if (s[i] === "−") out += "-"
      else out += s[i]
    }
    return out
  }

  // The number in `text`, or NaN when it isn't a valid value for this field.
  function parse(text) {
    var s = normalize(text)
    if (!/^-?\d+(\.\d+)?$/.test(s)) return NaN
    var v = Number(s)
    if (decimals === 0 && Math.floor(v) !== v) return NaN
    if (v < from || v > to) return NaN
    return Number(v.toFixed(decimals))
  }

  function show() {
    field.text = format(value)   // the internal editor, never `value`
    dirty = false
  }

  function cancelEdit() {
    show()
    errorText = ""
  }

  // Returns true when the draft is settled (committed, unchanged or reverted).
  function commitEdit(revertInvalid) {
    if (!dirty) return true
    var v = parse(field.text)
    if (isNaN(v)) {
      errorText = invalidText
      if (revertInvalid) show()
      return revertInvalid === true
    }
    errorText = ""
    var text = format(v)
    if (v !== Number(Number(value).toFixed(decimals)) && text !== lastCommitted) {
      lastCommitted = text
      committed(v)
    }
    dirty = false
    field.text = text            // shows the commit until `value` catches up
    return true
  }

  function step(direction) {
    var current = parse(field.text)
    if (isNaN(current)) current = value
    var next = Math.min(to, Math.max(from, current + direction * stepSize))
    field.text = format(next)
    dirty = true
    errorText = ""
  }

  // Escape and Up/Down; true when the key was handled (and must be consumed).
  function handleKey(key) {
    if (key === Qt.Key_Escape) { cancelEdit(); return true }
    if (key === Qt.Key_Up || key === Qt.Key_Down) { step(key === Qt.Key_Up ? 1 : -1); return true }
    return false
  }

  onValueChanged: {
    lastCommitted = ""
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

    RowLayout {
      width: parent.width
      spacing: FoamyStyle.gap

      SafeTextField {
        id: field
        Layout.fillWidth: true
        hasCursor: root.hasCursor
        translate: FoamyI18n.t
        maximumLength: 24
        horizontalAlignment: Text.AlignLeft
        Accessible.name: root.label
        onTextEdited: { root.dirty = true; root.errorText = "" }
        onAccepted: root.commitEdit(false)
        onEditingFinished: if (!field.inputActiveFocus) root.commitEdit(true)
        onKeyPressed: function(event) { if (root.handleKey(event.key)) event.accepted = true }
      }

      Text {
        visible: root.unit !== ""
        text: root.unit
        textFormat: Text.PlainText
        color: FoamyPalette.secondaryText
        font.family: FoamyStyle.fontFamily
        font.pixelSize: FoamyStyle.font.bodySmall
      }
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
