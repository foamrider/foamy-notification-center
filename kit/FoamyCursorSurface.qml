// foamy-kit 0.3.3 322db103ce6d6476aac66858d421c75258365a5a2017188906cce61c8b1610ee — do not edit; change foamy-kit and run sync
import QtQuick
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
CursorSurface {
  id: root

  signal hovered()
  signal clicked()

  property int cursorShape: Qt.PointingHandCursor

  radius: FoamyStyle.radius

  HoverHandler {
    cursorShape: root.cursorShape
    onHoveredChanged: if (hovered) root.hovered()
  }
  TapHandler {
    onTapped: root.clicked()
  }
}
