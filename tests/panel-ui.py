"""Load the real Panel.qml offscreen with a stand-in store and check what the
bar button and the open panel show and do.

  python3 tests/panel-ui.py

The store is a plain object in the shape of Service.qml (as in
preview/Preview.qml), published through ServiceRegistry the way the shell
service does it, so each step sets exactly the store state it needs. Checks:
the bell's badge, count and tooltip for each unread and silenced state; a
right click silences without opening; the panel's open/close IPC target;
the loading, empty, no-match and error lines; the next page loads when the
list ends inside the viewport, after a read, when more turns up and when the
list is scrolled to its end; rows are not rebuilt while the panel is closed
and are current when it opens again; the search field opens over the band's
title row and the list stays where it is; the keys come back to the panel
after Esc in the search field and after a click beside it, opening search
takes the cursor off More options, Up then stops at the first row, and an
empty search field closes when it lets the keys go
(not for its own right-click menu); a number setting whose save failed can
be saved again with the same number. The run's theme has a dim red: the
error line and a critical stack's edge read at 4.5:1 on what they are
drawn on.

Runs through foamy-kit's preview/harness.py (isolated HOME, private bus, no
host commands, offscreen screen) against the Omarchy 4.5 shell host."""

import os
import sys
from pathlib import Path

KIT = Path(os.environ.get("FOAMY_KIT", Path.home() / "GitHub/Personal/foamy-kit"))
sys.path.insert(0, str(KIT / "preview"))
import harness  # foamy-kit's preview/harness.py

PLUGIN = Path(__file__).resolve().parents[1]
# Test functions in SHELL; QtTest's count at completion includes one entry of its own.
CASES = 12

