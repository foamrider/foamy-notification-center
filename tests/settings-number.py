"""Numeric settings use kit FoamyNumberField: an external change shows while Settings is open,
and Escape restores the saved value without saving or leaving the page. Offscreen; OMARCHY_TEST_ROOT
selects the host shell (default 4.0.6)."""
import os
from pathlib import Path
import subprocess
import tempfile

source = Path(__file__).resolve().parents[1]
host = (os.environ.get('OMARCHY_TEST_ROOT') or '/usr/share/omarchy')
base = Path(tempfile.mkdtemp(prefix='foamy-center-number-'))
app = base / 'app'
app.mkdir()
for name in ['Commons', 'Ui']:
    (app / name).symlink_to(host + '/shell/' + name)
(app / 'plugin').symlink_to(source)
(base / 'runtime').mkdir(mode=0o700)
(app / 'shell.qml').write_text('''import QtQuick
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
   function editor() { var f = findChild(pane, "center-keepDays"); verify(f !== null); return f }
   function test_external_change_shows_while_open() {
    var f = editor()
    compare(f.field.text, "30")
    pane.settings = ({ keepDays: 14, maxItems: 1000 })     // another monitor, the CLI
    tryCompare(f.field, "text", "14")
    compare(pane.saved.length, 0)
   }
   function test_escape_restores_and_stays() {
    var f = editor()
    f.field.forceActiveFocus()
    keyClick(Qt.Key_End); keyClick(Qt.Key_Backspace); keyClick(Qt.Key_Backspace); keyClick(Qt.Key_7)
    verify(f.editing)
    keyClick(Qt.Key_Escape)
    compare(f.field.text, String(pane.settings.keepDays))
    verify(!f.editing)
    f.field.focus = false
    compare(pane.saved.length, 0)
   }
   function test_enter_commits_once() {
    var f = editor()
    f.field.forceActiveFocus()
    keyClick(Qt.Key_End); keyClick(Qt.Key_Backspace); keyClick(Qt.Key_Backspace); keyClick(Qt.Key_9)
    keyClick(Qt.Key_Return)
    f.field.focus = false
    compare(pane.saved, ["center:keepDays=9"])
   }
   function test_same_number_retries_after_a_failed_save() {
    var f = editor()
    f.field.forceActiveFocus()
    keyClick(Qt.Key_End); keyClick(Qt.Key_Backspace); keyClick(Qt.Key_Backspace); keyClick(Qt.Key_1); keyClick(Qt.Key_4)
    keyClick(Qt.Key_Return)
    compare(pane.saved, ["center:keepDays=14"])
    pane.saveFailed("center", "keepDays")                    // Panel.finishPreference(false); value stays 30
    compare(f.field.text, "30")
    keyClick(Qt.Key_End); keyClick(Qt.Key_Backspace); keyClick(Qt.Key_Backspace); keyClick(Qt.Key_1); keyClick(Qt.Key_4)
    keyClick(Qt.Key_Return)
    compare(pane.saved, ["center:keepDays=14", "center:keepDays=14"])
    f.field.focus = false
    compare(pane.saved.length, 2)                           // focus-out does not send it a third time
   }
   function cleanup() { pane.settings = ({ keepDays: 30, maxItems: 1000 }); pane.saved = []; wait(50) }
   onCompletedChanged: if (completed) console.log("NUMBER_SETTINGS", qtest_results.passCount, "passed", qtest_results.failCount, "failed")
  }
 }
}
''')
env = dict(os.environ, XDG_RUNTIME_DIR=str(base / 'runtime'), QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='generic', QT_QUICK_BACKEND='software')
for key in ['WAYLAND_DISPLAY', 'HYPRLAND_INSTANCE_SIGNATURE']:
    env.pop(key, None)
result = subprocess.run(['quickshell', '-p', str(app), '--no-color'], env=env, capture_output=True, text=True, timeout=20)
output = result.stdout + result.stderr
print('\n'.join(line for line in output.splitlines() if 'NUMBER_SETTINGS' in line or 'FAIL' in line or 'Actual' in line or 'Expected' in line or 'Error' in line))
import re
match = re.search(r'NUMBER_SETTINGS (\d+) passed (\d+) failed', output)
assert match and int(match.group(1)) >= 4 and match.group(2) == '0', output
