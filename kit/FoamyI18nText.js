.pragma library
// foamy-kit 0.9.0 a541e98f164e6c2e83b493341e50b128ba539dc4f32cf2253fb688731a513c3c — do not edit; change foamy-kit and run sync

// FoamyI18n's string work without the shell: value substitution, and t()/tn()
// over plain catalogs for node unit tests. FoamyI18n.qml substitutes through
// this file, so a node test exercises the same code the panel runs.
//
//   const I18n = require("../kit/node-loader.cjs").load("FoamyI18nText")
//   const { t, tn } = I18n.translator(require("../i18n/no.json"), require("../i18n/en.json"))
//   t("Updated %1 minutes ago", 5); tn("%1 devices", 1)
//
// substitute(text, values, number): %1… take values[0]… (a lone value fills
// %1), {name} takes values.name; numbers go through number() (default
// String). Each hole is filled once, so a value holding "%2" or "{x}" stays
// literal, and so do replacement patterns like "$&". A hole without a value
// stays as written.

function substitute(text, values, number) {
  var format = typeof number === "function" ? number : String
  return String(text).replace(/%([1-9][0-9]*)|\{(\w+)\}/g, function(token, index, name) {
    if (values === undefined || values === null) return token
    var value = name ? values[name] : Array.isArray(values) ? values[Number(index) - 1] : Number(index) === 1 ? values : undefined
    return value === undefined ? token : typeof value === "number" ? format(value) : String(value)
  })
}

function lookup(catalogs, key) {
  for (var i = 0; i < catalogs.length; i++) {
    var catalog = catalogs[i]
    if (catalog && Object.prototype.hasOwnProperty.call(catalog, key)) {
      var value = catalog[key]
      if ((typeof value === "string" && value !== "") || (value && typeof value === "object")) return value
    }
  }
  return undefined
}

// { t(key, values), tn(key, count, values) } over `catalog`, then `english`,
// then the key, like the shell's Translations. Plural entries pick `one` for
// a count of ±1 and `other` otherwise (English and Norwegian rules; the live
// shell applies each language's CLDR rules).
function translator(catalog, english, number) {
  var catalogs = [catalog, english]
  function form(value, count) {
    if (value && typeof value === "object")
      value = count !== undefined && Math.abs(Number(count)) === 1 && typeof value.one === "string" ? value.one : value.other
    return value
  }
  return {
    t: function(key, values) {
      var value = form(lookup(catalogs, key))
      return substitute(typeof value === "string" && value !== "" ? value : key, values, number)
    },
    tn: function(key, count, values) {
      var value = form(lookup(catalogs, key), count)
      return substitute(typeof value === "string" && value !== "" ? value : key, values === undefined ? [count] : values, number)
    }
  }
}

if (typeof module !== "undefined") module.exports = { substitute: substitute, translator: translator }
