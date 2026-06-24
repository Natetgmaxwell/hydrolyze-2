# Multi-Wave Pairing Hardening — Design Spec

**Chunk:** v1.16 (PairingEngine hardening for N-wave race scenarios)
**Date:** 2026-06-18
**Status:** Approved — greenlit 2026-06-18
**Source code:** `ios-native/Hydrolyze/Sources/Services/PairingEngine.swift` (280 lines, v1.10 refactor)
**Existing plan:** `plans/pairing-algorithm-design.md` (498 lines, "Approved for implementation" — the v1 design, which describes a *nearest-neighbor* heuristic that has since been superseded by the v1.10 single-Hungarian refactor). Per the 2026-06-18 decision, an addendum to that plan is written in §11 below.

---

## 1. The Question

How does the pairing engine behave when there are 3+ waves of swimmers starting at different send-off offsets (e.g., wave 0 at T=0, wave 1 at T=10s, wave 2 at T=20s, etc.)? Is the current implementation best-in-class for this scenario, or are there edge cases the existing code doesn't handle well?

## 2. Current State — The v1.10 Design

`PairingEngine.swift` (v1.10 refactor, on `main`) uses a **single global Hungarian** with the cost function in **velocity space**:

```swift
// Per-wave-relative-time cost (the multi-wave handling)
let waveRelativeTime = lap.elapsedMs - wa.sendOffOffsetMs
cost[i][j] = velocitySpaceCost(actualTimeMs: waveRelativeTime, prediction: pred)

// Velocity-space cost (V10 pattern from pairing_research/algorithms.swift)
private func velocitySpaceCost(actualTimeMs: Int, prediction: Prediction?) -> Double {
    // cost = (vel - meanVel)² / (2 * varVel)
    // where meanVel = 1 / prediction.timeMs
    //       varVel  = (sigmaMs / timeMs²)²
}
```

**Why this works for N waves:** the wave structure is *implicit* in the cost function via `waveRelativeTime = lap.elapsedMs - wa.sendOffOffsetMs`. A wave 0 lap at 25s has wave-relative=25s (compared to a ~25s prediction → low cost). A wave 1 lap at 25s has wave-relative=15s (compared to a ~25s prediction → high cost). A wave 2 lap at 25s has wave-relative=5s (compared to a ~25s prediction → very high cost). The Hungarian finds the globally optimal assignment across all N waves in one pass.

**The pivot point (v1.6 → v1.10):** the pre-v1.6 design used per-wave time windows (`[sendOffN, sendOffN + maxSwim + 5s)`) and per-wave Hungarian solves. That had a structural bug: adjacent wave windows overlap (wave 0 [0, 35s) and wave 1 [10, 47.8s) overlap in [10, 35s)), so a wave 0 lap at 28s would be claimed by both wave 0's and wave 1's Hungarian. The v1.10 refactor eliminates this by making wave structure implicit in the cost function, not enforced as hard windows.

**Verified by CLI test (PairingEngineCLITest.swift, 1069 lines):** 3 scenarios already covered — 6+2 (default two-wave), 0+8 (single wave 1), 8+0 (single wave 0). Plus ghost-tap and missed-tap sub-scenarios.

## 3. What the Web Research Confirms

| Source | Verdict |
|---|---|
| Wikipedia: Hungarian algorithm | O(n³) optimal assignment, standard since 1955. Correct tool. |
| Brilliant: Hungarian matching | "If a number is added/subtracted from all entries of a row or column, the optimal assignment is preserved." This is the *theoretical justification* for the wave-relative shift — subtracting `sendOffOffsetMs` from the lap's elapsed time is a column-shift in the cost matrix. The optimal assignment is invariant. |
| Towards Data Science: Optimum Assignment | Bipartite graph representation. The cost matrix `(swimmers × laps)` is the standard formulation. |
| M Stopwatch (Reddit recommendation) | Industry pattern: parallel stopwatches per athlete, manual lap attribution. The Hungarian approach is the *automation* of this manual workflow. |

**Verdict:** the algorithmic pattern is correct and standard. The wave-relative time is a column-shift in the cost matrix, which Hungarian handles correctly. The current V10 is well-positioned for the multi-wave case.

## 4. Multi-Wave Scaling — What Changes at N=3, N=4, N=5

| N waves | Swimmers | Cost matrix size | Hungarian ops | Wall-clock | Status |
|---|---|---|---|---|---|
| 2 | 16 (8+8) | 16×16 | 4,096 | <1ms | ✅ tested (6+2, 8+0, 0+8) |
| 3 | 24 (8+8+8) | 24×24 | 13,824 | <1ms | ❌ no test coverage |
| 4 | 32 (8×4) | 32×32 | 32,768 | <5ms | ❌ no test coverage |
| 5+ | 40+ | 40+ × 40+ | 64,000+ | ~10ms | ❌ no test coverage |

