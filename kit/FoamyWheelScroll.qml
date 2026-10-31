// foamy-kit 0.4.0 943bfede8d88625df409d71c4092a4742789fba65af88439bfbf1a79e8fb6a8d — do not edit; change foamy-kit and run sync
import QtQuick

// Normal wheel and touchpad scrolling for a Flickable (ListView, GridView…),
// plus ensureVisible(item).
//
//   Flickable { id: list; … }
//   FoamyWheelScroll { id: wheel; target: list }        // declare it anywhere
//   …
//   onExpandedChanged: if (expanded) wheel.ensureVisible(section)
//
// Why: Qt 6's Flickable turns every wheel event into a short smoothing
// animation that starts from where the content is *now*. A high-resolution
// wheel (most current mice, the Logitech G502 X included) sends a notch as
// several small events (8 x 15 instead of 1 x 120), and each one restarts
// the animation, so a notch moves the list ~28 px instead of 72 (measured on
// Qt 6.12, tests/test_wheel.py). FoamyWheelScroll takes the wheel events
// before the Flickable does and scrolls by the delta itself:
//   - a wheel notch (angleDelta 120) scrolls `notch` px (wheelScrollLines,
//     normally 3, rows of FoamyStyle.rowHeight), however the notch is split;
//     consecutive notches add up (animated by FoamyMotion.slider, instant
//     under reduced motion)
//   - touchpad pixel deltas map 1:1 (no animation)
//   - horizontal-only wheel events and content that fits are left alone, so
//     inner horizontal lists and outer scroll views still get them
//
// FoamySettingsPage uses it; plugin Flickables add one line. `enabled: false`
// hands the wheel back to the Flickable.
//
// ensureVisible(item[, margin]): scroll the least amount that shows `item`
// (a descendant of the Flickable's content), top first when it is taller
// than the view. For a section that expands with an animation call it when
// the expansion starts: it keeps the growing item in view for `followMs`.
QtObject {
  id: root

  property Flickable target: null
  // false hands the wheel back to the Flickable.
  property bool enabled: true
  // One notch (angleDelta 120).
  property real notch: Math.max(1, Qt.styleHints.wheelScrollLines) * FoamyStyle.rowHeight
  property real margin: FoamyStyle.gap
  property int followMs: 450
  // Where an animated scroll is going (NaN when idle). For tests.
  readonly property real destination: animation.running ? animation.to : NaN
  readonly property bool scrollable: !!target && maxY > minY + 0.5

  readonly property real minY: target ? target.originY - target.topMargin : 0
  readonly property real maxY: target
    ? Math.max(minY, target.originY + target.contentHeight + target.bottomMargin - target.height) : 0

  function clamp(y) { return Math.max(minY, Math.min(maxY, y)) }

  // Scroll by `dy` content px. animate: glide there (wheel notches).
  function scrollBy(dy, animate) {
    if (!target || dy === 0) return false
    var from = animation.running ? animation.to : target.contentY
    var to = clamp(from + dy)
    if (Math.abs(to - from) < 0.01 && !animation.running) return false
    scrollTo(to, animate)
    return true
  }

  function scrollTo(y, animate) {
    if (!target) return
    target.cancelFlick()
    var to = clamp(y)
    animation.stop()
    if (animate && FoamyMotion.slider > 0) {
      animation.from = target.contentY
      animation.to = to
      animation.start()
    } else {
      target.contentY = to
    }
  }

  // Handle a wheel event (a WheelEvent, or {angleDelta, pixelDelta} in
  // tests). Returns true when it scrolled.
  function wheel(event) {
    if (!target || !enabled) return false
    var pixel = event.pixelDelta ? event.pixelDelta.y : 0
    var angle = event.angleDelta ? event.angleDelta.y : 0
    if (pixel !== 0) return scrollBy(-pixel, false)
    if (angle !== 0) return scrollBy(-angle / 120 * notch, true)
    return false
  }

  function _place(item, margin) {
    if (!target || !item) return
    var content = target.contentItem
    var ancestor = item
    while (ancestor && ancestor !== content) ancestor = ancestor.parent
    if (!ancestor) return
    var top = item.mapToItem(content, 0, 0).y
    var bottom = top + item.height
    var viewTop = animation.running ? animation.to : target.contentY
    var viewBottom = viewTop + target.height
    var m = margin === undefined ? root.margin : margin
    var y = viewTop
    if (bottom - top + m * 2 > target.height || top < viewTop + m) y = top - m
    else if (bottom > viewBottom - m) y = bottom - target.height + m
    if (Math.abs(clamp(y) - target.contentY) > 0.5) scrollTo(y, true)
  }

  property var _following: null
  property var _followMargin: undefined
  function _refollow() { if (root._following) root._place(root._following, root._followMargin) }

  function ensureVisible(item, margin) {
    if (!target || !item) return
    if (_following && _following !== item) _following.heightChanged.disconnect(_refollow)
    if (_following !== item) item.heightChanged.connect(_refollow)
    _following = item
    _followMargin = margin
    followTimer.restart()
    _place(item, margin)
  }

  property Timer _followTimer: Timer {
    id: followTimer
    interval: root.followMs
    onTriggered: {
      if (root._following) root._following.heightChanged.disconnect(root._refollow)
      root._following = null
    }
  }

  property NumberAnimation _animation: NumberAnimation {
    id: animation
    target: root.target
    property: "contentY"
    duration: FoamyMotion.slider
    easing.type: Easing.OutCubic
  }

  // The handler lives in the Flickable's content item: the content (sliders,
  // nested lists) still sees the wheel first, and the Flickable never gets a
  // wheel event while we can scroll.
  property WheelHandler _handler: null
  property Component _handlerComponent: Component {
    WheelHandler {
      target: null
      enabled: root.enabled && root.scrollable && root.target !== null && root.target.interactive
      orientation: Qt.Vertical
      acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
      onWheel: function(event) { root.wheel(event) }
    }
  }
  function _attach() {
    if (_handler) { _handler.destroy(); _handler = null }
    if (target) _handler = _handlerComponent.createObject(target)
  }
  onTargetChanged: _attach()
  Component.onCompleted: if (target && !_handler) _attach()
}
