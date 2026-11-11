// foamy-kit 0.9.0 31371ef41d02ff56eb60557ef113a98f1f10dd6fd3881d2e0b8f9de55649dbf1 — do not edit; change foamy-kit and run sync
import QtQuick

// The panel's single cursor over a flat list of stops (rows, then buttons),
// for PanelKeyCatcher panels. Keyboard and pointer move the same cursor, so
// one highlight is on screen at a time.
//
//   FoamyCursor { id: cursor; count: rows.length + 1 }
//   PanelKeyCatcher {
//     onMoveRequested: function(dx, dy) { cursor.move(dy !== 0 ? dy : dx) }
//     onActivateRequested: root.activate(cursor.index)
//     onCloseRequested: root.close()
//     onTabRequested: function(direction) { root.switchPanel(direction) }
//     onTextKey: function(text, modifiers) {
//       if (!cursor.plain(modifiers)) return            // leave Alt+S etc. alone
//       if (text === "s") root.openSettings()
//     }
//   }
//   FoamyCursorSurface { hasCursor: cursor.at(index); onHovered: cursor.hover(index) }
//
// index is -1 until the first move or hover (no highlight on open). reset()
// on close; clamp happens automatically when count shrinks.
//
// PanelKeyCatcher.textKey is textKey(text, modifiers). Declare handlers as
// function(text, modifiers); plain(modifiers) is true for a missing value
// too (a synthetic key). Tests emit it with emitTextKey(catcher, text).
QtObject {
  id: root

  property int count: 0
  property int index: -1
  property bool wrap: false
  readonly property bool active: index >= 0

  function at(i) {
    return index === i
  }
  function hover(i) {
    if (i >= 0 && i < count)
      index = i
  }
  function reset() {
    index = -1
  }
  // A letter shortcut with no Ctrl/Alt/Meta held (Shift is fine).
  function plain(modifiers) {
    if (modifiers === undefined || modifiers === null)
      return true
    return (modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) === 0
  }
  // Emit a catcher's textKey (tests, synthetic keys); no modifiers by default.
  function emitTextKey(catcher, text, modifiers) {
    catcher.textKey(text, modifiers === undefined ? Qt.NoModifier : modifiers)
  }
  function move(delta) {
    if (count <= 0) {
      index = -1
      return
    }
    if (index < 0) {
      index = delta < 0 ? count - 1 : 0
      return
    }
    var next = index + (delta < 0 ? -1 : 1)
    index = wrap ? (next + count) % count : Math.max(0, Math.min(count - 1, next))
  }

  onCountChanged: if (index >= count)
    index = count - 1
}
