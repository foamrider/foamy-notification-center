import QtQuick
import QtQuick.Effects
import qs.Commons
import qs.Ui
import "../Translations.js" as Translations

Item {
  id: root
  required property var entry
  property bool last: false
  property bool first: false
  property bool layered: false
  property bool expanded: false
  property bool groupCritical: false
  property bool hasCursor: false
  property bool dismissHasCursor: false
  property bool compact: false
  property bool showBody: true
  property bool showPreview: true
  property double now: 0
  property string language: "en"
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  signal clicked()
  signal removeRequested()
  signal pointerUsed()

  readonly property bool critical: Number(entry.urgency) === 2
  readonly property real verticalPadding: Style.space(compact ? 8 : 12)
  readonly property real cardHeight: texts.implicitHeight + verticalPadding * 2
  readonly property bool hasPreview: showPreview && String(entry.preview || "") !== "" && previewImage.status !== Image.Error
  implicitHeight: cardHeight + (last ? Style.space(layered ? 24 : 14) : 0)

  // Sender-controlled markup must never load resources from notification text.
  function plain(value) {
    return String(value || "").replace(/<img[^>]*>/gi, "").replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim()
  }

  Rectangle {
    visible: root.last && root.layered
    x: Style.space(14)
    y: root.cardHeight - Style.space(6)
    width: parent.width - Style.space(28)
    height: Style.space(16)
    radius: Style.cornerRadius * 2
    color: Color.popups.background
    border.width: 1
    border.color: Util.alpha(root.foreground, 0.18)
  }
  Rectangle {
    visible: root.last && root.layered
    x: Style.space(7)
    y: root.cardHeight - Style.space(8)
    width: parent.width - Style.space(14)
    height: Style.space(13)
    radius: Style.cornerRadius * 2
    color: Qt.tint(Color.popups.background, Util.alpha(root.foreground, 0.04))
    border.width: 1
    border.color: Util.alpha(root.foreground, 0.18)
  }
  Item {
    id: card
    width: parent.width
    height: root.cardHeight
    HoverHandler { id: hover; onHoveredChanged: if (hovered) root.pointerUsed() }
    StackFrame {
      anchors.fill: parent
      last: root.last
      critical: root.groupCritical
      foreground: root.foreground
      fill: root.critical ? Qt.tint(Color.popups.background, Util.alpha(Color.urgent, 0.09)) : Color.popups.background
    }
    Rectangle {
      visible: !root.first
      x: root.groupCritical ? Style.space(3) : 1
      width: parent.width - x - 1
      height: 1
      color: Util.alpha(root.foreground, 0.12)
    }
    Rectangle {
      anchors.fill: parent
      anchors.margins: Style.space(3)
      color: "transparent"
      border.width: root.hasCursor && !root.dismissHasCursor ? 1 : 0
      border.color: Color.accent
      radius: Style.cornerRadius * 2
    }
    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onClicked: function(mouse) {
        root.pointerUsed()
        if (mouse.button === Qt.RightButton) root.removeRequested()
        else root.clicked()
      }
    }
    Column {
      id: texts
      x: Style.space(13)
      y: root.verticalPadding
      width: parent.width - Style.space(26)
      spacing: Style.space(4)
      Text {
        visible: root.expanded
        textFormat: Text.PlainText
        text: Translations.relativeTime(Number(root.entry.timestamp || 0), root.now, root.language)
        color: Util.alpha(root.foreground, 0.6)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
      Text {
        width: parent.width - (root.expanded ? Style.space(28) : 0)
        textFormat: Text.PlainText
        text: root.plain(root.entry.summary)
        elide: Text.ElideRight
        maximumLineCount: 1
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
      Text {
        width: parent.width
        visible: root.showBody && text !== ""
        textFormat: Text.PlainText
        text: root.plain(root.entry.body)
        wrapMode: Text.WordWrap
        elide: Text.ElideRight
        maximumLineCount: 2
        color: Util.alpha(root.foreground, 0.75)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
      Image {
        id: previewImage
        width: parent.width
        height: root.hasPreview ? Math.min(width * 9 / 16, Style.space(104)) : 0
        visible: root.hasPreview
        source: root.showPreview ? String(root.entry.preview || "") : ""
        sourceSize.width: Math.round(width * 2)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        layer.enabled: true
        layer.effect: MultiEffect {
          maskEnabled: true
          maskSource: previewMask
          maskThresholdMin: 0.5
          maskSpreadAtMin: 1.0
        }
      }

    }
    Rectangle {
      id: previewMask
      width: previewImage.width
      height: previewImage.height
      radius: Style.cornerRadius * 2
      color: "black"
      visible: false
      layer.enabled: true
    }
    NotificationAction {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      y: root.verticalPadding - Style.space(3)
      visible: root.expanded || root.dismissHasCursor
      opacity: hover.hovered || root.hasCursor ? 1 : 0
      iconName: "close"
      size: Style.space(26)
      iconSize: Style.space(14)
      focusable: false
      tooltipText: Translations.text("Dismiss notification", root.language)
      foreground: root.foreground
      hasCursor: root.dismissHasCursor
      onClicked: { root.pointerUsed(); root.removeRequested() }
    }
  }
}
