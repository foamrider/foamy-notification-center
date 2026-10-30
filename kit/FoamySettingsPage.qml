// foamy-kit 0.2.0 e4d34cbda2ed58587abbcbad643ded693f0b8df1c3961577e792564449d60c07 — do not edit; change foamy-kit and run sync
import QtQuick
import QtQuick.Controls as Controls

// The foamy settings page skeleton, shown in place of the popup content at
// the same width: header (back, "Settings", "Saving…"), an error line with
// optional Retry, then the plugin's sections in a scrolling column.
//
//   FoamySettingsPage {
//     width: parent.width
//     saving: root.saving
//     error: root.settingsError
//     retryable: root.lastSave !== null
//     onBack: root.closeSettings()
//     onRetry: root.retrySave()
//     FoamySettingsSection { title: FoamyI18n.t("Bar"); … }
//   }
//
// Esc goes back. Tab walks the form controls (focusable: true); the page
// scrolls to keep the focused control visible. RTL mirrors the whole page.
// Focus `backTarget` when the page opens.
FocusScope {
  id: root

  property string title: FoamyI18n.t("Settings")
  property bool saving: false
  property string error: ""
  property bool retryable: false
  property alias backTarget: header.backButton
  property real maxHeight: FoamyStyle.popupMaxHeight
  default property alias content: body.data

  signal back()
  signal retry()

  LayoutMirroring.enabled: FoamyI18n.rightToLeft
  LayoutMirroring.childrenInherit: true
  implicitHeight: header.implicitHeight + column.implicitHeight

  function focusBack() { header.backButton.forceActiveFocus() }
  function resetScroll() { scroll.contentY = 0 }

  function keepVisible(item) {
    var ancestor = item
    while (ancestor && ancestor !== scroll.contentItem) ancestor = ancestor.parent
    if (!ancestor) return
    var point = item.mapToItem(scroll.contentItem, 0, 0)
    var margin = FoamyStyle.gap
    if (point.y < scroll.contentY) scroll.contentY = Math.max(0, point.y - margin)
    else if (point.y + item.height > scroll.contentY + scroll.height)
      scroll.contentY = Math.max(0, Math.min(scroll.contentHeight - scroll.height, point.y + item.height - scroll.height + margin))
  }

  Keys.onEscapePressed: function(event) { root.back(); event.accepted = true }

  Connections {
    target: root.Window.window
    ignoreUnknownSignals: true
    function onActiveFocusItemChanged() { if (target && target.activeFocusItem) root.keepVisible(target.activeFocusItem) }
  }

  FoamySettingsHeader {
    id: header
    width: parent.width
    title: root.title
    saving: root.saving
    onBack: root.back()
  }

  Flickable {
    id: scroll
    anchors.top: header.bottom
    anchors.bottom: parent.bottom
    width: parent.width
    contentWidth: width
    contentHeight: column.implicitHeight
    clip: true
    flickableDirection: Flickable.VerticalFlick
    boundsBehavior: Flickable.StopAtBounds
    onContentHeightChanged: contentY = Math.max(0, Math.min(contentY, contentHeight - height))
    onHeightChanged: contentY = Math.max(0, Math.min(contentY, contentHeight - height))
    Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }

    Column {
      id: column
      width: scroll.width
      leftPadding: FoamyStyle.padding
      rightPadding: FoamyStyle.padding
      bottomPadding: FoamyStyle.padding
      spacing: FoamyStyle.sectionGap

      FoamySettingsError {
        width: parent.width - FoamyStyle.padding * 2
        text: root.error
        retryable: root.retryable
        onRetry: root.retry()
      }
      Column {
        id: body
        width: parent.width - FoamyStyle.padding * 2
        spacing: FoamyStyle.sectionGap
      }
    }
  }
}
