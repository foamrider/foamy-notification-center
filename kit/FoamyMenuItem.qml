// foamy-kit 0.16.0 3761a1732fc11bad464a0babf455a205aae1f6dc337d88c80f1d58d571ab3e79 — do not edit; change foamy-kit and run sync
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
// visible: false leaves it out. checked: true marks it with a check: the
// current choice of a set (one entry), where a menu opened from the keys
// starts (FoamyMenu.open(true)). A multi-select menu (labels) with exactly
// one checked entry starts on it too, so there Enter unchecks it.
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
    for (var i = 0; i < items.length; i++)
      if (items[i] && items[i].visible !== false)
        return true
    return false
  }

  signal triggered
}
