pragma ComponentBehavior: Bound
// foamy-kit 0.16.0 399fff048da536c56732e31d87e4d4ebf2e4a442d87566f4cd773f58799e8705 — do not edit; change foamy-kit and run sync
import QtQuick
import qs.Commons as Commons

// A small menu that drops from a button inside the popup card: the foamy
// overflow menu (FoamyHeader/FoamyHeroBand build one for `menuItems`), also
// usable on its own for a row's ⋯ button.
//
//   FoamyAction { id: more; iconName: "ellipsis"; tooltipText: FoamyI18n.t("More options"); onClicked: menu.toggle(false) }
//   FoamyMenu {
//     id: menu
//     anchorItem: more
//     FoamyMenuItem { text: FoamyI18n.t("Mark as read"); iconName: "check"; onTriggered: … }
//     FoamyMenuItem { separator: true }
//     FoamyMenuItem { text: FoamyI18n.t("Delete"); iconName: "trash"; destructive: true; onTriggered: … }
//   }
//
// Placement: an overlay inside the popup card (never a separate window), its
// top just under `anchorItem` and its trailing edge on the button's trailing
// edge (right in LTR, left in RTL), kept inside the card; when the card has
// no room below it opens above the button, and a long menu scrolls. Not
// clipped by the hero band and drawn over the body. In a FoamyPopup or
// FoamyPopupCard, when the menu fits neither below nor above its button,
// the card grows while it is open (by at most `maxGrowHeight` of menu, as
// far as the screen allows; a longer menu scrolls) and shrinks back after.
//
// Keyboard (single cursor): open(true) from the keyboard selects the
// checked entry (the current choice; else the first), so Enter at once
// keeps what is chosen; open(false) from a click selects nothing until the
// pointer or a key moves. Up/Down/j/k/Home/End move; a long menu then scrolls the least
// that shows the entry (the wheel and hover scroll and highlight freely).
// Enter/Space/Right/l activate (Right opens a submenu), Left/h/Backspace
// leave a submenu, Esc leaves a submenu or closes, Tab closes. While open the menu has the keys and the pointer
// (hover outside does nothing, a press outside closes it), so the panel's own
// cursor stays put: add `menu.opened` to your PanelKeyCatcher's `blocked`.
// Focus returns to whatever had it when the menu opened.
//
// It closes when the anchor is hidden (popup closed, settings opened).
QtObject {
  id: root

  property Item anchorItem: null
  default property list<QtObject> items
  property real menuWidth: FoamyStyle.menuWidth
  // The most menu a card grows for; past it the menu scrolls.
  property real maxGrowHeight: FoamyStyle.rowHeight * 9
  // Where the overlay lives; found from anchorItem (the popup card, else the
  // window's root item) when null.
  property Item host: null
  property bool mirrored: FoamyI18n.rightToLeft
  readonly property bool opened: _opened
  // The highlighted entry of the shown level (-1: none).
  readonly property int currentIndex: _index
  // The shown level's entries (FoamyMenuItem; a submenu adds a Back entry first).
  readonly property var entries: _entries
  readonly property bool inSubmenu: _parentEntry !== null
  readonly property Item panel: menuPanel
  readonly property Item overlayItem: _overlay

  signal aboutToOpen
  signal closed

  property bool _opened: false
  property int _index: -1
  property var _parentEntry: null
  property Item _hostItem: null
  property Item _reserveHolder: null
  // Whether the card grows for this open: decided when it opens and again
  // when a submenu or another level shows (entries laid out first), and
  // never taken back while open, so the card doesn't jump down and up.
  property bool _grow: false
  property real _reserved: 0
  property Item _restoreFocus: null

  readonly property var _entries: {
    var level = _parentEntry ? _parentEntry.items : items
    var out = []
    if (_parentEntry)
      out.push(_back)
    var lastSeparator = true
    for (var i = 0; i < level.length; i++) {
      var entry = level[i]
      if (!entry || entry.visible === false)
        continue
      if (entry.separator) {
        if (lastSeparator)
          continue
        lastSeparator = true
      } else {
        lastSeparator = false
      }
      out.push(entry)
    }
    while (out.length && out[out.length - 1].separator)
      out.pop()
    return out
  }

  function selectable(i) {
    var entry = _entries[i]
    return !!entry && !entry.separator && entry.enabled !== false
  }

  function open(keyboard) {
    if (!anchorItem)
      return
    var host = root.host || _findHost()
    if (!host)
      return
    aboutToOpen()
    _hostItem = host
    _parentEntry = null
    var window = anchorItem.Window.window
    _restoreFocus = window ? window.activeFocusItem : null
    _index = -1
    _opened = true
    _reserveHolder = null
    for (var item = anchorItem; item; item = item.parent)
      if ("foamyMenuReserve" in item) {
        _reserveHolder = item
        break
      }
    _grow = false
    _reserved = 0
    overlay.decideGrowth()
    if (keyboard)
      _startOnChoice()
    _overlay.place()
    overlay.reveal()
    _overlay.forceActiveFocus()
  }

  // From the keys: the current choice (the one checked entry of a set),
  // else the first entry. With several checked (toggles, labels) Enter
  // would turn one off, so then the first.
  function _startOnChoice() {
    const checked = []
    for (let i = 0; i < _entries.length; i++)
      if (_entries[i].checked === true && selectable(i))
        checked.push(i)
    if (checked.length === 1)
      _index = checked[0]
    else {
      _index = -1
      move(1)
    }
  }

  function close() {
    if (!_opened)
      return
    _opened = false
    _parentEntry = null
    _index = -1
    if (_reserveHolder)
      _reserveHolder.foamyMenuReserve = 0
    _reserveHolder = null
    _grow = false
    _reserved = 0
    var restore = _restoreFocus
    _restoreFocus = null
    if (restore && restore.visible)
      restore.forceActiveFocus()
    closed()
  }

  function toggle(keyboard) {
    if (_opened)
      close()
    else
      open(keyboard)
  }

  function move(delta) {
    var n = _entries.length
    if (n === 0) {
      _index = -1
      return
    }
    var i = _index
    for (var step = 0; step < n; step++) {
      i = i < 0 ? (delta > 0 ? 0 : n - 1) : Math.max(0, Math.min(n - 1, i + (delta > 0 ? 1 : -1)))
      if (selectable(i)) {
        _index = i
        overlay.reveal()
        return
      }
      if ((delta > 0 && i === n - 1) || (delta < 0 && i === 0))
        return
    }
  }

  function moveTo(edge) {
    _index = -1
    if (edge > 0) {
      _index = _entries.length
      move(-1)
    } else
      move(1)
  }

  function hover(i) {
    if (selectable(i))
      _index = i
  }
  // Where the pointer last was, in the menu panel's coordinates. Rows
  // that scroll under a resting pointer (a keyboard move revealing its
  // entry, the wheel) send hover events too; only a pointer that moved
  // takes the highlight, so Enter keeps the entry the keys chose.
  property point _pointer: Qt.point(-1, -1)
  function _pointerHover(area, i) {
    var at = area.mapToItem(menuPanel, area.mouseX, area.mouseY)
    if (Math.abs(at.x - _pointer.x) < 0.5 && Math.abs(at.y - _pointer.y) < 0.5)
      return
    _pointer = at
    hover(i)
  }

  // Activate entry i (the highlighted one by default).
  function activate(i) {
    if (i === undefined)
      i = _index
    if (!selectable(i))
      return
    var entry = _entries[i]
    if (entry === _back) {
      leaveSubmenu()
      return
    }
    // A submenu opens in place on its first item (after the Back row).
    if (entry.hasSubmenu) {
      _parentEntry = entry
      overlay.decideGrowth()
      _startOnChoice()
      // Not the Back row: the submenu's own first entry or its choice.
      if (_index === 0)
        move(1)
      _overlay.place()
      overlay.reveal()
      return
    }
    close()
    entry.triggered()
  }

  function leaveSubmenu() {
    if (!_parentEntry)
      return false
    var from = _parentEntry
    // No highlight while the level changes (else the old index lights a
    // row of the new level for a frame).
    _index = -1
    _parentEntry = null
    _index = _entries.indexOf(from)
    overlay.decideGrowth()
    _overlay.place()
    overlay.reveal()
    return true
  }

  // The card: the first bordered surface (a host BorderSurface) above the
  // popup's body (the item that holds foamyMenuReserve), so a row's or a
  // button's own surface between the anchor and the body is never taken
  // for it. Outside a FoamyPopup or FoamyPopupCard: the first bordered
  // surface above the anchor, else the window's root item.
  function _findHost() {
    var inPopup = false
    for (let at = anchorItem; at && !inPopup; at = at.parent)
      inPopup = "foamyMenuReserve" in at
    var passedBody = !inPopup
    var top = null
    for (var item = anchorItem; item; item = item.parent) {
      if ("foamyMenuReserve" in item)
        passedBody = true
      if (passedBody && "borderSpec" in item && "contentBottomInset" in item)
        return item
      top = item
    }
    return top
  }

  property FoamyMenuItem _back: FoamyMenuItem {
    text: root._parentEntry ? root._parentEntry.text : FoamyI18n.t("Back")
    iconName: "chevron-left"
  }

  property Item _overlay: FocusScope {
    id: overlay
    objectName: "foamyMenuOverlay"
    parent: root._opened ? root._hostItem : null
    visible: root._opened
    width: parent ? parent.width : 0
    height: parent ? parent.height : 0
    z: 1000
    LayoutMirroring.enabled: root.mirrored
    LayoutMirroring.childrenInherit: true

    readonly property real margin: FoamyStyle.gap
    readonly property real naturalHeight: list.implicitHeight + FoamyStyle.menuPadding * 2 + 2
    property real menuX: 0
    property real menuY: 0
    property real menuHeight: 0

    // Grow the card when the shown level, laid out now (its entries may
    // have just changed), fits neither below nor above its button in the
    // card as it is, and growing helps: the most it would grow for is more
    // than the larger room. Once grown, it stays grown while open.
    function decideGrowth() {
      var host = root._hostItem
      if (!root._reserveHolder || !host || !root.anchorItem || root._grow)
        return
      list.forceLayout()
      var b = root.anchorItem.mapToItem(host, 0, 0)
      var below = host.height - (b.y + root.anchorItem.height + FoamyStyle.gapSmall) - margin
      var above = b.y - FoamyStyle.gapSmall - margin
      root._grow = Math.min(naturalHeight, root.maxGrowHeight) > Math.max(below, above)
    }
    function place() {
      if (!root._opened || !root.anchorItem || !parent)
        return
      // In a FoamyPopup/FoamyPopupCard the card grows for the menu below its
      // button when decideGrowth() said so (by at most maxGrowHeight, up to
      // the screen); otherwise, and elsewhere, a long menu scrolls.
      // The card may still be shrinking from an earlier open: decide again
      // as it changes (only ever towards growing).
      decideGrowth()
      var holder = root._reserveHolder
      if (holder && root._grow) {
        var h0 = root.anchorItem.mapToItem(holder, 0, 0)
        // Never less than this open asked for: a shorter level doesn't
        // shrink the card under the menu.
        root._reserved = Math.max(root._reserved, h0.y + root.anchorItem.height + FoamyStyle.gapSmall + Math.min(naturalHeight, root.maxGrowHeight) + margin)
        holder.foamyMenuReserve = root._reserved
      }
      var b = root.anchorItem.mapToItem(overlay, 0, 0)
      var w = Math.max(0, Math.min(root.menuWidth, width - margin * 2))
      var x = root.mirrored ? b.x : b.x + root.anchorItem.width - w
      menuX = Math.max(margin, Math.min(width - w - margin, x))
      var below = height - (b.y + root.anchorItem.height + FoamyStyle.gapSmall) - margin
      var above = b.y - FoamyStyle.gapSmall - margin
      var h = naturalHeight
      if (h <= below || below >= above) {
        menuHeight = Math.max(0, Math.min(h, below))
        menuY = b.y + root.anchorItem.height + FoamyStyle.gapSmall
      } else {
        menuHeight = Math.max(0, Math.min(h, above))
        menuY = b.y - FoamyStyle.gapSmall - menuHeight
      }
    }
    // Keyboard moves keep the highlighted entry in view: the least scroll
    // that shows it, at once (Enter must never pick a hidden entry). The
    // wheel and hover don't call it, so they scroll and highlight freely.
    function reveal() {
      if (!root._opened || root._index < 0)
        return
      // A new level's rows are laid out on the next polish; place them now.
      list.forceLayout()
      var row = rows.itemAt(root._index)
      if (!row)
        return
      var top = row.y
      var bottom = top + row.height
      var y = scroller.contentY
      if (top < y)
        y = top
      else if (bottom > y + scroller.height)
        y = bottom - scroller.height
      if (Math.abs(menuWheel.clamp(y) - scroller.contentY) > 0.5)
        menuWheel.scrollTo(y, false)
    }
    onWidthChanged: place()
    // The card grows after a keyboard open: keep the entry in view (only
    // while it grows for this menu, so a wheel scroll otherwise stays).
    onHeightChanged: {
      place()
      if (root._grow)
        reveal()
    }
    onNaturalHeightChanged: place()

    Connections {
      target: root.anchorItem
      ignoreUnknownSignals: true
      function onVisibleChanged() {
        if (root.anchorItem && !root.anchorItem.visible)
          root.close()
      }
    }
    Connections {
      target: root._hostItem
      ignoreUnknownSignals: true
      function onVisibleChanged() {
        if (root._hostItem && !root._hostItem.visible)
          root.close()
      }
    }

    Keys.onPressed: function (event) {
      var forward = Qt.Key_Right, backward = Qt.Key_Left
      if (root.mirrored) {
        forward = Qt.Key_Left
        backward = Qt.Key_Right
      }
      switch (event.key) {
      case Qt.Key_Down:
      case Qt.Key_J:
        root.move(1)
        break
      case Qt.Key_Up:
      case Qt.Key_K:
        root.move(-1)
        break
      case Qt.Key_Home:
        root.moveTo(-1)
        break
      case Qt.Key_End:
        root.moveTo(1)
        break
      case Qt.Key_Return:
      case Qt.Key_Enter:
      case Qt.Key_Space:
        root.activate()
        break
      case Qt.Key_L:
      case forward:
        if (root.selectable(root._index) && root._entries[root._index].hasSubmenu)
          root.activate()
        break
      case Qt.Key_H:
      case Qt.Key_Backspace:
      case backward:
        root.leaveSubmenu()
        break
      case Qt.Key_Escape:
        if (!root.leaveSubmenu())
          root.close()
        break
      case Qt.Key_Tab:
      case Qt.Key_Backtab:
        root.close()
        break
      default:
        break
      }
      // The menu has the keys while it is open.
      event.accepted = true
    }

    // Outside the menu: a press closes it, hover reaches nothing below.
    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.AllButtons
      onPressed: function (mouse) {
        mouse.accepted = true
        root.close()
      }
      onWheel: function (wheel) {
        wheel.accepted = true
      }
    }

    Rectangle {
      id: menuPanel
      objectName: "foamyMenuPanel"
      // Place with x even under mirroring: menuX is already resolved.
      LayoutMirroring.enabled: false
      x: overlay.menuX
      y: overlay.menuY
      width: Math.max(0, Math.min(root.menuWidth, overlay.width - overlay.margin * 2))
      height: overlay.menuHeight
      radius: FoamyStyle.radius
      color: FoamyPalette.menuFill
      border.width: FoamyStyle.borderWidth
      border.color: FoamyPalette.menuBorder
      clip: true
      Accessible.role: Accessible.PopupMenu
      Accessible.name: root._parentEntry ? root._parentEntry.text : ""

      // Swallow presses between rows so they don't close the menu.
      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        onWheel: function (wheel) {
          wheel.accepted = false
        }
      }

      Flickable {
        id: scroller
        objectName: "foamyMenuScroller"
        anchors.fill: parent
        anchors.margins: FoamyStyle.menuPadding + FoamyStyle.borderWidth
        contentWidth: width
        contentHeight: list.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        LayoutMirroring.enabled: root.mirrored
        LayoutMirroring.childrenInherit: true

        Column {
          id: list
          width: scroller.width
          Repeater {
            id: rows
            model: root._entries
            Item {
              id: row
              required property var modelData
              required property int index
              readonly property bool separator: !!modelData.separator
              readonly property bool current: root._index === index
              readonly property bool usable: !separator && modelData.enabled !== false
              readonly property bool isBack: modelData === root._back
              width: list.width
              height: separator ? FoamyStyle.gap + 1 : FoamyStyle.rowHeight
              objectName: "foamyMenuRow"
              Accessible.role: separator ? Accessible.Separator : Accessible.MenuItem
              Accessible.name: separator ? "" : String(modelData.text || "")
              Accessible.onPressAction: root.activate(index)

              Rectangle {
                visible: row.separator
                anchors.verticalCenter: parent.verticalCenter
                x: FoamyStyle.gapSmall
                width: parent.width - FoamyStyle.gapSmall * 2
                height: 1
                color: FoamyPalette.divider
              }
              Rectangle {
                visible: !row.separator
                anchors.fill: parent
                radius: FoamyStyle.innerRadius(FoamyStyle.radius, FoamyStyle.menuPadding / 2)
                color: row.current && row.usable ? (row.modelData.destructive ? Qt.alpha(Commons.Color.urgent, 0.14) : FoamyPalette.hoverFill) : "transparent"
                Behavior on color {
                  ColorAnimation {
                    duration: FoamyMotion.hover
                  }
                }
              }
              Row {
                visible: !row.separator
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: FoamyStyle.rowPadding
                anchors.rightMargin: FoamyStyle.rowPadding
                anchors.verticalCenter: parent.verticalCenter
                spacing: FoamyStyle.rowPadding
                opacity: row.usable || row.separator ? 1 : FoamyStyle.disabledOpacity
                readonly property color tone: row.modelData.destructive && row.current ? FoamyPalette.onSurface(Commons.Color.urgent, Qt.tint(FoamyPalette.menuFill, Qt.alpha(Commons.Color.urgent, 0.14))) : FoamyPalette.text
                FoamyIcon {
                  name: row.modelData.iconName || "settings"
                  visible: !!row.modelData.iconName
                  width: FoamyStyle.iconSize
                  height: width
                  anchors.verticalCenter: parent.verticalCenter
                  color: row.modelData.iconColor && row.modelData.iconColor.a > 0 ? row.modelData.iconColor : parent.tone
                  Accessible.ignored: true
                }
                Text {
                  width: parent.width - FoamyStyle.iconSize - parent.spacing - (trailingIcon.visible ? trailingIcon.width + parent.spacing : 0)
                  anchors.verticalCenter: parent.verticalCenter
                  text: String(row.modelData.text || "")
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  horizontalAlignment: Text.AlignLeft
                  color: parent.tone
                  font.family: FoamyStyle.fontFamily
                  font.pixelSize: FoamyStyle.font.body
                  font.weight: row.isBack ? Font.DemiBold : Font.Normal
                }
                FoamyIcon {
                  id: trailingIcon
                  visible: !row.isBack && (row.modelData.hasSubmenu || row.modelData.checked === true)
                  name: row.modelData.hasSubmenu ? "chevron-right" : "check"
                  width: FoamyStyle.iconSize
                  height: width
                  anchors.verticalCenter: parent.verticalCenter
                  color: row.modelData.hasSubmenu ? FoamyPalette.secondaryText : Commons.Color.accent
                  Accessible.ignored: true
                }
              }
              MouseArea {
                anchors.fill: parent
                enabled: !row.separator
                hoverEnabled: true
                cursorShape: row.usable ? Qt.PointingHandCursor : Qt.ArrowCursor
                onEntered: root._pointerHover(this, row.index)
                onPositionChanged: root._pointerHover(this, row.index)
                onClicked: root.activate(row.index)
              }
            }
          }
        }
      }
      FoamyWheelScroll {
        id: menuWheel
        target: scroller
      }
    }
  }
}
