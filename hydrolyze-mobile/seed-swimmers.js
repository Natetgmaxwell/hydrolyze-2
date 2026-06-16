#!/usr/bin/env node
/**
 * Patch existing swimmer_stats to add set_id=50 (since all current records
 * are 50m training averages), then re-upsert the seed data with proper set_ids.
 *
 * Run: node seed-swimmers.js
 */

const ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZsaWRqdGxkZnZycm50end0bnNxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjE1MjcyODMsImV4cCI6MjA3NzEwMzI4M30.kRhOyhPLVmVww6W03wMrlZnX0yeD6F73_cUpaOaRldE'
const BASE = 'https://flidjtldfvrrntzwtnsq.supabase.co/rest/v1'

const headers = () => ({
  'apikey': ANON_KEY,
  'Authorization': `Bearer ${ANON_KEY}`,
  'Content-Type': 'application/json',
})

const SWIMMERS = {
  emma:   '00000000-0000-0000-0000-000000000001',
  jake:   '00000000-0000-0000-0000-000000000002',
  sofia:  '00000000-0000-0000-0000-000000000003',
  marcus: '00000000-0000-0000-0000-000000000004',
  lily:   '00000000-0000-0000-0000-000000000005',
  ryan:   '00000000-0000-0000-0000-000000000006',
}

// All records in swimmer_stats right now are 50m averages
// (sample_count 4-15, mean_time_ms 25400-138600ms)
const PBS = [
  { swimmer_id: SWIMMERS.emma,   stroke: 'Free',  distance: 50,  pb_ms: 30800 },
  { swimmer_id: SWIMMERS.emma,   stroke: 'Free',  distance: 100, pb_ms: 66800 },
  { swimmer_id: SWIMMERS.emma,   stroke: 'Free',  distance: 200, pb_ms: 138500 },
  { swimmer_id: SWIMMERS.emma,   stroke: 'Back',  distance: 50,  pb_ms: 34800 },
  { swimmer_id: SWIMMERS.emma,   stroke: 'Back',  distance: 100, pb_ms: 73800 },
  { swimmer_id: SWIMMERS.jake,   stroke: 'Free',  distance: 50,  pb_ms: 27200 },
  { swimmer_id: SWIMMERS.jake,   stroke: 'Free',  distance: 100, pb_ms: 58200 },
  { swimmer_id: SWIMMERS.jake,   stroke: 'Free',  distance: 200, pb_ms: 123500 },
  { swimmer_id: SWIMMERS.jake,   stroke: 'Fly',   distance: 50,  pb_ms: 29600 },
  { swimmer_id: SWIMMERS.jake,   stroke: 'Fly',   distance: 100, pb_ms: 64500 },
  { swimmer_id: SWIMMERS.sofia,  stroke: 'Free',  distance: 50,  pb_ms: 29500 },
  { swimmer_id: SWIMMERS.sofia,  stroke: 'Free',  distance: 100, pb_ms: 63800 },
  { swimmer_id: SWIMMERS.sofia,  stroke: 'Free',  distance: 200, pb_ms: 134200 },
  { swimmer_id: SWIMMERS.sofia,  stroke: 'Back',  distance: 50,  pb_ms: 33800 },
  { swimmer_id: SWIMMERS.sofia,  stroke: 'Back',  distance: 100, pb_ms: 71800 },
  { swimmer_id: SWIMMERS.sofia,  stroke: 'Fly',   distance: 50,  pb_ms: 34500 },
  { swimmer_id: SWIMMERS.marcus, stroke: 'Free',  distance: 50,  pb_ms: 26200 },
  { swimmer_id: SWIMMERS.marcus, stroke: 'Free',  distance: 100, pb_ms: 56200 },
  { swimmer_id: SWIMMERS.marcus, stroke: 'Free',  distance: 200, pb_ms: 119800 },
  { swimmer_id: SWIMMERS.marcus, stroke: 'IM',    distance: 200, pb_ms: 135600 },
  { swimmer_id: SWIMMERS.marcus, stroke: 'Breast', distance: 100, pb_ms: 69800 },
  { swimmer_id: SWIMMERS.lily,   stroke: 'Free',  distance: 50,  pb_ms: 31800 },
  { swimmer_id: SWIMMERS.lily,   stroke: 'Free',  distance: 100, pb_ms: 69200 },
  { swimmer_id: SWIMMERS.lily,   stroke: 'Back',  distance: 50,  pb_ms: 35500 },
  { swimmer_id: SWIMMERS.lily,   stroke: 'Back',  distance: 100, pb_ms: 75800 },
  { swimmer_id: SWIMMERS.lily,   stroke: 'Fly',   distance: 50,  pb_ms: 34200 },
  { swimmer_id: SWIMMERS.ryan,   stroke: 'Free',  distance: 50,  pb_ms: 24800 },
  { swimmer_id: SWIMMERS.ryan,   stroke: 'Free',  distance: 100, pb_ms: 53800 },
  { swimmer_id: SWIMMERS.ryan,   stroke: 'Free',  distance: 200, pb_ms: 114300 },
  { swimmer_id: SWIMMERS.ryan,   stroke: 'Back',  distance: 50,  pb_ms: 32200 },
  { swimmer_id: SWIMMERS.ryan,   stroke: 'Back',  distance: 100, pb_ms: 67800 },
  { swimmer_id: SWIMMERS.ryan,   stroke: 'Fly',   distance: 100, pb_ms: 61800 },
]

