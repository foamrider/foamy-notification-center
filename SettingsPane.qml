pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import "Preferences.js" as Preferences
import "kit"

// The center's settings sections, placed inside the kit FoamySettingsPage
// (back, "Settings", "Saving…", error line, scrolling, Esc). Center settings
// belong to this widget; the "Pop-up notifications" section is owned by Foamy
// Notifications and saved through its IPC (Panel.savePreference).
Column {
  id: root
  required property var settings
  required property var popupSettings
  property bool popupAvailable: false
  property bool popupInstalled: false
  property bool loading: false
  property bool saving: false
  // The enclosing FoamySettingsPage, to keep focused fields visible.
  property Item page: null
  signal save(string scope, string key, var value)
  // The panel reports a save that failed (Panel.finishPreference(false)).
  signal saveFailed(string scope, string key)
  spacing: FoamyStyle.sectionGap

  function current(scope, key) {
    return Preferences.value(scope, scope === "center" ? root.settings : root.popupSettings, key)
  }
  function optionLabel(option) {
    return FoamyI18n.t(Preferences.optionLabel(option))
  }

  Repeater {
    // Two scopes with look-alike rows (favicons, compact, pictures): the
    // headings and descriptions say which one each block changes.
    model: [{scope: "center", title: "Notification center", fields: Preferences.centerFields,
             description: "This list: how it groups and shows notifications, and how long it keeps them."},
            {scope: "popups", title: "Pop-up notifications", fields: Preferences.popupFields,
             description: "Notifications as they appear on screen (the Foamy Notifications plugin)."}]
    FoamySettingsSection {
      id: section
      required property var modelData
      width: root.width
      title: FoamyI18n.t(section.modelData.title)
      description: FoamyI18n.t(section.modelData.description)

      Text {
        objectName: section.modelData.scope + "-availability"
        width: parent.width
        visible: section.modelData.scope === "popups" && !root.popupAvailable
        text: FoamyI18n.t(root.loading ? "Reading settings…" : root.popupInstalled ? "Plugin not enabled" : "Plugin not installed")
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: FoamyPalette.mutedText
        font.family: FoamyStyle.fontFamily
        font.pixelSize: FoamyStyle.font.bodySmall
      }

      Repeater {
        // Keep loaded editors stable during refreshes so reads cannot steal focus.
        model: section.modelData.scope === "center" || root.popupAvailable ? section.modelData.fields : []
        Loader {
          id: field
          required property var modelData
          readonly property string scope: section.modelData.scope
          width: section.width
          enabled: !root.saving
          sourceComponent: modelData.type === "boolean" ? toggleField : modelData.type === "enum" ? choiceField : numberField

          Component {
            id: toggleField
            FoamyToggle {
              objectName: field.scope + "-" + field.modelData.key
              label: FoamyI18n.t(field.modelData.label)
              checked: root.current(field.scope, field.modelData.key) === true
              onClicked: root.save(field.scope, field.modelData.key, !checked)
            }
          }
          Component {
            id: choiceField
            // Short choices: the settings row form (label on the start, dropdown on the end).
            FoamyDropdown {
              objectName: field.scope + "-" + field.modelData.key
              width: field.width
              compact: true
              label: FoamyI18n.t(field.modelData.label)
              value: String(root.current(field.scope, field.modelData.key))
              options: field.modelData.options.map(function(option) { return { value: option, label: root.optionLabel(option) } })
              onChanged: function(next) { root.save(field.scope, field.modelData.key, next) }
            }
          }
          Component {
            id: numberField
            // kit FoamyNumberField: shows the setting (following external changes
            // while not being edited), commits a valid changed number once on
            // Enter/focus-out, and Escape restores the value and stays on the page.
            // The row form: label on the start, a narrow field and its unit on the end.
            FoamyNumberField {
              id: numberEditor
              objectName: field.scope + "-" + field.modelData.key
              width: field.width
              compact: true
              label: FoamyI18n.t(field.modelData.label)
              unit: field.modelData.unit ? FoamyI18n.t(field.modelData.unit) : ""
              value: root.current(field.scope, field.modelData.key)
              from: field.modelData.min
              to: field.modelData.max
              stepSize: field.modelData.step || 1
              onCommitted: function(next) {
                if (Preferences.valid(field.scope, field.modelData.key, next)) root.save(field.scope, field.modelData.key, next)
              }
              // A failed save leaves `value` as it was: saveFailed() shows the
              // stored value again (keeping a newer draft) and lets the same
              // number be committed again.
              Connections {
                target: root
                function onSaveFailed(scope, key) {
                  if (scope === field.scope && key === field.modelData.key) numberEditor.saveFailed()
                }
              }
            }
          }
        }
      }
    }
  }
}
