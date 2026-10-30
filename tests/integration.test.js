const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const {spawnSync, spawn} = require('node:child_process')
const vm = require('node:vm')
const script = path.join(__dirname,'../bin/notification-center')
function fixture(t) {
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'foamy-integration-'))
 t.after(()=>fs.rmSync(dir,{recursive:true,force:true}))
 const source=path.join(dir,'source'),store=path.join(dir,'store')
 fs.mkdirSync(path.join(source,'history'),{recursive:true})
 const env={...process.env,NC_SRC_DIR:source,NC_SRC_HISTORY:path.join(source,'history'),NC_STORE:store,NC_PREVIEWS:'0'}
 const run=(...args)=>{const r=spawnSync(script,args,{env,encoding:'utf8',timeout:5000});assert.equal(r.status,0,r.stderr);return JSON.parse(r.stdout)}
 return {dir,source,store,env,run}
}
test('replacement updates retain identity and images; repeated ingestion is idempotent',t=>{
 const f=fixture(t),stamp=Date.now(),key=`${stamp}-42`,file=path.join(f.source,key+'.json')
 const image=path.join(f.dir,'image.png')
 const generated=spawnSync('magick',['-size','1x1','xc:red',image],{encoding:'utf8'});assert.equal(generated.status,0,generated.stderr)
 const entry={timestamp:stamp,originalId:42,app:'Download',desktopEntry:'download',summary:'Transfer',body:'10 percent',image}
 fs.writeFileSync(file,JSON.stringify(entry));f.run('sync')
 const retained=path.join(f.store,'images',key+'-image.png'),before=fs.statSync(retained,{bigint:true})
 entry.body='Download complete';fs.writeFileSync(file,JSON.stringify(entry));f.run('sync')
 const rows=f.run('list');assert.equal(rows.length,1);assert.equal(rows[0].body,entry.body);assert.equal(rows[0].desktopEntry,'download')
 assert.equal(fs.statSync(retained,{bigint:true}).mtimeNs,before.mtimeNs)
 const archive=fs.readFileSync(path.join(f.store,'archive.jsonl'),'utf8');f.run('sync');assert.equal(fs.readFileSync(path.join(f.store,'archive.jsonl'),'utf8'),archive)
 fs.unlinkSync(image);entry.body='Source removed';fs.writeFileSync(file,JSON.stringify(entry));f.run('sync');assert.equal(f.run('list')[0].image,rows[0].image);assert.ok(fs.existsSync(retained))
 f.run('remove',key);f.run('sync');assert.equal(f.run('list').length,0)
})
test('watcher announces replacements, external clear and removal, and remains quiet while idle',async t=>{
 const f=fixture(t),events=[],watch=spawn(script,['watch'],{env:f.env})
 let pending='';watch.stdout.on('data',chunk=>{pending+=chunk;let n;while((n=pending.indexOf('\n'))>=0){const line=pending.slice(0,n);pending=pending.slice(n+1);events.push(JSON.parse(line))}})
 t.after(()=>watch.kill())
 async function until(fn) { const end=Date.now()+5000;while(!fn()){assert.ok(Date.now()<end,JSON.stringify(events));await new Promise(r=>setTimeout(r,25))} }
 await until(()=>events.some(e=>e.event==='storeChanged'));events.length=0
 const stamp=Date.now(),key=`${stamp}-1`,file=path.join(f.source,key+'.json')
 const entry={timestamp:stamp,app:'Test',summary:'Before'}
 fs.writeFileSync(file,JSON.stringify(entry));await until(()=>events.some(e=>e.summary==='Before'))
 entry.summary='After';fs.writeFileSync(file,JSON.stringify(entry));await until(()=>events.some(e=>e.summary==='After'))
 await new Promise(r=>setTimeout(r,150));events.length=0;f.run('remove',key);await until(()=>events.some(e=>e.event==='storeChanged'))
 events.length=0;f.run('clear');await until(()=>events.some(e=>e.event==='storeChanged'))
 await new Promise(r=>setTimeout(r,150));events.length=0;await new Promise(r=>setTimeout(r,200));assert.equal(events.length,0)
})
test('queued archive refreshes and content comparisons do not drop updates',()=>{
 const source=fs.readFileSync(path.join(__dirname,'../Service.qml'),'utf8')
 const state=vm.createContext({entries:[{key:'1-1',body:'old'}],listLoadCount:0,loadPending:false,archiveRevision:2,listRevision:1,listProc:{running:true},storeCommand:a=>a,pageSize:500})
 state.root=state
 for(const name of ['load','differsFrom']) {const start=source.indexOf(`  function ${name}(`);vm.runInContext(source.slice(start,source.indexOf('\n  }',start)+4),state)}
 assert.equal(state.differsFrom([{key:'1-1',body:'new'}]),true)
 state.load();assert.equal(state.loadPending,true);state.listProc.running=false;state.load();assert.equal(state.listRevision,2);assert.equal(state.loadPending,false)
})

