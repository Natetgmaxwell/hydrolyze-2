/**
 * End-to-end pairing tests — ranking swimmers by residual (|lap - expected|) for a lap time.
 *
 * Core principle: lower residual = more likely = ranked higher.
 * Raw residual in ms is the primary signal. z-score is secondary context.
 * No confidence scores. Just ranked list.
 */

import { describe, test, expect } from 'vitest'
import { StatsStore, PBStore } from '../src/types.js'
import { rankLap } from '../src/rank.js'
import type { Swimmer, SetContext } from '../src/types.js'

function swimmer(id: string, formStroke: string | null = null): Swimmer {
  return { id, formStroke: formStroke as any ?? null }
}

const ctx50FreeMod: SetContext = { distance: 50, stroke: 'Free', intensity: 'moderate', gear: null }

// ─── Core residual ranking ─────────────────────────────────────────────────────

describe('rankLap — residual ranking', () => {
  test('lowest residual ranked first', () => {
    const store = new StatsStore()
    store.set('A', 'Free', 50, 'moderate', null, { meanTimeMs: 60000, stddevMs: 1000, sampleCount: 10 })
    store.set('B', 'Free', 50, 'moderate', null, { meanTimeMs: 75000, stddevMs: 1000, sampleCount: 10 })

    const ranked = rankLap(60000, [swimmer('A'), swimmer('B')], ctx50FreeMod, store, new PBStore())

    expect(ranked[0].swimmerId).toBe('A')
    expect(ranked[0].errorMs).toBe(0)
    expect(ranked[1].swimmerId).toBe('B')
    expect(ranked[1].errorMs).toBeGreaterThan(ranked[0].errorMs)
  })

  test('exact match → errorMs = 0', () => {
    const store = new StatsStore()
    store.set('A', 'Free', 50, 'moderate', null, { meanTimeMs: 60000, stddevMs: 500, sampleCount: 10 })

    const ranked = rankLap(60000, [swimmer('A')], ctx50FreeMod, store, new PBStore())

    expect(ranked[0].swimmerId).toBe('A')
    expect(ranked[0].errorMs).toBe(0)
    expect(ranked[0].errorSec).toBe(0)
    expect(ranked[0].suspicious).toBe(false)
  })

  test('closest to mean wins (by residual, not z-score)', () => {
    // Key difference from z-score: raw residual.
    // A: 55s mean, B: 60s mean, lap: 58s → A=3s off, B=2s off → B wins (lower residual)
    const store = new StatsStore()
    store.set('A', 'Free', 50, 'moderate', null, { meanTimeMs: 55000, stddevMs: 500, sampleCount: 10 })
    store.set('B', 'Free', 50, 'moderate', null, { meanTimeMs: 60000, stddevMs: 500, sampleCount: 10 })
    store.set('C', 'Free', 50, 'moderate', null, { meanTimeMs: 65000, stddevMs: 500, sampleCount: 10 })

    const ranked = rankLap(58000, [swimmer('A'), swimmer('B'), swimmer('C')], ctx50FreeMod, store, new PBStore())

    // A: |58-55|=3s, B: |58-60|=2s, C: |58-65|=7s → B wins (lowest residual)
    expect(ranked[0].swimmerId).toBe('B')
    expect(ranked[0].errorMs).toBe(2000)
    expect(ranked[0].errorSec).toBeCloseTo(2.0, 0)
  })

  test('raw residual vs z-score — tight stddev case', () => {
    // Both have same stddev=100ms. A mean=60s, B mean=60.2s. Lap=60.1s.
    // A: residual=100ms, z=1.0 | B: residual=100ms, z=1.0 → tie, pool order wins
    const store = new StatsStore()
    store.set('A', 'Free', 50, 'moderate', null, { meanTimeMs: 60000, stddevMs: 100, sampleCount: 20 })
    store.set('B', 'Free', 50, 'moderate', null, { meanTimeMs: 60200, stddevMs: 100, sampleCount: 20 })

    const ranked = rankLap(60100, [swimmer('A'), swimmer('B')], ctx50FreeMod, store, new PBStore())

    expect(ranked[0].errorMs).toBeCloseTo(100, -2)
    expect(ranked[0].marginRatio).toBeCloseTo(1.0, 2) // runnerUp=100ms / winner=100ms = 1.0
  })
})

// ─── Real-world seeded data ────────────────────────────────────────────────────

