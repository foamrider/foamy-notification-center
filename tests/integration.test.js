const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const {spawnSync, spawn} = require('node:child_process')
const vm = require('node:vm')
const helper = require('./helper.cjs')
function fixture(t) {
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'foamy-integration-'))
 t.after(()=>fs.rmSync(dir,{recursive:true,force:true}))
 const source=path.join(dir,'source'),store=path.join(dir,'store')
 fs.mkdirSync(path.join(source,'history'),{recursive:true})
 const env={...process.env,NC_SRC_DIR:source,NC_SRC_HISTORY:path.join(source,'history'),NC_STORE:store,NC_PREVIEWS:'0'}
 // A crash (no status) names its signal.
 const run=(...args)=>{const r=helper.spawnSync(args,{env,encoding:'utf8',timeout:5000});assert.equal(r.status,0,r.stderr||String(r.signal));return JSON.parse(r.stdout)}
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
 const f=fixture(t),events=[],watch=helper.spawn(['watch'],{env:f.env})
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

test('a list read older than a watcher event is dropped and repeated; invalid or failed reads show an error',()=>{
 const source=fs.readFileSync(path.join(__dirname,'../Service.qml'),'utf8')
 const take=name=>{const start=source.indexOf(`  function ${name}(`);assert.ok(start>=0,name);return source.slice(start,source.indexOf('\n  }',start)+4)}
 // The handlers of listProc as Quickshell runs them: the reply's text, then the exit.
 const list=source.indexOf('    id: listProc\n'),at=source.indexOf('      onStreamFinished: {',list);assert.ok(list>=0&&at>list)
 const finished=source.slice(source.indexOf('{',at)+1,source.indexOf('\n      }',at))
 const exited=require('./qml-process.cjs').handler(source,'listProc','onExited');assert.ok(exited.startsWith('function'))
 const FoamyNative=require('../kit/node-loader.cjs').load('FoamyNative')
 const service=()=>{
  const ctx=vm.createContext({FoamyNative,console:{warn(){}},JSON,helperUnavailable:false,entries:[{key:'1-1',body:'old'}],loadError:'',loadPending:false,
   listRevision:1,archiveRevision:1,listLimit:2,hasMore:false,removedKeys:{},searchQuery:'',unreadSource:'untouched',loaded:false,resets:0,text:'',
   reloadArchive:{restarts:0,restart(){this.restarts++}}})
  ctx.root=ctx;ctx.entriesReset=()=>{ctx.resets++}
  for(const name of ['visibleEntries','differsFrom','storeUnavailable']) vm.runInContext(take(name),ctx)
  return ctx
 }
 const finish=(ctx,text)=>{ctx.text=text;vm.runInContext('(function(){'+finished+'})()',ctx)}
 const exit=(ctx,code)=>vm.runInContext(`(${exited})(${code}, 0)`,ctx)
 const keys=ctx=>Array.from(ctx.entries,e=>e.key)
 const rows=JSON.stringify([{key:'3-1'},{key:'2-1'},{key:'1-2'}])
 // A watcher event arrived during the read: drop the reply and read again.
 let ctx=service();ctx.archiveRevision=2;finish(ctx,rows)
 assert.equal(ctx.loadPending,true);assert.equal(ctx.reloadArchive.restarts,1);assert.deepEqual(keys(ctx),['1-1']);assert.equal(ctx.resets,0)
 // A reply that is not a JSON array keeps the list and says so.
 for(const text of ['not json','{}']) {
  ctx=service();finish(ctx,text)
  assert.equal(ctx.loadError,'Invalid notification history response.',text);assert.deepEqual(keys(ctx),['1-1'],text);assert.equal(ctx.loaded,false,text)
 }
 // One row past the page means more; removed keys stay hidden; the unread
 // badge follows the unfiltered list only.
 ctx=service();ctx.loadError='old error';ctx.removedKeys={'2-1':true};finish(ctx,rows)
 assert.equal(ctx.hasMore,true);assert.deepEqual(keys(ctx),['3-1']);assert.deepEqual(Array.from(ctx.unreadSource,e=>e.key),['3-1'])
 assert.equal(ctx.loadError,'');assert.equal(ctx.loaded,true);assert.equal(ctx.resets,1)
 ctx=service();ctx.searchQuery='x';finish(ctx,JSON.stringify([{key:'3-1'}]))
 assert.equal(ctx.hasMore,false);assert.deepEqual(keys(ctx),['3-1']);assert.equal(ctx.unreadSource,'untouched')
 // An unchanged list does not reset the view; a changed one does.
 finish(ctx,JSON.stringify([{key:'3-1'}]));assert.equal(ctx.resets,1)
 finish(ctx,JSON.stringify([{key:'4-1'}]));assert.equal(ctx.resets,2);assert.deepEqual(keys(ctx),['4-1'])
 // A failed read says so and runs a queued read; a missing helper shows its own text.
 ctx=service();ctx.loadPending=true;exit(ctx,1)
 assert.match(ctx.loadError,/Could not refresh notification history/);assert.equal(ctx.reloadArchive.restarts,1)
 ctx=service();exit(ctx,0);assert.equal(ctx.loadError,'');assert.equal(ctx.reloadArchive.restarts,0)
 ctx=service();ctx.loadPending=true;exit(ctx,127)
 assert.equal(ctx.loadError,FoamyNative.UNAVAILABLE_TEXT);assert.equal(ctx.reloadArchive.restarts,0)
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
 fs.writeFileSync(path.join(f.store,'cleared_at'),'0');const expired=helper.spawnSync(['list','5000'],{env:{...f.env,NC_KEEP_DAYS:'1'},encoding:'utf8'});assert.equal(JSON.parse(expired.stdout).length,1000)
 fs.appendFileSync(path.join(f.store,'archive.jsonl'),JSON.stringify({key:'5-5',timestamp:5})+'\n');assert.equal(f.run('list','5000').length,1000)
 assert.deepEqual(f.run('list','0'),[])
 const bad=helper.spawnSync(['list','invalid'],{env:f.env,encoding:'utf8'});assert.equal(bad.status,1);assert.equal(JSON.parse(bad.stdout).ok,false)
})
test('the source comes from the service (IPC), never from another plugin\'s config, and the handled journal is applied',t=>{
 const f=fixture(t),home=path.join(f.dir,'home'),config=path.join(home,'.config/omarchy')
 fs.mkdirSync(config,{recursive:true})
 const stamp=Date.now(),stock=path.join(home,'.local/state/omarchy/notifications'),foamy=path.join(f.dir,'foamy')
 for(const [dir,title,id] of [[stock,'Stock',1],[path.join(foamy,'popups'),'Foamy',2]]) {fs.mkdirSync(dir,{recursive:true});fs.writeFileSync(path.join(dir,`${stamp}-${id}.json`),JSON.stringify({timestamp:stamp,originalId:id,app:'Test',summary:title}))}
 // Foamy enabled in shell.json no longer changes anything by itself.
 fs.writeFileSync(path.join(config,'shell.json'),JSON.stringify({plugins:[{id:'foamy.notifications'}]}))
 const base={...f.env,HOME:home,XDG_CONFIG_HOME:path.join(home,'.config')};delete base.NC_SRC_DIR;delete base.NC_SRC_HISTORY
 const run=(env,...args)=>{const r=helper.spawnSync(args,{env,encoding:'utf8',timeout:5000});assert.equal(r.status,0,r.stderr);return JSON.parse(r.stdout)}
 run(base,'sync');assert.deepEqual(run(base,'list').map(r=>r.summary),['Stock'])
 fs.rmSync(f.store,{recursive:true,force:true})
 const handled=path.join(foamy,'handled')
 const env={...base,NC_SOURCE:'foamy',NC_SRC_DIR:path.join(foamy,'popups'),NC_SRC_HISTORY:path.join(foamy,'history'),NC_HANDLED:handled,NC_STATE_FILE:path.join(foamy,'state.json')}
 run(env,'sync');assert.deepEqual(run(env,'list').map(r=>r.summary),['Foamy'])
 fs.writeFileSync(handled,`${stamp}-2\n`);run(env,'sync');assert.deepEqual(run(env,'list'),[])
 assert.ok(fs.existsSync(path.join(foamy,'popups',`${stamp}-2.json`)),'source files are read-only')
})
test('a key in Foamy\'s handled journal before its file arrives is never archived, even after the journal moves on',async t=>{
 const f=fixture(t),foamy=path.join(f.dir,'foamy'),handled=path.join(foamy,'handled'),history=path.join(foamy,'history')
 fs.mkdirSync(path.join(foamy,'popups'),{recursive:true});fs.mkdirSync(history,{recursive:true});fs.writeFileSync(handled,'')
 const env={...f.env,NC_SOURCE:'foamy',NC_SRC_DIR:path.join(foamy,'popups'),NC_SRC_HISTORY:history,NC_HANDLED:handled,NC_STATE_FILE:path.join(foamy,'state.json')}
 const run=(...args)=>{const r=helper.spawnSync(args,{env,encoding:'utf8',timeout:5000});assert.equal(r.status,0,r.stderr);return JSON.parse(r.stdout)}
 const events=[],watch=helper.spawn(['watch'],{env})
 let pending='';watch.stdout.on('data',chunk=>{pending+=chunk;let n;while((n=pending.indexOf('\n'))>=0){events.push(JSON.parse(pending.slice(0,n)));pending=pending.slice(n+1)}})
 t.after(()=>watch.kill())
 async function until(fn){const end=Date.now()+5000;while(!fn()){assert.ok(Date.now()<end,JSON.stringify(events));await new Promise(r=>setTimeout(r,25))}}
 await until(()=>events.some(e=>e.event==='storeChanged'))
 const stamp=Date.now(),write=(id,summary)=>fs.writeFileSync(path.join(history,`${stamp}-${id}.json`),JSON.stringify({timestamp:stamp,originalId:id,app:'Test',summary}))
 // The journal names the key first (its `handled` IPC never arrives), then the file lands.
 fs.writeFileSync(handled,`${stamp}-3\n`);await new Promise(r=>setTimeout(r,150))
 write(3,'Handled');write(4,'Fresh')
 await until(()=>events.some(e=>e.summary==='Fresh'))
 assert.ok(!events.some(e=>e.summary==='Handled'),JSON.stringify(events))
 assert.deepEqual(run('list').map(r=>r.summary),['Fresh'])
 // Durable: Foamy trimming its journal while the file stays does not bring it back.
 fs.writeFileSync(handled,'');run('sync');assert.deepEqual(run('list').map(r=>r.summary),['Fresh'])
})
test('a first page that fits the viewport (collapsed stacks) still loads the next page',()=>{
 const panel=fs.readFileSync(path.join(__dirname,'../Panel.qml'),'utf8'),service=fs.readFileSync(path.join(__dirname,'../Service.qml'),'utf8')
 const take=(src,name)=>{const start=src.indexOf(`  function ${name}(`);assert.ok(start>=0,name);return src.slice(start,src.indexOf('\n  }',start)+4)}
 const store=vm.createContext({hasMore:false,listLimit:500,pageSize:500,maxItems:1000,loads:0,listProc:{running:false},load(){store.loads++}})
 store.root=store;vm.runInContext(take(service,'loadMore'),store)
 Object.defineProperty(store,'listing',{get(){return store.listProc.running}})
 // 500 rows of one app collapse to a header and one message: the list sits at its end from the start.
 const ui=vm.createContext({opened:true,list:{atYEnd:true},store});ui.root=ui;vm.runInContext(take(panel,'pageIfAtEnd'),ui)
 // The read is still running when hasMore turns true: nothing yet, one request per read.
 store.listProc.running=true;store.hasMore=true;ui.pageIfAtEnd();assert.equal(store.loads,0)
 // The read ends (onListingChanged) with atYEnd unchanged: the next page loads without any scroll.
 store.listProc.running=false;ui.pageIfAtEnd();assert.equal(store.listLimit,1000);assert.equal(store.loads,1)
 store.listProc.running=true;ui.pageIfAtEnd();store.listProc.running=false;ui.pageIfAtEnd();assert.equal(store.listLimit,1000,'never past maxItems')
 ui.opened=false;store.listLimit=500;ui.pageIfAtEnd();assert.equal(store.listLimit,500,'closed: no paging')
 // The panel re-checks when `listing` ends (tests/panel-ui.py, real Panel.qml); it must follow the read process.
 assert.match(service,/readonly property bool listing: listProc\.running/)
})
test('search folds Unicode case like the panel and matches the query literally',t=>{
 const f=fixture(t);f.run('list')
 const stamp=Date.now()-1000
 fs.writeFileSync(path.join(f.store,'archive.jsonl'),[{key:`${stamp}-1`,timestamp:stamp,summary:'ÉCOLE ouverte'},{key:`${stamp}-2`,timestamp:stamp,summary:'axb'}].map(JSON.stringify).join('\n')+'\n')
 assert.deepEqual(f.run('list','10','école').map(r=>r.key),[`${stamp}-1`])
 assert.deepEqual(f.run('list','10','a.b'),[])
 assert.deepEqual(f.run('list','10','['),[])
})
test('a source directory created after the watcher started is picked up',async t=>{
 const f=fixture(t),late=path.join(f.dir,'late','notifications')
 const env={...f.env,NC_SRC_DIR:late,NC_SRC_HISTORY:path.join(late,'history')}
 const events=[],watch=helper.spawn(['watch'],{env})
 let pending='';watch.stdout.on('data',chunk=>{pending+=chunk;let n;while((n=pending.indexOf('\n'))>=0){events.push(JSON.parse(pending.slice(0,n)));pending=pending.slice(n+1)}})
 t.after(()=>watch.kill())
 async function until(fn){const end=Date.now()+5000;while(!fn()){assert.ok(Date.now()<end,JSON.stringify(events));await new Promise(r=>setTimeout(r,25))}}
 await until(()=>events.some(e=>e.event==='storeChanged'))
 assert.equal(fs.existsSync(late),false,'the watcher never creates the source directory')
 const stamp=Date.now()
 // The directory appears with its file (renamed into place), so the watcher's sync cannot run between the two.
 const staging=path.join(f.dir,'staging');fs.mkdirSync(path.join(staging,'notifications'),{recursive:true})
 fs.writeFileSync(path.join(staging,'notifications',`${stamp}-7.json`),JSON.stringify({timestamp:stamp,originalId:7,app:'Late',summary:'Arrived'}))
 fs.renameSync(staging,path.dirname(late))
 await until(()=>events.some(e=>e.event==='rewatch'))
 assert.deepEqual(f.run('list').map(r=>r.summary),['Arrived'])
})
test('a retention pass reports every pruned Foamy key, in bounded events',async t=>{
 const f=fixture(t),stamp=Date.now()-1000
 f.run('list')
 fs.writeFileSync(path.join(f.store,'archive.jsonl'),Array.from({length:2101},(_,i)=>JSON.stringify({key:`${stamp+i}-1`,timestamp:stamp+i,summary:'x'})).join('\n')+'\n')
 const events=[],watch=helper.spawn(['watch'],{env:{...f.env,NC_SOURCE:'foamy',NC_MAX_ITEMS:'100'}})
 let pending='';watch.stdout.on('data',chunk=>{pending+=chunk;let n;while((n=pending.indexOf('\n'))>=0){events.push(JSON.parse(pending.slice(0,n)));pending=pending.slice(n+1)}})
 t.after(()=>watch.kill())
 const end=Date.now()+8000
 while(!events.some(e=>e.event==='storeChanged')){assert.ok(Date.now()<end);await new Promise(r=>setTimeout(r,25))}
 const pruned=events.filter(e=>e.event==='pruned')
 assert.equal(pruned.length,3)
 assert.ok(pruned.every(e=>e.keys.length<=1000))
 assert.equal(new Set(pruned.flatMap(e=>e.keys)).size,2001)
})
test('whitespace-only or truncated source files are skipped, not fatal',t=>{
 const f=fixture(t),stamp=Date.now()
 fs.writeFileSync(path.join(f.source,`${stamp}-1.json`),'  \n')
 fs.writeFileSync(path.join(f.source,`${stamp}-2.json`),JSON.stringify({timestamp:stamp,originalId:2,app:'Ok',summary:'Kept'}))
 // A file caught mid-write by the source.
 fs.writeFileSync(path.join(f.source,`${stamp}-3.json`),'{"timestamp":'+stamp+',"app":"Half')
 f.run('sync')
 assert.deepEqual(f.run('list').map(r=>r.summary),['Kept'])
})
test('a source nested as deep as the parser allows is archived without its command; a deeper file is skipped',t=>{
 const f=fixture(t),stamp=Date.now()
 // execArgv is the sender's omarchy-exec-argv hint, parsed as JSON by the helper.
 const deep='['.repeat(9999)+']'.repeat(9999)
 fs.writeFileSync(path.join(f.source,`${stamp}-1.json`),JSON.stringify({timestamp:stamp,app:'Deep',summary:'Kept',execArgv:deep}))
 fs.writeFileSync(path.join(f.source,`${stamp}-2.json`),'['.repeat(10001)+']'.repeat(10001))
 f.run('sync')
 assert.deepEqual(f.run('list').map(r=>[r.summary,r.file,r.execArgv]),[['Kept','',undefined]])
})
test('an archive whose last line lost its newline still takes the next arrival on a line of its own',t=>{
 const f=fixture(t),stamp=Date.now()
 f.run('list')
 const archive=path.join(f.store,'archive.jsonl')
 fs.writeFileSync(archive,JSON.stringify({key:`${stamp-10}-1`,timestamp:stamp-10,summary:'Before'}))
 fs.writeFileSync(path.join(f.source,`${stamp}-2.json`),JSON.stringify({timestamp:stamp,app:'A',summary:'After'}))
 f.run('sync')
 assert.deepEqual(f.run('list').map(r=>r.summary),['After','Before'])
})
test('archive search matches the joined app, title and text like the panel',t=>{
 const f=fixture(t);f.run('list')
 const stamp=Date.now()-1000
 fs.writeFileSync(path.join(f.store,'archive.jsonl'),[{key:`${stamp}-1`,timestamp:stamp,app:'Firefox',summary:'Download complete',body:'file.zip'},{key:`${stamp}-2`,timestamp:stamp,app:'',summary:'x',body:''}].map(JSON.stringify).join('\n')+'\n')
 assert.deepEqual(f.run('list','10','firefox download').map(r=>r.key),[`${stamp}-1`])
 assert.deepEqual(f.run('list','10','complete file').map(r=>r.key),[`${stamp}-1`])
 assert.deepEqual(f.run('list','10','unknown app x').map(r=>r.key),[`${stamp}-2`])
})
test('retention is by timestamp and pruned source copies never re-enter the archive',t=>{
 const f=fixture(t),stamp=Date.now()-10000,env={...f.env,NC_MAX_ITEMS:'2'}
 const run=(...args)=>{const r=helper.spawnSync(args,{env,encoding:'utf8',timeout:5000});assert.equal(r.status,0,r.stderr);return JSON.parse(r.stdout)}
 for(const i of [1,2,3]) fs.writeFileSync(path.join(f.source,'history',`${stamp+i}-${i}.json`),JSON.stringify({timestamp:stamp+i,originalId:i,app:'T',summary:String(i)}))
 for(let round=0;round<4;round++){run('sync');assert.deepEqual(run('list').map(r=>r.summary),['3','2'],`sync ${round}`)}
 // A late-arriving older copy does not displace newer rows either.
 fs.writeFileSync(path.join(f.source,`${stamp}-9.json`),JSON.stringify({timestamp:stamp,originalId:9,app:'T',summary:'old'}))
 run('sync');assert.deepEqual(run('list').map(r=>r.summary),['3','2'])
 // Source copies older than the age limit are not archived at all.
 fs.writeFileSync(path.join(f.source,'1000-8.json'),JSON.stringify({timestamp:1000,originalId:8,app:'T',summary:'ancient'}))
 run('sync');assert.ok(!fs.readFileSync(path.join(f.store,'archive.jsonl'),'utf8').includes('ancient'))
})
test('pages are newest by timestamp even when an old row arrived last',t=>{
 const f=fixture(t);f.run('list')
 const b=Date.now()-100000
 fs.writeFileSync(path.join(f.store,'archive.jsonl'),[...[0,1,2].map(i=>({key:`${b+10+i}-1`,timestamp:b+10+i,summary:'new'+i})),{key:`${b}-9`,timestamp:b,summary:'late-old'}].map(JSON.stringify).join('\n')+'\n')
 assert.deepEqual(f.run('list','3').map(r=>r.summary),['new2','new1','new0'])
})
test('rows retained across an equal-timestamp split keep taking updates',t=>{
 const f=fixture(t),stamp=Date.now()-5000,env={...f.env,NC_MAX_ITEMS:'2'}
 const run=(...args)=>{const r=helper.spawnSync(args,{env,encoding:'utf8',timeout:5000});assert.equal(r.status,0,r.stderr);return JSON.parse(r.stdout)}
 for(const i of [1,2,3]) fs.writeFileSync(path.join(f.source,'history',`${stamp}-${i}.json`),JSON.stringify({timestamp:stamp,originalId:i,app:'T',summary:'v1'}))
 run('sync');const kept=run('list').map(r=>r.key).sort();assert.deepEqual(kept,[`${stamp}-2`,`${stamp}-3`])
 fs.writeFileSync(path.join(f.source,'history',`${stamp}-3.json`),JSON.stringify({timestamp:stamp,originalId:3,app:'T',summary:'v2'}))
 run('sync');assert.equal(run('list').find(r=>r.key===`${stamp}-3`).summary,'v2')
 assert.ok(!run('list').some(r=>r.key===`${stamp}-1`))
})
test('a dismissal tombstone outlives any number of older rows while its source copy survives',t=>{
 const f=fixture(t),now=Date.now(),key=`${now-1000}-1`
 fs.writeFileSync(path.join(f.source,'history',`${key}.json`),JSON.stringify({timestamp:now-1000,originalId:1,app:'T',summary:'dismissed'}))
 f.run('sync');f.run('remove',key)
 const older=Array.from({length:2100},(_,i)=>JSON.stringify({key:`${now-900000+i}-${i+10}`,timestamp:now-900000+i,summary:'x'}))
 fs.appendFileSync(path.join(f.store,'archive.jsonl'),older.join('\n')+'\n')
 // The service removes in batches of at most 100 keys.
 for(let b=0;b<2100;b+=100) f.run('remove',...Array.from({length:100},(_,i)=>`${now-900000+b+i}-${b+i+10}`))
 f.run('prune');f.run('sync')
 assert.ok(!f.run('list','5000').some(r=>r.key===key),'the dismissed notification came back')
})
test('lowering then raising the age limit never brings back a dismissed notification',t=>{
 const f=fixture(t),ts=Date.now()-2*86400000,key=`${ts}-1`
 fs.writeFileSync(path.join(f.source,'history',`${key}.json`),JSON.stringify({timestamp:ts,originalId:1,app:'T',summary:'old'}))
 const run=(days,...args)=>{const r=helper.spawnSync(args,{env:{...f.env,NC_KEEP_DAYS:String(days)},encoding:'utf8',timeout:5000});assert.equal(r.status,0,r.stderr);return JSON.parse(r.stdout)}
 run(30,'sync');run(30,'remove',key);run(1,'prune');run(30,'sync')
 assert.deepEqual(run(30,'list'),[])
 assert.match(fs.readFileSync(path.join(f.store,'dismissed'),'utf8'),new RegExp(`^${key} `,'m'),'the tombstone outlives the age limit while the source copy exists')
})
test('retention runs on its deadline while events keep arriving (30-minute events over 3 hours, time scaled 1:1800)',async t=>{
 // Interval 2 s stands for the hourly deadline; an event every second stands for every 30 minutes.
 const f=fixture(t),events=[],watch=helper.spawn(['watch'],{env:{...f.env,NC_RETENTION_INTERVAL:'2',NC_KEEP_DAYS:'1'}})
 let pending='';watch.stdout.on('data',chunk=>{pending+=chunk;let n;while((n=pending.indexOf('\n'))>=0){events.push(JSON.parse(pending.slice(0,n)));pending=pending.slice(n+1)}})
 t.after(()=>watch.kill())
 const until=async fn=>{const end=Date.now()+5000;while(!fn()){assert.ok(Date.now()<end,JSON.stringify(events));await new Promise(r=>setTimeout(r,25))}}
 await until(()=>events.some(e=>e.event==='storeChanged'))
 const archive=path.join(f.store,'archive.jsonl'),expired=JSON.stringify({key:'5000-1',timestamp:5000,summary:'expired'})
 fs.appendFileSync(archive,expired+'\n')
 let gone=false
 for(let i=0;i<6&&!gone;i++){
  fs.writeFileSync(path.join(f.store,'seen'),String(Date.now()))   // steady traffic (panel opened)
  await new Promise(r=>setTimeout(r,1000))
  gone=!fs.readFileSync(archive,'utf8').includes('"expired"')
 }
 assert.ok(gone,'retention never ran while events kept arriving')
})
test('any archive-setting change restarts the running watcher, even without a source change',()=>{
 const source=fs.readFileSync(path.join(__dirname,'../Service.qml'),'utf8')
 const start=source.indexOf('  onStoreEnvironmentChanged: if (watchProc.running) {');assert.ok(start>=0)
 const body=source.slice(source.indexOf('{',start)+1,source.indexOf('\n  }',start))
 const ctx=vm.createContext({watchProc:{running:true},sourceRestartPending:false})
 vm.runInContext(body,ctx)
 assert.equal(ctx.watchProc.running,false);assert.equal(ctx.sourceRestartPending,true)
})
test('the store environment carries the limits and the resolved source paths',()=>{
 const source=fs.readFileSync(path.join(__dirname,'../Service.qml'),'utf8')
 // The binding's body, run as the function QML evaluates.
 const start=source.indexOf('  readonly property var storeEnvironment: {');assert.ok(start>=0)
 const body=source.slice(source.indexOf('{',start)+1,source.indexOf('\n  }\n',start))
 const environment=(sourceKind,sourceInfo,vars={})=>{
  const ctx=vm.createContext({keepDays:7,maxItems:60,showPreview:false,sourceKind,sourceInfo,String,Quickshell:{env:name=>vars[name]}})
  ctx.root=ctx
  return JSON.parse(JSON.stringify(vm.runInContext('(function(){'+body+'})()',ctx)))
 }
 const limits={NC_KEEP_DAYS:'7',NC_MAX_ITEMS:'60',NC_PREVIEWS:'0'}
 const foamy=environment('foamy',{popups:'/p',history:'/h',handled:'/j',state:'/s'})
 assert.deepEqual(foamy,{...limits,NC_SOURCE:'foamy',NC_SRC_DIR:'/p',NC_SRC_HISTORY:'/h',NC_HANDLED:'/j',NC_STATE_FILE:'/s'})
 assert.deepEqual(environment('legacy',{},{XDG_STATE_HOME:'/x',HOME:'/home/u'}),
  {...limits,NC_SOURCE:'legacy',NC_SRC_DIR:'/x/omarchy/notifications',NC_STATE_FILE:'/x/omarchy/notifications.json'})
 assert.deepEqual(environment('legacy',{},{HOME:'/home/u'}),
  {...limits,NC_SOURCE:'legacy',NC_SRC_DIR:'/home/u/.local/state/omarchy/notifications',NC_STATE_FILE:'/home/u/.local/state/omarchy/notifications.json'})
 assert.deepEqual(environment('',{}),{...limits,NC_SOURCE:'stock'})
 // Every value the helper reads from its environment is passed (the rest are
 // test and helper-internal settings).
 const native=path.join(__dirname,'../native/src'),script=fs.readdirSync(native).filter(n=>n.endsWith('.rs')).map(n=>fs.readFileSync(path.join(native,n),'utf8')).join('\n')
 for(const name of new Set(script.match(/NC_[A-Z_]+/g))) if(!['NC_STORE','NC_WATCHING','NC_RETENTION_INTERVAL','NC_LOCK_WAIT_MS'].includes(name)) assert.ok(Object.hasOwn(foamy,name),`the helper reads ${name} but the service does not pass it`)
})
test('the source is the Foamy store it reports, an older Foamy, or stock, and a change restarts the watcher',()=>{
 const source=fs.readFileSync(path.join(__dirname,'../Service.qml'),'utf8')
 const take=name=>{const start=source.indexOf(`  function ${name}(`);assert.ok(start>=0,name);return source.slice(start,source.indexOf('\n  }',start)+4)}
 const service=answers=>{
  const ctx=vm.createContext({JSON,Number,String,sourceKind:'',sourceInfo:{},sourceRestartPending:false,calls:[],retries:0,restarts:0,
   watchProc:{running:true},restartWatch:{interval:30000,restart(){ctx.restarts++}},sourceRetry:{restart(){ctx.retries++}},
   peer:{call(target,method,args,done){ctx.calls.push(method);const [ok,output]=answers[method]||[false,''];done(ok,output)}}})
  ctx.root=ctx
  for(const name of ['resolveSource','useSource']) vm.runInContext(take(name),ctx)
  return ctx
 }
 const info={layout:'foamy-files',version:2,ready:true,popups:'/p',history:'/h',handled:'/j',state:'/s'}
 // Contract v2: the reported paths; the running watcher stops so it restarts with them.
 let ctx=service({storeInfo:[true,JSON.stringify(info)]});ctx.resolveSource()
 assert.equal(ctx.sourceKind,'foamy');assert.equal(ctx.sourceInfo.popups,'/p');assert.equal(ctx.sourceInfo.state,'/s')
 assert.equal(ctx.watchProc.running,false);assert.equal(ctx.sourceRestartPending,true);assert.deepEqual(ctx.calls,['storeInfo'])
 // The same answer again leaves a running watcher alone.
 ctx.watchProc.running=true;ctx.sourceRestartPending=false;ctx.resolveSource()
 assert.equal(ctx.watchProc.running,true);assert.equal(ctx.sourceRestartPending,false);assert.equal(ctx.restarts,0)
 // A watcher that is not running starts soon.
 ctx.watchProc.running=false;ctx.resolveSource();assert.equal(ctx.restarts,1);assert.equal(ctx.restartWatch.interval,50)
 // A Foamy store that is not ready yet is asked again later; nothing changes now.
 ctx=service({storeInfo:[true,JSON.stringify({...info,ready:false})]});ctx.resolveSource()
 assert.equal(ctx.retries,1);assert.equal(ctx.sourceKind,'');assert.equal(ctx.watchProc.running,true);assert.deepEqual(ctx.calls,['storeInfo'])
 // No usable storeInfo: an older Foamy answers ping, else the stock daemon.
 for(const storeInfo of [[true,JSON.stringify({...info,version:1})],[true,JSON.stringify({...info,layout:'other'})],[true,'not json'],[false,'']]) {
  for(const [ping,kind] of [[[true,'ok\n'],'legacy'],[[true,'x'],'stock'],[[false,'ok'],'stock']]) {
   ctx=service({storeInfo,ping});ctx.resolveSource()
   assert.deepEqual(ctx.calls,['storeInfo','ping'],storeInfo[1]);assert.equal(ctx.sourceKind,kind,`${storeInfo[1]} ${ping}`)
   assert.equal(JSON.stringify(ctx.sourceInfo),'{}');assert.equal(ctx.sourceRestartPending,true)
  }
 }
})
test('Clear all uses the cutoff captured at the click, so later arrivals survive (as in Foamy)',t=>{
 const f=fixture(t);f.run('list')
 const now=Date.now()
 fs.writeFileSync(path.join(f.store,'archive.jsonl'),[{key:`${now-5000}-1`,timestamp:now-5000,summary:'before'},{key:`${now-1000}-2`,timestamp:now-1000,summary:'after the click'}].map(JSON.stringify).join('\n')+'\n')
 f.run('clear',String(now-3000))
 assert.deepEqual(f.run('list').map(r=>r.summary),['after the click'])
 assert.equal(fs.readFileSync(path.join(f.store,'cleared_at'),'utf8').trim(),String(now-3000))
 // An older cutoff never lowers the clear line.
 f.run('clear',String(now-4000));assert.equal(fs.readFileSync(path.join(f.store,'cleared_at'),'utf8').trim(),String(now-3000))
 const bad=helper.spawnSync(['clear','../x'],{env:f.env,encoding:'utf8'});assert.notEqual(bad.status,0)
})
test('a clear whose clear line cannot be written fails and leaves the archive as it was',t=>{
 // Without a durable clear line nothing keeps cleared ts-id keys out of the
 // next sync (I1), so the rows must stay and the caller must hear it failed.
 const f=fixture(t);f.run('list')
 const now=Date.now(),archive=path.join(f.store,'archive.jsonl')
 fs.writeFileSync(archive,JSON.stringify({key:`${now-5000}-1`,timestamp:now-5000,summary:'kept'})+'\n')
 const before=fs.readFileSync(archive,'utf8')
 fs.mkdirSync(path.join(f.store,'cleared_at'))
 const r=helper.spawnSync(['clear',String(now-1000)],{env:f.env,encoding:'utf8',timeout:5000})
 assert.equal(r.status,1,r.stdout)
 assert.deepEqual(JSON.parse(r.stdout),{ok:false,error:'could not clear notifications'})
 assert.equal(fs.readFileSync(archive,'utf8'),before)
})
test('a seen stamp that cannot be written fails instead of answering ok',t=>{
 // A stamp lost on disk makes the badge count already-seen rows as new after
 // the next start, so the write's failure must reach the caller.
 const f=fixture(t);f.run('seen','5')
 fs.rmSync(path.join(f.store,'seen'));fs.mkdirSync(path.join(f.store,'seen'))
 const r=helper.spawnSync(['seen','1730000000123'],{env:f.env,encoding:'utf8',timeout:5000})
 assert.equal(r.status,1,r.stdout)
 assert.deepEqual(JSON.parse(r.stdout),{ok:false,error:'could not save seen'})
})
test('a rewatch after a source directory appears keeps its pruned events',async t=>{
 const f=fixture(t),late=path.join(f.dir,'late','popups'),now=Date.now()
 const env={...f.env,NC_SOURCE:'foamy',NC_MAX_ITEMS:'2',NC_SRC_DIR:late,NC_SRC_HISTORY:path.join(f.dir,'late','history')}
 fs.mkdirSync(f.store,{recursive:true})
 fs.writeFileSync(path.join(f.store,'archive.jsonl'),[1,2].map(i=>JSON.stringify({key:`${now-9000+i}-${i}`,timestamp:now-9000+i,summary:'old '+i})).join('\n')+'\n')
 const events=[],watch=helper.spawn(['watch'],{env})
 let pending='';watch.stdout.on('data',chunk=>{pending+=chunk;let n;while((n=pending.indexOf('\n'))>=0){events.push(JSON.parse(pending.slice(0,n)));pending=pending.slice(n+1)}})
 t.after(()=>watch.kill())
 const until=async fn=>{const end=Date.now()+5000;while(!fn()){assert.ok(Date.now()<end,JSON.stringify(events));await new Promise(r=>setTimeout(r,25))}}
 await until(()=>events.some(e=>e.event==='storeChanged'))
 const staging=path.join(f.dir,'staging');fs.mkdirSync(path.join(staging,'popups'),{recursive:true})
 fs.writeFileSync(path.join(staging,'popups',`${now}-7.json`),JSON.stringify({timestamp:now,originalId:7,app:'Late',summary:'new'}))
 fs.renameSync(staging,path.dirname(late))
 await until(()=>events.some(e=>e.event==='rewatch'))
 const pruned=events.filter(e=>e.event==='pruned').flatMap(e=>e.keys)
 assert.deepEqual(pruned,[`${now-8999}-1`],'the dropped Foamy key reaches the service for releaseHistory')
})
test('every store process the service launches gets the resolved store environment',()=>{
 const source=fs.readFileSync(path.join(__dirname,'../Service.qml'),'utf8')
 // Each Process whose command runs the store script (root.script / storeCommand).
 const blocks=source.split(/\n  Process \{/).slice(1).map(b=>b.slice(0,b.indexOf('\n  }')))
 const store=blocks.filter(b=>/id: (removeProc|clearProc|watchProc|listProc|seenProc|markProc)\b/.test(b)||/root\.script|storeCommand/.test(b))
 assert.ok(store.length>=4)
 for(const b of store) assert.match(b,/environment: root\.storeEnvironment/,b.split('\n')[1])
 assert.match(source,/id: markProc\n    environment: root\.storeEnvironment/)
 // Commands are built from values captured when the work was requested.
 assert.match(source,/command: root\.storeCommand\(\["clear", cut\]\)/)
})
test('a seen stamp taken while a write runs is written afterwards, not dropped',()=>{
 const source=fs.readFileSync(path.join(__dirname,'../Service.qml'),'utf8')
 const fn=source.slice(source.indexOf('  function markSeen() {'),source.indexOf('\n  }',source.indexOf('  function markSeen() {'))+4)
 let clock=10
 const commands=[],proc={running:false,command:[]}
 const ctx=vm.createContext({Date:{now:()=>clock},String,root:null,markProc:proc,seenPending:''})
 ctx.root=ctx;ctx.storeCommand=a=>a
 Object.defineProperty(proc,'running',{get(){return this._r||false},set(v){this._r=v;if(v)commands.push(this.command[1])}})
 vm.runInContext(fn,ctx)
 ctx.markSeen();clock=20;ctx.markSeen()
 assert.deepEqual(commands,['10']);assert.equal(ctx.seenPending,'20')
 const exit=source.slice(source.indexOf('{',source.indexOf('onExited: {',source.indexOf('id: markProc')))+1,source.indexOf('\n    }',source.indexOf('id: markProc')))
 proc._r=false
 const ectx=vm.createContext({root:ctx})
 Object.defineProperty(ectx,'command',{get(){return proc.command},set(v){proc.command=v}})
 Object.defineProperty(ectx,'running',{get(){return proc.running},set(v){proc.running=v}})
 vm.runInContext('(function(){'+exit+'})()',ectx)
 assert.deepEqual(commands,['10','20']);assert.equal(ctx.seenPending,'')
})
test('a helper missing for this CPU is reported once, translated, and never restarted',()=>{
 const source=fs.readFileSync(path.join(__dirname,'../Service.qml'),'utf8')
 const FoamyNative=require('../kit/node-loader.cjs').load('FoamyNative'),no=require('../i18n/no.json')
 assert.ok(no[FoamyNative.UNAVAILABLE_TEXT],'Norwegian text')
 const take=name=>{const start=source.indexOf(`  function ${name}(`);assert.ok(start>=0,name);return source.slice(start,source.indexOf('\n  }',start)+4)}
 const ctx=vm.createContext({FoamyNative,console:{warn(){ctx.warnings++}},warnings:0,helperUnavailable:false,loadError:'',listProc:{running:false},loadPending:false,listRevision:0,archiveRevision:0,listLoadCount:0,listLimit:500,searchQuery:'',storeCommand:a=>a,String})
 ctx.root=ctx
 for(const name of ['storeUnavailable','load']) vm.runInContext(take(name),ctx)
 assert.equal(ctx.storeUnavailable(1),false);assert.equal(ctx.helperUnavailable,false)
 assert.equal(ctx.storeUnavailable(127),true);assert.equal(ctx.storeUnavailable(126),true)
 assert.equal(ctx.helperUnavailable,true);assert.equal(ctx.loadError,FoamyNative.UNAVAILABLE_TEXT);assert.equal(ctx.warnings,1)
 ctx.load();assert.equal(ctx.listLoadCount,0,'no list read without a helper')
 // The watcher stops for good: the flapping-watcher test below runs its exit
 // and its restart timer with a missing helper.
})

const {processFixture,handler}=require('./qml-process.cjs')
function watchService(clock) {
 const source=fs.readFileSync(path.join(__dirname,'../Service.qml'),'utf8')
 const take=name=>{const start=source.indexOf(`  function ${name}(`);assert.ok(start>=0,name);return source.slice(start,source.indexOf('\n  }',start)+4)}
 const ctx=vm.createContext({FoamyNative:require('../kit/node-loader.cjs').load('FoamyNative'),console:{warn(){ctx.warnings++}},warnings:0,
  helperUnavailable:false,loadError:'',sourceRestartPending:false,archiveRevision:0,removedKeys:{},entries:[],JSON,String,
  reloadArchive:{restart(){}},restarts:[],restartWatch:{interval:30000,restart(){ctx.restarts.push(ctx.restartWatch.interval)}}})
 ctx.root=ctx
 for(const name of ['watchBackoffMs','watchBackoffMaxMs','watchStableMs']) ctx[name]=Number(source.match(new RegExp('property int '+name+': ([0-9]+)'))[1])
 ctx.watchStartedAt=0
 for(const name of ['storeUnavailable','scheduleWatchRestart','absorb']) vm.runInContext(take(name),ctx)
 ctx.watchProc=processFixture(source,'watchProc',ctx,{Date:{now:()=>clock.now}})
 // What the restartWatch Timer runs when it fires.
 ctx.sourceKind='stock'
 const timer=handler(source,'restartWatch','onTriggered');assert.ok(timer.startsWith('{'))
 ctx.trigger=()=>vm.runInContext('(function() '+timer+')()',ctx)
 return ctx
}
test('a watcher that keeps failing to start backs off to 60 s instead of a 1 Hz loop',()=>{
 const clock={now:0},ctx=watchService(clock)
 // Ten minutes of a watcher that can't start (no exited(), only running -> false).
 let attempts=0
 ctx.trigger()
 while(clock.now<600000) {
  attempts++;ctx.watchProc.failStart()
  assert.equal(ctx.watchProc.launched,false)
  clock.now+=ctx.restarts[ctx.restarts.length-1];ctx.trigger()
 }
 assert.deepEqual(ctx.restarts.slice(0,8),[1000,2000,4000,8000,16000,32000,60000,60000])
 assert.ok(attempts<=16,`${attempts} attempts in 10 minutes`)
 assert.equal(ctx.warnings,attempts,'one warning per failure')
})
test('a flapping watcher backs off; a run that reports in or lasts 30 s restarts after 1 s again',()=>{
 const clock={now:1000},ctx=watchService(clock)
 const run=(lasted,code=1,reported=false,sourceChange=false)=>{
  ctx.trigger();ctx.watchStartedAt=clock.now
  if(reported) ctx.absorb('{"event":"storeChanged"}')
  if(sourceChange) ctx.sourceRestartPending=true
  clock.now+=lasted;ctx.watchProc.exit(code,0)
 }
 // Dies at once (inotify limit, a store it can't create: an error line, exit 1).
 ctx.absorb('{"ok":false,"error":"notification watcher failed to start"}')
 for(let i=0;i<4;i++) run(50)
 assert.deepEqual(ctx.restarts,[1000,2000,4000,8000])
 // A source change keeps its 100 ms restart and leaves the backoff alone.
 run(50,143,false,true);assert.equal(ctx.restarts.pop(),100)
 run(50);assert.equal(ctx.restarts.pop(),16000)
 // Up and synced: the next failure restarts after 1 s.
 run(500,1,true);assert.equal(ctx.restarts.pop(),1000)
 run(50);assert.equal(ctx.restarts.pop(),2000)
 // A long run resets it too.
 run(30000);assert.equal(ctx.restarts.pop(),1000)
 // No helper for this CPU: no restart, and running -> false after exited() adds none.
 const before=ctx.restarts.length;run(50,127);assert.equal(ctx.restarts.length,before);assert.equal(ctx.helperUnavailable,true)
 // Even when its timer fires, the watcher stays stopped.
 ctx.trigger();assert.equal(ctx.watchProc.running,false)
})
test('store commands run without a whole-command deadline; the helper bounds only its lock wait, above one step of another store process',()=>{
 const source=fs.readFileSync(path.join(__dirname,'../Service.qml'),'utf8')
 // A list may migrate a whole archive first: nothing may kill it at a deadline.
 assert.ok(!/storeCall|storeDeadline|"timeout"/.test(source),'a store command under a whole-command deadline')
 for(const call of ['listProc.command = root.storeCommand(["list"','markProc.command = root.storeCommand(["seen"','removeProc.command = storeCommand(["remove"]','command: root.storeCommand(["clear", cut])','command = root.storeCommand(["seen", root.seenPending])','command: root.storeCommand(["watch"])'])
  assert.ok(source.includes(call),call)
 // One locked step takes in one notification: at most three images (icon, image, preview), each bounded by these deadlines.
 const images=fs.readFileSync(path.join(__dirname,'../native/src/images.rs'),'utf8')
 const step=['READ_DEADLINE','MIME_DEADLINE','CONVERT_DEADLINE'].map(n=>Number(images.match(new RegExp(n+': Duration = Duration::from_secs\\(([0-9]+)\\)'))[1])).reduce((a,b)=>a+b)
 const store=fs.readFileSync(path.join(__dirname,'../native/src/store.rs'),'utf8')
 const wait=Number(store.match(/pub const REQUEST_LOCK_WAIT: Duration = Duration::from_secs\(([0-9]+)\)/)[1])
 assert.ok(wait>3*step,`the request lock wait (${wait} s) must exceed ${3*step} s`)
})
test('list, remove and clear answer "notification store is busy" while another holds the store lock, and work once it is free',async t=>{
 const f=fixture(t);f.run('sync')
 const lock=path.join(f.store,'lock'),env={...f.env,NC_LOCK_WAIT_MS:'200'}
 const exec=(...args)=>helper.spawnSync(args,{env,encoding:'utf8',timeout:5000})
 // flock(1) holds the store's own lock (closed before its child runs), in a group of its own.
 const holder=spawn('flock',['--exclusive','--close',lock,'sleep','30'],{stdio:'ignore',detached:true})
 const gone=new Promise(resolve=>holder.on('exit',resolve))
 t.after(()=>{try{process.kill(-holder.pid,'SIGKILL')}catch{}})
 for(let i=0;spawnSync('flock',['--nonblock',lock,'true']).status===0;i++){assert.ok(i<200,'the holder never took the lock');await new Promise(r=>setTimeout(r,25))}
 for(const args of [['list'],['remove','1-1'],['clear',String(Date.now())]]){
  const started=Date.now(),r=exec(...args)
  assert.equal(r.status,1,`${args[0]}: ${r.stderr}`)
  assert.deepEqual(JSON.parse(r.stdout),{ok:false,error:'notification store is busy'},args[0])
  assert.ok(Date.now()-started>=200,`${args[0]} gave up before its wait`)
 }
 // Nothing was written without the lock; seen takes none and still works.
 assert.ok(!fs.existsSync(path.join(f.store,'cleared_at')),'clear wrote its cutoff without the lock')
 assert.equal(JSON.parse(exec('seen','5').stdout).seen,5)
 process.kill(-holder.pid,'SIGKILL');await gone
 assert.deepEqual(JSON.parse(exec('list').stdout),[])
 assert.equal(JSON.parse(exec('remove','1-1').stdout).ok,true)
 assert.equal(JSON.parse(exec('clear').stdout).cleared,true)
})
