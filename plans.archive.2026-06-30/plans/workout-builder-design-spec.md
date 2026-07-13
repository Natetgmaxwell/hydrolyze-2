# I7 Workout Builder + Set Schedule Design Spec — Native SwiftUI
> **[FROZEN 2026-06-30]** Shipped. See source files for current state. Do not edit without checking the working tree first.

**Chunk:** I7 (set-schedule + workout builder)
**Date:** 2026-05-17
**Status:** Draft — pending user review
**Source:** RN `app/workout/new.tsx` (builder), `app/workout/set-schedule.tsx` (schedule), `plans/native-swift-migration.md` (confirmed I7 scope)

---

## 1. Screen Identity

Two screens:

- **WorkoutBuilderView** — natural language workout creation. Coach types workout text, parser live-renders the parsed tree below, coach saves as draft or schedules immediately.
- **SetScheduleView** — date picker + AM/PM toggle. Presented as a sheet from WorkoutBuilderView after save, or standalone from WorkoutDetailView's "Schedule" action.

Pool-deck ergonomics: coach types on phone one-handed (typing requires two hands — acceptable trade-off). Live preview shows exactly what the workout looks like parsed.

---

## 2. Visual Design

### Color Palette (Swift equivalents from `lib/theme.ts`)

| Role          | Hex       | Usage                          |
| ------------- | --------- | ------------------------------ |
| Background    | `#060e18` | Page background                |
| Surface       | `#0d1b2a` | Text area, cards               |
| Elevated      | `#1a2d42` | Input focus state              |
| Border        | `#2d3e50` | Dividers, borders              |
| Text primary  | `#e2f4fa` | Headings, typed text           |
| Text muted    | `#7a9bb0` | Placeholder, secondary labels  |
| Text dim      | `#4a6572` | Metadata, timestamps           |
| Cyan accent   | `#09d4ee` | CTAs, focus ring, active state |
| Amber         | `#f59e0b` | AM/PM badge, intensity label   |
| Optimal green | `#10b981` | Parsed ✓ indicator             |
| Danger red    | `#ef4444` | Unparsed warning               |

### Typography

| Element          | Font    | Size | Weight   |
| ---------------- | ------- | ---- | -------- |
| Screen label     | System  | 10pt | Semibold |
| Title input      | System  | 17pt | Medium   |
| Workout textarea | System  | 16pt | Regular  |
| Preview spine    | SF Mono | 15pt | Medium   |
| Preview meta     | System  | 13pt | Regular  |
| Button text      | System  | 16pt | Semibold |
| Section label    | System  | 11pt | Semibold |

---

## 3. Layout Structure

### WorkoutBuilderView

```
┌─────────────────────────────────────┐
│  ← Workouts          [Cancel]       │  ← nav bar: back + cancel
│                                     │
│  WORKOUT BUILDER                    │  ← screen label, 10pt semibold
│                                     │
│  ┌─────────────────────────────┐   │
│  │ Workout title (optional)   │   │  ← single-line title input
│  └─────────────────────────────┘   │
│                                     │
│  ┌─────────────────────────────┐   │
│  │ 4×100 free @1:30            │   │  ← multiline textarea
│  │ 4×50 kick fins @1:00       │   │  ← auto-focus on appear
│  │ 200 easy                    │   │  ← cyan focus ring
│  │                             │   │
│  │ [placeholder: example text] │   │
│  └─────────────────────────────┘   │
│                                     │
│  ✓ 4 sets parsed                   │  ← status line (green ✓ or amber ⚠)
│                                     │
│  ┌─ MAIN SET ─────────────────┐   │  ← WorkoutPreview live output
│  │ 4×100m Free @1:30          │   │  ← parsed tree rendered live
│  │ 4×50m Kick · Fins @1:00   │   │
│  │ 200m Easy                  │   │
│  └─────────────────────────────┘   │
│                                     │
│  [     Save Workout          ]     │  ← cyan CTA (or Schedule →)
│  [     Schedule →             ]     │  ← surface button → SetScheduleView
│                                     │
└─────────────────────────────────────┘
```

**Split layout (vertical):**

- Top half: title input + large multiline textarea (60% of content height)
- Bottom half: live `WorkoutPreview` output (scrolls if content taller than remaining space)
- Keyboard-aware: view scrolls when keyboard appears (`.scrollDismissesKeyboard(true)`)
- "Schedule →" button visible only when `ready = true` (at least one parsed set)

