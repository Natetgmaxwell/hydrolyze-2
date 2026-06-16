# Native Swift Migration Plan — Hydrolyze

**Status:** Approved — decisions locked
**Author:** Vision
**Date:** 2026-05-16
**Decisions (2026-05-16):**

- Bundle ID: in-place replacement of current Hydrolyze RN app's bundle ID (existing TestFlight/App Store listing becomes native binary; coaches updating from store get native iOS app)
- iOS floor: iOS 17.0 (Swift Charts, @Observable, full SwiftUI)
- Staffing: solo build, user is the engineer
- Web app: keep indefinitely alongside iOS native (permanent parallel coexistence, not transitional)
- TestFlight: staged rollout (internal alpha → small beta cohort → broader beta → public)

---

## Context

An exhaustive feasibility survey has been completed. The verdict: a native Swift iOS rewrite is feasible in 8–20 weeks depending on scope, the `supabase-swift` SDK is mature with full feature parity, and the watchOS timing companion has a universal input story (Crown press = lap on every Apple Watch Series 4+). This plan covers the full build in two phases.

**Decision at review:** Confirm iOS-first, watchOS-Phase-2 sequencing. The user has already confirmed this.

---

## Phase 1 — Native iOS App

**Timeline:** 8–20 engineer-weeks (solo Swift-literate engineer), 12–28 weeks if learning Swift simultaneously. Eng-Manager to confirm Swift literacy at I1 — effort estimates assume Swift-literate; add 30–50% if learning Swift simultaneously.

### 1.1 Project Scaffold

**Xcode structure:**

- Single Xcode workspace with one iOS app target
- watchOS companion target (bundled, not standalone — added in Phase 2)
- Shared framework for models + Supabase client (consumed by both iOS and watch targets)

**Folder layout:**

```
Hydrolyze/
├── App/
│   ├── HydrolyzeApp.swift          # @main entry point
│   └── AppDelegate.swift
├── Features/
│   ├── Auth/
│   │   ├── LoginView.swift
│   │   ├── LoginCallbackView.swift
│   │   └── OnboardingView.swift
│   ├── Today/
│   │   ├── TodayView.swift
│   │   └── TodayViewModel.swift
│   ├── Swimmers/
│   │   ├── SwimmersListView.swift
│   │   ├── SwimmerDetailView.swift
│   │   └── SwimmerSheetView.swift   # add/edit modal
│   ├── Workouts/
│   │   ├── WorkoutsListView.swift
│   │   ├── WorkoutDetailView.swift
│   │   ├── WorkoutBuilderView.swift
│   │   └── SetScheduleView.swift
│   ├── Session/
│   │   ├── SetPickerView.swift
│   │   ├── AttendanceView.swift
│   │   ├── TimingView.swift          # the critical screen
│   │   ├── ResultsView.swift
│   │   └── SessionViewModel.swift
│   └── Profile/
│       └── ProfileView.swift
├── Models/
│   ├── Coach.swift
│   ├── Swimmer.swift
│   ├── Group.swift
│   ├── Workout.swift
│   ├── WorkoutSet.swift
│   ├── RecordedTime.swift
│   ├── SwimmerPB.swift
│   └── IntensityCalibration.swift
├── Services/
│   ├── SupabaseClient.swift         # singleton client + config
│   ├── AuthService.swift            # PKCE sign-in, sign-out, session
│   ├── SwimmerService.swift         # CRUD
│   ├── WorkoutService.swift         # CRUD
│   ├── SessionService.swift         # timing + recorded times
│   └── ProgressionService.swift     # swimmer stats + PB queries
├── Components/
│   ├── LapButton.swift
│   ├── SwimmerCard.swift
│   ├── WorkoutPreview.swift
│   ├── ProgressionChart.swift
│   ├── TrendChart.swift
│   ├── SpeedCurveChart.swift
│   └── SwapSwimmerModal.swift
├── Utilities/
│   ├── WorkoutParser.swift          # port from workout-parser-v2.ts
│   ├── MLPairing.swift              # port from ml-pairing.ts
│   ├── SpeedCurve.swift             # port from speed-curve.ts
│   └── Theme.swift                  # Color + Font extensions
├── Resources/
│   └── Assets.xcassets
└── Tests/
    ├── WorkoutParserTests.swift
    ├── MLPairingTests.swift
    └── SpeedCurveTests.swift
```