Hungarian is O(n³) but n is the total swimmers across all waves (since one global matrix). At 8 lanes × 5 waves = 40 swimmers, the matrix is 40×40 and Hungarian runs in single-digit ms. **No performance concern up to 5+ waves.**

What *does* change at N≥3:
- **Cost matrix gets denser.** With 2 waves, wave 0 taps mostly cluster around the wave 0 prediction window, wave 1 taps around wave 1's. The cost matrix has a clear "diagonal-ish" structure. With 3+ waves, the wave windows overlap more, and the Hungarian has to work harder to disambiguate.
- **Edge cases compound.** A line finish between a wave 0 and a wave 1 swimmer is one thing. A line finish between a wave 0, a wave 1, and a wave 2 swimmer (all within 100ms) is another. The Hungarian still finds an optimal assignment, but the *confidence* of each individual assignment drops.
- **The `sendOffIntervalMs` parameter is the inter-wave offset.** Currently hardcoded to 10s in the CLI test (`PairingEngineCLITest.swift:42`). For real use, the inter-wave offset comes from `WaveAssignment.sendOffOffsetMs`, which is computed by `WaveAllocator.PoolConfig` from the swim set's interval. No code change needed for N=3+ — the engine already takes per-wave `sendOffOffsetMs` from each `WaveAssignment`.

## 5. Edge Cases the Current Code Doesn't Handle Well

