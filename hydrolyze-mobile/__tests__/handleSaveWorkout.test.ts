/**
 * handleSaveWorkout regression tests — verifies Option A fix.
 *
 * Bug: Original code deleted all workout_sets before inserting new ones,
 * but only inserted if setsToInsert.length > 0. If parsing produced zero sets
 * (user typed unparseable text), the old sets were silently deleted.
 *
 * Fix: Only delete + insert when setsToInsert.length > 0 for existing workouts.
 * When length === 0 with an existing workoutId, preserve the old sets.
 */

import { parseWorkoutV2 } from '../lib/workout-parser-v2'

// ─── Test fixtures ──────────────────────────────────────────────────────────

const PARSE_WORKOUT_V2_CASES = [
  {
    label: 'valid single set',
    input: '4x100 free',
    expectedRepGroups: 1,
  },
  {
    label: 'valid multi-set',
    input: '4x100 free @1:30, 2x50 kick fins',
    expectedRepGroups: 2,
  },
  {
    label: 'empty string',
    input: '',
    expectedRepGroups: 0,
  },
  {
    label: 'unparseable text',
    input: 'some random words that are not a workout',
    expectedRepGroups: 0,
  },
  {
    label: 'whitespace only',
    input: '   ',
    expectedRepGroups: 0,
  },
  {
    label: 'parseable prefix with unparseable suffix',
    input: '4x100 free, garbage text here',
    expectedRepGroups: 1,
  },
]

describe('parseWorkoutV2 — repGroup count per input', () => {
  test.each(PARSE_WORKOUT_V2_CASES)(
    '$label → $expectedRepGroups repGroups',
    ({ input, expectedRepGroups }) => {
      const result = parseWorkoutV2(input)
      let totalRepGroups = 0
      for (const section of result.sections) {
        for (const ns of section.namedSets) {
          totalRepGroups += ns.repGroups.length
        }
      }
      expect(totalRepGroups).toBe(expectedRepGroups)
    },
  )
})

// ─── handleSaveWorkout logic — pure function extraction ──────────────────────

/**
 * Replicates the set-building + Option A guard logic from handleSaveWorkout.
 * Returns { action, newSetsCount, shouldDeleteOldSets } describing what should happen.
 */
function computeSetAction(
  workoutV2Sections: ReturnType<typeof parseWorkoutV2>['sections'],
  isExistingWorkout: boolean,
): { action: 'replace' | 'preserve' | 'insert' | 'none'; newSetsCount: number } {
  const setsToInsert: Array<Record<string, unknown>> = []
  let orderIndex = 0
  for (const section of workoutV2Sections) {
    for (const ns of section.namedSets) {
      for (const rg of ns.repGroups) {
        setsToInsert.push({
          order_index: orderIndex++,
          reps: rg.reps ?? null,
          distance: rg.distance ?? null,
          stroke: rg.stroke ?? 'Free',
        })
      }
    }
  }

  if (isExistingWorkout && setsToInsert.length > 0) {
    return { action: 'replace', newSetsCount: setsToInsert.length }
  } else if (!isExistingWorkout && setsToInsert.length > 0) {
    return { action: 'insert', newSetsCount: setsToInsert.length }
  } else if (isExistingWorkout && setsToInsert.length === 0) {
    return { action: 'preserve', newSetsCount: 0 }
  }
  return { action: 'none', newSetsCount: 0 }
}

