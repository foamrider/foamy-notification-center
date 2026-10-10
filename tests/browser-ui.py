"""Exercise local favicon lookup and both icon fallbacks on the real QML card."""
from contextlib import closing
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import sys
import tempfile

from favicon_test import png

source = Path(__file__).resolve().parents[1]
center = source.name == 'foamy-notification-center'
base = Path(tempfile.mkdtemp(prefix='foamy-browser-ui-'))
app = base / 'app'
app.mkdir()
for name in ['Commons', 'Ui']:
    (app / name).symlink_to('/usr/share/omarchy/shell/' + name, target_is_directory=True)
(app / 'plugin').symlink_to(source, target_is_directory=True)
failed_helper = (source / 'components/BrowserIcons.qml').read_text().replace('import "../BrowserIdentity.js"', 'import "plugin/BrowserIdentity.js"')
failed_helper = failed_helper.replace('    command: ["python3", Qt.resolvedUrl("../bin/browser-favicon.py").toString().replace(/^file:\\/\\//, "")]', '    command: ["/nonexistent/foamy-favicon-test-helper"]')
assert '/nonexistent/foamy-favicon-test-helper' in failed_helper
(app / 'FailedBrowserIcons.qml').write_text(failed_helper)
(app / 'fallback.svg').write_text('<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"><rect width="32" height="32" rx="6" fill="#e05555"/><text x="16" y="23" text-anchor="middle" fill="white" font-size="22">V</text></svg>')
home = base / 'home'
database = home / '.config/vivaldi/Default/Favicons'
database.parent.mkdir(parents=True)
with closing(sqlite3.connect(database)) as db:
    db.executescript('CREATE TABLE icon_mapping (page_url TEXT, icon_id INTEGER); CREATE TABLE favicon_bitmaps (icon_id INTEGER, image_data BLOB, width INTEGER, height INTEGER, last_updated INTEGER);')
    db.execute('INSERT INTO icon_mapping VALUES (?, 1)', ('https://teams.example.com/chat',))
    db.execute('INSERT INTO favicon_bitmaps VALUES (1, ?, 32, 32, 100)', (png(),))
    db.commit()

# Keep the browser's exclusive cache lock throughout the actual QML/helper flow.
browser = sqlite3.connect(database)
browser.execute('PRAGMA locking_mode=EXCLUSIVE')
browser.execute('BEGIN EXCLUSIVE')
browser.commit()

widget = '''NotificationStackHeader {
      id: card; x: 20; y: 20; width: 420
      compact: false
      group: Object.assign({}, root.groups[0], {appIcon:root.entry.appIcon,favicon:root.iconSource})
    }''' if center else '''NotificationCard {
      id: card; x: 20; y: 20; width: 420
      app:"Vivaldi"; appIcon:root.entry.appIcon; favicon:root.iconSource
      summary:"Design review";body:"teams.example.com\\nThe updated files are ready to review."
    }'''
