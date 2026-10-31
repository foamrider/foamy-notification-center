const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")
const test = require("node:test")
const source = fs.readFileSync(path.join(__dirname,"../Service.qml"),"utf8")
function service() {
  let refreshes = 0
  const state = vm.createContext({ doNotDisturb:false,dndKnown:false,dndError:"",console:{warn(){}},dndProc:{running:false,command:[]},dndRefresh:{restart(){ refreshes++ }} })
  state.root=state
  for (const name of ["refreshDnd","toggleDnd","applyDndResult"]) {
    const start=source.indexOf(`  function ${name}(`)
    assert.notEqual(start,-1)
    vm.runInContext(source.slice(start,source.indexOf("\n  }",start)+4),state)
  }
  state.refreshes=()=>refreshes
  return state
}
test("silencing uses the daemon's atomic toggle rather than a stale local boolean",()=>{
  const state=service()
  state.toggleDnd()
  assert.deepEqual(Array.from(state.dndProc.command),["omarchy-shell","notifications","toggleDnd"])
  assert.equal(state.doNotDisturb,false)
  state.applyDndResult(0,0,"on\n")
  assert.equal(state.doNotDisturb,true)
  assert.equal(state.dndKnown,true)
  state.applyDndResult(0,0,"off\n")
  assert.equal(state.doNotDisturb,false)
})
test("external refresh waits for an active toggle",()=>{
  const state=service()
  state.toggleDnd()
  state.refreshDnd()
  assert.equal(state.refreshes(),1)
  assert.equal(state.dndProc.command[2],"toggleDnd")
  state.dndProc.running=false
  state.refreshDnd()
  assert.equal(state.dndProc.command[2],"isDnd")
})
test("failed or malformed responses preserve the last state and surface a retry error",()=>{
  const state=service()
  state.applyDndResult(0,0,"on")
  for (const [code,status,output] of [[1,0,"off"],[0,1,"off"],[0,0,"invalid"]]) {
    state.applyDndResult(code,status,output)
    assert.equal(state.doNotDisturb,true)
    assert.match(state.dndError,/Try again/)
  }
  state.applyDndResult(0,0,"off")
  assert.equal(state.doNotDisturb,false)
  assert.equal(state.dndError,"")
})
