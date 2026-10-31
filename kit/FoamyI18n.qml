pragma Singleton
// foamy-kit 0.4.0 e2f6c278c7432824fd946f47c487edbcca3aa2341adb20f621c5dbaff6f12899 — do not edit; change foamy-kit and run sync
import QtQuick
import Quickshell.Io

// Plugin strings with the 4.5 language picker, English on 4.0.
//
// Catalogs live in the plugin's i18n/ directory (en.json, da.json, …), keyed
// by their English text. On 4.5 the shell's Commons.Translations type is
// created at runtime so 4.0 can still load the plugin; on 4.0 strings come
// from i18n/en.json (or the key itself).
//
//   FoamyI18n.t("Updated %1 minutes ago", minutes)     %1 / {name} holes
//   FoamyI18n.tn("%1 devices", count)                  plural entry {"one":…,"other":…}
//   FoamyI18n.number(13.14, 1)                         "13,1" in Danish, ungrouped
//   Qt.locale(FoamyI18n.formatLocale)                  dates follow the picked language
//
// Numeric hole values go through number() (ungrouped, so ports and years stay
// intact). User-controlled values are substituted once, so a name containing
// %1 or {x} stays literal.
QtObject {
  id: root
  property var backend: null
  // The plugin's catalogs: kit/ sits in the plugin root, beside i18n/.
  property url catalogDirectory: Qt.resolvedUrl("../i18n")
  readonly property string language: backend ? backend.language : "en"
  // 4.0 keeps the system calendar locale rather than forcing en-US.
  readonly property string formatLocale: backend ? backend.formatLocale : Qt.locale().name
  readonly property bool rightToLeft: backend ? backend.rightToLeft : false
  readonly property bool translationsAvailable: backend !== null

  Component.onCompleted: {
    // Resolve the 4.5 type at runtime so 4.0 can still load the plugin in English.
    try {
      backend = Qt.createQmlObject('import qs.Commons; Translations { readonly property string formatLocale: I18n.formatLocale; readonly property bool rightToLeft: I18n.rightToLeft; function number(value, decimals) { return I18n.formatNumber(value, decimals) } }', root, "FoamyTranslations")
      backend.directory = root.catalogDirectory
    } catch (error) {
      backend = null
      console.info("Foamy translations unavailable; using English:", error.message)
    }
  }

  // 4.0 only: English catalog, for plural entries and English overrides.
  readonly property var english: backend ? ({}) : parseCatalog(englishFile.text())
  property FileView englishFile: FileView {
    path: root.backend ? "" : String(root.catalogDirectory).replace(/^file:\/\//, "") + "/en.json"
    printErrors: false
    blockLoading: true
  }

  function parseCatalog(raw) {
    try {
      var parsed = JSON.parse(raw || "{}")
      return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : ({})
    } catch (error) {
      return ({})
    }
  }

  function englishText(key, count) {
    var value = english[key]
    if (value && typeof value === "object")
      value = count !== undefined && Math.abs(Number(count)) === 1 && typeof value.one === "string" ? value.one : value.other
    return typeof value === "string" && value.length > 0 ? value : key
  }

  function substitute(text, values) {
    return String(text).replace(/%([1-9][0-9]*)|\{(\w+)\}/g, function(token, index, name) {
      if (values === undefined || values === null) return token
      var value = name ? values[name] : Array.isArray(values) ? values[Number(index) - 1] : Number(index) === 1 ? values : undefined
      return value === undefined ? token : typeof value === "number" ? root.number(value) : String(value)
    })
  }

  function t(key, values) {
    return substitute(backend ? backend.t(key, key) : englishText(key), values)
  }

  // Plural form of `key` for `count`. %1 is the count unless `values` says otherwise.
  function tn(key, count, values) {
    var text = backend && typeof backend.tn === "function" ? backend.tn(key, count, englishText(key, count)) : englishText(key, count)
    return substitute(text, values === undefined ? [count] : values)
  }

  function number(value, decimals) {
    if (backend) return backend.number(value, decimals)
    return decimals === undefined ? String(value) : Number(value).toFixed(decimals)
  }
}
