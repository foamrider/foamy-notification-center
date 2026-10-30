const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")
const test = require("node:test")
const Model = require("../Model.js")

// Exercise the service's actual handlers with delayed process output.
const source = fs.readFileSync(path.join(__dirname, "../Service.qml"), "utf8")
function service() {
  const context = vm.createContext({
    entries: [], removedKeys: {}, pageSize: 500, archiveRevision: 0,
    pendingRemovalKeys: [], activeRemovalKeys: [], removalError: "",
    removeProc: { running: false, command: [] },
    entriesReset() {}, entryAdded() {}, storeCommand(args) { return args },
    Quickshell: { execDetached() {} },
    quietRemovalKeys: {}, foamySource: true, peer: { call() {} },
    searchQuery: "", listLimit: 500, hasMore: false, unreadSource: [], reloadArchive: { restart() {} }
  })
  context.root = context
  for (const name of ["remove", "removeMany", "startRemoval", "absorb", "visibleEntries"]) {
    const start = source.indexOf(`  function ${name}(`)
    assert.notEqual(start, -1)
    const end = source.indexOf("\n  }", start) + 4
    vm.runInContext(source.slice(start, end), context)
  }
  return context
}

test("delayed watcher and list results cannot restore a removed unread entry", () => {
  const state = service()
  const clicked = { key: "300-1", timestamp: 300, urgency: 2 }
  const retained = { key: "200-2", timestamp: 200, urgency: 1 }
  state.absorb(JSON.stringify(retained))
  state.absorb(JSON.stringify(clicked))
  state.remove(clicked.key)
  state.absorb(JSON.stringify(clicked))
  state.entries = state.visibleEntries([clicked, retained])
  assert.deepEqual(Array.from(state.entries, entry => entry.key), [retained.key])
  assert.deepEqual(Model.unreadState(state.entries, 0), {
    unread: 1, hasCriticalUnread: false
  })
  state.remove(retained.key)
  state.absorb(JSON.stringify(retained))
  assert.equal(Model.unreadState(state.entries, 0).unread, 0)
})

test("stack dismissal batches captured keys and retains later arrivals", () => {
  const state = service()
  state.entries = [
    { key: "300-1", timestamp: 300, app: "Chat" },
    { key: "200-1", timestamp: 200, app: "Chat" },
    { key: "100-1", timestamp: 100, app: "Other" }
  ]
  state.removeMany(["300-1", "200-1", "300-1"])
  assert.deepEqual(Array.from(state.removeProc.command), ["remove", "300-1", "200-1"])
  state.absorb(JSON.stringify({ key: "400-1", timestamp: 400, app: "Chat" }))
  state.absorb(JSON.stringify({ key: "300-1", timestamp: 300, app: "Chat" }))
  assert.deepEqual(Array.from(state.entries, entry => entry.key), ["400-1", "100-1"])
  state.remove("100-1")
  assert.deepEqual(Array.from(state.pendingRemovalKeys), ["100-1"])
})

test("a click before first ingestion stays removed while new notifications arrive", () => {
  const state = service()
  state.remove("300-1")
  state.absorb(JSON.stringify({ key: "300-1", timestamp: 300 }))
  state.absorb(JSON.stringify({ key: "400-1", timestamp: 400 }))
  assert.deepEqual(Array.from(state.entries, entry => entry.key), ["400-1"])
})

test("failed dismissal releases only failed tombstones and reloads for retry", () => {
  const state = service()
  const failed = { key: "300-1", timestamp: 300 }
  const removed = { key: "200-1", timestamp: 200 }
  state.entries = [failed, removed]
  state.remove(removed.key)
  state.removeProc.running = false
  state.remove(failed.key)
  state.removeProc.running = false
  let reloads = 0
  state.load = () => { reloads++; state.entries = state.visibleEntries([failed, removed]) }
  state.removeErrors = { text: "Read-only archive" }
  state.console = { warn() {} }
  state.exitCode = 1
  state.exitStatus = 0
  const start = source.indexOf("    onExited: function(exitCode, exitStatus) {", source.indexOf("    id: removeProc"))
  const end = source.indexOf("\n    }", start)
  vm.runInContext(source.slice(source.indexOf("{", start) + 1, end), state)
  assert.equal(reloads, 1)
  assert.match(state.removalError, /Try again/)
  assert.deepEqual(Array.from(state.entries, entry => entry.key), [failed.key])
  assert.equal(state.removedKeys[failed.key], undefined)
  assert.equal(state.removedKeys[removed.key], true)
  state.remove(failed.key)
  assert.deepEqual(Array.from(state.removeProc.command), ["remove", failed.key])
})

