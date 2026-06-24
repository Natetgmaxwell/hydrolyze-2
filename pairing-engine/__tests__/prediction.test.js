/**
 * Unit tests for the prediction pipeline.
 * Tests Layer 1/2/3 lookup, effective mean calculation, and fallback behavior.
 */
import { describe, test, expect } from 'vitest';
import { StatsStore, PBStore, GearCalibrationStore, predictSwimmer, predictPool } from '../src/prediction.js';
// ─── Data helpers ─────────────────────────────────────────────────────────────
const FREE = 'Free';
const BACK = 'Back';
const MOD = 'moderate';
const RACE = 'race';
function stats(mean, std, n = 10) {
    return { meanTimeMs: mean, stddevMs: std, sampleCount: n };
}
function pbs(...pairs) {
    return pairs.map(([d, ms]) => ({ distance: d, pbMs: ms }));
}
// ─── Layer 1: Recorded stats ───────────────────────────────────────────────────
describe('Layer 1 — Recorded stats (exact 5-way match)', () => {
    test('finds exact 5-way match: swimmerId + stroke + distance + intensity + gear', () => {
        const store = new StatsStore();
        store.set('swim:A', FREE, 50, MOD, 'paddles', stats(60000, 1000));
        const pred = predictSwimmer('swim:A', null, FREE, 50, MOD, 'paddles', store, new PBStore(), new GearCalibrationStore());
        expect(pred.statsType).toBe('recorded');
        expect(pred.meanTimeMs).toBe(60000 * 1.05); // universal paddles penalty
        expect(pred.sampleCount).toBe(10);
        expect(pred.confidenceCeiling).toBe(95);
    });
    test('falls back to bare-hand when exact gear match not found', () => {
        const store = new StatsStore();
        store.set('swim:A', FREE, 50, MOD, null, stats(60000, 1000));
        const pred = predictSwimmer('swim:A', null, FREE, 50, MOD, 'paddles', store, new PBStore(), new GearCalibrationStore());
        expect(pred.statsType).toBe('recorded');
        expect(pred.sourceLabel).toContain('bare→paddles');
        expect(pred.confidenceCeiling).toBe(95);
    });
    test('recorded stats uses per-swimmer gear calibration when available', () => {
        const store = new StatsStore();
        store.set('swim:A', FREE, 50, MOD, null, stats(60000, 1000));
        const calStore = new GearCalibrationStore();
        calStore.add({ swimmerId: 'swim:A', gear: 'paddles', adjustmentFactor: 1.10, sampleCount: 20, computedAt: '2026-04-01' });
        const pred = predictSwimmer('swim:A', null, FREE, 50, MOD, 'paddles', store, new PBStore(), calStore);
        expect(pred.statsType).toBe('recorded');
        expect(pred.gearPenalty).toBe(1.10); // personal calibration, not universal 1.05
    });
    test('recorded stats with no gear → no penalty applied', () => {
        const store = new StatsStore();
        store.set('swim:A', FREE, 50, MOD, null, stats(60000, 1000));
        const pred = predictSwimmer('swim:A', null, FREE, 50, MOD, null, store, new PBStore(), new GearCalibrationStore());
        expect(pred.statsType).toBe('recorded');
        expect(pred.gearPenalty).toBe(1.0);
        expect(pred.meanTimeMs).toBe(60000);
    });
    test('Form stroke resolves to swimmer formStroke', () => {
        const store = new StatsStore();
        store.set('swim:A', BACK, 50, MOD, null, stats(65000, 1200));
        const pred = predictSwimmer('swim:A', BACK, 'Form', 50, MOD, null, store, new PBStore(), new GearCalibrationStore());
        expect(pred.statsType).toBe('recorded');
        expect(pred.sourceLabel).toContain('Back');
    });
    test('null formStroke defaults to Free when stroke is Form', () => {
        const store = new StatsStore();
        store.set('swim:A', FREE, 50, MOD, null, stats(60000, 1000));
        const pred = predictSwimmer('swim:A', null, 'Form', 50, MOD, null, store, new PBStore(), new GearCalibrationStore());
        expect(pred.statsType).toBe('recorded');
    });
});
// ─── Layer 2: Speed curve from PBs ─────────────────────────────────────────────
describe('Layer 2 — Speed curve from PBs', () => {
    test('uses speed curve when no recorded stats exist', () => {
        const pbStore = new PBStore();
        pbStore.set('swim:A', FREE, pbs([50, 27000], [100, 60000], [200, 129000]));
        const pred = predictSwimmer('swim:A', null, FREE, 50, MOD, null, new StatsStore(), pbStore, new GearCalibrationStore());
        expect(pred.statsType).toBe('curve');
        expect(pred.sourceLabel).toContain('curve');
        expect(pred.confidenceCeiling).toBe(70);
    });
    test('curve predicts at exact PB distance → "exact" classification', () => {
        const pbStore = new PBStore();
        pbStore.set('swim:A', FREE, pbs([50, 27000], [100, 60000]));
        const pred = predictSwimmer('swim:A', null, FREE, 50, MOD, null, new StatsStore(), pbStore, new GearCalibrationStore());
        expect(pred.statsType).toBe('curve');
        expect(pred.sourceLabel).toContain('exact');
    });
    test('curve predicts at interpolated distance → "interpolated"', () => {
        const pbStore = new PBStore();
        pbStore.set('swim:A', FREE, pbs([50, 27000], [200, 129000]));
        const pred = predictSwimmer('swim:A', null, FREE, 100, MOD, null, new StatsStore(), pbStore, new GearCalibrationStore());
        expect(pred.statsType).toBe('curve');
        expect(pred.sourceLabel).toContain('interpolated');
    });
    test('curve predicts at extrapolated distance → "extrapolated"', () => {
        const pbStore = new PBStore();
        pbStore.set('swim:A', FREE, pbs([50, 27000], [100, 60000]));
        const pred = predictSwimmer('swim:A', null, FREE, 400, MOD, null, new StatsStore(), pbStore, new GearCalibrationStore());
        expect(pred.statsType).toBe('curve');
        expect(pred.sourceLabel).toContain('extrapolated');
    });
    test('speed curve applies intensity multiplier to race-pace prediction', () => {
        const pbStore = new PBStore();
        pbStore.set('swim:A', FREE, pbs([50, 27000])); // race-pace 50m free
        const modPred = predictSwimmer('swim:A', null, FREE, 50, MOD, null, new StatsStore(), pbStore, new GearCalibrationStore());
        const racePred = predictSwimmer('swim:A', null, FREE, 50, RACE, null, new StatsStore(), pbStore, new GearCalibrationStore());
        // Race pace: 27000ms * 1.0 = 27000ms
        // Moderate: 27000ms * 1.10 = 29700ms
        expect(racePred.meanTimeMs).toBeLessThan(modPred.meanTimeMs);
        expect(racePred.meanTimeMs).toBe(27000);
        expect(modPred.meanTimeMs).toBeCloseTo(29700, 0); // floating point tolerance
    });
    test('speed curve applies gear penalty to effective mean', () => {
        const pbStore = new PBStore();
        pbStore.set('swim:A', FREE, pbs([50, 27000]));
        const noGear = predictSwimmer('swim:A', null, FREE, 50, MOD, null, new StatsStore(), pbStore, new GearCalibrationStore());
        const withFins = predictSwimmer('swim:A', null, FREE, 50, MOD, 'fins', new StatsStore(), pbStore, new GearCalibrationStore());
        // Fins: penalty=0.88 → effective mean is LOWER (swimmer is faster)
        expect(withFins.meanTimeMs).toBeLessThan(noGear.meanTimeMs);
        expect(withFins.gearPenalty).toBe(0.88);
    });
    test('distance-aware stddev: 50m → 5%, 400m → 10%', () => {
        const pbStore = new PBStore();
        pbStore.set('swim:A', FREE, pbs([50, 27000], [400, 280000]));
        const pred50 = predictSwimmer('swim:A', null, FREE, 50, MOD, null, new StatsStore(), pbStore, new GearCalibrationStore());
        const pred400 = predictSwimmer('swim:A', null, FREE, 400, MOD, null, new StatsStore(), pbStore, new GearCalibrationStore());
        // stddev is stddevFraction * meanTime
        expect(pred50.stddevMs).toBeCloseTo(pred50.meanTimeMs * 0.05, -1);
        expect(pred400.stddevMs).toBeCloseTo(pred400.meanTimeMs * 0.10, -1);
    });
    test('no PBs → Layer 2 not used → falls through to Layer 3', () => {
        const pbStore = new PBStore(); // empty
        const pred = predictSwimmer('swim:A', null, FREE, 50, MOD, null, new StatsStore(), pbStore, new GearCalibrationStore());
        expect(pred.statsType).toBe('seed'); // fell through to seed
    });
});
// ─── Layer 3: Universal seed ─────────────────────────────────────────────────────
describe('Layer 3 — Universal seed (population averages)', () => {
    test('uses population speed when no recorded stats or PBs exist', () => {
        const pred = predictSwimmer('swim:A', null, FREE, 50, MOD, null, new StatsStore(), new PBStore(), new GearCalibrationStore());
        expect(pred.statsType).toBe('seed');
        expect(pred.sourceLabel).toContain('seed');
        expect(pred.confidenceCeiling).toBe(55);
    });
    test('seed mean ≈ population average for Free 50m', () => {
        const pred = predictSwimmer('swim:A', null, FREE, 50, MOD, null, new StatsStore(), new PBStore(), new GearCalibrationStore());
        // population speed for Free: 1.45 m/s → race pace = 50/1.45*1000 = 34483ms
        // moderate = 34483 * 1.10 = 37931ms
        expect(pred.meanTimeMs).toBeCloseTo(37931, -2); // within 1%
    });
    test('seed stddev uses distance-aware fraction', () => {
        const pred = predictSwimmer('swim:A', null, FREE, 400, MOD, null, new StatsStore(), new PBStore(), new GearCalibrationStore());
        // stddevFraction for 400m = 0.10
        expect(pred.stddevMs).toBeCloseTo(pred.meanTimeMs * 0.10, -1);
    });
    test('seed applies gear penalty from calibration or universal fallback', () => {
        const pred = predictSwimmer('swim:A', null, FREE, 50, MOD, 'paddles', new StatsStore(), new PBStore(), new GearCalibrationStore());
        expect(pred.statsType).toBe('seed');
        expect(pred.gearPenalty).toBe(1.05); // universal fallback
    });
});
// ─── Gear calibration store ────────────────────────────────────────────────────
describe('GearCalibrationStore', () => {
    test('returns undefined when no calibration exists', () => {
        const store = new GearCalibrationStore();
        expect(store.get('swim:A', 'paddles')).toBeUndefined();
    });
    test('stores and retrieves per-swimmer gear calibrations', () => {
        const store = new GearCalibrationStore();
        store.add({ swimmerId: 'swim:A', gear: 'paddles', adjustmentFactor: 1.12, sampleCount: 30, computedAt: '2026-04-01' });
        const cal = store.get('swim:A', 'paddles');
        expect(cal?.adjustmentFactor).toBe(1.12);
    });
    test('effectivePenalty returns per-swimmer calibration when available', () => {
        const store = new GearCalibrationStore();
        store.add({ swimmerId: 'swim:A', gear: 'fins', adjustmentFactor: 0.80, sampleCount: 25, computedAt: '2026-04-01' });
        expect(store.effectivePenalty('swim:A', 'fins')).toBe(0.80);
    });
    test('effectivePenalty falls back to universal when no calibration', () => {
        const store = new GearCalibrationStore();
        expect(store.effectivePenalty('swim:A', 'paddles')).toBe(1.05); // universal
        expect(store.effectivePenalty('swim:A', 'fins')).toBe(0.88); // universal
    });
    test('effectivePenalty returns 1.0 for null gear', () => {
        const store = new GearCalibrationStore();
        expect(store.effectivePenalty('swim:A', null)).toBe(1.0);
    });
});
// ─── Pool prediction ──────────────────────────────────────────────────────────
describe('predictPool — batch prediction for all swimmers', () => {
    test('predicts all swimmers in pool', () => {
        const store = new StatsStore();
        store.set('swim:A', FREE, 50, MOD, null, stats(28000, 300));
        store.set('swim:B', FREE, 50, MOD, null, stats(32000, 700));
        store.set('swim:C', FREE, 50, MOD, null, stats(30000, 500));
        const pool = [
            { id: 'swim:A', formStroke: null },
            { id: 'swim:B', formStroke: null },
            { id: 'swim:C', formStroke: null },
        ];
        const predictions = predictPool(pool, 50, FREE, MOD, null, store, new PBStore(), new GearCalibrationStore());
        expect(Object.keys(predictions)).toHaveLength(3);
        expect(predictions['swim:A'].meanTimeMs).toBe(28000);
        expect(predictions['swim:B'].meanTimeMs).toBe(32000);
        expect(predictions['swim:C'].meanTimeMs).toBe(30000);
    });
    test('returns seed for swimmers with no data', () => {
        const pool = [
            { id: 'swim:A', formStroke: null },
            { id: 'swim:B', formStroke: null },
        ];
        const predictions = predictPool(pool, 50, FREE, MOD, null, new StatsStore(), new PBStore(), new GearCalibrationStore());
        expect(predictions['swim:A'].statsType).toBe('seed');
        expect(predictions['swim:B'].statsType).toBe('seed');
    });
});
