import QtQuick
import QtQuick.Controls
import QtQuick.Controls as Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

import "." as Plugin
import "Model.js" as Model
import "Translations.js" as Translations
import "components"

// A notification center for Omarchy: everything you were sent, still there
// when you go back for it.
//
// Omarchy already writes every notification to disk: one JSON file per popup
// under ~/.local/state/omarchy/notifications/, moved into history/ when it
// leaves the screen. That is where these come from, and nothing here writes to
// those directories. What it is not is a history you can read: it holds ten
// files, deletes the eleventh, and deletes the icon it was keeping for it at
// the same time. Ten is the right number for a service whose job is replaying
// the toasts you just missed, and far too few for the question this panel
// exists to answer, which is "what did that say".
//
// So `bin/notification-center` copies each file out of there the moment it
// lands, into an archive kept for as long as you asked for, icon and all. It
// follows the directory with inotify rather than polling it, so a notification
// is in the archive before its toast has finished appearing.
//
// Glyphs are \u escapes rather than literal characters, so the source survives
// editors and patches that mangle private-use codepoints.
Panel {
  id: root

  moduleName: "foamy.notification-center"
  ipcTarget: "foamy.notification-center"

  readonly property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  readonly property color foreground: Color.popups.text
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ----------------------------------------------------------------- settings

  readonly property int panelWidth: setting("panelWidth", 420)
  readonly property int listHeight: setting("listHeight", 0)
  readonly property string badge: setting("badge", "Dot")
  readonly property int keepDays: setting("keepDays", 30)
  readonly property int maxItems: setting("maxItems", 1000)
  readonly property string clickAction: setting("clickAction", "Auto")
  readonly property bool compact: setting("compact", false)
  readonly property bool showBody: setting("showBody", true)
  readonly property bool showPreview: setting("showPreview", true)

  // ------------------------------------------------------------- the service
  //
  readonly property string language: Translations.language(setting("language", "system"), Qt.locale().name)
  function tr(label, value) { return Translations.text(label, language, value) }

  readonly property bool dnd: store ? store.doNotDisturb : false
  function toggleDnd() { if (store) store.toggleDnd() }

  // ------------------------------------------------------------- the store
  //
  // The archive is a shell service, not a child of this widget. Omarchy
  // builds a bar per monitor, and a Process in here would be one watcher
  // per screen: unread and clear would stick to whichever copy you clicked.
  readonly property var store: Plugin.ServiceRegistry.instance

  onStoreChanged: {
    // Let dependent bindings and the row model finish initializing first.
    Qt.callLater(function() { root.pushSettings(); root.rebuild() })
  }

  function pushSettings() {
    if (!store) return
    store.keepDays = keepDays
    store.maxItems = maxItems
    store.showPreview = showPreview
  }

  onKeepDaysChanged: pushSettings()
  onMaxItemsChanged: pushSettings()
  onShowPreviewChanged: pushSettings()

  Connections {
    target: root.store
    function onEntryAdded(entry) { root.handleEntryAdded(entry) }
    function onEntriesReset() { root.rebuild() }
  }

  // -------------------------------------------------------------------- state

  readonly property var entries: store ? store.entries : []
  property string filter: ""
  // What the rows are marked against. Opening the center makes everything in
  // it read, so marking against `lastSeen` would mean the list never once
  // shows you which of these you had not seen, because the marks would be gone by the
  // time it finished drawing. This holds the reading from the moment before
  // you opened it, which is the question you were asking.
  property double readMark: 0
  readonly property bool loaded: store ? store.loaded : false
  property bool searching: false
  property double now: Date.now()

  readonly property int unread: store ? store.unread : 0
  readonly property bool hasCriticalUnread: store ? store.hasCriticalUnread : false
  readonly property double lastSeen: store ? store.lastSeen : 0

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.now = Date.now()
  }

  function startSearch() {
    searching = true
    Qt.callLater(function() { if (root.searching) search.forceActiveFocus() })
  }

  function endSearch() {
    searching = false
    filter = ""
    search.text = ""
    Qt.callLater(function() { if (root.opened) keyCatcher.forceActiveFocus() })
  }

  Connections {
    target: root.store
    function onFocusCompleted() { root.close() }
  }

  function remove(key) {
    if (store) store.remove(key)
  }

  function clearAll() {
    if (store) store.clearAll()
  }

  function handleEntryAdded(entry) {
    if (!entry || !entry.key) return
    if (root.opened && store) store.markSeen()
    rebuild()
    if (root.opened && list.atYBeginning) Qt.callLater(function() {
      if (root.opened) list.positionViewAtBeginning()
    })
  }

  // ----------------------------------------------------------------- the list

  property var rows: []
  property var expandedGroups: ({})
  property int cursorIndex: -1
  property bool cursorDismiss: false
  property bool keyboardNavigation: false

  function rebuild() {
    var focused = cursorIndex >= 0 && cursorIndex < rows.length ? rows[cursorIndex].id : ""
    var next = Model.stackRows(entries, expandedGroups, filter)
    var index = next.findIndex(function(row) { return row.id === focused })
    rows = next
    cursorIndex = index >= 0 ? index : Math.min(cursorIndex, rows.length - 1)
  }

  function toggleGroup(key) {
    var next = Object.assign(Object.create(null), expandedGroups)
    next[key] = !next[key]
    expandedGroups = next
    rebuild()
  }

  function removeGroup(group) {
    if (store) store.removeMany(group.entries.map(function(entry) { return entry.key }))
  }

  function moveCursor(dx, dy) {
    if (rows.length === 0) return
    keyboardNavigation = true
    if (dy) {
      cursorIndex = Math.max(0, Math.min(rows.length - 1, cursorIndex + dy))
      cursorDismiss = false
    } else {
      if (cursorIndex < 0) cursorIndex = 0
      cursorDismiss = dx > 0
    }
    list.positionViewAtIndex(cursorIndex, ListView.Contain)
  }

  function activateCursor(removeOnly) {
    if (cursorIndex < 0 || cursorIndex >= rows.length) return
    var row = rows[cursorIndex]
    if (removeOnly || cursorDismiss) {
      if (row.kind === "header") removeGroup(row.group)
      else remove(row.entry.key)
    } else if (row.kind === "header") {
      if (row.group.entries.length > 1) toggleGroup(row.group.key)
    } else activate(row.entry)
  }

  onFilterChanged: rebuild()

  // --------------------------------------------------------------- activating

  function activate(row) {
    if (!row || clickAction === "Nothing") return
    // Ignore sender commands even before an old archive has been migrated.
    if (clickAction === "Auto" && Model.isPreviewFile(row.file)) {
      Quickshell.execDetached(["xdg-open", row.file])
      root.remove(row.key)
      root.close()
      return
    }
    if (store) store.focusNotification(row, clickAction === "Auto")
  }

  // ---------------------------------------------------------------- lifecycle

  Component.onCompleted: pushSettings()

  onOpenedChanged: {
    if (!opened) {
      searching = false
      filter = ""
      search.text = ""
      return
    }
    now = Date.now()
    keyboardNavigation = false
    cursorIndex = -1
    cursorDismiss = false
    if (store) store.load()
    readMark = lastSeen
    if (store) store.markSeen()
  }

  // --------------------------------------------------------------------- bar

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    bar: root.bar

    // A bell, and a bell with a line through it while notifications are
    // silenced. The second is the same glyph the shell's own DND indicator
    // uses, so the bar never shows two different pictures of one state.
    // U+F009B (bell-off) and U+F009A (bell), written as surrogate pairs so the
    // source survives editors that mangle private-use codepoints. The first is
    // the glyph the shell's own DND indicator uses, so the bar never shows two
    // different pictures of one state.
    text: root.dnd ? "\uDB80\uDC9B" : "\uDB80\uDC9A"
    dimmed: root.dnd

    // The Highlight marker: no shape added beside the bell, the bell itself
    // recoloured. BarIconButton already draws its glyph in activeColor while
    // active, which is the same mechanism the bar's own indicators use to say
    // a thing wants you, so this is that state rather than a second drawing of
    // it. Accent instead of the inherited urgent, because unread mail is not
    // an emergency.
    active: root.badge === "Highlight" && root.unread > 0
    activeColor: Color.accent
    tooltipText: {
      if (root.dnd) return root.unread > 0
        ? root.tr("Silenced · %1 new", root.unread) : root.tr("Notifications silenced")
      if (root.unread === 1) return root.tr("1 new notification")
      if (root.unread > 1) return root.tr("%1 new notifications", root.unread)
      return root.tr("Notifications")
    }

    onPressed: function(b) {
      // Right-click silences without opening anything, because deciding you
      // want quiet and wanting to read the backlog are opposite impulses.
      if (b === Qt.RightButton) {
        root.toggleDnd()
        return
      }
      root.toggle()
    }
  }

  // Where the panel hangs from: a zero-width point far past the right edge of
  // any screen. Invisible, in the layout for nothing, and read only for its
  // position; see the anchor comment on the panel itself.
  Item {
    id: rightAnchor
    anchors.top: button.top
    anchors.bottom: button.bottom
    x: 1000000
    width: 1
    visible: false
  }

  // The Dot marker, drawn over the bell rather than beside it: a bar that
  // changes width every time a message arrives is a bar that twitches all day.
  Rectangle {
    id: dot
    visible: root.badge === "Dot" && root.unread > 0
    anchors.right: button.right
    anchors.rightMargin: Style.space(6)
    anchors.top: button.top
    anchors.topMargin: Style.space(10)
    width: Style.space(6)
    height: width
    radius: width / 2
    color: root.hasCriticalUnread ? root.urgent : Color.accent
  }

  Rectangle {
    id: countBadge
    visible: root.badge === "Count" && root.unread > 0
    anchors.right: button.right
    anchors.rightMargin: Style.space(1)
    anchors.top: button.top
    anchors.topMargin: Style.space(3)
    width: Math.max(countText.implicitWidth + Style.space(6), Style.space(12))
    height: Style.space(12)
    radius: height / 2
    color: Color.accent

    Text {
      textFormat: Text.PlainText
      id: countText
      anchors.centerIn: parent
      // Past ninety-nine the number has stopped being information and the
      // badge is only saying "a lot", which it can say in three characters.
      text: root.unread > 99 ? "99+" : String(root.unread)
      font.family: root.fontFamily
      font.pixelSize: Math.max(8, Style.font.caption - Style.space(3))
      font.bold: true
      color: Color.background
    }
  }

  // ------------------------------------------------------------------- panel

  NotificationPopup {
    id: popup
    // Anchored to a point past the right edge of the screen rather than to the
    // bell. KeyboardPanel clamps its card inside the screen, so an anchor out
    // there always resolves to hard against the right edge, whatever the bar
    // has been rearranged into since. This is the one panel in the bar with a
    // fixed home: a notification center that opened in a different place
    // depending on how many widgets were to its left would be a notification
    // center you have to look for.
    anchorItem: rightAnchor
    bar: root.bar
    owner: root
    open: root.opened
    focusTarget: keyCatcher
    padding: 0
    borderSpec: Border.flat(Qt.alpha(Color.popups.text, 0.15), 1)
    contentWidth: popup.fittedContentWidth(Style.space(root.panelWidth))
    // fittedContentHeight() clamps against availableCardHeight, which collapses
    // to its 120px minimum under a screen-sized bar window (see
    // usableCardHeight below), so the same fit is done here against the
    // corrected ceiling: the content plus the card insets, never taller than
    // the space the screen actually has.
    contentHeight: Math.round(Math.min(
      Math.max(popup.verticalContentInset, content.implicitHeight + Style.space(10) + popup.verticalContentInset),
      popup.usableCardHeight))

    Behavior on contentHeight {
      enabled: root.opened
      NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }

    // The stock omarchy bar window is only as tall as the bar strip, so the
    // screen minus that window is the space a panel has. Some bars draw their
    // strip inside a screen-sized window instead, which makes KeyboardPanel
    // mistake the whole screen for the bar and collapse to its 120px safety
    // minimum - a card a few entries tall no matter how much room there is.
    // Measure the strip itself when the window is screen-sized; both bars
    // expose barSize, so this works under either host.
    readonly property real usableCardHeight: {
      if (barH >= screenH && root.bar && Number(root.bar.barSize) > 0)
        return Math.max(120, screenH - (Number(root.bar.barSize) + gap + margin))
      return availableCardHeight
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the search field has the focus it owns every key, including the
      // ones this would otherwise read as navigation.
      blocked: search.activeFocus
      onCloseRequested: root.searching ? root.endSearch() : root.close()
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activateCursor(false)
      onDeleteRequested: root.activateCursor(true)
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        // "/" is the only key that starts a search, because a panel that
        // started filtering on any keypress would be a panel that swallows
        // whatever you were typing in the window underneath.
        if (text === "/") root.startSearch()
      }

      Column {
        id: content
        anchors.fill: parent
        spacing: Style.space(8)

        // -------------------------------------------------------- header

        Item {
          id: header
          width: parent.width
          height: Style.space(58)

          Canvas {
            anchors.fill: parent
            property color surface: Color.popups.background
            property color accent: Color.accent
            // Inset the header curve so it meets the inside of the popup border.
            readonly property real cornerRadius: Math.max(0, Math.min(width / 2, height, popup.cornerRadius - Border.top(popup.borderSpec)))
            onCornerRadiusChanged: requestPaint()
            onSurfaceChanged: requestPaint()
            onAccentChanged: requestPaint()
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            onPaint: {
              var ctx = getContext("2d")
              ctx.reset()
              var r = cornerRadius
              ctx.beginPath()
              ctx.moveTo(r, 0)
              ctx.lineTo(width - r, 0)
              ctx.arcTo(width, 0, width, r, r)
              ctx.lineTo(width, height)
              ctx.lineTo(0, height)
              ctx.lineTo(0, r)
              ctx.arcTo(0, 0, r, 0, r)
              ctx.closePath()
              var wash = ctx.createLinearGradient(0, 0, width, height)
              wash.addColorStop(0, Qt.tint(surface, Qt.alpha(accent, 0.12)))
              wash.addColorStop(1, Qt.tint(surface, Qt.alpha(accent, 0.035)))
              ctx.fillStyle = wash
              ctx.fill()
            }
          }
          Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: 1
            color: Qt.alpha(root.foreground, 0.08)
          }

          Column {
            id: title
            anchors.left: parent.left
            anchors.leftMargin: Style.space(16)
            width: Math.max(0, searchControl.x - x - Style.space(8))
            opacity: root.searching ? 0 : 1
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: 100 } }
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)
            Text {
              textFormat: Text.PlainText
              width: parent.width
              elide: Text.ElideRight
              text: root.tr("Notifications")
              font.bold: true
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
            Text {
              textFormat: Text.PlainText
              width: parent.width
              elide: Text.ElideRight
              text: {
                if (root.dnd) return root.tr("Do not disturb")
                var count = Model.unreadState(root.entries, root.readMark).unread
                return root.tr(count === 1 ? "1 unread" : "%1 unread", count)
              }
              color: Util.alpha(root.foreground, 0.6)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Row {
            id: actions
            anchors.right: parent.right
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            NotificationAction {
              iconName: root.dnd ? "bellOff" : "bell"
              tooltipText: root.dnd ? root.tr("Allow notifications") : root.tr("Silence notifications")
              foreground: root.dnd ? Color.accent : Qt.alpha(root.foreground, 0.65)
              enabled: !!root.store && !root.store.dndBusy
              onClicked: root.toggleDnd()
            }
            NotificationAction {
              iconName: "trash"
              tooltipText: root.tr("Clear all notifications")
              foreground: Qt.alpha(root.foreground, 0.65)
              hoverForeground: Color.urgent
              enabled: root.entries.length > 0
              onClicked: root.clearAll()
            }
          }

          Rectangle {
            id: searchControl
            anchors.right: actions.left
            anchors.rightMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            width: root.searching ? actions.x - Style.space(20) : Style.space(32)
            height: Style.space(32)
            radius: Style.cornerRadius * 2
            color: root.searching ? Qt.alpha(root.foreground, 0.055) : "transparent"
            border.width: search.activeFocus ? 1 : 0
            border.color: Color.accent
            // Clipping this rounded surface cuts off its antialiased focus outline.
            antialiasing: true
            border.pixelAligned: false
            Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

            NotificationAction {
              iconName: "search"
              tooltipText: root.tr("Search notifications  ( / )")
              foreground: root.searching ? Color.accent : Qt.alpha(root.foreground, 0.65)
              onClicked: root.startSearch()
            }
            Controls.TextField {
              id: search
              x: Style.space(32)
              width: Math.max(0, parent.width - Style.space(64))
              height: parent.height
              visible: root.searching
              enabled: root.searching
              placeholderText: root.tr("Search")
              color: root.foreground
              placeholderTextColor: Qt.alpha(root.foreground, 0.45)
              selectionColor: Qt.alpha(Color.accent, 0.3)
              selectedTextColor: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              padding: 0
              background: Item {}
              onTextChanged: root.filter = text
              Keys.onEscapePressed: root.endSearch()
              // Keep the query while handing keyboard navigation to its results.
              Keys.onDownPressed: {
                keyCatcher.forceActiveFocus()
                root.cursorIndex = -1
                root.moveCursor(0, 1)
              }
              Keys.onReturnPressed: {
                keyCatcher.forceActiveFocus()
                root.cursorIndex = -1
                root.moveCursor(0, 1)
              }
            }
            NotificationAction {
              anchors.right: parent.right
              visible: root.searching
              iconName: "close"
              tooltipText: root.tr("Close search  ( Esc )")
              foreground: Qt.alpha(root.foreground, 0.65)
              onClicked: root.endSearch()
            }
          }
        }

        Text {
          id: removalError
          x: Style.space(14)
          width: parent.width - Style.space(28)
          textFormat: Text.PlainText
          text: root.store ? root.tr(root.store.dndError || (root.store.focusError || root.store.loadError || root.store.removalError)) : ""
          visible: text !== ""
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        // ---------------------------------------------------------- list

        NotificationList {
          id: list
          width: parent.width
          wheelStep: Style.space(96)
          scrollbarWidth: Style.space(6)
          scrollbarInset: Style.space(2)
          // The flattened model keeps expanded stacks within the same virtualized list.
          readonly property int cap: {
            var chrome = header.height + (removalError.visible ? removalError.implicitHeight : 0)
                       + content.spacing * (1 + Number(removalError.visible))
                       + Style.space(10)
            var available = Math.max(Style.space(100), popup.usableCardHeight - popup.verticalContentInset - chrome)
            return root.listHeight > 0 ? Math.min(Style.space(root.listHeight), available) : available
          }

          height: Math.min(contentHeight, cap)
          visible: root.rows.length > 0 || contentHeight > 0
          rows: root.rows
          entranceDistance: Style.space(8)
          spacing: 0

          delegate: Item {
            id: delegateRoot
            required property string rowId
            // Qt can deliver removal after the source map has already advanced.
            property var retainedData: null
            property var modelData: list.rowsById[rowId] || retainedData
            onModelDataChanged: if (modelData) retainedData = modelData
            required property int index
            property real entranceOffset: 0
            property bool retired: false
            enabled: !retired
            transform: Translate { y: delegateRoot.entranceOffset }
            ListView.delayRemove: exitMotion.running
            ListView.onRemove: {
              // Freeze departing content until Qt finishes its removal transition.
              modelData = modelData
              retired = true
              exitMotion.start()
            }
            SequentialAnimation {
              id: exitMotion
              NumberAnimation { target: delegateRoot; property: "opacity"; to: 0; duration: 120; easing.type: Easing.OutCubic }
              // Let ListView lay out the shrinking space, including its scroll extent.
              NumberAnimation { target: delegateRoot; property: "height"; to: 0; duration: 140; easing.type: Easing.OutCubic }
            }
            width: list.width
            height: rowLoader.implicitHeight

            Loader {
              id: rowLoader
              // ListView positions delegates; inset their content instead of the delegate itself.
              x: Style.space(14)
              width: parent.width - Style.space(28)
              sourceComponent: delegateRoot.modelData.kind === "header" ? headerDelegate : messageDelegate
            }
            Component {
              id: headerDelegate
              NotificationStackHeader {
                compact: root.compact
                group: delegateRoot.modelData.group
                expanded: delegateRoot.modelData.expanded
                language: root.language
                now: root.now
                readMark: root.readMark
                foreground: root.foreground
                fontFamily: root.fontFamily
                hasCursor: root.keyboardNavigation && root.cursorIndex === delegateRoot.index
                dismissHasCursor: hasCursor && root.cursorDismiss
                onPointerUsed: root.keyboardNavigation = false
                onToggleRequested: root.toggleGroup(group.key)
                onRemoveRequested: root.removeGroup(group)
              }
            }
            Component {
              id: messageDelegate
              NotificationRow {
                compact: root.compact
                entry: delegateRoot.modelData.entry
                first: delegateRoot.modelData.first
                last: delegateRoot.modelData.last
                layered: delegateRoot.modelData.layered
                expanded: delegateRoot.modelData.expanded
                groupCritical: delegateRoot.modelData.group.critical
                language: root.language
                now: root.now
                showBody: root.showBody
                showPreview: root.showPreview
                foreground: root.foreground
                fontFamily: root.fontFamily
                hasCursor: root.keyboardNavigation && root.cursorIndex === delegateRoot.index
                dismissHasCursor: hasCursor && root.cursorDismiss
                onPointerUsed: root.keyboardNavigation = false
                onClicked: root.activate(entry)
                onRemoveRequested: root.remove(entry.key)
              }
            }
          }
        }

        // --------------------------------------------------------- empty

        Text {
          textFormat: Text.PlainText
          x: Style.space(14)
          width: parent.width - Style.space(28)
          visible: root.rows.length === 0 && list.contentHeight <= 0
          horizontalAlignment: Text.AlignHCenter
          topPadding: Style.space(22)
          bottomPadding: Style.space(22)
          text: !root.loaded ? root.tr("Reading the archive…")
              : root.filter !== "" ? root.tr("Nothing matches “%1”", root.filter)
              : root.tr("Nothing has come in yet")
          wrapMode: Text.WordWrap
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.foreground
          opacity: 0.55
        }

      }
    }
  }
}
