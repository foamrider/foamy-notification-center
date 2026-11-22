"""Load the real Panel.qml with the real Service and its helper offscreen, on
disposable configuration, and check the settings, the menu, search, the
archived screenshot click and dismissal.

  python3 tests/settings-ui.py

Fixtures: a history file with an omasnap screenshot, a shell.json with the
center's bar entry and Foamy Notifications' plugins[] entry, a model of Foamy
Notifications' preference endpoint and of the stock daemon's snooze and DND
calls, the host's setBarWidget endpoint, a test double of `omarchy bar set`
and an omasnap stand-in. XDG_CONFIG_HOME points away from
$HOME/.config: the host reads shell.json only there, so the panel must watch
that path (the store's watcher of the same file has no runtime test yet).

Runs through foamy-kit's preview/harness.py (isolated HOME, private bus, no
host commands, offscreen screen) against the Omarchy 4.5 shell host."""

import json
import os
import sys
import time
from pathlib import Path

from favicon_test import png

KIT = Path(os.environ.get("FOAMY_KIT", Path.home() / "GitHub/Personal/foamy-kit"))
sys.path.insert(0, str(KIT / "preview"))
import harness  # noqa: E402  (foamy-kit's preview/harness.py)

PLUGIN = Path(__file__).resolve().parents[1]
# Test functions in SHELL; QtTest's pass count also includes its initTestCase.
CASES = 11

