"""Verify text and dismiss hit regions do not overlap in either direction."""
import os
from pathlib import Path
import subprocess
import tempfile

source = Path(__file__).resolve().parents[1]
base = Path(tempfile.mkdtemp(prefix='foamy-center-rtl-'))
app = base / 'app'
app.mkdir()
for name in ['Commons', 'Ui']:
    # OMARCHY_TEST_ROOT selects the host shell (an extracted 4.5 tree); default 4.0.6.
    (app / name).symlink_to(os.environ.get('OMARCHY_TEST_ROOT', '/usr/share/omarchy') + '/shell/' + name)
(app / 'plugin').symlink_to(source)
runtime = base / 'runtime'
runtime.mkdir(mode=0o700)
(app / 'shell.qml').write_text('''import QtQuick
import QtTest
import Quickshell
import "plugin/kit" as Kit
import "plugin/components" as Components
ShellRoot {
 QtObject { id: translator; property string language: "en"; property bool rightToLeft: false; property string formatLocale: "en-US"; function t(key,fallback) { return fallback } function number(value) { return String(value) } }
 FloatingWindow {
  id: window; visible: true; implicitWidth: 500; implicitHeight: 500
  Components.NotificationRow {
   id: row; width: 420; height: implicitHeight; expanded: true; hasCursor: true; first: true; last: true; groupCritical: true
   entry: ({summary:"A long message that must stay outside the dismiss button",body:"A longer body with enough text to wrap at narrow widths without entering the dismiss hit area.",timestamp:1}); now: 100000
   LayoutMirroring.enabled: Kit.FoamyI18n.rightToLeft
   LayoutMirroring.childrenInherit: true
   property int removed: 0
   onRemoveRequested: removed++
  }
  Timer { interval: 300; running:true; onTriggered: test.ready=true }
  TestCase {
   id: test; property bool ready: false; when: ready; name:"NotificationRowDirection"
   function test_direction() {
    Kit.FoamyI18n.backend=translator;
    var texts=findChild(row,"notificationRowText"), dismiss=findChild(row,"notificationRowDismiss");
    verify(texts!==null && dismiss!==null);
    for(var rtl of [false,true]) {
     translator.rightToLeft=rtl;
     for(var width of [420,280]) {
      row.width=width; wait(100);
      var textX=texts.mapToItem(row,0,0).x, dismissX=dismiss.mapToItem(row,0,0).x;
      verify(texts.width>100);
      verify(rtl ? textX>=dismissX+dismiss.width : textX+texts.width<=dismissX);
      var before=row.removed; mouseClick(dismiss); compare(row.removed,before+1);
      var done=false;row.grabToImage(function(result){verify(result.saveToFile(Qt.resolvedUrl((rtl?"rtl-":"ltr-")+width+".png").toString().replace("file://","")));done=true});tryVerify(function(){return done});
     }
    }
    Kit.FoamyI18n.backend=null;
   }
   onCompletedChanged: if(completed)console.log("RTL_ROWS",qtest_results.passCount,"passed",qtest_results.failCount,"failed")
  }
 }
}
''')
env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='generic', QT_QUICK_BACKEND='software')
env.pop('WAYLAND_DISPLAY', None)
result = subprocess.run(['quickshell', '-p', str(app), '--no-color'], env=env, capture_output=True, text=True, timeout=15)
output = result.stdout + result.stderr
print(output)
print('Row captures:', app)
assert result.returncode == 0 and 'RTL_ROWS 2 passed 0 failed' in output, output
