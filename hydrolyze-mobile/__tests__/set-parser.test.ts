import { parseSet, buildIntensityPattern, summarisePattern, INTENSITY_MULTIPLIERS } from '../lib/set-parser'
import type { IntensityLevel } from '../lib/set-parser'

// ─── Core parsing ─────────────────────────────────────────────────────────────

describe('parseSet — reps and distance', () => {
  test('NxM format', () => {
    const r = parseSet('4x50')
    expect(r.reps).toBe(4)
    expect(r.distance).toBe(50)
  })

  test('N × M with spaces', () => {
    const r = parseSet('3 x 100')
    expect(r.reps).toBe(3)
    expect(r.distance).toBe(100)
  })

  test('spoken "by"', () => {
    const r = parseSet('6 by 25')
    expect(r.reps).toBe(6)
    expect(r.distance).toBe(25)
  })

  test('word numbers', () => {
    const r = parseSet('four x 50')
    expect(r.reps).toBe(4)
    expect(r.distance).toBe(50)
  })
})

describe('parseSet — stroke', () => {
  test('detects free', () => expect(parseSet('4x50 free').stroke).toBe('Free'))
  test('detects freestyle', () => expect(parseSet('4x50 freestyle').stroke).toBe('Free'))
  test('detects back', () => expect(parseSet('3x100 back').stroke).toBe('Back'))
  test('detects butterfly', () => expect(parseSet('6x25 butterfly').stroke).toBe('Fly'))
  test('detects fly', () => expect(parseSet('6x25 fly').stroke).toBe('Fly'))
  test('detects IM', () => expect(parseSet('2x200 IM').stroke).toBe('IM'))
  test('null when not specified', () => expect(parseSet('4x50').stroke).toBeNull())
})

describe('parseSet — interval', () => {
  test('@mm:ss format', () => {
    expect(parseSet('4x50 @1:30').interval).toBe('1:30')
  })
  test('on mm:ss', () => {
    expect(parseSet('4x50 on 1:30').interval).toBe('1:30')
  })
  test('on N minutes', () => {
    expect(parseSet('4x50 on 2 minutes').interval).toBe('2:00')
  })
  test('null when not specified', () => {
    expect(parseSet('4x50').interval).toBeNull()
  })
})

// ─── Intensity type parsing ───────────────────────────────────────────────────

describe('parseSet — single intensity type', () => {
  test('easy', () => expect(parseSet('4x50 easy').intensity?.type).toBe('easy'))
  test('sprint/fast', () => expect(parseSet('4x50 fast').intensity?.type).toBe('sprint'))
  test('race pace', () => expect(parseSet('4x50 race pace').intensity?.type).toBe('race_pace'))
  test('descend', () => expect(parseSet('3x100 desc').intensity?.type).toBe('descend'))
  test('threshold', () => expect(parseSet('4x50 threshold').intensity?.type).toBe('threshold'))
  test('null when unspecified', () => expect(parseSet('4x50').intensity).toBeNull())
})

// ─── Per-rep intensity patterns ───────────────────────────────────────────────

describe('parseSet — intensityPattern', () => {
  test('all-same single intensity fills pattern', () => {
    const r = parseSet('4x50 easy @60')
    expect(r.intensityPattern).toEqual(['easy', 'easy', 'easy', 'easy'])
  })

  test('desc fills gradient across reps', () => {
    const r = parseSet('3x100 desc @1:30')
    expect(r.intensityPattern).toHaveLength(3)
    // First rep easier than last
    const levels: IntensityLevel[] = ['easy', 'moderate', 'hard', 'race']
    const first = levels.indexOf(r.intensityPattern[0])
    const last  = levels.indexOf(r.intensityPattern[2])
    expect(first).toBeLessThan(last)
  })

  test('"1 easy 1 fast" alternating pattern for 4 reps', () => {
    const r = parseSet('4x50 1 easy 1 fast @60')
    expect(r.intensityPattern).toEqual(['easy', 'hard', 'easy', 'hard'])
  })

  test('"1 easy 1 fast" for 6 reps — cycles correctly', () => {
    const r = parseSet('6x50 1 easy 1 fast @60')
    expect(r.intensityPattern).toEqual(['easy', 'hard', 'easy', 'hard', 'easy', 'hard'])
  })

  test('"2 mod 1 race" pattern for 6 reps', () => {
    const r = parseSet('6x50 2 mod 1 race @60')
    expect(r.intensityPattern).toEqual(['moderate', 'moderate', 'race', 'moderate', 'moderate', 'race'])
  })

  test('no intensity → defaults to moderate', () => {
    const r = parseSet('4x50 @60')
    expect(r.intensityPattern).toEqual(['moderate', 'moderate', 'moderate', 'moderate'])
  })

  test('empty pattern when reps unknown', () => {
    const r = parseSet('50m free')
    expect(r.intensityPattern).toEqual([])
  })

  test('race intensity fills all reps at race level', () => {
    const r = parseSet('6x25 fly race @45')
    expect(r.intensityPattern).toHaveLength(6)
    expect(r.intensityPattern.every(l => l === 'race')).toBe(true)
  })
})

