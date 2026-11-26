// foamy-kit 0.14.0 cbc26d6a043bec397561973249cfec1a2a1ce2b9d4ce634d5daa43851d0c029d — do not edit; change foamy-kit and run sync
import QtQuick
import Quickshell.Io

// Reads the clipboard's text for a paste without letting Qt read it, for a
// plugin that draws its own text input (SafeTextField does this inside).
// Qt's own paste, and an editable TextInput or TextField even on every
// clipboard change, read the whole offer on the UI thread with no byte cap
// and no total deadline: a clipboard owner that keeps sending can fill the
// shell's memory or hold its UI. clipboard.sh reads it in its own process
// instead: at most 16 KiB of text without NUL, line breaks as spaces (or
// kept as "\n" with `multiline: true`, for a multi-line editor), killed
// with its producer at 2 s.
//
//   FoamyClipboard {
//     id: clipboard
//     multiline: false                     // true keeps line breaks ("\n")
//     onRead: function (text) { … }        // the text, possibly ""
//     onFailed: function (message) { … }   // English; FoamyI18n.t() it to show
//   }
//   clipboard.start(false)   // the clipboard; true: the primary selection
//   clipboard.cancel()       // stops a read; neither signal follows
//
// One read at a time: start() returns false while one runs (busy). A read
// ends exactly once, on exit or a failed start. The caller drops a result
// whose target changed meanwhile (typing, another view, a closed window).
// clipboardScript resolves relative to this file unless absolute.
Item {
  id: reader

  property string clipboardScript: "clipboard.sh"
  // Keep line breaks (each CR LF, CR, U+2028 or U+2029 as "\n") instead of
  // turning them into spaces. Read at start().
  property bool multiline: false
  // Busy until a stopped read has also exited: running = false only sends
  // TERM, and a start before the exit would be a no-op whose result is the
  // stopped read's exit.
  readonly property bool busy: proc.pending || proc.running

  signal read(string text)
  signal failed(string message)

  function start(primary) {
    if (reader.busy)
      return false
    proc.pending = true
    var command = ["bash", decodeURIComponent(Qt.resolvedUrl(reader.clipboardScript).toString().replace(/^file:\/\//, "")), primary ? "primary" : "clipboard"]
    if (reader.multiline)
      command.push("multiline")
    proc.command = command
    proc.running = true
    return true
  }

  function cancel() {
    proc.pending = false
    proc.running = false
  }

  // The one way a read ends: exited, or couldn't start (then Quickshell
  // emits no exited(), only running -> false). A cancelled read ends here
  // too, with nothing pending, and reports nothing.
  function finish(code, output) {
    if (!proc.pending)
      return
    proc.pending = false
    if (code === 124 || code === 137) {
      reader.failed("Clipboard paste timed out. Copy the text again.")
      return
    }
    if (code === 5) {
      reader.failed("Clipboard text is too large or contains invalid characters.")
      return
    }
    // clipboard.sh leaves "" on stdout when wl-paste fails, so the text
    // counts only after exit 0.
    var text = null
    if (code === 0) {
      try {
        text = JSON.parse(output)
      } catch (e) {
        text = null
      }
    }
    if (typeof text !== "string" || text.length > 16384) {
      reader.failed("Could not paste clipboard text. Copy plain text and try again.")
      return
    }
    reader.read(text)
  }

  Component.onDestruction: reader.cancel()

  Process {
    id: proc
    property bool pending: false
    stdout: StdioCollector {
      id: output
    }
    onExited: function (exitCode) {
      reader.finish(exitCode, output.text)
    }
    onRunningChanged: if (!running)
      reader.finish(-1, "")
  }
}
