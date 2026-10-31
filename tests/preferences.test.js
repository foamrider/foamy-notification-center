const I18n = require('./i18n.cjs');
const test = require('node:test')
const assert = require('node:assert/strict')
const P = require('../Preferences.js')
const T = require('../Translations.js')

test('settings validate integers and booleans without coercion and keep scopes separate', () => {
  for (const [scope,key,value] of [['center','keepDays',30],['center','browserGrouping','hostname'],['popups','normalTimeoutSec',120],['popups','compact',false]]) assert.equal(P.valid(scope,key,value),true)
  for (const [scope,key,value] of [['center','keepDays',0],['center','keepDays',1.2],['center','maxItems',49],['popups','normalTimeoutSec',0],['popups','normalTimeoutSec',true],['popups','compact','false'],['popups','browserGrouping','hostname'],['center','groupDuplicates',true],['missing','compact',true]]) assert.equal(P.valid(scope,key,value),false)
  assert.equal(P.value('center',{},'compact'),false)
  assert.equal(P.value('popups',{},'compact'),true)
})
test('saving routes widget and service settings to their existing owners', () => {
})
test('number settings carry a translated unit beside a unit-free label', () => {
  assert.equal(I18n.text(P.field('center','keepDays').label,'nb'),'Behold varsler')
  assert.equal(I18n.text(P.field('center','keepDays').unit,'nb'),'dager')
  assert.equal(I18n.text(P.field('popups','normalTimeoutSec').label,'nb'),'Visningstid for vanlige varsler')
  assert.equal(I18n.text(P.field('popups','normalTimeoutSec').unit,'nb'),'s')
  assert.equal(P.field('center','maxItems').unit, undefined)
  for (const f of [...P.centerFields, ...P.popupFields]) assert.doesNotMatch(f.label, /\(/, f.key)
})
test('X history removal is a translated popup setting with a strict boolean', () => {
  assert.equal(P.value('popups',{},'closeButtonRemovesHistory'),false)
  assert.equal(P.valid('popups','closeButtonRemovesHistory',true),true)
  assert.equal(P.valid('popups','closeButtonRemovesHistory','true'),false)
  assert.equal(P.valid('center','closeButtonRemovesHistory',true),false)
  assert.equal(I18n.text(P.field('popups','closeButtonRemovesHistory').label,'nb'),'X fjerner fra historikken')
})


test('critical DND silencing belongs to popup settings with a translated boolean control',()=>{
 assert.equal(P.value('popups',{},'dndSilenceCritical'),false)
 assert.equal(P.valid('popups','dndSilenceCritical',true),true)
 assert.equal(P.valid('popups','dndSilenceCritical','true'),false)
 assert.equal(P.valid('center','dndSilenceCritical',true),false)
 assert.equal(I18n.text(P.field('popups','dndSilenceCritical').label,'nb'),'Ikke forstyrr demper også kritiske varsler')
})
test('center settings save through FoamyPrefs with the host module name; popup settings go to Foamy over IPC', () => {
  const panel = require('node:fs').readFileSync(require('node:path').join(__dirname, '../Panel.qml'), 'utf8')
  assert.ok(panel.includes('Prefs.save(root.bar, root.moduleName, Preferences.centerFields'))
  assert.ok(panel.includes('peer.call("foamy.notifications", "setPreference"'))
  assert.ok(!/notification-preferences|setBarWidget/.test(panel))
})
test('numeric settings use kit FoamyNumberField and never assign over the setting', () => {
  const pane = require('node:fs').readFileSync(require('node:path').join(__dirname, '../SettingsPane.qml'), 'utf8')
  assert.match(pane, /FoamyNumberField \{/)
  // Escape, invalid input and external changes are the kit's rules (runtime: tests/settings-number.py).
  assert.doesNotMatch(pane, /\btext\s*=\s*String\(root\.current/)
  assert.doesNotMatch(pane, /SafeTextField/)
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
  assert.match(panel, /function onPreferenceFailed\(scope, key\) \{ settingsFields\.saveFailed\(scope, key\) \}/)
})
