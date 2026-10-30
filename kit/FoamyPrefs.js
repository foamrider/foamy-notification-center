.pragma library
// foamy-kit 0.3.0 aeaf0e29f6d83d27bac96614f33f843116dbbd070a675b82f0301773f105624c — do not edit; change foamy-kit and run sync

// Inline widget settings: schema validation and saving, for every plugin.
//
// The bar entry in shell.json is the source of truth. A plugin keeps its
// schema next to its Panel (fields mirror manifest.json barWidget.schema):
//
//   // Preferences.js
//   var fields = [
//     { key: "showPercentage", type: "boolean", defaultValue: true },
//     { key: "layout", type: "enum", options: ["list", "tiles"], defaultValue: "list" },
//     { key: "refreshSeconds", type: "integer", min: 30, max: 3600, step: 30, defaultValue: 60 },
//     { key: "folders", type: "array", maxItems: 20, validate: function(v) { … }, defaultValue: [] },
//     { key: "route", type: "object", validate: function(v) { … }, defaultValue: null }
//   ]
//
// Most plugins should save through FoamyPrefsQueue.qml (one queue per panel:
// serialised saves, newest value per key, no merge over a stale entry,
// `saving`/`error`/`retry()`). The functions below are its engine and stay
// usable directly:
//
//   import "kit/FoamyPrefs.js" as Prefs
//   readonly property bool showPercentage: Prefs.value(Schema.fields, root.settings, "showPercentage")
//
// Saving prefers the in-process bar.shell.updateEntryInline(moduleName,
// settings), present on 4.0.6 and 4.5. It REPLACES the entry with
// { id: moduleName, ...settings }, so save() always passes the full entry
// with one key changed, never a partial object. Pass the values saved but not
// yet reflected in `settings` as `pending` so a second save in a row does not
// merge over the stale entry and undo the first. updateEntryInline returns
// false both when nothing changed and when the call is not permitted, so
// save() skips unchanged values itself and treats false as "use the CLI".
//
// CLI fallback: `omarchy bar set <id> <key> <json> --json` (same on 4.0 and
// 4.5). An array value can't go that way: on 4.0 (and whenever the 4.5
// socket is down) it ends in `qs ipc call`, whose argument parser splits a
// "[…]" argument into a list, so the call fails. Arrays go straight to the
// shell's setBarWidget with a leading space (JSON.parse ignores it), through
// `sh -c` with positional arguments, which fails unless the shell says "ok".
//
// Field types: boolean, enum (options), integer/number (min, max; `step` is a
// UI hint and not enforced), string (maxLength, pattern), array (maxItems,
// validate), object (validate). `validate(value)` returns true, or false / an
// error string. Invalid stored values read as the default (array and object
// defaults are copied, so callers can't mutate the schema).
//
// Node unit tests: require("../kit/node-loader.cjs").load("FoamyPrefs").

var NOT_ALLOWED = "That value isn't allowed."
var NO_ENTRY = "Settings can't be saved: this widget has no bar entry."

