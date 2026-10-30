// foamy-kit 0.3.3 6d958db7c8f083e7e73e36c9975c9652ef2e10672fcb325d3cd2956a4b77e9d1 — do not edit; change foamy-kit and run sync
import QtQuick
import "FoamyIpcResolver.js" as Resolver

// Keeps one FoamyIpc first for its target in 4.5's IpcRegistry, so the
// omarchy-shell socket answers from it even when another service registers
// the same target (foamy-lock vs the stock omarchy.lock on target "lock").
// IpcRegistry has no change signal, so it re-claims on start, on recheck(),
// and every `interval` ms while another handler shares the target (one short
// array scan; 0 turns the timer off). With no rival it doesn't poll: a
// handler registered later queues behind this one anyway. Call recheck()
// when you need a fresh `others` count (e.g. in a status reply). 4.0 has no registry: `answering` stays
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
    running: preference.active && preference.interval > 0 && preference.handler !== null && preference.others > 0
    onTriggered: preference.recheck()
  }
}