test('large archive pages contain one JSON array, filter before limiting, and keep newest order',t=>{
 const f=fixture(t);f.run('list')
 const base=Date.now()-100000,records=Array.from({length:1000},(_,i)=>({key:`${base+i+1}-1`,timestamp:base+i+1,body:i===10?'needle':'x'.repeat(500)}))
 fs.writeFileSync(path.join(f.store,'archive.jsonl'),records.map(JSON.stringify).join('\n')+'\ninvalid\n')
 const page=f.run('list','500');assert.equal(page.length,500);assert.equal(page[0].key,`${base+1000}-1`);assert.equal(page[499].key,`${base+501}-1`)
 // Paging past the first 500 and searching the whole archive.
 assert.equal(f.run('list','1001').length,1000)
 assert.deepEqual(f.run('list','500','NEEDLE').map(r=>r.key),[`${base+11}-1`])
 fs.writeFileSync(path.join(f.store,'cleared_at'),String(base+750));assert.equal(f.run('list','500').length,250)
 // Expired rows never show, even before retention runs.
 fs.writeFileSync(path.join(f.store,'cleared_at'),'0');const expired=spawnSync(script,['list','5000'],{env:{...f.env,NC_KEEP_DAYS:'1'},encoding:'utf8'});assert.equal(JSON.parse(expired.stdout).length,1000)
 fs.appendFileSync(path.join(f.store,'archive.jsonl'),JSON.stringify({key:'5-5',timestamp:5})+'\n');assert.equal(f.run('list','5000').length,1000)
 assert.deepEqual(f.run('list','0'),[])
 const bad=spawnSync(script,['list','invalid'],{env:f.env,encoding:'utf8'});assert.equal(bad.status,1);assert.equal(JSON.parse(bad.stdout).ok,false)
})
test('the source comes from the service (IPC), never from another plugin\'s config, and the handled journal is applied',t=>{
 const f=fixture(t),home=path.join(f.dir,'home'),config=path.join(home,'.config/omarchy')
 fs.mkdirSync(config,{recursive:true})
 const stamp=Date.now(),stock=path.join(home,'.local/state/omarchy/notifications'),foamy=path.join(f.dir,'foamy')
 for(const [dir,title,id] of [[stock,'Stock',1],[path.join(foamy,'popups'),'Foamy',2]]) {fs.mkdirSync(dir,{recursive:true});fs.writeFileSync(path.join(dir,`${stamp}-${id}.json`),JSON.stringify({timestamp:stamp,originalId:id,app:'Test',summary:title}))}
 // Foamy enabled in shell.json no longer changes anything by itself.
 fs.writeFileSync(path.join(config,'shell.json'),JSON.stringify({plugins:[{id:'foamy.notifications'}]}))
 const base={...f.env,HOME:home,XDG_CONFIG_HOME:path.join(home,'.config')};delete base.NC_SRC_DIR;delete base.NC_SRC_HISTORY
 const run=(env,...args)=>{const r=spawnSync(script,args,{env,encoding:'utf8',timeout:5000});assert.equal(r.status,0,r.stderr);return JSON.parse(r.stdout)}
 run(base,'sync');assert.deepEqual(run(base,'list').map(r=>r.summary),['Stock'])
 fs.rmSync(f.store,{recursive:true,force:true})
 const handled=path.join(foamy,'handled')
 const env={...base,NC_SOURCE:'foamy',NC_SRC_DIR:path.join(foamy,'popups'),NC_SRC_HISTORY:path.join(foamy,'history'),NC_HANDLED:handled,NC_STATE_FILE:path.join(foamy,'state.json')}
 run(env,'sync');assert.deepEqual(run(env,'list').map(r=>r.summary),['Foamy'])
 fs.writeFileSync(handled,`${stamp}-2\n`);run(env,'sync');assert.deepEqual(run(env,'list'),[])
 assert.ok(fs.existsSync(path.join(foamy,'popups',`${stamp}-2.json`)),'source files are read-only')
})
