import QtQuick
import Quickshell.Io
import "../BrowserIdentity.js" as BrowserIdentity

Item {
  id: root
  visible: false
  property var icons: ({})
  property var pending: ({})
  property var requests: []
  property var active: null
  signal updated()

  function source(row) {
    if (!row) return ""
    var entry = icons[BrowserIdentity.key(row)]
    return entry ? entry.source : ""
  }

  function warm(rows) {
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
    command: ["python3", Qt.resolvedUrl("../bin/browser-favicon.py").toString().replace(/^file:\/\//, "")]
    stdinEnabled: true
    stdout: StdioCollector { id: output }
    stderr: StdioCollector { id: errors }
    onStarted: {
      lookup.write(JSON.stringify({browser: root.active.browser, hostname: root.active.hostname}))
      lookup.stdinEnabled = false
    }
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0 || exitStatus !== 0) console.warn("Favicon lookup failed; using the app icon:", errors.text.trim())
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
