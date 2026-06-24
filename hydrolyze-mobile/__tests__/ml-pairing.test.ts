import { pairTime, rankSwimmers } from '../lib/ml-pairing'
import type { Swimmer, StatsCache, Stroke } from '../lib/ml-pairing'

// ─── StatsCache entry builder ──────────────────────────────────────────────────

function makeStats(
  mean: number,
  stddev: number,
  n = 10,
  source: 'recorded' | 'curve' | 'seed' = 'recorded',
  pbMs?: number,
) {
  return {
    mean_time_ms: mean,
    stddev_time_ms: stddev,
    sample_count: n,
    is_estimated: source !== 'recorded',
    assignmentSource: source,
    ...(pbMs != null ? { pb_predicted_ms: pbMs } : {}),
  }
}

// 5D key: swimmerId:stroke:distance:intensity:gear
function sk(swimmerId: string, stroke: Stroke = 'Free', distance = 50, intensity = 'moderate', gear = 'none'): string {
  return `${swimmerId}:${stroke}:${distance}:${intensity}:${gear}`
}

// ─── Swimmers ─────────────────────────────────────────────────────────────────

const swimmerA: Swimmer = { id: 'A', name: 'Alice', form_stroke: 'Back' }
const swimmerB: Swimmer = { id: 'B', name: 'Bob', form_stroke: 'Free' }
const swimmerC: Swimmer = { id: 'C', name: 'Charlie', form_stroke: 'Free' }

// ─── Core residual ranking tests ───────────────────────────────────────────────

