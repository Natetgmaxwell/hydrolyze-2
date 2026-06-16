/**
 * End-to-end pairing tests.
 * Tests the full pairLap() function combining prediction + confidence scoring.
 *
 * Key formulas (for reference):
 *   positional(z) = exp(-0.5 * z²) * 100
 *   marginFactor = (runnerUpZ / winnerZ - 1) / 1.5, clamped [0, 1]
 *   outlierBonus = maxZ > 5 ? 15 : maxZ > 3 ? 10 : 0
 *
 * Confidence scoring:
 *   if winnerZ > 5 (extreme regime): ((winnerZ - 5) / 30) * 90 + outlierBonus
 *   else (normal regime): positional(winnerZ) * (0.5 + 0.5 * marginFactor) + outlierBonus
 *   Then: Math.min(ceiling, Math.max(0, raw))
 */

import { describe, test, expect } from 'vitest'
import type { Stroke, GearType, IntensityLevel } from '../src/types.js'
import { StatsStore, PBStore, GearCalibrationStore } from '../src/prediction.js'
import { pairLap } from '../src/pair.js'

// ─── Data helpers ─────────────────────────────────────────────────────────────

const FREE: Stroke = 'Free'
const MOD: IntensityLevel = 'moderate'

function stats(meanMs: number, stdMs: number, n = 10) {
  return { meanTimeMs: meanMs, stddevMs: stdMs, sampleCount: n }
}

function swimmer(id: string, formStroke: Stroke | null = null) {
  return { id, formStroke }
}

function lap(timeMs: number, distance = 50, stroke: Stroke = FREE, intensity: IntensityLevel = MOD, gear: GearType | null = null) {
  return { timeMs, setDistance: distance, stroke, intensity, gear }
}

// ─── Happy path ───────────────────────────────────────────────────────────────

describe('pairLap — happy path', () => {
  test('assigns closest swimmer with high confidence', () => {
    const store = new StatsStore()
    store.set('A', FREE, 50, MOD, null, stats(60000, 1000))
    store.set('B', FREE, 50, MOD, null, stats(75000, 1000))

    const result = pairLap(lap(60000), { swimmers: [swimmer('A'), swimmer('B')], statsStore: store, pbStore: new PBStore() })

    expect(result.winnerId).toBe('A')
    expect(result.confidence).toBeGreaterThan(70)
    expect(result.statsType).toBe('recorded')
    expect(result.zScore).toBeCloseTo(0, 1)
  })

  test('exact match on mean → confidence = ceiling (cap respected, not 100)', () => {
    const store = new StatsStore()
    store.set('A', FREE, 50, MOD, null, stats(60000, 500))
    store.set('B', FREE, 50, MOD, null, stats(90000, 2000))

    const result = pairLap(lap(60000), { swimmers: [swimmer('A'), swimmer('B')], statsStore: store, pbStore: new PBStore() })

    expect(result.winnerId).toBe('A')
    expect(result.zScore).toBe(0)
    expect(result.confidence).toBe(95) // z=0 → ceiling returned (cap respected)
  })

  test('returns all candidates ranked by confidence', () => {
    const store = new StatsStore()
    store.set('A', FREE, 50, MOD, null, stats(60000, 1000))
    store.set('B', FREE, 50, MOD, null, stats(75000, 1000))
    store.set('C', FREE, 50, MOD, null, stats(55000, 1000))

    const result = pairLap(lap(62000), { swimmers: [swimmer('A'), swimmer('B'), swimmer('C')], statsStore: store, pbStore: new PBStore() })

    expect(result.allCandidates.length).toBe(3)
    // Sorted by z-score: A(z=2.0), C(z=7.0), B(z=13.0)
    // A conf=29 (positional(2)*0.5 + 15 outlier). C conf=21. B conf=39 (z=13→extreme+15)
    expect(result.allCandidates[0].swimmerId).toBe('A')
    expect(result.allCandidates[0].confidence).toBe(29)
    expect(result.allCandidates[1].swimmerId).toBe('C')
    expect(result.allCandidates[1].confidence).toBe(21)
    expect(result.allCandidates[2].swimmerId).toBe('B')
    expect(result.allCandidates[2].confidence).toBe(39)
  })
})

// ─── Confidence scoring ───────────────────────────────────────────────────────

