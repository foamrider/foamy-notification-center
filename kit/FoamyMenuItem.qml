// foamy-kit 0.4.2 cfe84fbb27e412da43a3ad4652cd17d0bb071e81119a0e4565fca7fcb1dda488 — do not edit; change foamy-kit and run sync
import QtQuick

// One entry of a FoamyMenu (and of FoamyHeader/FoamyHeroBand `menuItems`).
// Every entry has an icon (DESIGN.md). Children are a submenu: activating
// the entry shows them in place, with a Back row.
//
//   FoamyMenuItem { text: FoamyI18n.t("Silence notifications"); iconName: "bell-off"; onTriggered: root.toggleDnd() }
//   FoamyMenuItem {
//     text: FoamyI18n.t("Snooze notifications"); iconName: "clock"
//     FoamyMenuItem { text: FoamyI18n.t("30 minutes"); iconName: "clock"; onTriggered: store.snoozeAll(30) }
//     FoamyMenuItem { text: FoamyI18n.t("1 hour"); iconName: "clock"; onTriggered: store.snoozeAll(60) }
//   }
//   FoamyMenuItem { separator: true }
//
// enabled: false shows it greyed out and skips it with the keyboard;
// visible: false leaves it out. checked: true marks it with a check.
QtObject {
  id: root

  property string text: ""
  property string iconName: ""
  property color iconColor: "transparent"   // transparent = the menu's text colour
  property bool enabled: true
  property bool visible: true
  property bool destructive: false
  property bool checked: false
  property bool separator: false
  default property list<QtObject> items
  readonly property bool hasSubmenu: {
    for (var i = 0; i < items.length; i++) if (items[i] && items[i].visible !== false) return true
    return false
  }

  signal triggered()
}
