// The store helper's frozen contract: the exact bytes each subcommand prints,
// and the formats of the files it keeps (archive rows, tombstones, the clear
// line, the retention watermark, the seen stamp). Existing archives and
// tombstones written by earlier versions must stay valid, so hashes and source
// tags are checked against independent computations.
const test = require('node:test')
const assert = require('node:assert/strict')
const crypto = require('node:crypto')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const {spawnSync} = require('node:child_process')
const helper = require('./helper.cjs')

const sha = text => crypto.createHash('sha256').update(text).digest('hex')
const cksum = text => spawnSync('cksum', [], {input: text, encoding: 'utf8'}).stdout.split(' ')[0]

function fixture(t, extra = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'nc-contract-'))
  t.after(() => fs.rmSync(dir, {recursive: true, force: true}))
  const source = path.join(dir, 'source'), store = path.join(dir, 'store')
  fs.mkdirSync(path.join(source, 'history'), {recursive: true})
  const env = {...process.env, HOME: path.join(dir, 'home'), NC_SRC_DIR: source, NC_SRC_HISTORY: path.join(source, 'history'),
    NC_STORE: store, NC_PREVIEWS: '0', ...extra}
  const exec = (args, more = {}) => helper.spawnSync(args, {env: {...env, ...more}, encoding: 'utf8', timeout: 10000})
  const out = (...args) => { const r = exec(args); assert.equal(r.status, 0, r.stderr + r.stdout); return r.stdout }
  const file = name => path.join(store, name)
  return {dir, source, store, env, exec, out, file, read: name => fs.readFileSync(file(name), 'utf8')}
}

test('every subcommand prints exactly one JSON line', t => {
  const f = fixture(t)
  assert.equal(f.out('sync'), '{"ok":true,"synced":true}\n')
  assert.equal(f.out('list'), '[]\n')
  assert.equal(f.out('seen'), '{"ok":true,"seen":0}\n')
  assert.equal(f.out('seen', '1730000000123'), '{"ok":true,"seen":1730000000123}\n')
  assert.equal(f.read('seen'), '1730000000123\n')
  assert.equal(f.out('seen'), '{"ok":true,"seen":1730000000123}\n')
  assert.equal(f.out('unread'), '{"ok":true,"unread":0}\n')
  assert.equal(f.out('seed', '3'), '{"ok":true,"seeded":3}\n')
  assert.equal(f.out('unread'), '{"ok":true,"unread":3}\n')
  const keys = f.read('archive.jsonl').trim().split('\n').map(line => JSON.parse(line).key)
  assert.equal(f.out('remove', keys[0], keys[1]), `{"ok":true,"removed":"${keys[0]}","count":2}\n`)
  assert.equal(f.out('backfill'), '{"ok":true,"filled":0}\n')
  assert.equal(f.out('prune'), '{"ok":true,"pruned":true}\n')
  assert.equal(f.out('clear'), '{"ok":true,"cleared":true}\n')
  assert.equal(f.out('clear', '1000'), '{"ok":true,"cleared":true}\n')
  assert.equal(f.out('list', '5'), '[]\n')
})

test('failures print {"ok":false,"error":…} and exit 1; unknown commands exit 64 without output', t => {
  const f = fixture(t)
  for (const [args, error] of [
    [['list', 'x'], 'list limit must be a nonnegative integer'],
    [['list', '-1'], 'list limit must be a nonnegative integer'],
    [['list', '10', 'q'.repeat(257)], 'search is too long'],
    [['remove'], 'remove needs a key'],
    [['remove', '1-1', '../x'], 'invalid notification key'],
    [['remove', 'stock-' + 'a'.repeat(121)], 'invalid notification key'],
    [['clear', 'x'], 'clear cutoff must be a millisecond timestamp'],
    [['clear', '12345678901234567'], 'clear cutoff must be a millisecond timestamp'],
  ]) {
    const r = f.exec(args)
    assert.equal(r.status, 1, args.join(' '))
    assert.equal(r.stdout, JSON.stringify({ok: false, error}) + '\n', args.join(' '))
  }
  assert.equal(f.out('list', '10', 'q'.repeat(256)), '[]\n')
  assert.equal(f.out('remove', 'stock-' + 'a'.repeat(120)), `{"ok":true,"removed":"stock-${'a'.repeat(120)}","count":1}\n`)
  for (const args of [[], ['nonsense']]) {
    const r = f.exec(args)
    assert.equal(r.status, 64)
    assert.equal(r.stdout, '')
    assert.match(r.stderr, /the store behind the Omarchy notification center/)
  }
  // The store cannot be created: still JSON.
  fs.writeFileSync(path.join(f.dir, 'blocker'), '')
  const blocked = f.exec(['list'], {NC_STORE: path.join(f.dir, 'blocker', 'store')})
  assert.equal(blocked.status, 1)
  assert.equal(blocked.stdout, JSON.stringify({ok: false, error: `cannot create ${path.join(f.dir, 'blocker', 'store')}`}) + '\n')
})

