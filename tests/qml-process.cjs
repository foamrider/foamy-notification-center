// Runs a Process's own handlers from Service.qml in node, emitted the way
// Quickshell 0.3.2 emits them: a normal end is exited() and then running ->
// false (running is already false in onExited, and true again when the
// handler started the next step); a start that fails (missing binary) emits
// only running -> false.
//
//   const proc = processFixture(source, "dndProc", state, {dndOutput: {text: ""}})
//   state.dndProc = proc; state.toggleDnd(); proc.exit(0, 0); proc.failStart()
const vm = require("node:vm")

function block(source, id) {
  const start = source.indexOf(`    id: ${id}\n`)
  if (start < 0) throw new Error(`no Process with id ${id}`)
  return source.slice(start, source.indexOf("\n  }", start))
}

// A handler's text: its first line, plus the indented lines of a multi-line body.
function handler(source, id, name) {
  const lines = block(source, id).split("\n")
  const head = `    ${name}: `
  const at = lines.findIndex(line => line.startsWith(head))
  if (at < 0) return ""
  const out = [lines[at].slice(head.length)]
  for (let i = at + 1; i < lines.length; i++) {
    if (/^      /.test(lines[i])) { out.push(lines[i]); continue }
    if (lines[i] === "    }") out.push(lines[i])
    break
  }
  return out.join("\n")
}

function processFixture(source, id, root, props) {
  const proc = vm.createContext({running: false, launched: false, command: [], root, console, ...props})
  const exited = handler(source, id, "onExited")
  const changed = handler(source, id, "onRunningChanged")
  const runExited = (code, status) => {
    if (!exited) return
    if (exited.startsWith("function")) vm.runInContext(`(${exited})(${code}, ${status})`, proc)
    else vm.runInContext(`(function() ${exited})()`, proc)
  }
  const runChanged = () => { if (changed) vm.runInContext(changed, proc) }
  proc.starts = 0
  // A command set and started counts as one start (the fixture's `running` is a plain value).
  proc.exit = (code, status) => { proc.running = false; runExited(code, status); runChanged() }
  proc.failStart = () => { proc.running = false; runChanged() }
  return proc
}

module.exports = {block, handler, processFixture}
