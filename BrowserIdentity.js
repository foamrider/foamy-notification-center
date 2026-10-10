// Website identity comes only from the browser's leading origin, never message links.
function browser(row) {
  // File paths can contain browser names without identifying the sending app.
  var icon = String(row.appIcon || "")
  if (icon.indexOf("/") >= 0 || icon.indexOf(":") >= 0) icon = ""
  var source = [row.app, row.desktopEntry, icon].join(" ").toLowerCase()
  var names = ["vivaldi", "brave", "microsoft-edge", "msedge", "chromium", "google-chrome", "chrome", "opera", "firefox"]
  for (var i = 0; i < names.length; i++) {
    if (new RegExp("(?:^|[^a-z0-9])" + names[i] + "(?:$|[^a-z0-9])").test(source)) return names[i]
  }
  return ""
}

function hostname(row) {
  if (!browser(row)) return ""
  var text = String(row.body || "").trim()
  var first = text.split(/\r?\n/, 1)[0].trim()
  var label = "[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
  var hostPattern = new RegExp("^(?:" + label + "\\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$", "i")
  if (first.length <= 253 && hostPattern.test(first)) return first.toLowerCase()
  var link = /^(?:<a\s+[^>]*href=["'](https?:\/\/[^"']+)["'][^>]*>|(https?:\/\/[^\s<]+))/i.exec(text)
  if (!link) return ""
  // Reject credentials, ports and malformed hosts instead of guessing their identity.
  var origin = /^https?:\/\/([^/?#]+)(?:[/?#]|$)/i.exec(link[1] || link[2])
  return origin && origin[1].length <= 253 && hostPattern.test(origin[1]) ? origin[1].toLowerCase() : ""
}

function key(row) {
  var host = hostname(row)
  return host ? JSON.stringify([browser(row), host]) : ""
}

if (typeof module !== "undefined") module.exports = { browser: browser, hostname: hostname, key: key }
