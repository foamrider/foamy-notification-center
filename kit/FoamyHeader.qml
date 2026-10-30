// foamy-kit 0.3.2 ce8a8a5f3462791974ccef640994e84d4f02513fd1f54d97edca3893c3d9e1ae — do not edit; change foamy-kit and run sync
import QtQuick
import QtQuick.Layouts

// The one foamy popup header: icon, title, meta line, trailing controls and
// the settings button, inside FoamyStyle.padding.
//
//   FoamyHeader {
//     width: parent.width
//     iconName: "monitor"
//     title: FoamyI18n.t("Displays")
//     meta: FoamyI18n.tn("%1 connected", count)
//     settingsHasCursor: root.cursor === "settings"
//     onSettingsClicked: root.openSettings()
//     FoamyAction { iconName: "refresh-cw"; tooltipText: FoamyI18n.t("Refresh") }   // trailing extras
//   }
//
// The settings button carries the tooltip "Settings" and is reachable with
// `s` through the panel's PanelKeyCatcher.onTextKey (wire that in the panel).
Item {
  id: root

  property string iconName: ""
  property string title: ""
  property string meta: ""
  property bool showSettings: true
  property bool settingsHasCursor: false
  property color foreground: FoamyPalette.text
  // Insets around the row (FoamyHeroBand sets the vertical ones to 0).
  property real horizontalPadding: FoamyStyle.padding
  property real topPadding: FoamyStyle.padding
  property real bottomPadding: FoamyStyle.padding
  property alias settingsButton: settingsButton
  default property alias trailing: trailingRow.data

  signal settingsClicked()
  signal settingsHovered(bool hovered)

  implicitWidth: row.implicitWidth + horizontalPadding * 2
  implicitHeight: Math.max(FoamyStyle.settingsButtonSize, textColumn.implicitHeight) + topPadding + bottomPadding

  RowLayout {
    id: row
    anchors.fill: parent
    anchors.leftMargin: root.horizontalPadding
    anchors.rightMargin: root.horizontalPadding
    anchors.topMargin: root.topPadding
    anchors.bottomMargin: root.bottomPadding
    spacing: FoamyStyle.gapLarge

    FoamyIcon {
      visible: root.iconName !== ""
      name: root.iconName
      color: root.foreground
      Layout.preferredWidth: FoamyStyle.headerIconSize
      Layout.preferredHeight: FoamyStyle.headerIconSize
      Layout.alignment: Qt.AlignVCenter
    }

    Column {
      id: textColumn
      Layout.fillWidth: true
      Layout.alignment: Qt.AlignVCenter
      spacing: FoamyStyle.gapTiny
      Text {
        width: parent.width
        text: root.title
        textFormat: Text.PlainText
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignLeft
        color: root.foreground
        font.family: FoamyStyle.fontFamily
        font.pixelSize: FoamyStyle.font.title
        font.weight: Font.DemiBold
      }
      Text {
        visible: root.meta !== ""
        width: parent.width
        text: root.meta
        textFormat: Text.PlainText
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignLeft
        color: FoamyPalette.secondaryText
        font.family: FoamyStyle.fontFamily
        font.pixelSize: FoamyStyle.font.bodySmall
      }
    }

    Row {
      id: trailingRow
      Layout.alignment: Qt.AlignVCenter
      spacing: FoamyStyle.gapSmall
    }

    FoamyAction {
      id: settingsButton
      visible: root.showSettings
      settings: true
      iconName: "settings"
      foreground: FoamyPalette.secondaryText
      tooltipText: FoamyI18n.t("Settings")
      hasCursor: root.settingsHasCursor
      Layout.alignment: Qt.AlignVCenter
      onClicked: root.settingsClicked()
      onHoveredChanged: root.settingsHovered(hovered)
    }
  }
}
