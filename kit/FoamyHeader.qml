// foamy-kit 0.4.0 465df6b1eba83f0a26b277269932e44f8db9ee9f242a1deee0fca1c0b3047f9e — do not edit; change foamy-kit and run sync
import QtQuick
import QtQuick.Layouts

// The one foamy popup header: icon, title, meta line, trailing controls, the
// overflow (⋯) menu and the settings button, inside FoamyStyle.padding.
//
//   FoamyHeader {
//     width: parent.width
//     iconName: "monitor"
//     title: FoamyI18n.t("Displays")
//     meta: FoamyI18n.tn("%1 connected", count)
//     settingsHasCursor: root.cursor === "settings"
//     onSettingsClicked: root.openSettings()
//     FoamyAction { iconName: "refresh-cw"; tooltipText: FoamyI18n.t("Refresh") }   // trailing, most important first
//     menuItems: [
//       FoamyMenuItem { text: FoamyI18n.t("Silence notifications"); iconName: "bell-off"; onTriggered: … }
//     ]
//   }
//
// At most `maxButtons` (3) buttons on the top right (DESIGN.md). Declare the
// trailing actions in priority order. When the actions, the menu button and
// Settings don't fit in three, a ⋯ button takes the last slot and the menu
// gets, in order: the trailing actions that didn't fit (icon and tooltip
// text; they keep working through their `clicked`), `menuItems`, then a
// separator and Settings. With `menuItems` and room to spare, the ⋯ button
// shows next to Settings and the menu holds just the items. Trailing items
// without `clicked`/`iconName` (not actions) always stay in the row.
//
// The settings button carries the tooltip "Settings" and is reachable with
// `s` through the panel's PanelKeyCatcher.onTextKey (wire that in the panel).
//
// Keyboard: give the ⋯ button a stop in your cursor (`menuHasCursor`, route
// `menuHovered`), open it with `openMenu(true)` on Enter, and add `menuOpen`
// to the PanelKeyCatcher's `blocked`; the menu takes the keys until it
// closes (FoamyMenu). `shownTrailing` lists the actions still in the row, for
// cursor stops. While Settings is in the menu, `settingsHasCursor` lights the
// ⋯ button.
Item {
  id: root

  property string iconName: ""
  property string title: ""
  property string meta: ""
  property bool showSettings: true
  property bool settingsHasCursor: false
  property color foreground: FoamyPalette.text
  // false hides the icon and the title/meta column (FoamyHeroBand `centered`
  // draws them itself); the buttons stay at the trailing end.
  property bool showTitle: true
  // Insets around the row (FoamyHeroBand sets the vertical ones to 0).
  property real horizontalPadding: FoamyStyle.padding
  property real topPadding: FoamyStyle.padding
  property real bottomPadding: FoamyStyle.padding
  property alias settingsButton: settingsButton
  default property list<Item> trailing

  // --- overflow menu -------------------------------------------------------------
  property list<QtObject> menuItems
  property int maxButtons: 3
  property bool menuHasCursor: false
  property string menuTooltip: FoamyI18n.t("More options")
  property alias menuButton: menuButton
  readonly property FoamyMenu menu: overflowMenu
  readonly property bool menuOpen: overflowMenu.opened
  readonly property bool overflowing: _overflowing
  readonly property bool settingsInMenu: _overflowing && showSettings
  readonly property bool showsMenuButton: _overflowing || _menuCount > 0
  // Trailing items in the row / moved into the menu, in declaration order.
  readonly property var shownTrailing: _shown
  readonly property var overflowTrailing: _overflow
  // The row's buttons as laid out (trailing, ⋯, Settings): its width, for
  // layouts that keep clear of them.
  readonly property real buttonsWidth: trailingRow.width + (settingsButton.visible ? settingsButton.width + row.spacing : 0)

  signal settingsClicked()
  signal settingsHovered(bool hovered)
  signal menuHovered(bool hovered)

  function openMenu(keyboard) { if (showsMenuButton) overflowMenu.open(!!keyboard) }
  function closeMenu() { overflowMenu.close() }
  function toggleMenu(keyboard) { if (overflowMenu.opened) closeMenu(); else openMenu(keyboard) }

  implicitWidth: row.implicitWidth + horizontalPadding * 2
  implicitHeight: Math.max(FoamyStyle.settingsButtonSize, showTitle ? textColumn.implicitHeight : 0) + topPadding + bottomPadding

  // --- layout of the trailing actions ---------------------------------------------
  property var _shown: []
  property var _overflow: []
  property bool _overflowing: false
  readonly property int _menuCount: {
    var n = 0
    for (var i = 0; i < menuItems.length; i++)
      if (menuItems[i] && menuItems[i].visible !== false && !menuItems[i].separator) n++
    return n
  }
  property var _watched: []
  property var _proxies: []

  function _isAction(item) { return !!item && typeof item.clicked === "function" && "iconName" in item }

  function _relayout() {
    // Item.visible is the effective visibility: only meaningful while shown.
    if (!root.visible) return
    var all = [], shown = []
    for (var i = 0; i < trailing.length; i++) if (trailing[i]) all.push(trailing[i])
    for (i = 0; i < all.length; i++) if (all[i].visible) shown.push(all[i])
    var settings = showSettings ? 1 : 0
    var overflowing = shown.length + settings + (_menuCount > 0 ? 1 : 0) > maxButtons
    var keep = [], moved = []
    if (!overflowing) {
      keep = shown
    } else {
      var pinned = shown.filter(function(item) { return !root._isAction(item) })
      var slots = Math.max(0, maxButtons - 1 - pinned.length)
      for (i = 0; i < shown.length; i++) {
        if (!_isAction(shown[i])) keep.push(shown[i])
        else if (slots > 0) { keep.push(shown[i]); slots-- }
        else moved.push(shown[i])
      }
    }
    var old = _proxies
    var proxies = []
    for (i = 0; i < moved.length; i++) proxies.push(proxyComponent.createObject(root, { action: moved[i] }))
    _proxies = proxies
    for (i = 0; i < old.length; i++) old[i].destroy()
    _overflow = moved
    _shown = keep
    _overflowing = overflowing
    _place()
  }

  // Lay the row out by hand: kept actions in declaration order, then ⋯.
  // Moved actions stay where they are in the item tree (reparenting an item
  // in the frame it is shown makes the software renderer drop it) and only
  // go out of sight, so their own `visible` stays readable for the next
  // relayout. Mirrored by hand in RTL.
  function _place() {
    var order = _shown.slice()
    if (menuButton.visible) order.push(menuButton)
    var x = 0, height = 0
    var placed = []
    for (var i = 0; i < order.length; i++) {
      var item = order[i]
      if (!item.visible) continue
      if (placed.length) x += trailingRow.spacing
      item.x = x
      x += item.width
      height = Math.max(height, item.height)
      placed.push(item)
    }
    trailingRow.implicitWidth = x
    trailingRow.implicitHeight = height
    for (i = 0; i < placed.length; i++) {
      if (_mirrored) placed[i].x = x - placed[i].x - placed[i].width
      placed[i].y = (height - placed[i].height) / 2
    }
    for (i = 0; i < _overflow.length; i++) { _overflow[i].x = -100000; _overflow[i].y = 0 }
  }
  readonly property bool _mirrored: LayoutMirroring.enabled
  on_MirroredChanged: _place()

  function _unwatch(item) {
    item.visibleChanged.disconnect(_queueRelayout)
    item.widthChanged.disconnect(_queueRelayout)
    item.heightChanged.disconnect(_queueRelayout)
  }
  function _watch() {
    for (var i = 0; i < _watched.length; i++) if (_watched[i]) _unwatch(_watched[i])
    var list = []
    for (i = 0; i < trailing.length; i++) {
      var item = trailing[i]
      if (!item) continue
      if (item.parent !== trailingRow) item.parent = trailingRow
      item.visibleChanged.connect(_queueRelayout)
      item.widthChanged.connect(_queueRelayout)
      item.heightChanged.connect(_queueRelayout)
      list.push(item)
    }
    _watched = list
    _queueRelayout()
  }
  // A child Timer, not Qt.callLater: it dies with the header, so a header
  // destroyed before the relayout runs (popup opened and closed in one
  // frame, a bar removed) doesn't call into a dead object.
  function _queueRelayout() { if (!relayoutTimer.running) relayoutTimer.start() }
  Timer { id: relayoutTimer; interval: 0; onTriggered: root._relayout() }

  onTrailingChanged: _watch()
  onShowSettingsChanged: _queueRelayout()
  onMaxButtonsChanged: _queueRelayout()
  on_MenuCountChanged: _queueRelayout()
  onVisibleChanged: if (visible) _queueRelayout(); else overflowMenu.close()
  Component.onCompleted: { _watch(); _relayout() }
  Component.onDestruction: {
    for (var i = 0; i < _watched.length; i++) if (_watched[i]) _unwatch(_watched[i])
  }

  Component {
    id: proxyComponent
    FoamyMenuItem {
      property Item action: null
      text: action ? String(action.tooltipText || action.label || "") : ""
      iconName: action ? action.iconName : ""
      enabled: !!action && action.active !== false
      destructive: !!action && action.destructive === true
      onTriggered: if (action) action.clicked()
    }
  }
  FoamyMenuItem { id: menuSeparator; separator: true }
  FoamyMenuItem {
    id: settingsEntry
    objectName: "foamyMenuSettings"
    text: FoamyI18n.t("Settings")
    iconName: "settings"
    onTriggered: root.settingsClicked()
  }

  FoamyMenu {
    id: overflowMenu
    anchorItem: menuButton
    mirrored: root.LayoutMirroring.enabled
    items: {
      var list = root._proxies.slice()
      for (var i = 0; i < root.menuItems.length; i++) list.push(root.menuItems[i])
      if (root.settingsInMenu) { list.push(menuSeparator); list.push(settingsEntry) }
      return list
    }
  }

  RowLayout {
    id: row
    anchors.fill: parent
    anchors.leftMargin: root.horizontalPadding
    anchors.rightMargin: root.horizontalPadding
    anchors.topMargin: root.topPadding
    anchors.bottomMargin: root.bottomPadding
    spacing: FoamyStyle.gapLarge

    FoamyIcon {
      visible: root.showTitle && root.iconName !== ""
      name: root.iconName
      color: root.foreground
      Layout.preferredWidth: FoamyStyle.headerIconSize
      Layout.preferredHeight: FoamyStyle.headerIconSize
      Layout.alignment: Qt.AlignVCenter
    }

    Column {
      id: textColumn
      visible: root.showTitle
      Layout.fillWidth: true
      Layout.alignment: Qt.AlignVCenter
      spacing: FoamyStyle.gapTiny
      Text {
        width: parent.width
        text: root.title
        textFormat: Text.PlainText
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignLeft
        color: root.foreground
        font.family: FoamyStyle.fontFamily
        font.pixelSize: FoamyStyle.font.title
        font.weight: Font.DemiBold
      }
      Text {
        visible: root.meta !== ""
        width: parent.width
        text: root.meta
        textFormat: Text.PlainText
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignLeft
        color: FoamyPalette.secondaryText
        font.family: FoamyStyle.fontFamily
        font.pixelSize: FoamyStyle.font.bodySmall
      }
    }
    Item { visible: !root.showTitle; Layout.fillWidth: true }

    // Laid out by _place(): kept trailing actions, then ⋯.
    Item {
      id: trailingRow
      objectName: "foamyHeaderTrailing"
      readonly property real spacing: FoamyStyle.gapSmall
      Layout.alignment: Qt.AlignVCenter
      Layout.preferredWidth: implicitWidth
      Layout.preferredHeight: implicitHeight

      FoamyAction {
        id: menuButton
        objectName: "foamyMenuButton"
        visible: root.showsMenuButton
        iconName: "ellipsis"
        foreground: FoamyPalette.secondaryText
        tooltipText: root.menuTooltip
        hasCursor: root.menuHasCursor || (root.settingsInMenu && root.settingsHasCursor) || overflowMenu.opened
        onClicked: root.toggleMenu(false)
        onHoveredChanged: root.menuHovered(hovered)
        onVisibleChanged: root._queueRelayout()
      }
    }

    FoamyAction {
      id: settingsButton
      visible: root.showSettings && !root.settingsInMenu
      settings: true
      iconName: "settings"
      foreground: FoamyPalette.secondaryText
      tooltipText: FoamyI18n.t("Settings")
      hasCursor: root.settingsHasCursor
      Layout.alignment: Qt.AlignVCenter
      onClicked: root.settingsClicked()
      onHoveredChanged: root.settingsHovered(hovered)
    }
  }

}
