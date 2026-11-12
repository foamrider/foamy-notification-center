// foamy-kit 0.9.0 5ac3d10d8ee34c6a4fa810d12b0f5855faf70bda6b6a225aab3687bd2a16af52 — do not edit; change foamy-kit and run sync
import QtQuick
import QtQuick.Layouts
import qs.Commons as Commons

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
      color: Commons.Color.urgent
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
