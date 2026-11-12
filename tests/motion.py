"""Exercise real Center list delegates with synthetic history and an isolated Qt surface."""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

KIT = Path(os.environ.get("FOAMY_KIT", Path.home() / "GitHub/Personal/foamy-kit"))
sys.path.insert(0, str(KIT / "preview"))
import hostenv  # noqa: E402  (foamy-kit's preview/hostenv.py)

source = Path(__file__).resolve().parents[1]
desktop = "--desktop" in sys.argv
# --desktop opens a real surface on the live desktop: only when asked for.
if desktop and os.environ.get("FOAMY_TEST_DESKTOP") != "1":
    raise SystemExit("motion --desktop: opens a real surface on the live desktop; set FOAMY_TEST_DESKTOP=1 to run it")
base = Path(tempfile.mkdtemp(prefix="foamy-center-motion-"))
app = base / "app"
app.mkdir()
(app / "Commons").symlink_to(hostenv.root() / "shell/Commons", target_is_directory=True)
# Include the plugin translator without registering unrelated fixture types.
(app / "kit").symlink_to(source / "kit", target_is_directory=True)
(app / "i18n").symlink_to(source / "i18n", target_is_directory=True)
for name in ["Markup.js", "BrowserIdentity.js"]:
    (app / name).symlink_to(source / name)
(app / "Ui").symlink_to(hostenv.root() / "shell/Ui", target_is_directory=True)
(app / "components").symlink_to(source / "components", target_is_directory=True)
for name in ["Model.js", "Translations.js"]:
    (app / name).symlink_to(source / name)
s = (source / "Panel.qml").read_text()
# The list's delegate object, from "delegate: Item {" to its matching brace
# (the panel's delegate source has no brace inside a string or comment).
a = s.index("delegate: Item {")
depth, b = 0, s.index("{", a)
while True:
    depth += {"{": 1, "}": -1}.get(s[b], 0)
    b += 1
    if depth == 0:
        break
