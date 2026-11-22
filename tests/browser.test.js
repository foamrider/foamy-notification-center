const test = require('node:test')
const assert = require('node:assert/strict')
const M = require('../Model.js')

const entries = [
  {key:'3-1',app:'Vivaldi',body:'teams.microsoft.com\nNew message',timestamp:300},
  {key:'2-1',app:'Vivaldi',body:'https://mail.example.com/\nNew mail',timestamp:200},
  {key:'1-1',app:'Vivaldi',body:'teams.microsoft.com\nOld message',timestamp:100},
  {key:'4-1',app:'Chat',body:'teams.microsoft.com\nNative message',timestamp:50}
]

test('browser defaults retain one stack and mixed websites use the browser icon', () => {
  const groups = M.groupsFor(entries)
  assert.equal(groups.length,2)
  assert.equal(groups[0].entries.length,3)
  assert.equal(groups[0].hostname,'')
  assert.equal(groups[0].iconEntry,null)
  const oneSite = M.groupsFor([entries[0],entries[2]])[0]
  assert.equal(oneSite.hostname,'teams.microsoft.com')
  assert.equal(oneSite.iconEntry,entries[0])
})

test('hostname grouping separates sites, supports expansion and keeps unknown origins under the browser', () => {
  const input = [...entries,{key:'5-1',app:'Vivaldi',timestamp:20,body:'Visit https://teams.microsoft.com/'}]
  const groups = M.groupsFor(input,'hostname')
  assert.deepEqual(groups.map(g=>g.label),['teams.microsoft.com','mail.example.com','Chat','Vivaldi'])
  assert.deepEqual(groups[0].entries.map(e=>e.key),['3-1','1-1'])
  assert.equal(groups[2].hostname,'')
  const rows = M.stackRows(input,{[groups[0].key]:true},'','hostname')
  assert.equal(rows.filter(r=>r.kind==='message' && r.group.key===groups[0].key).length,2)
  // The store's answer to a search for "old" keeps the website heading.
  assert.equal(M.groupsFor(input.filter(e=>e.key==='1-1'),'hostname')[0].label,'teams.microsoft.com')
  assert.equal(M.groupsFor(input.filter(e=>e.key!=='3-1'),'hostname')[1].entries[0].key,'1-1')
})

test('none keeps browser notifications separate and leaves native app stacks intact', () => {
  const groups = M.groupsFor([...entries,{...entries[3],key:'6-1'}],'none')
  assert.equal(groups.length,4)
  assert.equal(groups[3].entries.length,2)
  assert.equal(M.groupsFor(entries,'invalid').length,2)
})
