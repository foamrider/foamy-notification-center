var CRITICAL_URGENCY = 2

// Recheck persisted paths at the click boundary, including unmigrated entries.
// Archived sender commands are never executable actions.
function isPreviewFile(value) {
  return typeof value === "string"
    && /^\/[^"'\x00-\x1f\x7f]*\.(jpe?g|png|webp|gif)$/i.test(value)
}

function unreadState(entries, lastSeen) {
  var rows = Array.isArray(entries) ? entries : []
  var boundary = Number(lastSeen)
  if (!isFinite(boundary)) boundary = 0

  var unread = 0
  var hasCriticalUnread = false

  // Entries are newest first. Stop at the read boundary so an older critical
  // notification cannot keep the current badge red.
  for (var i = 0; i < rows.length; i++) {
    var entry = rows[i] || {}
    var timestamp = Number(entry.timestamp)
    if (!isFinite(timestamp)) continue
    if (timestamp <= boundary) break

    unread++
    if (Number(entry.urgency) === CRITICAL_URGENCY)
      hasCriticalUnread = true
  }

  return {
    unread: unread,
    hasCriticalUnread: hasCriticalUnread
  }
}

function relativeTime(timestamp, now) {
  var minutes = Math.floor(Math.max(0, now - timestamp) / 60000)
  if (minutes < 1) return "now"
  if (minutes < 60) return minutes + "m ago"
  if (minutes < 1440) return Math.floor(minutes / 60) + "h ago"
  return Math.floor(minutes / 1440) + "d ago"
}

function groupsFor(entries, filter, browserGrouping, identity) {
  identity = identity || (typeof require === "function" ? require("./BrowserIdentity.js") : null)
  browserGrouping = ["browser", "hostname", "none"].indexOf(browserGrouping) >= 0 ? browserGrouping : "browser"
  var needle = String(filter || "").toLowerCase()
  var byApp = Object.create(null)
  var seen = Object.create(null)
  var groups = []
  var sorted = (Array.isArray(entries) ? entries : []).filter(function(entry) {
    return entry && entry.key
  }).sort(function(a, b) {
    return Number(b.timestamp || 0) - Number(a.timestamp || 0)
  })
  for (var i = 0; i < sorted.length; i++) {
    var entry = sorted[i]
    if (!entry || !entry.key || seen[entry.key]) continue
    seen[entry.key] = true
    var app = String(entry.app || "Unknown app")
    if (needle && [app, entry.summary || "", entry.body || ""].join(" ").toLowerCase().indexOf(needle) < 0) continue
    var browser = identity && identity.browser(entry)
    var host = identity ? identity.hostname(entry) : ""
    var key = app
    if (browserGrouping !== "browser") {
      key = JSON.stringify(browser ? ["browser", app, browserGrouping, browserGrouping === "none" ? entry.key : host] : ["app", app])
    }
    var group = byApp[key]
    if (!group) {
      group = { key: key, app: app, label: browserGrouping === "hostname" && host ? host : app, hostname: host, iconEntry: entry, appIcon: "", glyph: "", timestamp: Number(entry.timestamp || 0), critical: false, entries: [] }
      byApp[key] = group
      groups.push(group)
    }
    // A browser-wide stack with several websites has no single website favicon.
    if (group.hostname !== host) { group.hostname = ""; group.iconEntry = null }
    // Archived image fields can be avatars; only appIcon identifies the app.
    if (!group.appIcon && entry.appIcon) group.appIcon = String(entry.appIcon)
    if (!group.glyph && entry.glyph) group.glyph = String(entry.glyph)
    group.critical = group.critical || Number(entry.urgency) === CRITICAL_URGENCY
    group.entries.push(entry)
  }
  return groups
}

function stackRows(entries, expanded, filter, browserGrouping, identity) {
  var groups = groupsFor(entries, filter, browserGrouping, identity)
  var rows = []
  for (var i = 0; i < groups.length; i++) {
    var group = groups[i]
    var multiple = group.entries.length > 1
    var open = multiple && (Boolean(filter) || expanded[group.key] === true)
    rows.push({ id: "group:" + group.key, kind: "header", group: group, expanded: open })
    var visible = open ? group.entries : group.entries.slice(0, 1)
    // Flatten stacks so ListView virtualizes individual messages even in large groups.
    for (var j = 0; j < visible.length; j++) {
      rows.push({ id: "entry:" + visible[j].key, kind: "message", group: group,
        entry: visible[j], expanded: open, first: j === 0, last: j === visible.length - 1,
        layered: multiple && !open })
    }
  }
  return rows
}

if (typeof module !== "undefined") {
  module.exports = {
    isPreviewFile: isPreviewFile,
    CRITICAL_URGENCY: CRITICAL_URGENCY,
    unreadState: unreadState,
    relativeTime: relativeTime,
    groupsFor: groupsFor,
    stackRows: stackRows
  }
}
