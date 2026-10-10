pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import qs.Ui
import qs.Commons
import "Preferences.js" as Preferences
import "Translations.js" as Translations
import "components"

Item {
  id: root
  required property var settings
  required property var popupSettings
  required property string language
  property bool popupAvailable: false
  property bool popupInstalled: false
  property bool loading: false
  property bool saving: false
  property string error: ""
  readonly property color secondary: Qt.tint(Color.popups.background, Qt.alpha(Color.popups.text, 0.7))
  readonly property int padding: Style.space(20)
  implicitHeight: settingsHeader.height + settingsBody.implicitHeight
  signal save(string scope, string key, var value)
  signal back()
  signal clearError()
  function tr(label) { return Translations.text(label, language) }
  function focusBack() { backButton.forceActiveFocus() }
  function resetScroll() { settingsScroll.contentY = 0 }
  Keys.onEscapePressed: root.back()

  // Keep native Tab focus visible when the complete settings page needs to scroll.
  function keepFocusVisible(item) {
    if (!visible || !item) return
    var ancestor = item
    while (ancestor && ancestor !== settingsScroll.contentItem) ancestor = ancestor.parent
    if (!ancestor) return
    var point = item.mapToItem(settingsScroll.contentItem, 0, 0)
    if (point.y < settingsScroll.contentY) settingsScroll.contentY = Math.max(0, point.y - Style.space(8))
    else if (point.y + item.height > settingsScroll.contentY + settingsScroll.height)
      settingsScroll.contentY = Math.max(0, Math.min(settingsScroll.contentHeight - settingsScroll.height, point.y + item.height - settingsScroll.height + Style.space(8)))
  }
  Connections {
    target: root.Window.window
    function onActiveFocusItemChanged() { root.keepFocusVisible(target.activeFocusItem) }
  }
  Item {
    id: settingsHeader
    width: parent.width
    height: headerRow.implicitHeight + root.padding * 2
    RowLayout {
      id: headerRow
      anchors.centerIn: parent
      width: root.width - root.padding * 2
      NotificationAction {
        id: backButton
        objectName: "settingsBack"
        iconName: "back"
        foreground: root.secondary
        tooltipText: root.tr("Back")
        onClicked: root.back()
      }
      Text { text: root.tr("Settings"); color: root.secondary; font.family: "sans-serif"; font.pixelSize: Style.space(13); Layout.fillWidth: true }
      Text { visible: root.saving; text: root.tr("Saving…"); color: root.secondary; font.family: "sans-serif"; font.pixelSize: Style.space(11) }
    }
  }
  Flickable {
    id: settingsScroll
    objectName: "settingsScroll"
    anchors.top: settingsHeader.bottom
    anchors.bottom: parent.bottom
    width: parent.width
    contentWidth: width
    contentHeight: settingsBody.implicitHeight
    clip: true
    flickableDirection: Flickable.VerticalFlick
    boundsBehavior: Flickable.StopAtBounds
    onContentHeightChanged: contentY = Math.max(0, Math.min(contentY, contentHeight - height))
    onHeightChanged: contentY = Math.max(0, Math.min(contentY, contentHeight - height))
    Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }
    Column {
      id: settingsBody
      width: parent.width
      leftPadding: root.padding
      rightPadding: root.padding
      bottomPadding: root.padding
      spacing: Style.space(14)
      Text {
        width: root.width - root.padding * 2
        visible: root.error !== ""
        text: root.error
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: Color.urgent
        font.family: "sans-serif"
        font.pixelSize: Style.space(12)
        Accessible.role: Accessible.AlertMessage
      }
      Repeater {
        model: [{scope:"center",label:"Notification Center",fields:Preferences.centerFields}, {scope:"popups",label:"Foamy Notifications",fields:Preferences.popupFields}]
        Column {
          id: section
          required property var modelData
          width: root.width - root.padding * 2
          spacing: Style.space(14)
          Text { text: root.tr(section.modelData.label); color: root.secondary; font.family: "sans-serif"; font.pixelSize: Style.space(13) }
          Text {
            objectName: section.modelData.scope + "-availability"
            width: parent.width
            visible: section.modelData.scope === "popups" && !root.popupAvailable && (root.loading || root.error === "")
            text: root.tr(root.loading ? "Reading settings…" : root.popupInstalled ? "Plugin not enabled" : "Plugin not installed")
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: Qt.tint(Color.popups.background, Qt.alpha(Color.popups.text, 0.55))
            font.family: "sans-serif"
            font.pixelSize: Style.space(12)
          }
          Repeater {
            // Keep loaded editors stable during refreshes so reads cannot steal focus.
            model: section.modelData.scope === "center" || root.popupAvailable ? section.modelData.fields : []
            SettingsField {
              required property var modelData
              width: section.width
              scope: section.modelData.scope
              field: modelData
              settings: scope === "center" ? root.settings : root.popupSettings
              language: root.language
              enabled: !root.saving && (scope === "center" || root.popupAvailable)
              opacity: enabled ? 1 : 0.55
              onSave: function(value) { root.save(scope, field.key, value) }
              onClearError: root.clearError()
            }
          }
        }
      }
    }
  }
}
