// foamy-kit 0.3.4 9560787e2fe14c573f84942540ba4c4686cde246420984419379ed8769a77697 — do not edit; change foamy-kit and run sync
import QtQuick
import "FoamyIpcResolver.js" as Resolver

// Keeps one FoamyIpc first for its target in 4.5's IpcRegistry, so the
// omarchy-shell socket answers from it even when another service registers
// the same target (foamy-lock vs the stock omarchy.lock on target "lock").
// IpcRegistry keeps its handlers in a plain array mutated in place, so it has
// no change signal to react to. The preference therefore re-claims on start,
// on recheck(), and every `interval` ms for as long as it is active on 4.5 —
// whether or not a rival was seen at the last check, because a handler can
// be registered or moved ahead at any time (a hijacked "lock" route is a
// security problem, not a cosmetic one). The check is one short array scan.
// `interval: 0` turns the timer off; only do that for targets where losing
// first place is harmless. Call recheck() for a fresh `others` count. 4.0 has no registry: `answering` stays
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
