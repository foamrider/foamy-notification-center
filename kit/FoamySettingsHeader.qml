// foamy-kit 0.1.0 30a5b66bc0f1ae714a166e672ac32c2db3952913ca1d618165cef71a31d9d897 — do not edit; change foamy-kit and run sync
import QtQuick
import QtQuick.Layouts

// Settings page header: back button, "Settings", and "Saving…" while a save
// is in flight. Part of FoamySettingsPage; use it alone only for a custom page.
Item {
  id: root

  property string title: FoamyI18n.t("Settings")
  property bool saving: false
  property alias backButton: backButton

  signal back()

  implicitHeight: Math.max(FoamyStyle.settingsButtonSize, titleText.implicitHeight) + FoamyStyle.padding * 2

  RowLayout {
    anchors.fill: parent
    anchors.margins: FoamyStyle.padding
    spacing: FoamyStyle.gap

    FoamyAction {
      id: backButton
      settings: true
      focusable: true
      iconName: "arrow-left"
      foreground: FoamyPalette.secondaryText
      tooltipText: FoamyI18n.t("Back")
      Layout.alignment: Qt.AlignVCenter
      onClicked: root.back()
    }
    Text {
      id: titleText
      Layout.fillWidth: true
      Layout.alignment: Qt.AlignVCenter
      text: root.title
      textFormat: Text.PlainText
      horizontalAlignment: Text.AlignLeft
      elide: Text.ElideRight
      color: FoamyPalette.text
      font.family: FoamyStyle.fontFamily
      font.pixelSize: FoamyStyle.font.title
      font.weight: Font.DemiBold
    }
    Text {
      visible: root.saving
      Layout.alignment: Qt.AlignVCenter
      text: FoamyI18n.t("Saving…")
      textFormat: Text.PlainText
      color: FoamyPalette.secondaryText
      font.family: FoamyStyle.fontFamily
      font.pixelSize: FoamyStyle.font.bodySmall
    }
  }
}
