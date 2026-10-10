import QtQuick
import Quickshell
import Quickshell.Io
import "." as Plugin
import "Model.js" as Model
import "components"

// The archive, mounted once for the shell.
//
// Omarchy builds a bar per monitor. If the watcher and the in-memory list
// lived on the widget, each screen would have its own lastSeen and its own
// entries, and marking read or clearing on one would leave the other as it
// was. The on-disk store is already shared; this is the QML owner of the
// processes that talk to it.
Item {
  id: root
  width: 0
  height: 0
  visible: false

  property var shell: null
  property var manifest: null
  property var pluginRegistry: null
  property var barWidgetRegistry: null
  property string omarchyPath: ""

  property int keepDays: 30
  property int maxItems: 1000
  property bool showPreview: true
  property int pageSize: 500

  BrowserIcons { id: browserIcons; onUpdated: root.browserIconsUpdated() }
  signal browserIconsUpdated()
  function faviconSource(row) { return row ? browserIcons.source(row) : "" }
  function warmBrowserIcons(rows) { browserIcons.warm(rows) }

  property var entries: []
  // Keep removals authoritative while watcher events and older reads drain.
  // The disk store retains the same tombstones across shell restarts.
  property var removedKeys: ({})
  property double lastSeen: 0
  property bool loaded: false
  property bool loadPending: false
  property string loadError: ""
  property int archiveRevision: 0
  property int listRevision: 0
  property int listLoadCount: 0
  property string removalError: ""
  property var pendingRemovalKeys: []
  property var activeRemovalKeys: []

  readonly property bool watching: watchProc.running

  readonly property var unreadState: Model.unreadState(entries, lastSeen)
  readonly property int unread: unreadState.unread
  readonly property bool hasCriticalUnread: unreadState.hasCriticalUnread

  readonly property string script:
    Qt.resolvedUrl("bin/notification-center").toString().replace(/^file:\/\//, "")

  readonly property var storeEnvironment: ({
    "NC_KEEP_DAYS": String(root.keepDays),
    "NC_MAX_ITEMS": String(root.maxItems),
    "NC_PREVIEWS": root.showPreview ? "1" : "0"
  })

  property string focusError: ""
  property var focusEntry: null
  property bool invokingDefault: false
  signal focusCompleted()

  function focusNotification(row, useDefault) {
    if (focusProc.running || !row || !/^[0-9]+-[0-9]+$/.test(String(row.key))) return
    focusError = ""
    focusEntry = row
    if (useDefault === false) { focusSendingApp(); return }
    invokingDefault = true
    // Probe the running daemon, not an installed plugin that may be disabled.
    focusProc.command = ["omarchy-shell", "foamy.notifications", "invokeDefault", String(row.key)]
    focusProc.running = true
  }

  function focusSendingApp() {
    invokingDefault = false
    // The stock helper treats names as regexes; allow only literal app names.
    if (!/^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$/.test(focusEntry.app)) {
      focusError = "Could not identify the sending app."
      focusEntry = null
      return
    }
    var directory = root.omarchyPath || Quickshell.env("OMARCHY_PATH")
    focusProc.command = [directory + "/bin/omarchy-hyprland-focus-app", focusEntry.app.replace(/\./g, "\\.")]
    focusProc.running = true
  }

  function finishFocus(exitCode, exitStatus, output) {
    var succeeded = exitCode === 0 && exitStatus === 0
    if (invokingDefault) {
      var result = String(output || "").trim()
      if (succeeded && result === "busy") {
        focusError = "This notification is already being opened. Try again."
        focusEntry = null
        return
      }
      if (!succeeded || result !== "invoked") {
        // Stock/older daemons and expired callbacks all use the stock fallback.
        focusSendingApp()
        return
      }
      // The daemon owns durable handling of its callback and acknowledges removal.
      root.focusCompleted()
      focusEntry = null
      return
    }
    if (succeeded) { root.remove(focusEntry.key); root.focusCompleted() }
    else {
      focusError = "Could not focus the sending app. Open the app and try again."
      console.warn("Notification focus failed:", exitCode, exitStatus)
    }
    focusEntry = null
  }

  Process {
    id: focusProc
    stdout: StdioCollector { id: focusOutput }
    stderr: StdioCollector {}
    onExited: function(exitCode, exitStatus) { root.finishFocus(exitCode, exitStatus, focusOutput.text) }
  }

  signal entryAdded(var entry)
  signal entriesReset()

  function storeCommand(args) {
    return [root.script].concat(args)
  }

  function differsFrom(data) {
    return JSON.stringify(data) !== JSON.stringify(entries)
  }

  function load() {
    if (listProc.running) { loadPending = true; return }
    loadPending = false
    listRevision = archiveRevision
    listLoadCount++
    listProc.command = root.storeCommand(["list", String(root.pageSize)])
    listProc.running = true
  }

  function readSeen() {
    if (seenProc.running) return
    seenProc.command = root.storeCommand(["seen"])
    seenProc.running = true
  }

  function markSeen() {
    var stamp = Date.now()
    root.lastSeen = stamp
    if (markProc.running) return
    markProc.command = root.storeCommand(["seen", String(stamp)])
    markProc.running = true
  }

  function remove(key) {
    removeMany([key])
  }

  function removeMany(keys) {
    var queued = pendingRemovalKeys.slice()
    for (var i = 0; i < keys.length; i++) {
      var key = String(keys[i] || "")
      if (!key || removedKeys[key]) continue
      removedKeys[key] = true
      queued.push(key)
    }
    if (queued.length === pendingRemovalKeys.length) return
    // Capture exact keys before watcher updates; later arrivals from the same app survive.
    pendingRemovalKeys = queued
    entries = visibleEntries(entries)
    entriesReset()
    startRemoval()
  }

  function startRemoval() {
    if (removeProc.running || pendingRemovalKeys.length === 0) return
    activeRemovalKeys = pendingRemovalKeys
    pendingRemovalKeys = []
    removalError = ""
    removeProc.command = storeCommand(["remove"].concat(activeRemovalKeys))
    removeProc.running = true
  }

  Process {
    id: removeProc
    stderr: StdioCollector { id: removeErrors }
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0 || exitStatus !== 0) {
        // Release failed tombstones so a reload can restore entries for a retry.
        for (var i = 0; i < root.activeRemovalKeys.length; i++)
          delete root.removedKeys[root.activeRemovalKeys[i]]
        root.removalError = "Could not dismiss notifications. Try again."
        console.warn("Notification dismissal failed:", removeErrors.text)
        root.load()
      } else root.releaseNotificationActions(root.activeRemovalKeys)
      root.activeRemovalKeys = []
      root.startRemoval()
    }
  }

  function releaseNotificationActions(keys) {
    // Stock and older daemons have no retained actions; cleanup is optional IPC.
    for (var i = 0; i < keys.length; i += 100)
      Quickshell.execDetached(["omarchy-shell", "-q", "foamy.notifications", "releaseHistory", keys.slice(i, i + 100).join(",")])
  }

  // Ordinary plugins use the public IPC commands, not the bar-only service proxy.
  property bool doNotDisturb: false
  property bool dndKnown: false
  property string dndError: ""
  readonly property bool dndBusy: dndProc.running

  function refreshDnd() {
    if (dndProc.running) { dndRefresh.restart(); return }
    dndProc.command = ["omarchy-shell", "notifications", "dndState"]
    dndProc.running = true
  }

  function toggleDnd() {
    if (dndProc.running) return
    // Toggle in the daemon so a concurrent external change cannot invert stale UI state.
    dndProc.command = ["omarchy-shell", "notifications", "toggleDnd"]
    dndProc.running = true
  }

  function applyDndResult(exitCode, exitStatus, output) {
    var state = String(output || "").trim()
    if (exitCode === 0 && exitStatus === 0 && (state === "on" || state === "off")) {
      doNotDisturb = state === "on"
      dndKnown = true
      dndError = ""
      return
    }
    dndError = "Could not update notification silencing. Try again."
    console.warn("Notification silencing command failed:", exitCode, exitStatus)
  }

  Process {
    id: dndProc
    stdout: StdioCollector { id: dndOutput }
    stderr: StdioCollector {}
    onExited: function(exitCode, exitStatus) { root.applyDndResult(exitCode, exitStatus, dndOutput.text) }
  }

  Timer { id: dndRefresh; interval: 200; onTriggered: root.refreshDnd() }

  // Detached, like remove and seed above it: a clear that arrives while the
  // previous one is still running used to return early and never happen, so
  // the list came back on the next sync and the button looked broken.
  function clearAll() {
    entries = []
    entriesReset()
    // Release callbacks only after durable clearing, without catching newer arrivals.
    Quickshell.execDetached(["bash", "-c", '"$1" clear && omarchy-shell -q foamy.notifications releaseHistoryBefore "$2"',
      "--", root.script, String(Date.now())])
  }

  function absorb(line) {
    var entry
    try {
      entry = JSON.parse(line)
    } catch (e) {
      return
    }
    if (entry && entry.event === "storeChanged") { archiveRevision++; reloadArchive.restart(); return }
    if (entry && entry.event === "dndChanged") { dndRefresh.restart(); return }
    if (entry && entry.event === "seenChanged") { root.readSeen(); return }
    if (!entry || !entry.key) return
    if (removedKeys[String(entry.key)]) return
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].key !== entry.key) continue
      if (JSON.stringify(entries[i]) === JSON.stringify(entry)) return
      archiveRevision++
      var updated = entries.slice()
      updated[i] = entry
      entries = updated
      entriesReset()
      return
    }
    archiveRevision++

    var next = [entry].concat(entries)
    if (next.length > pageSize) next = next.slice(0, pageSize)
    entries = next
    entryAdded(entry)
  }

  function visibleEntries(data) {
    return data.filter(function(entry) {
      return !root.removedKeys[String(entry.key)]
    })
  }

  property bool sourceRestartPending: false
  FileView {
    path: (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onFileChanged: {
      reload()
      // A daemon switch must re-resolve the source without restarting the center.
      root.sourceRestartPending = true
      if (watchProc.running) watchProc.running = false
      else { restartWatch.interval = 100; restartWatch.restart() }
    }
  }

  Process {
    id: watchProc
    command: root.storeCommand(["watch"])
    environment: root.storeEnvironment
    running: true
    stdout: SplitParser {
      onRead: function(line) { root.absorb(line) }
    }
    onExited: {
      restartWatch.interval = root.sourceRestartPending ? 100 : 30000
      restartWatch.restart()
    }
  }

  Timer {
    id: restartWatch
    interval: 30000
    onTriggered: { root.sourceRestartPending = false; if (!watchProc.running) watchProc.running = true }
  }

  Timer { id: reloadArchive; interval: 75; onTriggered: root.load() }

  Process {
    id: listProc
    environment: root.storeEnvironment
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0 || exitStatus !== 0) root.loadError = "Could not refresh notification history. Reopen the center to retry."
      if (root.loadPending) reloadArchive.restart()
    }
    stdout: StdioCollector {
      onStreamFinished: {
        // A watcher event newer than this read wins; reconcile again after the read drains.
        if (root.listRevision !== root.archiveRevision) { root.loadPending = true; reloadArchive.restart(); return }
        var data
        try {
          data = JSON.parse(text)
        } catch (e) { root.loadError = "Invalid notification history response."; return }
        if (!Array.isArray(data)) { root.loadError = "Invalid notification history response."; return }
        root.loadError = ""
        data = root.visibleEntries(data)
        var wasLoaded = root.loaded
        root.loaded = true
        if (wasLoaded && !root.differsFrom(data)) return
        root.entries = data
        root.entriesReset()
      }
    }
  }

  Process {
    id: seenProc
    environment: root.storeEnvironment
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          if (data.ok === true) root.lastSeen = Number(data.seen) || 0
        } catch (e) {
        }
      }
    }
  }

  Process { id: markProc; environment: root.storeEnvironment }

  Component.onCompleted: {
    Plugin.ServiceRegistry.instance = root
    readSeen()
    load()
    dndRefresh.restart()
  }

  Component.onDestruction: {
    // A retiring service must not clear its replacement during a reload.
    if (Plugin.ServiceRegistry.instance === root) Plugin.ServiceRegistry.instance = null
  }

  // Popup actions use public IPC because plugins cannot call each other's services.
  IpcHandler {
    // The panel owns foamy.notification-center (open/close); the store needs a distinct target.
    target: "foamy.notification-center.store"
    function remove(keysCsv: string): string {
      var keys = keysCsv.split(",")
      if (!Array.isArray(keys) || keys.length > 100 || keys.some(function(key) {
        return typeof key !== "string" || !/^[0-9]+-[0-9]+$/.test(key)
      })) return "error: invalid keys"
      root.removeMany(keys)
      return "ok"
    }
    function handled(keysCsv: string): string {
      var keys = keysCsv.split(",")
      if (!Array.isArray(keys) || keys.length > 100 || keys.some(function(key) {
        return typeof key !== "string" || !/^[0-9]+-[0-9]+$/.test(key)
      })) return "error: invalid keys"
      for (var i = 0; i < keys.length; i++) root.removedKeys[keys[i]] = true
      root.entries = root.visibleEntries(root.entries)
      root.entriesReset()
      return "ok"
    }
  }

  IpcHandler {
    target: "foamy.notification-center.test"

    function seed(count: int): string {
      Quickshell.execDetached(root.storeCommand(["seed", String(count > 0 ? count : 25)]))
      reloadAfterSeed.restart()
      return "seeding " + count
    }

    function clear(): string {
      root.clearAll()
      return "cleared"
    }

    function reload(): string {
      root.load()
      return "reloading"
    }

    function state(): string {
      return JSON.stringify({
        entries: root.entries.length,
        listLoads: root.listLoadCount,
        focusError: root.focusError,
        loadError: root.loadError,
        newest: root.entries.length > 0 ? root.entries[0].summary : "",
        unread: root.unread,
        hasCriticalUnread: root.hasCriticalUnread,
        watching: watchProc.running,
        loaded: root.loaded,
        lastSeen: root.lastSeen,
        doNotDisturb: root.doNotDisturb,
        dndKnown: root.dndKnown,
        dndBusy: root.dndBusy,
        dndError: root.dndError
      })
    }
  }

  Timer {
    id: reloadAfterSeed
    interval: 600
    onTriggered: root.load()
  }
}