**Edit mode:** When `workoutId` is present (navigated from WorkoutDetailView's Edit):

- Pre-fills title and textarea from `workouts.workout_text`
- Button says "Update Workout" not "Save Workout"
- "Schedule →" becomes "Re-schedule →" if workout already has a date

### SetScheduleView (Sheet)

```
┌─────────────────────────────────────┐
│  ─────────── ───────────           │  ← grabber handle
│                                     │
│  Schedule Workout                   │  ← sheet title, 17pt semibold
│                                     │
│  DATE                               │  ← label, 11pt dim
│  ┌─────────────────────────────┐   │
│  │  Saturday, May 17, 2025   ▼ │   │  ← tappable row → DatePicker sheet
│  └─────────────────────────────┘   │
│                                     │
│  SESSION                            │  ← label, 11pt dim
│  [AM]  [PM]                         │  ← toggle pills, full width
│                                     │
│  [    Confirm Schedule    ]         │  ← cyan CTA, disabled until date set
│  [    Save as Draft        ]        │  ← surface button, saves without date
│                                     │
└─────────────────────────────────────┘
```

**Presented as:** `.sheet()` (not fullScreenCover) — coach may want to peek at calendar while filling it in.
**Dismiss behavior:** Swipe down cancels (returns to builder without saving schedule).
**Validation:** Date must be selected before "Confirm Schedule" enables.

---

## 4. Navigation Flow

```
WorkoutsListView
  └── WorkoutDetailView
        └── Edit (WorkoutBuilderView — fullScreenCover or push)
              └── Schedule → (SetScheduleView — sheet)
                    └── Confirm → pop to WorkoutsListView
                          └── (or Save as Draft → pop to detail)

WorkoutsListView
  └── + New button
        └── WorkoutBuilderView (fresh — no workoutId)
              └── Schedule → (SetScheduleView — sheet)
```

---

## 5. Component Inventory

### `WorkoutBuilderView`

| Element           | Spec                                                                                                          |
| ----------------- | ------------------------------------------------------------------------------------------------------------- |
| Title input       | `TextField`, single line, placeholder "Workout title (optional)", 17pt                                        |
| Workout textarea  | `TextEditor`, multiline, min height 160pt, auto-focus on appear, `.autocapitalize(.none) .autocorrect(false)` |
| Focus ring        | Cyan border (2px) on textarea when focused                                                                    |
| Placeholder text  | `"4×100 free @1:30, 4×50 kick fins @1:00, 200 easy\n\nTip: separate sets with commas..."`                     |
| Parse status line | `"✓ N sets parsed"` (green) or `"⚠ N sets need attention"` (amber), 13pt                                      |
| Live preview      | `WorkoutPreview(workout: parsedWorkout)` — same component from I6                                             |
| Save button       | Full-width cyan, 56pt tall, disabled when `!ready`                                                            |
| Schedule button   | Surface button, disabled when `!ready`, title changes contextually                                            |
| Cancel button     | Nav bar trailing, text button, destructive — asks confirmation if input is non-empty                          |

### `SetScheduleView`

| Element              | Spec                                                                                   |
| -------------------- | -------------------------------------------------------------------------------------- |
| Grabber              | Standard `.sheet` grabber (system-provided)                                            |
| Date row             | Tappable `HStack` showing formatted date — opens `DatePicker` inline or new sheet      |
| AM/PM toggle         | Two pills, full-width `HStack`, selected = cyan fill, unselected = surface with border |
| Confirm button       | Full-width cyan, 56pt tall, disabled until date is selected                            |
| Save as Draft button | Surface, text button below confirm                                                     |
| DatePicker           | `.datePickerStyle(.graphical)` in a sheet, or compact inline                           |

### `WorkoutPreview`

**Fully defined in I6** — re-used here without changes. Renders the parsed `Workout` tree (Section → NamedSet → RepGroup) in the same visual language as the RN builder preview.

---

## 6. State & Data Flow

### `WorkoutBuilderViewModel`

```swift
@MainActor
final class WorkoutBuilderViewModel: ObservableObject {
    @Published var title: String = ""
    @Published var workoutText: String = ""
    @Published var parsedWorkout: WorkoutModel? = nil
    @Published var isLoading: Bool = false
    @Published var saveError: String?

    // Navigation args
    var workoutId: String?   // nil = new, non-nil = edit

    // Debounced parse (300ms) as user types
    func parseInput(_ text: String) { ... }

    // Save workflow
    func saveWorkout(coachId: String?) async -> String?  // returns workoutId
    func saveAndSchedule(coachId: String?, date: Date, amPm: String) async -> Bool
    func saveDraft(coachId: String?) async -> String?
}
```

**Parser invocation:** Debounce 300ms after last keystroke. Parse on every change (not just on save) so the coach sees live preview immediately. For performance, the parse runs on the main actor with a lightweight string-parser — no async needed at this scale.

**Empty state:** `parsedWorkout.sections.isEmpty` → show placeholder text in preview area: "Start typing above to see your workout parsed here."

**Error state:** If parser throws (malformed input), show `"⚠ Couldn't parse — check your formatting"` in the status line. Do NOT block saving — coach can save partially parsed workout as draft.

### `SetScheduleViewModel`

```swift
@MainActor
final class SetScheduleViewModel: ObservableObject {
    @Published var selectedDate: Date = Date()
    @Published var amPm: AmPm = .am   // enum { am, pm }

    func confirmSchedule(workoutId: String) async -> Bool
    func saveDraft(workoutId: String) async -> Bool
}
```

**Save order:** Confirm Schedule first saves the schedule to `workouts.scheduled_at` + `workouts.am_pm`, then updates `status = 'scheduled'`. Save as Draft only updates `status = 'draft'` with no date.

---

## 7. Interactions

| Interaction                   | Behavior                                                                  |
| ----------------------------- | ------------------------------------------------------------------------- |
| Type in textarea              | Debounce 300ms → parse → update `WorkoutPreview` live                     |
| Tap Save                      | Insert/update `workouts` row, insert `workout_sets` rows, pop to detail   |
| Tap Schedule →                | Present `SetScheduleView` sheet                                           |
| Confirm Schedule              | Save schedule to DB, pop to detail (or workouts list)                     |
| Save as Draft                 | Save without date, pop to detail                                          |
| Swipe down on sheet           | Cancel — no save                                                          |
| Tap Cancel (nav bar)          | If input non-empty: confirmation alert "Discard changes?" → discard → pop |
| Edit mode (workoutId present) | Pre-fill from `workouts.workout_text`, button says "Update Workout"       |

---

## 8. File Structure

```
ios-native/Hydrolyze/Sources/
├── Views/
│   ├── Workouts/
│   │   ├── WorkoutBuilderView.swift    ← I7: main builder screen
│   │   ├── SetScheduleView.swift       ← I7: date/AM-PM sheet
│   │   ├── WorkoutsListView.swift      ← from I6
│   │   └── WorkoutDetailView.swift     ← from I6
│   └── Today/                          ← from I5
├── ViewModels/
│   ├── WorkoutBuilderViewModel.swift   ← I7: builder state + parse
│   └── SetScheduleViewModel.swift      ← I7: schedule state
├── Models/                             ← from I3
├── Services/                           ← from I2/I3
├── Components/
│   ├── WorkoutPreview.swift             ← from I6 (shared)
│   └── Components/                     ← from I6
└── Lib/
    ├── Color+Hex.swift                  ← from I4
    └── WorkoutParser.swift             ← I7: Swift port of v2 parser (or stub + raw text for MVP)
```

**Parser strategy (flag for Eng-Manager):**

- Option A: Full Swift port of `workout-parser-v2.ts` — most correct, takes time
- Option B: Send raw text to Supabase Edge Function that runs the TS parser — faster to implement, adds latency
- Option C: Stub `WorkoutParser.parse()` that returns an empty `WorkoutModel` with `sections: []` for now, real parse in a later sprint
- **Recommendation for I7:** Option B (Edge Function) is the pragmatic path for I7. Flag this tradeoff clearly. Option A should be scheduled as a dedicated sprint item after I7 to avoid parser work blocking UI progress.

---

## 9. RN Parity / Deliberate Divergence

| RN behavior                                                | Native decision                                     | Reason                                             |
| ---------------------------------------------------------- | --------------------------------------------------- | -------------------------------------------------- |
| `TextInput` multiline (React Native)                       | `TextEditor` (SwiftUI)                              | SwiftUI's text editor for multiline                |
| Live parse on every keystroke                              | Debounce 300ms + parse                              | Avoid over-parsing while typing                    |
| Gear selector chips on each set card                       | Not in builder (gear comes from parser)             | Parser extracts gear; gear override in later chunk |
| "Schedule Workout" and "Save as Draft" as separate buttons | "Schedule →" sheet trigger + "Save Workout" primary | iOS pattern: sheet for date/AM-PM selection        |
| "Fix unparsed sets first" blocking save                    | Allow save with unparsed text as draft              | Coach may intentionally save partial work          |
| Edit pre-fills on appear                                   | Pre-fill from `workouts.workout_text` via `.task`   | SwiftUI `.task` fires on appear                    |
| Cancel asks confirmation if non-empty                      | Same — Alert with "Discard changes?"                | Protect against accidental dismissal               |

---

## 10. Key Design Decisions

1. **Live preview** is the core UX — coach sees parsed workout as they type, no separate preview step.
2. **Split vertical layout** — textarea top (60%), preview bottom (40%). Both scroll independently if content overflows.
3. **Schedule as sheet** — date/AM-PM selection is a modal sheet, not a separate screen. Coach keeps builder context while scheduling.
4. **Save as primary CTA** — "Save Workout" is always visible (unless nothing parsed). "Schedule →" is secondary for coaches who want to schedule immediately.
5. **Debounced parsing** — 300ms debounce balances responsiveness with performance. Parser is synchronous (fast enough at character-count of typical workouts).
6. **Cancel confirmation** — if the coach has typed anything and taps Cancel, confirm they want to discard.
7. **Edit pre-fills** — workoutId passed as environment variable, builder fetches and pre-fills on appear.

---

## 11. Out Of Scope

- **Gear override per rep** — later chunk (after I9 timing screen)
- **Swimmer assignment to workout** — later chunk (I8 attendance)
- **Voice input** — not in I7
- **Workout duplication** — later chunk
- **Full Swift WorkoutParser** — pragmatic stub or Edge Function for I7; full port in follow-up sprint

---

_Designer: Hydrolyze Senior Designer_
_Plan absolute path: `/Users/nathanmaxwell/Downloads/Hydrolyze 2/plans/workout-builder-design-spec.md`_
_Plan relative path: `plans/workout-builder-design-spec.md`_