// Training stats keyed to 50m distance (set_id=50)
const TRAINING_STATS = [
  { swimmer_id: SWIMMERS.emma,   stroke: 'Free',  set_id: 50, mean_time_ms: 31600, stddev_time_ms: 450, sample_count: 8 },
  { swimmer_id: SWIMMERS.emma,   stroke: 'Back',  set_id: 50, mean_time_ms: 35800, stddev_time_ms: 500, sample_count: 6 },
  { swimmer_id: SWIMMERS.jake,   stroke: 'Free',  set_id: 50, mean_time_ms: 27800, stddev_time_ms: 300, sample_count: 12 },
  { swimmer_id: SWIMMERS.jake,   stroke: 'Fly',   set_id: 50, mean_time_ms: 30300, stddev_time_ms: 400, sample_count: 9 },
  { swimmer_id: SWIMMERS.sofia,  stroke: 'Free',  set_id: 50, mean_time_ms: 30200, stddev_time_ms: 280, sample_count: 11 },
  { swimmer_id: SWIMMERS.sofia,  stroke: 'Back',  set_id: 50, mean_time_ms: 34500, stddev_time_ms: 320, sample_count: 10 },
  { swimmer_id: SWIMMERS.sofia,  stroke: 'Fly',   set_id: 50, mean_time_ms: 35300, stddev_time_ms: 450, sample_count: 5 },
  { swimmer_id: SWIMMERS.marcus, stroke: 'Free',  set_id: 50, mean_time_ms: 26800, stddev_time_ms: 280, sample_count: 13 },
  { swimmer_id: SWIMMERS.marcus, stroke: 'IM',    set_id: 50, mean_time_ms: 138600, stddev_time_ms: 1400, sample_count: 7 },
  { swimmer_id: SWIMMERS.marcus, stroke: 'Breast', set_id: 50, mean_time_ms: 71500, stddev_time_ms: 900, sample_count: 6 },
  { swimmer_id: SWIMMERS.lily,   stroke: 'Free',  set_id: 50, mean_time_ms: 32500, stddev_time_ms: 700, sample_count: 7 },
  { swimmer_id: SWIMMERS.lily,   stroke: 'Back',  set_id: 50, mean_time_ms: 36200, stddev_time_ms: 580, sample_count: 8 },
  { swimmer_id: SWIMMERS.lily,   stroke: 'Fly',   set_id: 50, mean_time_ms: 35000, stddev_time_ms: 650, sample_count: 4 },
  { swimmer_id: SWIMMERS.ryan,   stroke: 'Free',  set_id: 50, mean_time_ms: 25400, stddev_time_ms: 150, sample_count: 15 },
  { swimmer_id: SWIMMERS.ryan,   stroke: 'Back',  set_id: 50, mean_time_ms: 33000, stddev_time_ms: 350, sample_count: 9 },
  { swimmer_id: SWIMMERS.ryan,   stroke: 'Fly',   set_id: 50, mean_time_ms: 63200, stddev_time_ms: 700, sample_count: 6 },
]

