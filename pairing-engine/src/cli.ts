/**
 * CLI for the pairing engine.
 *
 * Usage:
 *   npx tsx src/cli.ts --pool=jake,sofia --lap=38400 --stroke=Free --distance=50 --intensity=moderate
 */

import { StatsStore, PBStore } from './prediction.js'
import { pairLap } from './pair.js'
import type { Stroke, IntensityLevel, GearType } from './types.js'

// ─── Parse arguments ─────────────────────────────────────────────────────────

const args: Record<string, string> = {}
for (let i = 2; i < process.argv.length; i++) {
  const arg = process.argv[i]
  const match = arg.match(/^--(.+?)=(.*)$/)
  if (match) {
    args[match[1].replace(/-/g, '_')] = match[2]
  }
}

// ─── Seed data helpers ─────────────────────────────────────────────────────────

function parseSwimmers(poolStr: string) {
  return poolStr.split(',').map((id: string) => ({
    id: id.trim(),
    formStroke: null as Stroke | null,
  }))
}

function parseStroke(s: string | undefined): Stroke {
  const map: Record<string, Stroke> = { free: 'Free', back: 'Back', breast: 'Breast', fly: 'Fly', im: 'IM', form: 'Form' }
  return map[s?.toLowerCase() ?? ''] ?? 'Free'
}

function parseIntensity(s: string | undefined): IntensityLevel {
  const map: Record<string, IntensityLevel> = { easy: 'easy', moderate: 'moderate', hard: 'hard', race: 'race' }
  return map[s?.toLowerCase() ?? ''] ?? 'moderate'
}

function parseGear(s: string | undefined): GearType | null {
  if (!s || s === 'null' || s === 'none') return null
  const valid: GearType[] = ['paddles', 'pull_buoy', 'fins', 'kickboard', 'dragSuit']
  if (valid.includes(s as GearType)) return s as GearType
  return null
}

// ─── Build stores from seed data ──────────────────────────────────────────────

const statsStore = new StatsStore()
const pbStore = new PBStore()

// Seed from the actual Supabase data (50m Free, moderate, no gear)
const seedData = [
  { id: '00000000-0000-0000-0000-000000000001', name: 'Marcus', mean: 26800, std: 280 },
  { id: '00000000-0000-0000-0000-000000000002', name: 'Jake',   mean: 27800, std: 300 },
  { id: '00000000-0000-0000-0000-000000000003', name: 'Sofia', mean: 30200, std: 280 },
  { id: '00000000-0000-0000-0000-000000000004', name: 'Emma',   mean: 31600, std: 450 },
  { id: '00000000-0000-0000-0000-000000000005', name: 'Lily',   mean: 32500, std: 700 },
  { id: '00000000-0000-0000-0000-000000000006', name: 'Ryan',   mean: 25400, std: 150 },
]

for (const s of seedData) {
  statsStore.set(s.id, 'Free', 50, 'moderate', null, {
    meanTimeMs: s.mean,
    stddevMs: s.std,
    sampleCount: 10,
  })
}

// ─── Run pairing ──────────────────────────────────────────────────────────────

if (!args.pool || !args.lap) {
  console.error('Usage: npx tsx src/cli.ts --pool=id1,id2,... --lap=ms [--stroke=Free] [--distance=50] [--intensity=moderate] [--gear=null]')
  process.exit(1)
}

const swimmers = parseSwimmers(args.pool)
const lapTimeMs = parseInt(args.lap)
const stroke: Stroke = parseStroke(args.stroke)
const distance = parseInt(args.distance ?? '50')
const intensity: IntensityLevel = parseIntensity(args.intensity ?? 'moderate')
const gear: GearType | null = parseGear(args.gear)

const result = pairLap(
  { timeMs: lapTimeMs, setDistance: distance, stroke, intensity, gear },
  { swimmers, statsStore, pbStore }
)

// ─── Output ───────────────────────────────────────────────────────────────────

console.log(`\nPairing Engine — CLI\n${'─'.repeat(60)}`)
console.log(`Pool size:    ${swimmers.length} swimmers`)
console.log(`Lap time:     ${(lapTimeMs / 1000).toFixed(2)}s`)
console.log(`Stroke:       ${stroke} / ${distance}m / ${intensity}${gear ? ` / ${gear}` : ''}`)
console.log(`\nResult:`)
console.log(`  Winner:          ${result.winnerId ?? 'null'} (confidence: ${result.confidence}%)`)
console.log(`  Stats type:      ${result.statsType}`)
console.log(`  z-score:          ${result.zScore === Infinity ? '∞' : result.zScore.toFixed(2)}`)
const distLabel = result.poolDistinctiveness === Infinity ? '∞' : result.poolDistinctiveness.toFixed(2)
console.log(`  Distinctiveness: ${distLabel}× over runner-up`)

if (result.diagnostic) {
  console.log(`  Winner mean:     ${(result.diagnostic.winnerMeanMs / 1000).toFixed(2)}s`)
  console.log(`  Winner σ:        ${result.diagnostic.winnerStddevMs}ms`)
  console.log(`  Gear penalty:    ${result.diagnostic.winnerGearPenalty}×`)
}

console.log(`\nFull pool ranking:`)
for (const c of result.allCandidates) {
  const src = c.statsType === 'recorded' ? 'REC  ' : c.statsType === 'curve' ? 'CUR  ' : c.statsType === 'seed' ? 'SEED' : 'ND   '
  const zStr = c.zScore.toFixed(2).padStart(6)
  const confStr = String(c.confidence).padStart(3)
  const meanStr = (c.meanTimeMs / 1000).toFixed(2).padStart(6)
  console.log(`  ${c.swimmerId.padEnd(38)} z=${zStr}  conf=${confStr}%  [${src}]  mean=${meanStr}s  σ=${String(c.stddevMs).padStart(5)}ms  gear=${c.gearPenalty}×`)
}

if (result.unassignable.length > 0) {
  console.log(`\nUnassignable:  ${result.unassignable.join(', ')}`)
}

console.log('')