pragma Singleton
// foamy-kit 0.9.0 ef1cbd050ad9980e584bd165d7a6e3543cfb9da7de868e7a86f16159ff1ecd9d — do not edit; change foamy-kit and run sync
import QtQuick
import qs.Commons
import "FoamyI18nText.js" as I18nText

// Plugin strings with the Omarchy language picker.
//
// Catalogs live in the plugin's i18n/ directory (en.json, da.json, …), keyed
// by their English text, and are read by the shell's Commons.Translations:
// a string missing from the picked language falls back to its base
// language, then to en.json, then to the key itself.
//
//   FoamyI18n.t("Updated %1 minutes ago", minutes)     %1 / {name} holes
//   FoamyI18n.tn("%1 devices", count)                  plural entry {"one":…,"other":…}
//   FoamyI18n.number(13.14, 1)                         "13,1" in Danish, ungrouped
//   FoamyI18n.updatedAgo(updatedMs, nowMs)             "Updated 3 hours ago"
//   Qt.locale(FoamyI18n.formatLocale)                  dates follow the picked language
//
// Numeric hole values go through number() (ungrouped, so ports and years stay
// intact). User-controlled values are substituted once, so a name containing
// %1 or {x} stays literal.
QtObject {
  id: root
  // The plugin's catalogs: kit/ sits in the plugin root, beside i18n/.
  property url catalogDirectory: Qt.resolvedUrl("../i18n")
  property Translations backend: Translations {
    directory: root.catalogDirectory
  }
  readonly property string language: backend.language
  readonly property string formatLocale: I18n.formatLocale
  readonly property bool rightToLeft: I18n.rightToLeft
  // Always true since kit 0.9.0 (Omarchy 4.5 only); kept for plugins that
  // still read it.
  readonly property bool translationsAvailable: true

  // Node tests reach the same substitution through FoamyI18nText.js.
  function substitute(text, values) {
    return I18nText.substitute(text, values, root.number)
  }

  function t(key, values) {
    return substitute(backend.t(key, key), values)
  }

  // Plural form of `key` for `count`. %1 is the count unless `values` says otherwise.
  function tn(key, count, values) {
    return substitute(backend.tn(key, count, key), values === undefined ? [count] : values)
  }

  // A footer's freshness: just now, then minutes, hours and days. The plugin's
  // catalogs carry "Updated just now" and the plural entries "Updated %1
  // minutes ago", "Updated %1 hours ago" and "Updated %1 days ago".
  // "" without a time.
  function updatedAgo(updatedMs, nowMs) {
    var updated = Number(updatedMs)
    if (!isFinite(updated) || updated <= 0)
      return ""
    var minutes = Math.max(0, Math.floor((Number(nowMs === undefined ? Date.now() : nowMs) - updated) / 60000))
    if (minutes === 0)
      return t("Updated just now")
    if (minutes < 60)
      return tn("Updated %1 minutes ago", minutes)
    var hours = Math.floor(minutes / 60)
    if (hours < 24)
      return tn("Updated %1 hours ago", hours)
    return tn("Updated %1 days ago", Math.floor(hours / 24))
  }

  function number(value, decimals) {
    return I18n.formatNumber(value, decimals)
  }
}
