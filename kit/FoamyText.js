.pragma library
// foamy-kit 0.13.1 82e646f371aaa05336883bb248832de06feb982a83967d1d2cfe065f2b3a9e07 — do not edit; change foamy-kit and run sync

// Size bounds for text a plugin hands to a sink that has none of its own.
//
// The host bar's tooltip (bar.showTooltip) is a PlainText label sized to its
// text: no width, wrap, elide or line limit. PlainText stops markup, not
// size, so a long or many-line title from an app (MPRIS metadata, a
// notification, a tray item) makes a window as big as the text. Cap it first:
//
//   import "kit/FoamyText.js" as FoamyText
//   bar.showTooltip(button, FoamyText.tooltip(player.title + "\n" + player.artist))
//   FoamyText.cap(text, 3, 60)                      // 3 lines of at most 60 characters
//
// Give a list one item per line ("Mouse 82%\nKeyboard 14%"), not one line
// joined with " · ": tooltip() keeps 6 lines and cuts each line on its own,
// so a long item loses only its own end; in one joined line everything after
// the 100th character is gone, whole items included.
//
// cap(text, maxLines, maxChars): at most maxLines lines of at most maxChars
// characters each. A cut line ends in "…" (within maxChars), and so does the
// last line when lines were dropped. Characters are code points: a
// surrogate pair is never split (a combining sequence or emoji ZWJ sequence
// may be, which still renders). Line breaks are \n, \r\n, \r, U+2028 and
// U+2029 (Qt breaks on all of them); the result uses \n. Trailing blank lines
// count as nothing dropped. One pass that stops after the last kept line;
// it bounds what is shown, not what the caller already holds in memory.
// Non-strings become strings; null and undefined become "".
//
// Node unit tests: require("../kit/node-loader.cjs").load("FoamyText").

var ELLIPSIS = "…"
var TOOLTIP_LINES = 6
var TOOLTIP_CHARS = 100
// How far past the last kept line cap() looks for more text before it
// assumes some (a trailing run of blanks longer than this counts as text).
var BLANK_LOOKAHEAD = 4096

function isBreak(code) {
  return code === 10 || code === 13 || code === 0x2028 || code === 0x2029
}

function isBlank(code) {
  return code === 32 || code === 9 || code === 11 || code === 12 || isBreak(code)
}

function limit(value, fallback) {
  var number = Math.floor(Number(value))
  return isFinite(number) && number >= 1 ? number : fallback
}

// True when `text` has a non-blank character at or after `index`.
function moreText(text, index) {
  var end = Math.min(text.length, index + BLANK_LOOKAHEAD)
  for (var i = index; i < end; i++) if (!isBlank(text.charCodeAt(i))) return true
  return end < text.length
}

function cap(text, maxLines, maxChars) {
  var source = text === undefined || text === null ? "" : String(text)
  var lines = limit(maxLines, TOOLTIP_LINES)
  var chars = limit(maxChars, TOOLTIP_CHARS)
  var out = []
  var line = ""
  var count = 0          // code points in `line`
  var cut = false        // `line` lost characters
  var i = 0
  while (i < source.length) {
    var code = source.charCodeAt(i)
    if (isBreak(code)) {
      i += code === 13 && source.charCodeAt(i + 1) === 10 ? 2 : 1
      out.push(cut ? line + ELLIPSIS : line)
      line = ""; count = 0; cut = false
      if (out.length === lines) {
        if (moreText(source, i)) out[lines - 1] = ellipsize(out[lines - 1], chars)
        return trimTrailingBlankLines(out).join("\n")
      }
      continue
    }
    var width = code >= 0xD800 && code <= 0xDBFF && i + 1 < source.length
      && source.charCodeAt(i + 1) >= 0xDC00 && source.charCodeAt(i + 1) <= 0xDFFF ? 2 : 1
    if (cut) {
      i += width
      // Skip the rest of a cut line without collecting it.
      continue
    }
    if (count === chars) {
      // The line is full and goes on: drop its last character for the "…".
      line = dropLast(line)
      cut = true
      i += width
      continue
    }
    line += source.substr(i, width)
    count++
    i += width
  }
  out.push(cut ? line + ELLIPSIS : line)
  return trimTrailingBlankLines(out).join("\n")
}

// `line` (at most `chars` code points) ending in "…", still within `chars`.
function ellipsize(line, chars) {
  if (line.slice(-1) === ELLIPSIS) return line
  var count = 0
  for (var i = 0; i < line.length; i++) {
    var code = line.charCodeAt(i)
    if (code >= 0xD800 && code <= 0xDBFF && i + 1 < line.length) {
      var next = line.charCodeAt(i + 1)
      if (next >= 0xDC00 && next <= 0xDFFF) i++
    }
    count++
  }
  return (count >= chars ? dropLast(line) : line) + ELLIPSIS
}

// `line` without its last code point (a surrogate pair as one).
function dropLast(line) {
  if (line.length >= 2) {
    var low = line.charCodeAt(line.length - 1)
    var high = line.charCodeAt(line.length - 2)
    if (low >= 0xDC00 && low <= 0xDFFF && high >= 0xD800 && high <= 0xDBFF) return line.slice(0, -2)
  }
  return line.slice(0, -1)
}

function trimTrailingBlankLines(lines) {
  var end = lines.length
  while (end > 1 && /^[ \t\v\f]*$/.test(lines[end - 1])) end--
  return lines.slice(0, end)
}

// The host bar tooltip's cap: TOOLTIP_LINES lines of TOOLTIP_CHARS characters.
function tooltip(text) {
  return cap(text, TOOLTIP_LINES, TOOLTIP_CHARS)
}

if (typeof module !== "undefined") module.exports = {
  ELLIPSIS: ELLIPSIS, TOOLTIP_LINES: TOOLTIP_LINES, TOOLTIP_CHARS: TOOLTIP_CHARS, cap: cap, tooltip: tooltip
}
