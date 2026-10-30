import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
// Not "Translations": 4.5 qs.Commons has a Translations type, and the clash breaks loading.
import "../Translations.js" as CenterText
import "../kit"

Item {
  id: root
  required property var group
  property bool compact: false
  property bool expanded: false
  property bool hasCursor: false
  property bool dismissHasCursor: false
  property double now: 0
  property string language: "en"
  property double readMark: 0
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family
  signal toggleRequested()
  signal removeRequested()
  signal pointerUsed()

  implicitHeight: Math.max(Style.space(root.compact ? 32 : 44), labels.implicitHeight + Style.space(root.compact ? 8 : 20))
  readonly property bool expandable: group.entries.length > 1
  readonly property string storeImages: "file://" + (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy-notification-center/images/"
  readonly property string iconSource: {
    var value = String(group.appIcon || "")
    if (!value) return ""
    // Only the archive's own normalized images or a theme icon name; never a
    // provider URL or an arbitrary path from a (tampered) archive.
    if (value.indexOf(root.storeImages) === 0 && value.indexOf("/..") < 0) return value
    return /^[A-Za-z0-9_.-]+$/.test(value) ? Quickshell.iconPath(value, true) : ""
  }

  HoverHandler { id: hover; onHoveredChanged: if (hovered) root.pointerUsed() }
  StackFrame {
    anchors.fill: parent
    first: true
    critical: root.group.critical
    foreground: root.foreground
    fill: Qt.tint(Commons.Color.popups.background, Util.alpha(root.foreground, 0.055))
  }
  Rectangle {
    anchors.fill: headingMouse
    color: "transparent"
    border.width: root.hasCursor && !root.dismissHasCursor ? 1 : 0
    border.color: Commons.Color.accent
    radius: FoamyStyle.radius
  }
  MouseArea {
    id: headingMouse
    anchors.fill: parent
    anchors.rightMargin: dismiss.width + Style.space(8)
    cursorShape: root.expandable ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: { root.pointerUsed(); if (root.expandable) root.toggleRequested() }
  }
  Item {
    id: avatar
    anchors.left: parent.left
    anchors.leftMargin: Style.space(12)
    anchors.verticalCenter: parent.verticalCenter
    width: Style.space(root.compact ? 14 : 22)
    height: width
    Image {
      id: appIcon
      objectName: "notificationAppIcon"
      anchors.fill: parent
      source: root.iconSource
      sourceSize.width: width * 2
      sourceSize.height: height * 2
      fillMode: Image.PreserveAspectFit
      asynchronous: true
      visible: status === Image.Ready && faviconIcon.status !== Image.Ready
    }
    Image {
      id: faviconIcon
      objectName: "notificationFavicon"
      anchors.fill: parent
      source: String(root.group.favicon || "").indexOf("file://") === 0 ? root.group.favicon : ""
      sourceSize.width: width * 2
      sourceSize.height: height * 2
      fillMode: Image.PreserveAspectFit
      asynchronous: true
      visible: status === Image.Ready
    }
    Text {
      anchors.centerIn: parent
      visible: appIcon.status !== Image.Ready && faviconIcon.status !== Image.Ready
      textFormat: Text.PlainText
      text: root.group.glyph || root.group.app.charAt(0).toUpperCase()
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
  }
  Text {
    id: labels
    anchors.left: avatar.right
    anchors.leftMargin: Style.space(9)
    anchors.right: metadata.left
    anchors.rightMargin: Style.space(9)
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    text: root.group.app === "Unknown app" ? FoamyI18n.t("Unknown app") : (root.group.label || root.group.app)
    elide: Text.ElideRight
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
  Row {
    id: metadata
    anchors.right: dismiss.left
    anchors.rightMargin: Style.space(5)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(6)
    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      visible: root.group.timestamp > root.readMark
      width: Style.space(4)
      height: width
      radius: width / 2
      color: Commons.Color.accent
    }
    Text {
      textFormat: Text.PlainText
      text: FoamyI18n.number(root.group.entries.length) + " · " + CenterText.relativeTime(root.group.timestamp, root.now, FoamyI18n.t)
      color: Util.alpha(root.foreground, 0.65)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
  NotificationAction {
    id: dismiss
    anchors.right: parent.right
    anchors.rightMargin: Style.space(6)
    anchors.verticalCenter: parent.verticalCenter
    iconName: "close"
    size: Style.space(26)
    iconSize: Style.space(14)
    focusable: false
    foreground: root.foreground
    hasCursor: root.dismissHasCursor
    opacity: hover.hovered || root.hasCursor ? 1 : 0
    tooltipText: FoamyI18n.t(root.group.entries.length === 1 ? "Dismiss 1 notification" : "Dismiss %1 notifications", root.group.entries.length)
    onClicked: { root.pointerUsed(); root.removeRequested() }
  }
}
