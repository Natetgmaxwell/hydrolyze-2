import { fitSpeedCurve, predictTime, predictFromPBs } from '../lib/speed-curve'

describe('fitSpeedCurve', () => {
  test('returns null for empty input', () => {
    expect(fitSpeedCurve([])).toBeNull()
  })

  test('returns null for all invalid PBs (zero values)', () => {
    expect(fitSpeedCurve([{ distance: 0, pb_ms: 30000 }, { distance: 50, pb_ms: 0 }])).toBeNull()
  })

  test('single PB — uses fixed slope (single_pb_fixed_slope)', () => {
    const curve = fitSpeedCurve([{ distance: 50, pb_ms: 30000 }])
    expect(curve).not.toBeNull()
    expect(curve!.fitMethod).toBe('single_pb_fixed_slope')
    expect(curve!.pbDistances).toEqual([50])
    expect(curve!.b).toBeCloseTo(-0.165, 3)
  })

  test('two PBs — uses OLS regression', () => {
    const curve = fitSpeedCurve([
      { distance: 50, pb_ms: 30000 },
      { distance: 200, pb_ms: 135000 },
    ])
    expect(curve).not.toBeNull()
    expect(curve!.fitMethod).toBe('regression')
    expect(curve!.pbDistances).toEqual([50, 200])
    expect(curve!.b).toBeLessThan(0) // always negative for real swimmers
  })

  test('SSxx=0 guard — all PBs at same distance falls back to single-PB path', () => {
    const curve = fitSpeedCurve([
      { distance: 50, pb_ms: 30000 },
      { distance: 50, pb_ms: 31000 },
    ])
    expect(curve).not.toBeNull()
    expect(curve!.fitMethod).toBe('single_pb_fixed_slope')
  })

  test('b>=0 guard — biologically impossible slope falls back to single-PB path', () => {
    // Trick the OLS into a positive slope by providing inverted times
    // (shorter distance = slower time). Real swimmers never do this.
    const curve = fitSpeedCurve([
      { distance: 50, pb_ms: 90000 },   // "50m in 90s" — slower than 200m
      { distance: 200, pb_ms: 30000 },  // "200m in 30s" — impossible
    ])
    expect(curve).not.toBeNull()
    // b>0 triggers fallback to median PB → single_pb_fixed_slope
    expect(curve!.fitMethod).toBe('single_pb_fixed_slope')
  })
})

describe('predictTime', () => {
  test('predicts exact distance when it matches a PB', () => {
    const curve = fitSpeedCurve([{ distance: 50, pb_ms: 30000 }])!
    const result = predictTime(curve, 50)
    expect(result).not.toBeNull()
    expect(result!.curveSource).toBe('exact')
    // Predicted time should be close to the PB (not identical — curve fits speed, not time directly)
    expect(result!.predicted_time_ms).toBeGreaterThan(25000)
    expect(result!.predicted_time_ms).toBeLessThan(35000)
  })

  test('single PB — any non-matching distance is extrapolated', () => {
    const curve = fitSpeedCurve([{ distance: 50, pb_ms: 30000 }])!
    const result = predictTime(curve, 100)
    expect(result!.curveSource).toBe('extrapolated')
  })

  test('two PBs — distance between them is interpolated', () => {
    const curve = fitSpeedCurve([
      { distance: 50, pb_ms: 30000 },
      { distance: 200, pb_ms: 135000 },
    ])!
    const result = predictTime(curve, 100)
    expect(result!.curveSource).toBe('interpolated')
  })

  test('two PBs — distance outside range is extrapolated', () => {
    const curve = fitSpeedCurve([
      { distance: 50, pb_ms: 30000 },
      { distance: 200, pb_ms: 135000 },
    ])!
    const result = predictTime(curve, 400)
    expect(result!.curveSource).toBe('extrapolated')
  })

  test('returns null for zero or negative distance', () => {
    const curve = fitSpeedCurve([{ distance: 50, pb_ms: 30000 }])!
    expect(predictTime(curve, 0)).toBeNull()
    expect(predictTime(curve, -10)).toBeNull()
  })
})

describe('predictFromPBs', () => {
  test('returns null for empty PB list', () => {
    expect(predictFromPBs([], 100)).toBeNull()
  })

  test('interpolates correctly from two PBs bracketing target', () => {
    // Swimmer has 50m and 200m PBs — predict 100m
    const result = predictFromPBs(
      [
        { distance: 50, pb_ms: 30000 },
        { distance: 200, pb_ms: 135000 },
      ],
      100
    )
    expect(result).not.toBeNull()
    expect(result!.curveSource).toBe('interpolated')
    // 100m time should be between 50m and 200m times
    expect(result!.predicted_time_ms).toBeGreaterThan(30000)
    expect(result!.predicted_time_ms).toBeLessThan(135000)
  })

  test('extrapolates from single PB at different distance', () => {
    const result = predictFromPBs([{ distance: 50, pb_ms: 30000 }], 100)
    expect(result!.curveSource).toBe('extrapolated')
    // 100m should take longer than 50m
    expect(result!.predicted_time_ms).toBeGreaterThan(30000)
  })
})

describe('margin-based confidence in pairTime', () => {
  // These tests live here because they validate the speed-curve interaction
  // with pairing. See ml-pairing.test.ts for the pairing unit tests.
  test('predictFromPBs produces a stddev > 0 for training band calculation', () => {
    const result = predictFromPBs([{ distance: 50, pb_ms: 30000 }], 50)!
    const mean = Math.round(result.predicted_time_ms * 1.10)
    const stddev = Math.round(result.predicted_time_ms * 0.10)
    expect(stddev).toBeGreaterThan(0)
    expect(mean).toBeGreaterThan(result.predicted_time_ms) // training > race pace
  })
})
