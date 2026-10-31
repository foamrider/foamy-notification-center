// foamy-kit 0.4.2 b717a528267202710c196f4a67600467b292db64f643a502ea1eebb92df75095 — do not edit; change foamy-kit and run sync
import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Adapted from Omarchy Ui/Dropdown.qml (MIT, see LICENSE-OMARCHY) for the
// foamy look: foamy radius, font and control height, RTL mirroring of the
// option list (the popup is a separate overlay, so it does not inherit the
// panel's mirroring), and an optional label delegate.
//
// `value` belongs to the caller: bind it to the setting. Selecting an option
// emits changed(value) and never assigns `value` (upstream does, which
// destroys the caller's binding, and since popup bodies are kept between
// opens, later changes to the setting would stop showing). Until the
// caller's binding catches up, the pick is shown (`shownValue`); it gives way
// as soon as `value` changes, the list is reopened, or after pickHoldMs. A
// caller that wants an uncontrolled dropdown handles changed() itself.
//
// Compact form (`compact: true`), for short choices in settings (enums,
// intervals; DESIGN.md "Short values use the row form"): one row like a
// FoamyToggle row, the label (subtitle, normal weight) and an optional
// `description` on the reading start, the dropdown on the end, sized to its widest option plus
// the chevron (`compactNaturalWidth`), at most `compactMaxFraction` (half)
// of the row and eliding beyond; the open list may be wider (up to the row),
// growing toward the label. Same row height as toggle rows and compact
// FoamyNumberFields, so their trailing controls line up. RTL mirrors it.
//   FoamyDropdown { width: parent.width; compact: true; label: FoamyI18n.t("Mouse wheel"); value: …; options: […]; onChanged: … }
//
//   FoamyDropdown {
//     label: FoamyI18n.t("Refresh every")
//     value: String(Prefs.value(fields, root.settings, "refreshSeconds"))
//     options: [{ value: "30", label: FoamyI18n.t("30 seconds") }, …]
//     onChanged: function(v) { root.save("refreshSeconds", Number(v)) }
//   }
//
// labelDelegate: a Component whose root declares `property string text` and
// `property color color`; it draws the trigger and option labels (e.g. the
// clock plugin's glyph-and-time split).
//
// Themed single-select dropdown. Trigger row paints with the kit's focus
// chrome; the popup anchors below and uses Commons.Color.popups.background +
// Commons.Color.popups.border so it reads as a panel surface rather than the
// platform-native ComboBox look.
//
// `options` accepts either a plain string[] or an array of
// { value, label } objects (label is what we render; value is what we
// emit). Mixing is fine — each row is interpreted independently.
//
// Keyboard: Tab to focus the trigger, Enter/Space opens, Esc closes,
// j/k or Up/Down walks options inside the open popup, Enter selects.
// A sibling SearchableDropdown reuses the same visuals but adds an
// embedded filter input — keep the two separate so each stays simple.
Item {
  id: root

  property string label: ""
  property string value: ""
  property var options: []

  property color foreground: Commons.Color.popups.text
  property color background: Commons.Color.popups.background
  property color popupBorder: Commons.Color.popups.border
  property color accent: Commons.Color.accent
  property real cornerRadius: FoamyStyle.radius
  property Component labelDelegate: null
  // The option on show: the last pick while the caller's value catches up.
  readonly property string shownValue: pickHeld ? pickedValue : value
  property int pickHoldMs: 10000
  property string pickedValue: ""
  property bool pickHeld: false
  onValueChanged: pickHeld = false
  readonly property var popupBorderSpec: Border.localOrSurfaceSpec("popups", "border", popupBorder, Commons.Color.popups.border, Style.normalBorderWidth)
  property string fontFamily: FoamyStyle.fontFamily
  property int rowHeight: FoamyStyle.controlHeight
  property int popupRowHeight: Style.spacing.popupRowHeight
  property bool showLabel: true
  // The row form (see above). `description` shows under the label there.
  property bool compact: false
  property string description: ""
  property real compactMaxFraction: 0.5
  // Label → chevron at its widest option (plain-text width; a labelDelegate
  // drawing something wider sets compactWidth).
  readonly property real compactNaturalWidth: !compact ? 0 : Math.ceil(widestLabel()) + FoamyStyle.controlPaddingX
    + Style.spacing.md + FoamyStyle.iconSize + Style.spacing.controlGap + FoamyStyle.borderWidth * 4
  property real compactWidth: compactNaturalWidth
  readonly property real compactTriggerWidth: Math.max(FoamyStyle.controlHeight * 2,
    Math.min(compactWidth, Math.floor(width * compactMaxFraction)))
  readonly property alias triggerItem: trigger

  // Panel-cursor flag. When true, the trigger renders the shared
  // hover-cursor state. Active Qt focus defaults to the same visuals.
  // Emits `hovered(bool)` on pointer enter/leave so the panel can keep
  // its cursor state in sync with the mouse.
  property bool hasCursor: false

  // popupOpen + open()/close()/toggle() let a parent panel know when the
  // dropdown owns keys (its embedded ListView is active) and suspend its
  // own keyCatcher so j/k inside the popup don't double-drive the panel
  // cursor.
  readonly property bool popupOpen: popup.opened
  function open() { popup.open() }
  // Pick an option as the list does: show it and emit changed(), without
  // touching `value`.
  function select(v) {
    v = String(v)
    if (v !== value) {
      pickedValue = v
      pickHeld = true
      pickHold.restart()
    }
    changed(v)
  }
  function close() { popup.close() }
  function toggle() { popup.opened ? popup.close() : popup.open() }

  signal changed(string value)
  signal hovered(bool isHovered)

  function optionValue(o) {
    return (o && typeof o === "object") ? String(o.value) : String(o)
  }
  function optionLabel(o) {
    return (o && typeof o === "object") ? String(o.label) : String(o)
  }
  function widestLabel() {
    var widest = 0
    for (var i = 0; i < options.length; i++)
      widest = Math.max(widest, labelMetrics.advanceWidth(optionLabel(options[i])))
    return Math.max(widest, labelMetrics.advanceWidth(currentLabel()))
  }
  function currentLabel() {
    for (var i = 0; i < options.length; i++) {
      if (optionValue(options[i]) === shownValue) return optionLabel(options[i])
    }
    return shownValue
  }

  // A label: plain text, or the caller's labelDelegate.
  component OptionText: Item {
    id: optionText
    property string text: ""
    property color color: root.foreground
    implicitHeight: plain.implicitHeight
    clip: true
    Text {
      id: plain
      visible: !root.labelDelegate
      anchors.fill: parent
      text: optionText.text
      textFormat: Text.PlainText
      horizontalAlignment: Text.AlignLeft
      verticalAlignment: Text.AlignVCenter
      color: optionText.color
      font.family: root.fontFamily
      font.pixelSize: FoamyStyle.font.body
      elide: Text.ElideRight
    }
    Loader {
      anchors.fill: parent
      active: !!root.labelDelegate
      sourceComponent: root.labelDelegate
      onLoaded: {
        item.text = Qt.binding(function() { return optionText.text })
        item.color = Qt.binding(function() { return optionText.color })
      }
    }
  }

  FontMetrics {
    id: labelMetrics
    font.family: root.fontFamily
    font.pixelSize: FoamyStyle.font.body
  }

  Timer {
    id: pickHold
    interval: root.pickHoldMs
    onTriggered: root.pickHeld = false
  }

  implicitWidth: compact ? FoamyStyle.popupWidth - FoamyStyle.padding * 2 : Style.spacing.dropdownWidth
  implicitHeight: compact
    ? Math.max(FoamyStyle.rowHeight + FoamyStyle.gapSmall, rowHeight, rowText.implicitHeight + FoamyStyle.gap * 2)
    : (showLabel && label !== "" ? rowHeight + Style.spacing.huge : rowHeight)

  // Compact: the label and description on the start, in the toggle row style.
  Column {
    id: rowText
    objectName: "foamyDropdownRowText"
    visible: root.compact
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.rightMargin: trigger.width + FoamyStyle.gapLarge
    anchors.verticalCenter: parent.verticalCenter
    spacing: FoamyStyle.gapTiny
    Text {
      visible: root.showLabel && root.label !== ""
      width: parent.width
      text: root.label
      textFormat: Text.PlainText
      horizontalAlignment: Text.AlignLeft
      wrapMode: Text.WordWrap
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: FoamyStyle.font.subtitle
    }
    Text {
      visible: root.description !== ""
      width: parent.width
      text: root.description
      textFormat: Text.PlainText
      horizontalAlignment: Text.AlignLeft
      wrapMode: Text.WordWrap
      color: FoamyPalette.secondaryText
      font.family: root.fontFamily
      font.pixelSize: FoamyStyle.font.bodySmall
    }
  }

  Column {
    anchors.left: parent.left
    anchors.right: parent.right
    y: root.compact ? Math.round((root.height - root.rowHeight) / 2) : 0
    spacing: Style.spacing.labelGap

    Text {
      textFormat: Text.PlainText
      visible: !root.compact && root.showLabel && root.label !== ""
      width: parent.width
      horizontalAlignment: Text.AlignLeft
      text: root.label
      color: FoamyPalette.secondaryText
      font.family: root.fontFamily
      font.pixelSize: FoamyStyle.font.bodySmall
      font.bold: true
    }

    BorderSurface {
      id: trigger
      // The end of the row (mirrored in RTL); full width outside compact.
      anchors.right: parent.right
      width: root.compact ? root.compactTriggerWidth : parent.width
      height: root.rowHeight
      radius: root.cornerRadius

      readonly property bool _focused: trigger.activeFocus
      readonly property bool _hot: triggerHover.hovered || root.hasCursor
      readonly property var _borderSpec: Border.controlSpec(trigger._focused ? "focus" : (trigger._hot ? "hover-cursor" : "normal"), root.foreground, root.accent)

      color: Style.controlFill(trigger._focused, trigger._hot, root.foreground, root.accent)
      borderSpec: _borderSpec

      activeFocusOnTab: true
      Accessible.role: Accessible.ComboBox
      Accessible.name: root.Accessible.name !== "" ? root.Accessible.name : root.label
      Accessible.description: root.description

      HoverHandler {
        id: triggerHover
        onHoveredChanged: root.hovered(hovered)
      }

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
            || event.key === Qt.Key_Space || event.key === Qt.Key_Down) {
          popup.opened ? popup.close() : popup.open()
          event.accepted = true
        } else if (event.key === Qt.Key_Escape && popup.opened) {
          popup.close(); event.accepted = true
        }
      }

      OptionText {
        anchors.left: parent.left
        anchors.right: chevron.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: trigger.borderLeft + FoamyStyle.controlPaddingX
        anchors.rightMargin: trigger.borderRight + Style.spacing.md
        text: root.currentLabel()
        color: root.foreground
      }

      FoamyIcon {
        id: chevron
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.rightMargin: trigger.borderRight + Style.spacing.controlGap
        width: FoamyStyle.iconSize
        height: width
        name: "chevron-down"
        color: FoamyPalette.secondaryText
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: {
          trigger.forceActiveFocus()
          popup.opened ? popup.close() : popup.open()
        }
      }

      Popup {
        id: popup
        // A compact trigger may be narrower than its options: the list grows
        // toward the label (left in LTR, right in RTL), up to the row.
        readonly property real naturalWidth: !root.compact ? 0 : Math.ceil(root.widestLabel()) + FoamyStyle.controlPaddingX * 2
          + leftPadding + rightPadding
        readonly property bool onRowEnd: trigger.x + trigger.width / 2 > root.width / 2
        x: root.compact && onRowEnd ? trigger.width - width : 0
        y: trigger.height + Style.spacing.xxs
        width: root.compact ? Math.max(trigger.width, Math.min(naturalWidth, root.width)) : trigger.width
        implicitHeight: Math.min(root.options.length * root.popupRowHeight + Math.max(0, root.options.length - 1) * Style.spacing.labelGap + Style.spacing.xxs,
                                 root.popupRowHeight * 8 + 7 * Style.spacing.labelGap + Style.spacing.xxs)
        padding: Style.spacing.hairline
        leftPadding: Border.left(root.popupBorderSpec) + Style.spacing.hairline
        rightPadding: Border.right(root.popupBorderSpec) + Style.spacing.hairline
        topPadding: Border.top(root.popupBorderSpec) + Style.spacing.hairline
        bottomPadding: Border.bottom(root.popupBorderSpec) + Style.spacing.hairline
        focus: true

        background: BorderSurface {
          color: root.background
          borderSpec: root.popupBorderSpec
          radius: root.cornerRadius
        }

        onOpened: {
          root.pickHeld = false
          optionList.currentIndex = Math.max(0, optionList.indexOfValue(root.value))
          optionList.forceActiveFocus()
        }

        contentItem: ListView {
          id: optionList
          spacing: Style.spacing.labelGap
          LayoutMirroring.enabled: FoamyI18n.rightToLeft
          LayoutMirroring.childrenInherit: true

          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) { popup.close(); event.accepted = true }
            else if (event.key === Qt.Key_Down || event.text === "j") {
              optionList.currentIndex = Math.min(root.options.length - 1, optionList.currentIndex + 1)
              event.accepted = true
            } else if (event.key === Qt.Key_Up || event.text === "k") {
              optionList.currentIndex = Math.max(0, optionList.currentIndex - 1)
              event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              optionList.selectCurrent(); event.accepted = true
            }
          }
          implicitHeight: contentHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          model: root.options
          currentIndex: -1

          function indexOfValue(v) {
            for (var i = 0; i < root.options.length; i++)
              if (root.optionValue(root.options[i]) === v) return i
            return -1
          }

          function selectCurrent() {
            if (currentIndex < 0 || currentIndex >= root.options.length) return
            var v = root.optionValue(root.options[currentIndex])
            root.select(v)
            popup.close()
          }

          delegate: Rectangle {
            required property var modelData
            required property int index
            width: optionList.width
            height: root.popupRowHeight
            radius: FoamyStyle.innerRadius(root.cornerRadius, popup.leftPadding)
            color: index === optionList.currentIndex
              ? Style.hoverFillFor(root.foreground, root.accent)
              : "transparent"

            OptionText {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: FoamyStyle.controlPaddingX
              anchors.rightMargin: FoamyStyle.controlPaddingX
              text: root.optionLabel(modelData)
              color: index === optionList.currentIndex ? Style.hoverStateColor(root.foreground, root.accent) : root.foreground
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onPositionChanged: optionList.currentIndex = parent.index
              onClicked: optionList.selectCurrent()
            }
          }
        }
      }
    }
  }
}
