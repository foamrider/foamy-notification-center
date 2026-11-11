"""Wheel and touchpad scrolling of the notification list (kit FoamyWheelScroll).

One wheel notch scrolls `wheelStep` px however the mouse splits it (a
high-resolution wheel sends 8 x 15 instead of 1 x 120), notches add up,
touchpad pixels map 1:1, and a list that fits does not move.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

KIT = Path(os.environ.get('FOAMY_KIT', Path.home() / 'GitHub/Personal/foamy-kit'))
sys.path.insert(0, str(KIT / 'preview'))
import hostenv  # noqa: E402  (foamy-kit's preview/hostenv.py)

source = Path(__file__).resolve().parents[1]
base = Path(tempfile.mkdtemp(prefix='foamy-center-scroll-'))
app = base / 'app'
app.mkdir()
for name in ['Commons', 'Ui']:
    # hostenv.root(): the installed 4.5 shell unless OMARCHY_TEST_ROOT / FOAMY_HOST_45 pick another.
    (app / name).symlink_to(hostenv.root() / 'shell' / name)
(app / 'plugin').symlink_to(source)
runtime = base / 'runtime'
runtime.mkdir(mode=0o700)
(app / 'shell.qml').write_text('''import QtQuick
import QtQuick.Controls
import QtTest
import Quickshell
import "plugin/kit" as Kit
import "plugin/components" as Components
ShellRoot {
 FloatingWindow {
  id: window; visible: true; implicitWidth: 420; implicitHeight: 400
  Components.NotificationList {
   id: list
   anchors.fill: parent
   model: 30
   delegate: Item {
    x: 14
    width: list.width - 28
    height: 120
    MouseArea { anchors.fill: parent; acceptedButtons: Qt.LeftButton | Qt.RightButton }
   }
  }
  Timer { interval: 300; running: true; onTriggered: test.ready = true }
  TestCase {
   id: test; property bool ready: false; when: ready; name: "NotificationScrolling"
   function init() { list.scrollBy(-100000, false); wait(Kit.FoamyMotion.slider + 50) }
   function settle() { wait(Kit.FoamyMotion.slider + 80) }
   function test_notchOnCardAndBothGutters() {
    verify(list.wheelStep > 0)
    for (var x of [100, 4, 409]) {
     var start = list.contentY
     mouseWheel(list, x, 100, 0, -120, Qt.NoButton)
     settle()
     fuzzyCompare(list.contentY - start, list.wheelStep, 1)
    }
   }
   function test_highResolutionNotch() {
    // One notch of a high-resolution wheel: 8 events of 15.
    for (var i = 0; i < 8; i++) mouseWheel(list, 100, 100, 0, -15, Qt.NoButton)
    settle()
    fuzzyCompare(list.contentY, list.originY + list.wheelStep, 1)
   }
   function test_scrollbarAtOuterEdge() {
    var bar = list.ScrollBar.vertical
    compare(bar.x + bar.width, list.width - list.scrollbarInset)
    compare(bar.height, list.height)
    verify(bar.active)
    compare(bar.availableWidth, list.scrollbarWidth)
   }
   function test_fastNotchesAccumulate() {
    for (var i = 0; i < 4; i++) mouseWheel(list, 100, 100, 0, -120, Qt.NoButton)
    settle()
    fuzzyCompare(list.contentY, list.originY + 4 * list.wheelStep, 1)
   }
   function test_edgesAndPixelMovement() {
    list.scrollBy(-1000, false)
    compare(list.contentY, list.originY)
    list.scrollBy(23, false)
    compare(list.contentY, list.originY + 23)
    list.scrollBy(100000, false)
    compare(list.contentY, list.originY + list.contentHeight - list.height)
    mouseWheel(list, 100, 100, 0, -120, Qt.NoButton)
    settle()
    compare(list.contentY, list.originY + list.contentHeight - list.height)
   }
   function test_shortListDoesNotScroll() {
    list.model = 1; wait(100)
    mouseWheel(list, 100, 100, 0, -120, Qt.NoButton)
    settle()
    compare(list.contentY, list.originY)
    list.model = 30
   }
   onCompletedChanged: if (completed) console.log("SCROLLING", qtest_results.passCount, "passed", qtest_results.failCount, "failed")
  }
 }
}
''')
# A private home and config: on 4.5 the shell language is $XDG_CONFIG_HOME/omarchy/language.
home = base / 'home'
home.mkdir()
env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home / '.config'), XDG_STATE_HOME=str(home / '.local/state'), XDG_RUNTIME_DIR=str(runtime), QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='generic', QT_QUICK_BACKEND='software')
env.pop('WAYLAND_DISPLAY', None)
hostenv.isolate(env, base)
env.update(hostenv.make(base, app, env=env))
result = subprocess.run(['quickshell', '-p', str(app), '--no-color'], env=env, capture_output=True, text=True, timeout=60)
output = result.stdout + result.stderr
print(output)
hostenv.check(env, output, *hostenv.calls(base))
assert result.returncode == 0 and 'SCROLLING 7 passed 0 failed' in output, output
