const assert = require("node:assert/strict")
const { spawnSync } = require("node:child_process")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const vm = require("node:vm")
const test = require("node:test")
const Model = require("../Model.js")

const panel = fs.readFileSync(path.join(__dirname, "../Panel.qml"), "utf8")
const start = panel.indexOf("  function activate(")
const activate = panel.slice(start, panel.indexOf("\n  }", start) + 4)

function view(mode = "Auto") {
  const state = vm.createContext({
    clickAction: mode, Model, store: { focusNotification(row) { state.focusProc.running = true; state.focusProc.row = row; state.delegated.push(row) } }, omarchyPath: "/omarchy", focusProc: {},
    actions: [], images: [], delegated: [], removed: [], closed: 0,
    Util: { execArgv(argv) { state.actions.push(argv) } },
    Quickshell: { execDetached(argv) { state.images.push(argv) } },
    remove(key) { state.removed.push(key) }, close() { state.closed++ }
  })
  state.root = state
  vm.runInContext(activate, state)
  return state
}

function fixture(t) {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), "notification-actions-"))
  t.after(() => fs.rmSync(temp, { recursive: true, force: true }))
  const source = path.join(temp, "source")
  const store = path.join(temp, "store")
  fs.mkdirSync(path.join(source, "history"), { recursive: true })
  const env = { ...process.env, NC_SRC_DIR: source, NC_SRC_HISTORY: path.join(source, "history"),
    NC_STORE: store, NC_PREVIEWS: "0" }
  const script = path.join(__dirname, "../bin/notification-center")
  return { temp, source, archive: path.join(store, "archive.jsonl"), run(command) {
    const result = spawnSync(script, [command], { env, encoding: "utf8" })
    assert.equal(result.status, 0, result.stderr)
    return JSON.parse(result.stdout)
  } }
}

function assertDisarmed(entries) {
  for (const row of entries) {
    assert.equal(Object.hasOwn(row, "exec"), false)
    assert.equal(Object.hasOwn(row, "execArgv"), false)
  }
}

test("sync discards sender commands from live and historical notifications; stacked clicks delegate the selected image", t => {
  const f = fixture(t)
  const timestamp = Date.now()
  const files = ["/tmp/a picture.png", "/tmp/another picture.JPEG"]
  for (let i = 0; i < 2; i++) {
    const argv = ["bash", "-c", "arbitrary sender command", `file://${files[i]}`]
    fs.writeFileSync(path.join(i ? f.source : path.join(f.source, "history"), `${timestamp + i}-${i}.json`),
      JSON.stringify({ timestamp: timestamp + i, app: "Actions", summary: "Picture",
        exec: "arbitrary legacy command", execArgv: i ? JSON.stringify(argv) : argv }))
  }
  f.run("sync")
  const entries = f.run("list")
  assert.equal(entries.length, 2)
  assertDisarmed(entries)
  assertDisarmed(fs.readFileSync(f.archive, "utf8").trim().split("\n").map(JSON.parse))
  const state = view()
  const collapsed = Model.stackRows(entries, {}, "").filter(row => row.kind === "message")
  assert.equal(collapsed.length, 1)
  state.activate(collapsed[0].entry)
  const expanded = Model.stackRows(entries, { Actions: true }, "").filter(row => row.kind === "message")
  state.activate(expanded[1].entry)
  assert.equal(state.actions.length, 0)
  assert.deepEqual(Array.from(state.delegated, row => row.file), [files[1], files[0]])
  assert.equal(state.images.length, 0)
  assert.equal(state.removed.length, 0)
  assert.equal(state.closed, 0)
})

