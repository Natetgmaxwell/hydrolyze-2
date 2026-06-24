import {
  parseWorkout,
  parseGear,
  gearPenalty,
  GEAR_PENALTIES,
  isWorkoutReady,
  parsedCount,
  totalReps,
  formatWorkout,
  statsCacheKey,
  effectiveMean,
} from '../lib/workout-parser'
import type { IntensityLevel } from '../lib/set-parser'

// ─── parseGear ────────────────────────────────────────────────────────────────

describe('parseGear', () => {
  test('fins', () => expect(parseGear('4x50 kick fins')).toBe('fins'))
  test('flippers (plural)', () => expect(parseGear('2x25 flippers')).toBe('fins'))
  test('paddles', () => expect(parseGear('4x100 paddles')).toBe('paddles'))
  test('paddle (singular)', () => expect(parseGear('4x100 paddle')).toBe('paddles'))
  test('pull buoy', () => expect(parseGear('3x100 pull buoy')).toBe('pull_buoy'))
  test('pull-buoy (hyphen)', () => expect(parseGear('3x100 pull-buoy')).toBe('pull_buoy'))
  test('kickboard', () => expect(parseGear('8x50 kickboard')).toBe('kickboard'))
  test('kick board (two words)', () => expect(parseGear('8x50 kick board')).toBe('kickboard'))
  test('board alone', () => expect(parseGear('8x50 board')).toBe('kickboard'))
  test('drag suit', () => expect(parseGear('4x50 drag suit')).toBe('dragSuit'))
  test('no gear → null', () => expect(parseGear('4x50 free')).toBe(null))
  test('case insensitive', () => expect(parseGear('4x50 FINS')).toBe('fins'))
})

// ─── gearPenalty + GEAR_PENALTIES ───────────────────────────────────────────

describe('gearPenalty', () => {
  test('null → 1.0 (no adjustment)', () => {
    expect(gearPenalty(null)).toBe(1.0)
  })
  test('fins → 0.88 (faster)', () => {
    expect(gearPenalty('fins')).toBe(GEAR_PENALTIES.fins)
  })
  test('paddles → 1.12 (slower)', () => {
    expect(gearPenalty('paddles')).toBe(GEAR_PENALTIES.paddles)
  })
  test('pull_buoy → 1.08', () => {
    expect(gearPenalty('pull_buoy')).toBe(GEAR_PENALTIES.pull_buoy)
  })
  test('kickboard → 1.05', () => {
    expect(gearPenalty('kickboard')).toBe(GEAR_PENALTIES.kickboard)
  })
  test('dragSuit → 1.18', () => {
    expect(gearPenalty('dragSuit')).toBe(GEAR_PENALTIES.dragSuit)
  })
})

// ─── parseWorkout — single set ───────────────────────────────────────────────

describe('parseWorkout — single set', () => {
  test('single set parses completely', () => {
    const result = parseWorkout('4x50 free @1:00')
    expect(result).toHaveLength(1)
    expect(result[0].parsed).toBe(true)
    expect(result[0].set?.reps).toBe(4)
    expect(result[0].set?.distance).toBe(50)
    expect(result[0].set?.stroke).toBe('Free')
    expect(result[0].gear).toBe(null)
  })

  test('single set with gear', () => {
    const result = parseWorkout('4x50 kick fins')
    expect(result).toHaveLength(1)
    expect(result[0].parsed).toBe(true)
    expect(result[0].gear).toBe('fins')
  })
})

// ─── parseWorkout — multi-set comma-separated ───────────────────────────────

