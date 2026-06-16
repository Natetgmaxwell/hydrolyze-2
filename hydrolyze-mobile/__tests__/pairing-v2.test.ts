/**
 * Integration tests for pairing-v2 in the Hydrolyze React Native app.
 * Tests the rankLap function with the same swimmer data the app uses.
 */

import { describe, test, expect } from '@jest/globals'
import { predict, rankLap } from '../lib/pairing-v2'
import type { Swimmer } from '../lib/ml-pairing'

// ─── App-style swimmer helpers ────────────────────────────────────────────────

const SWIMMERS: Swimmer[] = [
  { id: 'marcus', name: 'Marcus', form_stroke: null },
  { id: 'jake',   name: 'Jake',   form_stroke: null },
  { id: 'sofia',  name: 'Sofia',  form_stroke: null },
  { id: 'lily',   name: 'Lily',   form_stroke: null },
  { id: 'ryan',   name: 'Ryan',   form_stroke: null },
]

const recordedStats = {
  marcus: { meanTimeMs: 26800, stddevMs: 280, sampleCount: 12 },
  jake:   { meanTimeMs: 27800, stddevMs: 300, sampleCount: 12 },
  sofia:  { meanTimeMs: 30200, stddevMs: 280, sampleCount: 11 },
  lily:   { meanTimeMs: 32500, stddevMs: 700, sampleCount: 5 },
  ryan:   { meanTimeMs: 25400, stddevMs: 150, sampleCount: 15 },
}

// ─── Mock prediction lookup (simulates StatsCache) ─────────────────────────────

function getPrediction(swimmerId: string) {
  const stats = recordedStats[swimmerId as keyof typeof recordedStats]
  if (stats) {
    return predict(stats, [], 'Free', 50, 'moderate', null)
  }
  return predict(null, [], 'Free', 50, 'moderate', null)
}

// ─── Tests ─────────────────────────────────────────────────────────────────────

describe('predict — Layer 1/2/3 priority', () => {
  test('recorded stats used when available', () => {
    const pred = predict(recordedStats.jake, [], 'Free', 50, 'moderate', null)
    expect(pred.source).toBe('recorded')
    expect(pred.expectedTimeMs).toBeCloseTo(27800, -1)
    expect(pred.sampleCount).toBe(12)
  })

  test('population seed used when no recorded stats', () => {
    const pred = predict(null, [], 'Free', 50, 'moderate', null)
    expect(pred.source).toBe('seed')
    expect(pred.sampleCount).toBe(1)
    expect(pred.expectedTimeMs).toBeGreaterThan(30000)
  })

  test('gear multiplier applied to recorded stats', () => {
    const pred = predict(recordedStats.jake, [], 'Free', 50, 'moderate', 'paddles')
    expect(pred.source).toBe('recorded')
    expect(pred.expectedTimeMs).toBeCloseTo(27800 * 1.05, -1)
    expect(pred.gearMultiplier).toBe(1.05)
  })

  test('fins multiplier makes swimmer faster (lower expected time)', () => {
    const noFins = predict(recordedStats.jake, [], 'Free', 50, 'moderate', null)
    const withFins = predict(recordedStats.jake, [], 'Free', 50, 'moderate', 'fins')
    expect(withFins.expectedTimeMs).toBeLessThan(noFins.expectedTimeMs)
  })

  test('race intensity → lower multiplier for curve-derived predictions', () => {
    const moderate = predict(null, [{ distance: 50, pbMs: 27000 }], 'Free', 50, 'moderate', null)
    const race = predict(null, [{ distance: 50, pbMs: 27000 }], 'Free', 50, 'race', null)
    expect(race.intensityMultiplier).toBeLessThan(moderate.intensityMultiplier)
    expect(race.expectedTimeMs).toBeLessThan(moderate.expectedTimeMs)
  })
})

