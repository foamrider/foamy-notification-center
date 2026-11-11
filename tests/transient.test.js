const assert = require("node:assert/strict")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const test = require("node:test")
const helper = require("./helper.cjs")

test("transient stock notification records never enter the archive", () => {
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "notification-transient-"))
  try {
    const source = path.join(scratch, "notifications")
    fs.mkdirSync(path.join(source, "history"), { recursive: true })
    const timestamp = Date.now()
    for (const [id, appName, hints] of [
      [1, "omarchy-action", { transient: true }],
      [2, "Vivaldi", {}],
      [3, "omarchy-action", {}],
    ]) {
      // Test the stock daemon's persisted format without depending on another plugin.
      const serialized = JSON.stringify({ originalId: id, appName, summary: "Test", body: "",
        appIcon: "", urgency: 0, timestamp, transient: hints.transient === true })
      fs.writeFileSync(path.join(source, `${timestamp}-${id}.json`), serialized)
    }
    // A malformed source must not prevent valid notifications being archived.
    fs.writeFileSync(path.join(source, "broken.json"), "{")
    const env = { ...process.env, NC_SRC_DIR: source, NC_SRC_HISTORY: path.join(source, "history"), NC_STORE: path.join(scratch, "archive") }
    for (let pass = 0; pass < 2; pass++) {
      const sync = helper.spawnSync(["sync"], { env, encoding: "utf8" })
      assert.equal(sync.status, 0, sync.stderr)
      const result = helper.spawnSync(["list", "100"], { env, encoding: "utf8" })
      assert.equal(result.status, 0, result.stderr)
      assert.deepEqual(JSON.parse(result.stdout).map(row => row.key).sort(), [`${timestamp}-2`, `${timestamp}-3`])
      // Expiry moves the same files to history; catch-up must still skip transient toasts.
      if (pass === 0) for (const file of fs.readdirSync(source).filter(file => file.endsWith(".json")))
        fs.renameSync(path.join(source, file), path.join(source, "history", file))
    }
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true })
  }
})
