// Shared by foamy-notifications and foamy-notification-center: keep both copies
// identical (tests/shared-files.sha256).
//
// Calls the other notification plugin's public IPC target. The two plugins
// never read, write or delete each other's files or run each other's scripts;
// everything between them goes through these calls (see CONTRACT in README).
//
//   PeerIpc { id: peer }
//   peer.call("foamy.notifications", "storeInfo", [], function(ok, output) { … })
//
// On Omarchy 4.5 the call is answered in-process through IpcRegistry (the same
// path the omarchy-shell socket uses). When the registry does not know the
// target (4.0, or a peer that registers only a plain IpcHandler) it falls back
// to `omarchy-shell <target> <method> <args…>`. `done(ok, output)` is always
// called later, never from inside call(). Arguments are strings; pass JSON
// with a leading space when it could start with "-" (qs ipc option parsing).
import QtQuick
import Quickshell.Io
import "../kit/FoamyIpcResolver.js" as Resolver

Item {
  id: root
  visible: false
  width: 0
  height: 0

  // Calls still waiting for a CLI answer; bounded so a stuck shell cannot pile up processes.
  property int running: 0
  readonly property int limit: 8

  function call(target, method, args, done) {
    var list = (args || []).map(function(value) { return String(value) })
    var finish = function(ok, output) { if (done) Qt.callLater(function() { done(ok, output) }) }
    var registry = Resolver.registry(root)
    if (registry && typeof registry.call === "function") {
      var result = null
      try { result = registry.call(String(target), String(method), list) } catch (e) { result = null }
      if (result && result.ran) { finish(true, String(result.output || "")); return }
    }
    if (running >= limit) { finish(false, ""); return }
    running++
    runner.createObject(root, { command: ["omarchy-shell", String(target), String(method)].concat(list), done: finish })
  }

  Component {
    id: runner
    Process {
      id: proc
      property var done: null
      running: true
      stdout: StdioCollector { id: output }
      stderr: StdioCollector {}
      onExited: function(code, status) {
        root.running = Math.max(0, root.running - 1)
        var text = String(output.text || "").trim()
        // omarchy-shell exits 0 with an error line when the target is missing.
        var ok = code === 0 && status === 0 && !/^(error|No such|Target not found|Function not found)/i.test(text)
        if (proc.done) proc.done(ok, text)
        proc.destroy()
      }
    }
  }
}
