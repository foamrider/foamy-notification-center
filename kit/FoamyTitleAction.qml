// foamy-kit 0.17.1 3cb8ef7b94c9e4c184117dc1b69e7a33bb8477b3207b8b8080768e6ca8cc4398 — do not edit; change foamy-kit and run sync
import QtQuick
import qs.Commons as Commons
import qs.Ui
import "FoamyText.js" as FoamyText

// A title that is a control: it names something the user changes (an
// editor's place) and opens its menu. A leading mark (`iconName` in
// `iconColor`; none when empty), the text and a chevron on a hover fill,
// with the keys' accent ring. A click, Enter, Return, Space or the
// accessible press emits `activated(keyboard)` (true from the keys, for
// FoamyMenu.open); disabled, nothing does. A Button named `accessibleName`
// (default: the text) for assistive technology.
//
//   FoamyTitleAction {
//     id: place
//     width: Math.min(implicitWidth, room)
//     text: root.placeLabel; iconName: "hash"; iconColor: root.placeColor
//     onActivated: function (keyboard) { menu.anchorItem = place.menuAnchor; menu.open(keyboard) }
//   }
//
// It is as wide as its content (implicitWidth); give it less and the text
// ends with "…" (the mark and the chevron stay; `minimumWidth` holds them
// and no text). A cut text shows on hover in a tooltip, wrapped, at most
// `tooltipMaxWidth` wide (Style.space(320)), with at most 3 lines of 200
// characters, cut with "…"; the accessible name keeps it all.
// `iconCenter` and `textStart` (from its start edge) line the mark and the
// text up with a column outside it (a form's icon column, its text edge);
// `fontSize` and `fontWeight` (FoamyStyle.font.title, DemiBold) set the
// text's font.
// `menuAnchor` is an item `menuWidth` wide (FoamyStyle.menuWidth, as a
// FoamyMenu) at its start: a menu anchored to it, its trailing edge on the
// anchor's, hangs under the control from its start (the right in RTL).
// Anchored children, so a mirrored layout mirrors it.
Rectangle {
  id: root

  property string text: ""
  property string iconName: ""
  property color iconColor: FoamyPalette.secondaryText
  property string accessibleName: text
  property real fontSize: FoamyStyle.font.title
  property int fontWeight: Font.DemiBold
  property real iconCenter: FoamyStyle.gap + FoamyStyle.iconSize / 2
  property real textStart: iconName !== "" ? FoamyStyle.gap + FoamyStyle.iconSize + FoamyStyle.gapSmall : FoamyStyle.gap
  property real tooltipMaxWidth: Commons.Style.space(320)
  property real menuWidth: FoamyStyle.menuWidth
  readonly property bool hovered: mouse.containsMouse
  // Everything but the text's words: its start, the chevron, the end padding.
  readonly property real minimumWidth: textStart + FoamyStyle.gapSmall + FoamyStyle.iconSize + FoamyStyle.gap
  readonly property alias menuAnchor: menuAnchor

  signal activated(bool keyboard)

  objectName: "foamyTitleAction"
  implicitWidth: minimumWidth + label.implicitWidth
  implicitHeight: FoamyStyle.actionSize
  radius: FoamyStyle.radius
  color: hovered || activeFocus ? FoamyPalette.hoverFill : "transparent"
  border.width: activeFocus ? 1 : 0
  border.color: Commons.Color.accent
  activeFocusOnTab: true

  Behavior on color {
    ColorAnimation {
      duration: FoamyMotion.hover
    }
  }

  Accessible.role: Accessible.Button
  Accessible.name: accessibleName
  Accessible.onPressAction: if (root.enabled)
    root.activated(false)
  Keys.onPressed: function (event) {
    if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      event.accepted = true
      root.activated(true)
    }
  }

  FoamyIcon {
    objectName: "foamyTitleActionMark"
    visible: root.iconName !== ""
    anchors.left: parent.left
    anchors.leftMargin: root.iconCenter - width / 2
    anchors.verticalCenter: parent.verticalCenter
    width: FoamyStyle.iconSize
    height: width
    name: root.iconName
    color: root.iconColor
  }
  Text {
    id: label
    objectName: "foamyTitleActionText"
    anchors.left: parent.left
    anchors.leftMargin: root.textStart
    anchors.verticalCenter: parent.verticalCenter
    width: Math.max(0, root.width - root.minimumWidth)
    text: root.text
    textFormat: Text.PlainText
    horizontalAlignment: Text.AlignLeft
    elide: Text.ElideRight
    color: FoamyPalette.text
    font.family: FoamyStyle.fontFamily
    font.pixelSize: root.fontSize
    font.weight: root.fontWeight
  }
  // On the end edge: after the text, and inside the box when the box is
  // narrower than minimumWidth.
  FoamyIcon {
    objectName: "foamyTitleActionChevron"
    anchors.right: parent.right
    anchors.rightMargin: FoamyStyle.gap
    anchors.verticalCenter: parent.verticalCenter
    width: FoamyStyle.iconSize
    height: width
    name: "chevron-down"
    color: FoamyPalette.secondaryText
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.activated(false)
  }

  PanelToolTip {
    id: tip
    objectName: "foamyTitleActionTip"
    visible: root.hovered && label.truncated
    // Capped through implicitWidth, which the tooltip centers itself by.
    implicitWidth: Math.min(implicitContentWidth + leftPadding + rightPadding, root.tooltipMaxWidth)
    text: FoamyText.cap(root.text, 3, 200)
    fontFamily: FoamyStyle.fontFamily
    // The host's text wraps at word boundaries only; a name typed without
    // spaces may break anywhere.
    Binding {
      target: tip.contentItem
      property: "wrapMode"
      value: Text.WrapAtWordBoundaryOrAnywhere
      when: tip.contentItem !== null
    }
  }

  Item {
    id: menuAnchor
    objectName: "foamyTitleMenuAnchor"
    anchors.left: parent.left
    anchors.top: parent.top
    width: root.menuWidth
    height: root.height
  }
}