describe('rankLap — seeded swimmer data', () => {
  // Real seeded: Jake: mean=27800, σ=300ms | Sofia: mean=30200, σ=280ms
  //             Lily: mean=32500, σ=700ms | Ryan: mean=25400, σ=150ms

  test('Jake swims his average (27.8s) → Jake ranked first', () => {
    const store = new StatsStore()
    store.set('jake', 'Free', 50, 'moderate', null, { meanTimeMs: 27800, stddevMs: 300, sampleCount: 12 })
    store.set('sofia', 'Free', 50, 'moderate', null, { meanTimeMs: 30200, stddevMs: 280, sampleCount: 11 })
    store.set('lily', 'Free', 50, 'moderate', null, { meanTimeMs: 32500, stddevMs: 700, sampleCount: 5 })
    store.set('ryan', 'Free', 50, 'moderate', null, { meanTimeMs: 25400, stddevMs: 150, sampleCount: 15 })

    const ranked = rankLap(27800, [swimmer('jake'), swimmer('sofia'), swimmer('lily'), swimmer('ryan')], ctx50FreeMod, store, new PBStore())
    expect(ranked[0].swimmerId).toBe('jake')
    expect(ranked[0].errorMs).toBe(0)
  })

  test('Jake swims 38.4s → Lily wins (lowest residual)', () => {
    const store = new StatsStore()
    store.set('jake', 'Free', 50, 'moderate', null, { meanTimeMs: 27800, stddevMs: 300, sampleCount: 12 })
    store.set('sofia', 'Free', 50, 'moderate', null, { meanTimeMs: 30200, stddevMs: 280, sampleCount: 11 })
    store.set('lily', 'Free', 50, 'moderate', null, { meanTimeMs: 32500, stddevMs: 700, sampleCount: 5 })
    store.set('ryan', 'Free', 50, 'moderate', null, { meanTimeMs: 25400, stddevMs: 150, sampleCount: 15 })

    const ranked = rankLap(38400, [swimmer('jake'), swimmer('sofia'), swimmer('lily'), swimmer('ryan')], ctx50FreeMod, store, new PBStore())

    // Jake: |38400-27800|=10600ms, Sofia: 8200ms, Lily: 5900ms, Ryan: 13000ms → Lily wins
    expect(ranked[0].swimmerId).toBe('lily')
    expect(ranked[0].errorMs).toBe(5900)
    expect(ranked[0].errorSec).toBeCloseTo(5.9, 0)
  })

    test('Jake swims 38.4s → not suspicious (best residual 5.9s > 4s threshold → suspicious)', () => {
    // Actually 5900ms > 4000ms threshold → suspicious should be true
    const store = new StatsStore()
    store.set('jake', 'Free', 50, 'moderate', null, { meanTimeMs: 27800, stddevMs: 300, sampleCount: 12 })
    store.set('sofia', 'Free', 50, 'moderate', null, { meanTimeMs: 30200, stddevMs: 280, sampleCount: 11 })
    store.set('lily', 'Free', 50, 'moderate', null, { meanTimeMs: 32500, stddevMs: 700, sampleCount: 5 })
    store.set('ryan', 'Free', 50, 'moderate', null, { meanTimeMs: 25400, stddevMs: 150, sampleCount: 15 })

    const ranked = rankLap(38400, [swimmer('jake'), swimmer('sofia'), swimmer('lily'), swimmer('ryan')], ctx50FreeMod, store, new PBStore())

    // Best residual = 5900ms > 4000ms threshold → suspicious
    expect(ranked[0].suspicious).toBe(true)
    expect(ranked[0].errorMs).toBe(5900)
  })

  test('Jake swims 27.8s → not suspicious (best residual = 0 < 4000ms)', () => {
    const store = new StatsStore()
    store.set('jake', 'Free', 50, 'moderate', null, { meanTimeMs: 27800, stddevMs: 300, sampleCount: 12 })

    const ranked = rankLap(27800, [swimmer('jake')], ctx50FreeMod, store, new PBStore())
    expect(ranked[0].suspicious).toBe(false)
  })

  test('Sofia swims 32.9s → Lily wins (residual: Lily=400ms vs Sofia=2700ms)', () => {
    const store = new StatsStore()
    store.set('jake', 'Free', 50, 'moderate', null, { meanTimeMs: 27800, stddevMs: 300, sampleCount: 12 })
    store.set('sofia', 'Free', 50, 'moderate', null, { meanTimeMs: 30200, stddevMs: 280, sampleCount: 11 })
    store.set('lily', 'Free', 50, 'moderate', null, { meanTimeMs: 32500, stddevMs: 700, sampleCount: 5 })
    store.set('ryan', 'Free', 50, 'moderate', null, { meanTimeMs: 25400, stddevMs: 150, sampleCount: 15 })

    const ranked = rankLap(32900, [swimmer('jake'), swimmer('sofia'), swimmer('lily'), swimmer('ryan')], ctx50FreeMod, store, new PBStore())

    expect(ranked[0].swimmerId).toBe('lily')
    expect(ranked[0].errorMs).toBe(400) // |32900-32500|
  })

  test('Ryan swims 25.4s → Ryan first (zero residual)', () => {
    const store = new StatsStore()
    store.set('jake', 'Free', 50, 'moderate', null, { meanTimeMs: 27800, stddevMs: 300, sampleCount: 12 })
    store.set('sofia', 'Free', 50, 'moderate', null, { meanTimeMs: 30200, stddevMs: 280, sampleCount: 11 })
    store.set('lily', 'Free', 50, 'moderate', null, { meanTimeMs: 32500, stddevMs: 700, sampleCount: 5 })
    store.set('ryan', 'Free', 50, 'moderate', null, { meanTimeMs: 25400, stddevMs: 150, sampleCount: 15 })

    const ranked = rankLap(25400, [swimmer('jake'), swimmer('sofia'), swimmer('lily'), swimmer('ryan')], ctx50FreeMod, store, new PBStore())
    expect(ranked[0].swimmerId).toBe('ryan')
    expect(ranked[0].errorMs).toBe(0)
  })
})

