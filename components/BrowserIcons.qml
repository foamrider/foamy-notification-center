import QtQuick
import Quickshell.Io
import "../BrowserIdentity.js" as BrowserIdentity
import "../kit/FoamyNative.js" as FoamyNative

Item {
  id: root
  visible: false
  property var icons: ({})
  property var pending: ({})
  property var requests: []
  property var active: null
  // The plugin's native helper (bin/<arch>/<helper>, foamy-kit FoamyNative); set
  // where BrowserIcons is used. Its `favicon` subcommand is the lookup.
  property string helper: ""
  // No helper binary for this CPU: app icons only, without retrying.
  property bool unavailable: false
  signal updated()

  function source(row) {
    if (!row) return ""
    var entry = icons[BrowserIdentity.key(row)]
    return entry ? entry.source : ""
  }

  function warm(rows) {
    if (unavailable || !helper) return
    var queue = requests.slice()
    for (var i = 0; i < Math.min(rows.length, 128) && queue.length < 128; i++) {
      var row = rows[i], key = BrowserIdentity.key(row)
      if (!key || pending[key]) continue
      var cached = icons[key]
      if (cached && Date.now() - cached.timestamp < (cached.source ? 86400000 : 300000)) continue
      pending[key] = true
      queue.push({key: key, browser: BrowserIdentity.browser(row), hostname: BrowserIdentity.hostname(row)})
    }
    requests = queue
    startNext()
  }

  function startNext() {
    if (lookup.running || active || requests.length === 0) return
    active = requests[0]
    requests = requests.slice(1)
    lookup.stdinEnabled = true
    lookup.running = true
  }

  function finish(output) {
    if (!active) return
    var result = ""
    try {
      var parsed = JSON.parse(output)
      if (typeof parsed.source === "string" && parsed.source.indexOf("file://") === 0) result = parsed.source
      if (parsed.status === "cache-unavailable") console.warn("Favicon lookup: local cache unavailable; using the app icon")
    } catch (e) { console.warn("Invalid favicon lookup response; using the app icon") }
    var next = Object.assign({}, icons)
    // Limit both successful and failed lookups; misses are retried after five minutes.
    if (Object.keys(next).length >= 128) delete next[Object.keys(next)[0]]
    next[active.key] = {source: result, timestamp: Date.now()}
    icons = next
    delete pending[active.key]
    active = null
    updated()
    Qt.callLater(startNext)
  }

  Process {
    id: lookup
    command: root.helper ? FoamyNative.command(FoamyNative.localPath(Qt.resolvedUrl("..")), root.helper, ["favicon"]) : []
    stdinEnabled: true
    stdout: StdioCollector { id: output }
    stderr: StdioCollector { id: errors }
    onStarted: {
      lookup.write(JSON.stringify({browser: root.active.browser, hostname: root.active.hostname}))
      lookup.stdinEnabled = false
    }
    onExited: function(exitCode, exitStatus) {
      if (FoamyNative.unavailable(exitCode)) {
        if (!root.unavailable) console.warn("Favicon lookup: " + FoamyNative.UNAVAILABLE_TEXT + " Using app icons.")
        root.unavailable = true
        root.requests = []
        root.pending = ({})
      } else if (exitCode !== 0 || exitStatus !== 0) console.warn("Favicon lookup failed; using the app icon:", errors.text.trim())
      root.finish(output.text)
    }
  }
  // A helper failure must never block later notifications or hold a popup's action.
  Timer {
    interval: 4000
    // A failed process start can leave an active request without a running process.
    running: root.active !== null
    onTriggered: {
      if (lookup.running) lookup.signal(9)
      else { console.warn("Favicon helper could not start; using the app icon"); root.finish("") }
    }
  }
}