test('an ingested row has a fixed key order, keeps number literals and hashes its source text', t => {
  const f = fixture(t)
  const stamp = Date.now() - 1000, key = `${stamp}-7`
  const text = `{"timestamp":${stamp},"app":"Café\\u007f","appIcon":"slack","summary":"S","body":"B","desktopEntry":"d","glyph":"g","urgency":2.50,"originalId":7}\n\n`
  fs.writeFileSync(path.join(f.source, `${key}.json`), text)
  f.out('sync')
  const lines = f.read('archive.jsonl').split('\n')
  assert.equal(lines.length, 2)
  const listed = '{"key":"' + key + '","imageFormat":1,"sourceHash":"' + sha(text.replace(/\n+$/, '')) + '","stockHash":"",' +
    '"assetsHash":"' + sha('slack\n\n\n0\n') + '","assetSources":"' + sha('slack\n\n\n0\n') + '",' +
    '"desktopEntry":"d","app":"Café\\u007f","appIcon":"slack","summary":"S","body":"B","image":"","preview":"","file":"",' +
    '"fileAction":"","glyph":"g","urgency":2.50,"timestamp":' + stamp + '}'
  assert.equal(lines[0], listed)
  assert.equal(f.out('list'), '[' + listed + ']\n')
  // Unchanged source, unchanged archive (no rewrite, no re-ingest).
  const before = fs.statSync(f.file('archive.jsonl'), {bigint: true}).mtimeNs
  f.out('sync')
  assert.equal(fs.statSync(f.file('archive.jsonl'), {bigint: true}).mtimeNs, before)
})

test('the assets hash covers each sender file as stat -L prints it', t => {
  const f = fixture(t)
  const stamp = Date.now() - 1000, key = `${stamp}-8`
  const note = path.join(f.dir, 'not-an-image.txt')
  fs.writeFileSync(note, 'plain text')
  fs.writeFileSync(path.join(f.source, `${key}.json`), JSON.stringify({timestamp: stamp, app: 'A', summary: 'S', image: note}))
  const r = f.exec(['sync'])
  assert.equal(r.status, 0)
  assert.match(r.stderr, /image_rejected/)
  const row = JSON.parse(f.read('archive.jsonl'))
  const stat = spawnSync('stat', ['-Lc', '%d:%i:%s:%y:%z', '--', note], {encoding: 'utf8'}).stdout
  assert.equal(row.assetSources, sha(`\n${note}\n\n0\n`))
  assert.equal(row.assetsHash, sha(`\n${note}\n\n0\n` + stat))
  assert.equal(row.image, '')
})

test('tombstones, the clear line and the retention watermark keep their formats', t => {
  const f = fixture(t, {NC_MAX_ITEMS: '1'})
  const now = Date.now(), a = `${now - 3000}-1`, b = `${now - 2000}-2`, c = `${now - 1000}-3`
  for (const [key, ts] of [[a, now - 3000], [b, now - 2000], [c, now - 1000]])
    fs.writeFileSync(path.join(f.source, 'history', `${key}.json`), JSON.stringify({timestamp: ts, app: 'T', summary: key}))
  f.out('sync')
  assert.deepEqual(JSON.parse(f.out('list')).map(row => row.key), [c])
  assert.equal(f.read('pruned_through'), `${now - 2000} ${b}\n`)
  const before = Date.now()
  f.out('remove', c, '1-1', 'stock-x')
  const tag = cksum(f.source)
  const stones = f.read('dismissed').trim().split('\n').map(line => line.split(' '))
  assert.deepEqual(stones.map(s => [s[0], s[1], s[3]]), [[c, String(now - 1000), tag], ['1-1', '1', tag], ['stock-x', '0', tag]])
  for (const s of stones) assert.ok(Number(s[2]) >= before && Number(s[2]) <= Date.now())
  f.out('clear', String(now - 500))
  assert.equal(f.read('cleared_at'), `${now - 500}\n`)
  for (const name of ['archive.jsonl', 'dismissed', 'seen', 'cleared_at', 'pruned_through', 'lock'])
    if (fs.existsSync(f.file(name))) assert.equal(fs.statSync(f.file(name)).mode & 0o777, 0o600, name)
  for (const dir of ['', 'images']) assert.equal(fs.statSync(f.file(dir)).mode & 0o777, 0o700, dir || 'store')
})

