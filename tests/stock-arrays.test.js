const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const {spawnSync, spawn} = require('node:child_process')
function fixture(t) {
 const temp=fs.mkdtempSync(path.join(os.tmpdir(),'foamy-stock-arrays-'))
 t.after(()=>fs.rmSync(temp,{recursive:true,force:true}))
 const source=path.join(temp,'source'),store=path.join(temp,'store')
 fs.mkdirSync(source)
 const env={...process.env,HOME:temp,XDG_CONFIG_HOME:path.join(temp,'config'),NC_SRC_DIR:source,NC_STORE:store,NC_PREVIEWS:'0'}
 const script=path.join(__dirname,'../bin/notification-center')
 function run(...args){const result=spawnSync(script,args,{env,encoding:'utf8'});assert.equal(result.status,0,result.stderr+result.stdout);return JSON.parse(result.stdout)}
 function write(name,rows){fs.writeFileSync(path.join(source,name+'.tmp'),JSON.stringify(rows));fs.renameSync(path.join(source,name+'.tmp'),path.join(source,name+'.json'))}
 return {temp,source,store,env,script,run,write}
}
function row(key,ts,extra={}){return {key,ts,app:'Vivaldi',summary:'Hello',body:'Message',rawBody:'<a href="https://example.test">example.test</a>\nMessage',...extra}}
test('4.5 arrays preserve opaque keys, browser identity, replacement read state, removal and clear',t=>{
 const f=fixture(t),now=Date.now()/1000
 f.write('history',[row('n-old',now-10)])
 f.write('live',[row('n-live',now)])
 f.run('sync');let rows=f.run('list')
 assert.equal(rows.length,2);assert.equal(rows[0].key,'stock-n-live');assert.equal(rows[0].timestamp,Math.floor(now*1000));assert.match(rows[0].body,/example.test/)
 const stamp=rows[0].timestamp
 f.run('seen',String(Date.now()+1))
 f.write('live',[row('n-live',now+2,{summary:'Updated'})]);f.run('sync');rows=f.run('list')
 assert.equal(rows[0].summary,'Updated');assert.equal(rows[0].timestamp,stamp);assert.equal(f.run('unread').unread,0)
 f.write('history',[row('n-live',now+2,{summary:'Updated',closed_reason:'expired'}),row('n-old',now-10)]);f.write('live',[])
 f.run('sync');assert.equal(f.run('list').length,2)
 const original=fs.readFileSync(path.join(f.source,'history.json'),'utf8')
 f.run('remove','stock-n-live');f.run('sync');assert.deepEqual(f.run('list').map(r=>r.key),['stock-n-old'])
 assert.equal(fs.readFileSync(path.join(f.source,'history.json'),'utf8'),original)
 f.run('clear');f.run('sync');assert.deepEqual(f.run('list'),[])
 f.write('live',[row('n-new',now+10)]);f.run('sync');assert.deepEqual(f.run('list').map(r=>r.key),['stock-n-new'])
})
test('4.5 malformed arrays fail visibly; invalid rows and commands never become actions',t=>{
 const f=fixture(t),now=Date.now()/1000
 for(const bad of ['{','{}',JSON.stringify(Array(101).fill(row('n-x',now)))]) {
  fs.writeFileSync(path.join(f.source,'live.json'),bad)
  const r=spawnSync(f.script,['sync'],{env:f.env,encoding:'utf8'})
  assert.notEqual(r.status,0);assert.equal(JSON.parse(r.stdout).ok,false)
 }
 f.write('live',[row('../escape',now),row('n-good',now,{execArgv:'["bash","-c","must not run"]'}),row('n-bad',now,{ts:'bad'}),row('n-ephemeral',now,{transient:true})])
 f.run('sync');const rows=f.run('list');assert.equal(rows.length,1);assert.equal(rows[0].key,'stock-n-good');assert.equal(rows[0].execArgv,undefined)
 assert.doesNotMatch(fs.readFileSync(path.join(f.store,'archive.jsonl'),'utf8'),/must not run/)
})
test('watcher follows atomic array and quiet-state replacements',async t=>{
 const f=fixture(t);f.write('live',[]);f.write('history',[])
 const watcher=spawn(f.script,['watch'],{env:f.env,stdio:['ignore','pipe','pipe']})
 t.after(()=>watcher.kill())
 let output='',errors='';watcher.stdout.on('data',d=>output+=d);watcher.stderr.on('data',d=>errors+=d)
 async function wait(fn){for(let i=0;i<100;i++){if(fn())return;await new Promise(r=>setTimeout(r,30))}assert.fail(output+errors)}
 await wait(()=>output.includes('storeChanged'))
 f.write('live',[row('n-watch',Date.now()/1000)])
 await wait(()=>output.includes('stock-n-watch'))
 f.write('quiet',{dnd:true,snoozes:{}})
 await wait(()=>output.includes('dndChanged'))
 assert.equal(f.run('list')[0].key,'stock-n-watch')
 watcher.kill();await new Promise(r=>watcher.on('close',r))
})
