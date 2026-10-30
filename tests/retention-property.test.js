// Property test for the archive invariants written at the top of
// bin/notification-center: random arrivals (with equal-millisecond ties, some
// days old), in-place updates, dismissals (also before first ingestion), count
// and age retention limits that go down and up again, and syncs. Sources keep
// their files after a dismissal, as stock 4.0 does. Invariants are checked
// after every sync.
const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawnSync } = require('node:child_process')
const script = path.join(__dirname, '../bin/notification-center')

function rng(seed) { return () => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed / 0x7fffffff } }
const rankLe = (a, b) => a.ts < b.ts || (a.ts === b.ts && a.key <= b.key)

for (const seed of [7, 42, 1337, 2024, 99]) {
  test(`archive invariants hold under random histories (seed ${seed})`, t => {
    const random = rng(seed), pick = list => list[Math.floor(random() * list.length)]
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'nc-property-'))
    t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
    const source = path.join(dir, 'source'), store = path.join(dir, 'store')
    fs.mkdirSync(path.join(source, 'history'), { recursive: true })
    const DAY = 86400000, base = Date.now() - 600000
    const run = (env, ...args) => {
      const r = spawnSync(script, args, { env: { ...process.env, NC_SRC_DIR: source, NC_SRC_HISTORY: path.join(source, 'history'), NC_STORE: store, NC_PREVIEWS: '0', ...env }, encoding: 'utf8', timeout: 10000 })
      assert.equal(r.status, 0, r.stderr + r.stdout)
      return JSON.parse(r.stdout)
    }
    const sources = new Map()          // key -> {ts, summary, file}
    const removed = new Set(), pruned = new Set()
    let id = 0, archived = new Map()
    const write = key => { const s = sources.get(key); fs.writeFileSync(s.file, JSON.stringify({ timestamp: s.ts, originalId: Number(key.split('-')[1]), app: 'P', summary: s.summary })) }
    for (let step = 0; step < 70; step++) {
      const op = random()
      if (op < 0.35 || sources.size < 3) {
        // Arrivals cluster on a few milliseconds so ties are common.
        // Some arrivals are two days old: an age limit of one day prunes them, 30 days admits them.
        const ts = base - (random() < 0.35 ? 2 * DAY + Math.floor(random() * 4) * 3600000 : 0) + Math.floor(random() * 6), key = `${ts}-${++id}`
        sources.set(key, { ts, summary: 'v0', file: path.join(source, random() < 0.5 ? 'history' : '', `${key}.json`) })
        write(key)
      } else if (op < 0.5) {
        const key = pick([...sources.keys()])
        sources.get(key).summary = 'v' + step
        write(key)
      } else if (op < 0.62) {
        // The watcher's hourly retention pass, with whatever age limit is set right now.
        run({ NC_MAX_ITEMS: '50', NC_KEEP_DAYS: random() < 0.5 ? '1' : '30' }, 'prune')
        const kept = new Map(run({}, 'list', '1000').map(row => [row.key, row]))
        for (const key of archived.keys()) if (!kept.has(key) && !removed.has(key)) pruned.add(key)
        archived = kept
      } else if (op < 0.76) {
        // Dismiss an archived row, or a source row before its first ingestion.
        // Often the newest of the old (two-day) rows: the case an age-only tombstone rule gets wrong.
        const old = [...archived.keys()].filter(k => sources.get(k).ts < Date.now() - DAY).sort((a, b) => sources.get(a).ts - sources.get(b).ts)
        const key = old.length && random() < 0.5 ? old[old.length - 1]
          : random() < 0.7 && archived.size ? pick([...archived.keys()]) : pick([...sources.keys()])
        run({}, 'remove', key)
        removed.add(key)
      } else {
        // Mostly a roomy count limit, so the age limit and tombstones (not count pruning) decide.
        const max = random() < 0.25 ? 2 + Math.floor(random() * 4) : 50, days = random() < 0.4 ? 1 : 30
        const cutoff = Date.now() - days * DAY
        const before = new Set(archived.keys())
        run({ NC_MAX_ITEMS: String(max), NC_KEEP_DAYS: String(days) }, 'sync')
        archived = new Map(run({ NC_KEEP_DAYS: String(days) }, 'list', '1000').map(row => [row.key, row]))
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
          // Too old for this sync's age limit and never archived: not pruned, may enter later.
          if (!before.has(key) && sources.get(key).ts < cutoff) continue
          const wm = watermark()
          if (before.has(key) || archived.size >= max || (wm && rankLe(rank(key), wm))) pruned.add(key)
        }
        for (const p of pruned) for (const a of archived.keys()) assert.ok(!rankLe(rank(a), rank(p)), `step ${step}: ${a} ranks below pruned ${p}`)
        // I4: with room to spare, every eligible source row is archived.
        if (archived.size < max) for (const key of sources.keys())
          if (!removed.has(key) && !pruned.has(key) && sources.get(key).ts >= cutoff) assert.ok(archived.has(key), `step ${step}: ${key} never entered`)
      }
    }
  })
}