SHELL = r"""pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import "harness"
import "plugin" as Plugin
import "plugin/Preferences.js" as PluginPreferences
import "plugin/kit" as Kit
ShellRoot {
  id: root
  // The shell's language file: Arabic turns FoamyI18n.rightToLeft on.
  FileView { id: language; path: Quickshell.env("OMARCHY_LANGUAGE_FILE") }
  property var config: ({})
  property bool failSave: false
  property bool dnd: false
  property int snoozedMinutes: 0
  // Every `unsnooze` key, in order: "*" clears the old timer before a new
  // snooze, "" resumes.
  property var unsnoozed: []
  QtObject {
    id: registry
    property var installedPlugins: ({"foamy.notifications":{id:"foamy.notifications"}})
  }
  Component.onCompleted: {
    Commons.Color.background = "#24273a"; Commons.Color.foreground = "#cad3f5"; Commons.Color.accent = "#8aadf4"
  }
  // The stock daemon's snooze and DND calls.
  IpcHandler {
    target: "notifications"
    function snoozes(): string { return "{}" }
    function unsnooze(key: string): string { root.unsnoozed = root.unsnoozed.concat([key]); root.snoozedMinutes=0; return "ok" }
    function snoozeAll(minutes: string): string { root.snoozedMinutes=Number(minutes); return "ok" }
    function isDnd(): string { return root.dnd ? "on" : "off" }
    function toggleDnd(): string { root.dnd = !root.dnd; return root.dnd ? "on" : "off" }
  }
  FileView {
    id: configFile
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true
    onFileChanged: reload()
    onLoaded: root.config = JSON.parse(text())
  }
  // Model Foamy Notifications' preference endpoint (Service.qml FoamyIpc): it
  // answers only while enabled in shell.json, saves to its own plugins[] entry
  // and then pokes the center's store ("saving", then peerChanged).
  IpcHandler {
    target: "foamy.notifications"
    function entry() {
      var config = JSON.parse(configFile.text())
      if ((config.disabledPlugins || []).indexOf("foamy.notifications") >= 0) return null
      return (config.plugins || []).filter(function(p) { return p.id === "foamy.notifications" })[0] || null
    }
    function preferences(): string {
      var stored = entry()
      if (!stored) return ""
      var values = {}
      PluginPreferences.popupFields.forEach(function(field) {
        values[field.key] = PluginPreferences.value("popups", stored, field.key)
      })
      return JSON.stringify({settings: values, error: "", saving: false, saveError: ""})
    }
    function setPreference(key: string, valueJson: string): string {
      var value
      try { value = JSON.parse(String(valueJson).trim()) } catch (e) { return "error: invalid value" }
      if (!entry() || !PluginPreferences.valid("popups", key, value)) return "error: invalid value"
      var next = JSON.parse(configFile.text())
      next.plugins.filter(function(p) { return p.id === "foamy.notifications" })[0][key] = value
      configFile.setText(JSON.stringify(next))
      root.config = next
      peerSaved.restart()
      return "saving"
    }
  }
  // The real save runs a helper process, so the poke comes after "saving" is read.
  Timer { id: peerSaved; interval: 150; onTriggered: store.peerPreferencesChanged() }
  // Model the host's widget endpoint.
  IpcHandler {
    target: "shell"
    function setBarWidget(id: string, key: string, valueJson: string, selectorJson: string): string {
      if (root.failSave) return "fixture save failure"
      var next = JSON.parse(configFile.text())
      if (id !== "foamy.notification-center") return "invalid widget"
      next.bar.layout.right[0][key] = JSON.parse(valueJson)
      configFile.setText(JSON.stringify(next))
      root.config = next
      return "ok"
    }
  }
  Plugin.Service { id: store }
  // The store's own seed command; its exit reloads the list.
  Process { id: seeder; command: store.storeCommand(["seed", "4"]); environment: store.storeEnvironment; onExited: store.load() }
  // The archived keys as a fresh helper `list` reads them. The Service's
  // memory (the removed keys it filters out, a list it emptied before its
  // helper ran) cannot stand in for what the archive holds.
  property var stored: null
  Process {
    id: reader
    command: store.storeCommand(["list", "100", ""])
    environment: store.storeEnvironment
    stdout: StdioCollector { onStreamFinished: root.stored = JSON.parse(text).map(function(row) { return row.key }) }
    onExited: function(code) { if (code !== 0) console.log("SETTINGS_FAILURE the store read exited with " + code) }
  }
  FileView { id: editorReady; path: Quickshell.env("HOME") + "/editor-ready" }
  // The bar API the panel uses. It has no shell.updateEntryInline, so center
  // saves take the `omarchy bar set` path (kit FoamyPrefs saveCommand).
  QtObject {
    id: bar
    property string position: "top"
    property var pluginRegistry: registry
    property int barSize: 34
    property string fontFamily: "sans-serif"
    property color barForeground: Commons.Color.foreground
    property color urgent: Commons.Color.urgent
    property bool vertical: false
    property bool hideLabels: false
    property bool foregroundAnimationEnabled: false
    property var activePopout: false
    function requestPopout(key) { activePopout = key }
    function releasePopout(key) { if (activePopout === key) activePopout = false }
  }
  FloatingWindow {
    id: window
    implicitWidth: 1920
    implicitHeight: 1080
    color: Commons.Color.background
    // The host KeyboardPanel's window is drawn into this simulated screen.
    ScreenSim { id: sim; thickness: 34 }
    Plugin.Panel {
      id: panel
      parent: sim.anchor
      width: sim.anchor.width
      height: sim.anchor.height
      bar: bar
      settings: root.config.bar ? root.config.bar.layout.right[0] : ({})
    }
    property bool ready: false
    Timer { interval: 500; running: true; onTriggered: window.ready = true }
    TestCase {
      name: "NotificationSettings"
      when: window.ready
      function lookup(name) {
        var item = findChild(panel, name)
        var pane = findChild(panel, "notificationSettingsPane")
        if (item === null && pane) item = findChild(pane, name)
        return item
      }
      function control(name) {
        var item = lookup(name)
        if (item === null) console.log("MISSING_CONTROL", name)
        verify(item !== null, "Missing " + name)
        return item
      }
      // `name` once it exists and shows.
      function shown(name) {
        var item = null
        tryVerify(function() { item = lookup(name); return item !== null && item.visible }, roundTrip, "shows " + name)
        return item
      }
      function capture(item, name) {
        var done = false
        item.grabToImage(function(result) { verify(result.saveToFile(Qt.resolvedUrl(name + ".png").toString().replace("file://", ""))); done = true })
        tryVerify(function() { return done }, roundTrip, "captured " + name)
      }
      // A hang guard for a step that waits on processes (an omarchy-shell
      // call is a `qs ipc` start, a save takes several), not a speed limit:
      // on a loaded machine one round trip took longer than the 5 s default.
      readonly property int roundTrip: 20000
      // keyClick() goes to the focus window: wait until `item` has the keys
      // there, not only the focus inside its own window.
      function focusOn(item) {
        item.forceActiveFocus()
        tryVerify(function() { return item.activeFocus && item.Window.active }, roundTrip, "keyboard focus on " + item)
      }
      // FileView.setText() writes asynchronously, and the watcher's reload
      // of an earlier write can land after it: wait until the file is
      // written and a fresh read returns `text`.
      // No preference read or save in flight: openSettings() starts no read
      // while one runs, so it would answer from before a configuration write.
      function settle() {
        tryVerify(function() { return !panel.popupSettingsLoading && panel.preferenceActive === null }, roundTrip, "the panel settled")
      }
      function writeFile(view, text) {
        var saved = false
        var onSaved = function() { saved = true }
        view.saved.connect(onSaved)
        view.setText(text)
        tryVerify(function() { return saved }, roundTrip, "wrote " + view.path)
        view.saved.disconnect(onSaved)
        view.reload()
        tryVerify(function() { return view.loaded && view.text() === text }, roundTrip, "read back " + view.path)
      }
      // QtTest sends keyClick() to QGuiApplication::focusWindow(): wait until
      // the window that holds the panel is active, or a key is lost.
      function init() {
        panel.open(); tryCompare(panel, "opened", true, roundTrip)
        tryVerify(function() { return panel.view !== null && panel.view.Window.active }, roundTrip, "The panel never got keyboard focus")
      }
      function cleanup() { panel.close(); tryCompare(panel, "opened", false, roundTrip) }
      // The panel's error line shows `english`, then `norwegian` under Norwegian.
      function speaks(english, norwegian) {
        var line = findChild(panel.view, "notificationError")
        tryCompare(line, "text", english, roundTrip)
        language.setText("no\n"); tryCompare(Kit.FoamyI18n, "language", "no", 10000)
        tryVerify(function() { return line.text === norwegian }, roundTrip, "the error line reads " + line.text + " in Norwegian")
        language.setText("en\n"); tryCompare(Kit.FoamyI18n, "language", "en", 10000)
        tryCompare(line, "text", english, roundTrip)
      }
      function test_00_direction() {
        try {
        for (var direction = 0; direction < 2; direction++) {
          language.setText(direction ? "ar\n" : "en\n");
          tryCompare(Kit.FoamyI18n, "rightToLeft", !!direction, 10000);
          panel.openSettings();
          var pane = shown("notificationSettingsPane");
          compare(pane.LayoutMirroring.enabled, !!direction);
          tryVerify(function() { var backX = pane.backTarget.mapToItem(pane, 0, 0).x; return direction ? backX > pane.width / 2 : backX < pane.width / 2 }, roundTrip, "Back sits on the reading start");
          capture(pane, direction ? "rtl-settings" : "ltr-settings");
          panel.closeSettings();
          tryVerify(function() { return !panel.editingSettings && panel.rows.length > 0 }, roundTrip, "the fixture's notification is listed");
          panel.moveCursor(direction ? -1 : 1, 0); compare(panel.cursorDismiss, true);
          panel.moveCursor(direction ? 1 : -1, 0); compare(panel.cursorDismiss, false);
          panel.startSearch();
          var search = shown("notificationSearch");
          tryVerify(function() { return search.width > 100 }, roundTrip, "Search must have usable width in both directions");
          search.text = "screenshot"; compare(panel.filter, "screenshot");
          capture(search.parent.parent, direction ? "rtl-search" : "ltr-search");
          panel.endSearch();
          tryCompare(panel, "searching", false, roundTrip);
        }
        language.setText("en\n");
        tryCompare(Kit.FoamyI18n, "rightToLeft", false, 10000);
        } catch (error) { console.log("SETTINGS_FAILURE direction", error.message, error.stack); throw error }
      }
      function test_00_snooze_menu() {
        try {
        // The header's kit ⋯ menu: Snooze is a submenu (opens in place, Back row first).
        var header = panel.header, menu = header.menu
        mouseClick(control("foamyMenuButton"))
        tryCompare(header, "menuOpen", true, roundTrip)
        var snooze = header.menuItems[1]
        compare(snooze.objectName, "notificationSnooze")
        tryCompare(snooze, "visible", true, roundTrip)
        tryCompare(snooze, "enabled", true, roundTrip)
        menu.activate(menu.entries.indexOf(snooze))
        tryCompare(menu, "inSubmenu", true, roundTrip)
        compare(menu.entries.length, 5)
        for (var i = 0; i < menu.entries.length; i++) verify(menu.entries[i].iconName !== "", "icon for " + menu.entries[i].text)
        wait(150); capture(menu.panel, "snooze-menu")
        // 30 minutes: the old timer is cleared first, then the new snooze set.
        menu.activate(menu.entries.indexOf(snooze.items[0])); tryCompare(root,"snoozedMinutes",30)
        compare(JSON.stringify(root.unsnoozed), JSON.stringify(["*"]))
        compare(header.menuOpen, false)
        // The fixture changes on the IPC call; the service takes the next
        // snooze only once that call's process has exited (one at a time).
        tryCompare(store, "snoozeBusy", false, roundTrip)
        header.openMenu(true)
        menu.activate(menu.entries.indexOf(snooze))
        // Resume: only the unsnooze of every source.
        menu.activate(menu.entries.indexOf(snooze.items[3])); tryCompare(root,"snoozedMinutes",0)
        tryCompare(store, "snoozeBusy", false, roundTrip)
        compare(JSON.stringify(root.unsnoozed), JSON.stringify(["*", ""]))
        header.closeMenu()
        } catch (error) { console.log("SETTINGS_FAILURE snooze", error.message, error.stack); throw error }
      }
      function test_01_menu_items_and_silence() {
        try {
        // Search and clear all stay in the row, then ⋯; Silence, Snooze, a
        // separator and Settings (last) are in its menu, each with an icon.
        var header = panel.header, menu = header.menu, more = control("foamyMenuButton")
        mouseClick(more)
        tryCompare(header, "menuOpen", true, roundTrip)
        verify(control("notificationSearchButton").visible)
        verify(control("clearAllNotifications").visible)
        var entries = menu.entries
        compare(entries.length, 4)
        compare(entries[0].objectName, "notificationMute")
        verify(entries[2].separator)
        compare(entries[3].objectName, "foamyMenuSettings")
        for (var i = 0; i < entries.length; i++) if (!entries[i].separator) verify(entries[i].iconName !== "", "icon for " + entries[i].text)
        wait(150); capture(menu.panel, "overflow-menu")
        // Silence is disabled while a DND read runs (one follows every snooze
        // and the startup refresh); activating it then would do nothing.
        tryCompare(store, "dndBusy", false, roundTrip)
        menu.activate(0)
        tryCompare(root, "dnd", true, roundTrip)
        tryCompare(panel, "dnd", true, roundTrip)
        } catch (error) { console.log("SETTINGS_FAILURE menu", error.message, error.stack); throw error }
      }
      function test_02_keyboard_reaches_settings() {
        try {
        // The ⋯ button is the cursor stop above the first row.
        var header = panel.header, menu = header.menu
        focusOn(panel.view); keyClick(Qt.Key_Up)
        verify(panel.cursorOnSettings && header.menuHasCursor)
        keyClick(Qt.Key_Return)
        tryCompare(header, "menuOpen", true, roundTrip)
        compare(menu.currentIndex, 0)
        keyClick(Qt.Key_End); keyClick(Qt.Key_Return)
        tryCompare(panel, "editingSettings", true, roundTrip)
        tryCompare(panel, "popupSettingsLoading", false, roundTrip)
        verify(panel.popupSettingsAvailable, panel.settingsError)
        shown("popups-compact")
        } catch (error) { console.log("SETTINGS_FAILURE keyboard", error.message, error.stack); throw error }
      }
      function test_03_saves_reach_their_owner() {
        try {
        panel.openSettings()
        tryCompare(panel, "popupSettingsLoading", false, roundTrip)
        verify(panel.popupSettingsAvailable, panel.settingsError)
        var pane = shown("notificationSettingsPane")
        tryVerify(function() { return pane.height > 500 }, roundTrip, "The full settings view must fit on this fixture screen")
        waitForRendering(pane)
        var card = pane.parent.parent.parent.parent
        capture(card, "settings-wide-dark")
        // Popup settings land in Foamy Notifications' plugins[] entry, never in the bar entry.
        var silenceCritical = shown("popups-dndSilenceCritical")
        compare(silenceCritical.checked, false)
        focusOn(silenceCritical); keyClick(Qt.Key_Space)
        tryVerify(function() { return panel.preferenceActive === null && panel.popupSettings.dndSilenceCritical === true }, roundTrip)
        compare(root.config.plugins[0].dndSilenceCritical, true)
        compare(root.config.bar.layout.right[0].dndSilenceCritical, undefined)
        var compact = control("popups-compact")
        compact.clicked()
        tryVerify(function() { return panel.preferenceActive === null && panel.popupSettings.compact === false }, roundTrip)
        compare(panel.popupSettings.compact, false)
        tryVerify(function() { return root.config.plugins[0].compact === false }, roundTrip)
        compare(root.config.bar.layout.right[0].compact, undefined)
        var removeWithX = control("popups-closeButtonRemovesHistory")
        compare(removeWithX.checked, false)
        focusOn(removeWithX); keyClick(Qt.Key_Space)
        tryVerify(function() { return panel.preferenceActive === null && panel.popupSettings.closeButtonRemovesHistory === true }, roundTrip)
        compare(root.config.plugins[0].closeButtonRemovesHistory, true)
        compare(root.config.bar.layout.right[0].closeButtonRemovesHistory, undefined)
        // A center setting lands in the bar entry through `omarchy bar set`.
        panel.savePreference("center", "compact", true)
        tryVerify(function() { return root.config.bar.layout.right[0].compact === true }, roundTrip)
        tryVerify(function() { return panel.preferenceActive === null }, roundTrip)
        compare(panel.compact, true)
        compare(root.config.plugins[0].compact, false)
        panel.savePreference("popups", "normalTimeoutSec", 15)
        tryVerify(function() { return panel.popupSettings.normalTimeoutSec === 15 }, roundTrip)
        // A key no save touches stays.
        compare(root.config.other, "preserved")
        // The settings page follows a narrow panel without clipping.
        panel.settings = Object.assign({}, panel.settings, {panelWidth:320})
        tryVerify(function() { return pane.width <= panel.panelWidth && pane.width > panel.panelWidth - 40 }, roundTrip, "the settings page fits the narrow panel")
        capture(card, "settings-narrow-dark")
        Commons.Color.background = "#eff1f5"; Commons.Color.foreground = "#4c4f69"; Commons.Color.accent = "#1e66f5"
        wait(200); capture(card, "settings-narrow-light")
        panel.settings = Qt.binding(function() { return root.config.bar.layout.right[0] })
        // Escape on Back returns the keys to the list.
        var back = pane.backTarget
        focusOn(back); keyClick(Qt.Key_Escape)
        tryCompare(panel, "editingSettings", false, roundTrip)
        tryVerify(function() { return panel.view.activeFocus }, roundTrip)
        } catch (error) { console.log("SETTINGS_FAILURE save", error.message, error.stack); throw error }
      }
      function test_04_invalid_and_failed_saves() {
        try {
        panel.openSettings()
        tryCompare(panel, "popupSettingsLoading", false, roundTrip)
        panel.savePreference("popups", "normalTimeoutSec", 0)
        verify(panel.settingsError !== "")
        compare(panel.preferenceActive, null)
        root.failSave = true
        panel.savePreference("center", "compact", false)
        tryVerify(function() { return panel.preferenceActive === null }, roundTrip)
        verify(panel.settingsError !== "")
        compare(panel.compact, true)
        var grouping = control("center-browserGrouping")
        grouping.open(); tryCompare(grouping, "popupOpen", true, roundTrip); keyClick(Qt.Key_Down); keyClick(Qt.Key_Return)
        tryCompare(grouping, "popupOpen", false, roundTrip)
        tryVerify(function() { return panel.settingsError !== "" && panel.preferenceActive === null && !panel.popupSettingsLoading }, roundTrip)
        compare(grouping.value, "hostname")
        capture(control("notificationSettingsPane").parent.parent.parent.parent, "settings-save-error")
        root.failSave = false
        tryVerify(function() { return !panel.popupSettingsLoading && panel.preferenceActive === null }, roundTrip)
        grouping.open(); tryCompare(grouping, "popupOpen", true, roundTrip); keyClick(Qt.Key_Down); keyClick(Qt.Key_Return)
        tryCompare(grouping, "popupOpen", false, roundTrip)
        tryCompare(panel, "browserGrouping", "none", roundTrip)
        tryCompare(grouping, "value", "none", roundTrip)
        grouping.open(); tryCompare(grouping, "popupOpen", true, roundTrip); keyClick(Qt.Key_Up); keyClick(Qt.Key_Return)
        tryCompare(grouping, "popupOpen", false, roundTrip)
        tryCompare(panel, "browserGrouping", "hostname", roundTrip)
        panel.savePreference("center", "compact", false)
        tryVerify(function() { return panel.preferenceActive === null }, roundTrip)
        compare(panel.settingsError, "")
        tryCompare(panel, "compact", false, roundTrip)
        // A typed popup number saves through Foamy Notifications' endpoint.
        var row = control("popups-normalTimeoutSec"), duration = row.field
        tryVerify(function() { return !panel.popupSettingsLoading && row.enabled }, roundTrip)
        duration.focusInput(); tryCompare(duration, "inputActiveFocus", true, roundTrip); keyClick(Qt.Key_A, Qt.ControlModifier)
        keyClick(Qt.Key_1); keyClick(Qt.Key_2); keyClick(Qt.Key_Return)
        tryVerify(function() { return panel.popupSettings.normalTimeoutSec === 12 && root.config.plugins[0].normalTimeoutSec === 12 }, roundTrip)
        tryVerify(function() { return !panel.popupSettingsLoading && row.enabled }, roundTrip)
        // The field shows the value read back after a save from elsewhere.
        panel.savePreference("popups", "normalTimeoutSec", 15)
        tryVerify(function() { return duration.text === "15" }, roundTrip)
        } catch (error) { console.log("SETTINGS_FAILURE errors", error.message, error.stack); throw error }
      }
      function test_05_disabled_service_and_scroll_focus() {
        try {
        settle()
        panel.openSettings()
        tryCompare(panel, "popupSettingsLoading", false, roundTrip)
        verify(panel.popupSettingsAvailable, panel.settingsError)
        // Disabling Foamy Notifications in shell.json reaches the open page:
        // the panel watches $HOME/.config/omarchy/shell.json, where the host
        // reads it, not $XDG_CONFIG_HOME.
        var next = JSON.parse(configFile.text())
        next.disabledPlugins = ["foamy.notifications"]
        writeFile(configFile, JSON.stringify(next))
        tryVerify(function() { return !panel.popupSettingsLoading && !panel.popupSettingsAvailable }, roundTrip, "the open settings page follows shell.json")
        var pane = control("notificationSettingsPane"), scroll = pane.flickable
        compare(findChild(pane, "popups-compact"), null)
        compare(control("popups-availability").text, "Plugin not enabled")
        wait(200)
        capture(pane.parent.parent.parent.parent, "settings-disabled")
        // A focused field below the fold scrolls into view.
        pane.height = 320
        control("center-maxItems").forceActiveFocus()
        tryVerify(function() { return scroll.contentY > 0 }, roundTrip)
        verify(control("center-maxItems").enabled)
        wait(200)
        capture(pane.parent.parent.parent.parent, "settings-disabled-scroll")
        } catch (error) { console.log("SETTINGS_FAILURE disabled/scroll", error.message, error.stack); throw error }
      }
      function test_06_uninstalled_service() {
        try {
        settle()
        var next = JSON.parse(configFile.text())
        delete next.disabledPlugins
        writeFile(configFile, JSON.stringify(next))
        registry.installedPlugins = ({})
        panel.openSettings()
        tryCompare(panel, "popupSettingsLoading", false, roundTrip)
        verify(panel.popupSettingsAvailable, "A stale configuration entry is retained in this fixture")
        verify(!panel.popupPluginInstalled)
        var pane = control("notificationSettingsPane")
        pane.height = pane.implicitHeight
        compare(findChild(pane, "popups-compact"), null)
        compare(control("popups-availability").text, "Plugin not installed")
        verify(control("center-maxItems").enabled)
        wait(200); capture(pane.parent.parent.parent.parent, "settings-uninstalled")
        settle()
        delete next.plugins
        writeFile(configFile, JSON.stringify(next))
        panel.openSettings()
        tryCompare(panel, "popupSettingsLoading", false, roundTrip)
        verify(!panel.popupSettingsAvailable)
        compare(panel.settingsError, "")
        compare(control("popups-availability").text, "Plugin not installed")
        } catch (error) { console.log("SETTINGS_FAILURE uninstalled", error.message, error.stack); throw error }
      }
      function test_07_clipboard_parent_keys_and_feedback() {
        try {
        panel.startSearch()
        var search = control("notificationSearch")
        tryCompare(search, "inputActiveFocus", true, roundTrip)
        keyClick(Qt.Key_A)
        compare(panel.filter, "a")
        keyClick(Qt.Key_Down)
        tryCompare(search, "inputActiveFocus", false, roundTrip)
        search.focusInput()
        tryCompare(search, "inputActiveFocus", true, roundTrip)
        keyClick(Qt.Key_Return)
        tryCompare(search, "inputActiveFocus", false, roundTrip)
        search.focusInput()
        tryCompare(search, "inputActiveFocus", true, roundTrip)
        search.pasteError = "Clipboard text is too large or contains invalid characters."
        wait(100)
        capture(search.parent.parent.parent, "search-paste-error")
        // The error line speaks the desktop's language.
        speaks("Clipboard text is too large or contains invalid characters.", "Teksten på utklippstavlen er for stor eller inneholder ugyldige tegn.")
        keyClick(Qt.Key_Escape)
        compare(panel.searching, false)
        compare(search.pasteError, "")
        compare(panel.filter, "")
        panel.openSettings()
        tryCompare(panel, "popupSettingsLoading", false, roundTrip)
        // A refused paste shows on the number row's own error line, and typing clears it.
        var row = control("center-maxItems"), field = row.field
        field.pasteError = "Could not paste clipboard text. Copy plain text and try again."
        tryVerify(function() { return row.implicitHeight > row.field.height + 4 }, roundTrip)
        field.focusInput()
        tryCompare(field, "inputActiveFocus", true, roundTrip)
        keyClick(Qt.Key_A, Qt.ControlModifier)
        keyClick(Qt.Key_7)
        compare(field.pasteError, "")
        keyClick(Qt.Key_Escape)
        compare(field.text, String(panel.settings.maxItems || 1000))
        } catch (error) { console.log("SETTINGS_FAILURE clipboard", error.message, error.stack); throw error }
      }
      function test_08_archived_screenshot_action_and_retry() {
        try {
        panel.editingSettings = false
        panel.searching = false
        panel.filter = ""
        tryVerify(function() { return store.entries.length === 1 }, roundTrip)
        var row = store.entries[0]
        compare(row.fileAction, "edit-screenshot")
        wait(200)
        capture(control("notificationSearch").parent.parent.parent, "screenshot-history")
        // The editor fails: the entry and the panel stay, and the panel says why.
        panel.activate(row)
        tryVerify(function() { return store.focusError.indexOf("Could not open the image") === 0 }, roundTrip)
        tryVerify(function() { var line = findChild(panel.view, "notificationError"); return line !== null && line.visible && line.text.indexOf("Could not open the image") === 0 }, roundTrip, "the panel shows the error")
        speaks("Could not open the image. Check that the file and its app are available, then try again.", "Kunne ikke åpne bildet. Sjekk at filen og appen den åpnes i er tilgjengelige, og prøv igjen.")
        compare(store.entries.length, 1)
        compare(panel.opened, true)
        capture(control("notificationSearch").parent.parent.parent, "screenshot-open-error")
        writeFile(editorReady, "ready")
        panel.activate(row)
        tryCompare(panel, "opened", false, roundTrip)
        compare(store.entries.length, 0)
        } catch (error) { console.log("SETTINGS_FAILURE screenshot", error.message, error.stack); throw error }
      }
      // A shown NotificationRow whose entry is still listed (a removed card
      // can stay a moment for its exit animation).
      function listedCard(item) {
        if (!item || !item.visible)
          return null
        if (item.entry !== undefined && item.removeRequested !== undefined && item.entry
            && store.entries.some(function(entry) { return entry.key === item.entry.key }))
          return item
        for (var i = 0; i < item.children.length; i++) {
          var found = listedCard(item.children[i])
          if (found)
            return found
        }
        return null
      }
      // No removed row is still closing its space, so the rows below stay
      // where a click is aimed.
      function listSettled() {
        var rows = panel.list.contentItem.children
        for (var i = 0; i < rows.length; i++)
          if (rows[i].retired === true)
            return false
        return true
      }
      // Reads the archive with a new helper process until `done(keys)` holds:
      // the Service's removal or clear may still be running.
      function storedUntil(done, what) {
        tryVerify(function() {
          if (reader.running)
            return false
          if (Array.isArray(root.stored) && done(root.stored))
            return true
          root.stored = null
          reader.running = true
          return false
        }, roundTrip, what)
      }
      function test_09_dismiss_and_clear_all() {
        try {
        // Seeding can bring back the fixture row too (it resets the
        // tombstones), so only the change of each step is checked.
        seeder.running = true
        tryVerify(function() { return !seeder.running && store.entries.length >= 4 }, roundTrip, "seeded rows are listed")
        var gone = function(key) { return !store.entries.some(function(entry) { return entry.key === key }) }
        // Delete on the cursor's card removes that card.
        var before = store.entries.length
        focusOn(panel.view)
        for (var i = 0; i < 6 && !(panel.cursorIndex >= 0 && panel.rows[panel.cursorIndex].kind === "message"); i++) keyClick(Qt.Key_Down)
        verify(panel.cursorIndex >= 0 && panel.rows[panel.cursorIndex].kind === "message", "the cursor reaches a card")
        var key = panel.rows[panel.cursorIndex].entry.key
        keyClick(Qt.Key_Delete)
        tryVerify(function() { return store.entries.length === before - 1 && gone(key) }, roundTrip, "Delete removes the cursor's card")
        // A right click on a card removes it from the archive, for good.
        var card = null
        tryVerify(function() { card = listSettled() ? listedCard(panel.list) : null; return card !== null }, roundTrip, "a card is shown")
        key = card.entry.key; before = store.entries.length
        mouseClick(card, 20, card.height / 2, Qt.RightButton)
        tryVerify(function() { return store.entries.length === before - 1 && gone(key) }, roundTrip, "a right click removes the card")
        storedUntil(function(keys) { return keys.indexOf(key) < 0 }, "the removed card is gone from the archive")
        compare(store.removalError, "", "the removal reports no error")
        store.load()
        tryVerify(function() { return !store.listing && store.entries.length === before - 1 && gone(key) }, roundTrip, "the removal is durable")
        // Clear all empties the archive, not only the list, and then has
        // nothing to do.
        verify(store.entries.length > 0, "rows are left to clear")
        mouseClick(control("clearAllNotifications"))
        tryVerify(function() { return store.entries.length === 0 && panel.rows.length === 0 }, roundTrip, "Clear all empties the list")
        storedUntil(function(keys) { return keys.length === 0 }, "Clear all empties the archive")
        store.load()
        tryVerify(function() { return !store.listing && store.entries.length === 0 && store.removalError === "" }, roundTrip, "the list stays empty after a reload")
        tryVerify(function() { return !control("clearAllNotifications").actionEnabled }, roundTrip, "Clear all is off for an empty list")
        } catch (error) { console.log("SETTINGS_FAILURE dismiss", error.message, error.stack); throw error }
      }
      onCompletedChanged: if (completed) {
        console.log("SETTINGS_UI", qtest_results.passCount, "passed", qtest_results.failCount, "failed")
        console.log("FOAMY DONE")
        Qt.quit()
      }
    }
  }
}
"""

