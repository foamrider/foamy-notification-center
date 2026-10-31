// foamy-kit 0.3.5 71758bdddfde7d4b7304ac51cc01c40c1d0a1c24f49a735069ec4b10ff8c51e2 — do not edit; change foamy-kit and run sync
import QtQuick

// Whether a panel shows its settings page, with the one safe ordering.
//
//   FoamySettingsState { id: settingsState; panel: root }
//   property alias editingSettings: settingsState.editing     // or bind to it
//   function openSettings() { settingsState.show() }          // IPC, `s`, the cog
//   function closeSettings() { settingsState.hide() }         // back, Esc
//
// show() opens the popup if needed and lands on Settings; the page resets
// when the popup closes, never when it opens. Resetting on open breaks
// openSettings() on a closed popup: Ui.Panel.open() flips `opened`
// synchronously, so an `onOpenedChanged: if (opened) editingSettings = false`
// runs after show() set it and the settings IPC lands on the overview.
// holdOnClose keeps the page across a close (e.g. a folder picker or browser
// sign-in that closes the popup and reopens it).
QtObject {
  id: state

  property QtObject panel: null
  property bool editing: false
  property bool holdOnClose: false

  signal shown()
  signal hidden()

  function show() {
    editing = true
    if (panel && !panel.opened) panel.open()
    shown()
  }

  function hide() {
    if (!editing) return
    editing = false
    hidden()
  }

  property Connections watcher: Connections {
    target: state.panel
    ignoreUnknownSignals: true
    function onOpenedChanged() {
      if (state.panel && !state.panel.opened && !state.holdOnClose) state.hide()
    }
  }
}
