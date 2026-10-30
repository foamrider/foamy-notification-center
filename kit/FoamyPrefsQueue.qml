// foamy-kit 0.3.2 dc9fa4a470494b87550314bf840121ae124fef5f929ea7ce276fc86ca1eb58a1 — do not edit; change foamy-kit and run sync
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
    if (inFlight || waiting.length > 0) {
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
    if (result.inline) {
      saved(key, value)
      Qt.callLater(advance)
      return true
    }
    current = { key: key, value: value, hadPrevious: hadPrevious, previous: previous }
    inFlight = true
    proc.command = result.command
    proc.running = true
    return true
  }

  function advance() {
    if (inFlight || waiting.length === 0) return
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

  property Process proc: Process {
    stderr: StdioCollector { id: stderrText }
    onExited: function(code) {
      var done = queue.current
      queue.current = null
      queue.inFlight = false
      if (code === 0) {
        if (done) {
          var since = Prefs.overlay({}, queue.pendingSince)
          since[done.key] = Date.now()
          queue.pendingSince = since
          queue.saved(done.key, done.value)
        }
      } else if (done) {
        // Back to what was saved before this attempt.
        if (done.hadPrevious) {
          var restored = Prefs.overlay({}, queue.pending)
          restored[done.key] = done.previous
          queue.pending = restored
        } else {
          queue.dropPending(done.key)
        }
        queue.error = "Couldn't save the setting."
        queue.lastFailed = done
        console.warn("foamy-kit: saving " + done.key + " failed: " + String(stderrText.text || "").trim())
        queue.failed(done.key, done.value, queue.error)
      }
      Qt.callLater(queue.advance)
    }
  }
}
