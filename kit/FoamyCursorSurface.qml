// foamy-kit 0.17.0 0546feee2b2984ff0a6173802dd3812051c3188dd4209c70239b14b4580ec200 — do not edit; change foamy-kit and run sync
import QtQuick
import qs.Commons as Commons
import qs.Ui

// A row or tile in the panel's single keyboard cursor model: the stock
// CursorSurface (one highlight for keyboard and pointer, theme state fills)
// with the foamy radius. Paint from `hasCursor`/`current`, never from
// containsMouse; route hover back to the panel cursor with `hovered`.
//
//   FoamyCursorSurface {
//     hasCursor: cursor.at(index)
//     onHovered: cursor.hover(index)
//     onClicked: root.activate(index)
//   }
//
// The pointer shows a hand over the row; set cursorShape (e.g.
// Qt.ArrowCursor) for rows that do nothing on click.
//
// Three looks, told apart by more than a shade of grey:
// - the cursor under the pointer: the soft hover fill and border;
// - the cursor the keys moved (`byKeys: cursor.byKeys`): the same fill
//   with a 1 px accent border, so the keys' place reads at a glance;
// - `current` (the selected row, the open view): FoamyPalette.selectedFill
//   (the accent, faint), kept under the cursor too; `currentBar: true`
//   adds a 3 px accent bar at the reading start, for a row whose details
//   show elsewhere (a pane).
CursorSurface {
  id: root

  signal hovered
  signal clicked

  property int cursorShape: Qt.PointingHandCursor
  property bool byKeys: false
  property bool currentBar: false

  radius: FoamyStyle.radius
  currentFill: FoamyPalette.selectedFill
  // Selected under the cursor: the selected tint, as much stronger as the
  // hover fill is strong (both are translucent, so Qt.tint wouldn't show).
  color: current ? (hasCursor ? Qt.alpha(currentFill, Math.min(1, currentFill.a + fill.a)) : currentFill) : hasCursor ? fill : "transparent"
  borderSpec: hasCursor ? (byKeys ? Commons.Border.flat(accent, FoamyStyle.borderWidth) : Commons.Border.controlSpec("hover-cursor", foreground, accent)) : current ? Commons.Border.controlSpec("selected", foreground, accent) : bordered ? Commons.Border.controlSpec("normal", foreground, accent) : Commons.Border.none()

  // Anchored, so RTL puts it at the reading start (the right). A pill
  // inset from the row's rounded ends.
  Rectangle {
    objectName: "foamyCurrentBar"
    visible: root.current && root.currentBar
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    width: FoamyStyle.borderWidth * 3
    height: Math.max(0, parent.height - FoamyStyle.gap * 2)
    radius: width / 2
    color: root.accent
  }

  HoverHandler {
    // While the keys drew the cursor (`byKeys`), a real pointer move inside
    // reports the pointer again (`hovered`), as entering does, so the
    // panel's cursor.hover(i) takes the cursor back. A scene position that
    // changed: Qt re-sends hover when items move under a resting pointer (a
    // keys-driven scroll), which is no move.
    property point scenePoint
    cursorShape: root.cursorShape
    onHoveredChanged: if (hovered) {
      scenePoint = point.scenePosition
      root.hovered()
    }
    onPointChanged: {
      const at = point.scenePosition
      if (hovered && root.byKeys && (at.x !== scenePoint.x || at.y !== scenePoint.y))
        root.hovered()
      scenePoint = at
    }
  }
  TapHandler {
    onTapped: root.clicked()
  }
}
