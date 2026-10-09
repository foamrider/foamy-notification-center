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
    Quickshell: { execDetached() {} }
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

test("callback cleanup runs only after durable dismissal and batches exact keys", () => {
 const state=service(),calls=[]
 state.Quickshell.execDetached=argv=>calls.push(Array.from(argv))
 const start=source.indexOf("  function releaseNotificationActions(")
 vm.runInContext(source.slice(start,source.indexOf("\n  }",start)+4),state)
 const keys=Array.from({length:101},(_,i)=>`${i+1}-1`)
 state.releaseNotificationActions(keys)
 assert.equal(calls.length,2)
 assert.equal(calls[0][4].split(',').length,100)
 assert.deepEqual(calls[1],["omarchy-shell","-q","foamy.notifications","releaseHistory","101-1"])
 state.activeRemovalKeys=['100-1'];state.removeErrors={text:''};state.exitCode=0;state.exitStatus=0
 const handler=source.indexOf("    onExited: function(exitCode, exitStatus) {",source.indexOf("    id: removeProc"))
 vm.runInContext(source.slice(source.indexOf("{",handler)+1,source.indexOf("\n    }",handler)),state)
 assert.equal(calls[2][4],"100-1")
})
