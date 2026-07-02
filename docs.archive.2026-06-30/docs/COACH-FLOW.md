# Hydrolyze 2 — Coach App Workflow Design

**Status:** Draft
**Last updated:** 2026-04-27

---

## Overview

A tab-based mobile app for swim coaches. Three tabs: **Today**, **Workouts**, **Swimmers**. Auth via Google or Apple Sign-In. Multi-team: each coach owns their swimmers, groups, and workouts. Past workouts are visible and accessible.

---

## Tab Navigation

```
┌──────────────────────────────────────────┐
│  [Today]     [Workouts]     [Swimmers]    │  ← Tab bar (bottom)
└──────────────────────────────────────────┘
```

Each tab is a Stack Navigator with its own screens. Tabs persist; navigating within a tab pushes onto its stack.

---

## Auth Flow

### Entry point: /login
First launch → `/login`

```
┌──────────────────────────┐
│                          │
│      HYDROLYZE           │
│   Swim coaching, timed.   │
│                          │
│  ┌──────────────────┐   │
│  │  Sign in with    │   │  ← Apple button (top, most common)
│  │  Apple            │   │
│  └──────────────────┘   │
│                          │
│  ┌──────────────────┐   │
│  │  Sign in with    │   │  ← Google button
│  │  Google           │   │
│  └──────────────────┘   │
│                          │
│   By continuing, you     │
│   agree to our Terms.    │
└──────────────────────────┘
```

### Post-auth check
After sign-in → check if coach record exists in `coaches` table:
- **No record:** → `/onboarding`
- **Has record:** → `/today` (main tab)

### Onboarding: /onboarding
Only runs once. Three steps:

**Step 1: Your name**
- Text input: "What should we call you?"
- Saves to `coaches.name`
- "Continue →"

**Step 2: Add swimmers**
- Text area: "Add your swimmers — one name per line"
- Placeholder: "Alice\nBob\nCharlie"
- "Add" → bulk inserts to `swimmers` table with `coach_id`
- Shows count: "12 swimmers added"
- "Continue →"

**Step 3: Create your first workout (optional)**
- Skippable
- If coach enters text → Workout Builder flow → saved as draft
- If skipped → saved as empty coach record → `/today`

After onboarding → `/today`

---

## Tab 1: Today

**Purpose:** Shows the next scheduled workout for today (or the next upcoming workout if none today). Coach taps a set → goes to timing. All sets are completed → session summary.

### /today (main screen)

```
┌──────────────────────────┐
│  TODAY                    │
│  Mon, Apr 27 · AM         │
├──────────────────────────┤
│                          │
│  Monday AM — Free + IM   │
│  6 swimmers · 3 groups    │
│                          │
│  ┌──────────────────────┐ │
│  │  ✓ 4×100 free paddles │ │  ← Completed set (tappable to review)
│  └──────────────────────┘ │
│  ┌──────────────────────┐ │
│  │  ● 8×25 sprint @20s  │ │  ← Current set (highlighted)
│  └──────────────────────┘ │
│  ┌──────────────────────┐ │
│  │  ○ 4×50 kick fins    │ │  ← Upcoming set
│  └──────────────────────┘ │
│  ┌──────────────────────┐ │
│  │  ○ 200 easy form     │ │
│  └──────────────────────┘ │
│                          │
│  ───────────────────────  │
│  Groups present:          │
│  [Gold ✓] [Juniors ✓]     │  ← Tap to toggle attendance
│                          │
│  [▶ Start 8×25 sprint]   │  ← CTA to timing screen
│                          │
└──────────────────────────┘
```

**State A: No workout today**
- Shows next upcoming workout (date + title)
- "No session today — next: Monday PM"
- Quick action: "Start without a workout" (for unscheduled practice)

**State B: All sets complete**
- All sets show ✓
- "Session Complete" banner
- "View Summary" → `/today/summary`

### /today/attendance
Group-based attendance. Coach toggles groups present, not individual swimmers.

```
┌──────────────────────────┐
│  ATTENDANCE              │
│  Tap to mark present     │
├──────────────────────────┤
│                          │
│  Gold ✓                  │  ← Tapped = present (dimmed)
│  ┌──────────────────────┐│
│  │ Alice  Bob  Carl     ││
│  │ Dave   Emma          ││
│  └──────────────────────┘│
│                          │
│  Juniors                 │
│  ┌──────────────────────┐│
│  │ Frank  Gina  Hank   ││
│  │ Ivy                    ││
│  └──────────────────────┘│
│                          │
│  ───────────────────────  │
│  Sprinters                │
│  ┌──────────────────────┐│
│  │ Jack   Kate          ││
│  └──────────────────────┘│
│                          │
│  [Continue →]            │
│                          │
└──────────────────────────┘
```

