# I6 WorkoutsView Design Spec — Native SwiftUI

**Chunk:** I6 (workouts list + workout detail)
**Date:** 2026-05-17
**Status:** Draft — pending user review
**Source:** RN `app/(tabs)/workouts.tsx` (list), `app/workout/[id].tsx` (detail), `app/workout/new.tsx` (builder)

---

## 1. Screen Identity

Two screens:

- **WorkoutsListView** — `TabView` item 1. Filterable list of all workouts for the coach.
- **WorkoutDetailView** — pushed from list row. Full workout info + actions.

Pool-deck ergonomics: coach can scan upcoming workouts, pick one, and launch a session with minimal taps.

---

## 2. Visual Design

### Color Palette (from `lib/theme.ts` — Swift equivalents)

| Role          | Hex       | Usage                     |
| ------------- | --------- | ------------------------- |
| Background    | `#060e18` | Page background           |
| Surface       | `#0d1b2a` | Cards, elevated surfaces  |
| Border        | `#2d3e50` | Dividers, card borders    |
| Text primary  | `#e2f4fa` | Headings, primary content |
| Text muted    | `#7a9bb0` | Secondary labels, hints   |
| Text dim      | `#4a6572` | Timestamps, metadata      |
| Cyan accent   | `#09d4ee` | CTAs, active filter       |
| Amber         | `#f59e0b` | AM/PM badge, Draft status |
| Optimal green | `#10b981` | Complete status           |
| Danger red    | `#ef4444` | Delete actions            |

### Typography

| Element       | Font   | Size | Weight   |
| ------------- | ------ | ---- | -------- |
| Screen label  | System | 10pt | Semibold |
| Date heading  | System | 11pt | Regular  |
| Workout title | System | 17pt | Semibold |
| Status badge  | System | 10pt | Semibold |
| Filter pill   | System | 13pt | Medium   |
| Button text   | System | 16pt | Semibold |
| Tab label     | System | 10pt | Medium   |

---

## 3. Layout Structure

### WorkoutsListView

```
┌─────────────────────────────────────┐
│  WORKOUTS              [+ New]      │  ← nav bar: label + create button
├─────────────────────────────────────┤
│  [All] [Scheduled] [Draft] [Done]   │  ← filter pills, horizontal scroll
├─────────────────────────────────────┤
│  ▼ SAT MAY 17                       │  ← date section header (sticky)
│    Main Set                   [AM]  │  ← workout row
│    Draft                            │
│                                     │
│  ▶ SAT MAY 10                       │
│    Threshold Set              [AM]   │
│    Complete                        │
│                                     │
│  ▶ THU MAY 8                        │
│    Kick Set                        │
│    Draft                           │
└─────────────────────────────────────┘
```

**Sections grouped by date** — date header (weekday, month day) is a sticky section header. Only shows date if `scheduled_at` is not null; undated workouts grouped at top under "UNSCHEDULED".

### WorkoutDetailView

```
┌─────────────────────────────────────┐
│  ← Workouts               [Delete]  │  ← nav bar: back + delete
├─────────────────────────────────────┤
│  Main Set                           │  ← title, 22pt semibold
│  SAT MAY 17 · AM  ·  Draft          │  ← metadata row
├─────────────────────────────────────┤
│                                     │
│  [Parsed workout preview here]      │  ← WorkoutPreview component
│                                     │
├─────────────────────────────────────┤
│  [       Start Session         ]    │  ← cyan CTA (or "Continue")
│                                     │
│  [         Edit Workout        ]    │  ← surface button (draft/sched)
│                                     │
│  [        Mark Complete        ]    │  ← surface button (in_progress)
└─────────────────────────────────────┘
```

---

## 4. Navigation

- **WorkoutsListView** → **WorkoutDetailView**: tap row → `NavigationLink` push
- **WorkoutDetailView** → **Edit**: tap Edit → `fullScreenCover` (workout builder — later I chunk)
- **WorkoutDetailView** → **Start Session**: tap Start → push `SetPickerView` (later I chunk)
- **WorkoutsListView** → **New Workout**: `+` button → push `WorkoutBuilderView` (later I chunk)

