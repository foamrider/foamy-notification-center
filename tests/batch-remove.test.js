const assert = require("node:assert/strict")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const test = require("node:test")
const helper = require("./helper.cjs")

test("batch removal preserves other and newer entries and their images and rejects invalid keys before mutation", () => {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), "notification-batch-"))
  try {
    const source = path.join(temp, "source")
    fs.mkdirSync(path.join(source, "history"), { recursive: true })
    const store = path.join(temp, "store")
    const env = { ...process.env, NC_SRC_DIR: source, NC_SRC_HISTORY: path.join(source, "history"), NC_STORE: store }
    const run = (...args) => helper.spawnSync(args, { env, encoding: "utf8" })
    assert.equal(run("list").status, 0)
    const timestamp = Date.now()
    const records = [1, 2, 3].map(id => ({ key: `${timestamp}-${id}`, timestamp, app: id < 3 ? "Chat" : "Other" }))
    const archive = path.join(store, "archive.jsonl")
    fs.writeFileSync(archive, records.map(r => JSON.stringify(r)).join("\n") + "\n")
    for (const r of records) fs.writeFileSync(path.join(source, r.key + ".json"), JSON.stringify(r))
    const before = fs.readFileSync(archive, "utf8")
    assert.notEqual(run("remove", records[0].key, "../../invalid").status, 0)
    assert.equal(fs.readFileSync(archive, "utf8"), before)
    // The center's image copies of a removed row go; the others stay.
    const images = path.join(store, "images")
    fs.mkdirSync(images, { recursive: true })
    const copy = r => path.join(images, `${r.key}-appIcon.png`)
    for (const r of [records[0], records[2]]) fs.writeFileSync(copy(r), "png")
    assert.equal(run("remove", records[0].key, records[1].key).status, 0)
    assert.deepEqual(JSON.parse(run("list").stdout).map(r => r.key), [records[2].key])
    assert.equal(fs.existsSync(copy(records[0])), false)
    assert.equal(fs.existsSync(copy(records[2])), true)
    // The source's files are never deleted here (contract v2: its daemon is asked over IPC).
    assert.equal(fs.existsSync(path.join(source, records[0].key + ".json")), true)
    assert.equal(fs.existsSync(path.join(source, records[2].key + ".json")), true)
    assert.equal(run("remove", records[0].key, records[1].key).status, 0)
  } finally { fs.rmSync(temp, { recursive: true, force: true }) }
})
