// foamy-kit 0.15.2 fc80b2184a8c65ad07a3d9a1d88a6a29d825265aed14e2b0779f2335c310cb1c — do not edit; change foamy-kit and run sync
import QtQuick
import qs.Commons as Commons
import qs.Ui

// The foamy bar-widget popup: the host's own qs.Ui.KeyboardPanel with the
// foamy surface applied from outside. Because it IS the stock panel, it gets
// the host's behaviour for free: bar strip from bar.barSizeFor(screen)/
// bar.barSize (the bar window is full-screen), grow-from-0.97 open,
// same-section morph, height growth, reduced motion, RTL mirroring, focus
// priming; and the layer namespace stays "omarchy-keyboard-panel", so Hyprland layer
// rules aimed at stock panels apply to foamy ones too.
//
// What the wrapper adds:
//   - foamy radius and 1px alpha(text, .15) border (DESIGN.md)
//   - `body`: lazy content (built on first open, kept)
//   - default widths (420, or 560 with `wide`) and height fitted to the body
//
// API (everything KeyboardPanel has, plus):
//   required anchorItem, bar     the bar button and the widget's `bar`
//   owner                        the Panel (its close()/popoutSwitchClosing are used)
//   open                         bind to the panel's opened state
//   body: Component              lazy content; reach it as `bodyItem`
//   bodyItem, bodyImplicitHeight the built body (null until first open)
//   ensureBody()                 build the body without opening
//   wide: bool                   560 instead of 420
//   maxHeight: real              extra height cap for the fitted card. Default
//                                0: the card grows with its content up to the
//                                screen's available height (screen minus the
//                                bar, the gap and a margin; the host measures
//                                it from the bar thickness), so content fits
//                                where the screen
//                                allows and scrolls only beyond that. Set a
//                                number (e.g. FoamyStyle.popupMaxHeight, 640)
//                                to cap it lower.
//   contentWidth/contentHeight   override the defaults if needed
//   cornerRadius, surfaceColor   foamy surface (rarely overridden)
//   cardItem                     the drawn card (for screenshots/tests)
//   fittedContentWidth/Height(), availableCardHeight, barThickness (4.5)
//   menuReserve                  height an open FoamyMenu needs (the default
//                                contentHeight grows to it while the menu is open)
//   focusTarget                  defaults to the body; point it at a PanelKeyCatcher
//
// Click-away: a click on the body's empty space (where nothing takes the
// press) takes the keys from a focused text field and gives them back to
// `focusTarget` (to the body item while focusTarget is the default), or to
// a nearer `foamyKeyHome` (FoamyClickAway). Flickables get the same through
// FoamyWheelScroll.
//
// Keys of an item that hides: when the item in the body that has the keys
// hides (a settings page left with Back, or reset when the popup closes on
// it: FoamySettingsState), they go to the nearest key home that shows: a
// settings page that still shows (its Retry hid as the retry started),
// else the same key home as a click-away. So Esc and the panel's keys work
// at once and on the next open. A plugin needs no onHidden refocus; one it
// keeps (an item of its own, at once or later) still wins. The popup learns
// the item with the keys from its window's activeFocusItem, which Qt keeps
// only in the active window: on the desktop the popup's window is active
// (the host's KeyboardPanel takes the keyboard on every open). A test that
// runs the popup in a window that is not active, or in none, puts it in a
// window and activates it first (window.requestActivate(), then wait until
// window.active).
//
// Usage:
//   FoamyPopup {
//     id: popup
//     anchorItem: button; bar: root.bar; owner: root; open: root.opened
//     body: Component {
//       PanelKeyCatcher { … }
//     }
//   }
//
// Children declared directly (no `body`) still work but are built eagerly.
// Do not override borderSpec/padding per plugin; DESIGN.md owns them.
KeyboardPanel {
  id: root

  property bool wide: false
  property real maxHeight: 0
  property real cornerRadius: FoamyStyle.radius
  property color surfaceColor: Commons.Color.popups.background

  property Component body: null
  property bool bodyRequested: false
  readonly property Item bodyItem: bodyLoader.item
  readonly property real bodyImplicitHeight: bodyItem ? bodyItem.implicitHeight : 0
  // Room an open FoamyMenu asks for below its button (0 when none is open).
  // Include it if you override contentHeight: Math.max(body, menuReserve).
  readonly property real menuReserve: bodyLoader.foamyMenuReserve
  readonly property Item cardItem: surfaceHook.card

  function ensureBody() {
    if (body)
      bodyRequested = true
    return bodyLoader.item
  }

  padding: 0
  borderSpec: FoamyStyle.popupBorderSpec
  contentWidth: fittedContentWidth(wide ? FoamyStyle.popupWidthWide : FoamyStyle.popupWidth)
  // An open FoamyMenu may ask for room below its button (foamyMenuReserve)
  // when it fits neither below nor above it: the card grows while it is
  // open (FoamyMenu.maxGrowHeight of menu at most; past it the menu scrolls).
  contentHeight: fittedContentHeight(Math.max(bodyImplicitHeight, bodyLoader.foamyMenuReserve), maxHeight)
  focusTarget: bodyLoader

  onOpenChanged: if (open && body)
    bodyRequested = true

  // Under the body: only a press nothing in it takes reaches it.
  FoamyClickAway {
    anchors.fill: parent
  }

  Loader {
    id: bodyLoader
    property real foamyMenuReserve: 0
    // Where a click-away gives the keys back (FoamyClickAway).
    readonly property Item foamyKeyHome: root.focusTarget === bodyLoader ? root.bodyItem : root.focusTarget
    anchors.fill: parent
    focus: true
    active: !!root.body && (root.open || root.bodyRequested)
    sourceComponent: root.body
  }

  // Qt keeps the keys on an item that hides, and the host's focus on the
  // next open goes back to it: a settings page left with Back, or closed
  // with the popup, kept Esc and the arrows while the panel showed its list.
  // When the item in the body that has the keys hides, it lets go and the
  // nearest key home that shows takes them (a settings page that still
  // shows, else the body's). A plugin's own refocus, at once or later,
  // still wins: it moves the keys to an item that shows.
  property Item _keysAt: null
  property Connections _keysWatch: Connections {
    target: bodyLoader.Window
    function onActiveFocusItemChanged() {
      var item = bodyLoader.Window.activeFocusItem
      if (item && root._inBody(item))
        root._keysAt = item
    }
  }
  property Connections _keysHide: Connections {
    target: root._keysAt
    function onVisibleChanged() {
      if (root._keysAt && !root._keysAt.visible)
        Qt.callLater(root._reclaimKeys)
    }
  }
  function _inBody(item) {
    for (let at = item; at; at = at.parent)
      if (at === bodyLoader)
        return true
    return false
  }
  // The nearest key home above `item` that shows, up to the body's: a
  // settings page that still shows keeps the keys of a Retry that hid on it.
  function _keyHome(item) {
    for (let at = item; at; at = at.parent) {
      if ("foamyKeyHome" in at && at.foamyKeyHome && at.foamyKeyHome.visible)
        return at.foamyKeyHome
      if (at === bodyLoader)
        break
    }
    return null
  }
  function _reclaimKeys() {
    var held = _keysAt
    if (!held || held.visible || !_inBody(held))
      return
    var home = _keyHome(held)
    if (!home)
      return
    // The hidden items let go first: a home that is a focus scope (the
    // settings page) would hand the keys straight back to the hidden item.
    for (let at = held; at && !at.visible; at = at.parent)
      at.focus = false
    home.forceActiveFocus()
  }

  // KeyboardPanel draws the card with Style.cornerRadius and the popup
  // background and does not expose either. The card is the parent of the
  // item holding our children, so bind its radius and
  // colour from here. If a future host changes that, the panel keeps the
  // stock radius and says so once.
  Item {
    id: surfaceHook
    property Item card: null
    visible: false
    Component.onCompleted: {
      var candidate = parent ? parent.parent : null
      if (candidate && "borderSpec" in candidate && "contentTopInset" in candidate && "radius" in candidate) {
        card = candidate
        candidate.radius = Qt.binding(function () {
          return root.cornerRadius
        })
        candidate.color = Qt.binding(function () {
          return root.surfaceColor
        })
      } else {
        console.warn("FoamyPopup: host card not found; keeping the stock radius")
      }
    }
  }
}