# Test double of the host's `omarchy bar set ID KEY VALUE [--json]` (omarchy-bar
# cmd_set, same contract): the value as JSON, then the shell's setBarWidget
# through omarchy-shell, which must answer "ok". Anything else fails loudly.
OMARCHY = r"""#!/bin/bash
printf '%s\n' "omarchy $*" >> "$FOAMY_OUT/omarchy-double.log"
[[ ${1:-} == bar && ${2:-} == set && $# -ge 5 ]] || { echo "omarchy test double: unsupported: $*" >&2; exit 127; }
id=$3 key=$4 value=$5
shift 5
if [[ ${1:-} == --json ]]; then
  json=$(jq -cn --argjson value "$value" '$value') || { echo "omarchy-bar: invalid JSON value: $value" >&2; exit 1; }
  shift
else
  json=$(jq -cn --arg value "$value" '$value')
fi
(( $# == 0 )) || { echo "omarchy test double: placement is not modelled: $*" >&2; exit 127; }
result=$(omarchy-shell shell setBarWidget "$id" "$key" "$json" "{}") || exit 1
[[ $result == ok ]] || { echo "omarchy-bar: $result" >&2; exit 1; }
echo "Set $key on $id"
"""
FAKEBIN = {
    "omarchy": OMARCHY,
    # Reaches only this run's shell (the harness root is next to FOAMY_OUT).
    "omarchy-shell": '#!/bin/sh\n[ "$1" = -q ] && shift\nexec qs ipc -n -p "${FOAMY_OUT%/out}/shell" call "$@"\n',
    # The editor 4.5 names and the opener prefers.
    "omasnap": '#!/bin/bash\ngrep -q ready "$HOME/editor-ready" || exit 3\nprintf "%s" "$1" > "$HOME/editor-opened"\nsleep 1\n',
}


