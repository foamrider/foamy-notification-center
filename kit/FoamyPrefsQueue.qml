// foamy-kit 0.9.0 a7f61051a5f703d35cc890a4304bd761fb53f4e8cd0895357bdda7121310b7b9 — do not edit; change foamy-kit and run sync
import QtQuick
import Quickshell.Io
import "FoamyPrefs.js" as Prefs

// One panel's settings saves, in order, never lost.
//
//   FoamyPrefsQueue {
//     id: prefs
//     bar: root.bar
//     moduleName: root.moduleName
//     fields: Schema.fields
//     settings: root.settings
//   }
//   readonly property bool showCount: prefs.value("showCount")      // reads saved values at once
//   FoamyToggle { checked: prefs.value("showCount"); onClicked: prefs.save("showCount", !checked) }
//   FoamySettingsPage { saving: prefs.saving; error: FoamyI18n.t(prefs.error); retryable: prefs.canRetry; onRetry: prefs.retry() }
//
// - Saves go inline (bar.shell.updateEntryInline) when the host allows it,
//   else through the CLI (FoamyPrefs.saveCommand), one process at a time.
// - While a CLI save runs, later saves wait; only the newest value per key
//   is kept.
// - A CLI save fails (rolled back, retryable) when its command exits non-zero,
//   can't start (Quickshell then emits no exited(), only running -> false),
//   is stopped, or runs past saveTimeoutMs. Every one of these ends in
//   finish(), so `saving` always clears. At most stderrLimit characters of
//   its stderr are kept for the log.
// - A CLI save runs in its own process group (FoamyPrefs.bounded): at
//   saveTimeoutMs the whole group is SIGKILLed, and so is what's left of it
//   when the save is stopped by a signal or the queue is destroyed. The next
//   save starts only after that, so a timed-out save can't write late.
// - Each save merges over `effectiveSettings` (settings + values saved but
//   not yet reflected back), so two quick saves never undo each other.
// - A pending value is dropped once `settings` shows it, or after
//   reflectTimeoutMs if the host never does (then the host's value wins).
// - error is an English message for FoamyI18n.t(): "That value isn't
//   allowed.", "Couldn't save the setting." or the field's validate() text.
QtObject {
  id: queue

  property QtObject bar: null
  property string moduleName: ""
  property var fields: []
  property var settings: ({})
  property int reflectTimeoutMs: 10000
  // A CLI save normally takes well under a second (4.0's `qs ipc call` a few).
  property int saveTimeoutMs: 20000
  readonly property int stderrLimit: 4096

  property var pending: ({})
  readonly property var effectiveSettings: Prefs.overlay(settings, pending)
  readonly property bool saving: inFlight
  property bool inFlight: false
  readonly property bool busy: saving || waiting.length > 0
  property string error: ""
  property var lastFailed: null
  readonly property bool canRetry: lastFailed !== null && !busy

  // Waiting saves: [{ key, value }], newest value per key.
  property var waiting: []
  property var current: null
  property var pendingSince: ({})
  property string stderrHead: ""
  property double startedAt: 0
  // Kills the running save's process group (FoamyPrefs.killGroupCommand);
  // [] when there is none. Kept ready for Component.onDestruction.
  property var groupKill: []
  property bool reaping: false

  signal saved(string key, var value)
  signal failed(string key, var value, string error)

  function value(key) { return Prefs.value(fields, effectiveSettings, key) }
  function values() { return Prefs.values(fields, effectiveSettings) }

  function save(key, value) {
    var issue = Prefs.problem(fields, key, value)
    if (issue) {
      error = issue
      failed(key, value, issue)
      return false
    }
    error = ""
    lastFailed = null
    // proc.running / reaping: a stopped save whose processes aren't gone yet.
    if (inFlight || waiting.length > 0 || proc.running || reaping) {
      var next = waiting.filter(function(item) { return item.key !== key })
      next.push({ key: key, value: value })
      waiting = next
      return true
    }
    return run(key, value)
  }

  function retry() {
    if (!lastFailed) return false
    var failedSave = lastFailed
    return save(failedSave.key, failedSave.value)
  }

  function setPending(key, value) {
    var next = Prefs.overlay({}, pending)
    next[key] = value
    pending = next
    var since = Prefs.overlay({}, pendingSince)
    since[key] = Date.now()
    pendingSince = since
    expiry.restart()
  }

  function dropPending(key) {
    if (!(key in pending)) return
    var next = Prefs.overlay({}, pending)
    delete next[key]
    pending = next
  }

  function run(key, value) {
    var result = Prefs.save(bar, moduleName, fields, settings, key, value, pending)
    if (!result.ok) {
      error = result.error
      lastFailed = { key: key, value: value }
      failed(key, value, result.error)
      Qt.callLater(advance)
      return false
    }
    if (!result.changed) {
      saved(key, value)
      Qt.callLater(advance)
      return true
    }
    var hadPrevious = key in pending
    var previous = pending[key]
    setPending(key, value)
    // 4.5 reflects an inline save synchronously: `settings` already changed
    // inside Prefs.save(), before this value became pending, so settle now or
    // it would mask later outside changes and be written back by the next save.
    pending = Prefs.settle(settings, pending)
    if (result.inline) {
      saved(key, value)
      Qt.callLater(advance)
      return true
    }
    current = { key: key, value: value, hadPrevious: hadPrevious, previous: previous }
    inFlight = true
    stderrHead = ""
    groupKill = []
    startedAt = Date.now()
    deadline.restart()
    proc.command = Prefs.bounded(result.command, saveTimeoutMs)
    proc.running = true
    return true
  }

  // The one way a CLI save ends: exited, failed to start, stopped, timed out.
  // Later calls for the same attempt (running -> false after exited(), the
  // exit of a command killed at the deadline) find nothing in flight.
  function finish(ok, detail) {
    if (!inFlight) return
    deadline.stop()
    var done = current
    current = null
    inFlight = false
    if (ok) {
      if (done) {
        var since = Prefs.overlay({}, pendingSince)
        since[done.key] = Date.now()
        pendingSince = since
        saved(done.key, done.value)
      }
    } else if (done) {
      // Back to what was saved before this attempt.
      if (done.hadPrevious) {
        var restored = Prefs.overlay({}, pending)
        restored[done.key] = done.previous
        pending = restored
      } else {
        dropPending(done.key)
      }
      error = "Couldn't save the setting."
      lastFailed = done
      var output = stderrHead.trim()
      console.warn("foamy-kit: saving " + done.key + " failed (" + detail + ")" + (output ? ": " + output : ""))
      failed(done.key, done.value, error)
    }
    Qt.callLater(advance)
  }

  // SIGKILL the save's whole process group (before its leader is reaped, or
  // while any member is left, its id can't belong to anyone else).
  function killGroup() {
    var command = groupKill
    groupKill = []
    if (command.length === 0) return
    reaping = true
    reaper.command = command
    reaper.running = true
  }

  function keepStderr(data) {
    if (stderrHead.length < stderrLimit) stderrHead += String(data).slice(0, stderrLimit - stderrHead.length)
  }

  function advance() {
    if (inFlight || proc.running || reaping || waiting.length === 0) return
    var next = waiting[0]
    waiting = waiting.slice(1)
    run(next.key, next.value)
  }

  onSettingsChanged: pending = Prefs.settle(settings, pending)

  property Timer expiry: Timer {
    interval: 1000
    repeat: true
    running: Object.keys(queue.pending).length > 0
    onTriggered: {
      var now = Date.now()
      for (var key in queue.pending)
        if (!queue.inFlight && now - (queue.pendingSince[key] || 0) > queue.reflectTimeoutMs) queue.dropPending(key)
    }
  }

  // Backstop: `timeout` in the save's own group normally ends it at
  // saveTimeoutMs. If it didn't, kill the group from here (SIGKILL:
  // running = false only sends SIGTERM, which a stuck command may ignore).
  property Timer deadline: Timer {
    interval: Math.max(1, queue.saveTimeoutMs) + 2000
    onTriggered: {
      queue.killGroup()
      if (queue.proc.running) queue.proc.signal(9)
      queue.finish(false, "no exit after " + queue.saveTimeoutMs + " ms")
    }
  }

  // Destroyed mid-save (the panel went away): Quickshell kills only the
  // group leader and emits nothing, so kill the rest of the group (a
  // detached kill, as the queue is going) and let go. No JS globals here.
  Component.onDestruction: {
    deadline.stop()
    if (inFlight && groupKill.length > 0) {
      reaper.command = groupKill
      reaper.startDetached()
    }
    groupKill = []
    current = null
    inFlight = false
    waiting = []
  }

  property Process reaper: Process {
    onRunningChanged: {
      if (running) return
      queue.reaping = false
      Qt.callLater(queue.advance)
    }
  }

  property Process proc: Process {
    // Chunks as they arrive (no split), so only stderrLimit is ever kept.
    stderr: SplitParser {
      splitMarker: ""
      onRead: function(data) { queue.keepStderr(data) }
    }
    onStarted: queue.groupKill = Prefs.killGroupCommand(processId)
    onExited: function(code, status) {
      // timeout --signal=KILL kills its own group, itself included: signal 9.
      var timedOut = status !== 0 && code === 9 && Date.now() - queue.startedAt >= queue.saveTimeoutMs
      // Stopped by a signal: children that ignored it may still run.
      if (status !== 0) queue.killGroup()
      queue.finish(code === 0 && status === 0,
                   timedOut ? "no exit after " + queue.saveTimeoutMs + " ms" : status === 0 ? "exit " + code : "stopped by signal " + code)
    }
    // After exited() this finds nothing in flight. Without exited() before it
    // (missing or non-executable command) the save never started.
    onRunningChanged: {
      if (running) return
      queue.finish(false, "the command couldn't start")
      Qt.callLater(queue.advance)
    }
  }
}