**Swift Package Manager dependencies:**

- `supabase-swift` (v2.x) — database, auth, realtime, storage
- No other third-party packages needed — Swift Charts, HealthKit, WatchConnectivity are all native

**Bundle ID (locked):** In-place replacement of the current Hydrolyze RN app's bundle ID. The existing App Store listing and TestFlight build become the native iOS app. Coaches who update from the App Store get the native binary automatically. The RN app remains distributable via the existing build until native ships.

**iOS minimum version:**

- Recommended: **iOS 17** — enables Swift Charts, `@Observable` macro, full SwiftUI refinement
- iOS 16 fallback: remove `@Observable`, use `ObservableObject` + `@Published`, Swift Charts unavailable (use custom Canvas drawing) — not recommended
- **Locked: iOS 17.0**

---

### 1.2 Data Layer

**Supabase client singleton:**

```swift
// Services/SupabaseClient.swift
import Supabase

enum Config {
    static let supabaseURL = URL(string: "https://...supabase.co")!
    static let supabaseKey = "..." // anon key, public
}

@Singleton
class SupabaseClient {
    let client = SupabaseClient(
        supabaseURL: Config.supabaseURL,
        supabaseKey: Config.supabaseKey
    )
}
```

- Initialized once in `App` init, stored as `@Environment` throughout the view tree
- Auth state held in `AuthService`, consumed via `@Environment`

**Swift structs mirroring `workout-types.ts`:**
All types to port:

- `Workout` (id, coach_id, title, status, scheduled_at, am_pm, workout_text, sets)
- `WorkoutSet` (id, order_index, reps, distance, stroke, interval_text, gear, intensity_type, intensity_label, pace_target_distance, drill)
- `Swimmer` (id, coach_id, first_name, last_name, birthdate, gender, notes, archived_at, groups)
- `Group` (id, name)
- `RecordedTime` (id, swimmer_id, workout_set_id, workout_id, time_ms, rep_index, intensity, gear, created_at)
- `SwimmerPB` (id, swimmer_id, distance, stroke, time_ms, recorded_at, gear)
- `SwimmerIntensityCalibration` (swimmer_id, stroke, intensity, gear, multiplier_mean, sample_count)

**Query layer pattern:**

```swift
// Thin async/throws wrapper — no thenable issue in Swift
func query<T>(_ builder: QueryBuilder<T>) async throws -> T {
    let result = try await client.database.query(builder)
    return result.data ?? []
}
```

- All reads return `async throws`, caller handles errors in `Task { do { } catch { } }`
- No timeout wrapping needed — Swift `Task` deadline handles cancellation cleanly
- Repository pattern: one repository per aggregate (`SwimmerRepository`, `WorkoutRepository`) — keeps query logic co-located, services call repositories

**Caching strategy:**

- Phase 1: no caching layer — all reads hit Supabase directly
- `@Observable` view models hold screen state, focus-refetch reloads on appear
- `NSCache` for any computed expensive objects (chart data transformations) if needed later
- No react-query equivalent needed at this scale

---

### 1.3 Auth Flow

**PKCE OAuth — `supabase-swift` handles the full flow:**

1. App calls `signInWithOAuth()` — opens ASWebAuthenticationSession (system browser)
2. Callback URL received at custom URL scheme (`hydrolyze://login-callback`)
3. `exchangeCodeForSession()` inside `LoginCallbackView.onOpenURL`
4. Session stored in `AuthenticationServices.KeychainAccountStore` by default (built into supabase-swift)
5. `AuthService` holds current `Session` as `@Published` property
6. `AuthService.getCoachId()` called on session resolve — same `getOrCreateCoach` logic as current RN app

**AuthContext equivalent:**

```swift
@Observable
class AuthService {
    var session: Session?
    var coachId: String?
    var coachName: String?
    var loading = true

    func resolve() async {
        guard let session = try? await client.auth.session else { return }
        let coach = try? await getOrCreateCoach(session.user)
        self.coachId = coach?.id
        self.coachName = coach?.name
    }
}
```