describe('pairTime — residual ranking', () => {
  test('exact match — zero residual — winner is swimmer closest to their own mean', () => {
    const cache: StatsCache = {
      [sk('A')]: makeStats(60000, 1000),
      [sk('B')]: makeStats(75000, 1000),
    }
    const result = pairTime(60000, [swimmerA, swimmerB], cache, 'Free', 'moderate', 50, null)
    expect(result?.swimmerId).toBe('A')
    expect(result?.errorMs).toBe(0)
    expect(result?.source).toBe('recorded')
  })

  test('closest to mean wins by raw residual', () => {
    // A mean=60000, B mean=75000. Lap=70000ms.
    // A: |70000-60000|=10000ms. B: |70000-75000|=5000ms → B wins
    const cache: StatsCache = {
      [sk('A')]: makeStats(60000, 500),
      [sk('B')]: makeStats(75000, 500),
    }
    const result = pairTime(70000, [swimmerA, swimmerB], cache, 'Free', 'moderate', 50, null)
    expect(result?.swimmerId).toBe('B')
    expect(result?.errorMs).toBe(5000)
  })

  test('same stddev, similar means — swimmer closest to lap wins', () => {
    const cache: StatsCache = {
      [sk('A')]: makeStats(60000, 1000),
      [sk('B')]: makeStats(60200, 1000),
    }
    // Lap=60100ms: A residual=100ms, B residual=100ms → tie → pool order → A wins
    const result = pairTime(60100, [swimmerA, swimmerB], cache, 'Free', 'moderate', 50, null)
    expect(result?.swimmerId).toBe('A')
    expect(result?.errorMs).toBe(100)
  })

  test('different distances — picks right StatsCache entry', () => {
    const k50 = sk('A', 'Free', 50)
    const k100 = sk('A', 'Free', 100)
    const cache: StatsCache = {
      [k50]:  makeStats(60000, 1000),
      [k100]: makeStats(120000, 2000),
    }
    const result = pairTime(60000, [swimmerA], cache, 'Free', 'moderate', 50, null)
    expect(result?.swimmerId).toBe('A')
    expect(result?.errorMs).toBe(0)
  })

  test('paddles gear shifts expected time up 5 percent', () => {
    // A bare=60000ms, B bare=58000ms. Lap=60000ms. No gear → A wins (0ms vs 2000ms).
    const kBareA = sk('A', 'Free', 50, 'moderate', 'none')
    const kBareB = sk('B', 'Free', 50, 'moderate', 'none')
    const cacheBare: StatsCache = {
      [kBareA]: makeStats(60000, 500),
      [kBareB]: makeStats(58000, 500),
    }
    expect(pairTime(60000, [swimmerA, swimmerB], cacheBare, 'Free', 'moderate', 50, null)?.swimmerId).toBe('A')

    // With paddles: effective A=63000ms, B=60900ms. Lap=60000ms.
    // A residual=3000ms, B residual=900ms → B wins
    const kPadA = sk('A', 'Free', 50, 'moderate', 'paddles')
    const kPadB = sk('B', 'Free', 50, 'moderate', 'paddles')
    const cachePad: StatsCache = {
      [kPadA]: makeStats(60000, 500),
      [kPadB]: makeStats(58000, 500),
    }
    expect(pairTime(60000, [swimmerA, swimmerB], cachePad, 'Free', 'moderate', 50, 'paddles')?.swimmerId).toBe('B')
  })

  test('fins gear shifts expected time down 12 percent', () => {
    // With fins (0.88x): effective A=52800ms, B=51040ms. Lap=60000ms.
    // A residual=7200ms, B residual=8960ms → A wins
    const kA = sk('A', 'Free', 50, 'moderate', 'fins')
    const kB = sk('B', 'Free', 50, 'moderate', 'fins')
    const cache: StatsCache = {
      [kA]: makeStats(60000, 500),
      [kB]: makeStats(58000, 500),
    }
    expect(pairTime(60000, [swimmerA, swimmerB], cache, 'Free', 'moderate', 50, 'fins')?.swimmerId).toBe('A')
  })

  test('no entry in cache — swimmer skipped in ranking', () => {
    const cache: StatsCache = { [sk('A')]: makeStats(60000, 1000) }
    // B has no entry — should be skipped
    const result = pairTime(60000, [swimmerA, swimmerB], cache, 'Free', 'moderate', 50, null)
    expect(result?.swimmerId).toBe('A')
    expect(result?.source).toBe('recorded')
  })

  test('no stats for any swimmer — first swimmer assigned with seed source', () => {
    const cache: StatsCache = {}
    const result = pairTime(60000, [swimmerA, swimmerB], cache, 'Free', 'moderate', 50, null)
    expect(result?.swimmerId).toBe('A')
    expect(result?.source).toBe('seed')
    expect(result?.sampleCount).toBe(0)
  })

  test('Form stroke resolves to swimmer form_stroke', () => {
    const cache: StatsCache = { [sk('A', 'Back')]: makeStats(65000, 1000) }
    const result = pairTime(65000, [swimmerA], cache, 'Form', 'moderate', 50, null)
    expect(result?.swimmerId).toBe('A')
    expect(result?.source).toBe('recorded')
  })

  test('Form stroke with null formStroke defaults to Free', () => {
    const freeSwimmer: Swimmer = { id: 'C', name: 'Charlie', form_stroke: null }
    const cache: StatsCache = { [sk('C', 'Free')]: makeStats(60000, 1000) }
    const result = pairTime(60000, [freeSwimmer], cache, 'Form', 'moderate', 50, null)
    expect(result?.swimmerId).toBe('C')
  })

  test('IM stroke always returns null', () => {
    const cache: StatsCache = { [sk('A', 'IM', 100)]: makeStats(95000, 2000) }
    expect(pairTime(95000, [swimmerA], cache, 'IM', 'moderate', 100, null)).toBeNull()
  })

  test('empty pool returns null', () => {
    expect(pairTime(60000, [], {}, 'Free', 'moderate', 50, null)).toBeNull()
  })
})

// ─── Seeded swimmer real-world scenarios ────────────────────────────────────

describe('pairTime — seeded swimmer data', () => {
  const jake:  Swimmer = { id: 'jake',  name: 'Jake',   form_stroke: null }
  const sofia: Swimmer = { id: 'sofia', name: 'Sofia',  form_stroke: null }
  const lily:  Swimmer = { id: 'lily',  name: 'Lily',   form_stroke: null }
  const ryan:  Swimmer = { id: 'ryan',  name: 'Ryan',   form_stroke: null }

  function seededCache(): StatsCache {
    return {
      [sk('jake')]:  makeStats(27800, 300),
      [sk('sofia')]: makeStats(30200, 280),
      [sk('lily')]:  makeStats(32500, 700),
      [sk('ryan')]:  makeStats(25400, 150),
    }
  }

  test('Jake swims 27.8 seconds — Jake wins (zero residual)', () => {
    const result = pairTime(27800, [jake, sofia, lily, ryan], seededCache(), 'Free', 'moderate', 50, null)
    expect(result?.swimmerId).toBe('jake')
    expect(result?.errorMs).toBe(0)
  })

  test('Jake swims 38.4 seconds — Lily wins (lowest residual in pool)', () => {
    // Jake |38400-27800|=10600ms, Sofia 8200ms, Lily 5900ms, Ryan 13000ms → Lily wins
    const result = pairTime(38400, [jake, sofia, lily, ryan], seededCache(), 'Free', 'moderate', 50, null)
    expect(result?.swimmerId).toBe('lily')
    expect(result?.errorMs).toBe(5900)
  })

  test('Sofia swims 32.9 seconds — Lily wins (residual: Lily 400ms vs Sofia 2700ms)', () => {
    const result = pairTime(32900, [jake, sofia, lily, ryan], seededCache(), 'Free', 'moderate', 50, null)
    expect(result?.swimmerId).toBe('lily')
    expect(result?.errorMs).toBe(400)
  })

  test('Ryan swims 25.4 seconds — Ryan first (zero residual)', () => {
    const result = pairTime(25400, [jake, sofia, lily, ryan], seededCache(), 'Free', 'moderate', 50, null)
    expect(result?.swimmerId).toBe('ryan')
    expect(result?.errorMs).toBe(0)
  })
})

