"""Verify text and dismiss hit regions do not overlap in either direction."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile

KIT = Path(os.environ.get("FOAMY_KIT", Path.home() / "GitHub/Personal/foamy-kit"))
sys.path.insert(0, str(KIT / "preview"))
import hostenv  # noqa: E402  (foamy-kit's preview/hostenv.py)

source = Path(__file__).resolve().parents[1]
base = Path(tempfile.mkdtemp(prefix="foamy-center-rtl-"))
app = base / "app"
app.mkdir()
for name in ["Commons", "Ui"]:
    # hostenv.root(): the installed 4.5 shell unless OMARCHY_TEST_ROOT / FOAMY_HOST_45 pick another.
    (app / name).symlink_to(hostenv.root() / "shell" / name)
(app / "plugin").symlink_to(source)
runtime = base / "runtime"
runtime.mkdir(mode=0o700)
(app / "shell.qml").write_text("""import QtQuick
import QtTest
import Quickshell
import Quickshell.Io
import "plugin/kit" as Kit
import "plugin/components" as Components
ShellRoot {
 // The shell's language file: Arabic turns FoamyI18n.rightToLeft on.
 FileView { id: language; path: Quickshell.env("OMARCHY_LANGUAGE_FILE") }
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
    var texts=findChild(row,"notificationRowText"), dismiss=findChild(row,"notificationRowDismiss");
    verify(texts!==null && dismiss!==null);
    for(var rtl of [false,true]) {
     language.setText(rtl ? "ar\n" : "en\n");
     tryCompare(Kit.FoamyI18n, "rightToLeft", rtl, 10000);
     for(var width of [420,280]) {
      row.width=width;
      var apart=function(){var textX=texts.mapToItem(row,0,0).x, dismissX=dismiss.mapToItem(row,0,0).x; return texts.width>100 && (rtl ? textX>=dismissX+dismiss.width : textX+texts.width<=dismissX)};
      tryVerify(apart, 5000, (rtl?"RTL ":"LTR ")+width+": the text and the dismiss button overlap");
      var before=row.removed; mouseClick(dismiss); compare(row.removed,before+1);
      var done=false;row.grabToImage(function(result){verify(result.saveToFile(Qt.resolvedUrl((rtl?"rtl-":"ltr-")+width+".png").toString().replace("file://","")));done=true});tryVerify(function(){return done});
     }
    }
   }
   onCompletedChanged: if(completed)console.log("RTL_ROWS",qtest_results.passCount,"passed",qtest_results.failCount,"failed")
  }
 }
}
""")
# A private home and config: on 4.5 the shell language is $XDG_CONFIG_HOME/omarchy/language.
home = base / "home"
home.mkdir()
language = base / "language"
language.write_text("en\n")
env = dict(
    os.environ,
    HOME=str(home),
    XDG_CONFIG_HOME=str(home / ".config"),
    XDG_STATE_HOME=str(home / ".local/state"),
    XDG_RUNTIME_DIR=str(runtime),
    OMARCHY_LANGUAGE_FILE=str(language),
    QT_QPA_PLATFORM="offscreen",
    QT_QPA_PLATFORMTHEME="generic",
    QT_QUICK_BACKEND="software",
)
env.pop("WAYLAND_DISPLAY", None)
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
print(output)
print("Row captures:", app)
hostenv.check(env, output, *hostenv.calls(base))
assert status == 0 and "RTL_ROWS 2 passed 0 failed" in output, output
