// foamy-kit 0.4.2 31637cf414fddfbc7c18c7d107b4c9a77801568fd78ebb8212791fb66de476a9 — do not edit; change foamy-kit and run sync
import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The foamy action button: an icon (and optional label) on a rounded hover
// surface. One size everywhere (FoamyStyle.actionSize); the settings button
// is a FoamyAction with `settings: true`.
//
//   FoamyAction { iconName: "refresh-cw"; tooltipText: FoamyI18n.t("Refresh"); spinning: root.loading; onClicked: root.refresh() }
//
// Keyboard: in a PanelKeyCatcher panel the panel owns the cursor; set
// `hasCursor` from it and route `hoveredChanged` back so the pointer moves
// the same cursor (one highlight on screen). In a form (settings page) set
// `focusable: true` to join the Tab chain; Enter/Space activate.
//
// actionEnabled: false keeps the button visible with its tooltip but inert
// (for "nothing to do right now"); enabled: false greys it out entirely.
Rectangle {
  id: root

  property string iconName: "settings"
  property string label: ""
  property string tooltipText: ""
  property bool spinning: false
  property bool actionEnabled: true
  property bool hasCursor: false
  property bool focusable: false
  property bool settings: false
  property bool destructive: false
  property real iconSize: settings ? FoamyStyle.settingsIconSize : FoamyStyle.iconSize
  property color foreground: FoamyPalette.text
  property string fontFamily: FoamyStyle.fontFamily
  property Item keyTarget: null
  readonly property bool hovered: mouse.containsMouse
  readonly property bool active: enabled && actionEnabled

  signal clicked()

  readonly property real size: settings ? FoamyStyle.settingsButtonSize : FoamyStyle.actionSize
  implicitWidth: label ? content.implicitWidth + FoamyStyle.gapLarge * 2 : size
  implicitHeight: size
  radius: FoamyStyle.radius
  opacity: enabled ? (actionEnabled ? 1 : 0.7) : FoamyStyle.disabledOpacity
  color: active && (hasCursor || mouse.containsMouse || activeFocus)
    ? (destructive ? Qt.alpha(Commons.Color.urgent, 0.14) : FoamyPalette.hoverFill)
    : "transparent"
  border.width: activeFocus && focusable ? 1 : 0
  border.color: Commons.Color.accent
  activeFocusOnTab: focusable && active

  Behavior on color { ColorAnimation { duration: FoamyMotion.hover } }

  Accessible.role: Accessible.Button
  Accessible.name: tooltipText || label
  Accessible.onPressAction: if (root.active) root.clicked()
  Keys.onReturnPressed: if (root.active) root.clicked()
  Keys.onEnterPressed: if (root.active) root.clicked()
  Keys.onSpacePressed: if (root.active) root.clicked()
  Keys.forwardTo: keyTarget ? [keyTarget] : []

  Row {
    id: content
    anchors.centerIn: parent
    spacing: FoamyStyle.gap
    FoamyIcon {
      id: icon
      visible: root.iconName !== ""
      width: root.iconSize
      height: width
      color: root.destructive && (root.hasCursor || mouse.containsMouse) ? Commons.Color.urgent : root.foreground
      name: root.iconName
      anchors.verticalCenter: parent.verticalCenter
      // Only the glyph turns; the surface stays put. Off under reduced motion.
      RotationAnimation on rotation {
        running: root.spinning && root.visible && !FoamyMotion.reduceMotion
        from: 0
        to: 360
        duration: FoamyMotion.spin
        loops: Animation.Infinite
        onStopped: icon.rotation = 0
      }
    }
    Text {
      visible: root.label !== ""
      text: root.label
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: FoamyStyle.font.bodySmall
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: root.active ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: if (root.active) root.clicked()
  }

  PanelToolTip {
    visible: mouse.containsMouse && root.tooltipText !== ""
    text: root.tooltipText
    fontFamily: root.fontFamily
  }
}
