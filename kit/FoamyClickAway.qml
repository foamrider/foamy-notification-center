// foamy-kit 0.15.1 8dcfc8720fe0a2299a6c9c901be2f85bc2f9ba92170697e477d716be9cb9e8cf — do not edit; change foamy-kit and run sync
import QtQuick

// Click-away: a click on space that does nothing takes the keys from a
// focused text field (SafeTextField, SafeTextArea, any TextInput or
// TextEdit) and gives them to the field's key home. The field ends its
// edit as for any focus loss (`editingFinished`).
//
//   FoamyClickAway { anchors.fill: parent; z: -1; onClicked: root.clearSelection() }
//
// It lies under the content: a press reaches it only where nothing above
// takes it (a row, a button, a field), so real controls keep their clicks.
// In a Flickable a drag that starts on it still flicks (the Flickable takes
// it over), and it ignores the wheel; only a click (press and release
// without a drag) counts. Left button only.
//
// The key home is the nearest ancestor of the focused field with a
// non-null `foamyKeyHome` item:
//   - FoamyPopup's body: its `focusTarget` (the body item while that is
//     the default),
//   - FoamySettingsPage: the page itself (Esc still goes back),
//   - any item of a plugin may declare one (`readonly property Item
//     foamyKeyHome: keyItem`; null passes the search on to its parent).
// Without a home, or with no field focused, a click changes no focus.
//
// FoamyPopup puts one behind its body and FoamyWheelScroll one in its
// Flickable, so a plugin needs nothing for the general case. `clicked`
// fires on every click, whether a field had the keys or not, for a
// plugin's own reaction to a click on empty space.
Item {
  id: root

  signal clicked

  // The home `item`'s keys go to (null: none).
  function homeOf(item) {
    for (let at = item; at; at = at.parent) {
      if ("foamyKeyHome" in at && at.foamyKeyHome)
        return at.foamyKeyHome
    }
    return null
  }
  // Takes the keys from a focused text field in this window. True when it did.
  function releaseKeys() {
    var window = root.Window.window
    var focused = window ? window.activeFocusItem : null
    if (!(focused instanceof TextInput) && !(focused instanceof TextEdit))
      return false
    var home = homeOf(focused)
    if (!home || home === focused)
      return false
    // A focus scope that holds the field would hand the keys straight back
    // to it: the field lets go first, then the home takes them.
    focused.focus = false
    home.forceActiveFocus()
    return true
  }

  MouseArea {
    objectName: "clickAway"
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton
    onClicked: {
      root.releaseKeys()
      root.clicked()
    }
  }
}
