pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import qs.Ui
import qs.Commons
import "../Preferences.js" as Preferences
import "../Translations.js" as Translations

Column {
  id: root
  objectName: scope + "-" + field.key + "Field"
  required property string scope
  required property var field
  required property var settings
  required property string language
  readonly property var current: Preferences.value(scope, settings, field.key)
  signal save(var value)
  signal clearError()
  function tr(label) { return Translations.text(label, language) }
  Loader {
    width: parent.width
    active: root.field.type === "enum"
    visible: active
    sourceComponent: Component {
      SettingsDropdown {
        objectName: root.scope + "-" + root.field.key
        width: parent.width
        label: root.tr(root.field.label)
        fontFamily: "sans-serif"
        value: String(root.current)
        options: root.field.options.map(function(value) { return {value:value,label:root.tr(Preferences.optionLabel(value))} })
        onChanged: function(value) { root.save(value) }
      }
    }
  }
  Loader {
    width: parent.width
    active: root.field.type === "boolean"
    visible: active
    sourceComponent: Component {
      Toggle {
        objectName: root.scope + "-" + root.field.key
        width: parent.width
        implicitHeight: Style.space(36)
        color: "transparent"
        borderSpec: activeFocus ? Border.flat(Color.accent, 1) : Border.none()
        radius: Style.cornerRadius * 2
        foreground: Color.popups.text
        fontFamily: "sans-serif"
        titleSize: Style.space(13)
        label: root.tr(root.field.label)
        checked: root.current === true
        Accessible.role: Accessible.CheckBox
        Accessible.name: label
        Accessible.checkable: true
        Accessible.checked: checked
        Accessible.onToggleAction: if (enabled) root.save(!checked)
        onClicked: root.save(!checked)
      }
    }
  }
  Loader {
    width: parent.width
    active: root.field.type === "integer"
    visible: active
    sourceComponent: Component {
      RowLayout {
        width: parent.width
        spacing: Style.space(12)
        Text {
          Layout.fillWidth: true
          text: root.tr(root.field.label)
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: Color.popups.text
          font.family: "sans-serif"
          font.pixelSize: Style.space(13)
        }
        Controls.TextField {
          id: input
          objectName: root.scope + "-" + root.field.key
          Layout.preferredWidth: Style.space(68)
          implicitHeight: Style.space(34)
          text: String(root.current)
          selectByMouse: true
          color: Color.popups.text
          font.family: "sans-serif"
          font.pixelSize: Style.space(12)
          padding: Style.space(7)
          Accessible.name: root.tr(root.field.label)
          background: Rectangle {
            radius: Style.cornerRadius * 2
            color: Qt.alpha(Color.popups.text, 0.055)
            border.width: input.activeFocus ? 1 : 0
            border.color: Color.accent
          }
          onTextEdited: root.clearError()
          onEditingFinished: {
            if (!root.visible || !root.enabled) return
            var next = text.trim() === "" ? NaN : Number(text)
            if (next !== root.current) root.save(next)
          }
          // Cancel the editor without saving an unfinished value on Escape.
          Keys.onEscapePressed: { text = Qt.binding(function() { return String(root.current) }); root.forceActiveFocus(); }
          HoverHandler { id: numberHover }
          PanelToolTip {
            visible: numberHover.hovered || input.activeFocus
            text: root.field.min + "–" + root.field.max
            fontFamily: "sans-serif"
          }
        }
      }
    }
  }
}