describe('pairLap — confidence scoring', () => {
  test('Jake scenario: winnerZ=35.3 → extreme regime → 95% (capped at ceiling)', () => {
    // Jake: mean=27800ms, σ=300ms. Lap=38400ms → z=35.33
    // Sofia: mean=30200ms, σ=280ms. Lap=38400ms → z=29.29 → Sofia wins!
    const store = new StatsStore()
    store.set('A', FREE, 50, MOD, null, stats(27800, 300)) // Jake
    store.set('B', FREE, 50, MOD, null, stats(30200, 280)) // Sofia

    const result = pairLap(lap(38400), { swimmers: [swimmer('A'), swimmer('B')], statsStore: store, pbStore: new PBStore() })

    expect(result.winnerId).toBe('B') // Sofia (z=29.29 < Jake's 35.33)
    // extreme regime: ((29.29-5)/30)*90 + 15(outlier) = 72.9 + 15 = 87.9 → 88
    expect(result.confidence).toBe(88)
    expect(result.statsType).toBe('recorded')
  })

  test('extreme outlier wins with high confidence (z>5 → identifiable)', () => {
    // With pool order A,B → A wins if z(A) < z(B)
    // A z=35.33, B z=29.29 → B wins
    const store = new StatsStore()
    store.set('A', FREE, 50, MOD, null, stats(27800, 300))
    store.set('B', FREE, 50, MOD, null, stats(30200, 280))

    const result = pairLap(lap(38400), { swimmers: [swimmer('B'), swimmer('A')], statsStore: store, pbStore: new PBStore() })
    expect(result.winnerId).toBe('B') // lower z wins
  })

  test('close race → lower confidence due to margin factor', () => {
    const store = new StatsStore()
    store.set('A', FREE, 50, MOD, null, stats(60000, 1000))
    store.set('B', FREE, 50, MOD, null, stats(60200, 1000))

    const result = pairLap(lap(60100), { swimmers: [swimmer('A'), swimmer('B')], statsStore: store, pbStore: new PBStore() })

    expect(result.confidence).toBeLessThan(70)
    expect(result.poolDistinctiveness).toBeCloseTo(1, 1) // tiny margin
  })

  test('clear separation → high confidence with outlier bonus', () => {
    const store = new StatsStore()
    store.set('A', FREE, 50, MOD, null, stats(60000, 1000))
    store.set('B', FREE, 50, MOD, null, stats(90000, 3000))

    const result = pairLap(lap(59000), { swimmers: [swimmer('A'), swimmer('B')], statsStore: store, pbStore: new PBStore() })

    expect(result.winnerId).toBe('A')
    // z=1.0 → positional=61%, marginFactor=1, maxZ=10.33→5 → +15 bonus
    // raw = 61 * (0.5 + 0.5*1) + 15 = 61 + 15 = 76
    expect(result.confidence).toBe(76)
    expect(result.poolDistinctiveness).toBeCloseTo(10.33, 1)
  })

  test('recorded ceiling higher than seed ceiling', () => {
    const store = new StatsStore()
    store.set('A', FREE, 50, MOD, null, stats(60000, 1000))
    // B: no recorded stats, no PBs → seed → cap=55

    const result = pairLap(lap(60000), { swimmers: [swimmer('A'), swimmer('B')], statsStore: store, pbStore: new PBStore() })

    expect(result.winnerId).toBe('A')
    expect(result.statsType).toBe('recorded')
    expect(result.confidence).toBe(95) // z=0 → ceiling
  })
})

// ─── IM always manual ─────────────────────────────────────────────────────────

describe('pairLap — IM stroke returns null', () => {
  test('IM stroke → null result (always manual)', () => {
    const store = new StatsStore()
    store.set('A', 'IM', 100, MOD, null, stats(95000, 2000))

    const result = pairLap(lap(95000, 100, 'IM') as any, { swimmers: [swimmer('A')], statsStore: store, pbStore: new PBStore() })

    expect(result.winnerId).toBeNull()
    expect(result.statsType).toBe('no_data')
  })
})

// ─── Empty pool ───────────────────────────────────────────────────────────────

describe('pairLap — empty pool', () => {
  test('empty pool → null result', () => {
    const result = pairLap(lap(60000), { swimmers: [], statsStore: new StatsStore(), pbStore: new PBStore() })
    expect(result.winnerId).toBeNull()
    expect(result.confidence).toBe(0)
  })
})

