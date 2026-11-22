const assert = require("node:assert/strict")
const test = require("node:test")
const Model = require("../Model.js")

const entries = [
  { key: "1-1", app: "Chat", timestamp: 100, urgency: 2, appIcon: "chat-icon", image: "avatar", summary: "Old alert" },
  { key: "3-1", app: "Chat", timestamp: 300, urgency: 1, summary: "Latest message" },
  { key: "2-1", app: "Other", timestamp: 200, summary: "Other message" }
]

test("groups order by newest, use app icons, and retain older critical state", () => {
  const groups = Model.groupsFor(entries)
  assert.deepEqual(groups.map(g => g.app), ["Chat", "Other"])
  assert.deepEqual(groups[0].entries.map(e => e.key), ["3-1", "1-1"])
  assert.equal(groups[0].critical, true)
  assert.equal(groups[0].appIcon, "chat-icon")
  // The stack header shows the age of its newest card.
  assert.deepEqual(groups.map(g => g.timestamp), [300, 200])
  assert.equal(entries[0].key, "1-1")
})

test("collapsed and expanded stacks flatten into virtualizable rows", () => {
  const collapsed = Model.stackRows(entries, {}, "")
  assert.deepEqual(collapsed.map(r => r.id), ["group:Chat", "entry:3-1", "group:Other", "entry:2-1"])
  assert.equal(collapsed[1].layered, true)
  assert.equal(collapsed[1].last, true)
  // A stack of one card is not drawn as a stack.
  assert.equal(collapsed[3].layered, false)
  const expanded = Model.stackRows(entries, { Chat: true }, "")
  assert.equal(expanded.length, 5)
  assert.equal(expanded[1].last, false)
  assert.equal(expanded[2].last, true)
  assert.equal(expanded[2].layered, false)
})

test("a search shows every row the store found, with each stack open", () => {
  // The store matches with full Unicode case folding and a trimmed query, so
  // its answer is shown as it is: "strasse" found "Straße", "foo " found "foo".
  const cases = [
    { query: "strasse", found: { key: "5-1", app: "Maps", timestamp: 500, summary: "Straße closed" }, keys: ["5-1", "3-1", "1-1", "2-1"] },
    { query: "foo ", found: { key: "6-1", app: "Chat", timestamp: 600, body: "said foo" }, keys: ["6-1", "3-1", "1-1", "2-1"] }
  ]
  for (const { query, found, keys } of cases) {
    const rows = Model.stackRows([found, ...entries], {}, query)
    assert.deepEqual(rows.filter(r => r.kind === "message").map(r => r.entry.key), keys, query)
    assert.equal(rows.find(r => r.id === "group:Chat").expanded, true, query)
  }
  // Without a search, stacks stay as the user left them.
  assert.equal(Model.stackRows(entries, {}, "").find(r => r.id === "group:Chat").expanded, false)
  assert.deepEqual(Model.stackRows([], {}, "missing"), [])
})

test("sender names cannot collide with object properties and duplicate keys are ignored", () => {
  const rows = [{ key: "4-1", app: "__proto__", timestamp: 400 }, null, ...entries, entries[0]]
  assert.equal(Model.groupsFor(rows).length, 3)
  assert.equal(Model.groupsFor(rows)[1].entries.length, 2)
})

