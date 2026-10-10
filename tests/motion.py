"""Exercise real Center list delegates with synthetic history and an isolated Qt surface."""
import os,signal,subprocess,tempfile,sys
from pathlib import Path
source=Path(__file__).resolve().parents[1]
base=Path(tempfile.mkdtemp(prefix='foamy-center-motion-'));app=base/'app';app.mkdir()
(app/'Commons').symlink_to('/usr/share/omarchy/shell/Commons',target_is_directory=True)
(app/'Ui').symlink_to('/usr/share/omarchy/shell/Ui',target_is_directory=True)
(app/'components').symlink_to(source/'components',target_is_directory=True)
for name in ['Model.js','Translations.js']:(app/name).symlink_to(source/name)
s=(source/'Panel.qml').read_text();a=s.index('          delegate: Item {');b=s.index('\n            }\n          }\n        }\n\n        // --------------------------------------------------------- empty',a)
delegate=s[a:b]
(app/'shell.qml').write_text('''import QtQuick
import QtTest
import Quickshell
import qs.Commons
import "components"
import "Model.js" as Model
ShellRoot {
 id:root
 property bool compact:true
 property string language:"en"
 property double now:Date.now()
 property double readMark:0
 property color foreground:Color.popups.text
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
  property real fullHeight:0
  FrameAnimation {running:true;onTriggered:{var card=window.watched;if(!card)return;if(card.retired && card.height>0 && card.height<window.fullHeight)window.collapseFrames++;if(card.opacity>0 && card.opacity<1){if(card.retired)window.exitFrames++;else if(card.entranceOffset>0)window.entranceFrames++}}}
  TestCase {
   name:"CenterMotion";when:window.ready
   onCompletedChanged:if(completed)console.log("CENTER_MOTION",qtest_results.passCount,"passed",qtest_results.failCount,"failed")
   function row(key,app,stamp){return {key:key,app:app,timestamp:stamp,summary:"Design review "+key,body:"The updated files are ready. Have a look when you have a moment.",urgency:1}}
   function init(){window.watched=null;list.height=400;root.entries=[];root.filter="";root.expanded={};root.rebuild();wait(250);list.positionViewAtBeginning();window.entranceFrames=0;window.exitFrames=0;window.collapseFrames=0}
   function item(index){tryVerify(function(){return list.itemAtIndex(index)!==null});return list.itemAtIndex(index)}
   function capture(name){list.grabToImage(function(r){r.saveToFile(Qt.resolvedUrl(name+".png").toString().replace("file://",""))})}
   function test_arrival_update_and_removal(){try{
    root.entries=[row("3-1","Chat",300),row("2-1","Chat",200),row("1-1","Files",100)];root.rebuild()
    var card=item(1);window.watched=card;wait(40);capture("entrance");tryCompare(card,"opacity",1);tryCompare(card,"entranceOffset",0)
    verify(window.entranceFrames>0,"No intermediate entrance frames")
    root.entries[0]=Object.assign({},root.entries[0],{summary:"Updated design review"});root.rebuild();wait(40)
    compare(list.itemAtIndex(1),card);compare(card.modelData.entry.summary,"Updated design review");compare(card.opacity,1)
    root.toggleGroup("Chat");tryCompare(list,"count",5);wait(220);capture("expanded")
    compare(list.itemAtIndex(1),card)
    window.fullHeight=card.height;var below=item(3);var beforeY=below.mapToItem(list,0,0).y
    root.remove("3-1");tryCompare(card,"retired",true);verify(!card.enabled);compare(card.modelData.entry.summary,"Updated design review")
    wait(40);capture("exit");wait(120);verify(below.mapToItem(list,0,0).y<beforeY,"remaining cards must move during collapse");wait(180);verify(window.collapseFrames>0,"height must have intermediate collapse frames");verify(window.exitFrames>0,"No intermediate removal frames");window.watched=null
    root.entries=[];root.rebuild();tryCompare(list,"count",0);verify(list.contentHeight>0);tryVerify(function(){return list.contentHeight===0})
   }catch(e){console.log("FAILED",e.message,e.stack);throw e}}
   function test_first_group_closes_space_smoothly(){
    root.entries=[row("8-1","Chat",800),row("7-1","Files",700)];root.rebuild();var below=item(2);wait(230)
    var start=below.mapToItem(list,0,0).y
    root.removeGroup({app:"Chat"});wait(170)
    var middle=below.mapToItem(list,0,0).y
    verify(middle>0 && middle<start,"first-group removal must pass through intermediate positions")
    wait(250);fuzzyCompare(below.mapToItem(list,0,0).y,0,1)
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
    wait(350);window.heightSamples=[];window.sampleHeight=true
    root.removeGroup({app:"Chat"});wait(700);window.sampleHeight=false
    compare(list.count,7)
    verify(window.heightSamples.length>3)
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
    wait(350);var returned=item(1);verify(returned!==departing);verify(!returned.retired);compare(returned.opacity,1);compare(returned.entranceOffset,0)
    root.entries=[];root.rebuild();tryVerify(function(){return list.contentHeight===0})
   }
   function test_search_reorder_and_virtualization(){try{
    var rows=[];for(var i=0;i<40;i++)rows.push(row(String(i+1)+"-1","App "+i,1000-i))
    root.entries=rows;root.rebuild();tryCompare(list,"count",80);wait(250)
    var first=item(0);root.entries[1]=Object.assign({},root.entries[1],{timestamp:2000});root.rebuild();wait(200)
    compare(list.itemAtIndex(2),first);compare(first.opacity,1)
    list.positionViewAtEnd();wait(40);var last=item(79);compare(last.opacity,1);compare(last.entranceOffset,0)
    root.filter="no matches";root.rebuild();tryCompare(list,"count",0);wait(200)
    root.filter="App 3";root.rebuild();tryVerify(function(){return list.count>0});wait(220)
    list.positionViewAtBeginning();root.compact=false;list.width=320;Color.background="#eff1f5";Color.foreground="#4c4f69";wait(100);capture("narrow-light-search")
    root.keyboardNavigation=true;root.cursorIndex=1;wait(40)
    root.filter="";root.rebuild();tryCompare(list,"count",80)
   }catch(e){console.log("FAILED",e.message,e.stack);throw e}}
  }
 }
}
'''.replace('DELEGATE',delegate))
home=base/'home';home.mkdir();runtime=base/'runtime';runtime.mkdir(mode=0o700)
desktop='--desktop' in sys.argv
env=dict(os.environ,HOME=str(home),QT_QPA_PLATFORM='wayland' if desktop else 'offscreen',QT_QUICK_BACKEND='rhi' if desktop else 'software',QT_QPA_PLATFORMTHEME='basic')
if not desktop:
 env['XDG_RUNTIME_DIR']=str(runtime)
 for key in ['DISPLAY','WAYLAND_DISPLAY','HYPRLAND_INSTANCE_SIGNATURE']:env.pop(key,None)
proc=subprocess.Popen(['dbus-run-session','--','qs','-p',str(app),'--no-color'],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,start_new_session=True)
try:output=proc.communicate(timeout=25)[0]
except subprocess.TimeoutExpired:os.killpg(proc.pid,signal.SIGTERM);output=proc.communicate(timeout=3)[0]
print(output);print('Captures:',app)
assert proc.returncode==0 and 'CENTER_MOTION 6 passed 0 failed' in output