def write_fixtures(home):
    config = home / ".config/omarchy/shell.json"
    config.parent.mkdir(parents=True)
    config.write_text(
        json.dumps(
            {
                "version": 1,
                "other": "preserved",
                "bar": {"layout": {"right": [{"id": "foamy.notification-center", "browserGrouping": "hostname"}]}},
                "plugins": [{"id": "foamy.notifications", "browserGrouping": "hostname", "useBrowserFavicons": True}],
            }
        )
    )
    image = home / "screenshot with spaces.png"
    image.write_bytes(png())
    (home / "editor-ready").write_text("")
    history = home / ".local/state/omarchy/notifications/history"
    history.mkdir(parents=True)
    stamp = int(time.time() * 1000)
    (history / f"{stamp}-1.json").write_text(
        json.dumps(
            {
                "timestamp": stamp,
                "app": "omarchy-action",
                "summary": "Screenshot saved to clipboard and file",
                "body": "Edit with Super + Alt + , (or click this)",
                "image": str(image),
                "execArgv": json.dumps(["omasnap", str(image)]),
            }
        )
    )


status = 0
for host in harness.available_hosts(what="settings-ui"):
    run = harness.Run(host, SHELL, plugin=PLUGIN, prefix=f"foamy-center-settings-{host}-", fakebin=FAKEBIN)
    write_fixtures(run.base / "home")
    # The host reads $HOME/.config/omarchy/shell.json whatever XDG_CONFIG_HOME
    # says; the disabled and uninstalled cases fail if the panel follows it.
    run.env["XDG_CONFIG_HOME"] = str(run.base / "xdg-config")
    # A hang guard, not a speed limit: each step has its own bound.
    run.run(timeout=240)
    double = run.out / "omarchy-double.log"
    double = double.read_text().splitlines() if double.exists() else []
    # The center's saves went through the omarchy double (the CLI save path)
    # and never touched another plugin's entry.
    saves = [line for line in double if line.startswith("omarchy bar set foamy.notification-center ")]
    warnings = [
        line for line in run.log.splitlines() if "WARN" in line and "/plugin/" in line and "/plugin/kit/" not in line
    ]
    passed = f"SETTINGS_UI {CASES + 1} passed 0 failed" in run.log
    if run.ok and passed and not warnings and not run.host_commands() and len(saves) >= 3 and saves == double:
        print(f"{host}: settings-ui passed ({len(saves)} center saves)")
        run.cleanup()
    else:
        status = 1
        print(run.log)
        print("\n".join(warnings))
        print("host commands ran:", *run.host_commands(), sep="\n  ")
        print("omarchy calls:", *double, sep="\n  ")
        print(f"{host}: settings-ui FAILED; log and captures at {run.base}")
sys.exit(status)