describe('rankLap — residual ranking in app context', () => {
  test('exact match → errorMs=0, marginRatio=null, suspicious=false', () => {
    const ranked = rankLap(27800, SWIMMERS, 'Free', 50, 'moderate', null, getPrediction)
    expect(ranked[0].swimmerId).toBe('jake')
    expect(ranked[0].errorMs).toBe(0)
    expect(ranked[0].suspicious).toBe(false)
    expect(ranked[0].marginRatio).toBeNull()
  })

  test('Jake swims 38.4s → Lily wins (lowest residual in pool)', () => {
    const ranked = rankLap(38400, SWIMMERS, 'Free', 50, 'moderate', null, getPrediction)
    // Lily has lowest residual: |38400-32500|=5900ms
    expect(ranked[0].swimmerId).toBe('lily')
    expect(ranked[0].errorMs).toBe(5900)
    expect(ranked[0].suspicious).toBe(true) // 5900ms > 4000ms threshold
  })

  test('Sofia swims 32.9s → Lily wins (residual: Lily=400ms, Sofia=2700ms)', () => {
    const ranked = rankLap(32900, SWIMMERS, 'Free', 50, 'moderate', null, getPrediction)
    expect(ranked[0].swimmerId).toBe('lily')
    expect(ranked[0].errorMs).toBe(400)
    expect(ranked[0].suspicious).toBe(false)
  })

  test('Ryan swims 25.4s → Ryan first (zero residual)', () => {
    const ranked = rankLap(25400, SWIMMERS, 'Free', 50, 'moderate', null, getPrediction)
    expect(ranked[0].swimmerId).toBe('ryan')
    expect(ranked[0].errorMs).toBe(0)
  })

  test('IM stroke → empty ranking (always manual)', () => {
    const ranked = rankLap(95000, SWIMMERS, 'IM', 100, 'moderate', null, getPrediction)
    expect(ranked).toHaveLength(0)
  })

  test('margin ratio: close swimmers → low ratio', () => {
    // Lap=26.0s. Ryan=600ms, Marcus=800ms, Jake=1800ms. Margin=800/600=1.33
    const ranked = rankLap(26000, SWIMMERS, 'Free', 50, 'moderate', null, getPrediction)
    expect(ranked[0].swimmerId).toBe('ryan')
    expect(ranked[0].errorMs).toBe(600)
    expect(ranked[0].marginRatio).toBeCloseTo(1.33, 1)
  })

  test('suspicious threshold: 8s off → suspicious', () => {
    const ranked = rankLap(56000, SWIMMERS, 'Free', 50, 'moderate', null, getPrediction)
    expect(ranked[0].suspicious).toBe(true)
    expect(ranked[0].errorMs).toBe(23500)
  })

  test('custom suspicious threshold', () => {
    // 5.1s off: default 4s → suspicious. With 6s threshold → not suspicious.
    const ranked = rankLap(37600, SWIMMERS, 'Free', 50, 'moderate', null, getPrediction, 6000)
    expect(ranked[0].suspicious).toBe(false)
  })

  test('z-score computed from residual / stddev', () => {
    const ranked = rankLap(27800, [SWIMMERS[1]], 'Free', 50, 'moderate', null, getPrediction)
    expect(ranked[0].zScore).toBe(0)

    const ranked2 = rankLap(32900, [SWIMMERS[3]], 'Free', 50, 'moderate', null, getPrediction)
    expect(ranked2[0].zScore).toBeCloseTo(0.57, 1)
  })

  test('source badge: recorded vs seed', () => {
    const withData = rankLap(27800, [SWIMMERS[1]], 'Free', 50, 'moderate', null, getPrediction)
    expect(withData[0].source).toBe('recorded')

    const newSwimmer: Swimmer = { id: 'new', name: 'New', form_stroke: null }
    const noData = rankLap(30000, [newSwimmer], 'Free', 50, 'moderate', null, getPrediction)
    expect(noData[0].source).toBe('seed')
  })
})

describe('App integration — results screen data', () => {
  test('swimmerName derived from swimmerMap + best swimmer', () => {
    const swimmerMap: Record<string, string> = Object.fromEntries(SWIMMERS.map(s => [s.id, s.name]))
    const lapTimeMs = 32900
    const ranked = rankLap(lapTimeMs, SWIMMERS, 'Free', 50, 'moderate', null, getPrediction)
    const best = ranked[0]
    const swimmerName = swimmerMap[best.swimmerId]
    expect(swimmerName).toBe('Lily')
    expect(best.errorMs).toBe(400)
    expect(best.source).toBe('recorded')
    expect(best.suspicious).toBe(false)
  })

  test('sourceMap populated from ranked results', () => {
    const ranked = rankLap(32900, SWIMMERS, 'Free', 50, 'moderate', null, getPrediction)
    const sourceMap: Record<string, string> = {}
    for (const r of ranked) sourceMap[r.swimmerId] = r.source
    expect(sourceMap.lily).toBe('recorded')
    expect(sourceMap.ryan).toBe('recorded')
  })

  test('sampleCountMap from recordedStats', () => {
    const sampleCountMap: Record<string, number> = {}
    for (const [id, stats] of Object.entries(recordedStats)) {
      sampleCountMap[id] = stats.sampleCount
    }
    expect(sampleCountMap.lily).toBe(5) // 5 samples → learning tier
  })

  test('swap to second-best swimmer → new swimmerId', () => {
    const lapTimeMs = 32900
    const ranked = rankLap(lapTimeMs, SWIMMERS, 'Free', 50, 'moderate', null, getPrediction)
    expect(ranked[0].swimmerId).toBe('lily')
    expect(ranked[1].swimmerId).toBe('sofia')
    expect(ranked[1].errorMs).toBe(2700)
  })
})