// ─── buildIntensityPattern ────────────────────────────────────────────────────

describe('buildIntensityPattern', () => {
  test('repBlock overrides intensity — cycles to fill reps', () => {
    const result = buildIntensityPattern(4, null, ['easy', 'hard'])
    expect(result).toEqual(['easy', 'hard', 'easy', 'hard'])
  })

  test('no intensity, no block → all moderate', () => {
    expect(buildIntensityPattern(3, null, null)).toEqual(['moderate', 'moderate', 'moderate'])
  })

  test('descend type → gradient', () => {
    const result = buildIntensityPattern(4, { type: 'descend', paceDistance: null, label: 'descend' }, null)
    const levels: IntensityLevel[] = ['easy', 'moderate', 'hard', 'race']
    const indices = result.map(l => levels.indexOf(l))
    // Must be non-decreasing (gradient from easy to race)
    for (let i = 1; i < indices.length; i++) {
      expect(indices[i]).toBeGreaterThanOrEqual(indices[i - 1])
    }
  })

  test('negative_split → first half moderate, second half hard', () => {
    const result = buildIntensityPattern(4, { type: 'negative_split', paceDistance: null, label: 'neg split' }, null)
    expect(result[0]).toBe('moderate')
    expect(result[3]).toBe('hard')
  })
})

// ─── summarisePattern ─────────────────────────────────────────────────────────

describe('summarisePattern', () => {
  test('all same → single label', () => {
    expect(summarisePattern(['easy', 'easy', 'easy'])).toBe('easy')
  })
  test('alternating → cycle notation', () => {
    expect(summarisePattern(['easy', 'hard', 'easy', 'hard'])).toBe('easy / hard')
  })
  test('gradient → "desc"', () => {
    const desc = ['easy', 'moderate', 'hard', 'race'] as IntensityLevel[]
    expect(summarisePattern(desc)).toBe('desc')
  })
  test('empty → empty string', () => {
    expect(summarisePattern([])).toBe('')
  })
})

// ─── INTENSITY_MULTIPLIERS ────────────────────────────────────────────────────

describe('INTENSITY_MULTIPLIERS', () => {
  test('easy > moderate > hard > race (slower → faster)', () => {
    expect(INTENSITY_MULTIPLIERS.easy).toBeGreaterThan(INTENSITY_MULTIPLIERS.moderate)
    expect(INTENSITY_MULTIPLIERS.moderate).toBeGreaterThan(INTENSITY_MULTIPLIERS.hard)
    expect(INTENSITY_MULTIPLIERS.hard).toBeGreaterThan(INTENSITY_MULTIPLIERS.race)
    expect(INTENSITY_MULTIPLIERS.race).toBe(1.00)
  })
})

// ─── Full sentence examples from coaching context ─────────────────────────────

describe('parseSet — real coaching phrases', () => {
  test('3x100 desc 1-3 @1:30', () => {
    const r = parseSet('3x100 desc 1-3 @1:30')
    expect(r.reps).toBe(3)
    expect(r.distance).toBe(100)
    expect(r.intensity?.type).toBe('descend')
    expect(r.interval).toBe('1:30')
    expect(r.intensityPattern).toHaveLength(3)
  })

  test('4x50 1 easy 1 fast @60', () => {
    const r = parseSet('4x50 1 easy 1 fast @60')
    expect(r.reps).toBe(4)
    expect(r.distance).toBe(50)
    expect(r.intensityPattern).toEqual(['easy', 'hard', 'easy', 'hard'])
  })

  test('6x25 fly race @45', () => {
    const r = parseSet('6x25 fly race @45')
    expect(r.reps).toBe(6)
    expect(r.distance).toBe(25)
    expect(r.stroke).toBe('Fly')
    expect(r.intensityPattern.every(l => l === 'race')).toBe(true)
  })
})
