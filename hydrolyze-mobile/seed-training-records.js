#!/usr/bin/env node
/**
 * Seed realistic training records for all 6 swimmers.
 * Run: node seed-training-records.js
 */

const ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZsaWRqdGxkZnZycm50end0bnNxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjE1MjcyODMsImV4cCI6MjA3NzEwMzI4M30.kRhOyhPLVmVww6W03wMrlZnX0yeD6F73_cUpaOaRldE'
const BASE = 'https://flidjtldfvrrntzwtnsq.supabase.co/rest/v1'

const headers = () => ({
  'apikey': ANON_KEY,
  'Authorization': `Bearer ${ANON_KEY}`,
  'Content-Type': 'application/json',
  'Prefer': 'return=minimal',
})

// ── Swimmer IDs ─────────────────────────────────────────────────────────────
const S = {
  emma:   '00000000-0000-0000-0000-000000000001',
  jake:   '00000000-0000-0000-0000-000000000002',
  sofia:  '00000000-0000-0000-0000-000000000003',
  marcus: '00000000-0000-0000-0000-000000000004',
  lily:   '00000000-0000-0000-0000-000000000005',
  ryan:   '00000000-0000-0000-0000-000000000006',
}

// ── Historical session IDs (not used in recent practice) ────────────────────
const SESSIONS = [
  { id: 'd9ad1ac2-6fff-488f-abe1-290c15022e4d', date: '2024-04-14' },
  { id: '33359cc9-540b-4cc6-8555-fddd7295c93c', date: '2026-04-14' },
  { id: '71593cca-36ff-4c24-8f03-ef3dce662313', date: '2026-04-15' },
  { id: 'b891689d-186f-4a0e-a618-232cac92b744', date: '2026-04-24' },
  { id: '5143b38a-cb70-4905-b5ce-5cc393b8968d', date: '2026-04-24' },
]

// ── Real 50m Free workout_set IDs ───────────────────────────────────────────
const WORKOUT_SETS_50 = [
  'feb3c22c-6e32-4d70-b5e4-0881e1db4528',
  '52de429f-f691-483c-b869-1e7dd3c22732',
  '0415f792-a9b6-4d7f-acb1-65121e189228',
  '349e5fad-ec2b-4a30-bfff-b6238ce7ce1f',
  '8782329b-abb7-4798-bfd8-d0f23c59a696',
  'bb41f688-2894-409b-a583-81e3e2c3c92b',
  'a8a6603a-6ac5-4a8c-8921-98bac3d50e72',
]

// ── Training stats (from swimmer_stats DB) ──────────────────────────────────
// mean = typical training average (slightly slower than race-pace PB)
// sigma = day-to-day standard deviation
const STATS = {
  [S.emma]:   { Free: { mean: 31600, sigma: 450 }, Back: { mean: 35800, sigma: 500 } },
  [S.jake]:   { Free: { mean: 27800, sigma: 300 }, Fly: { mean: 30300, sigma: 400 } },
  [S.sofia]:  { Free: { mean: 30200, sigma: 280 }, Back: { mean: 34500, sigma: 320 }, Fly: { mean: 35300, sigma: 450 } },
  [S.marcus]: { Free: { mean: 26800, sigma: 280 }, IM: { mean: 138600, sigma: 1400 }, Breast: { mean: 71500, sigma: 900 } },
  [S.lily]:   { Free: { mean: 32500, sigma: 700 }, Back: { mean: 36200, sigma: 580 }, Fly: { mean: 35000, sigma: 650 } },
  [S.ryan]:   { Free: { mean: 25400, sigma: 150 }, Back: { mean: 33000, sigma: 350 }, Fly: { mean: 63200, sigma: 700 } },
}

// ── Box-Muller: two independent standard normals per call ──────────────────
function boxMuller() {
  const u1 = Math.random(), u2 = Math.random()
  // Reject u1=0 (log would blow up), try again
  if (u1 < 1e-10) return [0, 0]
  const z0 = Math.sqrt(-2 * Math.log(u1)) * Math.cos(2 * Math.PI * u2)
  const z1 = Math.sqrt(-2 * Math.log(u1)) * Math.sin(2 * Math.PI * u2)
  return [z0, z1]
}

/** Gaussian sample with mean and sigma */
function randn(mean, sigma) {
  const [z] = boxMuller()
  return mean + sigma * z
}

// ── Set definitions ─────────────────────────────────────────────────────────
// 3 sets per session: 50m Free (no gear), 50m Free (fins), 100m Free (hard)
const SET_DEFS = [
  { stroke: 'Free', distance: 50, reps: 4, gear: null,     intensity: 'moderate', wsOffset: 0 },
  { stroke: 'Free', distance: 50, reps: 2, gear: 'fins', intensity: 'easy',    wsOffset: 1 },
  { stroke: 'Free', distance: 100, reps: 3, gear: null,   intensity: 'hard',   wsOffset: 2 },
]

// Gear speed multipliers (fins = faster, paddles = slower)
const GEAR_MULT = { fins: 0.88, paddles: 1.12, pull_buoy: 1.08, kickboard: 1.05 }

// Intensity: easy = 3% slower, hard = 5% faster (race pace)
const INT_MULT = { easy: 1.03, moderate: 1.0, hard: 0.95 }

