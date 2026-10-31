// foamy-kit 0.4.0 0cdd515336db1689fa7ab6f088e650cba651b3f249aad67e4539324e17bf8d3f — do not edit; change foamy-kit and run sync
import QtQuick
import QtQuick.Layouts

// Help that is longer than a label: an (i) beside a heading that opens an
// inline note under it, instead of a tooltip (tooltips are for short labels
// only; a long one spans the screen). DESIGN.md "Tooltips".
//
//   FoamyInfoNote {
//     width: parent.width
//     title: FoamyI18n.t("Git LFS")                      // the heading the (i) sits beside
//     text: FoamyI18n.t("Automatic checks run Git without …")
//   }
//
// In a settings section, use FoamySettingsSection's `info` instead; it puts
// the (i) beside the section title. The note is word-wrapped bodySmall in
// the secondary tone on a subtle rounded surface, as wide as the column it
// is in (never wider than the popup). Clicking the (i) again, or Esc while
// it has focus, folds it.
//
// Without a `title` only the (i) shows on the heading line. `showHeader:
// false` drops the heading line: open it from your own control with
// toggle(). `expanded` is the note's own state: read it, call toggle() /
// open() / close(); don't bind it.
//
// Keyboard: in a settings form the (i) is `focusable` (Tab, Enter/Space);
// in a PanelKeyCatcher panel set `buttonHasCursor` and route `buttonHovered`.
// When it opens inside a scrolling FoamySettingsPage (or anything with an
// `ensureVisible(item)` function above it) the note is scrolled into view.
ColumnLayout {
  id: root

  property string title: ""
  property string text: ""
  property bool expanded: false
  property bool showHeader: true
  property bool focusable: true
  property bool buttonHasCursor: false
  property string buttonTooltip: FoamyI18n.t("More information")
  readonly property alias infoButton: infoButton
  readonly property alias note: note

  signal buttonHovered(bool hovered)

  function toggle() { if (expanded) close(); else open() }
  function open() {
    expanded = true
    revealTimer.start()
  }
  // After the note is laid out: scroll it into view (a child Timer dies with
  // the note, unlike Qt.callLater).
  Timer {
    id: revealTimer
    interval: 0
    onTriggered: {
      for (var item = root.parent; item; item = item.parent)
        if (typeof item.ensureVisible === "function") { item.ensureVisible(note); return }
    }
  }
  function close() { expanded = false }

  spacing: FoamyStyle.gapSmall

  RowLayout {
    visible: root.showHeader
    Layout.fillWidth: true
    spacing: FoamyStyle.gapSmall
    Text {
      visible: root.title !== ""
      text: root.title
      textFormat: Text.PlainText
      color: FoamyPalette.secondaryText
      font.family: FoamyStyle.fontFamily
      font.pixelSize: FoamyStyle.font.bodySmall
      font.weight: Font.DemiBold
      Accessible.role: Accessible.Heading
      Layout.alignment: Qt.AlignVCenter
    }
    FoamyAction {
      id: infoButton
      objectName: "foamyInfoButton"
      implicitWidth: FoamyStyle.iconSize + FoamyStyle.gapSmall * 2 + 2
      implicitHeight: implicitWidth
      iconName: "info"
      iconSize: FoamyStyle.iconSize - 2
      focusable: root.focusable
      hasCursor: root.buttonHasCursor
      foreground: root.expanded ? FoamyPalette.text : FoamyPalette.secondaryText
      color: active && (root.expanded || hasCursor || hovered || activeFocus) ? FoamyPalette.hoverFill : "transparent"
      tooltipText: ""
      Accessible.name: root.buttonTooltip
      Accessible.checkable: true
      Accessible.checked: root.expanded
      Keys.onEscapePressed: function(event) { if (root.expanded) { root.close(); event.accepted = true } else event.accepted = false }
      Layout.alignment: Qt.AlignVCenter
      onClicked: root.toggle()
      onHoveredChanged: root.buttonHovered(hovered)
    }
    Item { Layout.fillWidth: true }
  }

  Rectangle {
    id: note
    objectName: "foamyInfoNote"
    visible: root.expanded
    opacity: visible ? 1 : 0
    Layout.fillWidth: true
    implicitHeight: noteText.implicitHeight + FoamyStyle.rowPadding * 2
    radius: FoamyStyle.radius
    color: FoamyPalette.noteFill
    border.width: FoamyStyle.borderWidth
    border.color: FoamyPalette.divider
    Behavior on opacity { NumberAnimation { duration: FoamyMotion.fadeIn } }

    Text {
      id: noteText
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: FoamyStyle.rowPadding
      anchors.leftMargin: FoamyStyle.gapLarge
      anchors.rightMargin: FoamyStyle.gapLarge
      text: root.text
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      horizontalAlignment: Text.AlignLeft
      lineHeight: 1.15
      color: FoamyPalette.secondaryText
      font.family: FoamyStyle.fontFamily
      font.pixelSize: FoamyStyle.font.bodySmall
      Accessible.role: Accessible.StaticText
      Accessible.name: root.text
    }
  }
}
