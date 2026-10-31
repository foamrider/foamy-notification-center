// Shared by foamy-notifications and foamy-notification-center: keep both copies
// identical (tests/shared-files.sha256). Adapted from Omarchy 4.5's
// shell/plugins/notifications/Markup.js (MIT; see LICENSE-OMARCHY).
//
// Notification bodies are markup, so senders escape them ("Tom &amp; Jerry").
// Everything is decoded, escaped again, and only a small allowlist is put back:
// <b> <i> <u> <s> <em> <strong> <br>. Every other tag (<img>, <font>, <a>,
// <h1>, <pre>, …) survives as literal text or, for <a>, as its label only:
// Foamy never makes body text clickable; links get an explicit footer button.
.pragma library

var MAX_BODY = 32768
var ALLOWED = ["b", "i", "u", "s", "em", "strong"]
var ENTITIES = { amp: "&", lt: "<", gt: ">", quot: "\"", apos: "'", nbsp: " " }

function bounded(value, max) {
  return typeof value === "string" ? value.slice(0, max) : (value === undefined || value === null ? "" : String(value).slice(0, max))
}

function decodeOnce(text) {
  return String(text || "")
    .replace(/&#(\d{1,7});/g, function(whole, n) {
      var code = parseInt(n, 10)
      return code > 0 && code < 0x110000 ? String.fromCodePoint(code) : whole
    })
    .replace(/&#x([0-9a-f]{1,6});/gi, function(whole, n) {
      var code = parseInt(n, 16)
      return code > 0 && code < 0x110000 ? String.fromCodePoint(code) : whole
    })
    .replace(/&([a-z]+);/gi, function(whole, name) {
      var hit = ENTITIES[String(name).toLowerCase()]
      return hit === undefined ? whole : hit
    })
}

// Up to three passes: relays stack escapes (KDE Connect re-escapes a
// WhatsApp &quot; into &amp;quot;).
function decodeEntities(text) {
  var out = bounded(text, MAX_BODY)
  for (var i = 0; i < 3; i++) {
    var once = decodeOnce(out)
    if (once === out) break
    out = once
  }
  return out
}

function escapeAll(text) {
  return String(text || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
}

// Put back only the allowed tags, attribute-free. Anchors keep their label.
function unescapeAllowed(text) {
  var out = text
  for (var i = 0; i < ALLOWED.length; i++) {
    var tag = ALLOWED[i]
    out = out.replace(new RegExp("&lt;" + tag + "&gt;", "gi"), "<" + tag + ">")
    out = out.replace(new RegExp("&lt;/" + tag + "&gt;", "gi"), "</" + tag + ">")
  }
  out = out.replace(/&lt;br\s*\/?&gt;/gi, "<br/>")
  out = out.replace(/&lt;a\s[^]*?&gt;([^]*?)&lt;\/a&gt;/gi, "$1")
  return out
}

// The body as Text.StyledText draws it: the permitted subset, newlines kept.
// Nothing the sender wrote can produce an image fetch, a font change or a link.
function render(body) {
  var out = unescapeAllowed(escapeAll(decodeEntities(body)))
  // StyledText has no <em>/<strong>.
  out = out.replace(/<(\/?)em>/gi, "<$1i>").replace(/<(\/?)strong>/gi, "<$1b>")
  return out.replace(/\r\n|\r|\n/g, "<br/>")
}

// One line of plain text for Text.PlainText: markup render() would draw is
// dropped; literal text ("<3", "<String>") stays, entities are decoded once.
function oneLine(body) {
  var text = unescapeAllowed(escapeAll(decodeEntities(body)))
  return decodeOnce(text.replace(/<[^>]+>/g, " ")).replace(/\s+/g, " ").trim()
}

// Plain text keeping line breaks (multi-line Text.PlainText).
function plainText(body) {
  var text = unescapeAllowed(escapeAll(decodeEntities(body))).replace(/<br\/>/g, "\n")
  return decodeOnce(text.replace(/<[^>]+>/g, "")).replace(/[ \t]+/g, " ").replace(/ *\n */g, "\n").trim()
}

if (typeof module !== "undefined") module.exports = { decodeEntities: decodeEntities, escapeAll: escapeAll, render: render, oneLine: oneLine, plainText: plainText }