delegate = s[a:b]
assert delegate.count("{") == delegate.count("}") and "root.activate(entry)" in delegate, delegate
(app / "shell.qml").write_text(
    """import QtQuick
import QtTest
import Quickshell
import qs.Commons
import qs.Commons as Commons
import "components"
import "kit"
import "Model.js" as Model
ShellRoot {
 id:root
 property bool compact:true
 property string language:"en"
 property double now:Date.now()
 property double readMark:0
 property color foreground:Commons.Color.popups.text
 property string fontFamily:Style.font.family
 property bool keyboardNavigation:false
 property bool popupContentActive:true
 property int cursorIndex:-1
 property bool cursorDismiss:false
 property bool showBody:true
 property bool showPreview:true
 property var entries:[]
 property var expanded:({})
 property string filter:""
 function rebuild(){list.rows=Model.stackRows(entries,expanded,filter)}
 function toggleGroup(key){var next=Object.assign({},expanded);next[key]=!next[key];expanded=next;rebuild()}
 function remove(key){entries=entries.filter(function(e){return e.key!==key});rebuild()}
 function removeGroup(group){entries=entries.filter(function(e){return e.app!==group.app});rebuild()}
 function activate(entry){}
 FloatingWindow {
  id:window;visible:true;implicitWidth:500;implicitHeight:480;color:"#18181c"
  NotificationList {id:list;x:20;y:20;width:420;height:400;entranceDistance:8
   DELEGATE
  }
  property bool ready:false
  Timer {interval:400;running:true;onTriggered:window.ready=true}
  property var heightSamples:[]
  property bool sampleHeight:false
  FrameAnimation {running:window.sampleHeight;onTriggered:window.heightSamples.push(list.contentHeight)}
  property var watched:null
  property int entranceFrames:0
  property int exitFrames:0
  property int collapseFrames:0
  // The longest frame while a card is watched: a frame longer than an
  // animation (a heavily loaded machine) can show none of its middle.
  property real longestFrame:0
  property real fullHeight:0
  // A card's y while it closes the space above it: whether a frame showed it
  // between where it started and where it ends (sampled every frame, so a
  // loaded machine that renders fewer frames still counts the ones it shows).
  property var tracked:null
  property real trackedStart:0
  property bool trackedBetween:false
  FrameAnimation {running:window.tracked!==null;onTriggered:{if(frameTime>window.longestFrame)window.longestFrame=frameTime;var y=window.tracked.mapToItem(list,0,0).y;if(y>1 && y<window.trackedStart-1)window.trackedBetween=true}}
  FrameAnimation {running:true;onTriggered:{var card=window.watched;if(!card)return;if(frameTime>window.longestFrame)window.longestFrame=frameTime;if(card.retired && card.height>0 && card.height<window.fullHeight)window.collapseFrames++;if(card.opacity>0 && card.opacity<1){if(card.retired)window.exitFrames++;else if(card.entranceOffset>0)window.entranceFrames++}}}
  TestCase {
   name:"CenterMotion";when:window.ready
   onCompletedChanged:if(completed)console.log("CENTER_MOTION",qtest_results.passCount,"passed",qtest_results.failCount,"failed")
   function row(key,app,stamp){return {key:key,app:app,timestamp:stamp,summary:"Design review "+key,body:"The updated files are ready. Have a look when you have a moment.",urgency:1}}
   function init(){window.watched=null;window.tracked=null;window.trackedBetween=false;list.height=400;root.entries=[];root.filter="";root.expanded={};root.rebuild();tryVerify(function(){return list.count===0 && list.contentHeight===0},5000);list.positionViewAtBeginning();window.entranceFrames=0;window.exitFrames=0;window.collapseFrames=0;window.longestFrame=0}
   // Intermediate frames of an animation lasting `ms`, unless no frame was
   // shorter than it (then there was no middle to show).
   function sawMiddle(frames,ms){return frames>0 || window.longestFrame*1000>=ms}
   // Until every created card has finished entering and the content height
   // holds still for 100 ms (a loaded machine runs the entrances slower).
   function settle(){
    for(var n=0;n<100;n++){
     var h=list.contentHeight,done=true
     for(var k=0;k<list.count;k++){var it=list.itemAtIndex(k);if(it && (it.opacity!==1 || it.entranceOffset!==0))done=false}
     wait(100)
     if(done && h===list.contentHeight)return
    }
    fail("the list never settled")
   }
   function item(index){tryVerify(function(){return list.itemAtIndex(index)!==null});return list.itemAtIndex(index)}
   function capture(name){list.grabToImage(function(r){r.saveToFile(Qt.resolvedUrl(name+".png").toString().replace("file://",""))})}
   function test_arrival_update_and_removal(){try{
    root.entries=[row("3-1","Chat",300),row("2-1","Chat",200),row("1-1","Files",100)];root.rebuild()
    var card=item(1);window.watched=card;wait(40);capture("entrance");tryCompare(card,"opacity",1);tryCompare(card,"entranceOffset",0)
    verify(sawMiddle(window.entranceFrames,FoamyMotion.fadeIn),"No intermediate entrance frames")
    root.entries[0]=Object.assign({},root.entries[0],{summary:"Updated design review"});root.rebuild();wait(40)
    compare(list.itemAtIndex(1),card);compare(card.modelData.entry.summary,"Updated design review");compare(card.opacity,1)
    root.toggleGroup("Chat");tryCompare(list,"count",5);wait(220);capture("expanded")
    compare(list.itemAtIndex(1),card)
    window.fullHeight=card.height;var below=item(3);var beforeY=below.mapToItem(list,0,0).y
    root.remove("3-1");tryCompare(card,"retired",true);verify(!card.enabled);compare(card.modelData.entry.summary,"Updated design review")
    wait(40);capture("exit")
    tryVerify(function(){return below.mapToItem(list,0,0).y<beforeY},3000,"remaining cards must move during collapse")
    tryVerify(function(){return sawMiddle(window.collapseFrames,FoamyMotion.duration(140))},3000,"height must have intermediate collapse frames")
    tryVerify(function(){return sawMiddle(window.exitFrames,FoamyMotion.duration(120))},3000,"No intermediate removal frames")
    window.watched=null
    root.entries=[];root.rebuild();tryCompare(list,"count",0);verify(list.contentHeight>0);tryVerify(function(){return list.contentHeight===0})
   }catch(e){console.log("FAILED",e.message,e.stack);throw e}}
   function test_first_group_closes_space_smoothly(){
    root.entries=[row("8-1","Chat",800),row("7-1","Files",700)];root.rebuild();var below=item(2)
    tryVerify(function(){return below.opacity===1 && below.entranceOffset===0 && item(0).opacity===1},5000)
    var start=below.mapToItem(list,0,0).y;verify(start>1)
    window.trackedStart=start;window.trackedBetween=false;window.tracked=below
    root.removeGroup({app:"Chat"})
    tryVerify(function(){return Math.abs(below.mapToItem(list,0,0).y)<=1},5000,"the remaining card must end at the top")
    window.tracked=null
    verify(sawMiddle(window.trackedBetween?1:0,FoamyMotion.duration(180)),"first-group removal must pass through intermediate positions")
   }
   function test_large_stack_removal_keeps_survivors_visible(){try{
    var rows=[]
    for(var i=0;i<18;i++){
     var entry=row(String(100-i)+"-1",i<12?"Chat":"Files",2000-i)
     entry.body=i<10?"A long notification message with several wrapped lines. ".repeat(12):"Current content after replacement."
     rows.push(entry)
    }
    root.entries=rows;root.expanded={Chat:true,Files:true};root.rebuild()
    list.height=Qt.binding(function(){return Math.min(list.contentHeight,1020)})
    settle();window.heightSamples=[];window.sampleHeight=true
    root.removeGroup({app:"Chat"});tryCompare(list,"count",7,5000)
    // Sample the whole removal: a few frames in, then until it holds still.
    tryVerify(function(){return window.heightSamples.length>3},5000);settle()
    // Every remaining row ends fully shown inside the viewport: none may be
    // stranded outside it by a displacement transition competing with the
    // outgoing height animation.
    tryVerify(function(){for(var k=0;k<7;k++){var it=list.itemAtIndex(k);if(!it || it.opacity!==1)return false;var y=it.mapToItem(list,0,0).y;if(y<-1 || y+it.height>list.height+1)return false}return true},5000,"the survivors settle inside the viewport")
    window.sampleHeight=false
    verify(Math.min.apply(null,window.heightSamples)>=list.contentHeight-1,"removal must not undershoot the remaining content height")
    // Every remaining row fits: none may be stranded outside the viewport by
    // a displacement transition competing with the outgoing height animation.
    for(var j=0;j<7;j++){
     var survivor=item(j)
     compare(survivor.opacity,1)
     verify(survivor.mapToItem(list,0,0).y>=-1)
     verify(survivor.mapToItem(list,0,0).y+survivor.height<=list.height+1)
    }
    capture("large-stack-removed")
   }catch(e){console.log("FAILED large-stack",e.message,e.stack);throw e}}
   function test_quick_removal_and_return(){
    root.entries=[row("9-1","Chat",900)];root.rebuild();var departing=item(1)
    wait(20);root.entries=[];root.rebuild();tryCompare(departing,"retired",true)
    root.entries=[row("9-1","Chat",900)];root.rebuild();tryCompare(list,"count",2)
    var returned=item(1);verify(returned!==departing);verify(!returned.retired);tryCompare(returned,"opacity",1,5000);tryCompare(returned,"entranceOffset",0,5000)
    root.entries=[];root.rebuild();tryVerify(function(){return list.contentHeight===0})
   }
   function test_search_reorder_and_virtualization(){try{
    var rows=[];for(var i=0;i<40;i++)rows.push(row(String(i+1)+"-1","App "+i,1000-i))
    root.entries=rows;root.rebuild();tryCompare(list,"count",80)
    var first=item(0);tryCompare(first,"opacity",1,5000);tryCompare(first,"entranceOffset",0,5000)
    root.entries[1]=Object.assign({},root.entries[1],{timestamp:2000});root.rebuild()
    tryVerify(function(){return list.itemAtIndex(2)===first},5000,"a moved card keeps its delegate");compare(first.opacity,1)
    list.positionViewAtEnd();wait(40);var last=item(79);compare(last.opacity,1);compare(last.entranceOffset,0)
    root.filter="no matches";root.rebuild();tryCompare(list,"count",0);wait(200)
    root.filter="App 3";root.rebuild();tryVerify(function(){return list.count>0});wait(220)
    list.positionViewAtBeginning();root.compact=false;list.width=320;Commons.Color.background="#eff1f5";Commons.Color.foreground="#4c4f69";wait(100);capture("narrow-light-search")
    root.keyboardNavigation=true;root.cursorIndex=1;wait(40)
    root.filter="";root.rebuild();tryCompare(list,"count",80)
   }catch(e){console.log("FAILED",e.message,e.stack);throw e}}
  }
 }
}
""".replace("DELEGATE", delegate)
)
home = base / "home"
home.mkdir()
runtime = base / "runtime"
runtime.mkdir(mode=0o700)
env = dict(
    os.environ,
    HOME=str(home),
    XDG_CONFIG_HOME=str(home / ".config"),
    XDG_STATE_HOME=str(home / ".local/state"),
    QT_QPA_PLATFORM="wayland" if desktop else "offscreen",
    QT_QUICK_BACKEND="rhi" if desktop else "software",
    QT_QPA_PLATFORMTHEME="basic",
)
if not desktop:
    env["XDG_RUNTIME_DIR"] = str(runtime)
    for key in ["DISPLAY", "WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE"]:
        env.pop(key, None)
hostenv.isolate(env, base, display=desktop)
env.update(hostenv.make(base, app, env=env))
# qs and dbus-run-session's daemon in one process group, stopped as a whole
# when the block ends (with the scripts qs's Processes started).
log = base / "qs.log"
with (
    log.open("w") as out,
    hostenv.ProcessGroup(
        ["dbus-run-session", "--", "qs", "-p", str(app), "--no-color"], env=env, stdout=out, stderr=subprocess.STDOUT
    ) as shell,
):
    status = shell.wait(60)
output = log.read_text()
print(output)
print("Captures:", app)
hostenv.check(env, output, *hostenv.calls(base))
assert status == 0 and "CENTER_MOTION 6 passed 0 failed" in output