Injected via `@Environment(AuthService.self)` throughout the app.

**Onboarding state machine:** Same states as current RN (onboarding_step: name → pool_units → done). `hasCompletedOnboarding` check same as current.

---

### 1.4 Navigation Architecture

```
TabView (4 tabs)
├── TodayTab (NavigationStack)
│   └── TodayView → SetPickerView → AttendanceView → TimingView
├── SwimmersTab (NavigationStack)
│   └── SwimmersListView → SwimmerDetailView
│   └── SwimmersListView → SwimmerSheetView (sheet)
├── WorkoutsTab (NavigationStack)
│   └── WorkoutsListView → WorkoutDetailView
│   └── WorkoutsListView → WorkoutBuilderView
│   └── WorkoutsListView → SetScheduleView (sheet)
└── ProfileTab (NavigationStack)
    └── ProfileView → SettingsView
```

- `NavigationStack` for all tab roots — standard SwiftUI push navigation
- Modal sheets: swimmer sheet, set-schedule sheet, swap modal → `.sheet()` modifier
- Deep links: `hydrolyze://workout/{id}`, `hydrolyze://swimmer/{id}` — `onOpenURL` routes to correct `NavigationPath`

---

### 1.5 Screens — Port List by Complexity

**Trivial (1–2 days each):**

- LoginView — email/password form, OAuth button, reset password
- LoginCallbackView — URL handler, session exchange, redirect
- ProfileView — display name, email, sign out button
- SettingsView — pool units, coach name edit
- AuthDebugView — session inspector (dev only)

**Standard CRUD (2–3 days each):**

- SwimmersListView — group sections, initials circles, add button
- SwimmerDetailView — PB list, notes, edit/delete
- SwimmerSheetView — add/edit swimmer form (first, last, birthdate, gender, groups, notes)
- WorkoutsListView — list with status badges, delete swipe
- WorkoutDetailView — parsed preview, edit button, start session
- SetScheduleView — date picker, AM/PM toggle

**Complex (3–5 days each):**

- TodayView — next scheduled workout card, date display, pull-to-refresh
- WorkoutBuilderView — workout text parser, set list, save flow
- AttendanceView — swimmer multi-select, stats cache fetch, start timing
- ResultsView — per-swimmer times, trend chart, save/discard flow

**Critical (1–2 weeks):**

- **TimingView** — see dedicated section below

**Charts (3–5 days for all three):**

- ProgressionChart — Swift Charts line chart, dot size/saturation by rep position/fatigue
- TrendChart — bar or line chart per swimmer per rep
- SpeedCurveChart — scatter plot + fitted curve

---

### 1.6 Timing Screen — The Heart Of The App

**State machine:** `ready → running → rep_done → (next rep → ready | end → results)`

**Core UI:**

- Large numeric elapsed time display (`.timer` font style) — center screen
- Rep progress indicator: "REP 2 OF 4" label
- Swimmer list below clock — shows assigned swimmers, remaining count
- Lap button: full-width, 80pt height, cyan background, haptic feedback on press

**Haptic feedback:**

```swift
import UIKit
let impact = UIImpactFeedbackGenerator(style: .heavy)
impact.impactOccurred()
```

- Lap press: medium impact
- Stop: heavy impact
- Error/unassign: light impact

**Screen keep-awake:**

```swift
UIApplication.shared.isIdleTimerDisabled = true // timing screen active
UIApplication.shared.isIdleTimerDisabled = false // on disappear
```

**Real-time clock:**

- `Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()` — 100ms tick, updates `elapsed` state
- `timelineView` for SwiftUI Canvas alternative if 100ms tick feels janky

**Swimmer assignment:**

- Port of `ml-pairing.ts` algorithm to Swift — same weighted assignment logic
- `statsCache` passed from `AttendanceView` via `@Environment`
- Swimmer assignment shown as list rows below clock during running state

**Background behavior:**

- App stays alive under iOS background via HealthKit `HKWorkoutSession` integration
- For Phase 1 (no watch): screen must stay on (`isIdleTimerDisabled = true`), app must stay in foreground
- Push notification reminder if app goes to background mid-session (Phase 2: watch handles this)

**Progression chart:**

