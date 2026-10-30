// foamy-kit 0.3.2 2c3b0b915777c824f03ad902d8fff2a5e8782128c461f921ef4afa5a7b551879 — do not edit; change foamy-kit and run sync
import QtQuick

// A titled group of settings rows. Titles are sentence case ("Bar", "Refresh").
//
//   FoamySettingsSection {
//     title: FoamyI18n.t("Bar")
//     Toggle { width: parent.width; label: FoamyI18n.t("Show percentage in the bar"); … }
//   }
Column {
  id: root

  property string title: ""
  property string description: ""
  default property alias content: rows.data

  spacing: FoamyStyle.gap

  Text {
    visible: root.title !== ""
    width: parent.width
    text: root.title
    textFormat: Text.PlainText
    horizontalAlignment: Text.AlignLeft
    wrapMode: Text.WordWrap
    color: FoamyPalette.secondaryText
    font.family: FoamyStyle.fontFamily
    font.pixelSize: FoamyStyle.font.bodySmall
    font.weight: Font.DemiBold
    Accessible.role: Accessible.Heading
  }
  Text {
    visible: root.description !== ""
    width: parent.width
    text: root.description
    textFormat: Text.PlainText
    horizontalAlignment: Text.AlignLeft
    wrapMode: Text.WordWrap
    color: FoamyPalette.mutedText
    font.family: FoamyStyle.fontFamily
    font.pixelSize: FoamyStyle.font.bodySmall
  }
  Column {
    id: rows
    width: parent.width
    spacing: FoamyStyle.gap
  }
}