**Behavior:**
- Tapping a group marks all swimmers in that group as present
- Swimmers appear under groups (multi-group swimmers appear under each)
- Ungrouped swimmers shown in "Other" section
- Attendance is remembered for this session (can be adjusted mid-session)

### /today/set-picker
Intermediate screen before timing. Shows all sets, tap to select.

```
┌──────────────────────────┐
│  SELECT A SET            │
│  Tap to start timing     │
├──────────────────────────┤
│                          │
│  1. 4×100 free paddles   │
│     on 1:30              │
│  2. 8×25 sprint @20s     │  ← This is the next incomplete set
│  3. 4×50 kick fins       │
│  4. 200 easy form        │
│                          │
└──────────────────────────┘
```

Tap any set → `/today/timing?setId=X`

### /today/timing
Live stopwatch + LAP button. Algorithm auto-assigns times.

```
┌──────────────────────────┐
│  8×25 SPRINT            │
│  Rep 2 of 8 · @20s      │
├──────────────────────────┤
│                          │
│         00:14.32         │  ← Live stopwatch
│                          │
│  ┌──────────────────┐   │
│  │       LAP        │   │  ← Big button, one tap per swimmer
│  └──────────────────┘   │
│                          │
│  Times this rep:         │
│  ┌──────────────────┐   │
│  │ Alice  14.32  ✓  │   │
│  │ Bob    14.87  ✓  │   │
│  │ Carl   15.01     │   │  ← Unassigned (tap to fix)
│  │ Dave   14.45  ✓  │   │
│  └──────────────────┘   │
│                          │
│  Swimmers present: 4/6   │
│  [Rep complete →]       │
│                          │
└──────────────────────────┘
```

**Behavior:**
- LAP tap: records `Date.now() - startTime`, runs assignment algorithm
- Assigned swimmers show name + time + ✓
- Unassigned times show time only → tap to open swap modal
- Rep complete → advance to next rep (or next set)
- If all reps done → prompt to proceed to next set

### /today/swap
Modal for fixing wrong assignments.

```
┌──────────────────────────┐
│  FIX ASSIGNMENT          │
│  Tap time, tap swimmer   │
├──────────────────────────┤
│                          │
│  Unassigned time:        │
│  ┌──────────────────┐   │
│  │     15.34        │   │  ← Tap to select
│  └──────────────────┘   │
│                          │
│  Assign to:              │
│  [Alice] [Bob] [Carl]    │
│  [Dave]  [Emma] [Frank]  │
│                          │
│  Or:                     │
│  [Discard this time]    │
│                          │
└──────────────────────────┘
```

### /today/summary
Post-session summary.

```
┌──────────────────────────┐
│  SESSION COMPLETE        │
│  Monday AM · 4×100 free  │
├──────────────────────────┤
│                          │
│  Times recorded: 24      │
│  Auto-assigned: 22       │
│  Manual fixes: 2         │
│                          │
│  ┌──────────────────┐   │
│  │ View times →     │   │
│  └──────────────────┘   │
│                          │
│  [Back to Today]         │
│                          │
└──────────────────────────┘
```

---

## Tab 2: Workouts

**Purpose:** All workouts — scheduled, draft, and past. Create, edit, schedule, delete.

### /workouts (main screen)

```
┌──────────────────────────┐
│  WORKOUTS                │
│  [All] [Scheduled] [Drafts]│  ← Filter pills
├──────────────────────────┤
│                          │
│  UPCOMING                 │
│  ───────────────────────  │
│  Mon, Apr 27 · AM        │
│  Monday AM — Free + IM   │
│  4 sets                  │
│                          │
│  Wed, Apr 29 · PM        │
│  Wednesday PM — Sprint   │
│  6 sets                  │
│                          │
│  ───────────────────────  │
│  DRAFTS                  │
│  ───────────────────────  │
│  Thursday AM (unsched.)  │
│  2 sets                  │
│                          │
│  ───────────────────────  │
│  PAST                    │
│  ───────────────────────  │
│  Fri, Apr 25 · AM        │
│  Friday AM — IM Set      │
│  8 sets · complete       │
│                          │
│  Sun, Apr 20 · AM        │
│  Sunday AM — Distance    │
│  5 sets · complete       │
│                          │
└──────────────────────────┘
```

**Workout card actions:**
- Tap → view/edit (if draft) or view (if scheduled/past)
- Long-press → context menu: Edit, Schedule, Delete
- Swipe left → quick delete (with confirm)

### /workouts/new (Workout Builder)

Same as existing `/workout/new` but with two save options:

```
┌──────────────────────────┐
│  WORKOUT BUILDER         │
│  [Save Draft] [Schedule] │
├──────────────────────────┤
│                          │
│  [Title input]            │
│                          │
│  [NL input area]          │
│                          │
│  Set preview cards...     │
│                          │
└──────────────────────────┘
```

