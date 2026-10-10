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
  assert.equal(T.text(P.field('center','keepDays').label,'nb'),'Behold varsler (dager)')
  assert.equal(T.text(P.field('popups','normalTimeoutSec').label,'nb'),'Visningstid for vanlige varsler (sekunder)')
})
