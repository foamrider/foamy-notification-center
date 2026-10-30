pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import qs.Ui
import qs.Commons
import qs.Commons as Commons
import "../Preferences.js" as Preferences
import "../kit"

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
  signal pasteFailed(string message)
  function tr(label) { return FoamyI18n.t(label) }
  Loader {
    width: parent.width
    active: root.field.type === "enum"
    visible: active
    sourceComponent: Component {
      SettingsDropdown {
        objectName: root.scope + "-" + root.field.key
        width: parent.width
        label: root.tr(root.field.label)
        fontFamily: FoamyStyle.fontFamily
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
      BorderSurface {
        id: toggle
        objectName: root.scope + "-" + root.field.key
        property string label: root.tr(root.field.label)
        property bool checked: root.current === true
        signal clicked()
        width: parent.width
        // Settings labels must remain readable when translations wrap on narrow panels.
        implicitHeight: Math.max(Style.space(36), toggleContent.implicitHeight + Style.space(16))
        color: "transparent"
        borderSpec: activeFocus ? Border.flat(Commons.Color.accent, 1) : Border.none()
        radius: FoamyStyle.radius
        activeFocusOnTab: true
        Keys.onReturnPressed: clicked()
        Keys.onEnterPressed: clicked()
        Keys.onSpacePressed: clicked()
        Accessible.role: Accessible.CheckBox
        Accessible.name: label
        Accessible.checkable: true
        Accessible.checked: checked
        Accessible.onToggleAction: if (enabled) root.save(!checked)
        onClicked: root.save(!checked)
        RowLayout {
          id: toggleContent
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: toggle.borderLeft + Style.spacing.rowPaddingX
          anchors.rightMargin: toggle.borderRight + Style.spacing.rowPaddingX
          spacing: Style.spacing.rowPaddingX
          Text {
            Layout.fillWidth: true
            text: toggle.label
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: Commons.Color.popups.text
            font.family: FoamyStyle.fontFamily
            font.pixelSize: Style.space(13)
            font.bold: true
          }
          ToggleSwitch {
            checked: toggle.checked
            interactive: false
            foreground: Commons.Color.popups.text
          }
        }
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: toggle.clicked()
        }
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
          color: Commons.Color.popups.text
          font.family: FoamyStyle.fontFamily
          font.pixelSize: Style.space(13)
        }
        SafeTextField {
          id: input
          objectName: root.scope + "-" + root.field.key
          Layout.preferredWidth: Style.space(68)
          implicitHeight: Style.space(34)
          text: String(root.current)
          color: Commons.Color.popups.text
          font.family: FoamyStyle.fontFamily
          font.pixelSize: Style.space(12)
          padding: Style.space(7)
          Accessible.name: root.tr(root.field.label)
          background: Rectangle {
            radius: FoamyStyle.radius
            color: Qt.alpha(Commons.Color.popups.text, 0.055)
            border.width: input.inputActiveFocus ? 1 : 0
            border.color: Commons.Color.accent
          }
          translate: root.tr
          onPasteErrorChanged: if (pasteError !== "") root.pasteFailed(pasteError)
          onTextEdited: root.clearError()
          onEditingFinished: {
            if (!root.visible || !root.enabled) return
            var next = text.trim() === "" ? NaN : Number(text)
            if (next !== root.current) root.save(next)
          }
          // Cancel the editor without saving an unfinished value on Escape.
          onKeyPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
              event.accepted = true
              text = Qt.binding(function() { return String(root.current) })
              root.forceActiveFocus()
            }
          }
          HoverHandler { id: numberHover }
          PanelToolTip {
            visible: numberHover.hovered || input.inputActiveFocus
            text: root.field.min + "–" + root.field.max
            fontFamily: FoamyStyle.fontFamily
          }
        }
      }
    }
  }
}