describe('parseWorkout — multi-set', () => {
  test('two sets separated by comma', () => {
    const result = parseWorkout('4x100 free, 2x50 kick fins')
    expect(result).toHaveLength(2)

    expect(result[0].index).toBe(0)
    expect(result[0].parsed).toBe(true)
    expect(result[0].set?.reps).toBe(4)
    expect(result[0].set?.distance).toBe(100)
    expect(result[0].gear).toBe(null)

    expect(result[1].index).toBe(1)
    expect(result[1].parsed).toBe(true)
    expect(result[1].set?.reps).toBe(2)
    expect(result[1].set?.distance).toBe(50)
    expect(result[1].gear).toBe('fins')
  })

  test('three sets with mixed gear', () => {
    const result = parseWorkout('4x100 free @1:30, 4x50 kick fins @1:00, 200 easy')
    expect(result).toHaveLength(3)
    expect(result[0].gear).toBe(null)
    expect(result[1].gear).toBe('fins')
    expect(result[2].gear).toBe(null)
  })

  test('trailing comma → ignored', () => {
    const result = parseWorkout('4x50 free,')
    expect(result).toHaveLength(1)
  })

  test('empty input → empty array', () => {
    expect(parseWorkout('')).toEqual([])
  })

  test('whitespace only → empty array', () => {
    expect(parseWorkout('   ')).toEqual([])
  })
})

// ─── parseWorkout — partial parse success ─────────────────────────────────────

describe('parseWorkout — partial parse (unparseable text)', () => {
  test('first set parses, second does not → both returned', () => {
    const result = parseWorkout('4x50 free, some weird instruction')
    expect(result).toHaveLength(2)

    expect(result[0].parsed).toBe(true)
    expect(result[0].set?.reps).toBe(4)

    expect(result[1].parsed).toBe(false)
    expect(result[1].set).not.toBe(null)  // parseSet always returns an object
    expect(result[1].set?.reps).toBeNull() // null reps/distance = unparseable
    expect(result[1].rawText).toBe('some weird instruction')
  })

  test('completely unparseable line → parsed=false, set has null fields', () => {
    const result = parseWorkout('warm up first')
    expect(result).toHaveLength(1)
    expect(result[0].parsed).toBe(false)
    expect(result[0].set).not.toBe(null)        // parseSet always returns an object
    expect(result[0].set?.reps).toBeNull()      // no reps extracted
    expect(result[0].set?.distance).toBeNull()  // no distance extracted
    expect(result[0].rawText).toBe('warm up first')
  })
})

// ─── parseWorkout — effectiveDistance (pace target resolution) ─────────────

describe('parseWorkout — effectiveDistance', () => {
  test('normal set → effectiveDistance = set.distance', () => {
    const result = parseWorkout('4x50 free')
    expect(result[0].effectiveDistance).toBe(50)
  })

  test('set with pace target → effectiveDistance = paceDistance', () => {
    const result = parseWorkout('4x100 free at 200 pace')
    expect(result[0].effectiveDistance).toBe(200)
    expect(result[0].set?.intensity?.type).toBe('pace_target')
    expect(result[0].set?.intensity?.paceDistance).toBe(200)
  })

  test('two sets: one with pace target, one without', () => {
    const result = parseWorkout('4x100 free at 200 pace, 4x50 kick fins')
    expect(result[0].effectiveDistance).toBe(200)
    expect(result[1].effectiveDistance).toBe(50)
  })

  test('unparsed set → effectiveDistance = null', () => {
    const result = parseWorkout('4x50 free, warm up')
    expect(result[0].effectiveDistance).toBe(50)
    expect(result[1].effectiveDistance).toBe(null)
  })
})

// ─── statsCacheKey ───────────────────────────────────────────────────────────

describe('statsCacheKey', () => {
  test('full 5-dimension key', () => {
    const key = statsCacheKey('swim-abc', 'Free', 100, 'hard', 'paddles')
    expect(key).toBe('swim-abc:Free:100:hard:paddles')
  })

  test('no gear → uses "none"', () => {
    const key = statsCacheKey('swim-abc', 'Free', 100, 'hard', null)
    expect(key).toBe('swim-abc:Free:100:hard:none')
  })

  test('different swimmers get different keys', () => {
    const alice = statsCacheKey('alice-id', 'Free', 50, 'moderate', null)
    const bob   = statsCacheKey('bob-id',   'Free', 50, 'moderate', null)
    expect(alice).not.toBe(bob)
  })

  test('different distances get different keys', () => {
    const k50 = statsCacheKey('swim-abc', 'Free', 50, 'race', null)
    const k100 = statsCacheKey('swim-abc', 'Free', 100, 'race', null)
    expect(k50).not.toBe(k100)
  })

  test('different intensities get different keys', () => {
    const kEasy = statsCacheKey('swim-abc', 'Free', 50, 'easy', null)
    const kRace = statsCacheKey('swim-abc', 'Free', 50, 'race', null)
    expect(kEasy).not.toBe(kRace)
  })

  test('different gears get different keys', () => {
    const kNoGear = statsCacheKey('swim-abc', 'Free', 50, 'moderate', null)
    const kFins   = statsCacheKey('swim-abc', 'Free', 50, 'moderate', 'fins')
    expect(kNoGear).not.toBe(kFins)
  })
})