async function get(table, params = '') {
  const res = await fetch(`${BASE}/${table}${params ? '?' + params : ''}`, { headers: headers() })
  return res.json().catch(() => [])
}

async function upsert(table, rows, prefer = 'resolution=merge-duplicates') {
  const res = await fetch(`${BASE}/${table}`, {
    method: 'POST',
    headers: { ...headers(), 'Prefer': prefer },
    body: JSON.stringify(rows),
  })
  return res.ok
}

async function patch(table, match, updates) {
  const qs = Object.entries(match).map(([k, v]) => `${k}=eq.${v}`).join('&')
  const res = await fetch(`${BASE}/${table}?${qs}`, {
    method: 'PATCH',
    headers: headers(),
    body: JSON.stringify(updates),
  })
  return res.ok
}

async function main() {
  console.log('🌊  Hydrolyze — Seeding swimmer data...\n')

  // ── 1. Patch existing swimmer_stats to set_id=50 ────────────────────────
  console.log('🔧  Backfilling set_id=50 on existing swimmer_stats...')
  const existing = await get('swimmer_stats', 'select=swimmer_id,stroke')
  for (const record of existing) {
    await patch('swimmer_stats', { swimmer_id: record.swimmer_id, stroke: record.stroke }, { set_id: 50 })
  }
  console.log(`   ✅  ${existing.length} records updated`)

  // ── 2. Seed PBs ─────────────────────────────────────────────────────────
  const existingPBs = await get('swimmer_pbs', 'select=swimmer_id,stroke,distance')
  const pbSet = new Set(existingPBs.map(r => `${r.swimmer_id}|${r.stroke}|${r.distance}`))
  const newPBs = PBS.filter(p => !pbSet.has(`${p.swimmer_id}|${p.stroke}|${p.distance}`))

  if (newPBs.length > 0) {
    console.log(`\n📋  Upserting ${newPBs.length} PBs...`)
    await upsert('swimmer_pbs', newPBs)
    console.log(`   ✅  ${newPBs.length} PBs inserted`)
  } else {
    console.log('\n✅  PBs already seeded')
  }

  // ── 3. Seed training stats with set_id=50 ───────────────────────────────
  console.log('\n💾  Upserting training stats (set_id=50)...')
  await upsert('swimmer_stats', TRAINING_STATS)
  console.log(`   ✅  ${TRAINING_STATS.length} stats records upserted\n`)

  // ── 4. Summary ──────────────────────────────────────────────────────────
  console.log('─── 50m Free stats in DB ──────────────────────────────────')
  const freeStats = TRAINING_STATS.filter(s => s.stroke === 'Free')
  for (const s of freeStats) {
    const name = Object.entries(SWIMMERS).find(([, id]) => id === s.swimmer_id)?.[0] ?? '?'
    const secs = (s.mean_time_ms / 1000).toFixed(2)
    const sigma = (s.stddev_time_ms / 1000).toFixed(3)
    console.log(`  ${name.padEnd(8)}  ${secs}s  (±${sigma}s, n=${s.sample_count})`)
  }

  console.log('\n✅  Done! Time a 50m Free set to see ML confidence scores.')
}

main().catch(err => {
  console.error('❌  Error:', err.message || err)
  process.exit(1)
})