SHELL = r"""
import QtQuick
import QtTest
import Quickshell
import qs.Commons
import qs.Commons as Commons
import "harness"
import "plugin" as Plugin
import "plugin/kit"

ShellRoot {
  id: shell
  // Entries in the shape the helper's `list` returns (newest first).
  function entries(count, distinctApps) {
    var out = []
    for (var i = 0; i < count; i++)
      out.push({key: (2000000 - i) + "-" + i, timestamp: 1793350800000 - i * 60000,
                app: distinctApps ? "App " + i : "Chat", appIcon: "", summary: "Message " + i, body: "Body " + i, urgency: 1})
    return out
  }

  QtObject {
    id: store
    signal entryAdded(var entry)
    signal entriesReset
    signal browserIconsUpdated
    signal peerPreferencesChanged
    signal focusCompleted
    property var entries: []
    property int unread: 0
    property bool unreadCapped: false
    property bool hasCriticalUnread: false
    property bool hasMore: false
    property bool listing: false
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
    property double lastSeen: 0
    property string searchQuery: ""
    // The search the current entries answer (Service.qml).
    property string entriesQuery: ""
    property int keepDays: 30
    property int maxItems: 1000
    property bool showPreview: true
    property var liveActions: ({})
    property bool pressingAction: false
    property int pages: 0
    property int dndToggles: 0
    function refreshLiveActions() {}
    function pressAction(row, index) {}
    function faviconSource(row) { return "" }
    function warmBrowserIcons(rows) {}
    function markSeen() {}
    function load() {}
    // As in Service.qml: a page request starts a read.
    function loadMore() { pages++; listing = true }
    function remove(key) {}
    function removeMany(keys) {}
    function clearAll() {}
    function toggleDnd() { dndToggles++ }
    function snoozeAll(minutes) {}
    function focusNotification(row, useDefault) {}
    // A new list read: the service replaces `entries` and resets the view.
    function show(rows) { entries = rows; entriesReset() }
  }
  Component.onCompleted: Plugin.ServiceRegistry.instance = store

  MockBar { id: bar; barSize: 34 }

  FloatingWindow {
    id: window
    implicitWidth: 1920
    implicitHeight: 1080
    color: "black"
    ScreenSim { id: sim; thickness: 34 }

    Plugin.Panel {
      id: panel
      parent: sim.anchor
      width: sim.anchor.width
      height: sim.anchor.height
      bar: bar
      fixedNow: 1793350800000
      settings: ({badge: "Dot"})
    }

    property bool ready: false
    Timer { interval: 300; running: true; onTriggered: window.ready = true }

    TestCase {
      name: "NotificationCenterPanel"
      when: window.ready
      // A guard for a step that waits on layout and timers, not a speed limit.
      readonly property int settle: 10000
      // The bar's inline save, while a case takes it away.
      property QtObject inlineShell: null
      // QtTest's own messages do not reach the qs log; this line does.
      function check(ok, what) {
        if (!ok)
          console.log("PANEL_UI FAIL " + what)
        verify(ok, what)
      }
      function same(actual, expected, what) {
        if (actual !== expected)
          console.log("PANEL_UI FAIL " + what + ": " + JSON.stringify(actual) + " instead of " + JSON.stringify(expected))
        compare(actual, expected, what)
      }
      function waitUntil(condition, what) {
        var deadline = Date.now() + settle
        while (!condition() && Date.now() < deadline)
          wait(20)
        check(condition(), what)
      }
      // Proves that no page request comes: the panel's paging hooks queue
      // their check with Qt.callLater, so a marker queued after the state
      // change runs after them. Then the panel decides once more with the
      // state as it is now.
      function noPageRequest(pages, what) {
        var done = false
        Qt.callLater(function() { done = true })
        waitUntil(function() { return done }, "the queued paging checks ran")
        panel.pageIfAtEnd()
        same(store.pages, pages, what)
      }
      // The bar items are direct children of the Panel: the bell is the one
      // with a tooltip, the count badge the Rectangle that holds a Text, the
      // dot the other round Rectangle.
      function barItems() {
        var found = {button: null, badge: null, dot: null}
        var kids = panel.children
        for (var i = 0; i < kids.length; i++) {
          var item = kids[i]
          if (item.tooltipText !== undefined)
            found.button = item
          else if (item.radius !== undefined && item.children.length === 1 && item.children[0].text !== undefined)
            found.badge = item
          else if (item.radius !== undefined && item.width > 0 && item.radius === item.width / 2)
            found.dot = item
        }
        check(found.button !== null && found.badge !== null && found.dot !== null, "the bell, count badge and dot exist")
        return found
      }
      function texts(item, out) {
        out = out || []
        if (!item)
          return out
        if (item.text !== undefined && typeof item.text === "string" && item.visible)
          out.push(item.text)
        var kids = item.children || []
        for (var i = 0; i < kids.length; i++)
          texts(kids[i], out)
        return out
      }
      function shows(text) { return panel.view !== null && texts(panel.view).indexOf(text) >= 0 }
      function openPanel() {
        panel.open()
        waitUntil(function() { return panel.opened && panel.view !== null && panel.list !== null }, "the panel opens")
      }
      function closePanel() {
        panel.close()
        waitUntil(function() { return !panel.opened }, "the panel closes")
      }
      function init() {
        store.unread = 0; store.unreadCapped = false; store.hasCriticalUnread = false
        store.doNotDisturb = false; store.loaded = true; store.loadError = ""
        store.hasMore = false; store.listing = false; store.pages = 0; store.dndToggles = 0
        store.entriesQuery = ""; store.searchQuery = ""
        panel.settings = ({badge: "Dot"})
      }
      // Each case starts from a closed panel whose list was released (the
      // panel drops it a second after closing), so no row animation of the
      // case before can move the list while the next one measures it.
      function cleanup() {
        if (panel.editingSettings)
          panel.closeSettings()
        if (inlineShell) {
          bar.shell = inlineShell
          inlineShell = null
        }
        if (panel.opened)
          closePanel()
        waitUntil(function() { return !panel.popupContentActive }, "the closed panel releases its list")
      }

      function test_bell_badge_and_tooltip() {
        var bell = barItems()
        check(!bell.dot.visible && !bell.badge.visible, "no badge without unread")
        same(bell.button.tooltipText, "Notifications", "tooltip without unread")
        store.unread = 1
        check(bell.dot.visible && !bell.badge.visible && !bell.button.active, "the dot shows unread, alone")
        same(String(bell.dot.color), String(Commons.Color.accent), "the dot colour for unread")
        same(bell.button.tooltipText, "1 new notification", "tooltip for one")
        store.unread = 3; store.hasCriticalUnread = true
        same(String(bell.dot.color), String(bar.urgent), "the dot colour for an unread critical")
        same(bell.button.tooltipText, "3 new notifications", "tooltip for several")
        store.doNotDisturb = true
        same(bell.button.tooltipText, "Silenced · 3 new", "tooltip while silenced with unread")
        check(bell.button.text !== "" && bell.button.dimmed, "the bell is dimmed while silenced")
        var silenced = bell.button.text
        store.unread = 0
        same(bell.button.tooltipText, "Notifications silenced", "tooltip while silenced")
        store.doNotDisturb = false
        check(bell.button.text !== silenced, "the bell glyph changes back when sound returns")
        panel.settings = ({badge: "Count"})
        store.unread = 120
        check(bell.badge.visible && !bell.dot.visible, "Count shows the number, not the dot")
        same(bell.badge.children[0].text, "99+", "count past 99")
        store.unread = 5
        same(bell.badge.children[0].text, "5", "count")
        store.unreadCapped = true
        same(bell.badge.children[0].text, "5+", "count beyond the loaded page")
        panel.settings = ({badge: "Highlight"})
        check(!bell.badge.visible && !bell.dot.visible && bell.button.active, "Highlight colours the bell itself")
        store.unread = 0
        check(!bell.button.active, "no highlight without unread")
      }

      function test_right_click_silences_without_opening() {
        var button = barItems().button
        mouseClick(button, button.width / 2, button.height / 2, Qt.RightButton)
        same(store.dndToggles, 1, "a right click toggles silence")
        check(!panel.opened, "a right click opens nothing")
        mouseClick(button, button.width / 2, button.height / 2, Qt.LeftButton)
        waitUntil(function() { return panel.opened }, "a left click opens the panel")
        same(store.dndToggles, 1, "a left click does not toggle silence")
      }

      function test_ipc_target_opens_and_closes() {
        // Users bind keys to `foamy.notification-center toggle`; the host's
        // registry answers omarchy-shell calls from the same handler.
        var handler = IpcRegistry.handlerFor("foamy.notification-center")
        check(handler !== null, "the panel registers its IPC target")
        IpcRegistry.call("foamy.notification-center", "toggle", [])
        waitUntil(function() { return panel.opened }, "toggle opens the panel")
        IpcRegistry.call("foamy.notification-center", "close", [])
        waitUntil(function() { return !panel.opened }, "close closes it")
      }

      function test_loading_empty_and_error_lines() {
        store.loaded = false
        store.show([])
        openPanel()
        waitUntil(function() { return shows("Reading the archive…") }, "the first read shows its progress")
        store.loaded = true
        waitUntil(function() { return shows("Nothing has come in yet") }, "an empty archive says so")
        store.loadError = "Invalid notification history response."
        var error = findChild(panel.view, "notificationError")
        waitUntil(function() { return error.visible && error.text === "Invalid notification history response." }, "a failed read shows its error")
        // The run's theme has a dim red (2.70:1 on the popup): the error
        // line still reads at 4.5:1 on the popup's card it is drawn on.
        var card = panel.popupPanel.cardItem
        check(card !== null, "the popup's card is drawn")
        check(FoamyPalette.contrastRatio(FoamyPalette.error, card.color) < 4.5, "the theme's red already reads; the check proves nothing")
        check(FoamyPalette.contrastRatio(error.color, card.color) >= 4.5, "the error line " + error.color + " reads on " + card.color)
        check(!shows("Nothing has come in yet"), "a failed read does not also say the archive is empty")
        panel.filter = "zzz"
        store.entriesQuery = "zzz"
        store.show([])
        check(!shows("Nothing matches “zzz”"), "a failed search read does not say nothing matches")
        panel.filter = ""
        store.entriesQuery = ""
        store.show([])
        store.loadError = ""
        check(!error.visible, "the error line goes once the read works")
        store.show(shell.entries(2, true))
        panel.filter = "zzz"
        store.entriesQuery = "zzz"
        store.show([])
        waitUntil(function() { return panel.rows.length === 0 && shows("Nothing matches “zzz”") }, "a search without hits names the query")
        panel.filter = ""
        store.entriesQuery = ""
        store.show(shell.entries(2, true))
        waitUntil(function() { return panel.rows.length > 0 && !shows("Nothing has come in yet") }, "rows replace the empty line")
      }

      // A critical stack's 3 px edge runs down its header and rows, each a
      // StackFrame. As painted, it reads at 4.5:1 on every fill it crosses
      // (in the run's dim red, which reads on none of them raw).
      function test_critical_edge_reads_on_each_fill() {
        store.show([
          {key: "2000000-0", timestamp: 1793350800000, app: "Calendar", appIcon: "", summary: "Team sync", body: "Starts in 10 minutes", urgency: 2},
          {key: "1999999-1", timestamp: 1793350740000, app: "Calendar", appIcon: "", summary: "Lunch", body: "Starts at noon", urgency: 1}
        ])
        openPanel()
        function frames(item, out) {
          if (item.critical === true && item.leading !== undefined && item.visible)
            out.push(item)
          var kids = item.children || []
          for (var i = 0; i < kids.length; i++)
            frames(kids[i], out)
          return out
        }
        waitUntil(function() { return panel.rows.length === 2 && frames(panel.list, []).length === 2 }, "the stack's header and its newest row show")
        // Expanded, the stack also shows its row that is not critical.
        panel.toggleGroup("Calendar")
        waitUntil(function() { return frames(panel.list, []).length === 3 }, "the expanded stack shows both rows")
        var found = frames(panel.list, [])
        var fills = found.map(function(frame) { return frame.fill }).concat([panel.popupPanel.cardItem.color])
        fills.forEach(function(fill) {
          check(FoamyPalette.contrastRatio(Commons.Color.urgent, fill) < 4.5, "the theme's urgent colour already reads on " + fill + "; the check proves nothing")
        })
        found.forEach(function(frame) {
          // What the frame painted, halfway down its leading edge (QtTest's
          // grabImage cannot grab the panel's own popup window).
          var data = frame.context.getImageData(1, Math.round(frame.height / 2), 1, 1).data
          var drawn = Qt.rgba(data[0] / 255, data[1] / 255, data[2] / 255, data[3] / 255)
          fills.forEach(function(fill) {
            check(FoamyPalette.contrastRatio(drawn, fill) >= 4.5, "the critical edge " + drawn + " reads on " + fill)
          })
        })
      }

      function test_search_shows_what_the_store_found() {
        store.show(shell.entries(2, true))
        openPanel()
        panel.startSearch()
        var search = findChild(panel.view, "notificationSearch")
        waitUntil(function() { return search !== null && search.visible }, "the search field opens")
        // The store gets the trimmed query; its matcher folds case fully, so
        // "strasse" finds "Straße". The panel shows that answer as it is.
        search.text = "strasse "
        same(store.searchQuery, "strasse", "the store searches the trimmed text")
        var found = [{key: "3000000-1", timestamp: 1793350800000, app: "Maps", appIcon: "", summary: "Straße closed", body: "Detour", urgency: 1},
                     {key: "2999999-1", timestamp: 1793350700000, app: "Maps", appIcon: "", summary: "Hauptstrasse", body: "Open again", urgency: 1}]
        store.entriesQuery = "strasse"
        store.show(found)
        waitUntil(function() { return panel.rows.length === 3 }, "both found rows are listed under their header")
        check(panel.rows[0].kind === "header" && panel.rows[0].expanded, "a search opens the stack")
        check(!shows("Nothing matches “strasse ”"), "no empty line while rows are found")
        panel.endSearch()
      }

      function test_search_opens_over_the_band_title_and_the_list_stays() {
        // DESIGN.md, Field mode: the field lies across the band's title row,
        // so the list under the band does not move when search opens.
        store.show(shell.entries(3, true))
        openPanel()
        var band = panel.header
        var listTop = function() { return panel.list.mapToItem(panel.view, 0, 0).y }
        waitUntil(function() { return listTop() >= band.height }, "the list lies under the band")
        var top = listTop()
        panel.startSearch()
        var search = findChild(panel.view, "notificationSearch")
        waitUntil(function() { return search.visible }, "the search field shows")
        // A frame later, so a layout change has been applied.
        waitForRendering(panel.view)
        same(listTop(), top, "the list's top while the search is open")
        var middle = search.mapToItem(band.titleRow, 0, search.height / 2).y
        check(middle > 0 && middle < band.titleRow.height, "the search field lies over the band's title row")
      }

      function test_keys_return_to_the_panel_when_the_search_field_lets_go() {
        // The hidden search field drops its focus to the popup body, not to
        // the key catcher, so the panel itself must hand the keys back.
        store.show(shell.entries(3, true))
        openPanel()
        waitUntil(function() { return panel.view.Window.active }, "the panel window is active")
        var search = findChild(panel.view, "notificationSearch")
        // Opened all the way, so a click beside it misses the growing field.
        var openSearch = function(what) {
          panel.startSearch()
          waitUntil(function() { return search.inputActiveFocus && panel.header.fieldProgress === 1 }, what)
        }
        // A click on the band's empty side padding, level with the field.
        var clickBeside = function() {
          var at = search.mapToItem(panel.view, 0, search.height / 2)
          mouseClick(panel.view, at.x / 2, at.y)
        }
        openSearch("the search field has the keys")
        keyClick(Qt.Key_M)
        keyClick(Qt.Key_Escape)
        waitUntil(function() { return !panel.searching && panel.view.activeFocus }, "Esc in the search field gives the keys to the panel")
        keyClick(Qt.Key_Down)
        check(panel.keyboardNavigation && panel.cursorIndex === 0, "Down after Esc moves the cursor to the first row")

        // More options selected, then "/" opens the field over it. A click
        // beside the field keeps the query, and the cursor is off that button.
        keyClick(Qt.Key_Up)
        check(panel.cursorOnSettings, "Up from the first row selects More options")
        keyClick("/")
        waitUntil(function() { return search.inputActiveFocus && panel.header.fieldProgress === 1 }, "\"/\" opens the search field with the keys")
        keyClick(Qt.Key_M)
        store.entriesQuery = "m"
        store.show(shell.entries(3, true))
        clickBeside()
        waitUntil(function() { return !search.inputActiveFocus && panel.view.activeFocus }, "a click beside the field gives the keys to the panel")
        check(panel.searching, "the search stays open after the click")
        same(search.text, "m", "the query after the click")
        keyClick(Qt.Key_Up)
        check(panel.cursorIndex === 0 && !panel.cursorOnSettings, "Up after the click selects the first row, not the covered More options")
        var cursor = panel.cursorIndex
        keyClick(Qt.Key_Down)
        same(panel.cursorIndex, cursor + 1, "Down after the click moves the cursor")
        // The field covers the ⋯ button, so Up has no stop above the first row.
        for (var up = panel.cursorIndex; up >= 0; up--)
          keyClick(Qt.Key_Up)
        check(panel.cursorIndex === 0 && !panel.cursorOnSettings, "Up stops at the first row while the search field covers ⋯")
        store.show([])
        waitUntil(function() { return panel.rows.length === 0 }, "the search finds nothing")
        keyClick(Qt.Key_Down)
        check(!panel.cursorOnSettings, "an arrow key without matches keeps the cursor off the covered ⋯")
        keyClick(Qt.Key_Escape)
        waitUntil(function() { return !panel.searching }, "Esc on the panel ends the search")
        check(panel.opened, "Esc that ends the search leaves the panel open")
        same(search.text, "", "the query after the search ends")

        // An empty field closes when it lets the keys go, so the title row
        // comes back. Its own right-click menu taking them is not that: the
        // menu's Paste needs the field open.
        openSearch("the search field has the keys once more")
        var editor = search.editorItem
        mouseClick(editor, editor.width / 2, editor.height / 2, Qt.RightButton)
        waitUntil(function() { return !search.inputActiveFocus }, "the field's menu takes the keys")
        check(panel.searching, "the empty search stays open while its menu has the keys")
        keyClick(Qt.Key_Escape)
        waitUntil(function() { return search.inputActiveFocus }, "Esc closes the menu back into the field")
        check(panel.searching, "the empty search stays open after its menu closes")
        clickBeside()
        waitUntil(function() { return !panel.searching && panel.view.activeFocus }, "an empty search closes when a click beside it takes the keys")
        check(panel.opened, "the click that closes the empty search leaves the panel open")
      }

      function test_next_page_loads_when_the_list_ends_in_view() {
        // 500 rows of one app collapse to a header and one card: the list
        // sits at its end from the start and never scrolls.
        store.listing = true
        store.hasMore = true
        store.show(shell.entries(500, false))
        openPanel()
        waitUntil(function() { return panel.rows.length === 2 }, "one collapsed stack")
        noPageRequest(0, "no page request while a read runs")
        store.listing = false
        waitUntil(function() { return store.pages === 1 }, "the read's end loads the next page")
        noPageRequest(1, "one request per read")
        // The page came back empty-handed: nothing more to read.
        store.hasMore = false
        store.listing = false
        noPageRequest(1, "no request without more")
        // A later read finds more (the archive grew) while the list still fits.
        store.hasMore = true
        waitUntil(function() { return store.pages === 2 }, "more turning up loads it")
        store.hasMore = false; store.listing = false
      }

      function test_next_page_loads_at_the_end_of_a_long_list() {
        store.hasMore = false
        store.show(shell.entries(40, true))
        openPanel()
        waitUntil(function() { return panel.rows.length === 80 && panel.list.contentHeight > panel.list.height }, "a list longer than the panel")
        store.hasMore = true
        noPageRequest(0, "no page request above the end")
        // Rows below the view are built as they come in, so the end moves
        // while the view gets there.
        waitUntil(function() { panel.list.positionViewAtEnd(); return panel.list.atYEnd }, "the list reaches its end")
        waitUntil(function() { return store.pages === 1 }, "scrolling to the end loads the next page")
      }

      function test_rows_wait_while_closed_and_are_current_on_open() {
        store.show(shell.entries(2, true))
        openPanel()
        waitUntil(function() { return panel.rows.length === 4 }, "two single-card stacks")
        closePanel()
        var before = panel.rows.length
        var next = shell.entries(3, true).map(function(row) { return Object.assign({}, row, {key: "9" + row.key, app: "New " + row.app}) })
        store.show(next.concat(store.entries))
        store.entryAdded(next[0])
        same(panel.rows.length, before, "no rebuild while closed")
        openPanel()
        same(panel.rows.length, 10, "the opened panel lists every entry")
        check(panel.rows.some(function(row) { return row.kind === "message" && row.entry.key === next[0].key }), "the new entry is listed")
      }

      function typeNine(number) {
        number.field.forceActiveFocus()
        keyClick(Qt.Key_End); keyClick(Qt.Key_Backspace); keyClick(Qt.Key_Backspace)
        keyClick(Qt.Key_9); keyClick(Qt.Key_Return)
      }

      function test_failed_number_save_can_be_retried() {
        // Without the bar's inline save the panel runs `omarchy bar set`;
        // the fake omarchy fails its first call and saves after that.
        inlineShell = bar.shell
        bar.shell = null
        openPanel()
        panel.openSettings()
        var days = null
        waitUntil(function() {
          days = panel.settingsPane ? findChild(panel.settingsPane, "center-keepDays") : null
          return days !== null && days.visible && !panel.popupSettingsLoading
        }, "the settings page shows the number field")
        same(days.field.text, "30", "the stored number")
        typeNine(days)
        waitUntil(function() { return panel.preferenceActive === null && panel.settingsError !== "" }, "the failed save ends")
        same(panel.settingsError, "Could not save settings. Try again.", "the error after a failed save")
        same(days.field.text, "30", "the field shows the stored number again")
        waitUntil(function() { return !panel.popupSettingsLoading }, "the settings page settles")
        // The same number again is a new attempt, not a commit already made.
        typeNine(days)
        waitUntil(function() { return panel.preferenceActive === null && !panel.popupSettingsLoading && panel.settingsError === "" }, "the same number saves again")
      }

      onCompletedChanged: if (completed) {
        console.log("PANEL_UI", qtest_results.passCount, "passed", qtest_results.failCount, "failed")
        console.log("FOAMY DONE")
        Qt.quit()
      }
    }
  }
}
"""

