// foamy-kit 0.4.2 90b1a10f5f5005c94031f36fef0ad3d8e705cf4e13372dd8362ef4579e0a93df — do not edit; change foamy-kit and run sync
// Loads a foamy-kit QML JavaScript library (".pragma library") in node, for
// plugin unit tests. require() can't: ".pragma library" is not JavaScript.
//
//   const Prefs = require("../kit/node-loader.cjs").load("FoamyPrefs")
//   const Prefs = require("../kit/node-loader.cjs").load("FoamyPrefs", { console: quietConsole })
//
// The file runs in a fresh vm context with `module.exports`, `console` and
// any extra globals you pass.
"use strict"
const fs = require("fs")
const path = require("path")
const vm = require("vm")

function load(name, globals) {
  const file = path.join(__dirname, name.endsWith(".js") ? name : `${name}.js`)
  const source = fs.readFileSync(file, "utf8").replace(/^\s*\.pragma\s+library\s*$/m, "")
  const sandbox = Object.assign({ module: { exports: {} }, console }, globals || {})
  vm.runInNewContext(source, sandbox, { filename: file })
  return sandbox.module.exports
}

module.exports = { load }
