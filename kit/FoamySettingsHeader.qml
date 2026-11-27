pragma ComponentBehavior: Bound
// foamy-kit 0.16.0 b600b580cc64df6aa412d88e6525e857c0eb17514619d13b2c58348e36288d63 — do not edit; change foamy-kit and run sync
import QtQuick
import QtQuick.Layouts

// Settings page header: back button, "Settings", and "Saving…" while a save
// is in flight. Part of FoamySettingsPage; use it alone only for a custom page.
// A sub-view built like the settings page (an editor page) may put icon
// actions (FoamyAction) at the trailing end with `trailing`, after "Saving…".
//
// Title action (off by default): with `titleAction: true` the title is a
// FoamyTitleAction, a control that opens something about it (an editor
// page's place: the move menu), the next Tab stop after Back. It shows
// `titleIconName` (in `titleIconColor`) before the title and a chevron
// after it; a click, Enter or Space emits `titleActivated(keyboard)` (true
// from the keys, for FoamyMenu.open). `titleAccessibleName` names the
// button (default: the title); a cut title shows in a tooltip on hover
// (FoamyTitleAction: capped). `titleButton` is the control (give it the
// keys back with forceActiveFocus()) and `titleMenuAnchor` its menuAnchor
// (a menu anchored to it hangs under the control from its start); both are
// null while the action is off, when the title is the plain text it always
// was and no control is created. Turned off, a menu anchored to it closes;
// if the control had the keys, the caller places them (they stay on no
// Tab stop: Tab goes to the page's first one).
Item {
  id: root

  property string title: FoamyI18n.t("Settings")
  property bool saving: false
  property alias backButton: backButton
  property alias trailing: trailingRow.data
  property real horizontalPadding: FoamyStyle.padding
  property real topPadding: FoamyStyle.padding
  property real bottomPadding: FoamyStyle.padding

  property bool titleAction: false
  property string titleIconName: ""
  property color titleIconColor: FoamyPalette.secondaryText
  property string titleAccessibleName: title
  // The control and its menu anchor while the action is on; else null.
  readonly property FoamyTitleAction titleButton: titleLoader.item as FoamyTitleAction
  readonly property Item titleMenuAnchor: titleButton ? titleButton.menuAnchor : null

  signal back
  signal titleActivated(bool keyboard)

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
      visible: !root.titleAction
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
    // The title action, created only while it is on: as wide as its
    // content, at most the room left. Turned off, the Loader hides it
    // before it goes, so a menu anchored to it closes (FoamyMenu closes
    // when its anchor hides).
    Item {
      id: titleSlot
      visible: root.titleAction
      Layout.fillWidth: true
      Layout.alignment: Qt.AlignVCenter
      implicitHeight: FoamyStyle.settingsButtonSize

      Loader {
        id: titleLoader
        active: root.titleAction
        // Anchored, so a mirrored header starts it at the right.
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        sourceComponent: FoamyTitleAction {
          width: Math.min(implicitWidth, titleSlot.width)
          height: FoamyStyle.settingsButtonSize
          text: root.title
          iconName: root.titleIconName
          iconColor: root.titleIconColor
          accessibleName: root.titleAccessibleName
          onActivated: function (keyboard) {
            root.titleActivated(keyboard)
          }
        }
      }
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
    Row {
      id: trailingRow
      visible: children.length > 0
      Layout.alignment: Qt.AlignVCenter
      spacing: FoamyStyle.gapSmall
    }
  }
}
