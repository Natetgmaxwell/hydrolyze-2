# plans.archive.2026-06-30 — Historical design docs

These 14 design specs from the pre-iOS-native era are preserved for
historical reference. As of 2026-06-30, the project consolidated onto
`ios-native/` (Swift / SwiftUI) and the React Native app
(`hydrolyze-mobile/`) was deleted.

**Do not edit these files.** They describe design decisions as they
existed when the project had parallel mobile + web clients. The
iOS-native code is the source of truth for current behavior.

## What's in here

| File | Era | Status |
|---|---|---|
| `data-flow-streamlining.md` | RN era | Historical — RN code is gone |
| `emotional-design-coverage-matrix.md` | RN era | Principles still relevant; current iOS code in `Lib/Haptics.swift`, `Lib/Animations.swift`, `Lib/PressFeedbackStyle.swift` |
| `login-view-design-spec.md` | RN era | FROZEN (in file) — iOS implementation: `Views/Auth/LoginView.swift` |
| `multi-wave-pairing-hardening.md` | RN era | FROZEN (in file) — iOS implementation: `Services/PairingEngine.swift` |
| `native-swift-migration.md` | Migration plan | DONE — ios-native is the canonical client |
| `pairing-algorithm-design.md` | RN era | FROZEN (in file) — iOS implementation: `Services/PairingEngine.swift` |
| `session-review-design-spec.md` | RN era | FROZEN (in file) — iOS implementation: `Views/SessionReview/SessionReviewView.swift` |
| `swimmer-invite-code-onboarding-design-spec.md` | Active | Migrated to iOS — see `Services/AuthService.swift`, `Services/AuthManager.swift` |
| `swimmers-view-design-spec.md` | RN era | FROZEN (in file) — iOS implementation: `Views/Swimmers/*` |
| `today-view-design-spec.md` | RN era | FROZEN (in file) — iOS implementation: `Views/Today/TodayView.swift` |
| `volume-button-stopwatch-implementation.md` | RN era | Decision was "don't ship volume button on iOS" — `Lib/VolumeButtonService.swift` retained for hardware integration testing |
| `volume-button-stopwatch-strategy.md` | RN era | Strategy doc — kept for App Store review context |
| `workout-builder-design-spec.md` | RN era | FROZEN (in file) — iOS implementation: `Views/Workouts/WorkoutBuilderView.swift` |
| `workouts-view-design-spec.md` | RN era | FROZEN (in file) — iOS implementation: `Views/Workouts/WorkoutsListView.swift` |

## How to use this archive

- For **why a current iOS screen looks the way it does**, the spec
  here is the design intent. Cross-reference with the Swift file
  for the current implementation.
- For **historical context** (e.g., why the project was rebuilt in
  Swift), `native-swift-migration.md` is the canonical reference.
- For **post-migration pivots** (e.g., the v1.16 micro-interaction
  work, the iOS micro-interaction system), the design now lives
  in the iOS code itself.

## What NOT to do

- Don't merge these back into `plans/` — that's the pre-cleanup
  pattern and would re-introduce the dual-truth problem.
- Don't edit these files "to match current code" — they describe
  intent at the time, not current state. The code is the source
  of truth; the spec is the historical reasoning.
