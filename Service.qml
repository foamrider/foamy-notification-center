import QtQuick
import Quickshell
import Quickshell.Io
import "." as Plugin
import "Model.js" as Model
import "components"
import "kit"

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
  // Paging: the list loads listLimit rows (pages of pageSize, up to maxItems);
  // hasMore says the archive holds more. A search runs in the store over the
  // whole archive, not just the loaded page.
  property int pageSize: 500
  property int listLimit: pageSize
  property bool hasMore: false
  property string searchQuery: ""
  onSearchQueryChanged: reloadArchive.restart()
  function loadMore() {
    if (!hasMore || listLimit >= maxItems) return
    listLimit = Math.min(maxItems, listLimit + pageSize)
    load()
  }

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

  // Unread state comes from the unfiltered newest page, never from search results.
  property var unreadSource: []
  readonly property var unreadState: Model.unreadState(unreadSource, lastSeen)
  readonly property int unread: unreadState.unread
  // Every loaded row is unread and more exist: the badge says "N+".
  readonly property bool unreadCapped: hasMore && unread >= unreadSource.length && unread > 0
  readonly property bool hasCriticalUnread: unreadState.hasCriticalUnread

  readonly property string script:
    Qt.resolvedUrl("bin/notification-center").toString().replace(/^file:\/\//, "")

  // ------------------------------------------------ the notification source
  //
  // Contract v2 with foamy.notifications (README "Foamy Notifications contract"):
  // its file locations come from `storeInfo` over IPC; they are read-only here.
  // Without Foamy the source is stock Omarchy (4.0 files or 4.5 arrays).
  property string sourceKind: ""
  property var sourceInfo: ({})
  FoamyPeerIpc { id: peer }
  readonly property bool foamySource: sourceKind === "foamy" || sourceKind === "legacy"

  function resolveSource() {
    peer.call("foamy.notifications", "storeInfo", [], function(ok, output) {
      var info = null
      try { info = ok ? JSON.parse(output) : null } catch (e) { info = null }
      if (info && info.layout === "foamy-files" && Number(info.version) >= 2) {
        if (!info.ready) { sourceRetry.restart(); return }
        root.useSource("foamy", info)
        return
      }
      // An older Foamy answers ping but has no storeInfo: its 4.0-layout files.
      peer.call("foamy.notifications", "ping", [], function(pinged, answer) {
        root.useSource(pinged && String(answer).trim() === "ok" ? "legacy" : "stock", {})
      })
    })
  }
  Timer { id: sourceRetry; interval: 2000; onTriggered: root.resolveSource() }

  function useSource(kind, info) {
    var same = kind === sourceKind && JSON.stringify(info) === JSON.stringify(sourceInfo)
    sourceKind = kind
    sourceInfo = info
    if (same && watchProc.running) return
    sourceRestartPending = true
    if (watchProc.running) watchProc.running = false
    else { restartWatch.interval = 50; restartWatch.restart() }
  }

  // The watcher reads every archive setting (keepDays, maxItems, previews) and
  // the source from its environment once, at start: any change restarts it
  // (debounced), even when the daemon/source itself did not change.
  onStoreEnvironmentChanged: if (watchProc.running) {
    sourceRestartPending = true
    watchProc.running = false
  }

  readonly property var storeEnvironment: {
    var env = {
      "NC_KEEP_DAYS": String(root.keepDays),
      "NC_MAX_ITEMS": String(root.maxItems),
      "NC_PREVIEWS": root.showPreview ? "1" : "0",
      "NC_SOURCE": root.sourceKind || "stock"
    }
    if (root.sourceKind === "foamy") {
      env.NC_SRC_DIR = String(root.sourceInfo.popups || "")
      env.NC_SRC_HISTORY = String(root.sourceInfo.history || "")
      env.NC_HANDLED = String(root.sourceInfo.handled || "")
      env.NC_STATE_FILE = String(root.sourceInfo.state || "")
    } else if (root.sourceKind === "legacy") {
      // Foamy before contract v2 kept the 4.0 layout under XDG_STATE_HOME.
      var state = Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state"
      env.NC_SRC_DIR = state + "/omarchy/notifications"
      env.NC_STATE_FILE = state + "/omarchy/notifications.json"
    }
    return env
  }

  property string focusError: ""
  property var focusEntry: null
  property bool invokingDefault: false
  property bool openingFile: false
  signal focusCompleted()

  function focusNotification(row, useDefault) {
    if (focusProc.running || !row || !/^([0-9]+-[0-9]+|stock-[A-Za-z0-9_-]{1,120})$/.test(String(row.key))) return
    focusError = ""
    focusEntry = row
    openingFile = false
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
    var helper = decodeURIComponent(Qt.resolvedUrl("bin/focus-notification-app").toString().replace(/^file:\/\//, ""))
    focusProc.command = ["bash", helper, directory, focusEntry.app.replace(/\./g, "\\.")]
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
        // Live sender actions take priority; archived pictures use a fixed opener.
        var command = Model.fileCommand(focusEntry)
        if (command) {
          invokingDefault = false
          openingFile = true
          var helper = decodeURIComponent(Qt.resolvedUrl("bin/open-notification-image").toString().replace(/^file:\/\//, ""))
          focusProc.command = ["bash", helper, command[0] === "omasnap" ? "edit-screenshot" : "view-image", command[1]]
          focusProc.running = true
        } else focusSendingApp()
        return
      }
      // The daemon owns durable handling of its callback and acknowledges removal.
      root.focusCompleted()
      focusEntry = null
      return
    }
    if (succeeded) { root.remove(focusEntry.key); root.focusCompleted() }
    else if (!openingFile && exitCode === 3 && exitStatus === 0) {
      // Background senders often have no window; retain history without an error.
      focusError = ""
    } else {
      focusError = openingFile ? "Could not open the image. Check that the file and its app are available, then try again."
                              : "Could not focus the sending app. Open the app and try again."
      console.warn(openingFile ? "Notification image opening failed:" : "Notification focus failed:", exitCode, exitStatus)
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
    // One row past the page says whether there is more.
    listProc.command = root.storeCommand(["list", String(root.listLimit + 1), root.searchQuery])
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

  signal peerPreferencesChanged()
  property var quietRemovalKeys: ({})

  function removeMany(keys, handledByPeer) {
    var queued = pendingRemovalKeys.slice()
    for (var i = 0; i < keys.length; i++) {
      var key = String(keys[i] || "")
      if (!key || removedKeys[key]) continue
      removedKeys[key] = true
      if (handledByPeer) quietRemovalKeys[key] = true
      queued.push(key)
    }
    if (queued.length === pendingRemovalKeys.length) return
    // Capture exact keys before watcher updates; later arrivals from the same app survive.
    pendingRemovalKeys = queued
    entries = visibleEntries(entries)
    unreadSource = visibleEntries(unreadSource)
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
      } else root.releaseNotificationActions(root.activeRemovalKeys.filter(function(key) { return !root.quietRemovalKeys[key] }))
      for (var j = 0; j < root.activeRemovalKeys.length; j++) delete root.quietRemovalKeys[root.activeRemovalKeys[j]]
      root.activeRemovalKeys = []
      root.startRemoval()
    }
  }

  // Foamy releases callbacks and drops its own copies; we never delete its files.
  // Keys go to Foamy 100 at a time, one call in flight (FoamyPeerIpc runs at
  // most 8 CLI calls on 4.0). Pending keys are kept, deduplicated and compacted
  // into full batches; the in-flight batch is removed only when Foamy answers
  // "ok", and a failed one is retried. These keys are already gone from the
  // archive, so no later prune would ask again. The bound (50,000 keys) is far
  // above the largest archive (10,000).
  property var releasePending: []
  property var releaseInFlight: []
  readonly property int releaseLimit: 50000
  function releaseNotificationActions(keys) {
    if (!foamySource) return
    var pending = releasePending.slice(), seen = ({})
    for (var p = 0; p < pending.length; p++) seen[pending[p]] = true
    for (var i = 0; i < keys.length; i++) {
      var key = String(keys[i] || "")
      if (!/^[0-9]+-[0-9]+$/.test(key) || seen[key]) continue
      if (pending.length >= releaseLimit) { console.warn("Notification release queue is full; Foamy keeps", keys.length - i, "copies until its own history trim"); break }
      seen[key] = true
      pending.push(key)
    }
    releasePending = pending
    pumpReleases()
  }
  function pumpReleases() {
    if (releaseInFlight.length || !releasePending.length || releaseRetry.running) return
    var batch = releasePending.slice(0, 100)
    releaseInFlight = batch
    peer.call("foamy.notifications", "releaseHistory", [batch.join(",")], function(ok, output) {
      if (ok && String(output).trim() === "ok") {
        var done = ({})
        for (var i = 0; i < batch.length; i++) done[batch[i]] = true
        root.releasePending = root.releasePending.filter(function(key) { return !done[key] })
        root.releaseInFlight = []
        root.pumpReleases()
      } else {
        root.releaseInFlight = []
        if (root.foamySource) releaseRetry.restart()
        else root.releasePending = []
      }
    })
  }
  Timer { id: releaseRetry; interval: 5000; onTriggered: root.pumpReleases() }

  // Ordinary plugins use the public IPC commands, not the bar-only service proxy.
  property bool doNotDisturb: false
  property bool dndKnown: false
  property string dndError: ""
  readonly property bool dndBusy: dndProc.running

  property bool snoozeAvailable: false
  readonly property bool snoozeBusy: snoozeProc.running
  property string snoozeError: ""

  // Capability, not version: stock 4.5-rc2 and 4.0 have no `snoozes`, so the menu is hidden there.
  function snoozeAll(minutes) {
    if (!snoozeAvailable || snoozeProc.running) return
    snoozeError = ""
    snoozeProc.minutes = minutes
    // Clear the old global timer before setting a new one.
    snoozeProc.command = ["omarchy-shell", "notifications", "unsnooze", minutes > 0 ? "*" : ""]
    snoozeProc.running = true
  }
  function refreshSnooze() {
    if (!snoozeProbe.running) snoozeProbe.running = true
  }
  Process {
    id: snoozeProbe
    command: ["omarchy-shell", "notifications", "snoozes"]
    stdout: StdioCollector { id: snoozeProbeOutput }
    stderr: StdioCollector {}
    onExited: function(code, status) {
      root.snoozeAvailable = false
      if (code !== 0 || status !== 0) return
      try {
        var value = JSON.parse(snoozeProbeOutput.text)
        root.snoozeAvailable = value !== null && typeof value === "object"
      } catch (e) { /* Stock 4.0 has no timed snooze; its DND control remains available. */ }
    }
  }
  Process {
    id: snoozeProc
    property int minutes: 0
    stdout: StdioCollector { id: snoozeOutput }
    stderr: StdioCollector {}
    onExited: function(code, status) {
      var result = String(snoozeOutput.text).trim()
      if (code !== 0 || status !== 0 || !result || /not found|invalid|error|^no$|^full$/i.test(result)) {
        root.snoozeError = "Could not change notification snooze. Try again."
        return
      }
      if (minutes > 0) {
        command = ["omarchy-shell", "notifications", "snoozeAll", String(minutes)]
        minutes = 0
        running = true
      }
      root.refreshDnd()
    }
  }

  function refreshDnd() {
    if (dndProc.running) { dndRefresh.restart(); return }
    // isDnd exists on stock 4.0, stock 4.5 and Foamy; dndState was removed in 4.5.
    dndProc.command = ["omarchy-shell", "notifications", "isDnd"]
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
    onExited: function(exitCode, exitStatus) { root.applyDndResult(exitCode, exitStatus, dndOutput.text); root.refreshSnooze() }
  }

  Timer { id: dndRefresh; interval: 200; onTriggered: root.refreshDnd() }

  // Detached, like remove and seed above it: a clear that arrives while the
  // previous one is still running used to return early and never happen, so
  // the list came back on the next sync and the button looked broken.
  // Clear all deletes the archived rows and images, then asks Foamy to drop its
  // copies up to the same moment (newer arrivals survive).
  function clearAll() {
    entries = []
    unreadSource = []
    entriesReset()
    // A clear requested while one runs runs again afterwards, with its own cutoff.
    if (clearProc.running) { clearPending = true; return }
    clearProc.cut = String(Date.now())
    clearProc.running = true
  }
  property bool clearPending: false
  Process {
    id: clearProc
    property string cut: ""
    command: [root.script, "clear"]
    environment: root.storeEnvironment
    onExited: function(code, status) {
      if (code === 0 && status === 0) { if (root.foamySource) peer.call("foamy.notifications", "releaseHistoryBefore", [cut]) }
      else root.removalError = "Could not clear notifications. Try again."
      if (root.clearPending) {
        root.clearPending = false
        cut = String(Date.now())
        running = true
        return
      }
      root.load()
    }
  }

  function absorb(line) {
    var entry
    try {
      entry = JSON.parse(line)
    } catch (e) {
      return
    }
    // Stopping the old watcher during a config change is an expected lifecycle event.
    if (root.sourceRestartPending && entry && entry.error === "notification watcher stopped") return
    if (entry && entry.ok === false) { root.loadError = String(entry.error || "Could not read notification history."); console.warn("Notification history:", root.loadError); return }
    if (entry && entry.event === "storeChanged") { archiveRevision++; reloadArchive.restart(); return }
    if (entry && entry.event === "dndChanged") { dndRefresh.restart(); return }
    if (entry && entry.event === "seenChanged") { root.readSeen(); return }
    if (entry && entry.event === "pruned") { root.releaseNotificationActions(entry.keys || []); return }
    // A missing source directory appeared: the watcher exits to be rebuilt with it.
    if (entry && entry.event === "rewatch") { root.sourceRestartPending = true; return }
    if (!entry || !entry.key) return
    if (removedKeys[String(entry.key)]) return
    // The unread badge follows the unfiltered newest page, search or not.
    absorbUnread(entry)
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

    if (searchQuery) { reloadArchive.restart(); return }
    var next = [entry].concat(entries)
    if (next.length > listLimit) { next = next.slice(0, listLimit); hasMore = true }
    entries = next
    entryAdded(entry)
  }

  // Keep the unfiltered unread source current independently of the (possibly
  // filtered) list: replace an updated row in place, or add a new one on top.
  function absorbUnread(entry) {
    var source = unreadSource.slice()
    for (var i = 0; i < source.length; i++) {
      if (source[i].key !== entry.key) continue
      if (JSON.stringify(source[i]) === JSON.stringify(entry)) return
      source[i] = entry
      unreadSource = source
      return
    }
    source.unshift(entry)
    unreadSource = source.length > listLimit ? source.slice(0, listLimit) : source
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
      root.resolveSource()
    }
  }

  Process {
    id: watchProc
    command: root.storeCommand(["watch"])
    environment: root.storeEnvironment
    // Started once the source is resolved (Component.onCompleted).
    running: false
    stdout: SplitParser {
      onRead: function(line) { root.absorb(line) }
    }
    onExited: {
      if (!root.sourceRestartPending) console.warn("Notification history watcher stopped; reconnecting")
      restartWatch.interval = root.sourceRestartPending ? 100 : 1000
      restartWatch.restart()
    }
  }

  Timer {
    id: restartWatch
    interval: 30000
    onTriggered: { root.sourceRestartPending = false; if (!watchProc.running && root.sourceKind) watchProc.running = true }
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
        root.hasMore = data.length > root.listLimit
        data = root.visibleEntries(data.slice(0, root.listLimit))
        if (!root.searchQuery) root.unreadSource = data
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
    resolveSource()
    dndRefresh.restart()
  }

  Component.onDestruction: {
    // A retiring service must not clear its replacement during a reload.
    if (Plugin.ServiceRegistry.instance === root) Plugin.ServiceRegistry.instance = null
  }

  // Popup actions use public IPC because plugins cannot call each other's services.
  FoamyIpc {
    // The panel owns foamy.notification-center (open/close); the store needs a distinct target.
    target: "foamy.notification-center.store"
    function remove(keysCsv: string): string {
      var keys = keysCsv.split(",")
      if (!Array.isArray(keys) || keys.length > 100 || keys.some(function(key) {
        return typeof key !== "string" || !/^([0-9]+-[0-9]+|stock-[A-Za-z0-9_-]{1,120})$/.test(key)
      })) return "error: invalid keys"
      root.removeMany(keys)
      return "ok"
    }
    // Foamy handled these (its journal is already durable): remove them durably
    // here too, without asking Foamy to release them again.
    function handled(keysCsv: string): string {
      var keys = keysCsv.split(",")
      if (!Array.isArray(keys) || keys.length > 100 || keys.some(function(key) {
        return typeof key !== "string" || !/^[0-9]+-[0-9]+$/.test(key)
      })) return "error: invalid keys"
      root.removeMany(keys, true)
      return "ok"
    }
    // Foamy started, migrated or changed its settings: re-read over IPC.
    function peerChanged(what: string): string {
      if (what === "store") root.resolveSource()
      else if (what === "preferences") root.peerPreferencesChanged()
      else return "error: unknown"
      return "ok"
    }
  }

  FoamyIpc {
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
        dndError: root.dndError,
        source: root.sourceKind,
        hasMore: root.hasMore,
        listLimit: root.listLimit
      })
    }
  }

  Timer {
    id: reloadAfterSeed
    interval: 600
    onTriggered: root.load()
  }
}
