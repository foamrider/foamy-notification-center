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
test('a center save runs bounded through the host CLI; a popup save goes to Foamy over IPC; saves run one at a time, newest value per key', () => {
  const fs = require('node:fs'), vm = require('node:vm')
  const panel = fs.readFileSync(require('node:path').join(__dirname, '../Panel.qml'), 'utf8')
  const take = head => { const start = panel.indexOf(head); assert.ok(start >= 0, head); const indent = head.match(/^ */)[0]; return panel.slice(start, panel.indexOf('\n' + indent + '}', start) + indent.length + 2) }
  const kit = require('../kit/node-loader.cjs').load('FoamyPrefs')
  const saves = [], calls = [], later = [], failed = []
  const ctx = vm.createContext({
    Preferences: P, moduleName: 'foamy.notification-center', bar: {}, settings: {}, store: {}, editingSettings: false,
    pendingPreferences: {}, preferenceActive: null, popupSettingsLoading: false, awaitingPeerSave: false, settingsError: '',
    popupSettings: {}, popupSettingsAvailable: false,
    preferencesSave: { command: [], running: false }, tr: s => s, console: { warn() {} }, JSON, Object, String,
    Qt: { callLater(fn) { later.push(fn) } }, preferenceFailed: (scope, key) => failed.push(`${scope}:${key}`),
    // The kit's bounded() runs as shipped; save() is the host's settings write.
    Prefs: { ...kit, save(...args) { saves.push(args); return { ok: true, command: ['omarchy', 'bar', 'set', args[1], args[4], JSON.stringify(args[5]), '--json'] } } },
    peer: { call(target, method, args, done) { calls.push({ target, method, args: Array.from(args), done }) } }
  })
  ctx.root = ctx
  for (const name of ['savePreference', 'flushPreferences', 'finishPreference', 'applyPopupPreferences', 'reloadPopupPreferences'])
    vm.runInContext(take(`  function ${name}(`), ctx)
  vm.runInContext(take('    function onPeerPreferencesChanged() {'), ctx)
  const drain = () => { while (later.length) later.shift()() }
  const popupSettings = extra => JSON.stringify({ settings: Object.fromEntries(P.popupFields.map(f => [f.key, f.defaultValue])), ...extra })
  // A center setting: one host save with this plugin's module and fields, killed whole after 4 s.
  ctx.savePreference('center', 'keepDays', 31)
  assert.equal(saves.length, 1)
  assert.deepEqual([saves[0][1], saves[0][2], saves[0][4], saves[0][5]], ['foamy.notification-center', P.centerFields, 'keepDays', 31])
  assert.deepEqual(Array.from(ctx.preferencesSave.command), ['timeout', '--signal=KILL', '4s', 'omarchy', 'bar', 'set', 'foamy.notification-center', 'keepDays', '31', '--json'])
  assert.equal(ctx.preferencesSave.running, true); assert.equal(calls.length, 0)
  // Edits while it runs wait; only the newest value per key is saved next.
  ctx.savePreference('center', 'keepDays', 40); ctx.savePreference('center', 'keepDays', 41)
  assert.equal(saves.length, 1)
  ctx.finishPreference(true); drain()
  assert.equal(saves.length, 2); assert.equal(saves[1][5], 41)
  ctx.finishPreference(true); drain()
  assert.equal(saves.length, 2); assert.equal(ctx.preferenceActive, null)
  // A popup setting goes to Foamy; the leading space keeps qs ipc from parsing the JSON.
  ctx.savePreference('popups', 'compact', false)
  assert.deepEqual(calls.map(c => [c.target, c.method, c.args]), [['foamy.notifications', 'setPreference', ['compact', ' false']]])
  assert.equal(saves.length, 2)
  calls[0].done(true, 'saving\n')
  assert.equal(ctx.awaitingPeerSave, true); assert.equal(ctx.settingsError, '')
  // Foamy says its preferences changed: done only once it no longer reports saving.
  ctx.onPeerPreferencesChanged(); calls[1].done(true, popupSettings({ saving: true }))
  assert.equal(calls[1].method, 'preferences'); assert.notEqual(ctx.preferenceActive, null)
  ctx.onPeerPreferencesChanged(); calls[2].done(true, popupSettings({}))
  assert.equal(ctx.preferenceActive, null); assert.equal(ctx.awaitingPeerSave, false); assert.equal(ctx.settingsError, ''); assert.deepEqual(failed, [])
  drain()
  // A save Foamy reports as failed, and a refused setPreference, are errors.
  ctx.savePreference('popups', 'compact', true); calls.at(-1).done(true, 'saving')
  ctx.onPeerPreferencesChanged(); calls.at(-1).done(true, popupSettings({ saveError: 'x' }))
  assert.equal(ctx.settingsError, 'Could not save settings. Try again.'); assert.deepEqual(failed, ['popups:compact'])
  drain(); ctx.settingsError = ''
  ctx.savePreference('popups', 'normalTimeoutSec', 9); calls.at(-1).done(true, 'unknown preference')
  assert.equal(ctx.settingsError, 'Could not save settings. Try again.'); assert.equal(ctx.awaitingPeerSave, false)
  drain()
  // An invalid value starts nothing.
  const before = [saves.length, calls.length]
  ctx.savePreference('center', 'keepDays', 0)
  assert.equal(ctx.settingsError, 'Invalid setting.'); assert.deepEqual([saves.length, calls.length], before)
})
test('the manifest declares exactly the settings the panel reads, and its defaults agree', () => {
  const bar = require('../manifest.json').barWidget
  // The keys Panel.qml reads with setting(); a key the panel dropped (such as language) fails here.
  const read = ['panelWidth', 'listHeight', 'badge', 'keepDays', 'maxItems', 'clickAction', 'compact', 'useBrowserFavicons', 'browserGrouping', 'showBody', 'showPreview']
  assert.deepEqual(bar.schema.map(f => f.key).sort(), [...read].sort())
  assert.deepEqual(Object.keys(bar.defaults).sort(), [...read].sort())
  for (const f of bar.schema) assert.deepEqual(bar.defaults[f.key], f.defaultValue, f.key)
  // The settings the center edits itself agree with the manifest the host edits.
  for (const f of P.centerFields) {
    const declared = bar.schema.find(entry => entry.key === f.key)
    for (const name of ['type', 'defaultValue', 'options', 'min', 'max']) assert.deepEqual(declared[name], f[name], `${f.key}.${name}`)
  }
})
