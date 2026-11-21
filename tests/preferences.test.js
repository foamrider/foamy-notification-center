const test = require('node:test')
const assert = require('node:assert/strict')
const P = require('../Preferences.js')

test('settings validate integers and booleans without coercion and keep scopes separate', () => {
  for (const [scope,key,value] of [['center','keepDays',30],['center','browserGrouping','hostname'],['popups','normalTimeoutSec',120],['popups','compact',false]]) assert.equal(P.valid(scope,key,value),true)
  for (const [scope,key,value] of [['center','keepDays',0],['center','keepDays',1.2],['center','maxItems',49],['popups','normalTimeoutSec',0],['popups','normalTimeoutSec',true],['popups','compact','false'],['popups','browserGrouping','hostname'],['center','groupDuplicates',true],['missing','compact',true]]) assert.equal(P.valid(scope,key,value),false)
  assert.equal(P.value('center',{},'compact'),false)
  assert.equal(P.value('popups',{},'compact'),true)
})
test('units are their own field, never part of a label', () => {
  assert.equal(P.field('center','keepDays').unit, 'days')
  assert.equal(P.field('popups','normalTimeoutSec').unit, 's')
  assert.equal(P.field('center','maxItems').unit, undefined)
  for (const f of [...P.centerFields, ...P.popupFields]) assert.doesNotMatch(f.label, /\(/, f.key)
})
test('center settings save through FoamyPrefs with the host module name; popup settings go to Foamy over IPC', () => {
  const panel = require('node:fs').readFileSync(require('node:path').join(__dirname, '../Panel.qml'), 'utf8')
  assert.ok(panel.includes('Prefs.save(root.bar, root.moduleName, Preferences.centerFields'))
  assert.ok(panel.includes('peer.call("foamy.notifications", "setPreference"'))
  assert.ok(!/notification-preferences|setBarWidget/.test(panel))
})
test('a failed save is reported to the settings fields so the same number can be retried', () => {
  const fs = require('node:fs'), vm = require('node:vm')
  const panel = fs.readFileSync(require('node:path').join(__dirname, '../Panel.qml'), 'utf8')
  const start = panel.indexOf('  function finishPreference(ok) {')
  const failed = []
  const ctx = vm.createContext({ preferenceActive: { scope: 'center', key: 'keepDays' }, settingsError: '', awaitingPeerSave: true,
    tr: s => s, console: { warn() {} }, Qt: { callLater() {} }, preferenceFailed: (scope, key) => failed.push(scope + ':' + key) })
  ctx.root = ctx
  vm.runInContext(panel.slice(start, panel.indexOf('\n  }', start) + 4), ctx)
  ctx.finishPreference(false)
  assert.deepEqual(failed, ['center:keepDays'])
  ctx.preferenceActive = { scope: 'center', key: 'maxItems' }; ctx.finishPreference(true)
  assert.deepEqual(failed, ['center:keepDays'])
  // The panel's settings page forwards it to SettingsPane.saveFailed (runtime: tests/settings-number.py).
  assert.match(panel, /function onPreferenceFailed\(scope, key\) \{\s*settingsFields\.saveFailed\(scope, key\)\s*\}/)
})