test("callback cleanup runs only after durable dismissal and batches exact keys, one batch at a time", () => {
 const state=service(),calls=[]
 let answer=true
 state.releaseQueue=[];state.releaseBusy=false;state.releaseRetry={running:false,restart(){this.running=true}}
 // Contract v2: Foamy is asked over its IPC (FoamyPeerIpc), never by deleting its files.
 state.peer.call=(target,method,args,done)=>{calls.push([target,method,...args]);done(answer,answer?'ok':'')}
 for(const name of ["releaseNotificationActions","pumpReleases"]) {
  const start=source.indexOf(`  function ${name}(`)
  vm.runInContext(source.slice(start,source.indexOf("\n  }",start)+4),state)
 }
 const keys=Array.from({length:1001},(_,i)=>`${i+1}-1`)
 state.releaseNotificationActions(keys)
 // All 11 batches go out (more than FoamyPeerIpc's 8 concurrent CLI calls), in order.
 assert.equal(calls.length,11)
 assert.equal(calls[0][2].split(',').length,100)
 assert.deepEqual(calls[10],["foamy.notifications","releaseHistory","1001-1"])
 // A failed batch stays queued for a retry instead of being dropped.
 answer=false;state.releaseNotificationActions(['5-5'])
 assert.equal(state.releaseQueue.length,1);assert.equal(state.releaseRetry.running,true)
 answer=true;state.releaseRetry.running=false;state.pumpReleases()
 assert.equal(state.releaseQueue.length,0)
 state.activeRemovalKeys=['100-1'];state.removeErrors={text:''};state.exitCode=0;state.exitStatus=0
 const handler=source.indexOf("    onExited: function(exitCode, exitStatus) {",source.indexOf("    id: removeProc"))
 const before=calls.length
 vm.runInContext(source.slice(source.indexOf("{",handler)+1,source.indexOf("\n    }",handler)),state)
 assert.equal(calls[before][2],"100-1")
 // Keys Foamy itself reported as handled are not sent back to it.
 state.quietRemovalKeys={'100-2':true};state.activeRemovalKeys=['100-2']
 vm.runInContext(source.slice(source.indexOf("{",handler)+1,source.indexOf("\n    }",handler)),state)
 assert.equal(calls.length,before+1)
 state.foamySource=false;state.releaseNotificationActions(['1-1']);assert.equal(calls.length,before+1)
})

test("a second Clear all while one runs is queued, not dropped", () => {
 const state=service()
 state.clearProc={running:true,cut:""};state.clearPending=false;state.unreadSource=[]
 const start=source.indexOf("  function clearAll(")
 vm.runInContext(source.slice(start,source.indexOf("\n  }",start)+4),state)
 state.clearAll()
 assert.equal(state.clearPending,true)
 const exit=source.indexOf("    onExited: function(code, status) {",source.indexOf("    id: clearProc"))
 const body=source.slice(source.indexOf("{",exit)+1,source.indexOf("\n    }",exit))
 const proc={cut:"1",running:false}
 const ctx=vm.createContext({code:0,status:0,cut:"1",running:false,root:{foamySource:false,clearPending:true,load(){ctx.loaded=true}},peer:{call(){}},String,Date})
 vm.runInContext("(function(){"+body+"})()",ctx)
 assert.equal(ctx.running,true,"the queued clear runs after the active one")
 assert.equal(ctx.root.clearPending,false)
})
