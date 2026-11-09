// Buttons Foamy Notifications can still press: only labels cross into the
// center, which never stores or runs a sender's command (marketplace #9099).
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const test = require('node:test')
const Model = require('../Model.js')
const source = fs.readFileSync(path.join(__dirname, '../Service.qml'), 'utf8')
const plain = value => JSON.parse(JSON.stringify(value))

function service(answers) {
  const calls = [], events = []
  const state = vm.createContext({
    Model, sourceKind: 'foamy', liveActions: {}, liveActionsLoading: false, liveActionsAgain: false,
    pressingAction: false, focusError: '', focusProc: { running: false },
    focusCompleted() { events.push('completed') },
    peer: { call(target, method, args, done) { calls.push([target, method, Array.from(args)]); done(true, answers[method]) } }
  })
  state.root = state
  for (const name of ['refreshLiveActions', 'pressAction']) {
    const start = source.indexOf(`  function ${name}(`)
    vm.runInContext(source.slice(start, source.indexOf('\n  }', start) + 4), state)
  }
  return { state, calls, events }
}

test('Foamy\'s reply is validated: exact keys, a few plain labels', () => {
  assert.deepEqual(plain(Model.parseLiveActions('{"10-1":["View in Zendesk","Mark as read"]}')), { '10-1': ['View in Zendesk', 'Mark as read'] })
  for (const bad of ['', 'nope', '[]', '{"../x":["a"]}', '{"10-1":[]}', '{"10-1":[1]}', '{"10-1":[" "]}', '{"10-1":"a"}',
    JSON.stringify({ '10-1': Array(13).fill('a') })]) assert.deepEqual(plain(Model.parseLiveActions(bad)), {}, bad)
  assert.equal(Model.parseLiveActions(JSON.stringify({ '10-1': ['x'.repeat(200)] }))['10-1'][0].length, 80)
})

test('labels are read from Foamy, never from the archive', () => {
  const { state, calls } = service({ centerActions: '{"10-1":["Mark as read"]}' })
  state.refreshLiveActions()
  assert.deepEqual(calls, [['foamy.notifications', 'centerActions', []]])
  assert.deepEqual(plain(state.liveActions), { '10-1': ['Mark as read'] })
  state.sourceKind = 'stock'; state.refreshLiveActions()
  assert.deepEqual(plain(state.liveActions), {}); assert.equal(calls.length, 1)
})

test('a button press is delegated to Foamy by key and index', () => {
  const { state, calls, events } = service({ centerActions: '{"10-1":["View","Mark as read"]}', invokeCenterAction: 'invoked' })
  state.refreshLiveActions()
  state.pressAction({ key: '10-1' }, 2); state.pressAction({ key: '../x' }, 0); state.pressAction({ key: '11-1' }, 0)
  assert.equal(calls.length, 1, 'only listed buttons are pressed')
  state.pressAction({ key: '10-1' }, 1)
  assert.deepEqual(calls[1], ['foamy.notifications', 'invokeCenterAction', ['10-1', '1']])
  assert.deepEqual(events, ['completed']); assert.equal(state.focusError, '')
})

test('an action that expired meanwhile says so and refreshes the buttons', () => {
  const { state, calls, events } = service({ centerActions: '{"10-1":["Mark as read"]}', invokeCenterAction: 'unavailable' })
  state.refreshLiveActions()
  state.pressAction({ key: '10-1' }, 0)
  assert.equal(state.focusError, 'This action is no longer available.')
  assert.deepEqual(events, []); assert.equal(calls.at(-1)[1], 'centerActions')
})

test('the archive keeps no sender commands or button labels', () => {
  const ingest = fs.readFileSync(path.join(__dirname, '../native/src/ingest.rs'), 'utf8')
  assert.doesNotMatch(ingest, /entry\.insert\("(exec|execArgv|execActions|actions)"/)
})