- **Save Draft:** saves as `status: 'draft'`, no scheduled date
- **Schedule:** opens day/AM-PM picker → saves as `status: 'scheduled'`, with `scheduled_at` + `am_pm`

### /workouts/schedule-picker (modal)

```
┌──────────────────────────┐
│  SCHEDULE WORKOUT        │
│  ─────────────────────── │
│  [AM] [PM]               │  ← Toggle
│  ─────────────────────── │
│  [Calendar picker]       │
│  Apr 28  Apr 29  Apr 30   │
│  May 1   May 2   May 3    │
│                          │
│  [Save]                  │
└──────────────────────────┘
```

### /workouts/[id] (Edit Workout)

Full edit screen. Same as builder but:
- Pre-populated with existing data
- NL input editable (re-parse on save)
- Sets list editable (delete set, reorder)
- Title editable
- Scheduled date editable (or unschedule → draft)

### /workouts/delete-confirm (modal)

```
┌──────────────────────────┐
│  DELETE WORKOUT?        │
│  ─────────────────────── │
│  Monday AM — Free + IM  │
│  4 sets will be removed  │
│                          │
│  [Keep as draft]         │
│  [Delete permanently]    │  ← Destructive, red
│  [Cancel]                │
└──────────────────────────┘
```

Two options:
- **Keep as draft:** changes `status` to `'draft'`, clears `scheduled_at`
- **Delete permanently:** hard delete from DB

---

## Tab 3: Swimmers

**Purpose:** Manage swimmers and groups. Swimmers can belong to multiple groups.

### /swimmers (main screen)

```
┌──────────────────────────┐
│  SWIMMERS                │
│  [Add swimmer] [+ Group]  │  ← Header actions
├──────────────────────────┤
│                          │
│  Gold                     │
│  ┌──────────────────────┐│
│  │ Alice  12 PB         ││  ← Tap → swimmer detail
│  │ Bob    8 PB          ││
│  │ Carl   15 PB         ││
│  │ Dave   6 PB          ││
│  │ Emma   9 PB          ││
│  └──────────────────────┘│
│  [Rename] [Delete group] │  ← Group actions
│                          │
│  ─────────────────────── │
│  Juniors                  │
│  ┌──────────────────────┐│
│  │ Frank   4 PB          ││
│  │ Gina    7 PB         ││
│  │ Hank   10 PB          ││
│  └──────────────────────┘│
│                          │
│  ─────────────────────── │
│  No group                 │
│  ┌──────────────────────┐│
│  │ Ivy     2 PB          ││  ← Ungrouped swimmers
│  │ Jack    5 PB          ││
│  └──────────────────────┘│
│                          │
└──────────────────────────┘
```

**Swimmer row:** shows name + PB count + chevron
**Swimmer tap:** → `/swimmers/[id]`

### /swimmers/add (modal)

```
┌──────────────────────────┐
│  ADD SWIMMERS            │
│  One name per line       │
│  ─────────────────────── │
│  Alice                   │
│  Bob                     │
│  Carl                    │
│  Dave                    │
│                          │
│  [Add swimmers]          │
│                          │
└──────────────────────────┘
```

After adding → group assignment screen:
- Checkboxes for existing groups
- "Assign to selected groups"
- Swimmers created with group memberships

### /swimmers/[id] (Swimmer Detail)

```
┌──────────────────────────┐
│  ALICE                   │
│  ─────────────────────── │
│  Groups: [Gold] [Juniors] │  ← Tap to remove
│  ─────────────────────── │
│  PERSONAL BESTS          │
│  ─────────────────────── │
│  100 Free  1:02.34       │
│  200 Free  2:15.67       │
│  100 Back   1:15.89      │
│  ─────────────────────── │
│  GEAR AVERAGES           │
│  ─────────────────────── │
│  Paddles (100 Free)      │
│  mean: 1:03.20           │
│  stddev: 1.2s            │
│  n=12                    │
│  ─────────────────────── │
│  RECENT TIMES            │
│  ─────────────────────── │
│  Apr 25 · 4×100 paddles  │
│  1:03.01  1:02.89        │
│  1:03.45  1:02.77        │
│  ─────────────────────── │
│  [Edit swimmer] [Delete]  │
│                          │
└──────────────────────────┘
```

**Edit swimmer:** name field, group reassignment
**Delete swimmer:** confirm modal → soft delete

### Group management

**Create group:**
```
┌──────────────────────────┐
│  NEW GROUP               │
│  [Name input]            │
│  [Create]                │
└──────────────────────────┘
```

**Rename group:**
- Long-press group → context menu → Rename

**Delete group:**
- Long-press group → context menu → Delete
- Swimmers remain, group membership removed
- "Delete group 'Gold'? 5 swimmers will be ungrouped."