function field(fields, key) {
  for (var i = 0; i < (fields || []).length; i++) if (fields[i] && fields[i].key === key) return fields[i]
  return null
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

// "" when `value` is valid for `key`, else a message (the field's own, if
// validate() returned one).
function problem(fields, key, value) {
  var f = field(fields, key)
  if (!f) return NOT_ALLOWED
  var ok = true
  switch (f.type) {
  case "boolean":
    ok = typeof value === "boolean"
    break
  case "enum":
    ok = typeof value === "string" && (f.options || []).indexOf(value) >= 0
    break
  case "integer":
  case "number":
    ok = typeof value === "number" && isFinite(value)
      && (f.type !== "integer" || Math.floor(value) === value)
      && (f.min === undefined || value >= f.min)
      && (f.max === undefined || value <= f.max)
    break
  case "string":
    ok = typeof value === "string"
      && (f.maxLength === undefined || value.length <= f.maxLength)
      && (f.pattern === undefined || (new RegExp(f.pattern)).test(value))
    break
  case "array":
    ok = Array.isArray(value) && (f.maxItems === undefined || value.length <= f.maxItems)
    break
  case "object":
    ok = isPlainObject(value)
    break
  default:
    ok = false
  }
  if (!ok) return NOT_ALLOWED
  if ((f.type === "array" || f.type === "object") && typeof f.validate === "function") {
    var verdict
    try { verdict = f.validate(value) } catch (error) { verdict = false }
    if (verdict !== true) return typeof verdict === "string" && verdict !== "" ? verdict : NOT_ALLOWED
  }
  return ""
}

function valid(fields, key, value) {
  return problem(fields, key, value) === ""
}

function clone(value) {
  return value === undefined ? undefined : JSON.parse(JSON.stringify(value))
}

function value(fields, settings, key) {
  var f = field(fields, key)
  if (!f) return undefined
  if (settings && valid(fields, key, settings[key])) return settings[key]
  return f.type === "array" || f.type === "object" ? clone(f.defaultValue) : f.defaultValue
}

// Every schema key with its effective value.
function values(fields, settings) {
  var out = {}
  for (var i = 0; i < (fields || []).length; i++) out[fields[i].key] = value(fields, settings, fields[i].key)
  return out
}

// JSON with object keys sorted, so equal settings compare equal whatever
// order the host keeps them in.
function canonical(value) {
  if (Array.isArray(value)) return "[" + value.map(canonical).join(",") + "]"
  if (isPlainObject(value)) {
    var keys = Object.keys(value).filter(function(k) { return value[k] !== undefined }).sort()
    return "{" + keys.map(function(k) { return JSON.stringify(k) + ":" + canonical(value[k]) }).join(",") + "}"
  }
  return value === undefined ? "undefined" : JSON.stringify(value)
}

function equal(a, b) {
  return canonical(a) === canonical(b)
}

// `settings` with the saved-but-unreflected `pending` values on top.
function overlay(settings, pending) {
  var out = {}
  if (isPlainObject(settings)) for (var k in settings) out[k] = settings[k]
  if (isPlainObject(pending)) for (var p in pending) out[p] = pending[p]
  return out
}

// `pending` minus the keys `settings` now reflects.
function settle(settings, pending) {
  var out = {}
  if (!isPlainObject(pending)) return out
  for (var k in pending)
    if (!(isPlainObject(settings) && equal(settings[k], pending[k]))) out[k] = pending[k]
  return out
}

// The full entry to persist: the current entry (unknown keys kept, `id`
// dropped because the host adds it) with `key` set to `next`.
function merged(settings, key, next) {
  var out = {}
  if (isPlainObject(settings))
    for (var k in settings) if (k !== "id" && settings[k] !== undefined) out[k] = settings[k]
  out[key] = next
  return out
}

var SET_BAR_WIDGET = 'out=$(omarchy-shell shell setBarWidget "$1" "$2" "$3" "{}") || exit 1; [ "$out" = ok ] && exit 0; printf "%s\\n" "$out" >&2; exit 1'

function saveCommand(moduleName, key, next) {
  var json = JSON.stringify(next)
  if (json.charAt(0) === "[")
    return ["sh", "-c", SET_BAR_WIDGET, "foamy-prefs", String(moduleName), String(key), " " + json]
  return ["omarchy", "bar", "set", String(moduleName), String(key), json, "--json"]
}

function canSaveInline(bar) {
  return !!(bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
}

// { ok, changed, inline, command, settings, error }. `command` is non-empty
// only when the caller must run it (inline save unavailable or refused).
// `pending`: values saved earlier that `settings` doesn't show yet.
function save(bar, moduleName, fields, settings, key, next, pending) {
  var result = { ok: false, changed: false, inline: false, command: [], settings: null, error: "" }
  if (!moduleName) { result.error = NO_ENTRY; return result }
  var issue = problem(fields, key, next)
  if (issue) { result.error = issue; return result }
  var effective = overlay(settings, pending)
  result.settings = merged(effective, key, next)
  result.ok = true
  if (equal(effective[key], next)) return result
  result.changed = true
  if (canSaveInline(bar)) {
    try {
      if (bar.shell.updateEntryInline(String(moduleName), result.settings) === true) {
        result.inline = true
        return result
      }
    } catch (error) {
      console.warn("foamy-kit: inline save failed, using the CLI:", error)
    }
  }
  result.command = saveCommand(moduleName, key, next)
  return result
}

if (typeof module !== "undefined") module.exports = {
  NOT_ALLOWED: NOT_ALLOWED, NO_ENTRY: NO_ENTRY, field: field, problem: problem, valid: valid, value: value,
  values: values, canonical: canonical, equal: equal, overlay: overlay, settle: settle, merged: merged,
  saveCommand: saveCommand, canSaveInline: canSaveInline, save: save
}
