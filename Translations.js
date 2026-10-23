// Relative time remains pure; the view supplies the live translator.

function relativeTime(timestamp, now, tr) {
  tr = tr || function(label, value) { return value === undefined ? label : label.replace("%1", String(value)) }
  var minutes = Math.floor(Math.max(0, now - timestamp) / 60000)
  if (minutes < 1) return tr("now")
  if (minutes < 60) return tr("%1m ago", minutes)
  if (minutes < 1440) return tr("%1h ago", Math.floor(minutes / 60))
  return tr("%1d ago", Math.floor(minutes / 1440))
}

if (typeof module !== "undefined") module.exports = {   relativeTime: relativeTime, }