// ─── effectiveMean ───────────────────────────────────────────────────────────

describe('effectiveMean', () => {
  test('no gear, no intensity override → moderate (1.1×) applied as default', () => {
    const stats = { mean_time_ms: 60000, stddev_time_ms: 1000, sample_count: 10,
      is_estimated: false, assignmentSource: 'recorded' }
    // undefined → defaults to 'moderate' (1.10)
    expect(effectiveMean(stats, undefined, null)).toBe(66000)
  })

  test('fins (gearMult=0.88) + moderate intensity (1.1×) → 60000*1.1*0.88', () => {
    const stats = { mean_time_ms: 60000, stddev_time_ms: 1000, sample_count: 10,
      is_estimated: false, assignmentSource: 'recorded' }
    // 60000 * 1.10 (moderate default) * 0.88 (fins) = 58080
    expect(effectiveMean(stats, undefined, 'fins')).toBeCloseTo(58080, 0)
  })

  test('paddles (gearMult=1.12) + moderate intensity (1.1×) → 60000*1.1*1.12', () => {
    const stats = { mean_time_ms: 60000, stddev_time_ms: 1000, sample_count: 10,
      is_estimated: false, assignmentSource: 'recorded' }
    // 60000 * 1.10 * 1.12 = 73920
    expect(effectiveMean(stats, undefined, 'paddles')).toBeCloseTo(73920, 0)
  })

  test('easy intensity (1.25×) slows the base mean', () => {
    const stats = { mean_time_ms: 60000, stddev_time_ms: 1000, sample_count: 10,
      is_estimated: false, assignmentSource: 'recorded' }
    // 60000 * 1.25 (easy) * 1.0 (no gear) = 75000
    expect(effectiveMean(stats, 'easy', null)).toBe(75000)
  })

  test('race intensity (1.0×) leaves base unchanged when explicit', () => {
    const stats = { mean_time_ms: 60000, stddev_time_ms: 1000, sample_count: 10,
      is_estimated: false, assignmentSource: 'recorded' }
    expect(effectiveMean(stats, 'race', null)).toBe(60000)
  })

  test('both intensity and gear combined', () => {
    const stats = { mean_time_ms: 60000, stddev_time_ms: 1000, sample_count: 10,
      is_estimated: false, assignmentSource: 'recorded' }
    // 60000 * 1.10 (moderate) * 0.88 (fins) = 58080
    expect(effectiveMean(stats, 'moderate', 'fins')).toBeCloseTo(58080, 0)
  })

  test('pb_predicted_ms used as base when available', () => {
    const stats = { mean_time_ms: 50000, stddev_time_ms: 1000, sample_count: 3,
      is_estimated: true, assignmentSource: 'pb_interpolated',
      pb_predicted_ms: 58000 }  // curve says 58000 at this distance
    // base = 58000 (not 50000 which is historical average)
    // 58000 * 1.0 (race) * 1.12 (paddles) = 64960
    expect(effectiveMean(stats, 'race', 'paddles')).toBeCloseTo(64960, 0)
  })

  test('per-swimmer intensity multiplier overrides global', () => {
    const stats = {
      mean_time_ms: 60000, stddev_time_ms: 1000, sample_count: 10,
      is_estimated: false, assignmentSource: 'recorded',
      intensityMultipliers: { easy: 1.35, moderate: 1.05 } as Partial<Record<IntensityLevel, number>>,
    }
    // Per-swimmer easy=1.35 (vs global 1.25)
    // 60000 * 1.35 * 1.0 = 81000
    expect(effectiveMean(stats, 'easy', null)).toBe(81000)
  })

  test('per-swimmer intensity multiplier only applies for that level', () => {
    const stats = {
      mean_time_ms: 60000, stddev_time_ms: 1000, sample_count: 10,
      is_estimated: false, assignmentSource: 'recorded',
      intensityMultipliers: { easy: 1.35 } as Partial<Record<IntensityLevel, number>>,
    }
    // 'moderate' not in overrides → use global (1.10)
    expect(effectiveMean(stats, 'moderate', null)).toBe(66000)
  })
})