For I6: Start Session and Edit are placeholders (print/log), just like TodayView's startSession.

---

## 5. Component Inventory

### `WorkoutsListView`

- Navigation title "WORKOUTS"
- `+` button top right → placeholder navigation
- Filter pill row (All / Scheduled / Draft / Complete)
- `@State private var selectedFilter: WorkoutFilter = .all`
- `List` with `Section` headers by date
- Pull-to-refresh: `.refreshable { await loadWorkouts() }`
- Swipe-to-delete with confirmation alert

### `WorkoutRow`

```
┌──────────────────────────────────────┐
│  SAT MAY 17                          │  ← date (11pt, dim)
│  Main Set            [AM]    ›       │  ← title (17pt semibold) + AM badge + chevron
│  Draft                                 │  ← status (10pt, amber/green/cyan)
└──────────────────────────────────────┘
```

- Status badge: Draft = amber, Complete = green, in_progress = cyan
- AM/PM badge: amber background pill, 8pt uppercase text
- Chevron: `>` character, dim color
- Height: standard touch target (44pt+)

### `WorkoutDetailView`

- Navigation title: workout title (truncated if long)
- Back button (auto-provided by NavigationStack)
- Delete button: top right trailing, destructive, shows confirmation alert
- Title section: title (22pt semibold) + metadata row (date · AM/PM · status)
- WorkoutPreview: renders the parsed workout tree (exact same component as RN)
- Action buttons: Start Session (cyan fill), Edit Workout (surface, draft/sched only), Mark Complete (surface, in_progress only)

### `WorkoutFilter` enum

```swift
enum WorkoutFilter: String, CaseIterable {
    case all = "All"
    case scheduled = "Scheduled"
    case draft = "Draft"
    case complete = "Complete"
}
```

### `WorkoutRowData`

```swift
struct WorkoutRowData: Identifiable {
    let id: String
    let title: String?
    let status: WorkoutStatus
    let scheduledAt: Date?
    let amPm: String?
}
```

### `WorkoutStatus` enum

```swift
enum WorkoutStatus: String {
    case draft
    case scheduled
    case inProgress = "in_progress"
    case complete
}
```

---

## 6. Data Flow

### WorkoutsListViewModel

```swift
@MainActor
final class WorkoutsListViewModel: ObservableObject {
    @Published var workouts: [WorkoutRowData] = []
    @Published var selectedFilter: WorkoutFilter = .all
    @Published var isLoading: Bool = false

    func loadWorkouts(coachId: String?) async
    func deleteWorkout(id: String) async
}
```

Fetch: `WorkoutService.fetchWorkouts(coachId:coachId, filter:)`
Delete: `WorkoutService.deleteWorkout(id:)`
Filter logic: same as RN — query `workouts` table with `.eq("coach_id", coachId)` + optional `.eq("status", filterValue)` based on filter selection.

### WorkoutDetailViewModel

```swift
@MainActor
final class WorkoutDetailViewModel: ObservableObject {
    @Published var workout: Workout?
    @Published var parsedWorkout: WorkoutModel?
    @Published var isLoading: Bool = true

    func loadWorkout(id: String, coachId: String?) async
    func deleteWorkout(id: String) async
    func markComplete(id: String) async
    func startSession()
}
```

Fetch: `WorkoutService.fetchWorkout(id:)` + `WorkoutService.fetchWorkoutSets(workoutId:)`
Parse: use `WorkoutParser.parse()` (the Swift port of the v2 parser — if not yet implemented, use a placeholder model with title + sections from the direct query for now)

---

## 7. Interactions