test('stock rows carry the 4.5 reader\'s fingerprint, so existing archives are not re-ingested', t => {
  const f = fixture(t)
  const icon = path.join(f.dir, 'icon.txt')
  fs.writeFileSync(icon, 'x')
  const now = Date.now() / 1000
  const row = {key: 'n-1', ts: now - 5, app: 'Vivaldi', summary: 'Hello é', body: 'Body', rawBody: '<b>Body</b>',
    appIcon: icon, image: '/nonexistent/picture.png', execArgv: JSON.stringify(['omasnap', '/nonexistent/shot.png']), urgency: 1, originalId: 4}
  fs.writeFileSync(path.join(f.source, 'history.json'), JSON.stringify([row]))
  f.out('sync')
  const archived = JSON.parse(f.read('archive.jsonl'))
  // The reader's digest: sorted, ASCII-escaped Python JSON plus each path's stat tuple.
  const expected = spawnSync('python3', ['-I', '-c', `
import hashlib, json, os, sys
row = json.loads(sys.argv[1])
digest = hashlib.sha256(json.dumps(row, ensure_ascii=True, sort_keys=True).encode())
for name in [row['appIcon'], row['image']] + json.loads(row['execArgv']):
    if not name.startswith('/'):
        continue
    try:
        info = os.stat(name)
        digest.update(str((info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)).encode())
    except OSError:
        digest.update(b'missing')
print(digest.hexdigest())`, JSON.stringify(row)], {encoding: 'utf8'}).stdout.trim()
  assert.equal(archived.stockHash, expected)
  assert.equal(archived.key, 'stock-n-1')
  assert.equal(archived.timestamp, Math.floor((now - 5) * 1000))
  assert.equal(archived.body, '<b>Body</b>')
  assert.equal(archived.file, '/nonexistent/shot.png')
  assert.equal(archived.fileAction, 'edit-screenshot')
  const text = f.read('archive.jsonl')
  f.out('sync')
  assert.equal(f.read('archive.jsonl'), text)
})

test('watch prints its events as fixed lines', async t => {
  const f = fixture(t, {NC_SOURCE: 'foamy', NC_MAX_ITEMS: '1', NC_STATE_FILE: ''})
  f.out('list')
  const now = Date.now()
  fs.writeFileSync(f.file('archive.jsonl'), [1, 2].map(i => JSON.stringify({key: `${now - 9000 + i}-${i}`, timestamp: now - 9000 + i, summary: 'x'})).join('\n') + '\n')
  const lines = [], watch = helper.spawn(['watch'], {env: f.env})
  let pending = ''
  watch.stdout.on('data', chunk => { pending += chunk; let n; while ((n = pending.indexOf('\n')) >= 0) { lines.push(pending.slice(0, n)); pending = pending.slice(n + 1) } })
  t.after(() => watch.kill())
  const until = async fn => { const end = Date.now() + 5000; while (!fn()) { assert.ok(Date.now() < end, lines.join('\n')); await new Promise(r => setTimeout(r, 25)) } }
  await until(() => lines.includes('{"event":"storeChanged"}'))
  assert.deepEqual(lines.slice(0, 2), [`{"event":"pruned","keys":["${now - 8999}-1"]}`, '{"event":"storeChanged"}'])
  lines.length = 0
  fs.writeFileSync(path.join(f.dir, 'notifications.json'), '{"dnd":true}')
  await until(() => lines.includes('{"event":"dndChanged"}'))
  fs.writeFileSync(f.file('seen'), '5')
  await until(() => lines.includes('{"event":"seenChanged"}'))
  fs.rmSync(f.store, {recursive: true, force: true})
  const code = await new Promise(resolve => watch.on('exit', resolve))
  await new Promise(r => setTimeout(r, 50))
  assert.equal(code, 1)
  assert.equal(lines.at(-1), '{"ok":false,"error":"notification source changed; reconnecting"}')
})
