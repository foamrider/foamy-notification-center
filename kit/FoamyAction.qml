// foamy-kit 0.15.2 d7f1aa2f6b43aa170f5792de7e7648cdf75b7f8adf654e96d10558769bed6a43 — do not edit; change foamy-kit and run sync
import QtQuick
import qs.Commons as Commons
import qs.Ui
import "FoamyText.js" as FoamyText

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
//
// The tooltip is at most Style.space(320) wide and shows at most 3 lines of
// 200 characters of tooltipText, cut with "…"; Accessible.name keeps it all.
Rectangle {
  id: root

  property string iconName: "settings"
  property string label: ""
  property string tooltipText: ""
  property bool spinning: false
  property bool actionEnabled: true
  property bool hasCursor: false
  // The keys moved the cursor here (FoamyCursor.byKeys): an accent border.
  property bool cursorByKeys: false
  property bool focusable: false
  property bool settings: false
  property bool destructive: false
  property real iconSize: settings ? FoamyStyle.settingsIconSize : FoamyStyle.iconSize
  property color foreground: FoamyPalette.text
  property string fontFamily: FoamyStyle.fontFamily
  property Item keyTarget: null
  readonly property bool hovered: mouse.containsMouse
  readonly property bool active: enabled && actionEnabled

  signal clicked

  readonly property real size: settings ? FoamyStyle.settingsButtonSize : FoamyStyle.actionSize
  implicitWidth: label ? content.implicitWidth + FoamyStyle.gapLarge * 2 : size
  implicitHeight: size
  radius: FoamyStyle.radius
  opacity: enabled ? (actionEnabled ? 1 : 0.7) : FoamyStyle.disabledOpacity
  color: active && (hasCursor || mouse.containsMouse || activeFocus) ? (destructive ? Qt.alpha(Commons.Color.urgent, 0.14) : FoamyPalette.hoverFill) : "transparent"
  border.width: (activeFocus && focusable) || (active && hasCursor && cursorByKeys) ? 1 : 0
  border.color: Commons.Color.accent
  activeFocusOnTab: focusable && active

  Behavior on color {
    ColorAnimation {
      duration: FoamyMotion.hover
    }
  }

  Accessible.role: Accessible.Button
  Accessible.name: tooltipText || label
  Accessible.onPressAction: if (root.active)
    root.clicked()
  Keys.onReturnPressed: if (root.active)
    root.clicked()
  Keys.onEnterPressed: if (root.active)
    root.clicked()
  Keys.onSpacePressed: if (root.active)
    root.clicked()
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
      // Readable on the destructive tint it sits on under the cursor, with
      // the popup surface under the tint. (In a band or on a selected row
      // the fill under it differs: it is measured as on the popup surface.)
      color: root.destructive && (root.hasCursor || mouse.containsMouse) ? FoamyPalette.onSurface(Commons.Color.urgent, Qt.tint(FoamyPalette.background, Qt.alpha(Commons.Color.urgent, 0.14))) : root.foreground
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
    onClicked: if (root.active)
      root.clicked()
  }

  PanelToolTip {
    id: tip
    visible: mouse.containsMouse && root.tooltipText !== ""
    // The host's tooltip is as wide as its text and wraps only under a cap,
    // so a long label or path would cover the whole popup. Capped through
    // implicitWidth, which the tooltip centers itself by (as the host does).
    implicitWidth: Math.min(implicitContentWidth + leftPadding + rightPadding, Commons.Style.space(320))
    // App text (a folder's path or name) has no length bound: 3 lines of
    // 200 characters keep an ordinary path whole and the wrapped tooltip a
    // few lines high, with a visible "…" beyond.
    text: FoamyText.cap(root.tooltipText, 3, 200)
    fontFamily: root.fontFamily

    // The host's text wraps at word boundaries only, so a name typed
    // without spaces would run past the capped width.
    Binding {
      target: tip.contentItem
      property: "wrapMode"
      value: Text.Wrap
    }
  }
}