// ─── Data source handling ───────────────────────────────────────────────────────

describe('rankLap — data source priority', () => {
  test('recorded stats preferred over speed curve', () => {
    const store = new StatsStore()
    store.set('A', 'Free', 50, 'moderate', null, { meanTimeMs: 60000, stddevMs: 500, sampleCount: 10 })

    const pbStore = new PBStore()
    pbStore.set('A', 'Free', [{ distance: 50, pbMs: 26000 }]) // speed curve would predict ~27000ms

    const ranked = rankLap(59000, [swimmer('A')], ctx50FreeMod, store, pbStore)
    expect(ranked[0].source).toBe('recorded')
  })

  test('speed curve used when no recorded stats', () => {
    const store = new StatsStore()
    const pbStore = new PBStore()
    pbStore.set('A', 'Free', [{ distance: 50, pbMs: 27000 }, { distance: 100, pbMs: 58000 }])

    const ranked = rankLap(30000, [swimmer('A')], ctx50FreeMod, store, pbStore)
    expect(ranked[0].source).toBe('curve')
  })

  test('population seed used when no recorded stats and no PBs', () => {
    const ranked = rankLap(35000, [swimmer('A')], ctx50FreeMod, new StatsStore(), new PBStore())
    expect(ranked[0].source).toBe('seed')
  })
})

// ─── Margin ratio (ambiguity flag) ─────────────────────────────────────────────

describe('rankLap — margin ratio (ambiguity flag)', () => {
  test('clear winner → high margin ratio', () => {
    const store = new StatsStore()
    store.set('A', 'Free', 50, 'moderate', null, { meanTimeMs: 60000, stddevMs: 1000, sampleCount: 10 })
    store.set('B', 'Free', 50, 'moderate', null, { meanTimeMs: 90000, stddevMs: 3000, sampleCount: 10 })

    const ranked = rankLap(59000, [swimmer('A'), swimmer('B')], ctx50FreeMod, store, new PBStore())

    expect(ranked[0].swimmerId).toBe('A')
    expect(ranked[0].marginRatio).toBeGreaterThan(5) // 30000/1000 = 30.0
  })

  test('close swimmers → low margin ratio (flag ambiguous)', () => {
    const store = new StatsStore()
    store.set('A', 'Free', 50, 'moderate', null, { meanTimeMs: 60000, stddevMs: 1000, sampleCount: 10 })
    store.set('B', 'Free', 50, 'moderate', null, { meanTimeMs: 60200, stddevMs: 1000, sampleCount: 10 })

    const ranked = rankLap(60100, [swimmer('A'), swimmer('B')], ctx50FreeMod, store, new PBStore())

    // A: residual=100ms, B: residual=100ms → marginRatio = 100/100 = 1.0
    expect(ranked[0].marginRatio).toBeCloseTo(1.0, 2)
  })

  test('single swimmer → margin ratio null', () => {
    const store = new StatsStore()
    store.set('A', 'Free', 50, 'moderate', null, { meanTimeMs: 60000, stddevMs: 1000, sampleCount: 10 })

    const ranked = rankLap(60000, [swimmer('A')], ctx50FreeMod, store, new PBStore())
    expect(ranked[0].marginRatio).toBeNull()
  })
})

// ─── Gear awareness ────────────────────────────────────────────────────────────

