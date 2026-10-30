import QtQuick
import "../kit"
import ".." as Plugin

// foamy-kit preview harness states (mock data only: no processes, no files).
// The real Panel is built with a mock store; the harness captures its FoamyPopup.
Item {
  id: preview
  required property QtObject bar
  required property Item anchorItem
  property var previewStates: ["default", "settings"]
  property string previewState: "default"
  property int settleMs: 900
  property Item popupRef: null
  readonly property Item popup: popupRef

  function find(item, name) {
    if (!item) return null
    if (item.objectName === name) return item
    var kids = item.data || item.children || []
    for (var i = 0; i < kids.length; i++) { var hit = find(kids[i], name); if (hit) return hit }
    return null
  }

  readonly property double now: 1793350800000
  readonly property var sample: [
    { key: "1793350740000-11", app: "Signal", appIcon: "signal-desktop", summary: "Ada Lovelace", body: "Are we still on for the review at 3? &amp; bring the notes", timestamp: now - 60000, urgency: 1 },
    { key: "1793350500000-10", app: "Signal", appIcon: "signal-desktop", summary: "Ada Lovelace", body: "Pushed the fix to the branch.", timestamp: now - 300000, urgency: 1 },
    { key: "1793349000000-9", app: "Omarchy", appIcon: "", glyph: "\u{f0450}", summary: "Update available", body: "Omarchy 4.5 is ready to install", timestamp: now - 1800000, urgency: 1 },
    { key: "1793345000000-8", app: "Calendar", appIcon: "org.gnome.Calendar", summary: "Team sync", body: "Starts in 10 minutes · Room 2", timestamp: now - 5800000, urgency: 2 },
    { key: "1793340000000-7", app: "Files", appIcon: "org.gnome.Nautilus", summary: "Transfer complete", body: "All 128 files were copied.", timestamp: now - 10800000, urgency: 1 }
  ]

  QtObject {
    id: store
    signal entryAdded(var entry)
    signal entriesReset()
    signal browserIconsUpdated()
    signal peerPreferencesChanged()
    signal focusCompleted()
    property var entries: preview.previewState === "empty" ? [] : preview.sample
    property int unread: preview.previewState === "empty" ? 0 : 2
    property bool unreadCapped: false
    property bool hasCriticalUnread: false
    property bool hasMore: false
    property bool loaded: true
    property string loadError: ""
    property bool doNotDisturb: false
    property bool dndBusy: false
    property string dndError: ""
    property bool snoozeAvailable: true
    property bool snoozeBusy: false
    property string snoozeError: ""
    property string focusError: ""
    property string removalError: ""
    property double lastSeen: preview.now - 120000
    property string searchQuery: ""
    property int keepDays: 30
    property int maxItems: 1000
    property bool showPreview: true
    function faviconSource(row) { return "" }
    function warmBrowserIcons(rows) {}
    function markSeen() {}
    function load() {}
    function loadMore() {}
    function remove(key) {}
    function removeMany(keys) {}
    function clearAll() {}
    function toggleDnd() {}
    function snoozeAll(minutes) {}
    function focusNotification(row, useDefault) {}
  }

  Component.onCompleted: Plugin.ServiceRegistry.instance = store

  Plugin.Panel {
    id: panel
    // Sit on the simulated bar's anchor so the popup lands where the real one does.
    x: preview.anchorItem.mapToItem(preview, 0, 0).x
    y: preview.anchorItem.mapToItem(preview, 0, 0).y
    width: preview.anchorItem.width
    height: preview.anchorItem.height
    bar: preview.bar
    manageIpc: false
    settings: ({ panelWidth: 420, badge: "Dot", compact: false, showBody: true, showPreview: true })
    Component.onCompleted: {
      preview.popupRef = panel.popupPanel
      Qt.callLater(function() { panel.open() })
    }
  }

  onPreviewStateChanged: Qt.callLater(function() {
    if (previewState === "settings") panel.openSettings()
    else if (panel.editingSettings) panel.closeSettings()
    var menu = find(panel, "notificationOverflowMenu")
    if (menu && previewState === "menu" && menu.open) menu.open()
  })
}
