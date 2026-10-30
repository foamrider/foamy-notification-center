pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import "Preferences.js" as Preferences
import "kit"

// The center's settings sections, placed inside the kit FoamySettingsPage
// (back, "Settings", "Saving…", error line, scrolling, Esc). Center settings
// belong to this widget; the "Foamy Notifications" section is owned by that
// plugin and saved through its IPC (Panel.savePreference).
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
  signal pasteFailed(string message)
  spacing: FoamyStyle.sectionGap

  function current(scope, key) {
    return Preferences.value(scope, scope === "center" ? root.settings : root.popupSettings, key)
  }
  function optionLabel(option) {
    return FoamyI18n.t(Preferences.optionLabel(option))
  }

  Repeater {
    model: [{scope: "center", title: "Notification center", fields: Preferences.centerFields},
            {scope: "popups", title: "Foamy Notifications", fields: Preferences.popupFields}]
    FoamySettingsSection {
      id: section
      required property var modelData
      width: root.width
      title: FoamyI18n.t(section.modelData.title)

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
            FoamyDropdown {
              objectName: field.scope + "-" + field.modelData.key
              label: FoamyI18n.t(field.modelData.label)
              value: String(root.current(field.scope, field.modelData.key))
              options: field.modelData.options.map(function(option) { return { value: option, label: root.optionLabel(option) } })
              onChanged: function(next) { root.save(field.scope, field.modelData.key, next) }
            }
          }
          Component {
            id: numberField
            RowLayout {
              id: numberRow
              spacing: FoamyStyle.gap
              Text {
                Layout.fillWidth: true
                text: FoamyI18n.t(field.modelData.label)
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: FoamyPalette.text
                font.family: FoamyStyle.fontFamily
                font.pixelSize: FoamyStyle.font.body
              }
              SafeTextField {
                id: input
                objectName: field.scope + "-" + field.modelData.key
                Layout.preferredWidth: Style.space(76)
                implicitHeight: FoamyStyle.controlHeight
                horizontalAlignment: Text.AlignRight
                text: String(root.current(field.scope, field.modelData.key))
                translate: FoamyI18n.t
                Accessible.name: FoamyI18n.t(field.modelData.label)
                onPasteErrorChanged: if (pasteError !== "") root.pasteFailed(pasteError)
                onInputActiveFocusChanged: if (inputActiveFocus && root.page) root.page.keepVisible(numberRow)
                function commit() {
                  var value = Number(text.trim())
                  if (/^[0-9]+$/.test(text.trim()) && Preferences.valid(field.scope, field.modelData.key, value)) {
                    if (value !== root.current(field.scope, field.modelData.key)) root.save(field.scope, field.modelData.key, value)
                  } else text = String(root.current(field.scope, field.modelData.key))
                }
                onEditingFinished: commit()
                onAccepted: commit()
              }
            }
          }
        }
      }
    }
  }
}
