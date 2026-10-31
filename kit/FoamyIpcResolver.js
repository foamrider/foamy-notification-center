.pragma library
// foamy-kit 0.3.4 429b18a7c00baf4488c6792a95e4be71207aefa1a237436cef34e33122956915 — do not edit; change foamy-kit and run sync

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

// Enabled handlers for `target`, in the order IpcRegistry asks them (the
// first one answers). Empty on 4.0.
function handlersFor(context, target) {
  var found = registry(context)
  if (!found || !Array.isArray(found.handlers)) return []
  return found.handlers.filter(function(handler) {
    return handler && handler.enabled && handler.target === target
  })
}

// Other enabled handlers sharing `handler`'s target (a second lock service…).
function others(context, handler) {
  if (!handler) return []
  return handlersFor(context, handler.target).filter(function(other) { return other !== handler })
}

// Make `handler` the one IpcRegistry (and so the omarchy-shell socket)
// answers for its target, by moving it to the front of the registry list.
// Nothing else is removed, disabled or called. Returns true when `handler`
// now answers; false on 4.0 (no registry) or when it is disabled. A handler
// registered later goes behind it, but a later prefer() by someone else
// wins: use FoamyIpcPreference to keep re-claiming.
function prefer(context, handler) {
  var found = registry(context)
  if (!found || !Array.isArray(found.handlers) || !handler || !handler.enabled) return false
  var list = found.handlers
  var index = list.indexOf(handler)
  if (index < 0) return false
  if (handlersFor(context, handler.target)[0] !== handler) {
    list.splice(index, 1)
    list.unshift(handler)
  }
  return handlersFor(context, handler.target)[0] === handler
}

// Call another plugin's IPC function in-process, exactly as the 4.5
// omarchy-shell socket would: { ran: true, output } or { ran: false } (no
// registry, no such target or function, wrong argument count). Arguments
// are passed as strings. FoamyPeerIpc adds the omarchy-shell fallback.
function call(context, target, method, args) {
  var found = registry(context)
  if (!found || typeof found.call !== "function") return { ran: false }
  try {
    var result = found.call(String(target), String(method), (args || []).map(function(value) { return String(value) }))
    return result && result.ran ? { ran: true, output: String(result.output === undefined ? "" : result.output) } : { ran: false }
  } catch (error) {
    return { ran: false }
  }
}
