const assert = require("node:assert/strict")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const { spawnSync } = require("node:child_process")
const test = require("node:test")

test("batch removal preserves other and newer entries and rejects invalid keys before mutation", () => {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), "notification-batch-"))
  try {
    const source = path.join(temp, "source")
    fs.mkdirSync(path.join(source, "history"), { recursive: true })
    const store = path.join(temp, "store")
    const env = { ...process.env, NC_SRC_DIR: source, NC_SRC_HISTORY: path.join(source, "history"), NC_STORE: store }
    const script = path.resolve(__dirname, "../bin/notification-center")
    const run = (...args) => spawnSync(script, args, { env, encoding: "utf8" })
    assert.equal(run("list").status, 0)
    const timestamp = Date.now()
    const records = [1, 2, 3].map(id => ({ key: `${timestamp}-${id}`, timestamp, app: id < 3 ? "Chat" : "Other" }))
    const archive = path.join(store, "archive.jsonl")
    fs.writeFileSync(archive, records.map(r => JSON.stringify(r)).join("\n") + "\n")
    for (const r of records) fs.writeFileSync(path.join(source, r.key + ".json"), JSON.stringify(r))
    const before = fs.readFileSync(archive, "utf8")
    assert.notEqual(run("remove", records[0].key, "../../invalid").status, 0)
    assert.equal(fs.readFileSync(archive, "utf8"), before)
    assert.equal(run("remove", records[0].key, records[1].key).status, 0)
    assert.deepEqual(JSON.parse(run("list").stdout).map(r => r.key), [records[2].key])
    // The source's files are never deleted here (contract v2: its daemon is asked over IPC).
    assert.equal(fs.existsSync(path.join(source, records[0].key + ".json")), true)
    assert.equal(fs.existsSync(path.join(source, records[2].key + ".json")), true)
    assert.equal(run("remove", records[0].key, records[1].key).status, 0)
  } finally { fs.rmSync(temp, { recursive: true, force: true }) }
})
