// foamy-kit 0.3.0 05c9e00f38dbd113a8d632ad7330cd4e65f1518dcf1feb676122e8e0790a14d5 — do not edit; change foamy-kit and run sync
import QtQuick
import "FoamyIpcResolver.js" as Resolver

// Keeps one FoamyIpc first for its target in 4.5's IpcRegistry, so the
// omarchy-shell socket answers from it even when another service registers
// the same target (foamy-lock vs the stock omarchy.lock on target "lock").
// IpcRegistry has no change signal, so it re-claims on start, on recheck(),
// and every `interval` ms on 4.5 (one short array scan; 0 turns the timer
// off and leaves re-claiming to recheck()). 4.0 has no registry: `answering` stays
// false and nothing happens.
//
//   FoamyIpc { id: lockIpc; target: "lock"; … }
//   FoamyIpcPreference { id: lockRoute; handler: lockIpc }
//   // lockRoute.others > 0 → report a conflict
QtObject {
  id: preference

  property var handler: null
  property bool active: true
  property int interval: 5000
  // Other enabled handlers for the same target, at the last check.
  property int others: 0
  // Whether `handler` answered the target at the last check.
  property bool answering: false

  function recheck() {
    if (!active || !handler) return
    answering = Resolver.prefer(preference, handler)
    others = Resolver.others(preference, handler).length
  }

  onHandlerChanged: Qt.callLater(recheck)
  onActiveChanged: Qt.callLater(recheck)
  Component.onCompleted: Qt.callLater(recheck)

  property Timer timer: Timer {
    interval: Math.max(250, preference.interval)
    repeat: true
    running: preference.active && preference.interval > 0 && preference.handler !== null && Resolver.fastPath(preference)
    onTriggered: preference.recheck()
  }
}
