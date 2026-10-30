pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Controls as Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import qs.Ui as Ui

import "." as Plugin
import "Model.js" as Model
import "BrowserIdentity.js" as BrowserIdentity
import "Preferences.js" as Preferences
import "kit/FoamyPrefs.js" as Prefs
import "components"
import "kit"

// A notification center for Omarchy: everything you were sent, still there
// when you go back for it.
//
// The notification daemon writes every notification to disk (stock Omarchy
// under ~/.local/state/omarchy/notifications/, Foamy Notifications wherever its
// `storeInfo` IPC says). That is where these come from, read-only: nothing here
// writes to or deletes from those directories. What it is not is a history you can read: it holds ten
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
Ui.Panel {
  id: root
  LayoutMirroring.enabled: FoamyI18n.rightToLeft
  LayoutMirroring.childrenInherit: true
  objectName: "notificationCenterPanel"

  function open() {
    preparePopup()
    // Build and lay out the list before mapping so the first frame has its final height.
    if (rowsDirty) rebuild(true)
    if (list) list.forceLayout()
    controller.show()
  }

  moduleName: "foamy.notification-center"
  // The popup, for the foamy-kit preview harness (preview/Preview.qml).
  readonly property alias popupPanel: popup
  ipcTarget: "foamy.notification-center"

  component SnoozeItem: Controls.MenuItem {
    id: snoozeItem
    implicitHeight: Math.max(Style.space(42), contentItem.implicitHeight + Style.space(16))
    contentItem: Text {
      text: snoozeItem.text
      textFormat: Text.PlainText
      font.family: root.fontFamily
      font.pixelSize: FoamyStyle.font.caption
      color: root.foreground
      opacity: snoozeItem.enabled ? 1 : 0.45
      wrapMode: Text.WordWrap
      verticalAlignment: Text.AlignVCenter
    }
    background: Rectangle { color: snoozeItem.highlighted ? Qt.alpha(root.foreground, 0.08) : "transparent"; radius: FoamyStyle.radius }
  }

  readonly property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  readonly property color foreground: Commons.Color.popups.text
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  // The foamy body font, as in every foamy popup.
  readonly property string fontFamily: FoamyStyle.fontFamily

  // ----------------------------------------------------------------- settings

  readonly property int panelWidth: setting("panelWidth", 420)
  readonly property int listHeight: setting("listHeight", 0)
  readonly property string badge: setting("badge", "Dot")
  readonly property int keepDays: setting("keepDays", 30)
  readonly property int maxItems: setting("maxItems", 1000)
  readonly property string clickAction: setting("clickAction", "Auto")
  readonly property bool compact: setting("compact", false)
  readonly property bool useBrowserFavicons: setting("useBrowserFavicons", true)
  readonly property string browserGrouping: setting("browserGrouping", "browser")
  onBrowserGroupingChanged: { expandedGroups = ({}); rebuild() }
  onUseBrowserFaviconsChanged: rebuild()
  readonly property bool showBody: setting("showBody", true)
  readonly property bool showPreview: setting("showPreview", true)

  // ------------------------------------------------------------- the service
  //
  readonly property string language: FoamyI18n.language
  function tr(label, value) { return FoamyI18n.t(label, value) }

  readonly property bool dnd: store ? store.doNotDisturb : false
  function toggleDnd() { if (store) store.toggleDnd() }

  property bool editingSettings: false
  property string settingsError: ""
  property var popupSettings: ({})
  property bool popupSettingsAvailable: false
  property bool popupSettingsLoading: false
  readonly property bool popupPluginInstalled: {
    var registry = bar && "pluginRegistry" in bar ? bar.pluginRegistry : null
    // Use the host's manifest registry so a stale settings entry cannot imply installation.
    return registry && registry.installedPlugins
      ? !!registry.installedPlugins["foamy.notifications"] : popupSettingsAvailable
  }
  property var pendingPreferences: ({})
  property var preferenceActive: null
  // Foamy Notifications owns its settings: read and saved over its IPC.
  property bool awaitingPeerSave: false

  function openSettings() {
    if (moreMenu) moreMenu.close()
    if (snoozeMenu) snoozeMenu.close()
    endSearch()
    editingSettings = true
    settingsError = ""
    reloadPopupPreferences()
    if (settingsPane) settingsPane.resetScroll()
    Qt.callLater(function() { if (root.opened && root.settingsPane) root.settingsPane.focusBack() })
  }
  function closeSettings() {
    editingSettings = false
    Qt.callLater(function() { if (root.opened && root.keyCatcher) root.keyCatcher.forceActiveFocus() })
  }
  function reloadPopupPreferences() {
    if (!editingSettings || popupSettingsLoading || preferenceActive !== null || !store) return
    popupSettingsLoading = true
    peer.call("foamy.notifications", "preferences", [], function(ok, output) {
      try {
        if (!ok) throw Error("Foamy Notifications is not answering")
        root.applyPopupPreferences(output)
      } catch (error) {
        root.popupSettingsAvailable = false
        root.popupSettings = ({})
      }
      root.popupSettingsLoading = false
      Qt.callLater(root.flushPreferences)
    })
  }
  function applyPopupPreferences(raw) {
    var result = JSON.parse(raw)
    if (!result || !result.settings || typeof result.settings !== "object") throw Error("Invalid settings response")
    var values = {}
    Preferences.popupFields.forEach(function(field) {
      if (!Preferences.valid("popups", field.key, result.settings[field.key])) throw Error("Invalid popup setting")
      values[field.key] = result.settings[field.key]
    })
    if (result.settings.browserGrouping === "none") values.groupDuplicates = false
    popupSettingsAvailable = true
    popupSettings = values
    return result
  }
  function savePreference(scope, key, value) {
    if (!Preferences.valid(scope, key, value)) { settingsError = tr("Invalid setting."); return }
    settingsError = ""
    // Serialize edits; collapse queued edits to the same key.
    pendingPreferences[scope + ":" + key] = {scope:scope,key:key,value:value}
    flushPreferences()
  }
  function flushPreferences() {
    if (preferenceActive !== null || popupSettingsLoading) return
    var keys = Object.keys(pendingPreferences)
    if (!keys.length) return
    var next = pendingPreferences[keys[0]]
    delete pendingPreferences[keys[0]]
    preferenceActive = next
    if (next.scope === "popups") {
      // Leading space: JSON stays out of the IPC CLI's option parser on 4.0.
      peer.call("foamy.notifications", "setPreference", [next.key, " " + JSON.stringify(next.value)], function(ok, output) {
        if (ok && String(output).trim() === "saving") root.awaitingPeerSave = true
        else root.finishPreference(false)
      })
      return
    }
    var result = Prefs.save(root.bar, root.moduleName, Preferences.centerFields, root.settings, next.key, next.value)
    if (!result.ok) { finishPreference(false); return }
    if (result.command.length) { preferencesSave.command = result.command; preferencesSave.running = true }
    else finishPreference(true)
  }
  // A failed save: the field shows the stored value again and accepts the same
  // number as a fresh attempt ("Try again" must be able to retry it).
  signal preferenceFailed(string scope, string key)
  function finishPreference(ok) {
    if (!preferenceActive) return
    if (!ok) {
      settingsError = tr("Could not save settings. Try again.")
      console.warn("Foamy Notification Center: settings save failed for", preferenceActive.scope, preferenceActive.key)
      preferenceFailed(preferenceActive.scope, preferenceActive.key)
    }
    preferenceActive = null
    awaitingPeerSave = false
    Qt.callLater(function() { root.flushPreferences(); root.reloadPopupPreferences() })
  }
  Connections {
    target: root.store
    function onPeerPreferencesChanged() {
      if (!root.awaitingPeerSave) { root.reloadPopupPreferences(); return }
      peer.call("foamy.notifications", "preferences", [], function(ok, output) {
        var result = null
        try { result = ok ? root.applyPopupPreferences(output) : null } catch (e) { result = null }
        if (result && result.saving) return
        root.finishPreference(!!result && !result.saveError)
      })
    }
  }
  FoamyPeerIpc { id: peer }
  Process {
    id: preferencesSave
    stdout: StdioCollector {}
    onExited: function(code, status) { root.finishPreference(code === 0 && status === 0) }
  }
  Timer {
    interval: 5000
    running: root.preferenceActive !== null
    onTriggered: {
      if (preferencesSave.running) preferencesSave.signal(9)
      else root.finishPreference(false)
    }
  }
  FileView {
    path: (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onFileChanged: { reload(); root.reloadPopupPreferences() }
  }

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

  // Paging: the end of the list loads the next page (up to maxItems). Checked
  // on scroll and whenever the content, hasMore or a read changes: collapsed
  // stacks can fit a whole page in the viewport, where atYEnd never changes.
  function pageIfAtEnd() {
    if (opened && list && list.atYEnd && store && store.hasMore && !store.listing) store.loadMore()
  }

  Connections {
    target: root.store
    function onHasMoreChanged() { Qt.callLater(root.pageIfAtEnd) }
    function onListingChanged() { Qt.callLater(root.pageIfAtEnd) }
    function onEntryAdded(entry) { root.handleEntryAdded(entry) }
    function onEntriesReset() { root.rebuild() }
    function onBrowserIconsUpdated() { root.rebuild() }
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
  // More unread than the loaded page holds.
  readonly property bool unreadCapped: !!store && store.unreadCapped
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
    Qt.callLater(function() { if (root.opened && root.searching && search) search.forceActiveFocus() })
  }

  function endSearch() {
    searching = false
    filter = ""
    if (store) store.searchQuery = ""
    if (search) { search.text = ""; search.pasteError = "" }
    Qt.callLater(function() { if (root.opened && keyCatcher) keyCatcher.forceActiveFocus() })
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
    if (root.opened && list && list.atYBeginning) Qt.callLater(function() {
      if (root.opened && list) list.positionViewAtBeginning()
    })
  }

  // ----------------------------------------------------------------- the list

  // The lazy popup body (null until the first open) and the parts of it the
  // panel drives.
  readonly property Item view: popup.bodyItem
  readonly property Item keyCatcher: view
  readonly property var list: view ? view.list : null
  readonly property var search: view ? view.search : null
  readonly property var moreMenu: view ? view.moreMenu : null
  readonly property var snoozeMenu: view ? view.snoozeMenu : null
  readonly property var settingsPane: view ? view.settingsPane : null
  readonly property real listAvailableHeight:
    Math.max(Style.space(100), popup.usableCardHeight - popup.verticalContentInset - (view ? view.chromeHeight : Style.space(80)))
  property bool rowsDirty: true
  property var rows: []
  property var expandedGroups: ({})
  property int cursorIndex: -1
  // The single cursor: list rows, or the header's settings button above row 0.
  property bool cursorOnSettings: false
  property bool cursorDismiss: false
  property bool keyboardNavigation: false

  function rebuild(forOpening) {
    // The archive and unread count stay live; display groups are needed only while open.
    if (!root.opened && forOpening !== true) { rowsDirty = true; return }
    rowsDirty = false
    var focused = cursorIndex >= 0 && cursorIndex < rows.length ? rows[cursorIndex].id : ""
    var next = Model.stackRows(entries, expandedGroups, filter, browserGrouping, BrowserIdentity)
    var index = next.findIndex(function(row) { return row.id === focused })
    var headers = next.filter(function(row) { return row.kind === "header" })
    headers.forEach(function(row) {
      row.group.favicon = root.useBrowserFavicons && store ? store.faviconSource(row.group.iconEntry) : ""
    })
    rows = next
    if (useBrowserFavicons && store) store.warmBrowserIcons(headers.map(function(row) { return row.group.iconEntry }).filter(Boolean))
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
    keyboardNavigation = true
    if (dy < 0 && cursorIndex <= 0) { cursorOnSettings = true; cursorIndex = -1; return }
    if (cursorOnSettings) {
      if (dy > 0 && rows.length > 0) { cursorOnSettings = false; cursorIndex = 0 }
      else return
    } else if (rows.length === 0) { cursorOnSettings = true; return }
    else if (dy) {
      cursorIndex = Math.max(0, Math.min(rows.length - 1, cursorIndex + dy))
      cursorDismiss = false
    } else {
      if (cursorIndex < 0) cursorIndex = 0
      cursorDismiss = FoamyI18n.rightToLeft ? dx < 0 : dx > 0
    }
    if (list) list.positionViewAtIndex(cursorIndex, ListView.Contain)
  }

  function activateCursor(removeOnly) {
    if (cursorOnSettings) { if (!removeOnly) openSettings(); return }
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
    if (store) store.focusNotification(row, clickAction === "Auto")
  }

  // ---------------------------------------------------------------- lifecycle

  Component.onCompleted: pushSettings()

  onOpenedChanged: {
    // Action feedback belongs to this panel visit, not the persistent archive.
    if (store) store.focusError = ""
    if (!opened) {
      if (moreMenu) moreMenu.close()
      if (snoozeMenu) snoozeMenu.close()
      editingSettings = false
      searching = false
      filter = ""
      if (search) { search.text = ""; search.pasteError = "" }
      return
    }
    now = Date.now()
    keyboardNavigation = false
    cursorOnSettings = false
    cursorIndex = -1
    cursorDismiss = false
    if (store) store.load()
    readMark = lastSeen
    if (store) store.markSeen()
    if (rowsDirty) rebuild()
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
    activeColor: Commons.Color.accent
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
    color: root.hasCriticalUnread ? root.urgent : Commons.Color.accent
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
    color: Commons.Color.accent

    Text {
      textFormat: Text.PlainText
      id: countText
      anchors.centerIn: parent
      // Past ninety-nine the number has stopped being information and the
      // badge is only saying "a lot", which it can say in three characters.
      text: root.unread > 99 || root.unreadCapped ? FoamyI18n.number(Math.min(99, root.unread)) + "+" : FoamyI18n.number(root.unread)
      font.family: root.fontFamily
      font.pixelSize: Math.max(8, FoamyStyle.font.caption - Style.space(3))
      font.bold: true
      color: Commons.Color.background
    }
  }

  // ------------------------------------------------------------------- panel

  // Keep the controller alive; release only the view after close animations finish.
  property bool popupContentActive: false
  function preparePopup() {
    popupUnload.stop()
    popupContentActive = true
  }
  Connections {
    target: root
    function onOpenedChanged() {
      if (root.opened) root.preparePopup()
      else popupUnload.restart()
    }
  }
  Timer {
    id: popupUnload
    interval: 1000
    onTriggered: {
      if (!root.opened && !popup.visible) {
        root.popupContentActive = false
        root.rows = []
        root.expandedGroups = ({})
        root.cursorIndex = -1
        root.rowsDirty = true
      }
    }
  }
  // foamy-kit FoamyPopup: the stock qs.Ui.KeyboardPanel (4.0 and 4.5, so 4.5's
  // full-screen bar window places the card under the bar) with the foamy
  // surface. Its content is the lazy `body`, built on first open; the archive,
  // unread count and IPC live in Service.qml, outside it.
  FoamyPopup {
    id: popup
    objectName: "notificationCenterPopup"
    // Anchored to a point past the right edge of the screen rather than to the
    // bell. KeyboardPanel clamps its card inside the screen, so an anchor out
    // there always resolves to hard against the right edge, whatever the bar
    // has been rearranged into since.
    anchorItem: rightAnchor
    bar: root.bar
    owner: root
    open: root.opened
    focusTarget: root.editingSettings && root.settingsPane ? root.settingsPane.backTarget : bodyItem
    contentWidth: popup.fittedContentWidth(Style.space(root.panelWidth))
    contentHeight: Math.round(Math.min(
      Math.max(popup.verticalContentInset, popup.bodyImplicitHeight + popup.verticalContentInset),
      popup.usableCardHeight))

    Behavior on contentHeight {
      enabled: root.opened
      NumberAnimation { duration: FoamyMotion.slider; easing.type: Easing.OutCubic }
    }

    // The host's own geometry: on 4.5 the stock KeyboardPanel measures the bar
    // strip, not the full-screen bar window.
    readonly property real usableCardHeight: availableCardHeight

    body: Component {
      PanelKeyCatcher {
        id: keyCatcher
        objectName: "notificationCenterView"
        // Reached from Panel functions through root.view.
        property alias list: listLoader.item
        property alias search: search
        property alias moreMenu: moreMenu
        property alias snoozeMenu: snoozeMenu
        property alias moreButton: moreButton
        property alias settingsPane: settingsPane
        readonly property real chromeHeight: header.height + (searchRow.visible ? searchRow.height + content.spacing : 0)
          + (errorLine.visible ? errorLine.implicitHeight + content.spacing : 0) + content.spacing + Style.space(10)
        implicitHeight: root.editingSettings ? settingsPane.implicitHeight : content.implicitHeight + Style.space(10)
        // While the search field or a menu has the keys, or Settings is open, this stands aside.
        blocked: search.inputActiveFocus || root.editingSettings || moreMenu.visible || snoozeMenu.visible
        onCloseRequested: root.searching ? root.endSearch() : root.close()
        onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
        onActivateRequested: root.activateCursor(false)
        onDeleteRequested: root.activateCursor(true)
        onTabRequested: function(direction) { root.switchPanel(direction) }
        onTextKey: function(text) {
          // "/" searches and "s" opens Settings; no other key starts anything, so
          // the panel never swallows what you were typing underneath.
          if (text === "/") root.startSearch()
          else if (text === "s") root.openSettings()
        }

        Column {
          id: content
          visible: !root.editingSettings
          width: parent.width
          spacing: Style.space(8)

          // ------------------------------------------------------ header
          // The foamy hero band: title row (bell, "Notifications", total, search /
          // clear / more, settings) and the unread summary in the hero slot.
          FoamyHeroBand {
            id: header
            objectName: "notificationCenterHeader"
            width: parent.width
            readonly property int unreadCount: Model.unreadState(root.entries, root.readMark).unread
            iconName: root.dnd ? "bell-off" : "bell"
            title: root.tr("Notifications")
            meta: root.entries.length ? FoamyI18n.tn("%1 notifications", root.entries.length) : ""
            settingsHasCursor: root.keyboardNavigation && root.cursorOnSettings
            onSettingsClicked: root.openSettings()
            onSettingsHovered: function(hovered) { if (hovered) root.keyboardNavigation = false }
            Component.onCompleted: settingsButton.objectName = "notificationSettings"
            trailing: [
              FoamyAction {
                objectName: "notificationSearchButton"
                iconName: "search"
                tooltipText: root.tr("Search notifications  ( / )")
                foreground: root.searching ? Commons.Color.accent : FoamyPalette.secondaryText
                onClicked: root.searching ? root.endSearch() : root.startSearch()
              },
              FoamyAction {
                objectName: "clearAllNotifications"
                iconName: "trash"
                destructive: true
                tooltipText: root.tr("Clear all notifications")
                foreground: FoamyPalette.secondaryText
                actionEnabled: root.entries.length > 0
                onClicked: root.clearAll()
              },
              FoamyAction {
                id: moreButton
                objectName: "notificationMore"
                iconName: "ellipsis"
                tooltipText: root.tr("More options")
                foreground: FoamyPalette.secondaryText
                onClicked: moreMenu.visible ? moreMenu.close() : moreMenu.open()
              }
            ]

            // Hero: the unread count and whether notifications are getting through.
            RowLayout {
              objectName: "notificationUnreadHero"
              Layout.fillWidth: true
              spacing: FoamyStyle.gapLarge
              Text {
                text: FoamyI18n.number(header.unreadCount) + (root.unreadCapped ? "+" : "")
                textFormat: Text.PlainText
                color: header.unreadCount > 0 ? FoamyPalette.text : FoamyPalette.secondaryText
                font.family: FoamyStyle.fontFamily
                font.pixelSize: FoamyStyle.font.numeralCompact
                font.weight: Font.Light
                Layout.alignment: Qt.AlignVCenter
              }
              Column {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                spacing: FoamyStyle.gapTiny
                Text {
                  width: parent.width
                  text: FoamyI18n.tn("unread", header.unreadCount)
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  color: FoamyPalette.text
                  font.family: FoamyStyle.fontFamily
                  font.pixelSize: FoamyStyle.font.subtitle
                }
                Text {
                  width: parent.width
                  text: root.dnd ? root.tr("Do not disturb is on") : root.tr("Notifications are on")
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  color: root.dnd ? Commons.Color.accent : FoamyPalette.secondaryText
                  font.family: FoamyStyle.fontFamily
                  font.pixelSize: FoamyStyle.font.bodySmall
                }
              }
            }
          }

          Controls.Menu {
            id: moreMenu
            contentItem.LayoutMirroring.enabled: FoamyI18n.rightToLeft
            contentItem.LayoutMirroring.childrenInherit: true
            objectName: "notificationOverflowMenu"
            x: FoamyI18n.rightToLeft ? FoamyStyle.padding : Math.max(0, content.width - width - FoamyStyle.padding)
            y: header.height - Style.space(6)
            width: Math.min(Style.space(248), content.width - FoamyStyle.padding * 2)
            padding: Style.space(5)
            closePolicy: Controls.Popup.CloseOnEscape | Controls.Popup.CloseOnPressOutside
            onClosed: Qt.callLater(function() { if (root.opened && !root.editingSettings) keyCatcher.forceActiveFocus() })
            background: BorderSurface { color: Commons.Color.popups.background; borderSpec: FoamyStyle.popupBorderSpec; radius: FoamyStyle.radius }
            Controls.MenuItem {
              id: muteItem
              objectName: "notificationMute"
              text: root.dnd ? root.tr("Allow notifications") : root.tr("Silence notifications")
              enabled: !!root.store && !root.store.dndBusy
              implicitHeight: Style.space(42)
              contentItem: RowLayout {
                spacing: Style.space(10)
                FoamyIcon { name: root.dnd ? "bell-off" : "bell"; color: root.dnd ? Commons.Color.accent : root.foreground; Layout.preferredWidth: FoamyStyle.iconSize; Layout.preferredHeight: FoamyStyle.iconSize; Accessible.ignored: true }
                Text { text: muteItem.text; textFormat: Text.PlainText; font.family: root.fontFamily; font.pixelSize: FoamyStyle.font.bodySmall; color: root.foreground; Layout.fillWidth: true; wrapMode: Text.WordWrap }
              }
              background: Rectangle { color: muteItem.highlighted ? FoamyPalette.hoverFill : "transparent"; radius: FoamyStyle.radius }
              onTriggered: root.toggleDnd()
            }
            SnoozeItem {
              text: root.tr("Snooze notifications")
              // Hidden, not disabled, where the daemon has no timed snooze (stock 4.0 and 4.5-rc2).
              visible: !!root.store && root.store.snoozeAvailable
              height: visible ? implicitHeight : 0
              enabled: visible && !root.store.snoozeBusy
              onTriggered: Qt.callLater(function() { snoozeMenu.open() })
            }
          }

          Controls.Menu {
            id: snoozeMenu
            contentItem.LayoutMirroring.enabled: FoamyI18n.rightToLeft
            contentItem.LayoutMirroring.childrenInherit: true
            objectName: "notificationSnoozeMenu"
            x: moreMenu.x
            y: moreMenu.y
            width: Math.min(Style.space(290), content.width - FoamyStyle.padding * 2)
            padding: Style.space(5)
            enabled: !!root.store && root.store.snoozeAvailable && !root.store.snoozeBusy
            closePolicy: Controls.Popup.CloseOnEscape | Controls.Popup.CloseOnPressOutside
            background: BorderSurface { color: Commons.Color.popups.background; borderSpec: FoamyStyle.popupBorderSpec; radius: FoamyStyle.radius }
            onClosed: Qt.callLater(function() { if (root.opened && !root.editingSettings) keyCatcher.forceActiveFocus() })
            SnoozeItem { text: root.tr("30 minutes"); onTriggered: root.store.snoozeAll(30) }
            SnoozeItem { text: root.tr("1 hour"); onTriggered: root.store.snoozeAll(60) }
            SnoozeItem { text: root.tr("4 hours"); onTriggered: root.store.snoozeAll(240) }
            SnoozeItem { text: root.tr("Resume snoozed notifications"); onTriggered: root.store.snoozeAll(0) }
          }

          // ------------------------------------------------------ search
          RowLayout {
            id: searchRow
            objectName: "notificationSearchRow"
            visible: root.searching
            x: FoamyStyle.padding
            width: parent.width - FoamyStyle.padding * 2
            spacing: FoamyStyle.gap
            SafeTextField {
              id: search
              objectName: "notificationSearch"
              Layout.fillWidth: true
              implicitHeight: FoamyStyle.controlHeight
              enabled: root.searching
              placeholderText: root.tr("Search")
              translate: root.tr
              onTextChanged: { root.filter = text; if (root.store) root.store.searchQuery = text.trim().slice(0, 256) }
              onKeyPressed: function(event) {
                if (event.key === Qt.Key_Escape) { event.accepted = true; root.endSearch() }
                else if (event.key === Qt.Key_Down) {
                  event.accepted = true
                  keyCatcher.forceActiveFocus()
                  root.cursorIndex = -1
                  root.moveCursor(0, 1)
                }
              }
              // Keep the query while handing keyboard navigation to its results.
              onAccepted: {
                keyCatcher.forceActiveFocus()
                root.cursorIndex = -1
                root.moveCursor(0, 1)
              }
            }
            FoamyAction {
              iconName: "x"
              tooltipText: root.tr("Close search  ( Esc )")
              foreground: FoamyPalette.secondaryText
              onClicked: root.endSearch()
            }
          }

          Text {
            id: errorLine
            objectName: "notificationError"
            x: FoamyStyle.padding
            width: parent.width - FoamyStyle.padding * 2
            textFormat: Text.PlainText
            text: search.pasteError || (root.store ? root.tr(root.store.snoozeError || root.store.dndError || (root.store.focusError || root.store.loadError || root.store.removalError)) : "")
            visible: text !== ""
            color: Commons.Color.urgent
            font.family: root.fontFamily
            font.pixelSize: FoamyStyle.font.bodySmall
            wrapMode: Text.WordWrap
            Accessible.role: Accessible.AlertMessage
          }

          // ------------------------------------------------------ list
        Loader {
          id: listLoader
          width: parent.width
          active: true
          visible: (root.rows.length > 0 || (item && item.contentHeight > 0))
          // Keep the lightweight list; detach its model to release delegates after fade-out.
          sourceComponent: Component {
            NotificationList {
              id: list
              width: parent.width
              // Construct only visible rows when restoring the detached model.
              cacheBuffer: 0
              wheelStep: Style.space(96)
              // Paging (root.pageIfAtEnd): reaching the end, or content that
              // already fits, loads the next page.
              onAtYEndChanged: Qt.callLater(root.pageIfAtEnd)
              onContentHeightChanged: Qt.callLater(root.pageIfAtEnd)
              scrollbarWidth: Style.space(6)
              scrollbarInset: Style.space(2)
              // The flattened model keeps expanded stacks within the same virtualized list.
              readonly property int cap: root.listHeight > 0
                ? Math.min(Style.space(root.listHeight), root.listAvailableHeight) : root.listAvailableHeight

              implicitHeight: Math.min(Math.max(contentHeight, root.rows.length > 0 ? Style.space(100) : 0), cap)
              visible: root.rows.length > 0 || contentHeight > 0
              rows: root.rows
              contentActive: root.popupContentActive
              animateChanges: root.opened
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
                ListView.delayRemove: root.popupContentActive && exitMotion.running
                ListView.onRemove: {
                  // An invisible window does not advance row exit animations.
                  if (!root.popupContentActive) return
                  // Freeze departing content until Qt finishes its removal transition.
                  modelData = modelData
                  retired = true
                  exitMotion.start()
                }
                SequentialAnimation {
                  id: exitMotion
                  NumberAnimation { target: delegateRoot; property: "opacity"; to: 0; duration: FoamyMotion.duration(120); easing.type: Easing.OutCubic }
                  // Let ListView lay out the shrinking space, including its scroll extent.
                  NumberAnimation { target: delegateRoot; property: "height"; to: 0; duration: FoamyMotion.duration(140); easing.type: Easing.OutCubic }
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
          }
        }

        // --------------------------------------------------------- empty

        Text {
          textFormat: Text.PlainText
          x: FoamyStyle.padding
          width: parent.width - FoamyStyle.padding * 2
          visible: root.rows.length === 0 && (!listLoader.item || listLoader.item.contentHeight <= 0)
          horizontalAlignment: Text.AlignHCenter
          topPadding: Style.space(22)
          bottomPadding: Style.space(22)
          text: !root.loaded ? root.tr("Reading the archive…")
              : root.filter !== "" ? root.tr("Nothing matches “%1”", root.filter)
              : root.tr("Nothing has come in yet")
          wrapMode: Text.WordWrap
          font.family: root.fontFamily
          font.pixelSize: FoamyStyle.font.bodySmall
          color: FoamyPalette.mutedText
        }

        }

        FoamySettingsPage {
          id: settingsPane
          objectName: "notificationSettingsPane"
          visible: root.editingSettings
          width: parent.width
          height: Math.min(implicitHeight, Math.max(Style.space(100), popup.usableCardHeight - popup.verticalContentInset))
          maxHeight: Math.max(Style.space(100), popup.usableCardHeight - popup.verticalContentInset)
          saving: root.preferenceActive !== null
          error: root.settingsError
          retryable: false
          onBack: root.closeSettings()
          SettingsPane {
            id: settingsFields
            width: parent.width
            settings: root.settings
            popupSettings: root.popupSettings
            popupInstalled: root.popupPluginInstalled
            popupAvailable: root.popupPluginInstalled && root.popupSettingsAvailable
            loading: root.popupSettingsLoading
            saving: root.preferenceActive !== null
            page: settingsPane
            onSave: function(scope, key, value) { root.savePreference(scope, key, value) }
            Connections {
              target: root
              function onPreferenceFailed(scope, key) { settingsFields.saveFailed(scope, key) }
            }
          }
        }
      }
    }
  }
}
