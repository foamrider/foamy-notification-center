"""Numeric settings use kit FoamyNumberField: an external change shows while Settings is open,
and Escape restores the saved value without saving or leaving the page. A choice whose save failed
shows the stored value again. Offscreen; the host shell is
hostenv.root() (the installed 4.5 unless OMARCHY_TEST_ROOT / FOAMY_HOST_45 pick another)."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile

KIT = Path(os.environ.get("FOAMY_KIT", Path.home() / "GitHub/Personal/foamy-kit"))
sys.path.insert(0, str(KIT / "preview"))
import hostenv  # noqa: E402  (foamy-kit's preview/hostenv.py)

source = Path(__file__).resolve().parents[1]
host = str(hostenv.root())
base = Path(tempfile.mkdtemp(prefix="foamy-center-number-"))
app = base / "app"
app.mkdir()
for name in ["Commons", "Ui"]:
    (app / name).symlink_to(host + "/shell/" + name)
(app / "plugin").symlink_to(source)
(base / "runtime").mkdir(mode=0o700)
(app / "shell.qml").write_text("""import QtQuick
import QtTest
import Quickshell
import "plugin" as Plugin
ShellRoot {
 FloatingWindow {
  visible: true; implicitWidth: 460; implicitHeight: 700
  Plugin.SettingsPane {
   id: pane; width: 420
   property var saved: []
   settings: ({ keepDays: 30, maxItems: 1000 })
   popupSettings: ({})
   onSave: function(scope, key, value) { saved.push(scope + ":" + key + "=" + value) }
  }
  Timer { interval: 300; running: true; onTriggered: test.ready = true }
  TestCase {
   id: test; property bool ready: false; when: ready; name: "NumberSettings"
   // QtTest's own messages do not reach the qs log; these lines do.
   function check(ok, what) {
    try { verify(ok, what) } catch (error) { console.log("NUMBER_SETTINGS FAIL " + what); throw error }
   }
   function same(actual, expected, what) {
    try { compare(actual, expected, what) } catch (error) {
     console.log("NUMBER_SETTINGS FAIL " + what + ": " + JSON.stringify(actual) + " instead of " + JSON.stringify(expected))
     throw error
    }
   }
   function waitUntil(condition, what) {
    try { tryVerify(condition, 5000, what) } catch (error) { console.log("NUMBER_SETTINGS FAIL " + what); throw error }
   }
   function editor() { var f = findChild(pane, "center-keepDays"); check(f !== null, "the keep-days field is on the page"); return f }
   function test_external_change_shows_while_open() {
    var f = editor()
    same(f.field.text, "30", "the field shows the stored number")
    pane.settings = ({ keepDays: 14, maxItems: 1000 })     // another monitor, the CLI
    waitUntil(function() { return f.field.text === "14" }, "the field shows a number changed elsewhere")
    same(pane.saved.length, 0, "a change made elsewhere is not saved again")
   }
   function test_escape_restores_and_stays() {
    var f = editor()
    f.field.forceActiveFocus()
    keyClick(Qt.Key_End); keyClick(Qt.Key_Backspace); keyClick(Qt.Key_Backspace); keyClick(Qt.Key_7)
    check(f.editing, "typing starts an edit")
    keyClick(Qt.Key_Escape)
    same(f.field.text, String(pane.settings.keepDays), "Escape shows the stored number again")
    check(!f.editing, "Escape ends the edit")
    f.field.focus = false
    same(pane.saved.length, 0, "an edit Escape ended is not saved")
   }
   function test_enter_commits_once() {
    var f = editor()
    f.field.forceActiveFocus()
    keyClick(Qt.Key_End); keyClick(Qt.Key_Backspace); keyClick(Qt.Key_Backspace); keyClick(Qt.Key_9)
    keyClick(Qt.Key_Return)
    f.field.focus = false
    same(pane.saved, ["center:keepDays=9"], "Enter and focus-out save the number once")
   }
   function test_same_number_retries_after_a_failed_save() {
    var f = editor()
    f.field.forceActiveFocus()
    keyClick(Qt.Key_End); keyClick(Qt.Key_Backspace); keyClick(Qt.Key_Backspace); keyClick(Qt.Key_1); keyClick(Qt.Key_4)
    keyClick(Qt.Key_Return)
    same(pane.saved, ["center:keepDays=14"], "Enter saves the number")
    pane.saveFailed("center", "keepDays", 14)                // Panel.finishPreference(false); value stays 30
    same(f.field.text, "30", "a failed save shows the stored number again")
    keyClick(Qt.Key_End); keyClick(Qt.Key_Backspace); keyClick(Qt.Key_Backspace); keyClick(Qt.Key_1); keyClick(Qt.Key_4)
    keyClick(Qt.Key_Return)
    same(pane.saved, ["center:keepDays=14", "center:keepDays=14"], "the same number saves again after a failed save")
    f.field.focus = false
    same(pane.saved.length, 2, "focus-out does not send it a third time")
   }
   function test_a_failed_pick_shows_the_stored_choice_again() {
    var g = findChild(pane, "center-browserGrouping"); check(g !== null, "the grouping choice is on the page")
    same(g.shownValue, "browser", "the choice shows the stored value")
    g.select("hostname"); g.select("none")
    same(pane.saved, ["center:browserGrouping=hostname", "center:browserGrouping=none"], "each pick is saved")
    // The panel saves one pick per key at a time: the older one failed and
    // the newer one still waits, so it stays on show.
    pane.saveFailed("center", "browserGrouping", "hostname")
    same(g.shownValue, "none", "the waiting pick stays on show when an older one fails")
    pane.saveFailed("center", "browserGrouping", "none")      // value stays "browser"
    same(g.shownValue, "browser", "a failed pick shows the stored choice again")
   }
   function test_short_values_are_rows() {
    // DESIGN.md "Short values use the row form": numbers and the grouping
    // choice are rows as tall as a toggle row, ending on the same edge.
    var days = editor(), most = findChild(pane, "center-maxItems")
    var grouping = findChild(pane, "center-browserGrouping"), toggle = findChild(pane, "center-compact")
    check(days.compact && most.compact && grouping.compact, "the numbers and the grouping choice use the row form")
    same(days.label, "Keep notifications", "the keep-days label")
    same(days.unit, "days", "the keep-days unit")
    same(most.unit, "", "the maximum has no unit")
    for (var row of [days, most, grouping]) {
     same(row.height, toggle.height, row.objectName + " is as tall as a toggle row")
     same(row.mapToItem(pane, row.width, 0).x, toggle.mapToItem(pane, toggle.width, 0).x, row.objectName + " ends on the toggle row's edge")
    }
    check(days.field.width < pane.width / 4, "the number field is narrow")
   }
   function cleanup() { pane.settings = ({ keepDays: 30, maxItems: 1000 }); pane.saved = []; wait(50) }
   onCompletedChanged: if (completed) console.log("NUMBER_SETTINGS", qtest_results.passCount, "passed", qtest_results.failCount, "failed")
  }
 }
}
""")
# A private home and config: on 4.5 the shell language is $XDG_CONFIG_HOME/omarchy/language.
home = base / "home"
home.mkdir()
env = dict(
    os.environ,
    HOME=str(home),
    XDG_CONFIG_HOME=str(home / ".config"),
    XDG_STATE_HOME=str(home / ".local/state"),
    XDG_RUNTIME_DIR=str(base / "runtime"),
    QT_QPA_PLATFORM="offscreen",
    QT_QPA_PLATFORMTHEME="generic",
    QT_QUICK_BACKEND="software",
)
for key in ["WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE"]:
    env.pop(key, None)
hostenv.isolate(env, base)
env.update(hostenv.make(base, app, env=env))
# Its own process group, stopped as a whole when the block ends.
log = base / "qs.log"
with (
    log.open("w") as out,
    hostenv.ProcessGroup(
        ["quickshell", "-p", str(app), "--no-color"], env=env, stdout=out, stderr=subprocess.STDOUT
    ) as shell,
):
    status = shell.wait(60)
output = log.read_text()
hostenv.check(env, output, *hostenv.calls(base))
print(
    "\n".join(
        line
        for line in output.splitlines()
        if "NUMBER_SETTINGS" in line or "FAIL" in line or "Actual" in line or "Expected" in line or "Error" in line
    )
)
# Six test functions plus QtTest's own count: a function that stops running fails here.
assert status == 0 and "NUMBER_SETTINGS 7 passed 0 failed" in output, output