| Edge case | Current behavior | Risk | Recommended fix |
|---|---|---|---|
| **Line finish (N swimmers finish within 100ms)** | Hungarian picks one assignment, others go to dummy-lap or dummy-swimmer columns with high cost. Confidence drops but the *structure* of the result is correct. | Medium — coach sees multiple likelyWrong rows for a "close finish" set. Annoying but not broken. | Add a `LineFinishDetector` post-processor: if 2+ taps have predictedTimeMs within 100ms of each other AND their wave-relative times are within 200ms, flag the cluster as a "line finish" and surface it as a group, not N individual rows. v1.17 slice. |
| **False start (wave 1 tap before wave 0 reaches the wall)** | The wave-relative time is negative. Velocity-space cost is computed normally. The pairer still assigns, but the resulting confidence is near 0 and the review UI shows the variance hint prominently. | Low — the negative time is detectable, the prediction's sigma handles the spread. | Add a `minWaveRelativeMs` guard in `PairingEngine.pair()` (e.g., reject if `waveRelativeMs < -1000`). The detection is the foundation for a v1.17 "invalidate swimmer/rep" coach action — the user reframe is that mistakes are handled by coach action, not by passive flags. v1.16 Slice 2 (detection) + v1.17 Slice 3 (action). |
| **Equipment malfunction (volume button bouncing → double-tap)** | Both taps are in the cost matrix. The Hungarian picks the more likely one; the other goes to a dummy-swimmer. | Low — handled by the ghost-tap chi-square gate. | None needed. v9 already addresses this. |
| **Cold-start swimmer (no PB for the set's stroke/distance)** | Riegel interpolation falls back to cross-stroke. Population seed for the 5-way match in `PBService.fetchPrediction`. | Medium — the prediction has high `sigmaMs`, which means low confidence. The Hungarian still assigns, but the coach sees `Likely Wrong` for cold-start swimmers. | Add a `cohort_seed` boost: when ≥2 swimmers in the same wave are cold-start, use the cohort's median predicted time as the prediction. Reduces the cold-start variance. v1.18 slice. |
| **Confidences are not calibrated** | The confidence output is `max(0, 99 - Int(z * 15))` — a linear decay from a z-score. Not a real probability. | Medium — the v1.14 band's "80% confidence" doesn't mean 80% of the time the engine is correct. It's a heuristic. | Online confidence calibration: track (confidence, was-the-pairing-correct) pairs after coach review. Fit a Platt scaling or isotonic regression to map raw confidence → calibrated probability. v1.17 slice. |
| **Inter-set learning** | The prediction is based on the swimmer's PB at the time of the set. After the set is confirmed, `PBService` writes a coach-confirmed PB. But the *prediction* for the next set is still PB-based, not EMA-based. | Medium — swimmer's actual times are not feeding back into the prediction model in real-time. | Welford's online algorithm for the predicted time: track running mean + variance from confirmed pairings, use the running estimate instead of the static PB. Already noted in the `hydrolyze-product-framing` skill as a v2 goal. v1.18 slice. |
| **The CLI test only covers 2 waves** | `PairingEngineCLITest.swift` has 6+2, 0+8, 8+0. No 3+ wave coverage. | High — the test suite gives false confidence for the multi-wave case. | Add `multiWaveScenarios` to the CLI test: 4+2+2 (3-wave), 3+3+3 (3-wave symmetric), 8+0+0 (3-wave degenerate), and a 3-wave line-finish case. v1.16 slice (this spec). |

## 6. Recommended Slices (vertical, testable, each gets a commit)

### Slice 1 — Multi-wave CLI test coverage (v1.16.0)
- **Scope:** add 4 new scenarios to `PairingEngineCLITest.swift`:
  - 3-wave: 4+2+2 (asymmetric), 3+3+3 (symmetric), 8+0+0 (degenerate — wave 0 only, but with 3 wave_assignments rows)
  - 3-wave line finish: 4 swimmers in wave 0, 2 in wave 1, 2 in wave 2, all finishing within 100ms of each other (high-confidence collision)
- **Verify:** all scenarios pass the v1.9 no-ghost-taps invariant; the line-finish case flags 3+ rows as `likelyWrong` with z-scores > 3.0
- **Estimate:** ~150 lines (scenario builders + assertions)

### Slice 2 — Wave-relative time guard (v1.16.1)
- **Scope:** add a `minWaveRelativeMs = -1000` guard in `PairingEngine.pair()`. If `waveRelativeTime < -1000`, set the assignment's `confidence: 0` (the existing confidence scale). **No `LikelyFalseStart` flag** per the 2026-06-18 user reframe — the false-start *detection* stays in v1.16 (via the guard + low confidence), but no flag is surfaced. The flag concept moves to a v1.17 "invalidate swimmer/rep" coach action (Slice 3 below).
- **Verify:** CLI test with a wave 1 tap at T=8s (2s before its wave 0 swimmer's typical 25s) gets `confidence: 0`. The existing 6+2 case still passes (no false starts).
- **Estimate:** ~20 lines (1 guard + 1 CLI test case, no model changes since `confidence: 0` is the existing low-confidence signal).

### Slice 3 — "Invalidate swimmer/rep" coach action (v1.17.0)
- **Scope:** per the 2026-06-18 user reframe, false-start and other "this was a mistake" cases are handled by an active coach action, not a passive flag. Slice 3 ships: (a) the line-finish detector (≥2 taps within 200ms of each other in the same wave, group as a cluster), (b) the "invalidate this rep" coach action on the review UI (a context menu on the row), (c) the data model — a `invalidated_at` column on `recorded_times` (for "invalidate this rep") and a `no_show_at` column on `wave_assignments` (for "invalidate this swimmer for this set"). The pairer skips invalidated swimmers/reps on the next pairing pass. Surface in the review UI as "Invalidate rep?" / "Mark swimmer as no-show" context menu items.
- **Verify:** CLI test with 3-wave line finish produces the right group. Manual test in Xcode: tap a row → "Invalidate rep" context menu → row is greyed out → "Save 4 (3 unconfirmed)" becomes "Save 3 (3 unconfirmed)".
- **Estimate:** ~200 lines (line-finish detector + invalidate button + 2 DB columns + 1 new view + tests).

### Slice 4 — Online confidence calibration (v1.17.1, depends on observed data)
- **Scope:** after Slice 1+2+3 ship, collect 30+ confirmed pairings from real sessions. Fit a Platt scaling on `(rawConfidence, wasCorrect)`. Apply the calibration in `PairingEngine.velocitySpaceCost → confidence mapping`.
- **Verify:** the calibrated `confidence: 80` actually means ~80% of the time the engine is correct. Measured on a held-out 10-pairings test.
- **Estimate:** ~80 lines + 30-pairings data + 1 regression test. **Cannot land in v1.16 — needs observed data.**

### Slice 5 — Cohort-seed for cold-start (v1.18.0)
- **Scope:** when a wave has ≥2 cold-start swimmers (no PB for the set's stroke/distance), use the cohort's median predicted time as the prediction. Reduces variance for the cold-start swimmers.
- **Verify:** CLI test with 2 cold-start swimmers in the same wave — predictions cluster around the cohort median. Both get high-confidence assignments.
- **Estimate:** ~60 lines

### Slice 6 — Inter-set learning via Welford's (v1.18.1, depends on observed data)
- **Scope:** maintain a per-swimmer running mean + variance from confirmed pairings (Welford's online algorithm). Use the running estimate for the next set's prediction, not the static PB.
- **Verify:** the second session for a swimmer uses the running estimate. Variance drops as more data accumulates. CLI test: 3 successive sets for the same swimmer — the predicted times get closer to the observed times.
- **Estimate:** ~120 lines (Welford's + integration with PBService)

## 7. Boundaries

- **Always:** Keep the cost function's velocity-space formulation. Don't replace with a greedy heuristic. Match the existing color palette and visual conventions. Match the existing PBService integration.
- **Ask first:** Adding a new column to `recorded_times` or `wave_assignments` (e.g., a `flags` JSONB column for `LikelyFalseStart`). Changing the v1.14 band's confidence thresholds (80/50). Adding a new score key (`line_finish_group_id`).
- **Never:** Modify `PairingEngineCLITest.swift` to remove existing scenarios. Modify `pairing_research/algorithms.swift` (the v0→v10 progression is the research record; it must stay intact). Touch files outside the spec'd scope (PairingEngine.swift, LapAssignment.swift, SessionReviewView.swift, SessionReviewViewModel.swift, the CLI test, and the iOS plan files).

## 8. Success Criteria

v1.16 is "hardened for multi-wave" when:
- **CLI test coverage** includes 3-wave scenarios (4+2+2, 3+3+3, 8+0+0) and a 3-wave line-finish case.
- **No new regressions** in the existing 6+2, 0+8, 8+0 scenarios.
- **The wave-relative-time guard** catches obvious false starts (wave 1 tap before wave 0 reaches the wall).
- **Build succeeded on the Mac Studio**, not just `swiftc -parse`.
- **Documented in `plans/pairing-algorithm-design.md`** — the existing v1 plan should be updated to reflect the v1.10 single-Hungarian refactor (the plan still describes nearest-neighbor; the code uses Hungarian). This is documentation drift to fix.

## 9. Open Questions

1. **Update `plans/pairing-algorithm-design.md` to reflect the v1.10 refactor, or write a new `plans/multi-wave-pairing-hardening.md` (this doc) and leave the old one alone?** The old plan is "Approved for implementation" but the implementation has since pivoted. *(My recommendation: write a short addendum to the old plan, not a rewrite — preserves the design history.)*
2. **What's the threshold for line-finish detection?** The spec says "≥2 taps within 200ms of each other in the same wave." Is 200ms the right number? *(My recommendation: start with 200ms, ship Slice 1, tune from real data.)*
3. **Should the `LikelyFalseStart` flag be a user-facing badge in the review UI, or just a hidden marker?** The variance hint already shows the wave-relative time; an extra badge might be noise. *(My recommendation: hidden marker for v1.16.1, surface as a user-facing badge in v1.17 if data warrants.)*
4. **Slice 4 (online calibration) and Slice 6 (Welford's) both need observed data.** Should we ship them as `TODO(data)` placeholders, or block v1.16 until the data is collected? *(My recommendation: ship v1.16 with Slices 1+2, and add Slices 4+6 to the v1.18 roadmap without a commit until the data exists.)*

---

## 10. Decisions (2026-06-18, greenlit by user)

1. **Addendum, not rewrite** — short addendum to `plans/pairing-algorithm-design.md` per the recommendation. Preserves the design history. (§11 below)
2. **Line-finish threshold = 200ms** — ship Slice 3 with 200ms, tune from real data.
3. **No `LikelyFalseStart` flag** — reframe per user direction: the false-start *detection* stays in v1.16 Slice 2 (the wave-relative-time guard), but no flag is surfaced. Instead, the v1.16 Slice 2 detection is the foundation for a future "invalidate swimmer/rep" coach action in v1.17. A coach who sees a wave-relative-time-guard row in the review UI can take an action to *invalidate* the rep (mark it as a mistake) or *invalidate* the swimmer for this set (mark them as a no-show). This shifts the design from a passive indicator to an active correction. Slice 2 ships the detection; Slice 3 ships the action; the data model + invalidation button land together in v1.17.
4. **Greenlit** — proceed to v1.16 Slice 1 (3-wave CLI test coverage) and v1.16 Slice 2 (wave-relative-time guard, detection-only). Slices 3-6 deferred to v1.17+.

## 11. Addendum to `plans/pairing-algorithm-design.md`

The existing v1 plan (498 lines) describes a "Cohort-gated nearest-neighbor heuristic" approach. The current production code uses a **single global Hungarian** with wave-relative time as the cost-function dimension (v1.10 refactor). The nearest-neighbor approach is preserved as the v0→v10 algorithm progression in `pairing_research/algorithms.swift` (research record, not production code).

The addendum is written to §11 by reading and patching `plans/pairing-algorithm-design.md` directly. The original v1 design content is preserved verbatim; the addendum is a short dated section noting the implementation pivot and referencing this spec.
