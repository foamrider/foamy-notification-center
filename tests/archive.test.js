const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");

test("prune retains valid records after corruption and clear deletes them", () => {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), "notification-archive-test-"));
  try {
    const state = path.join(temp, "omarchy-notification-center");
    fs.mkdirSync(state, { recursive: true });
    const env = { ...process.env, HOME: temp, XDG_CONFIG_HOME: path.join(temp, "config"), XDG_STATE_HOME: temp, NC_KEEP_DAYS: "30", NC_MAX_ITEMS: "1000" };
    const script = path.join(__dirname, "../bin/notification-center");
    const run = (...args) => {
      const result = spawnSync("bash", [script, ...args], { env, encoding: "utf8" });
      assert.equal(result.status, 0, result.stderr);
      return result.stdout;
    };
    run("list");
    const archive = path.join(state, "archive.jsonl");
    const timestamp = Date.now() - 1000;
    const records = [1, 2].map(i => ({ key: `${timestamp}-${i}`, timestamp, summary: `record ${i}` }));
    fs.writeFileSync(archive, JSON.stringify(records[0]) + "\ncorrupt\n" + JSON.stringify(records[1]) + "\n");
    run("sync");
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
