# I5 TodayView Design Spec — Native SwiftUI
> **[FROZEN 2026-06-30]** Shipped. See source files for current state. Do not edit without checking the working tree first.

**Chunk:** I5 (coach home screen after sign-in)
**Date:** 2026-05-10
**Status:** Approved — ready for Eng-Manager implementation
**Source:** RN `app/(tabs)/today.tsx` is the functional baseline; this spec enhances it for SwiftUI/iOS conventions and pool-deck ergonomics.

---

## 1. Screen Identity

**Route:** Root tab after sign-in (`TabView` item 0). Shown every time the coach opens the app.
**Purpose:** Glanceable daily context — what's scheduled today, can I start now?

Pool-deck ergonomics: one hand, standing in sun or shade, glancing at the screen between sets. Information density is moderate; action is one tap away.

---

## 2. Visual Design

### Color Palette (from `lib/theme.ts` — use Swift equivalents)

| Role             | Hex       | Usage                              |
| ---------------- | --------- | ---------------------------------- |
| Background       | `#060e18` | Page background                    |
| Surface          | `#0d1b2a` | Cards, elevated surfaces           |
| Surface elevated | `#1a2d42` | Input fields, interactive elements |
| Border           | `#2d3e50` | Dividers, card borders             |
| Text primary     | `#e2f4fa` | Headings, primary content          |
| Text muted       | `#7a9bb0` | Secondary labels, hints            |
| Text dim         | `#4a6572` | Timestamps, metadata               |
| Cyan accent      | `#09d4ee` | CTAs, active tab, title            |
| Amber            | `#f59e0b` | AM/PM badge, status indicators     |
| Optimal green    | `#10b981` | Complete status                    |

### Typography

| Element       | Font   | Size | Weight            |
| ------------- | ------ | ---- | ----------------- |
| "TODAY" label | System | 10pt | Semibold, tracked |
| Date heading  | System | 22pt | Bold              |
| Greeting      | System | 15pt | Regular           |
| Card title    | System | 18pt | Semibold          |
| Card subtitle | System | 13pt | Regular           |
| Button text   | System | 16pt | Semibold          |
| Tab labels    | System | 10pt | Medium            |

---

## 3. Layout Structure

### Tab Bar (bottom)

Persistent `TabView` with 4 items:

| Tab      | Icon             | Label    |
| -------- | ---------------- | -------- |
| Today    | `house.fill`     | Today    |
| Workouts | `calendar`       | Workouts |
| Swimmers | `person.2.fill`  | Swimmers |
| Settings | `gearshape.fill` | Settings |

Active tab: `Colors.cyan`. Inactive: `Colors.dim`. No labels on icons (consistent with RN tab bar).

### TodayView Content

```
┌─────────────────────────────────────┐
│  TODAY                    [avatar▾] │  ← nav bar: label + settings access
│  Saturday, May 17                   │  ← date heading, 22pt bold
│  Good morning, Coach.               │  ← greeting, 15pt muted
├─────────────────────────────────────┤
│                                     │
│  UP NEXT                            │  ← section label, 10pt dim
│  ┌─────────────────────────────┐   │
│  │ AM   Main Set               │   │  ← amber AM badge + card title
│  │ 4 × 100 Free @ threshold    │   │  ← set preview line
│  │ 8 swimmers · 8 sets         │   │  ← muted subtitle
│  │                             │   │
│  │    [ Start Session ]        │   │  ← cyan CTA, 56pt tall
│  └─────────────────────────────┘   │
│                                     │
│  ─────── OR ───────                 │
│                                     │
│  No workout scheduled today.         │  ← empty state
│  Tap Workouts to schedule one.      │
│                                     │
└─────────────────────────────────────┘
```

**Notes:**

- "TODAY" label in nav bar, not at top of content (consistent with iOS conventions)
- Settings access via avatar/menu in nav bar (one tap)
- Content scrolls if taller than screen

---

## 4. States

### Loading

- Centered `ProgressView()` on dark background
- No skeleton — loading is fast

### Workout Present

- Shows `WorkoutCard` (see Component Inventory below)
- Card shows: AM/PM badge, title, set summary, swimmer count, "Start Session" button

### Empty State

- Centered layout: `house` SF Symbol icon (48pt, dim)
- "No workout scheduled" heading (18pt, muted)
- "Tap Workouts to schedule one" hint (13pt, dim)
- No CTA button to create — creation lives in Workouts tab