---

## Data Model Changes

### New tables

```sql
-- Coaches (one per auth user)
coaches (
  id uuid PK DEFAULT gen_random_uuid(),
  auth_id uuid UNIQUE NOT NULL,  -- Supabase auth.users.id
  name text,
  created_at timestamptz DEFAULT now()
)

-- Swimmer-group memberships (many-to-many)
swimmer_groups (
  swimmer_id uuid FK → swimmers.id,
  group_id uuid FK → groups.id,
  PRIMARY KEY (swimmer_id, group_id)
)

-- Groups
groups (
  id uuid PK DEFAULT gen_random_uuid(),
  coach_id uuid FK → coaches.id,
  name text NOT NULL,
  created_at timestamptz DEFAULT now(),
  UNIQUE (coach_id, name)  -- no duplicate group names per coach
)

-- Sessions (each timing run = one session)
sessions (
  id uuid PK DEFAULT gen_random_uuid(),
  workout_id uuid FK → workouts.id,
  started_at timestamptz,
  completed_at timestamptz,
  status text DEFAULT 'in_progress'  -- in_progress | complete
)

-- Recorded times (now linked to sessions too)
recorded_times (
  id uuid PK DEFAULT gen_random_uuid(),
  session_id uuid FK → sessions.id,
  workout_set_id uuid FK → workout_sets.id,
  swimmer_id uuid FK → swimmers.id,
  rep_index integer,
  time_ms integer NOT NULL,
  assignment_confidence float,
  source text DEFAULT 'auto',  -- auto | manual | unassigned
  recorded_at timestamptz DEFAULT now()
)
```

### Modified existing tables

```sql
-- workouts: add status + scheduled_at
workouts (
  status text DEFAULT 'draft',  -- draft | scheduled | in_progress | complete
  scheduled_at date,
  am_pm text  -- 'AM' | 'PM'
)

-- swimmers: add coach_id
swimmers (
  coach_id uuid FK → coaches.id
)

-- workout_sets: add workout_id FK
workout_sets (
  workout_id uuid FK → workouts.id
)
```

### Supabase Auth setup

```sql
-- Enable OAuth providers
-- In Supabase dashboard: Auth > Providers
-- Enable: Apple, Google

-- RLS policies (example)
CREATE POLICY "Coaches see own data"
  ON coaches FOR ALL
  USING (auth.uid() = coach_id);

CREATE POLICY "Swimmers belong to coach"
  ON swimmers FOR ALL
  USING (coach_id = (
    SELECT coach_id FROM coaches WHERE auth_id = auth.uid()
  ));

CREATE POLICY "Groups belong to coach"
  ON groups FOR ALL
  USING (coach_id = (
    SELECT coach_id FROM coaches WHERE auth_id = auth.uid()
  ));

CREATE POLICY "Workouts belong to coach"
  ON workouts FOR ALL
  USING (coach_id = (
    SELECT coach_id FROM coaches WHERE auth_id = auth.uid()
  ));
```

---

## Key Interactions

### Wave support (deferred)
- Wave toggle on attendance screen
- If Wave 2: times collected, corrected by +10s, then assigned
- Both waves' corrected times go into same pool
- UI: "Wave 2" badge visible during Wave 2 timing

### Workout sharing (future)
- Coach A shares a workout → Coach B imports it
- For now: workouts are private to each coach

---

## Screen Map

```
/login
/onboarding
  /onboarding/step-1  (name)
  /onboarding/step-2  (swimmers)
  /onboarding/step-3  (first workout — optional)
/today
  /today/attendance
  /today/set-picker
  /today/timing
  /today/swap
  /today/summary
/workouts
  /workouts/new
  /workouts/schedule-picker
  /workouts/[id]
  /workouts/delete-confirm
/swimmers
  /swimmers/add
  /swimmers/[id]
```

---

## Open Questions

| Question | Decision needed |
|----------|----------------|
| Delete workout: archive vs hard delete? | User choice in delete modal |
| Swimmer detail: edit gear averages? | No — computed from times, not editable |
| Past workout re-open for re-timing? | Yes — tap past workout → set picker → new session |
| Import swimmers via CSV? | v2 |
| Restrict to 2 groups max per swimmer? | No limit in v1 |
| Coach can have assistants? | v2 |

---

## Implementation Priority

1. **Auth** — OAuth + coaches table + RLS policies
2. **Swimmers CRUD** — tab, add, groups, detail screen
3. **Workouts list** — tab, filter, long-press actions
4. **Workout Builder** — schedule flow, edit flow, delete flow
5. **Today tab** — next workout display, attendance (group-based), set picker
6. **Timing** — stopwatch, LAP, assignment, swap modal
7. **Onboarding** — coach name, swimmer add, first workout
