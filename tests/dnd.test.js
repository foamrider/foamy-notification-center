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

const {processFixture}=require("./qml-process.cjs")
test("a silencing command that can't start shows the error instead of a dead toggle",()=>{
  const state=service()
  let snoozeRefreshes=0
  state.refreshSnooze=()=>{ snoozeRefreshes++ }
  state.dndProc=processFixture(source,"dndProc",state,{dndOutput:{text:""}})
  // omarchy-shell missing: Quickshell emits no exited(), only running -> false.
  state.toggleDnd();assert.equal(state.dndProc.launched,true)
  state.dndProc.failStart()
  assert.match(state.dndError,/Try again/);assert.equal(state.dndKnown,false);assert.equal(snoozeRefreshes,1)
  // running -> false again (a stray emission) finds nothing launched.
  state.dndProc.failStart();assert.equal(snoozeRefreshes,1)
  // A normal end: exited(), then running -> false, handled once.
  state.dndProc.dndOutput.text="on\n"
  state.refreshDnd();state.dndProc.exit(0,0)
  assert.equal(state.doNotDisturb,true);assert.equal(state.dndKnown,true);assert.equal(state.dndError,"");assert.equal(snoozeRefreshes,2)
})
test("snooze commands that can't start report an error; a probe that can't start hides snooze",()=>{
  const state=vm.createContext({snoozeAvailable:true,snoozeError:"",console:{warn(){}},refreshDnd(){ state.dndRefreshes++ },dndRefreshes:0})
  state.root=state
  for (const name of ["snoozeAll","refreshSnooze"]) {
    const start=source.indexOf(`  function ${name}(`)
    vm.runInContext(source.slice(start,source.indexOf("\n  }",start)+4),state)
  }
  state.snoozeProc=processFixture(source,"snoozeProc",state,{minutes:0,snoozeOutput:{text:""}})
  state.snoozeProbe=processFixture(source,"snoozeProbe",state,{snoozeProbeOutput:{text:""}})
  state.snoozeAll(30)
  assert.deepEqual(Array.from(state.snoozeProc.command),["omarchy-shell","notifications","unsnooze","*"])
  state.snoozeProc.failStart()
  assert.match(state.snoozeError,/Try again/);assert.equal(state.snoozeProc.minutes,0);assert.equal(state.dndRefreshes,0)
  // Unsnooze, then the snoozeAll step it starts from its exit handler: that one can't start.
  state.snoozeError="";state.snoozeAll(30);state.snoozeProc.snoozeOutput.text="ok"
  state.snoozeProc.running=true;state.snoozeProc.exit(0,0)
  assert.deepEqual(Array.from(state.snoozeProc.command),["omarchy-shell","notifications","snoozeAll","30"])
  assert.equal(state.snoozeProc.running,true);assert.equal(state.snoozeError,"");assert.equal(state.dndRefreshes,1)
  state.snoozeProc.failStart();assert.match(state.snoozeError,/Try again/)
  state.refreshSnooze();state.snoozeProbe.failStart()
  assert.equal(state.snoozeAvailable,false)
})
