const I18n = require('./i18n.cjs');
const assert = require("node:assert/strict")
const test = require("node:test")
const T = require("../Translations.js")

test("relative ages translate at minute, hour and day boundaries", () => {
  const cases = [[-1,"now","nå"],[59999,"now","nå"],[60000,"1m ago","1 min siden"],[3599999,"59m ago","59 min siden"],[3600000,"1h ago","1 t siden"],[86400000,"1d ago","1 d siden"]]
  for (const [now,en,nb] of cases) {
    assert.equal(T.relativeTime(0,now),en)
    assert.equal(T.relativeTime(0,now,(key, value) => I18n.text(key,"no",value)),nb)
  }
})