- Renders above the START button in Ready state
- Uses `SwimmerProgressionService` query — same SQL shape as current `swimmer-stats.ts`
- Empty state: "★ First time swimming this exact set"

---

### 1.7 Charts (Swift Charts)

**ProgressionChart:** Line chart, `date` on x-axis, `timeMs` on y-axis. Dot mark with `size` encoded by `repPosition`, `color` by fatigue gradient. PB shown as a rule mark. Fits in Swift Charts natively.

**TrendChart:** Bar chart, `rep` on x-axis, `timeMs` on y-axis, per-swimmer color grouping. Fits Swift Charts directly.

**SpeedCurveChart:** Scatter plot (point mark) with fitted regression curve (line mark). Swift Charts `transform` API or pre-compute in Swift. Fits.

**Note on fidelity:** Current Canvas implementations use custom `SwiftUI.Canvas` for pixel-perfect gradient rendering. Swift Charts uses declarative Chart marks — visual fidelity will be slightly different (cleaner but less custom). Acceptable tradeoff for native performance and maintainability.

---

### 1.8 Component Library

| RN Component        | SwiftUI Replacement       | Notes                                  |
| ------------------- | ------------------------- | -------------------------------------- |
| `LapButton`         | `LapButton` (custom View) | Haptic on tap, large cyan button       |
| `SwimmerCard`       | `SwimmerCard`             | Row: initials + name + time/assignment |
| `WorkoutPreview`    | `WorkoutPreview`          | Parsed set list, same visual language  |
| `ProgressionChart`  | `ProgressionChart`        | Swift Charts                           |
| `WorkoutTrendChart` | `TrendChart`              | Swift Charts                           |
| `SpeedCurveChart`   | `SpeedCurveChart`         | Swift Charts                           |
| `SwapSwimmerModal`  | `SwapSheet`               | `.sheet()` with swimmer list           |

**Theme / design tokens (port from `theme.ts`):**

```swift
// Utilities/Theme.swift
extension Color {
    static let base = Color(hex: "0B0E14")
    static let surface = Color(hex: "151921")
    static let elevated = Color(hex: "1E2530")
    static let cyan = Color(hex: "00E5CC")
    static let amber = Color(hex: "F59E0B")
    static let danger = Color(hex: "EF4444")
    // ...
}
extension Font {
    static let uiSemiBold = Font.system(.body, design: .default, weight: .semibold)
    static let monoMedium = Font.system(.caption, design: .monospaced, weight: .medium)
    // ...
}
```

---

### 1.9 Testing Strategy

**High-value unit tests (XCTest):**

- `WorkoutParserTests` — port all V2 parser test cases, same inputs should produce same outputs
- `MLPairingTests` — port all existing pairing test cases
- `SpeedCurveTests` — port all speed curve test cases

**Integration tests:**

- Auth flow: sign in → resolve coach → navigate to today — can use mock Supabase
- Timing flow: simulate lap → assignment → save — require real DB or tight mock

**UI tests (sparingly):**

- Critical paths only: login → start session → save results
- SwiftUI test with `XCUIApplication` for navigation flows

**What NOT to unit test:**

- SwiftUI views (fragile, slow, low ROI)
- Supabase client (tested by supabase-swift team)
- Chart rendering (visual check only)

---

## Phase 2 — watchOS Companion App

**Timeline:** 4–6 engineer-weeks (after iOS Phase 1 stabilizes)

### 2.1 Target Setup

- **watchOS 10 minimum** — Swift Charts on watch, full `HKWorkoutSession` improvements
- **Companion target** (bundled inside iOS workspace) — not standalone App Store app
- **Shared framework** (`HydrolyzeWatchShared`) containing:
  - All model structs
  - `SupabaseClient` wrapper (read-only queries on watch)
  - `WatchConnectivityService`
  - No auth — watch inherits auth context from iPhone via `WCSession`

### 2.2 Universal Input Handling

| Action      | All watches           | Ultra bonus         |
| ----------- | --------------------- | ------------------- |
| Lap         | Crown press           | Action Button press |
| End session | Long Crown press (2s) | —                   |
| Undo last   | Swipe up (screen)     | —                   |

**Crown press → lap:**

