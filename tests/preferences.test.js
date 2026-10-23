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
  assert.deepEqual(P.saveCommand('center','compact',true,'/helper'), ['omarchy-shell','shell','setBarWidget','foamy.notification-center','compact',' true','{}'])
  assert.deepEqual(P.saveCommand('popups','normalTimeoutSec',12,'/helper'), ['python3','/helper','save','normalTimeoutSec','12'])
  assert.deepEqual(P.saveCommand('popups','browserGrouping','hostname','/helper'), [])
})
test('units belong to translated labels', () => {
  assert.equal(I18n.text(P.field('center','keepDays').label,'nb'),'Behold varsler (dager)')
  assert.equal(I18n.text(P.field('popups','normalTimeoutSec').label,'nb'),'Visningstid for vanlige varsler (sekunder)')
})
test('X history removal is a translated popup setting with a strict boolean', () => {
  assert.equal(P.value('popups',{},'closeButtonRemovesHistory'),false)
  assert.equal(P.valid('popups','closeButtonRemovesHistory',true),true)
  assert.equal(P.valid('popups','closeButtonRemovesHistory','true'),false)
  assert.equal(P.valid('center','closeButtonRemovesHistory',true),false)
  assert.deepEqual(P.saveCommand('popups','closeButtonRemovesHistory',true,'/helper'), ['python3','/helper','save','closeButtonRemovesHistory','true'])
  assert.equal(I18n.text(P.field('popups','closeButtonRemovesHistory').label,'nb'),'X fjerner fra historikken')
})


test('critical DND silencing belongs to popup settings with a translated boolean control',()=>{
 assert.equal(P.value('popups',{},'dndSilenceCritical'),false)
 assert.equal(P.valid('popups','dndSilenceCritical',true),true)
 assert.equal(P.valid('popups','dndSilenceCritical','true'),false)
 assert.equal(P.valid('center','dndSilenceCritical',true),false)
 assert.deepEqual(P.saveCommand('popups','dndSilenceCritical',true,'/helper'),['python3','/helper','save','dndSilenceCritical','true'])
 assert.equal(I18n.text(P.field('popups','dndSilenceCritical').label,'nb'),'Ikke forstyrr demper også kritiske varsler')
})
