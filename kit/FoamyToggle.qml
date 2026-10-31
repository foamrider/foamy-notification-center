// foamy-kit 0.4.0 8568f1884cc6624ccb4aca57dc01f0b0ddd7ed78383c4ad120f490bc88ee6543 — do not edit; change foamy-kit and run sync
import QtQuick
import qs.Commons as Commons
import qs.Ui

// The settings toggle row: a plain row, not a boxed card (DESIGN.md
// "Settings rows"): the label (normal weight) and an optional description
// on the reading start, the stock switch on the end. A soft hover/cursor fill
// shows it is one clickable row; Tab focus draws the accent ring. `divider`
// adds a hairline under the row (at most that between rows).
//
//   FoamyToggle { width: parent.width; label: FoamyI18n.t("Show … in the bar"); checked: root.showX; onClicked: root.save("showX", !checked) }
//
// API as before (the stock Toggle's): label, description, checked,
// hasCursor, rounded, foreground, accent, fontFamily, titleSize,
// descriptionSize, clicked(), hovered(bool). The row never flips `checked`
// itself; bind it and save in onClicked.
Item {
  id: root

  property string label: ""
  property string description: ""
  property bool checked: false
  property bool hasCursor: false
  property bool divider: false
  property bool rounded: FoamyStyle.rounded
  property color foreground: FoamyPalette.text
  property color accent: Commons.Color.accent
  property string fontFamily: FoamyStyle.fontFamily
  property real titleSize: FoamyStyle.font.subtitle
  property real descriptionSize: FoamyStyle.font.bodySmall
  // Kept for callers of the boxed 0.3 row; the row has no box.
  property real radius: FoamyStyle.radius
  readonly property bool hot: enabled && (hasCursor || mouse.containsMouse)
  readonly property alias switchItem: track

  signal clicked()
  signal hovered(bool isHovered)

  implicitWidth: FoamyStyle.popupWidth - FoamyStyle.padding * 2
  implicitHeight: Math.max(FoamyStyle.rowHeight + FoamyStyle.gapSmall, textColumn.implicitHeight + FoamyStyle.gap * 2)
  opacity: enabled ? 1 : FoamyStyle.disabledOpacity

  activeFocusOnTab: enabled
  Keys.onReturnPressed: root.clicked()
  Keys.onEnterPressed: root.clicked()
  Keys.onSpacePressed: root.clicked()
  Accessible.role: Accessible.CheckBox
  Accessible.name: label
  Accessible.description: description
  Accessible.checkable: true
  Accessible.checked: checked
  Accessible.onPressAction: if (root.enabled) root.clicked()
  Accessible.onToggleAction: if (root.enabled) root.clicked()

  // Hover / cursor / focus: a fill reaching a little past the text, so the
  // label stays aligned with section titles and fields.
  Rectangle {
    objectName: "foamyToggleFill"
    x: -FoamyStyle.gap
    width: parent.width + FoamyStyle.gap * 2
    height: parent.height
    radius: FoamyStyle.radius
    color: root.hot || root.activeFocus ? FoamyPalette.hoverFill : "transparent"
    border.width: root.activeFocus ? 1 : 0
    border.color: root.accent
    Behavior on color { ColorAnimation { duration: FoamyMotion.hover } }
  }

  Column {
    id: textColumn
    anchors.left: parent.left
    anchors.right: track.left
    anchors.rightMargin: FoamyStyle.gapLarge
    anchors.verticalCenter: parent.verticalCenter
    spacing: FoamyStyle.gapTiny
    Text {
      width: parent.width
      text: root.label
      textFormat: Text.PlainText
      horizontalAlignment: Text.AlignLeft
      wrapMode: Text.WordWrap
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: root.titleSize
    }
    Text {
      visible: root.description !== ""
      width: parent.width
      text: root.description
      textFormat: Text.PlainText
      horizontalAlignment: Text.AlignLeft
      wrapMode: Text.WordWrap
      color: FoamyPalette.secondaryText
      font.family: root.fontFamily
      font.pixelSize: root.descriptionSize
    }
  }

  // The row owns the click, so the switch is presentation only.
  ToggleSwitch {
    id: track
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    checked: root.checked
    rounded: root.rounded
    foreground: root.foreground
    accent: root.accent
    interactive: false
  }

  Rectangle {
    objectName: "foamyToggleDivider"
    visible: root.divider
    anchors.bottom: parent.bottom
    width: parent.width
    height: 1
    color: FoamyPalette.divider
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: root.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: if (root.enabled) root.clicked()
    onContainsMouseChanged: root.hovered(containsMouse)
  }
}