# `omarchy bar set` for the center's own settings: the first save fails,
# later ones succeed. Foamy Notifications (reached through omarchy-shell
# for the popup settings) is not running.
FAKEBIN = {
    "omarchy": '#!/bin/sh\nprintf "%s\\n" "$*" >> "$FOAMY_OUT/omarchy-calls.log"\n'
    '[ "$(wc -l < "$FOAMY_OUT/omarchy-calls.log")" -gt 1 ]\n',
    "omarchy-shell": "#!/bin/sh\nexit 1\n",
}
SAVE = "bar set foamy.notification-center keepDays 9 --json"
DIM_RED = KIT / "tests/fixtures/themes/dim-red.toml"

status = 0
for host in harness.available_hosts(what="panel-ui"):
    # The kit's dark theme with a dim red, for the error line's colour check.
    run = harness.Run(
        host, SHELL, plugin=PLUGIN, prefix=f"foamy-center-panel-{host}-", fakebin=FAKEBIN, theme=DIM_RED
    ).run(timeout=120)
    calls_log = run.out / "omarchy-calls.log"
    saves = calls_log.read_text().splitlines() if calls_log.exists() else []
    # Any QML warning from the plugin's own files fails the run too.
    warnings = [
        line for line in run.log.splitlines() if "WARN" in line and "/plugin/" in line and "/plugin/kit/" not in line
    ]
    summary = [line for line in run.log.splitlines() if "PANEL_UI" in line]
    passed = f"PANEL_UI {CASES + 1} passed 0 failed" in run.log
    if run.ok and passed and not warnings and not run.host_commands() and saves == [SAVE, SAVE]:
        print(f"{host}: panel-ui passed ({summary[-1].split('PANEL_UI', 1)[1].strip()})")
        run.cleanup()
    else:
        status = 1
        print(run.log)
        print("\n".join(warnings))
        print("host commands ran:", *run.host_commands(), sep="\n  ")
        print("omarchy calls:", *saves, sep="\n  ")
        print(f"{host}: panel-ui FAILED; log at {run.base}/qs.log")
sys.exit(status)
