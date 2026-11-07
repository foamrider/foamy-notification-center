.pragma library
// foamy-kit 0.5.2 16b017e91ba960a867a1c5cc056f7f8d7bad07c07722714b32765d7c6d53920a — do not edit; change foamy-kit and run sync
// FoamyNative: launch a plugin's bundled native helper, bin/<arch>/<name>.
//
//   import "kit/FoamyNative.js" as FoamyNative
//   Process {
//     command: ["timeout", "--kill-after=1s", "30s"].concat(
//       FoamyNative.command(FoamyNative.localPath(Qt.resolvedUrl(".")), "foamy-power-helper", ["set", profile]))
//     onExited: function(exitCode) {
//       if (FoamyNative.unavailable(exitCode)) { /* show FoamyI18n.t(FoamyNative.UNAVAILABLE_TEXT), don't retry */ }
//     }
//   }
//
// command() runs the helper through `bash -c 'exec -- …'`: bash picks the
// directory from its builtin $HOSTTYPE (x86_64, aarch64) and replaces itself
// with the helper, so no extra process stays around. A missing binary or an
// unsupported CPU becomes a normal exit 127 (126: not executable) instead of
// a Process that never reports an exit. Helpers never exit 126 or 127
// themselves (foamy-helper's json::run maps them to 1).

var UNAVAILABLE_TEXT = "This plugin's helper isn't available for this CPU."

var SCRIPT = 'exec -- "$1/bin/$HOSTTYPE/$2" "${@:3}"'

function command(pluginDir, name, args) {
  if (typeof pluginDir !== "string" || pluginDir.length === 0)
    throw new TypeError("FoamyNative.command: pluginDir must be a non-empty path")
  if (typeof name !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(name))
    throw new TypeError("FoamyNative.command: invalid helper name " + JSON.stringify(name))
  var argv = ["bash", "-c", SCRIPT, "foamy-native", pluginDir, name]
  var list = args === undefined || args === null ? [] : args
  if (!Array.isArray(list))
    throw new TypeError("FoamyNative.command: args must be an array")
  for (var i = 0; i < list.length; i++) {
    var arg = list[i]
    if (typeof arg === "number" && isFinite(arg)) arg = String(arg)
    if (typeof arg !== "string")
      throw new TypeError("FoamyNative.command: argument " + i + " is not a string")
    argv.push(arg)
  }
  return argv
}

// True for the exits that mean "the helper couldn't start": 127 (no binary
// for this CPU, or no bash) and 126 (not executable).
function unavailable(exitCode) {
  return exitCode === 126 || exitCode === 127
}

// A local path from a file URL, without the trailing slash: the plugin
// directory is localPath(Qt.resolvedUrl(".")) in a QML file at the plugin's
// root, localPath(Qt.resolvedUrl("..")) in a subdirectory.
function localPath(url) {
  var text = String(url)
  if (text.indexOf("file://") === 0) text = decodeURIComponent(text.slice(7))
  while (text.length > 1 && text.charAt(text.length - 1) === "/") text = text.slice(0, -1)
  return text
}

if (typeof module !== "undefined") module.exports = { UNAVAILABLE_TEXT: UNAVAILABLE_TEXT, command: command, unavailable: unavailable, localPath: localPath }
