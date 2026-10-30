.pragma library
// foamy-kit 0.1.0 1673920bcb77b1d1b7519713fadc127e6942de1ad0e18c2fd7685e38e8d91e66 — do not edit; change foamy-kit and run sync

// Inline widget settings: schema validation and saving, for every plugin.
//
// The bar entry in shell.json is the source of truth. A plugin keeps its
// schema next to its Panel (fields mirror manifest.json barWidget.schema):
//
//   // Preferences.js
//   var fields = [
//     { key: "showPercentage", type: "boolean", defaultValue: true },
//     { key: "layout", type: "enum", options: ["list", "tiles"], defaultValue: "list" },
//     { key: "refreshSeconds", type: "integer", min: 30, max: 3600, step: 30, defaultValue: 60 }
//   ]
//
//   import "kit/FoamyPrefs.js" as Prefs
//   import "Preferences.js" as Schema
//   readonly property bool showPercentage: Prefs.value(Schema.fields, root.settings, "showPercentage")
//   function save(key, next) {
//     var result = Prefs.save(root.bar, root.moduleName, Schema.fields, root.settings, key, next)
//     if (!result.ok) root.settingsError = result.error
//     else if (result.command.length) { saveProcess.command = result.command; saveProcess.running = true }
//   }
//
// Saving prefers the in-process bar.shell.updateEntryInline(moduleName,
// settings), present on 4.0.6 and 4.5. It REPLACES the entry with
// { id: moduleName, ...settings }, so save() always passes the full current
// entry with one key changed, never a partial object. It returns false both
// when nothing changed and when the call is not permitted, so save() skips
// unchanged values itself and treats false as "use the CLI": the returned
// `omarchy bar set <id> <key> <json> --json` command (same on both versions).
//
// Field types: boolean, enum (options), integer/number (min, max, step),
// string (maxLength, pattern). Invalid stored values read as the default.
// `step` is not enforced (values set from the CLI stay valid).

function field(fields, key) {
  for (var i = 0; i < (fields || []).length; i++) if (fields[i] && fields[i].key === key) return fields[i]
  return null
}

function valid(fields, key, value) {
  var f = field(fields, key)
  if (!f) return false
  switch (f.type) {
  case "boolean":
    return typeof value === "boolean"
  case "enum":
    return typeof value === "string" && (f.options || []).indexOf(value) >= 0
  case "integer":
  case "number":
    if (typeof value !== "number" || !isFinite(value)) return false
    if (f.type === "integer" && Math.floor(value) !== value) return false
    if (f.min !== undefined && value < f.min) return false
    // step is a UI hint (as in manifest schemas); it is not enforced.
    if (f.max !== undefined && value > f.max) return false
    return true
  case "string":
    if (typeof value !== "string") return false
    if (f.maxLength !== undefined && value.length > f.maxLength) return false
    if (f.pattern !== undefined && !(new RegExp(f.pattern)).test(value)) return false
    return true
  }
  return false
}

function value(fields, settings, key) {
  var f = field(fields, key)
  if (!f) return undefined
  return settings && valid(fields, key, settings[key]) ? settings[key] : f.defaultValue
}

// Every schema key with its effective value.
function values(fields, settings) {
  var out = {}
  for (var i = 0; i < (fields || []).length; i++) out[fields[i].key] = value(fields, settings, fields[i].key)
  return out
}

// The full entry to persist: the current entry (unknown keys kept, `id`
// dropped because the host adds it) with `key` set to `next`.
function merged(settings, key, next) {
  var out = {}
  if (settings && typeof settings === "object")
    for (var k in settings) if (k !== "id" && settings[k] !== undefined) out[k] = settings[k]
  out[key] = next
  return out
}

function saveCommand(moduleName, key, next) {
  return ["omarchy", "bar", "set", String(moduleName), String(key), JSON.stringify(next), "--json"]
}

function canSaveInline(bar) {
  return !!(bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
}

// { ok, changed, inline, command, settings, error }. `command` is non-empty
// only when the caller must run it (inline save unavailable or refused).
function save(bar, moduleName, fields, settings, key, next) {
  var result = { ok: false, changed: false, inline: false, command: [], settings: null, error: "" }
  if (!moduleName) { result.error = "Settings can't be saved: this widget has no bar entry."; return result }
  if (!valid(fields, key, next)) { result.error = "That value isn't allowed."; return result }
  result.settings = merged(settings, key, next)
  result.ok = true
  var current = settings && typeof settings === "object" ? settings[key] : undefined
  if (JSON.stringify(current) === JSON.stringify(next)) return result
  result.changed = true
  if (canSaveInline(bar)) {
    try {
      if (bar.shell.updateEntryInline(String(moduleName), result.settings) === true) {
        result.inline = true
        return result
      }
    } catch (error) {
      console.warn("foamy-kit: inline save failed, using omarchy bar set:", error)
    }
  }
  result.command = saveCommand(moduleName, key, next)
  return result
}

if (typeof module !== "undefined") module.exports = { field: field, valid: valid, value: value, values: values, merged: merged, saveCommand: saveCommand, canSaveInline: canSaveInline, save: save }