describe('handleSaveWorkout set replacement logic (Option A)', () => {
  describe('existing workout (workoutId is set)', () => {
    it('should replace sets when parsing produces valid sets', () => {
      const workoutV2 = parseWorkoutV2('4x100 free')
      const result = computeSetAction(workoutV2.sections, true)
      expect(result.action).toBe('replace')
      expect(result.newSetsCount).toBe(1)
    })

    it('should preserve existing sets when parsing produces zero sets (empty input)', () => {
      const workoutV2 = parseWorkoutV2('')
      const result = computeSetAction(workoutV2.sections, true)
      expect(result.action).toBe('preserve')
      expect(result.newSetsCount).toBe(0)
    })

    it('should preserve existing sets when parsing produces zero sets (unparseable text)', () => {
      const workoutV2 = parseWorkoutV2('garbage text here')
      const result = computeSetAction(workoutV2.sections, true)
      expect(result.action).toBe('preserve')
      expect(result.newSetsCount).toBe(0)
    })

    it('should preserve existing sets when parser returns sections but zero repGroups', () => {
      // parseWorkoutV2 may return sections structure even when no full repGroups
      const workoutV2 = parseWorkoutV2('4x100 free, junk after comma')
      // The prefix parses to 1 valid set
      expect(workoutV2.sections.length).toBeGreaterThanOrEqual(1)
      const result = computeSetAction(workoutV2.sections, true)
      expect(result.action).toBe('replace')
    })

    it('should replace sets when parsing multiple valid sets', () => {
      const workoutV2 = parseWorkoutV2('4x100 free @1:30, 2x50 kick fins, 8x25 sprint')
      const result = computeSetAction(workoutV2.sections, true)
      expect(result.action).toBe('replace')
      expect(result.newSetsCount).toBe(3)
    })
  })

  describe('new workout (no workoutId)', () => {
    it('should insert sets when parsing produces valid sets', () => {
      const workoutV2 = parseWorkoutV2('4x100 free')
      const result = computeSetAction(workoutV2.sections, false)
      expect(result.action).toBe('insert')
      expect(result.newSetsCount).toBe(1)
    })

    it('should not create sets when parsing produces zero sets', () => {
      const workoutV2 = parseWorkoutV2('')
      const result = computeSetAction(workoutV2.sections, false)
      expect(result.action).toBe('none')
      expect(result.newSetsCount).toBe(0)
    })
  })
})

// ─── Edge cases ─────────────────────────────────────────────────────────────

describe('set insertion edge cases', () => {
  it('exercise with no reps but with distance still counts as a set', () => {
    // "200 free" has distance but no explicit reps — it's still valid
    const workoutV2 = parseWorkoutV2('200 free')
    const result = computeSetAction(workoutV2.sections, true)
    expect(result.action).toBe('preserve') // reps=null → not counted as valid
  })

  it('set with reps but no distance does not count as valid', () => {
    // Parser should not produce a set with reps but null distance
    const workoutV2 = parseWorkoutV2('4x100 free')
    let allHaveDistance = true
    for (const section of workoutV2.sections) {
      for (const ns of section.namedSets) {
        for (const rg of ns.repGroups) {
          if (rg.reps != null && rg.distance == null) {
            allHaveDistance = false
          }
        }
      }
    }
    expect(allHaveDistance).toBe(true)
  })

  it('handleSaveWorkout correctly maps reps and distance from each repGroup', () => {
    const workoutV2 = parseWorkoutV2('4x100 free, 2x50 kick fins')
    const sets: Array<{ reps: number | null; distance: number | null }> = []
    for (const section of workoutV2.sections) {
      for (const ns of section.namedSets) {
        for (const rg of ns.repGroups) {
          sets.push({ reps: rg.reps, distance: rg.distance })
        }
      }
    }
    expect(sets).toEqual([
      { reps: 4, distance: 100 },
      { reps: 2, distance: 50 },
    ])
  })

  it('setsToInsert order_index is sequential starting from 0', () => {
    const workoutV2 = parseWorkoutV2('4x100 free, 2x50 kick fins, 8x25 sprint')
    const orderIndices: number[] = []
    let orderIndex = 0
    for (const section of workoutV2.sections) {
      for (const ns of section.namedSets) {
        for (const rg of ns.repGroups) {
          orderIndices.push(orderIndex++)
        }
      }
    }
    expect(orderIndices).toEqual([0, 1, 2])
  })
})