| Interaction            | Behavior                                                      |
| ---------------------- | ------------------------------------------------------------- |
| Tap workout row        | Push `WorkoutDetailView`                                      |
| Long-press / swipe row | Delete with confirmation alert                                |
| Tap `+` button         | Placeholder — prints to console (builder not in this chunk)   |
| Tap Start Session      | Placeholder — prints to console (SetPicker not in this chunk) |
| Tap Edit Workout       | Placeholder — prints to console (builder not in this chunk)   |
| Tap Mark Complete      | Updates local state optimistically, persists to Supabase      |
| Tap Delete (nav bar)   | Confirmation alert → delete → pop to list                     |
| Pull-to-refresh list   | Reloads workout list                                          |

---

## 8. File Structure

```
ios-native/Hydrolyze/Sources/
├── App/
│   └── ContentView.swift              ← update: tab bar items wired
├── Views/
│   ├── Workouts/
│   │   ├── WorkoutsListView.swift     ← I6: list screen
│   │   ├── WorkoutDetailView.swift    ← I6: detail screen
│   │   └── Components/
│   │       └── WorkoutRow.swift       ← I6: row component
│   ├── Today/                         ← from I5
│   │   ├── TodayView.swift
│   │   └── WorkoutCard.swift
│   └── Auth/                          ← from I4
├── Models/                            ← from I3
├── Services/                          ← from I2/I3
└── Lib/
    ├── Color+Hex.swift                 ← from I4
    └── WorkoutParser.swift            ← I6: minimal parser stub (or full v2 port)
```

---

## 9. RN Parity / Deliberate Divergence

| RN behavior                              | Native decision                          | Reason                                                 |
| ---------------------------------------- | ---------------------------------------- | ------------------------------------------------------ |
| FlatList with custom filter row          | `List` with `Section` by date            | SwiftUI `List` + `Section` is idiomatic                |
| No section headers                       | Date as sticky section header            | Groups workouts by day — cleaner for coaches with many |
| Long-press to delete                     | Swipe-to-delete on row                   | iOS native gesture, more discoverable                  |
| No pull-to-refresh                       | `.refreshable { }` on list               | Native iOS expectation                                 |
| Edit routes to `/workout/new?workoutId=` | `fullScreenCover` for edit (placeholder) | iOS modal pattern, real builder in later I chunk       |
| Status shown as capitalized text         | Status badge with color coding           | Visual hierarchy — one glance distinguishes status     |
| No AM/PM badge on row                    | AM/PM amber pill on row                  | Already on TodayView card; bring to list for context   |
| "Done" as filter label                   | "Complete" as filter label               | Status value is `complete` — match the value           |

---

## 10. Key Design Decisions

1. **Date sections over flat list** — coaches think in days. Grouping by date makes scanning faster than a flat chronological list.
2. **Swipe-to-delete over long-press** — native iOS pattern, no learning curve.
3. **WorkoutPreview component shared** — the Swift port of the parsed workout tree renderer should be shared between TodayView (future), WorkoutsListView (placeholder), and WorkoutDetailView. Build it once in I6.
4. **Optimistic UI for Mark Complete** — update local state immediately, persist in background.
5. **Status badge color coding** — amber (Draft), green (Complete), cyan (In Progress) — consistent with RN color tokens.
6. **WorkoutDetailView as push** — not a sheet or tab. Pushing from list is correct navigation hierarchy.
7. **Delete in nav bar** — less prominent than in RN (which has a danger zone at the bottom). On iOS, swipe-to-delete on the list row handles deletion; the detail view's delete is in the nav bar trailing position as a secondary action.

---

## 11. Out Of Scope

- **Workout builder/edit** — placeholder only (print/log). Builder is a later I chunk.
- **SetPickerView** — placeholder only (print/log). Part of I9 (timing screen).
- **Create from `+` button** — placeholder only. Builder is a later I chunk.
- **Empty state for filtered results** — show `List` empty view with prose: "No [status] workouts"
- **Workout preview parsing** — if the Swift `WorkoutParser` is not ready, use a simple text representation from the raw `workout_text` field for now.

---

_Designer: Hydrolyze Senior Designer_
_Plan absolute path: `/Users/nathanmaxwell/Downloads/Hydrolyze 2/plans/workouts-view-design-spec.md`_
_Plan relative path: `plans/workouts-view-design-spec.md`_