describe('rankLap — gear awareness', () => {
  test('paddles shifts expected time up (slower)', () => {
    const store = new StatsStore()
    store.set('A', 'Free', 50, 'moderate', null, { meanTimeMs: 60000, stddevMs: 1000, sampleCount: 10 })
    store.set('B', 'Free', 50, 'moderate', null, { meanTimeMs: 58000, stddevMs: 1000, sampleCount: 10 })

    const ctxPads: SetContext = { distance: 50, stroke: 'Free', intensity: 'moderate', gear: 'paddles' }
    const ranked = rankLap(63000, [swimmer('A'), swimmer('B')], ctxPads, store, new PBStore())

    // Paddles × 1.05: A→63000ms (residual=0), B→60900ms (residual=2100ms) → A wins
    expect(ranked[0].swimmerId).toBe('A')
    expect(ranked[0].errorMs).toBe(0)
  })

  test('fins shifts expected time down (faster)', () => {
    const store = new StatsStore()
    store.set('A', 'Free', 50, 'moderate', null, { meanTimeMs: 60000, stddevMs: 1000, sampleCount: 10 })
    store.set('B', 'Free', 50, 'moderate', null, { meanTimeMs: 58000, stddevMs: 1000, sampleCount: 10 })

    const ctxFins: SetContext = { distance: 50, stroke: 'Free', intensity: 'moderate', gear: 'fins' }
    const ranked = rankLap(51040, [swimmer('A'), swimmer('B')], ctxFins, store, new PBStore())

    // Fins ×0.88: A→52800ms (residual=1760ms), B→51040ms (residual=0) → B wins
    expect(ranked[0].swimmerId).toBe('B')
    expect(ranked[0].errorMs).toBe(0)
  })
})

// ─── Form stroke resolution ────────────────────────────────────────────────────

describe('rankLap — Form stroke resolution', () => {
  test('Form resolves to swimmer formStroke', () => {
    const store = new StatsStore()
    store.set('A', 'Back', 50, 'moderate', null, { meanTimeMs: 65000, stddevMs: 1000, sampleCount: 10 })

    const ctxForm: SetContext = { distance: 50, stroke: 'Form', intensity: 'moderate', gear: null }
    const ranked = rankLap(65000, [swimmer('A', 'Back')], ctxForm, store, new PBStore())

    expect(ranked[0].swimmerId).toBe('A')
    expect(ranked[0].errorMs).toBe(0)
  })

  test('null formStroke defaults to Free', () => {
    const store = new StatsStore()
    store.set('A', 'Free', 50, 'moderate', null, { meanTimeMs: 60000, stddevMs: 1000, sampleCount: 10 })

    const ctxForm: SetContext = { distance: 50, stroke: 'Form', intensity: 'moderate', gear: null }
    const ranked = rankLap(60000, [swimmer('A', null)], ctxForm, store, new PBStore())

    expect(ranked[0].swimmerId).toBe('A')
  })
})

// ─── IM always returns empty ──────────────────────────────────────────────────

describe('rankLap — IM stroke', () => {
  test('IM → empty pool (always manual)', () => {
    const store = new StatsStore()
    store.set('A', 'IM', 100, 'moderate', null, { meanTimeMs: 95000, stddevMs: 2000, sampleCount: 10 })

    const ctxIM: SetContext = { distance: 100, stroke: 'IM', intensity: 'moderate', gear: null }
    const ranked = rankLap(95000, [swimmer('A')], ctxIM, store, new PBStore())

    expect(ranked).toHaveLength(0)
  })
})

// ─── Suspicious lap detection ──────────────────────────────────────────────────

describe('rankLap — suspicious lap detection', () => {
  test('lap >4s from everyone → suspicious=true', () => {
    const store = new StatsStore()
    store.set('A', 'Free', 50, 'moderate', null, { meanTimeMs: 27000, stddevMs: 300, sampleCount: 12 })

    // 27000ms swimmer, lap=35000ms → residual=8000ms > 4000ms threshold
    const ranked = rankLap(35000, [swimmer('A')], ctx50FreeMod, store, new PBStore())
    expect(ranked[0].suspicious).toBe(true)
  })

  test('custom threshold works', () => {
    const store = new StatsStore()
    store.set('A', 'Free', 50, 'moderate', null, { meanTimeMs: 27000, stddevMs: 300, sampleCount: 12 })

    // Default threshold=4000ms: residual=8000ms → suspicious
    const ranked1 = rankLap(35000, [swimmer('A')], ctx50FreeMod, store, new PBStore())
    expect(ranked1[0].suspicious).toBe(true)

    // Threshold=10000ms: residual=8000ms < threshold → not suspicious
    const ranked2 = rankLap(35000, [swimmer('A')], ctx50FreeMod, store, new PBStore(), undefined, 10000)
    expect(ranked2[0].suspicious).toBe(false)
  })

  test('exact match → not suspicious', () => {
    const store = new StatsStore()
    store.set('A', 'Free', 50, 'moderate', null, { meanTimeMs: 27000, stddevMs: 300, sampleCount: 12 })

    const ranked = rankLap(27000, [swimmer('A')], ctx50FreeMod, store, new PBStore())
    expect(ranked[0].suspicious).toBe(false)
    expect(ranked[0].errorMs).toBe(0)
  })
})