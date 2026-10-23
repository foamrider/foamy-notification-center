pragma Singleton
import QtQuick

QtObject {
  id: root
  property var backend: null
  readonly property string language: backend ? backend.language : "en"
  readonly property string formatLocale: backend ? backend.formatLocale : "en-US"
  readonly property bool rightToLeft: backend ? backend.rightToLeft : false

  Component.onCompleted: {
    // Resolve the 4.5 type at runtime so 4.0 can still load the plugin in English.
    try {
      backend = Qt.createQmlObject('import qs.Commons; Translations { readonly property string formatLocale: I18n.formatLocale; readonly property bool rightToLeft: I18n.rightToLeft; function number(value, decimals) { return I18n.formatNumber(value, decimals) } }', root, "FoamyTranslations")
      backend.directory = Qt.resolvedUrl("i18n")
    } catch (error) {
      console.info("Foamy translations unavailable; using English:", error.message)
    }
  }

  function t(key, values) {
    var text = backend ? backend.t(key, key) : key
    // Substitute once: user-controlled names containing %1 or $ stay literal.
    return String(text).replace(/%([1-9][0-9]*)|\{(\w+)\}/g, function(token, index, name) {
      if (values === undefined || values === null) return token
      var value = name ? values[name] : Array.isArray(values) ? values[Number(index) - 1] : Number(index) === 1 ? values : undefined
      return value === undefined ? token : String(value)
    })
  }

  function number(value, decimals) {
    return backend ? backend.number(value, decimals) : decimals === undefined ? String(value) : Number(value).toFixed(decimals)
  }
}
