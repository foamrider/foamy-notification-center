// foamy-kit 0.9.0 47322c3ae1a2a09e28908d622241117d1a19c0e6349953f26609ee72c5e5b512 — do not edit; change foamy-kit and run sync
import QtQuick
import Quickshell.Io
import "FoamyIpcResolver.js" as Resolver

// Calls another plugin's public IPC target (from foamy-notifications'
// PeerIpc). Plugins never read each other's files or run each other's
// scripts; they talk through these calls.
//
//   FoamyPeerIpc { id: peer }
//   peer.call("foamy.notifications", "storeInfo", [], function(ok, output) { … })
//
// On 4.5 the call is answered in-process through IpcRegistry (the path the
// omarchy-shell socket uses). When that doesn't run it (4.0, or a peer with
// a plain IpcHandler) it falls back to `omarchy-shell <target> <method>
// <args…>`, at most `limit` processes at once. `done(ok, output)` is always
// called later, never from inside call(). Arguments are strings. An
// argument starting with "[" needs a leading space on the CLI path (qs ipc
// splits "[a,b]" into a list); JSON.parse ignores the space.
QtObject {
  id: root

  // CLI calls in flight; bounded so a stuck shell cannot pile up processes.
  property int running: 0
  property int limit: 8

  function call(target, method, args, done) {
    var list = (args || []).map(function(value) { return String(value) })
    var finish = function(ok, output) { if (done) Qt.callLater(function() { done(ok, output) }) }
    var result = Resolver.call(root, target, method, list)
    if (result.ran) { finish(true, result.output); return }
    if (running >= limit) { finish(false, ""); return }
    running++
    runner.createObject(root, { command: ["omarchy-shell", String(target), String(method)].concat(list), done: finish })
  }

  property Component runner: Component {
    Process {
      id: proc
      property var done: null
      property bool finished: false
      running: true
      stdout: StdioCollector { id: output }
      function complete(ok, text) {
        if (finished) return
        finished = true
        root.running = Math.max(0, root.running - 1)
        if (proc.done) proc.done(ok, text)
        proc.destroy()
      }
      onExited: function(code, status) {
        var text = String(output.text || "").trim()
        // omarchy-shell exits 0 with an error line when the target is missing.
        complete(code === 0 && status === 0 && !/^(error|No such|Target not found|Function not found)/i.test(text), text)
      }
      // After exited() this does nothing. Without it (omarchy-shell missing)
      // Quickshell emits no exited(), only running -> false.
      onRunningChanged: if (!running) complete(false, "")
    }
  }
}