### Error State

- Full-screen alert or banner: "Couldn't load today's workout. Pull to try again."
- Pull-to-refresh recovers

---

## 5. Component Inventory

### `TodayView`

Root view. Reads `coachName` from `AuthManager`. Fetches today's workout via `WorkoutService`.

### `WorkoutCard`

Surface card, corner radius 12, border 1px `Colors.border`:

```
┌──────────────────────────────┐
│  [AM] Main Set               │  ← amber badge (8pt) + title (18pt semibold)
│  4 × 100 Free @ threshold   │  ← set description line (13pt muted)
│  8 swimmers · 8 sets           │  ← metadata (12pt dim)
│                              │
│  [      Start Session      ] │  ← full-width cyan button, 56pt tall
└──────────────────────────────┘
```

- AM/PM badge: amber background pill, 8pt, uppercase
- Set description: one line, `distance × stroke @ intensity` — from the first set definition
- Metadata: swimmer count + total sets (from `workout_sets` count query)
- "Start Session" button: same `PrimaryButton` style as Login (cyan fill, glow shadow)
- Tap card title: navigation placeholder (calls out to future `WorkoutDetailView`)

### `EmptyStateView`

Centered icon + text. No button.

### `TabBar`

Bottom `TabView`. No custom styling needed — iOS native tab bar handles it.

---

## 6. Navigation

- **Start Session**: push to `SetPickerView` (the workout's set list — already exists in RN as `/session/set-picker`)
- **Settings tab**: separate tab item
- **Workouts tab**: separate tab item
- **Swimmers tab**: separate tab item

No modal or sheet navigation in I5.

---

## 7. Pull-to-Refresh

Use SwiftUI `.refreshable { }` on the main `List` or `ScrollView`:

```swift
List {
  // workout card
}
.refreshable {
  await loadTodayWorkout()
}
```

---

## 8. File Structure

```
ios-native/Hydrolyze/Sources/
├── App/
│   ├── ContentView.swift         ← update: TabView with 4 tabs
│   └── TodayView.swift           ← main coach home screen
├── Views/
│   ├── Today/
│   │   ├── WorkoutCard.swift      ← single workout card component
│   │   └── EmptyStateView.swift   ← no-workout state
│   └── Auth/                     ← from I4
│       ├── LoginView.swift
│       └── Components/
├── Models/                        ← from I3
├── Services/                     ← from I2/I3
└── Lib/
    └── Color+Hex.swift            ← from I4
```

---

## 9. Out Of Scope

- **WorkoutDetailView** — tap the card title → placeholder, don't build the detail screen yet
- **Create workout** — inline creation in TodayView, put in Workouts tab
- **Calendar view** — future I chunk (see migration plan)

---

## 10. Key Design Decisions

1. **No avatar menu in I5** — simplest nav bar: "TODAY" label + gear icon for settings. Avatar dropdown deferred to Settings chunk.
2. **AM/PM badge** — amber background pill, consistent with RN `today.tsx` card style
3. **Set summary on card** — shows first set's description + total set/swimmer counts. Full set breakdown shown in SetPicker, not here.
4. **Empty state is intentional** — feels designed, not broken. Icon + prose + hint pointing to action.
5. **Pull-to-refresh** — native iOS pattern, `.refreshable { }` on SwiftUI List

---

## 11. RN Parity / Deliberate Divergence

| RN behavior                             | Native decision                      | Reason                                                                      |
| --------------------------------------- | ------------------------------------ | --------------------------------------------------------------------------- |
| `TODAY` label at top of content         | Label moved to nav bar               | iOS convention — nav bar for persistent labels, content for scrollable body |
| No avatar/settings nav                  | Nav bar has gear icon → Settings tab | Settings is a tab, not a sheet — consistent with RN tab structure           |
| No pull-to-refresh                      | `.refreshable { }` added             | Native iOS expectation for data screens                                     |
| Empty hint "Create one in Workouts tab" | "Tap Workouts to schedule one"       | Active hint, same destination                                               |

---

_Designer: Hydrolyze Senior Designer_
_Plan absolute path: `/Users/nathanmaxwell/Downloads/Hydrolyze 2/plans/today-view-design-spec.md`_
_Plan relative path: `plans/today-view-design-spec.md`_
