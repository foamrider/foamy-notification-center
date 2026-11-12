"""Exercise archive normalization through the real service and visible image controls."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

KIT = Path(os.environ.get("FOAMY_KIT", Path.home() / "GitHub/Personal/foamy-kit"))
sys.path.insert(0, str(KIT / "preview"))
import hostenv  # noqa: E402  (foamy-kit"s preview/hostenv.py)

source = Path(__file__).resolve().parents[1]
base = Path(tempfile.mkdtemp(prefix="foamy-center-images-"))
app = base / "app"
app.mkdir()
for name in ["Commons", "Ui"]:
    (app / name).symlink_to(hostenv.root() / "shell" / name, target_is_directory=True)
(app / "plugin").symlink_to(source, target_is_directory=True)
notifications = base / "notifications"
(notifications / "history").mkdir(parents=True)
runtime = base / "runtime"
runtime.mkdir(mode=0o700)
cli = base / "bin"
cli.mkdir()
# The fixture has its own store; DND IPC must not reach the user's live shell.
(cli / "omarchy-shell").write_text("#!/bin/sh\nprintf 'off\\n'\n")
(cli / "omarchy-shell").chmod(0o755)
icon = app / "icon.jpg"
picture = app / "picture.png"
subprocess.run(
    [
        "magick",
        "-size",
        "64x64",
        "xc:#8aadf4",
        "-fill",
        "#24273a",
        "-draw",
        "circle 32,32 32,12",
        "-interlace",
        "Plane",
        str(icon),
    ],
    check=True,
)
subprocess.run(["magick", "-size", "1440x900", "gradient:#8aadf4-#a6da95", str(picture)], check=True)
bomb = bytearray(icon.read_bytes())
frame = bomb.index(b"\xff\xc2")
bomb[frame + 5 : frame + 9] = (60000).to_bytes(2, "big") * 2
(app / "rejected.jpg").write_bytes(bomb)
stamp = int(time.time() * 1000)
entry = {
    "timestamp": stamp,
    "app": "Image test",
    "appIcon": str(icon),
    "image": str(picture),
    "summary": "Picture retained",
    "body": "A progressive JPEG icon and a full picture preview.",
    "execArgv": ["viewer", str(picture)],
}
notification = notifications / f"{stamp}-1.json"
notification.write_text(json.dumps(entry))
(app / "shell.qml").write_text(
    """import QtQuick
