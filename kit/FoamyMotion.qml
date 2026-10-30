pragma Singleton
// foamy-kit 0.3.3 79218200ee2dbe5d1bdfd6ef41768bce029e136f8640f8f5f0833a97d8371d5a — do not edit; change foamy-kit and run sync
import QtQuick
import qs.Commons

// Every foamy duration goes through here. On 4.5, Style.duration(ms) returns
// 0 while animations are off (`omarchy toggle animations`, reduced motion,
// CPU rendering) and Style.reduceMotion says so; 4.0 has neither, so motion
// is always on there. Looping animations must also check reduceMotion:
//
//   NumberAnimation { duration: FoamyMotion.hover }
//   RotationAnimation on rotation {
//     running: root.busy && root.visible && !FoamyMotion.reduceMotion
//     duration: FoamyMotion.spin; loops: Animation.Infinite
//   }
QtObject {
  readonly property bool reduceMotion: Style.reduceMotion === true
  readonly property var easeOut: Style.easeOut !== undefined ? Style.easeOut : [0.23, 1.0, 0.32, 1.0, 1.0, 1.0]

  function duration(ms) {
    if (typeof Style.duration === "function") return Style.duration(ms)
    return reduceMotion ? 0 : ms
  }

  // Named durations (ms), matched to the 4.5 motion guide. Nothing over 300.
  readonly property int hover: duration(100)
  readonly property int press: duration(160)
  readonly property int toggle: duration(120)
  readonly property int slider: duration(140)
  readonly property int fadeIn: duration(180)
  readonly property int fadeOut: duration(120)
  readonly property int grow: duration(200)
  readonly property int morph: duration(220)
  readonly property int slow: duration(300)
  // Loop periods. A loop never runs under reduced motion, so these are not
  // scaled; guard the loop's `running` with !reduceMotion instead.
  readonly property int spin: 800
  readonly property int pulse: 1200

  // True when a looping animation may run for an item that is `shown`.
  function loopAllowed(shown) { return !!shown && !reduceMotion }
}