test("sync and backfill strip both command fields from old archives and retain only image paths", t => {
  const f = fixture(t)
  const timestamp = Date.now()
  const commands = [
    { execArgv: ["bash", "-c", "command"] },
    { execArgv: JSON.stringify(["viewer", "file:///tmp/image with spaces.webp"]) },
    { exec: "viewer /tmp/legacy.gif" },
    { file: "https://example.test/picture.png", execArgv: "bad JSON" },
    { file: "/tmp/run.desktop", execArgv: [] },
    { file: "/tmp/valid.png", exec: "command", execArgv: ["command"] },
  ]
  f.run("list")
  for (const command of ["sync", "backfill"]) {
    // Pretty field spacing exercises migration detection in imported archives.
    const rows = commands.map((fields, i) => ({ key: `${timestamp}-${i}`, timestamp, ...fields }))
    fs.writeFileSync(f.archive, rows.map(row => JSON.stringify(row).replace(/":/g, '" : ')).join("\n") + "\n")
    f.run(command)
    const entries = fs.readFileSync(f.archive, "utf8").trim().split("\n").map(JSON.parse)
    assertDisarmed(entries)
    const byKey = new Map(entries.map(row => [row.key, row]))
    assert.deepEqual(rows.map(row => byKey.get(row.key).file), ["", "/tmp/image with spaces.webp", "/tmp/legacy.gif", "", "", "/tmp/valid.png"])
    const before = fs.readFileSync(f.archive, "utf8")
    f.run(command)
    assert.equal(fs.readFileSync(f.archive, "utf8"), before)
  }
})

test("execArgv-only archives are automatically disarmed", t => {
  const f = fixture(t)
  f.run("list")
  const timestamp = Date.now()
  fs.writeFileSync(f.archive, JSON.stringify({ key: `${timestamp}-1`, timestamp,
    execArgv: '["bash", "-c", "command"]' }) + "\n")
  f.run("sync")
  const entries = f.run("list")
  assert.equal(entries.length, 1)
  assertDisarmed(entries)
})

test("old commands are ignored before migration, including shell, URL and malformed vectors", () => {
  for (const execArgv of ['["bash", "-c", "command"]', '["xdg-open", "https://example.test/"]',
    ["command"], "bad JSON", "null", "{}", "[]", '["xdg-open", 3]', undefined]) {
    const state = view()
    state.activate({ key: "100-1", app: "Browser", execArgv, exec: "command" })
    assert.equal(state.actions.length + state.images.length, 0)
    assert.equal(state.focusProc.row.app, "Browser")
    assert.equal(state.removed.length, 0)
  }
})

test("only absolute raster paths can reach the fixed opener; click settings still override it", () => {
  for (const file of [undefined, null, {}, [], "", "relative.png", "-option.png", "https://example.test/a.png",
    "file:///tmp/a.png", "/tmp/a.desktop", "/tmp/a.png.desktop", "/tmp/a.svg", "/tmp/a.png\n", "/tmp/a\u0000.png",
    '/tmp/a".png', "/tmp/a'.png"]) {
    assert.equal(Model.isPreviewFile(file), false)
    const state = view()
    state.activate({ key: "100-1", app: "Browser", file })
    assert.equal(state.images.length + state.actions.length, 0)
    assert.equal(state.focusProc.running, true)
  }
  for (const file of ["/tmp/preview.png", "/tmp/spaced image.JPG", "/tmp/a.gif", "/tmp/a.webp", "/tmp/a;literal.png"]) {
    const row = { key: "100-1", app: "Browser", file, execArgv: '["bash", "-c", "command"]' }
    const auto = view()
    auto.activate(row)
    assert.equal(auto.focusProc.row, row)
    assert.deepEqual(Model.fileCommand(row), ["xdg-open", file])
    assert.equal(auto.actions.length + auto.images.length + auto.removed.length, 0)
    assert.equal(auto.closed, 0)
    const focus = view("Focus the app")
    focus.activate(row)
    assert.equal(focus.actions.length + focus.images.length, 0)
    assert.equal(focus.focusProc.running, true)
    const nothing = view("Nothing")
    nothing.activate(row)
    assert.equal(nothing.actions.length + nothing.images.length + nothing.removed.length, 0)
    assert.equal(nothing.focusProc.running, undefined)
    assert.equal(nothing.closed, 0)
  }
})

test('Center delegates default action and browser focus without replaying archived commands or dismissing early',()=>{
 const state=view(),calls=[]
 state.store={focusNotification(row){calls.push(row)}}
 const row={key:'100-1',app:'Vivaldi',body:'teams.microsoft.com',execArgv:'["unsafe"]'}
 state.activate(row)
 assert.equal(calls[0],row);assert.equal(state.removed.length,0);assert.equal(state.closed,0);assert.equal(state.actions.length,0)
})

const serviceSource = fs.readFileSync(path.join(__dirname, "../Service.qml"), "utf8")
function focusService() {
 const state=vm.createContext({focusProc:{running:false},focusEntry:null,focusError:"",invokingDefault:false,openingFile:false,Model,
  Qt:{resolvedUrl(path){return "file:///plugin/"+path}},omarchyPath:"/omarchy",removed:[],completed:0,console,
  remove(key){state.removed.push(key)},focusCompleted(){state.completed++}})
 state.root=state
 for(const name of ["focusNotification","focusSendingApp","finishFocus"]) {
  const start=serviceSource.indexOf(`  function ${name}(`)
  vm.runInContext(serviceSource.slice(start,serviceSource.indexOf("\n  }",start)+4),state)
 }
 return state
}
test("live actions skip focus; missing, stock and older daemons use stock focus",()=>{
 for(const output of ["unavailable","Target not found.","Function not found.",""]) {
  const state=focusService();state.focusNotification({key:"100-1",app:"Vivaldi"})
  assert.deepEqual(Array.from(state.focusProc.command),["omarchy-shell","foamy.notifications","invokeDefault","100-1"])
  state.focusProc.running=false;state.finishFocus(0,0,output)
  assert.deepEqual(Array.from(state.focusProc.command),["bash","/plugin/bin/focus-notification-app","/omarchy","Vivaldi"])
  assert.equal(state.removed.length,0)
  state.focusProc.running=false;state.finishFocus(0,0,"")
  assert.deepEqual(Array.from(state.removed),["100-1"]);assert.equal(state.completed,1)
 }
 const state=focusService();state.focusNotification({key:"100-1",app:"Vivaldi"})
 state.focusProc.running=false;state.finishFocus(0,0,"invoked")
 assert.equal(state.invokingDefault,true);assert.equal(state.removed.length,0);assert.equal(state.completed,1)
})
test("focus failure and busy action retain history; focus-only skips the callback",()=>{
 const state=focusService();state.focusNotification({key:"100-1",app:"Vivaldi"},false)
 assert.equal(state.invokingDefault,false)
 state.focusProc.running=false;state.finishFocus(1,0,"")
 assert.equal(state.removed.length,0);assert.ok(state.focusError)
 state.focusNotification({key:"100-1",app:"Vivaldi"})
 state.focusProc.running=false;state.finishFocus(0,0,"busy")
 assert.equal(state.removed.length,0);assert.equal(state.focusEntry,null);assert.ok(state.focusError)
})
test("invalid app identity cannot become a stock focus regex",()=>{
 const state=focusService();state.focusNotification({key:"100-1",app:".*"},false)
 assert.equal(state.focusProc.running,false);assert.ok(state.focusError)
 state.focusNotification({key:"100-1",app:"org.example.App"},false)
 assert.equal(state.focusProc.command[3],"org\\.example\\.App")
})

 test("no window silently retains history and clears stale focus feedback",()=>{
 const state=focusService();state.focusError="old error"
 state.focusNotification({key:"100-1",app:"Background"},false)
 state.focusProc.running=false;state.finishFocus(3,0,"")
 assert.equal(state.focusError,"");assert.equal(state.focusEntry,null)
 assert.equal(state.removed.length,0);assert.equal(state.completed,0)
 })
 test("focus helper distinguishes absent windows from failed queries and focus",t=>{
 const temp=fs.mkdtempSync(path.join(os.tmpdir(),"notification-focus-"))
 t.after(()=>fs.rmSync(temp,{recursive:true,force:true}))
 fs.mkdirSync(path.join(temp,"bin"))
 fs.writeFileSync(path.join(temp,"hyprctl"),'#!/bin/bash\n[[ ${QUERY_FAIL:-0} == 0 ]] || exit 1\nprintf "%s" "$CLIENTS"\n',{mode:0o755})
 fs.writeFileSync(path.join(temp,"bin/omarchy-hyprland-focus-app"),'#!/bin/bash\nexit "${FOCUS_CODE:-0}"\n',{mode:0o755})
 const helper=path.join(__dirname,"../bin/focus-notification-app")
 const run=(clients,extra={})=>spawnSync("bash",[helper,temp,"Background"],{env:{...process.env,PATH:temp+":"+process.env.PATH,CLIENTS:clients,...extra},encoding:"utf8"}).status
 assert.equal(run("[]"),3)
 assert.equal(run("bad JSON"),5)
 assert.equal(run("[]",{QUERY_FAIL:"1"}),1)
 const clients=JSON.stringify([{class:"Background",address:"0x1"}])
 assert.equal(run(clients),0)
 assert.equal(run(clients,{FOCUS_CODE:"1"}),1)
 })


test("live image actions win; expired screenshots use Tensaku and other pictures use the viewer", () => {
 for (const [fileAction, program] of [["edit-screenshot", "omasnap"], ["", "xdg-open"], ["arbitrary command", "xdg-open"]]) {
  const row = {key:"100-1",app:"omarchy-action",file:"/tmp/image with spaces.png",fileAction,execArgv:'["unsafe"]'}
  const live = focusService(); live.focusNotification(row)
  live.focusProc.running=false; live.finishFocus(0,0,"invoked")
  assert.equal(live.completed,1); assert.equal(live.removed.length,0)
  const expired = focusService(); expired.focusNotification(row)
  expired.focusProc.running=false; expired.finishFocus(0,0,"unavailable")
  assert.deepEqual(Array.from(expired.focusProc.command),["bash","/plugin/bin/open-notification-image",program==="omasnap"?"edit-screenshot":"view-image",row.file])
  assert.equal(expired.removed.length,0)
  expired.focusProc.running=false; expired.finishFocus(0,0,"")
  assert.deepEqual(Array.from(expired.removed),[row.key]); assert.equal(expired.completed,1)
 }
})
test("failed image open retains history for retry, including exit code 3", () => {
 for(const code of [1,3,127]) {
  const state=focusService(); state.focusNotification({key:"100-1",app:"omarchy-action",file:"/tmp/a.png",fileAction:"edit-screenshot"})
  state.focusProc.running=false; state.finishFocus(1,0,"")
  assert.deepEqual(Array.from(state.focusProc.command),["bash","/plugin/bin/open-notification-image","edit-screenshot","/tmp/a.png"])
  state.focusProc.running=false; state.finishFocus(code,0,"")
  assert.equal(state.removed.length,0); assert.equal(state.completed,0); assert.match(state.focusError,/Could not open the image/)
 }
})
test("only a two-argument Tensaku image action survives as a fixed intent, including migration", t => {
 const f=fixture(t),timestamp=Date.now(),file="/tmp/screenshot with spaces.png"
 const commands=[["tensaku-edit",file],["/usr/bin/tensaku-edit",file],["tensaku-edit",file,"extra"],["/tmp/tensaku-edit",file],["bash","-c","tensaku-edit",file],["other-editor",file],["tensaku-edit","/tmp/a.desktop"]]
 for(let i=0;i<commands.length;i++) fs.writeFileSync(path.join(f.source,`${timestamp}-${i}.json`),JSON.stringify({timestamp,app:"omarchy-action",execArgv:JSON.stringify(commands[i])}))
 f.run("sync")
 let rows=f.run("list"),byKey=new Map(rows.map(row=>[row.key,row]))
 assertDisarmed(rows)
 assert.deepEqual(commands.map((_,i)=>byKey.get(`${timestamp}-${i}`).fileAction),["edit-screenshot","edit-screenshot","","","","",""])
 // Upgrading an unchanged source must add the intent without requiring a new notification.
 fs.writeFileSync(f.archive,rows.map(({fileAction,...row})=>JSON.stringify(row)).join("\n")+"\n")
 f.run("sync"); assert.equal(f.run("list").filter(row=>row.fileAction==="edit-screenshot").length,2)
 // An old archive with argv migrates, while an already disarmed archive cannot guess the editor.
 fs.writeFileSync(f.archive,JSON.stringify({key:`${timestamp}-99`,timestamp,execArgv:JSON.stringify(commands[0])})+"\n")
 f.run("backfill"); rows=f.run("list"); assertDisarmed(rows)
 assert.equal(rows[0].fileAction,"edit-screenshot"); assert.deepEqual(Model.fileCommand(rows[0]),["omasnap",file])
})

test("fixed image launcher preserves spaces, rejects unsafe paths and reports startup failures without waiting for the editor", t => {
 const temp=fs.mkdtempSync(path.join(os.tmpdir(),"notification-image-open-"))
 t.after(()=>fs.rmSync(temp,{recursive:true,force:true}))
 const file=path.join(temp,"a picture.png"),marker=path.join(temp,"opened")
 fs.writeFileSync(file,"fixture")
 for(const program of ["tensaku-edit","xdg-open"]) fs.writeFileSync(path.join(temp,program),'#!/bin/bash\nprintf "%s" "$1" > "$MARKER"\nexit "${OPEN_CODE:-0}"\n',{mode:0o755})
 const helper=path.join(__dirname,"../bin/open-notification-image")
 const run=(intent,image,extra={})=>spawnSync("/usr/bin/bash",[helper,intent,image],{env:{...process.env,PATH:temp+":"+process.env.PATH,MARKER:marker,...extra},encoding:"utf8",timeout:2000})
 for(const intent of ["edit-screenshot","view-image"]) {
  assert.equal(run(intent,file).status,0);assert.equal(fs.readFileSync(marker,"utf8"),file)
  assert.equal(run(intent,file,{OPEN_CODE:"3"}).status,3)
 }
 for(const invalid of ["-option.png","/tmp/a.png\n","/tmp/a.desktop","/tmp/a.svg","https://example.test/a.png"]) assert.equal(run("edit-screenshot",invalid).status,2)
 assert.equal(run("edit-screenshot",path.join(temp,"missing.png")).status,4)
 assert.equal(run("arbitrary-command",file).status,2)
 const unavailable=path.join(temp,"unavailable");fs.mkdirSync(unavailable)
 fs.symlinkSync("/usr/bin/jq",path.join(unavailable,"jq"))
 assert.equal(run("edit-screenshot",file,{PATH:unavailable}).status,127)
 // A long-lived editor must not hold the center's process or output pipes open.
 fs.writeFileSync(path.join(temp,"tensaku-edit"),'#!/bin/bash\nprintf "%s" "$1" > "$MARKER"\nsleep 1\n',{mode:0o755})
 const start=Date.now();assert.equal(run("edit-screenshot",file).status,0);assert.ok(Date.now()-start<700)
})

test('Omasnap screenshot vectors become a fixed intent and opener falls back in order',t=>{
 const f=fixture(t),stamp=Date.now(),file=path.join(f.temp,'shot with spaces.png')
 fs.writeFileSync(file,'fixture')
 for(const [i,argv] of [[0,['omasnap','file://'+file]],[1,['/usr/bin/omasnap',file]],[2,['/tmp/omasnap',file]],[3,['omasnap',file,'--extra']]]) {
  fs.writeFileSync(path.join(f.source,`${stamp}-${i}.json`),JSON.stringify({timestamp:stamp,app:'omarchy-action',summary:'Screenshot',body:'Edit',execArgv:JSON.stringify(argv)}))
 }
 f.run('sync');assert.equal(f.run('list').filter(row=>row.fileAction==='edit-screenshot').length,2)
 const bin=path.join(f.temp,'bin');fs.mkdirSync(bin)
 for(const name of ['jq','sleep']) fs.symlinkSync('/usr/bin/'+name,path.join(bin,name))
 for(const name of ['omasnap','tensaku-edit','xdg-open']) fs.writeFileSync(path.join(bin,name),'#!/bin/bash\nprintf "%s" "'+name+'" > "$MARKER"\n',{mode:0o755})
 const marker=path.join(f.temp,'marker'),helper=path.join(__dirname,'../bin/open-notification-image')
 for(const name of ['omasnap','tensaku-edit','xdg-open']) {
  const r=spawnSync('/usr/bin/bash',[helper,'edit-screenshot',file],{env:{...process.env,PATH:bin,MARKER:marker},encoding:'utf8'})
  assert.equal(r.status,0,r.stderr);assert.equal(fs.readFileSync(marker,'utf8'),name);fs.unlinkSync(path.join(bin,name))
 }
})