import QtTest
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import "plugin" as Plugin
import "plugin/components"
import "plugin/Model.js" as Model
ShellRoot {
  id: root
  property int activations: 0
  readonly property var entry: store.entries[0] || ({app:"Image test",summary:"Loading",body:"",timestamp:0})
  readonly property var groups: Model.groupsFor(store.entries,"","none")
  Plugin.Service { id: store }
  FileView { id: input; path: INPUT_PATH }
  FloatingWindow {
    id: window; visible:true; implicitWidth:600; implicitHeight:430; color:Commons.Color.background
    Column {
      id: card; x:20; y:20; width:520
      NotificationStackHeader {
        id: header; width:parent.width
        group: root.groups[0] || ({app:"Image test",entries:[],timestamp:0,critical:false})
      }
      NotificationRow {
        id: row; width:parent.width; entry:root.entry; first:true; last:true
        onClicked: root.activations++
      }
    }
    property bool ready:false
    Timer { interval:400; running:true; onTriggered:window.ready=true }
    TestCase {
      name:"ArchivedImages"; when:window.ready
      onCompletedChanged: if(completed) console.log("IMAGES_UI",qtest_results.passCount,"passed",qtest_results.failCount,"failed")
      function imageFor(item,source){
        if(item.source!==undefined && String(item.source)===source)return item
        for(var i=0;i<item.children.length;i++){var found=imageFor(item.children[i],source);if(found)return found}
        return null
      }
      function capture(name){var preview=imageFor(row,root.entry.preview);if(preview)tryCompare(preview,"status",Image.Ready);waitForRendering(card);wait(100);var done=false;card.grabToImage(function(r){verify(r.saveToFile(Qt.resolvedUrl(name+".png").toString().replace("file://","")));done=true});tryVerify(function(){return done})}
      function test_ingest_render_and_rejected_replacement(){
        tryCompare(store,"loaded",true)
        tryVerify(function(){return store.entries.length===1 && root.entry.imageFormat===1})
        var icon=findChild(header,"notificationAppIcon")
        verify(root.entry.appIcon.endsWith("-appIcon.png"));tryCompare(icon,"status",Image.Ready)
        tryVerify(function(){return row.hasPreview})
        var preview=imageFor(row,root.entry.preview);verify(preview!==null);tryCompare(preview,"status",Image.Ready)
        Commons.Color.background="#24273a";Commons.Color.foreground="#cad3f5";Commons.Color.accent="#8aadf4"
        capture("images-wide-dark");card.width=280;capture("images-narrow-dark")
        Commons.Color.background="#eff1f5";Commons.Color.foreground="#4c4f69";Commons.Color.accent="#1e66f5"
        card.width=520;capture("images-wide-light");card.width=280;capture("images-narrow-light")
        mouseClick(row,80,20);compare(root.activations,1)
        var updated=SOURCE_ENTRY
        updated.appIcon=Qt.resolvedUrl("rejected.jpg").toString();updated.summary="Invalid icon rejected"
        input.setText(JSON.stringify(updated))
        tryVerify(function(){return root.entry.summary==="Invalid icon rejected"})
        compare(root.entry.appIcon,"");tryCompare(icon,"status",Image.Null)
        verify(row.hasPreview);tryCompare(imageFor(row,root.entry.preview),"status",Image.Ready)
        capture("images-rejected-icon")
        updated.appIcon="foot";updated.summary="Themed icon retained"
        input.setText(JSON.stringify(updated))
        tryVerify(function(){return root.entry.summary==="Themed icon retained"})
        compare(root.entry.appIcon,"foot");tryCompare(icon,"status",Image.Ready)
      }
    }
  }
}
""".replace("INPUT_PATH", json.dumps(str(notification))).replace("SOURCE_ENTRY", json.dumps(entry))
)
env = dict(
    os.environ,
    HOME=str(base / "home"),
    XDG_CONFIG_HOME=str(base / "home/.config"),
    XDG_CACHE_HOME=str(base / "cache"),
    XDG_STATE_HOME=str(base / "state"),
    XDG_RUNTIME_DIR=str(runtime),
    NC_SRC_DIR=str(notifications),
    NC_SRC_HISTORY=str(notifications / "history"),
    NC_STORE=str(base / "state/omarchy-notification-center"),
    PATH=str(cli) + ":" + os.environ["PATH"],
    QT_QPA_PLATFORM="wayland",
    QT_QPA_PLATFORMTHEME="basic",
    QT_STYLE_OVERRIDE="Fusion",
)
env["WAYLAND_DISPLAY"] = str(Path(os.environ["XDG_RUNTIME_DIR"]) / os.environ["WAYLAND_DISPLAY"])
for key in ["DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE", "QT_QUICK_BACKEND"]:
    env.pop(key, None)
# On the live compositor on purpose; the bus is dbus-run-session's own.
hostenv.isolate(env, base, display=True)
env.update(hostenv.make(base, app, env=env))
env["PATH"] = str(cli) + ":" + env["PATH"]
# qs and dbus-run-session's daemon in one process group, stopped as a whole
# when the block ends (with the scripts qs's Processes started).
log = base / "qs.log"
with (
    log.open("w") as out,
    hostenv.ProcessGroup(
        ["dbus-run-session", "--", "quickshell", "-p", str(app), "--no-color"],
        env=env,
        stdout=out,
        stderr=subprocess.STDOUT,
    ) as shell,
):
    status = shell.wait(60)
output = log.read_text()
print(output)
print("Image captures:", app)
hostenv.check(env, output, *hostenv.calls(base))
assert status == 0 and "IMAGES_UI 2 passed 0 failed" in output