// ── Generate all records ────────────────────────────────────────────────────
function buildRecords() {
  const records = []
  let globalLap = 1

  const swimmerIds = Object.values(S)

  for (let si = 0; si < SESSIONS.length; si++) {
    const session = SESSIONS[si]
    const sessionDate = new Date(session.date + 'T10:00:00Z')

    for (const swimmerId of swimmerIds) {
      const swimmerStats = STATS[swimmerId] ?? {}

      for (const setDef of SET_DEFS) {
        // Skip strokes the swimmer doesn't have stats for
        if (!swimmerStats[setDef.stroke] && setDef.stroke !== 'Free') continue

        const strokeStats = swimmerStats[setDef.stroke]
        const baseMean = strokeStats?.mean ?? 30000
        const baseSigma = strokeStats?.sigma ?? 500

        const gearMult = GEAR_MULT[setDef.gear] ?? 1.0
        const intMult = INT_MULT[setDef.intensity] ?? 1.0

        // Pick a workout_set_id cycling through the available 50m sets
        const wsIdx = (si + setDef.wsOffset) % WORKOUT_SETS_50.length
        const workoutSetId = WORKOUT_SETS_50[wsIdx]

        for (let rep = 1; rep <= setDef.reps; rep++) {
          // sessionVariance = ±0.25σ (tight clustering)
          const sessionVariance = randn(0, baseSigma * 0.25)
          // Fatigue: 100ms per subsequent rep (harder sets have more fatigue)
          const fatigue = (rep - 1) * 100 * (setDef.intensity === 'hard' ? 1.5 : 1.0)

          const rawTime = baseMean * gearMult * intMult + sessionVariance - fatigue
          const time = Math.max(15000, Math.round(rawTime))

          records.push({
            session_id: session.id,
            swimmer_id: swimmerId,
            workout_set_id: workoutSetId,
            swim_set_id: null,
            lap_time_ms: time,
            lap_number: globalLap++,
            rep_number: rep,
            confidence: 80,
            gear: setDef.gear,
            wave_number: 1,
            intensity: setDef.intensity,
            rep_start_at: sessionDate.toISOString(),
            created_at: sessionDate.toISOString(),
          })
        }
      }
    }
  }

  return records
}

// ── HTTP helpers ────────────────────────────────────────────────────────────
async function insert(table, rows) {
  if (rows.length === 0) return true
  const res = await fetch(`${BASE}/${table}`, {
    method: 'POST',
    headers: headers(),
    body: JSON.stringify(rows),
  })
  if (!res.ok) {
    const err = await res.json().catch(() => [res.statusText])
    return err
  }
  return true
}

// ── Main ────────────────────────────────────────────────────────────────────
async function main() {
  console.log('🌊  Generating training records...\n')

  const records = buildRecords()
  console.log(`  📝  Built ${records.length} records`)

  // Verify generated times are realistic before inserting
  const times = records.filter(r => r.gear === null && r.intensity === 'moderate').map(r => r.lap_time_ms)
  const avg = (times.reduce((a, b) => a + b, 0) / times.length / 1000).toFixed(2)
  const min = (Math.min(...times) / 1000).toFixed(2)
  const max = (Math.max(...times) / 1000).toFixed(2)
  console.log(`  🔍  50m Free times: avg=${avg}s  range=[${min}s, ${max}s]`)

  if (parseFloat(max) > 50) {
    console.warn(`  ⚠️  WARNING: some times look too high. Check RNG before inserting.`)
  } else {
    console.log(`  ✅  Times look realistic — inserting...\n`)
  }

  // Insert in batches of 50
  const BATCH = 50
  let total = 0
  const errors = []

  for (let i = 0; i < records.length; i += BATCH) {
    const batch = records.slice(i, i + BATCH)
    const res = await insert('recorded_times', batch)
    if (res !== true) {
      errors.push({ batch: i / BATCH, error: res })
    } else {
      total += batch.length
      process.stdout.write(`\r  Inserted ${total}/${records.length} records...`)
    }
  }

  console.log(`\n\n✅  Inserted ${total} records\n`)

  if (errors.length) {
    for (const e of errors) console.warn('  ⚠️  Batch', e.batch, 'failed:', e.error)
  }

  // Summary
  console.log('─── Generated times (50m Free, no gear, rep 1) ──────────────')
  const bySwimmer = {}
  for (const r of records) {
    if (r.gear === null && r.intensity === 'moderate') {
      (bySwimmer[r.swimmer_id] ??= []).push(r.lap_time_ms)
    }
  }
  const NAME = { [S.emma]: 'Emma', [S.jake]: 'Jake', [S.sofia]: 'Sofia',
                 [S.marcus]: 'Marcus', [S.lily]: 'Lily', [S.ryan]: 'Ryan' }
  for (const [id, times] of Object.entries(bySwimmer)) {
    const avg = (times.reduce((a, b) => a + b, 0) / times.length / 1000).toFixed(2)
    const std = Math.sqrt(times.reduce((s, t) => s + (t - avg * 1000) ** 2, 0) / times.length) / 1000
    console.log(`  ${(NAME[id] ?? '?').padEnd(7)}  avg=${avg}s  σ=${std.toFixed(3)}s  n=${times.length}`)
  }

  console.log('\n✅  Done! Each swimmer now has realistic historical training data.')
}

main().catch(err => {
  console.error('\n❌  Error:', err.message || err)
  process.exit(1)
})