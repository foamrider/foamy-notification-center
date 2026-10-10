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
    clickAction: mode, Model, store: { focusNotification(row) { state.focusProc.running = true; state.focusProc.row = row } }, omarchyPath: "/omarchy", focusProc: {},
    actions: [], images: [], removed: [], closed: 0,
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

test("sync discards sender commands from live and historical notifications; stacked clicks only open image paths", t => {
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
  assert.deepEqual(state.images.map(argv => Array.from(argv)), [["xdg-open", files[1]], ["xdg-open", files[0]]])
  assert.deepEqual(Array.from(state.removed), [collapsed[0].entry.key, expanded[1].entry.key])
  assert.equal(state.closed, 2)
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
    assert.deepEqual(Array.from(auto.images[0]), ["xdg-open", file])
    assert.equal(auto.actions.length, 0)
    assert.deepEqual(Array.from(auto.removed), ["100-1"])
    assert.equal(auto.closed, 1)
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
 const state=vm.createContext({focusProc:{running:false},focusEntry:null,focusError:"",invokingDefault:false,
  Qt:{resolvedUrl(){return "file:///plugin/bin/focus-notification-app"}},omarchyPath:"/omarchy",removed:[],completed:0,console,
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
