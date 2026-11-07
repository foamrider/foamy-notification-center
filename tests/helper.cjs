// The store helper under test, run as a process (black box).
//
// FOAMY_HELPER is a JSON argv prefix, e.g.
//   FOAMY_HELPER='["/abs/path/bin/aarch64/foamy-notification-center-helper"]'
// Without it the plugin's own helper for this machine runs (bin/<arch>/).
//
// Every call gets a private HOME when the caller would otherwise hand the
// helper the real one, so no test can reach personal notification state.
const childProcess = require("node:child_process")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")

const root = path.resolve(__dirname, "..")
const realHome = os.homedir()

function prefix() {
  const configured = process.env.FOAMY_HELPER
  if (!configured) return [path.join(root, "bin", os.machine(), "foamy-notification-center-helper")]
  const argv = JSON.parse(configured)
  if (!Array.isArray(argv) || argv.length === 0 || !argv.every(arg => typeof arg === "string"))
    throw new Error("FOAMY_HELPER must be a JSON array of strings")
  if (!path.isAbsolute(argv[0])) throw new Error("FOAMY_HELPER must start with an absolute path")
  return argv
}

let sandbox = ""
function privateHome() {
  if (!sandbox) {
    sandbox = fs.mkdtempSync(path.join(os.tmpdir(), "nc-helper-home-"))
    process.on("exit", () => fs.rmSync(sandbox, { recursive: true, force: true }))
  }
  return sandbox
}

// The real home (and XDG dirs inside it) never reach the helper.
function isolated(env) {
  const out = { ...(env || process.env) }
  const inside = value => value && (value === realHome || value.startsWith(realHome + "/"))
  if (!out.HOME || out.HOME === realHome) out.HOME = privateHome()
  for (const name of ["XDG_STATE_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME"])
    if (inside(out[name])) delete out[name]
  return out
}

function command(args) {
  const argv = prefix()
  return [argv[0], [...argv.slice(1), ...args]]
}

module.exports = {
  command,
  spawnSync(args, options = {}) {
    const [file, argv] = command(args)
    return childProcess.spawnSync(file, argv, { ...options, env: isolated(options.env) })
  },
  spawn(args, options = {}) {
    const [file, argv] = command(args)
    return childProcess.spawn(file, argv, { ...options, env: isolated(options.env) })
  },
}
