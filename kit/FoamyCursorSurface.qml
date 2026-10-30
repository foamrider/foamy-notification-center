// foamy-kit 0.1.0 185f7381c12b890ff269a8a72a5784b2afecabe298c9ceb701675dc9acf4b71a — do not edit; change foamy-kit and run sync
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
CursorSurface {
  id: root

  signal hovered()
  signal clicked()

  radius: FoamyStyle.radius

  HoverHandler {
    onHoveredChanged: if (hovered) root.hovered()
  }
  TapHandler {
    onTapped: root.clicked()
  }
}