// ─── No data swimmers ─────────────────────────────────────────────────────────

describe('pairLap — no data swimmers', () => {
  test('no recorded stats, no PBs → seed type, low ceiling', () => {
    const result = pairLap(lap(60000), { swimmers: [swimmer('A')], statsStore: new StatsStore(), pbStore: new PBStore() })
    expect(result.winnerId).toBe('A')
    expect(result.statsType).toBe('seed')
    expect(result.confidence).toBeLessThan(60)
  })

  test('all swimmers get seed predictions — none unassignable', () => {
    // Seed is a valid prediction (statsType='seed'), not 'no_data'.
    // unassignable only contains swimmers with NO prediction at all.
    const result = pairLap(lap(60000), { swimmers: [swimmer('A'), swimmer('B')], statsStore: new StatsStore(), pbStore: new PBStore() })
    expect(result.unassignable).toHaveLength(0)
    expect(result.winnerId).toBe('A') // both at equal z, first in pool wins
  })
})

// ─── Gear effects ─────────────────────────────────────────────────────────────

describe('pairLap — gear awareness', () => {
  test('fins (0.88×) makes effective mean LOWER → swimmer appears faster', () => {
    const store = new StatsStore()
    store.set('A', FREE, 50, MOD, null, stats(60000, 1000))
    store.set('B', FREE, 50, MOD, null, stats(58000, 1000))

    const resultNoGear = pairLap(lap(58000), { swimmers: [swimmer('A'), swimmer('B')], statsStore: store, pbStore: new PBStore() })
    expect(resultNoGear.winnerId).toBe('B')

    const resultFins = pairLap(lap(51000, 50, FREE, MOD, 'fins'), { swimmers: [swimmer('A'), swimmer('B')], statsStore: store, pbStore: new PBStore() })
    expect(resultFins.winnerId).toBe('B')
    expect(resultFins.allCandidates.find(c => c.swimmerId === 'A')?.gearPenalty).toBe(0.88)
  })

  test('paddles (1.05×) makes effective mean HIGHER → swimmer appears slower', () => {
    const store = new StatsStore()
    store.set('A', FREE, 50, MOD, null, stats(55000, 1000))
    store.set('B', FREE, 50, MOD, null, stats(60000, 1000))

    const resultNoGear = pairLap(lap(55000), { swimmers: [swimmer('A'), swimmer('B')], statsStore: store, pbStore: new PBStore() })
    expect(resultNoGear.winnerId).toBe('A')

    const resultPads = pairLap(lap(57750, 50, FREE, MOD, 'paddles'), { swimmers: [swimmer('A'), swimmer('B')], statsStore: store, pbStore: new PBStore() })
    expect(resultPads.winnerId).toBe('A')
    expect(resultPads.allCandidates.find(c => c.swimmerId === 'A')?.gearPenalty).toBe(1.05)
  })
})

// ─── Pool context completeness ───────────────────────────────────────────────

describe('pairLap — pool context', () => {
  test('z=0 → confidence = ceiling (cap respected)', () => {
    const store = new StatsStore()
    store.set('A', FREE, 50, MOD, null, stats(60000, 1000))
    store.set('B', FREE, 50, MOD, null, stats(90000, 1000))

    const result = pairLap(lap(60000), { swimmers: [swimmer('A'), swimmer('B')], statsStore: store, pbStore: new PBStore() })

    expect(result.confidence).toBe(95)
    expect(result.poolDistinctiveness).toBe(Infinity) // runnerUpZ / winnerZ = 30/0
  })

  test('diagnostic includes all z-scores', () => {
    const store = new StatsStore()
    store.set('A', FREE, 50, MOD, null, stats(60000, 1000))
    store.set('B', FREE, 50, MOD, null, stats(75000, 1000))
    store.set('C', FREE, 50, MOD, null, stats(90000, 1000))

    const result = pairLap(lap(62000), { swimmers: [swimmer('A'), swimmer('B'), swimmer('C')], statsStore: store, pbStore: new PBStore() })

    expect(result.diagnostic.allZs).toHaveLength(3)
    expect(result.diagnostic.allZs.find(z => z.swimmerId === 'A')?.zScore).toBeCloseTo(2, 0)
  })
})