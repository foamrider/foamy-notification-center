// foamy-kit 0.17.0 4b03f2d9e8fff85a29ab30909dc4bef9c3c0e84a138bd804f804fd7758daf8bc — do not edit; change foamy-kit and run sync
import QtQuick
import QtQuick.Layouts

// A save or load error, announced to screen readers, with an optional Retry.
//
//   FoamySettingsError { width: parent.width; text: root.error; retryable: true; onRetry: root.save(…) }
Item {
  id: root

  property string text: ""
  property bool retryable: false

  signal retry

  visible: text !== ""
  implicitHeight: visible ? Math.max(message.implicitHeight, retryable ? retryButton.implicitHeight : 0) : 0

  RowLayout {
    anchors.fill: parent
    spacing: FoamyStyle.gap

    Text {
      id: message
      Layout.fillWidth: true
      Layout.alignment: Qt.AlignVCenter
      objectName: "settingsErrorText"
      text: root.text
      textFormat: Text.PlainText
      horizontalAlignment: Text.AlignLeft
      wrapMode: Text.WordWrap
      // The field errors' red (FoamyTextSettingField, FoamyNumberField), so
      // a page shows one red, readable on the popup surface.
      color: FoamyPalette.onSurface(FoamyPalette.error)
      font.family: FoamyStyle.fontFamily
      font.pixelSize: FoamyStyle.font.bodySmall
      Accessible.role: Accessible.AlertMessage
      Accessible.name: root.text
    }
    FoamyAction {
      id: retryButton
      visible: root.retryable
      focusable: true
      iconName: "refresh-cw"
      label: FoamyI18n.t("Retry")
      Layout.alignment: Qt.AlignVCenter
      onClicked: root.retry()
    }
  }
}
