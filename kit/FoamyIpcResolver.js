.pragma library
// foamy-kit 0.1.0 88966e4860766563e117b5a202e707a3ea65339a190ce676b13bd75767c129c0 — do not edit; change foamy-kit and run sync

// Finds 4.5's IpcRegistry at runtime. 4.0 has no such singleton, and a
// static `import qs.Commons` reference to it would stop the plugin loading
// there, so the lookup happens inside a throwaway object. The answer is
// cached for the engine (one shell generation).
var cached = undefined

function registry(context) {
  if (cached !== undefined) return cached
  cached = null
  try {
    var probe = Qt.createQmlObject('import QtQuick; import qs.Commons; QtObject { function get() { return typeof IpcRegistry === "undefined" ? null : IpcRegistry } }', context, "FoamyIpcProbe")
    var found = probe.get()
    probe.destroy()
    if (found && typeof found.register === "function" && typeof found.unregister === "function") cached = found
  } catch (error) {
    cached = null
  }
  return cached
}

// True when omarchy-shell can reach handlers over the shell socket (4.5).
function fastPath(context) {
  return registry(context) !== null
}
