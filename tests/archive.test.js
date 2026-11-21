const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");
const helper = require("./helper.cjs")

test("a retention rewrite keeps the valid rows around a corrupt line, and clear deletes them", () => {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), "notification-archive-test-"));
  try {
    const state = path.join(temp, "omarchy-notification-center");
    fs.mkdirSync(state, { recursive: true });
    const env = { ...process.env, HOME: temp, XDG_CONFIG_HOME: path.join(temp, "config"), XDG_STATE_HOME: temp, NC_KEEP_DAYS: "30", NC_MAX_ITEMS: "1000" };
    const run = (...args) => {
      const result = helper.spawnSync(args, { env, encoding: "utf8" });
      assert.equal(result.status, 0, result.stderr);
      return result.stdout;
    };
    run("list");
    const archive = path.join(state, "archive.jsonl");
    const timestamp = Date.now() - 1000;
    const records = [1, 2].map(i => ({ key: `${timestamp}-${i}`, timestamp, summary: `record ${i}` }));
    // A row older than the 30 days makes sync rewrite the archive (retention).
    const old = Date.now() - 40 * 86400000;
    fs.writeFileSync(archive, [JSON.stringify(records[0]), "corrupt", JSON.stringify(records[1]),
      JSON.stringify({ key: `${old}-3`, timestamp: old, summary: "old" })].join("\n") + "\n");
    run("sync");
    // The rewrite drops the old row and keeps the valid rows on both sides of
    // the corrupt line.
    const written = fs.readFileSync(archive, "utf8");
    for (const row of records) assert.ok(written.includes(`"key":"${row.key}"`), `${row.key} was lost:\n${written}`);
    assert.equal(written.includes(`"key":"${old}-3"`), false, written);
    assert.deepEqual(JSON.parse(run("list")).map(row => row.key).sort(), records.map(row => row.key));
    const image = path.join(state, "images", `${records[0].key}-image.png`);
    fs.mkdirSync(path.dirname(image), { recursive: true }); fs.writeFileSync(image, "png");
    run("clear");
    assert.deepEqual(JSON.parse(run("list")), []);
    // Clear all is a real deletion: rows and their retained images are gone.
    assert.equal(fs.readFileSync(archive, "utf8").trim(), "");
    assert.equal(fs.existsSync(image), false);
  } finally {
    fs.rmSync(temp, { recursive: true, force: true });
  }
});