```swift
crownsequencer.delegate = self
crownsequencer.focus()

// In delegate:
func crownDidTap(_ crown: WKCrownSequencer) {
    lapTime() // same action as tap button
}
```

**Action Button (Ultra):**

```swift
if WKExtensionDeviceActions.supportsActions {
    // Map .primaryAction to lap
}
```

### 2.3 HKWorkoutSession + Water Lock

**Session lifecycle:**

1. iPhone sends current set context to watch via `WCSession.sendMessage()` before session starts
2. Watch starts `HKWorkoutSession` when coach taps "Start" on watch (or when iPhone session begins)
3. Water Lock auto-engages on watch when workout session starts
4. Crown press registers lap timestamps (local, no iPhone needed)
5. On session end: watch sends batch of `{timestamp, rep_index}` back to iPhone via `transferUserInfo`

**Keep screen on:** `HKWorkoutSession` handles this automatically.

**Complications:** Configurable watch face complication showing current set description or rep count. Coach taps complication to resume session.

### 2.4 WatchConnectivity Sync

**iPhone → Watch (session context, before session):**

```swift
let context: [String: Any] = [
    "setDistance": 100,
    "stroke": "Free",
    "reps": 4,
    "targetTimeMs": 65000,
    "swimmers": swimmerNames // for display, no assignment
]
try session.updateApplicationContext(context)
```

**Watch → iPhone (lap times, batched):**

```swift
// On each lap:
let lapData: [String: Any] = ["lapMs": lapMs, "repIndex": repIndex]
session.transferUserInfo(lapData) // background-capable, reliable
```

**Offline behavior:**

- Watch stores laps in `UserDefaults` (or `WKInterfaceDevice`)
- If iPhone out of range: watch continues recording, syncs via `transferUserInfo` when connectivity restored
- iPhone app works fully standalone — watch is optional enhancement

### 2.5 Watch UI (3 screens max)

**Pre-session screen:** "Ready" — current set description, tap to begin. Crown press starts.

**Active timing screen:**

- Large elapsed time (center, `.timer` style)
- Current rep number (e.g., "REP 2 OF 4")
- "LAP" label below time (Crown tap = lap)
- Subtle swimmer count remaining

**Post-session screen:** Brief review of lap times before dismiss. iPhone handles the full results screen.

---

## Phase 3 — Schema Migration

**Timing:** Before Phase 2 watch development starts. Not a Phase 1 blocker.

**Migration 1 — source_device column:**

```sql
ALTER TABLE recorded_times
ADD COLUMN source_device TEXT NOT NULL DEFAULT 'phone'
CHECK (source_device IN ('phone', 'watch'));
```

- All existing rows default to `'phone'` — no data migration needed
- New rows from watch get `source_device = 'watch'`

**Migration 2 — device_uuid for sync correlation (optional, Phase 2 only):**

```sql
ALTER TABLE recorded_times
ADD COLUMN device_uuid TEXT;
```

- Nullable — used only when source is `'watch'` to correlate sync batches
- Not needed for Phase 1

---

## Migration Sequencing (Permanent Parallel Coexistence)

**Coexistence model (permanent):**

- RN/web app stays live permanently alongside iOS native app
- iPhone coaches migrate to native iOS when they want (TestFlight → public release)
- Web app serves iPad/desktop/Android coaches indefinitely (not transitional)
- Both apps are maintained in parallel — web is not sunset after iOS ships
- Android coaches stay on RN web (no Android native plan)

**iOS chunk sequence:**

