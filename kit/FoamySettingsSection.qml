// foamy-kit 0.4.2 8cdbb9c29ea18347ca78e37895688ee44c32c521868aaecfbe99e11f8255b073 — do not edit; change foamy-kit and run sync
import QtQuick

// A titled group of settings rows. Titles are sentence case ("Bar", "Refresh").
//
//   FoamySettingsSection {
//     title: FoamyI18n.t("Bar")
//     Toggle { width: parent.width; label: FoamyI18n.t("Show percentage in the bar"); … }
//   }
//
// `info`: help longer than a label. An (i) beside the title opens it as an
// inline note under the title (FoamyInfoNote); never put it in a tooltip.
//   FoamySettingsSection { title: FoamyI18n.t("Git LFS"); info: FoamyI18n.t("Automatic checks run Git …") }
Column {
  id: root

  property string title: ""
  property string description: ""
  property string info: ""
  readonly property alias infoNote: infoNote
  default property alias content: rows.data

  spacing: FoamyStyle.gap

  FoamyInfoNote {
    id: infoNote
    visible: root.info !== ""
    width: parent.width
    title: root.title
    text: root.info
  }
  Text {
    objectName: "foamySectionTitle"
    visible: root.title !== "" && root.info === ""
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
    objectName: "foamySectionDescription"
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