// ─── Source and sample count propagation ───────────────────────────────────

describe('pairTime — source and sample count', () => {
  test('recorded stats — source=recorded, sampleCount from entry', () => {
    const cache: StatsCache = { [sk('A')]: makeStats(60000, 500, 8) }
    const result = pairTime(60000, [swimmerA], cache, 'Free', 'moderate', 50, null)
    expect(result?.source).toBe('recorded')
    expect(result?.sampleCount).toBe(8)
  })

  test('curve source — PB-derived predictions', () => {
    const cache: StatsCache = { [sk('A')]: makeStats(60000, 600, 2, 'curve', 58000) }
    expect(pairTime(60000, [swimmerA], cache, 'Free', 'moderate', 50, null)?.source).toBe('curve')
  })

  test('seed source — population average', () => {
    const cache: StatsCache = { [sk('A')]: makeStats(60000, 600, 1, 'seed') }
    expect(pairTime(60000, [swimmerA], cache, 'Free', 'moderate', 50, null)?.source).toBe('seed')
  })

  test('seed — empty cache', () => {
    const result = pairTime(60000, [swimmerA], {}, 'Free', 'moderate', 50, null)
    expect(result?.source).toBe('seed')
    expect(result?.sampleCount).toBe(0)
  })
})

// ─── rankSwimmers — full ranking for swap modal ─────────────────────────────

describe('rankSwimmers — full ranking', () => {
  test('returns all swimmers sorted by residual ascending', () => {
    const cache: StatsCache = {
      [sk('A')]: makeStats(60000, 500),
      [sk('B')]: makeStats(75000, 500),
    }
    const ranked = rankSwimmers(70000, [swimmerA, swimmerB], cache, 'Free', 'moderate', 50, null)
    expect(ranked[0].swimmerId).toBe('B') // residual=5000ms < 10000ms
    expect(ranked[1].swimmerId).toBe('A')
    expect(ranked[0].errorMs).toBe(5000)
    expect(ranked[1].errorMs).toBe(10000)
  })

  test('exact match — first swimmer has errorMs=0', () => {
    const cache: StatsCache = { [sk('A')]: makeStats(60000, 500) }
    const ranked = rankSwimmers(60000, [swimmerA], cache, 'Free', 'moderate', 50, null)
    expect(ranked[0].errorMs).toBe(0)
    expect(ranked[0].swimmerName).toBe('Alice')
  })

  test('IM stroke returns empty array', () => {
    const cache: StatsCache = { [sk('A')]: makeStats(60000, 500) }
    expect(rankSwimmers(60000, [swimmerA], cache, 'IM', 'moderate', 50, null)).toHaveLength(0)
  })

  test('includes expectedTimeMs source and sampleCount for each swimmer', () => {
    const cache: StatsCache = { [sk('A')]: makeStats(60000, 500, 5, 'recorded') }
    const ranked = rankSwimmers(65000, [swimmerA], cache, 'Free', 'moderate', 50, null)
    expect(ranked[0].expectedTimeMs).toBe(60000)
    expect(ranked[0].errorMs).toBe(5000)
    expect(ranked[0].source).toBe('recorded')
    expect(ranked[0].sampleCount).toBe(5)
  })

  test('swimmer with no data — errorMs=Infinity in ranking', () => {
    const cache: StatsCache = { [sk('A')]: makeStats(60000, 500) }
    const ranked = rankSwimmers(60000, [swimmerA, swimmerB], cache, 'Free', 'moderate', 50, null)
    const b = ranked.find(r => r.swimmerId === 'B')
    expect(b?.errorMs).toBe(Infinity)
    expect(b?.source).toBe('seed')
  })
})