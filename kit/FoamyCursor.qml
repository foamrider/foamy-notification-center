// foamy-kit 0.3.2 4488b3dbaa2b0fab78fb66dea979e57bcc0f30e76e6443bb4a0f031fffc44709 — do not edit; change foamy-kit and run sync
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
// PanelKeyCatcher.textKey is textKey(text) on 4.0 and textKey(text, modifiers)
// on 4.5. Declare handlers as function(text, modifiers): `modifiers` is
// undefined on 4.0, and plain(modifiers) is true then. Tests that emit the
// signal must match the host's arity: emitTextKey(catcher, text) does that.
QtObject {
  id: root

  property int count: 0
  property int index: -1
  property bool wrap: false
  readonly property bool active: index >= 0

  function at(i) { return index === i }
  function hover(i) { if (i >= 0 && i < count) index = i }
  function reset() { index = -1 }
  // A letter shortcut with no Ctrl/Alt/Meta held (Shift is fine).
  function plain(modifiers) {
    if (modifiers === undefined || modifiers === null) return true
    return (modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) === 0
  }
  // Emit a catcher's textKey with the host's signature (tests, synthetic keys).
  function emitTextKey(catcher, text, modifiers) {
    try {
      catcher.textKey(text, modifiers === undefined ? Qt.NoModifier : modifiers)
    } catch (error) {
      catcher.textKey(text)
    }
  }
  function move(delta) {
    if (count <= 0) { index = -1; return }
    if (index < 0) { index = delta < 0 ? count - 1 : 0; return }
    var next = index + (delta < 0 ? -1 : 1)
    index = wrap ? (next + count) % count : Math.max(0, Math.min(count - 1, next))
  }

  onCountChanged: if (index >= count) index = count - 1
}
