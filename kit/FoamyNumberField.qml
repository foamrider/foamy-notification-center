// foamy-kit 0.4.2 2927c0c2f4281cc06f6b7b3e837fe8dd97d07c3769e2c9356541891693121aa4 — do not edit; change foamy-kit and run sync
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
//
// Compact form, for short values (a 2-digit percentage, a °C margin): the
// label on the reading start, a narrow field sized to the longest value
// (`to`/`from` with `decimals`; override with `compactDigits`), the unit
// after it, all on one row; stacked compact fields line their fields and
// units up. The error line stays under the row. The row is as tall as a
// FoamyToggle row and a compact FoamyDropdown (`rowHeight + gapSmall`), so a
// list mixing them reads as one; `description` (compact only) goes under the
// label as in those rows.
//   FoamyNumberField { width: parent.width; compact: true; label: FoamyI18n.t("CPU"); unit: "%"; value: …; from: 1; to: 100; onCommitted: … }
Item {
  id: root

  property real value: 0
  property real from: 0
  property real to: 100
  property real stepSize: 1
  property int decimals: 0
  property string label: ""
  property string unit: ""
  property string description: ""
  // The unit sits in a fixed column so stacked fields line up whatever their
  // units. A unitless field among fields with units: set reserveUnit. Units
  // wider than the column ("seconds") widen it: prefer short symbols, or give
  // every field in the section the same larger unitWidth. Compact: a narrow
  // column with the unit end-aligned, so it ends on the row's trailing edge.
  property real unitWidth: compact ? FoamyStyle.unitWidthCompact : FoamyStyle.unitWidth
  property bool reserveUnit: false
  property bool hasCursor: false
  property bool compact: false
  // Characters the compact field is sized for (digits, sign, decimal mark).
  property int compactDigits: Math.max(format(Math.abs(to)).length + (to < 0 ? 1 : 0),
                                       format(Math.abs(from)).length + (from < 0 ? 1 : 0), 1)
  readonly property real compactFieldWidth: Math.ceil(digitMetrics.advanceWidth * compactDigits)
    + FoamyStyle.controlPaddingX * 2 + FoamyStyle.borderWidth * 2 + FoamyStyle.gapSmall
  property string invalidText: FoamyI18n.t("Enter a number from %1 to %2", [FoamyI18n.number(from, decimals), FoamyI18n.number(to, decimals)])
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
    if (v !== Number(Number(value).toFixed(decimals)) && !(hasCommitted && text === lastCommitted)) {
      lastCommitted = text
      hasCommitted = true
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
    lastCommitted = ""
    hasCommitted = false
  }

  // Escape and Up/Down; true when the key was handled (and must be consumed).
  function handleKey(key) {
    if (key === Qt.Key_Escape) { cancelEdit(); return true }
    if (key === Qt.Key_Up || key === Qt.Key_Down) { step(key === Qt.Key_Up ? 1 : -1); return true }
    return false
  }

  onValueChanged: {
    lastCommitted = ""
    hasCommitted = false
    if (!dirty) show()
  }
  Component.onCompleted: show()

  Column {
    id: column
    width: parent.width
    spacing: FoamyStyle.gapSmall

    TextMetrics {
      id: digitMetrics
      font: field.font
      text: "0"
    }

    Text {
      visible: root.label !== "" && !root.compact
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
      id: fieldRow
      width: parent.width
      // Compact: the settings row height (toggle rows, compact dropdowns).
      height: root.compact ? Math.max(FoamyStyle.rowHeight + FoamyStyle.gapSmall, rowText.implicitHeight + FoamyStyle.gap * 2, implicitHeight) : implicitHeight
      spacing: FoamyStyle.gap

      // Compact: the label (and description) share the row, in the settings row style.
      Column {
        id: rowText
        objectName: "foamyNumberRowText"
        visible: root.compact && (root.label !== "" || root.description !== "")
        Layout.fillWidth: true
        Layout.preferredWidth: 1
        Layout.alignment: Qt.AlignVCenter
        Layout.rightMargin: FoamyStyle.gapLarge - FoamyStyle.gap
        spacing: FoamyStyle.gapTiny
        Text {
          visible: root.label !== ""
          width: parent.width
          text: root.label
          textFormat: Text.PlainText
          horizontalAlignment: Text.AlignLeft
          wrapMode: Text.WordWrap
          color: FoamyPalette.text
          font.family: FoamyStyle.fontFamily
          font.pixelSize: FoamyStyle.font.subtitle
        }
        Text {
          visible: root.description !== ""
          width: parent.width
          text: root.description
          textFormat: Text.PlainText
          horizontalAlignment: Text.AlignLeft
          wrapMode: Text.WordWrap
          color: FoamyPalette.secondaryText
          font.family: FoamyStyle.fontFamily
          font.pixelSize: FoamyStyle.font.bodySmall
        }
      }
      Item { visible: root.compact && root.label === "" && root.description === ""; Layout.fillWidth: true }

      SafeTextField {
        id: field
        Layout.fillWidth: !root.compact
        Layout.preferredWidth: root.compact ? root.compactFieldWidth : -1
        hasCursor: root.hasCursor
        translate: FoamyI18n.t
        maximumLength: root.compact ? Math.max(root.compactDigits, 1) + 2 : 24
        horizontalAlignment: root.compact ? Text.AlignRight : Text.AlignLeft
        Accessible.name: root.label
        Accessible.description: root.description
        onTextEdited: { root.dirty = true; root.errorText = ""; root.lastCommitted = ""; root.hasCommitted = false }
        onPasteErrorChanged: if (pasteError !== "") root.pasteFailed(FoamyI18n.t(pasteError))
        onAccepted: root.commitEdit(false)
        onEditingFinished: if (!field.inputActiveFocus) root.commitEdit(true)
        onKeyPressed: function(event) { if (root.handleKey(event.key)) event.accepted = true }
      }

      Text {
        id: unitLabel
        visible: root.unit !== "" || root.reserveUnit
        text: root.unit
        textFormat: Text.PlainText
        horizontalAlignment: root.compact ? Text.AlignRight : Text.AlignLeft
        Layout.preferredWidth: Math.max(root.unitWidth, implicitWidth)
        Layout.minimumWidth: root.unitWidth
        color: FoamyPalette.secondaryText
        font.family: FoamyStyle.fontFamily
        font.pixelSize: FoamyStyle.font.bodySmall
      }
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
