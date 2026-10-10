// UI language is configured on the widget in shell.json, like other Foamy plugins.
var norwegian = {
  "Notifications": "Varsler",
  "Notification Center": "Varselsenter",
  "Settings": "Innstillinger",
  "Back": "Tilbake",
  "More options": "Flere valg",
  "Saving…": "Lagrer…",
  "Reading settings…": "Leser innstillinger…",
  "Plugin not installed": "Utvidelsen er ikke installert",
  "Plugin not enabled": "Utvidelsen er ikke aktivert",
  "Could not read Foamy Notifications settings. Reopen Settings to retry.": "Kunne ikke lese innstillingene for Foamy Notifications. Åpne Innstillinger på nytt for å prøve igjen.",
  "Could not save settings. Try again.": "Kunne ikke lagre innstillingene. Prøv igjen.",
  "Invalid setting.": "Ugyldig innstilling.",
  "Group browser notifications by": "Grupper nettleservarsler etter",
  "Use website favicons": "Bruk nettstedsikoner",
  "Compact view": "Kompakt visning",
  "Keep notifications (days)": "Behold varsler (dager)",
  "Maximum notifications": "Maks antall varsler",
  "Group duplicate notifications": "Grupper like varsler",
  "Normal notification duration (seconds)": "Visningstid for vanlige varsler (sekunder)",
  "Browser": "Nettleser",
  "Hostname": "Vertsnavn",
  "Do not group": "Ikke grupper",
  "Show pictures": "Vis bilder",
  "Do not disturb": "Ikke forstyrr",
  "1 unread": "1 ulest",
  "%1 unread": "%1 uleste",
  "Silenced · %1 new": "Dempet · %1 nye",
  "Notifications silenced": "Varsler er dempet",
  "1 new notification": "1 nytt varsel",
  "%1 new notifications": "%1 nye varsler",
  "Allow notifications": "Tillat varsler",
  "Silence notifications": "Demp varsler",
  "Clear all notifications": "Tøm alle varsler",
  "Search notifications  ( / )": "Søk i varsler  ( / )",
  "Search": "Søk",
  "Close search  ( Esc )": "Lukk søk  ( Esc )",
  "Dismiss notification": "Fjern varsel",
  "Dismiss 1 notification": "Fjern 1 varsel",
  "Dismiss %1 notifications": "Fjern %1 varsler",
  "Reading the archive…": "Leser arkivet…",
  "Nothing matches “%1”": "Ingen treff for «%1»",
  "Nothing has come in yet": "Ingen varsler ennå",
  "Unknown app": "Ukjent app",
  "Could not dismiss notifications. Try again.": "Kunne ikke fjerne varslene. Prøv igjen.",
  "Could not update notification silencing. Try again.": "Kunne ikke endre varseldemping. Prøv igjen.",
  "now": "nå",
  "%1m ago": "%1 min siden",
  "%1h ago": "%1 t siden",
  "%1d ago": "%1 d siden"
}

function language(mode, locale) {
  if (mode === "en" || mode === "nb") return mode
  return /^(nb|nn|no)(_|-|$)/i.test(locale || "") ? "nb" : "en"
}

function text(label, lang, value) {
  var translated = lang === "nb" && Object.prototype.hasOwnProperty.call(norwegian, label) ? norwegian[label] : label
  // Callback replacement keeps sender-controlled search strings literal (including $&).
  return value === undefined ? translated : translated.replace(/%1/g, function() { return String(value) })
}

function relativeTime(timestamp, now, lang) {
  var minutes = Math.floor(Math.max(0, now - timestamp) / 60000)
  if (minutes < 1) return text("now", lang)
  if (minutes < 60) return text("%1m ago", lang, minutes)
  if (minutes < 1440) return text("%1h ago", lang, Math.floor(minutes / 60))
  return text("%1d ago", lang, Math.floor(minutes / 1440))
}

if (typeof module !== "undefined") module.exports = { language: language, text: text, relativeTime: relativeTime, norwegian: norwegian }
