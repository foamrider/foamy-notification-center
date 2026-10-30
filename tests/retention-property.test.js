// Property test for the archive invariants written at the top of
// bin/notification-center: random arrivals (with equal-millisecond ties),
// in-place updates, dismissals (also before first ingestion), retention limits
// and syncs, with the invariants checked after every sync.
const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawnSync } = require('node:child_process')
const script = path.join(__dirname, '../bin/notification-center')

function rng(seed) { return () => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed / 0x7fffffff } }
const rankLe = (a, b) => a.ts < b.ts || (a.ts === b.ts && a.key <= b.key)

for (const seed of [7, 42, 1337]) {
  test(`archive invariants hold under random histories (seed ${seed})`, t => {
    const random = rng(seed), pick = list => list[Math.floor(random() * list.length)]
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'nc-property-'))
    t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
    const source = path.join(dir, 'source'), store = path.join(dir, 'store')
    fs.mkdirSync(path.join(source, 'history'), { recursive: true })
    const base = Date.now() - 600000
    const run = (env, ...args) => {
      const r = spawnSync(script, args, { env: { ...process.env, NC_SRC_DIR: source, NC_SRC_HISTORY: path.join(source, 'history'), NC_STORE: store, NC_PREVIEWS: '0', ...env }, encoding: 'utf8', timeout: 10000 })
      assert.equal(r.status, 0, r.stderr + r.stdout)
      return JSON.parse(r.stdout)
    }
    const sources = new Map()          // key -> {ts, summary, file}
    const removed = new Set(), pruned = new Set()
    let id = 0, archived = new Map()
    const write = key => { const s = sources.get(key); fs.writeFileSync(s.file, JSON.stringify({ timestamp: s.ts, originalId: Number(key.split('-')[1]), app: 'P', summary: s.summary })) }
    for (let step = 0; step < 45; step++) {
      const op = random()
      if (op < 0.4 || sources.size < 3) {
        // Arrivals cluster on a few milliseconds so ties are common.
        const ts = base + Math.floor(random() * 6), key = `${ts}-${++id}`
        sources.set(key, { ts, summary: 'v0', file: path.join(source, random() < 0.5 ? 'history' : '', `${key}.json`) })
        write(key)
      } else if (op < 0.6) {
        const key = pick([...sources.keys()])
        sources.get(key).summary = 'v' + step
        write(key)
      } else if (op < 0.72) {
        // Dismiss an archived row, or a source row before its first ingestion.
        const key = random() < 0.7 && archived.size ? pick([...archived.keys()]) : pick([...sources.keys()])
        run({}, 'remove', key)
        removed.add(key)
      } else {
        const max = 2 + Math.floor(random() * 4)
        const before = new Set(archived.keys())
        run({ NC_MAX_ITEMS: String(max) }, 'sync')
        archived = new Map(run({}, 'list', '1000').map(row => [row.key, row]))
        const rank = key => ({ key, ts: sources.get(key).ts })
        // I1: removed stays removed.
        for (const key of [...removed, ...pruned]) assert.ok(!archived.has(key), `step ${step}: ${key} came back`)
        // I2: rows still archived carry their source's latest content.
        for (const [key, row] of archived) assert.equal(row.summary, sources.get(key).summary, `step ${step}: ${key} missed an update`)
        // I3: within the limit; everything kept outranks everything pruned.
        assert.ok(archived.size <= max, `step ${step}: ${archived.size} > ${max}`)
        // Rows that left without a dismissal were pruned by retention; a new row
        // ranked at or below the watermark (the highest pruned rank) counts as
        // already pruned (I4 admits only rows ranked above it).
        const watermark = () => [...pruned].map(rank).reduce((top, r) => !top || rankLe(top, r) ? r : top, null)
        for (const key of sources.keys()) {
          if (removed.has(key) || pruned.has(key) || archived.has(key)) continue
          const wm = watermark()
          if (before.has(key) || archived.size >= max || (wm && rankLe(rank(key), wm))) pruned.add(key)
        }
        for (const p of pruned) for (const a of archived.keys()) assert.ok(!rankLe(rank(a), rank(p)), `step ${step}: ${a} ranks below pruned ${p}`)
        // I4: with room to spare, every eligible source row is archived.
        if (archived.size < max) for (const key of sources.keys())
          if (!removed.has(key) && !pruned.has(key)) assert.ok(archived.has(key), `step ${step}: ${key} never entered`)
      }
    }
  })
}
