// foamy-kit 0.3.3 9ab3d2c41900d56f7ea39d8c0a12d839724ffb0c90f07a6efd69ff0bbc46861e — do not edit; change foamy-kit and run sync
import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The foamy bar-widget popup: the host's own qs.Ui.KeyboardPanel with the
// foamy surface applied from outside. Because it IS the stock panel, it gets
// the host's behaviour on each version for free:
//   4.5  bar strip from bar.barSizeFor(screen)/bar.barSize (the bar window
//        is full-screen), grow-from-0.97 open, same-section morph, height
//        growth, reduced motion, RTL mirroring, focus priming
//   4.0  bar strip from the bar window, 140 ms fade
// and the layer namespace stays "omarchy-keyboard-panel", so Hyprland layer
// rules aimed at stock panels apply to foamy ones too.
//
// What the wrapper adds:
//   - foamy radius and 1px alpha(text, .15) border (DESIGN.md)
//   - `body`: lazy content on 4.0 and 4.5 alike (built on first open, kept)
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
//   maxHeight: real              height cap for the fitted card (default
//                                FoamyStyle.popupMaxHeight 640; 0 = only the
//                                screen limit, for panels that compact
//                                themselves by screen height)
//   contentWidth/contentHeight   override the defaults if needed
//   cornerRadius, surfaceColor   foamy surface (rarely overridden)
//   cardItem                     the drawn card (for screenshots/tests)
//   fittedContentWidth/Height(), availableCardHeight, barThickness (4.5)
//   focusTarget                  defaults to the body; point it at a PanelKeyCatcher
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
  property real maxHeight: FoamyStyle.popupMaxHeight
  property real cornerRadius: FoamyStyle.radius
  property color surfaceColor: Commons.Color.popups.background

  property Component body: null
  property bool bodyRequested: false
  readonly property Item bodyItem: bodyLoader.item
  readonly property real bodyImplicitHeight: bodyItem ? bodyItem.implicitHeight : 0
  readonly property Item cardItem: surfaceHook.card

  function ensureBody() {
    if (body) bodyRequested = true
    return bodyLoader.item
  }

  padding: 0
  borderSpec: FoamyStyle.popupBorderSpec
  contentWidth: fittedContentWidth(wide ? FoamyStyle.popupWidthWide : FoamyStyle.popupWidth)
  contentHeight: fittedContentHeight(bodyImplicitHeight, maxHeight)
  focusTarget: bodyLoader

  onOpenChanged: if (open && body) bodyRequested = true

  Loader {
    id: bodyLoader
    anchors.fill: parent
    focus: true
    active: !!root.body && (root.open || root.bodyRequested)
    sourceComponent: root.body
    // 4.5 already mirrors the card content; 4.0 has no language support, so
    // this only matters there if a future 4.0 point release adds one.
    LayoutMirroring.enabled: FoamyI18n.rightToLeft
    LayoutMirroring.childrenInherit: true
  }

  // KeyboardPanel draws the card with Style.cornerRadius and the popup
  // background and does not expose either. The card is the parent of the
  // item holding our children on both 4.0 and 4.5, so bind its radius and
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
        candidate.radius = Qt.binding(function() { return root.cornerRadius })
        candidate.color = Qt.binding(function() { return root.surfaceColor })
      } else {
        console.warn("FoamyPopup: host card not found; keeping the stock radius")
      }
    }
  }
}