| Chunk  | Name                             | Key Files                                                                     | Success Check                                  | Est. Effort   |
| ------ | -------------------------------- | ----------------------------------------------------------------------------- | ---------------------------------------------- | ------------- |
| I1     | Xcode scaffold                   | `HydrolyzeApp.swift`, `ContentView.swift`, `SupabaseClient.swift`             | App builds, shows empty tab view               | 2–3 days      |
| I2     | Auth + AuthContext               | `AuthService.swift`, `LoginView.swift`, `LoginCallbackView.swift`             | Sign in flow works end-to-end                  | 3–4 days      |
| I3     | Models + query layer             | `Models/`, `SwimmerService.swift`, `WorkoutService.swift`                     | TypeScript tests pass when ported              | 3–4 days      |
| I4     | Today + Tab nav                  | `TodayView.swift`, `TabView` shell                                            | Today's workout shows                          | 2–3 days      |
| I5     | Swimmers list + detail           | `SwimmersListView.swift`, `SwimmerDetailView.swift`, `SwimmerSheetView.swift` | CRUD all swimmers                              | 3–4 days      |
| I6     | Workouts list + detail           | `WorkoutsListView.swift`, `WorkoutDetailView.swift`                           | List + detail + edit                           | 3–4 days      |
| I7     | Set-schedule + workout builder   | `SetScheduleView.swift`, `WorkoutBuilderView.swift`                           | Full workout creation                          | 3–4 days      |
| I8     | Attendance + stats cache         | `AttendanceView.swift`, `fetchStatsCache` port                                | Swimmer selection + stats load                 | 3–4 days      |
| **I9** | **Timing screen**                | `TimingView.swift`, `SessionViewModel.swift`, `LapButton.swift`               | **Core loop works**                            | **1–2 weeks** |
| I10    | Results + assignment flow        | `ResultsView.swift`, `SwimmerCard.swift`                                      | Save times to DB                               | 3–4 days      |
| I11    | Charts (all 3)                   | `ProgressionChart.swift`, `TrendChart.swift`, `SpeedCurveChart.swift`         | Charts render correctly                        | 3–5 days      |
| I12    | Profile + settings               | `ProfileView.swift`, `SettingsView.swift`                                     | Sign out, settings save                        | 1–2 days      |
| I13    | TestFlight prep + staged rollout | Assets, entitlements, onboarding edge cases                                   | TestFlight build stable, staged rollout begins | 2–3 days      |

**TestFlight staged rollout:**

- Internal alpha (solo + close testers, TestFlight internal)
- Small beta cohort (5–10 trusted coaches, TestFlight external)
- Broader beta (all signed-up coaches)
- Public App Store release (after beta period with no critical bugs)

**Phase 2 chunks (preliminary, revise after Phase 1):**

- W1: watch target scaffold + shared framework
- W2: WatchConnectivity sync service
- W3: HKWorkoutSession + Water Lock
- W4: Universal input (Crown + Action Button)
- W5: Watch UI (3 screens) + complications
- W6: Integration testing + sync verification

---

## Risk Register

| Risk                                                 | Likelihood                | Impact        | Mitigation                                                                                    |
| ---------------------------------------------------- | ------------------------- | ------------- | --------------------------------------------------------------------------------------------- |
| Engineer learning Swift simultaneously               | **Confirmed (TBD at I1)** | +50% timeline | Prototype timing screen first (I9) as confidence check; effort estimate adjusted for learning |
| Supabase Swift SDK auth callback URL handling on iOS | Low                       | Medium        | `onOpenURL` pattern well-documented; test early in I2                                         |
| App Store HealthKit review friction                  | Low                       | Low           | Swim coaching is clear legitimate use case; include justification                             |
| RN bugs accumulate during iOS build                  | High                      | Medium        | Keep RN app in maintenance mode (security fixes only), no new features                        |
| Schema migration needed mid-Phase-1                  | Low                       | Medium        | Avoid any schema changes in Phase 1; all additions only                                       |

---

## Non-Goals (explicit)

- **No Android native plan** — Android coaches stay on RN (Expo web or native if/when they want it)
- **No iPad-optimized layout** — iPhone-first, iPad scales acceptably with standard SwiftUI layouts
- **No offline-first** — online required (same as RN today)
- **No optimistic UI for writes** — writes go to Supabase, errors surface via Alert (same as today)
- **No RN + Swift hybrid** — this is not a RN migration, it's a from-scratch Swift rewrite

---

## Open Questions — All Resolved

All five open questions have been resolved by the user (2026-05-16). See the decision log at the top of this document.

---

## Files Created Summary

**Phase 1 iOS app:** ~40–50 new Swift files across `App/`, `Features/`, `Models/`, `Services/`, `Components/`, `Utilities/`, `Tests/`

**Phase 2 watchOS:** ~15–20 new Swift files across `WatchApp/`, `WatchShared/`

**Shared models + services:** ~20 Swift files (consumed by both targets)

**Total net new files:** ~75–90 Swift files
