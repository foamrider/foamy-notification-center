"""Exercise the real panel and settings helper against disposable configuration."""
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

from favicon_test import png

source = Path(__file__).resolve().parents[1]
base = Path(tempfile.mkdtemp(prefix="foamy-center-settings-"))
app = base / "app"
app.mkdir()
for name in ["Commons", "Ui"]:
    (app / name).symlink_to(os.environ.get("OMARCHY_TEST_ROOT", "/usr/share/omarchy") + "/shell/" + name, target_is_directory=True)
(app / "plugin").symlink_to(source, target_is_directory=True)
home = base / "home"
config = home / ".config/omarchy/shell.json"
config.parent.mkdir(parents=True)
original = {"version": 1, "other": "preserved", "bar": {"layout": {"right": [{"id": "foamy.notification-center", "language": "nb", "browserGrouping": "hostname"}]}}, "plugins": [{"id": "foamy.notifications", "browserGrouping": "hostname", "useBrowserFavicons": True}]}
config.write_text(json.dumps(original))
cli = base / "bin"
cli.mkdir()
(cli / "python3").symlink_to("/usr/bin/python3")
(cli / "omarchy-shell").write_text("#!/bin/sh\nexec qs ipc -n -p " + str(app) + " call \"$@\"\n")
(cli / "omarchy-shell").chmod(0o755)
image = home / "screenshot with spaces.png"
image.write_bytes(png())
(home / "editor-ready").write_text("")
(cli / "tensaku-edit").write_text('#!/bin/bash\ngrep -q ready "$HOME/editor-ready" || exit 3\nprintf "%s" "$1" > "$HOME/editor-opened"\nsleep 1\n')
(cli / "tensaku-edit").chmod(0o755)
history = home / ".local/state/omarchy/notifications/history"
history.mkdir(parents=True)
stamp = int(time.time() * 1000)
(history / f"{stamp}-1.json").write_text(json.dumps({"timestamp":stamp,"app":"omarchy-action","summary":"Screenshot saved to clipboard and file","body":"Edit with Super + Alt + , (or click this)","image":str(image),"execArgv":json.dumps(["tensaku-edit",str(image)])}))
(app / "shell.qml").write_text('''pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import "plugin" as Plugin
ShellRoot {
  id: root
  QtObject {
    id: translator
    property string language: "en"
    property string formatLocale: "en-US"
    property bool rightToLeft: false
    function t(key, fallback) { return fallback }
    function number(value) { return String(value) }
  }
  property var config: ({})
  property bool failSave: false
  property bool finished: false
  property bool dnd: false
  property int snoozedMinutes: 0
  QtObject {
    id: registry
    property var installedPlugins: ({"foamy.notifications":{id:"foamy.notifications"}})
  }
  Component.onCompleted: {
    Commons.Color.background = "#24273a"; Commons.Color.foreground = "#cad3f5"; Commons.Color.accent = "#8aadf4"
  }
  IpcHandler {
    target: "notifications"
    function snoozes(): string { return "{}" }
    function unsnooze(key: string): string { root.snoozedMinutes=0; return "ok" }
    function snoozeAll(minutes: string): string { root.snoozedMinutes=Number(minutes); return "ok" }
    function dndState(): string { return root.dnd ? "on" : "off" }
    function toggleDnd(): string { root.dnd = !root.dnd; return root.dnd ? "on" : "off" }
  }
  FileView {
    id: configFile
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true
    onFileChanged: reload()
    onLoaded: root.config = JSON.parse(text())
  }
  // Model the host's widget endpoint; service edits use the real Python helper.
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
  FileView { id: editorReady; path: Quickshell.env("HOME") + "/editor-ready" }
  PanelWindow {
    id: window
    visible: true
    screen: Quickshell.screens[0]
    implicitHeight: 32
    anchors { top: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "foamy-settings-test-bar"
    color: Commons.Color.background
    Item {
      id: bar
      width: parent.width
      height: 32
      property string position: "top"
      property var pluginRegistry: registry
      property int barSize: 32
      property string fontFamily: "sans-serif"
      property color barForeground: Commons.Color.foreground
      property color urgent: Commons.Color.urgent
      property bool vertical: false
      property bool hideLabels: false
      property bool foregroundAnimationEnabled: false
      property var activePopout: false
      function requestPopout(key) { activePopout = key }
      function releasePopout(key) { if (activePopout === key) activePopout = false }
      Plugin.Panel {
        id: panel
        bar: bar
        settings: root.config.bar ? root.config.bar.layout.right[0] : ({})
      }
    }
    property bool ready: false
    Timer { interval: 500; running: true; onTriggered: window.ready = true }
    TestCase {
      name: "NotificationSettings"
      when: window.ready
      function control(name) {
        var item = findChild(panel, name)
        var pane = findChild(panel, "notificationSettingsPane")
        if (item === null && pane) item = findChild(pane, name)
        if (item === null) console.log("MISSING_CONTROL", name)
        verify(item !== null, "Missing " + name)
        return item
      }
      function capture(item, name) {
        var done = false
        item.grabToImage(function(result) { verify(result.saveToFile(Qt.resolvedUrl(name + ".png").toString().replace("file://", ""))); done = true })
        tryVerify(function() { return done })
      }
      function init() { panel.open(); tryCompare(panel, "opened", true); wait(200) }
      function cleanup() { panel.close(); wait(200) }
      function test_00_direction() {
        Plugin.FoamyI18n.backend = translator;
        for (var direction = 0; direction < 2; direction++) {
          translator.rightToLeft = !!direction;
          translator.language = direction ? "ar" : "en";
          panel.openSettings(); wait(150);
          var pane = control("notificationSettingsPane");
          compare(pane.LayoutMirroring.enabled, !!direction);
          verify(direction ? control("settingsBack").x > pane.width / 2 : control("settingsBack").x < pane.width / 2);
          capture(pane, direction ? "rtl-settings" : "ltr-settings");
          panel.closeSettings(); wait(100);
          panel.moveCursor(direction ? -1 : 1, 0); compare(panel.cursorDismiss, true);
          panel.moveCursor(direction ? 1 : -1, 0); compare(panel.cursorDismiss, false);
          panel.startSearch(); wait(200);
          var search = control("notificationSearch");
          verify(search.width > 100, "Search must have usable width in both directions");
          search.text = "screenshot"; compare(panel.filter, "screenshot");
          capture(search.parent.parent, direction ? "rtl-search" : "ltr-search");
          panel.endSearch(); wait(200);
        }
        Plugin.FoamyI18n.backend = null;
      }
      function test_00_snooze_menu() {
        // The header's kit ⋯ menu: Snooze is a submenu (opens in place, Back row first).
        var header = panel.header, menu = header.menu
        mouseClick(control("foamyMenuButton"))
        tryCompare(header, "menuOpen", true)
        var snooze = header.menuItems[1]
        compare(snooze.objectName, "notificationSnooze")
        compare(snooze.iconName, "alarm-clock")
        tryCompare(snooze, "visible", true)
        tryCompare(snooze, "enabled", true)
        menu.activate(menu.entries.indexOf(snooze))
        tryCompare(menu, "inSubmenu", true)
        compare(menu.entries.length, 5)
        for (var i = 0; i < menu.entries.length; i++) verify(menu.entries[i].iconName !== "", "icon for " + menu.entries[i].text)
        wait(150); capture(menu.panel, "snooze-menu")
        menu.activate(menu.entries.indexOf(snooze.items[0])); tryCompare(root,"snoozedMinutes",30)
        compare(header.menuOpen, false)
        header.openMenu(true)
        menu.activate(menu.entries.indexOf(snooze))
        menu.activate(menu.entries.indexOf(snooze.items[3])); tryCompare(root,"snoozedMinutes",0)
        header.closeMenu()
      }
      function test_01_menu_and_settings_save() {
        try {
        // Search and clear all stay in the row, then ⋯; Silence, Snooze, a
        // separator and Settings (last) are in its menu, each with an icon.
        var header = panel.header, menu = header.menu, more = control("foamyMenuButton")
        mouseClick(more)
        tryCompare(header, "menuOpen", true)
        verify(header.overflowing && header.settingsInMenu)
        verify(control("notificationSearchButton").visible)
        verify(control("clearAllNotifications").visible)
        compare(header.shownTrailing.length, 2)
        var entries = menu.entries
        compare(entries.length, 4)
        compare(entries[0].objectName, "notificationMute")
        verify(entries[2].separator)
        compare(entries[3].objectName, "foamyMenuSettings")
        for (var i = 0; i < entries.length; i++) if (!entries[i].separator) verify(entries[i].iconName !== "", "icon for " + entries[i].text)
        // Dropped from the ⋯ button: its trailing edge on the button's, just below it.
        var box = menu.panel, end = more.mapToItem(null, more.width, more.height), edge = box.mapToItem(null, box.width, 0)
        verify(Math.abs(end.x - edge.x) <= 1, "menu trailing edge " + edge.x + " vs button " + end.x)
        verify(edge.y >= end.y - 1, "menu below the button")
        wait(150); capture(box, "overflow-menu")
        menu.activate(0)
        tryCompare(root, "dnd", true)
        tryCompare(panel, "dnd", true)
        compare(header.menuItems[0].iconName, "bell-ring")
        // Keyboard: the ⋯ button is the cursor stop above the first row.
        panel.view.forceActiveFocus(); keyClick(Qt.Key_Up)
        verify(panel.cursorOnSettings && header.menuHasCursor)
        keyClick(Qt.Key_Return)
        tryCompare(header, "menuOpen", true)
        compare(menu.currentIndex, 0)
        keyClick(Qt.Key_End); keyClick(Qt.Key_Return)
        tryCompare(panel, "editingSettings", true)
        tryCompare(panel, "popupSettingsLoading", false)
        verify(panel.popupSettingsAvailable, panel.settingsError)
        var pane = control("notificationSettingsPane")
        wait(250)
        verify(pane.height > 500, "The full settings view must fit on this fixture screen")
        waitForRendering(pane)
        var card = pane.parent.parent.parent.parent
        capture(card, "settings-wide-dark")
        var silenceCritical = control("popups-dndSilenceCritical")
        compare(silenceCritical.checked, false)
        silenceCritical.forceActiveFocus(); keyClick(Qt.Key_Space)
        tryVerify(function() { return panel.preferenceActive === null && panel.popupSettings.dndSilenceCritical === true })
        compare(root.config.plugins[0].dndSilenceCritical, true)
        compare(root.config.bar.layout.right[0].dndSilenceCritical, undefined)
        var compact = control("popups-compact")
        compact.clicked()
        tryVerify(function() { return panel.preferenceActive === null && panel.popupSettings.compact === false })
        compare(panel.popupSettings.compact, false)
        tryVerify(function() { return root.config.plugins[0].compact === false })
        compare(root.config.bar.layout.right[0].compact, undefined)
        var removeWithX = control("popups-closeButtonRemovesHistory")
        compare(removeWithX.checked, false)
        removeWithX.forceActiveFocus(); keyClick(Qt.Key_Space)
        tryVerify(function() { return panel.preferenceActive === null && panel.popupSettings.closeButtonRemovesHistory === true })
        compare(root.config.plugins[0].closeButtonRemovesHistory, true)
        compare(root.config.bar.layout.right[0].closeButtonRemovesHistory, undefined)
        panel.savePreference("center", "compact", true)
        tryVerify(function() { return root.config.bar.layout.right[0].compact === true })
        tryVerify(function() { return panel.preferenceActive === null })
        compare(panel.compact, true)
        compare(root.config.plugins[0].compact, false)
        panel.savePreference("popups", "normalTimeoutSec", 15)
        tryVerify(function() { return panel.popupSettings.normalTimeoutSec === 15 })
        compare(root.config.other, "preserved")
        panel.settings = Object.assign({}, panel.settings, {panelWidth:320})
        wait(200); compare(pane.width, panel.panelWidth - 2)
        capture(card, "settings-narrow-dark")
        Commons.Color.background = "#eff1f5"; Commons.Color.foreground = "#4c4f69"; Commons.Color.accent = "#1e66f5"
        wait(200); capture(card, "settings-narrow-light")
        panel.settings = Qt.binding(function() { return root.config.bar.layout.right[0] })
        var back = control("settingsBack")
        back.forceActiveFocus(); keyClick(Qt.Key_Escape)
        tryCompare(panel, "editingSettings", false)
        tryVerify(function() { return panel.view.activeFocus })
        } catch (error) { console.log("SETTINGS_FAILURE menu/save", error.message, error.stack); throw error }
      }
      function test_02_invalid_and_failed_saves() {
        try {
        panel.openSettings()
        tryCompare(panel, "popupSettingsLoading", false)
        panel.savePreference("popups", "normalTimeoutSec", 0)
        verify(panel.settingsError !== "")
        compare(panel.preferenceActive, null)
        root.failSave = true
        panel.savePreference("center", "compact", false)
        tryVerify(function() { return panel.preferenceActive === null })
        verify(panel.settingsError !== "")
        compare(panel.compact, true)
        var grouping = control("center-browserGrouping")
        grouping.open(); tryCompare(grouping, "popupOpen", true); keyClick(Qt.Key_Down); keyClick(Qt.Key_Return)
        tryCompare(grouping, "popupOpen", false)
        tryVerify(function() { return panel.settingsError !== "" && panel.preferenceActive === null && !panel.popupSettingsLoading })
        compare(grouping.value, "hostname")
        capture(control("notificationSettingsPane").parent.parent.parent.parent, "settings-save-error")
        root.failSave = false
        tryVerify(function() { return !panel.popupSettingsLoading && panel.preferenceActive === null })
        grouping.open(); tryCompare(grouping, "popupOpen", true); keyClick(Qt.Key_Down); keyClick(Qt.Key_Return)
        tryCompare(grouping, "popupOpen", false)
        tryCompare(panel, "browserGrouping", "none")
        tryCompare(grouping, "value", "none")
        grouping.open(); tryCompare(grouping, "popupOpen", true); keyClick(Qt.Key_Up); keyClick(Qt.Key_Return)
        tryCompare(grouping, "popupOpen", false)
        tryCompare(panel, "browserGrouping", "hostname")
        panel.savePreference("center", "compact", false)
        tryVerify(function() { return panel.preferenceActive === null })
        compare(panel.settingsError, "")
        tryCompare(panel, "compact", false)
        var duration = control("popups-normalTimeoutSec")
        tryVerify(function() { return !panel.popupSettingsLoading && duration.enabled })
        duration.forceActiveFocus(); keyClick(Qt.Key_A, Qt.ControlModifier)
        keyClick(Qt.Key_1); keyClick(Qt.Key_2); keyClick(Qt.Key_Return)
        tryVerify(function() { return panel.popupSettings.normalTimeoutSec === 12 })
        tryVerify(function() { return !panel.popupSettingsLoading && duration.enabled })
        duration.forceActiveFocus(); keyClick(Qt.Key_A, Qt.ControlModifier); keyClick(Qt.Key_9)
        keyClick(Qt.Key_Escape)
        compare(duration.text, "12")
        panel.savePreference("popups", "normalTimeoutSec", 15)
        tryVerify(function() { return duration.text === "15" })
        } catch (error) { console.log("SETTINGS_FAILURE errors", error.message, error.stack); throw error }
      }
      function test_03_disabled_service_and_scroll_focus() {
        try {
        var next = JSON.parse(configFile.text())
        next.disabledPlugins = ["foamy.notifications"]
        configFile.setText(JSON.stringify(next))
        wait(150)
        panel.openSettings()
        tryCompare(panel, "popupSettingsLoading", false)
        verify(!panel.popupSettingsAvailable)
        var pane = control("notificationSettingsPane"), scroll = control("settingsScroll")
        compare(findChild(pane, "popups-compact"), null)
        compare(control("popups-availability").text, "Plugin not enabled")
        wait(200)
        capture(pane.parent.parent.parent.parent, "settings-disabled")
        pane.height = 320
        control("center-maxItems").forceActiveFocus()
        tryVerify(function() { return scroll.contentY > 0 })
        verify(control("center-maxItems").enabled)
        wait(200)
        capture(pane.parent.parent.parent.parent, "settings-disabled-scroll")
        } catch (error) { console.log("SETTINGS_FAILURE disabled/scroll", error.message, error.stack); throw error }
      }
      function test_04_uninstalled_service() {
        var next = JSON.parse(configFile.text())
        delete next.disabledPlugins
        configFile.setText(JSON.stringify(next))
        registry.installedPlugins = ({})
        panel.openSettings()
        tryCompare(panel, "popupSettingsLoading", false)
        verify(panel.popupSettingsAvailable, "A stale configuration entry is retained in this fixture")
        verify(!panel.popupPluginInstalled)
        var pane = control("notificationSettingsPane")
        pane.height = pane.implicitHeight
        compare(findChild(pane, "popups-compact"), null)
        compare(control("popups-availability").text, "Plugin not installed")
        verify(control("center-maxItems").enabled)
        wait(200); capture(pane.parent.parent.parent.parent, "settings-uninstalled")
        delete next.plugins
        configFile.setText(JSON.stringify(next))
        panel.openSettings()
        tryCompare(panel, "popupSettingsLoading", false)
        verify(!panel.popupSettingsAvailable)
        compare(panel.settingsError, "")
        compare(control("popups-availability").text, "Plugin not installed")
      }
      function test_06_clipboard_parent_keys_and_feedback() {
        panel.startSearch()
        var search = control("notificationSearch")
        tryCompare(search, "inputActiveFocus", true)
        keyClick(Qt.Key_A)
        compare(panel.filter, "a")
        keyClick(Qt.Key_Down)
        tryCompare(search, "inputActiveFocus", false)
        search.focusInput()
        keyClick(Qt.Key_Return)
        tryCompare(search, "inputActiveFocus", false)
        search.focusInput()
        search.pasteError = "Clipboard text is too large or contains invalid characters."
        wait(100)
        capture(search.parent.parent.parent, "search-paste-error")
        keyClick(Qt.Key_Escape)
        compare(panel.searching, false)
        compare(search.pasteError, "")
        compare(panel.filter, "")
        panel.openSettings()
        tryCompare(panel, "popupSettingsLoading", false)
        var field = control("center-maxItems")
        field.pasteError = "Could not paste clipboard text. Copy plain text and try again."
        compare(panel.settingsError, field.pasteError)
        field.focusInput()
        keyClick(Qt.Key_A, Qt.ControlModifier)
        keyClick(Qt.Key_7)
        compare(panel.settingsError, "")
        keyClick(Qt.Key_Escape)
        compare(field.text, String(panel.settings.maxItems || 1000))
      }
      function test_07_archived_screenshot_action_and_retry() {
        try {
        panel.editingSettings = false
        panel.searching = false
        panel.filter = ""
        tryVerify(function() { return store.entries.length === 1 })
        var row = store.entries[0]
        compare(row.fileAction, "edit-screenshot")
        wait(200)
        capture(control("notificationSearch").parent.parent.parent, "screenshot-history")
        panel.activate(row)
        tryVerify(function() { return store.focusError.indexOf("Could not open the image") === 0 })
        compare(store.entries.length, 1)
        compare(panel.opened, true)
        capture(control("notificationSearch").parent.parent.parent, "screenshot-open-error")
        editorReady.setText("ready")
        wait(100)
        panel.activate(row)
        tryCompare(panel, "opened", false)
        compare(store.entries.length, 0)
        } catch (error) { console.log("SETTINGS_FAILURE screenshot", error.message, error.stack); throw error }
      }
      onCompletedChanged: if (completed) { console.log("SETTINGS_UI", qtest_results.passCount, "passed", qtest_results.failCount, "failed"); root.finished = true }
    }
  }
}
''')
# Avoid starting desktop portal daemons on the disposable test bus.
env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home / ".config"), XDG_CACHE_HOME=str(home / ".cache"), XDG_STATE_HOME=str(home / ".local/state"), PATH=str(cli) + ":" + os.environ["PATH"], QT_QPA_PLATFORM="wayland", QT_QUICK_BACKEND="rhi", QT_QPA_PLATFORMTHEME="basic", QT_NO_XDG_DESKTOP_PORTAL="1", OMARCHY_PATH="/usr/share/omarchy")
process = subprocess.Popen(["dbus-run-session", "--", "qs", "-p", str(app), "--no-color"], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
try:
    output = process.communicate(timeout=30)[0]
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGTERM)
    output = process.communicate(timeout=3)[0]
print(output)
print("Settings captures:", app)
assert process.returncode == 0 and "SETTINGS_UI 9 passed 0 failed" in output
