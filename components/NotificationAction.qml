import QtQuick
import qs.Commons
import qs.Ui

Rectangle {
  id: root
  property string iconName: "search"
  property real size: Style.space(32)
  property real iconSize: Style.space(16)
  property string tooltipText: ""
  property color foreground: Color.popups.text
  property color hoverForeground: foreground
  property bool hasCursor: false
  property bool focusable: true
  readonly property bool highlighted: mouse.containsMouse || activeFocus || hasCursor
  signal clicked()

  implicitWidth: size
  implicitHeight: size
  radius: Style.cornerRadius * 2
  color: highlighted ? Qt.alpha(hoverForeground, 0.08) : "transparent"
  opacity: enabled ? 1 : 0.4
  border.width: activeFocus ? 1 : 0
  border.color: Color.accent
  activeFocusOnTab: focusable
  Accessible.role: Accessible.Button
  Accessible.name: tooltipText
  Accessible.onPressAction: if (enabled) clicked()
  Keys.onReturnPressed: if (enabled) clicked()
  Keys.onEnterPressed: if (enabled) clicked()
  Keys.onSpacePressed: if (enabled) clicked()

  Image {
    anchors.centerIn: parent
    width: root.iconSize
    height: width
    sourceSize.width: width * 2
    sourceSize.height: height * 2
    readonly property color ink: root.highlighted ? root.hoverForeground : root.foreground
    readonly property var paths: ({
      search: '<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 5 5"/>',
      bell: '<path d="M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9M10 21h4"/>',
      bellOff: '<path d="M9 3a6 6 0 0 1 9 5c0 2 .3 3.5.7 4.6M6 6C6 7 6 8 6 8c0 7-3 7-3 9h14M10 21h4M3 3l18 18"/>',
      trash: '<path d="M3 6h18M9 6V4h6v2M5 6l1 14h12l1-14M10 10v6M14 10v6"/>',
      more: '<circle cx="5" cy="12" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/>',
      back: '<path d="M19 12H5m7-7-7 7 7 7"/>',
      settings: '<path d="m9 3-1 3-3 1-2 5 2 5 3 1 1 3h6l1-3 3-1 2-5-2-5-3-1-1-3Z"/><circle cx="12" cy="12" r="3"/>',
      close: '<path d="m6 6 12 12M6 18 18 6"/>'
    })
    source: "data:image/svg+xml," + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="' + Qt.rgba(ink.r, ink.g, ink.b, 1) + '" stroke-opacity="' + ink.a + '" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">' + paths[root.iconName] + '</svg>')
  }
  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }
  PanelToolTip {
    visible: mouse.containsMouse && root.tooltipText !== ""
    text: root.tooltipText
    fontFamily: "sans-serif"
  }
}
