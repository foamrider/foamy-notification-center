// foamy-kit 0.9.0 2bc5d90a32e9d35f884e33793c3875e76eb957a8a4e332f37405cd34ca853546 — do not edit; change foamy-kit and run sync
import QtQuick
import QtQuick.Layouts

// Settings page header: back button, "Settings", and "Saving…" while a save
// is in flight. Part of FoamySettingsPage; use it alone only for a custom page.
Item {
  id: root

  property string title: FoamyI18n.t("Settings")
  property bool saving: false
  property alias backButton: backButton
  property real horizontalPadding: FoamyStyle.padding
  property real topPadding: FoamyStyle.padding
  property real bottomPadding: FoamyStyle.padding

  signal back

  implicitHeight: Math.max(FoamyStyle.settingsButtonSize, titleText.implicitHeight) + topPadding + bottomPadding

  RowLayout {
    anchors.fill: parent
    anchors.leftMargin: root.horizontalPadding
    anchors.rightMargin: root.horizontalPadding
    anchors.topMargin: root.topPadding
    anchors.bottomMargin: root.bottomPadding
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