// ─── Helper functions ────────────────────────────────────────────────────────

describe('isWorkoutReady', () => {
  test('all sets parsed → true', () => {
    const result = parseWorkout('4x50 free, 2x25 kick fins')
    expect(isWorkoutReady(result)).toBe(true)
  })

  test('some sets unparsed → false', () => {
    const result = parseWorkout('4x50 free, warm up first')
    expect(isWorkoutReady(result)).toBe(false)
  })

  test('empty workout → false', () => {
    expect(isWorkoutReady([])).toBe(false)
  })
})

describe('parsedCount', () => {
  test('counts parsed sets', () => {
    const result = parseWorkout('4x50 free, some junk, 2x25 kick')
    expect(parsedCount(result)).toBe(2)
  })

  test('all parsed → count = length', () => {
    const result = parseWorkout('4x50 free, 2x25 kick')
    expect(parsedCount(result)).toBe(2)
  })
})

describe('totalReps', () => {
  test('sums reps from all parsed sets', () => {
    const result = parseWorkout('4x50 free, 2x25 kick')
    expect(totalReps(result)).toBe(6)
  })

  test('unparsed sets contribute 0 reps', () => {
    const result = parseWorkout('warm up, 4x50 free')
    expect(totalReps(result)).toBe(4)
  })

  test('empty → 0', () => {
    expect(totalReps([])).toBe(0)
  })
})

describe('formatWorkout', () => {
  test('formatted labels for parsed sets', () => {
    const result = parseWorkout('4x50 free, 2x25 kick fins')
    const labels = formatWorkout(result)
    expect(labels).toHaveLength(2)
    expect(labels[0]).toContain('4×50m')
    expect(labels[0]).toContain('Free')
    expect(labels[1]).toContain('2×25m')
    expect(labels[1]).toContain('fins')
  })

  test('unparsed text shows raw input', () => {
    const result = parseWorkout('warm up first, 4x50 free')
    const labels = formatWorkout(result)
    expect(labels[0]).toBe('warm up first')
    expect(labels[1]).toContain('4×50m')
  })
})

// ─── Real coaching workout examples ─────────────────────────────────────────

describe('parseWorkout — real coaching phrases', () => {
  test('"4x100 free @1:30, 4x50 kick fins @1:00, 200 easy"', () => {
    const result = parseWorkout('4x100 free @1:30, 4x50 kick fins @1:00, 200 easy')
    expect(result).toHaveLength(3)
    expect(result[0].gear).toBe(null)
    expect(result[1].gear).toBe('fins')
    expect(result[2].gear).toBe(null)
    expect(result[0].set?.interval).toBe('1:30')
    expect(result[1].set?.interval).toBe('1:00')
  })

  test('"3x100 on 1:30, 2x50 1 easy 1 fast @45, 100 easy"', () => {
    const result = parseWorkout('3x100 on 1:30, 2x50 1 easy 1 fast @45, 100 easy')
    expect(result).toHaveLength(3)
    // Second set has alternating pattern
    expect(result[1].set?.intensityPattern).toEqual(['easy', 'hard'])
  })

  test('"4x100 at 200 pace free, 4x50 easy"' , () => {
    const result = parseWorkout('4x100 at 200 pace free, 4x50 easy')
    expect(result[0].effectiveDistance).toBe(200)
    expect(result[0].set?.intensity?.type).toBe('pace_target')
    expect(result[1].effectiveDistance).toBe(50)
  })

  test('"8x25 fly sprint @30"' , () => {
    const result = parseWorkout('8x25 fly sprint @30')
    expect(result).toHaveLength(1)
    expect(result[0].set?.stroke).toBe('Fly')
    expect(result[0].set?.intensity?.type).toBe('sprint')
    expect(result[0].gear).toBe(null)
  })
})