model_import = 'import "plugin/Model.js" as Model\nimport "plugin/BrowserIdentity.js" as BrowserIdentity\n' if center else ''
model_properties = '''  property string grouping:"hostname"
  readonly property var groups:Model.groupsFor([entry,{key:"900-1",app:"Vivaldi",body:"mail.example.com\\nNew mail",timestamp:900}],"",grouping,BrowserIdentity)
''' if center else ''
identity_entry = 'groups[0].iconEntry' if center else 'entry'
model_check = '''        compare(root.groups.length,2);compare(root.groups[0].label,"teams.example.com")
        root.grouping="browser";compare(root.groups.length,1);compare(root.groups[0].iconEntry,null);compare(root.iconSource,"");verify(appIcon.visible)
        root.grouping="none";compare(root.groups.length,2)
        root.grouping="hostname";compare(root.groups.length,2)
        tryCompare(favicon,"status",Image.Ready)
''' if center else ''
(app / 'shell.qml').write_text('''import QtQuick
import QtTest
import Quickshell
import qs.Commons
import "plugin/components"
MODEL_IMPORT
ShellRoot {
  id: root
  MODEL_PROPERTIES
  property var entry:({key:"1000-1",timestamp:1000,app:"Vivaldi",body:"teams.example.com\\nNew message",appIcon:Qt.resolvedUrl("fallback.svg").toString()})
  property string overrideSource:"resolved"
  readonly property string iconSource:overrideSource==="resolved" ? resolver.source(IDENTITY_ENTRY) : overrideSource
  BrowserIcons { id:resolver }
  FailedBrowserIcons { id:failedResolver }
  FloatingWindow {
    id:window;visible:true;implicitWidth:500;implicitHeight:250;color:Color.background
    WIDGET
    property bool ready:false
    Timer {interval:400;running:true;onTriggered:window.ready=true}
    TestCase {
      name:"BrowserIcons";when:window.ready
      onCompletedChanged:if(completed)console.log("BROWSER_UI",qtest_results.passCount,"passed",qtest_results.failCount,"failed")
      function capture(name){var done=false;card.grabToImage(function(r){verify(r.saveToFile(Qt.resolvedUrl(name+".png").toString().replace("file://","")));done=true});tryVerify(function(){return done})}
      function test_failed_helper_start_does_not_block_the_queue(){
        var row={app:"Vivaldi",body:"failed.example.com\\nMessage"}
        failedResolver.warm([row])
        verify(failedResolver.active!==null)
        tryVerify(function(){return failedResolver.active===null},5000)
        compare(failedResolver.requests.length,0);compare(Object.keys(failedResolver.pending).length,0)
        compare(failedResolver.source(row),"")
        verify(Object.keys(failedResolver.icons).length===1)
      }
      function test_local_cache_and_fallback(){
        var favicon=findChild(card,"notificationFavicon"),appIcon=findChild(card,"notificationAppIcon")
        resolver.warm([root.entry,{app:"Vivaldi",body:"missing.example.com\\nMessage"}])
        tryVerify(function(){return root.iconSource.indexOf("file://")===0})
        tryCompare(favicon,"status",Image.Ready);tryCompare(appIcon,"status",Image.Ready)
        verify(favicon.visible);verify(!appIcon.visible);capture("favicon-wide-dark")
        card.width=280;waitForRendering(card);capture("favicon-narrow-dark")
        Color.background="#eff1f5";Color.foreground="#4c4f69";Color.accent="#1e66f5";card.width=420;waitForRendering(card);capture("favicon-wide-light")
MODEL_CHECK
        root.overrideSource=Qt.resolvedUrl("missing.png").toString()
        tryCompare(favicon,"status",Image.Error);verify(!favicon.visible);verify(appIcon.visible);capture("fallback-missing")
        root.overrideSource="";verify(appIcon.visible);capture("fallback-disabled")
        tryVerify(function(){return resolver.requests.length===0 && resolver.active===null})
        compare(resolver.source({app:"Vivaldi",body:"missing.example.com\\nMessage"}),"")
      }
    }
  }
}
'''.replace('WIDGET', widget).replace('MODEL_IMPORT', model_import).replace('MODEL_PROPERTIES', model_properties).replace('IDENTITY_ENTRY', identity_entry).replace('MODEL_CHECK', model_check))
runtime = base / 'runtime'
runtime.mkdir(mode=0o700)
env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home / '.config'), XDG_CACHE_HOME=str(home / '.cache'), XDG_STATE_HOME=str(home / '.local/state'), XDG_RUNTIME_DIR=str(runtime), QT_QPA_PLATFORM='offscreen', QT_QUICK_BACKEND='software', QT_QPA_PLATFORMTHEME='basic', QT_STYLE_OVERRIDE='Fusion')
for key in ['DISPLAY', 'WAYLAND_DISPLAY', 'HYPRLAND_INSTANCE_SIGNATURE']:
    env.pop(key, None)
process = subprocess.Popen(['dbus-run-session', '--', 'quickshell', '-p', str(app), '--no-color'], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
try:
    output = process.communicate(timeout=15)[0]
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGTERM)
    output = process.communicate(timeout=3)[0]
finally:
    browser.close()
print(output)
print('Browser captures:', app)
assert process.returncode == 0 and 'BROWSER_UI 3 passed 0 failed' in output
