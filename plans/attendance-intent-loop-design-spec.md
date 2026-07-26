# Attendance Intent Loop — Design Spec

**Status:** Approved — greenlit 2026-07-26
**Date:** 2026-07-26
**Version target:** v1.17
**Supersedes:** nothing. Extends `originals/hydrolyze-coach-self-mark-attendance-v1` (2026-07-02, brainstorm) into shippable slices.
**v1 → v2:** user answered Q1–Q5 (2026-07-26). Q1 became squad-scoping (needs migration). Q3 became a **standing weekly schedule** — a new table, and the single biggest change from v1. Gap A reframed from bug-fix to coach-configurable squad setting.
**v2 → v3:** §10 decided (option 1, first-run prompt) + user added `squad_session_slot` — the coach defines which sessions the squad offers, and the swimmer's standing schedule is a subset of those. 8 slices, unchanged count.

---

## 0. Grounding note

### What already exists (verified against live DB + codebase, 2026-07-26)

| Layer | Artifact | State |
|---|---|---|
| DB | `swimmer_attendance_intent` (workout_id, swimmer_id, intent, marked_at, source) | **Shipped**, 0 rows |
| DB | RLS: `swimmer_own_intent_policy`, `coach_intent_override_policy` | **Shipped** |
| DB | `groups` (id, coach_id, name), `swimmer_groups` (swimmer_id, group_id) | **Shipped, 0 rows, orphaned** |
| DB | `workouts` — **no `group_id` column** | Gap |
| DB | `coaches.preferences` jsonb | **Shipped**, available |
| Swimmer UI | `Views/Swimmer/SwimmerUpcomingView.swift` + tab | **Shipped** |
| Swimmer svc | `Services/IntentService.swift` | **Shipped, bug** (§2.1) |
| Coach UI | `Views/Today/AttendanceBadge.swift` @ `TodayView:88,156` | **Shipped** |
| Coach svc | `Services/CoachIntentService.swift` incl. `promoteConfirmedToRoster()` | **Shipped, wired wrong** (§2.2) |

**The loop has never run.** 0 intent rows. 0 of 15 swimmers have `auth_id`. No swimmer has ever logged in.

### What does not exist

- Any squad/group data (`groups` and `swimmer_groups` are empty; `workouts` isn't linked to either)
- Any standing weekly schedule concept — **the whole of Q3**
- Any per-squad settings storage

---

## 1. Problem

> "the swimmer users of hydrolyze should be able to give their intention to
> swim certain sessions during the week. this then marks their attendance for
> the coach, instead of the coach having to do it themselves — freeing up
> mental real estate to coach, rather than deal with admin tasks. while also
> narrowing down the population of swimmers [for] the pairing engine. there's
> no point trying to pair a time to a swimmer that's not present at the workout."

Plus, from the Q3 answer:

> "each swimmer should also have their weekly training schedule, which is the
> default (unless they remove themselves for certain sessions)."

That second sentence changes the model. Attendance is no longer *"the swimmer
marks each session."* It is **"the swimmer declares a standing pattern once,
and only touches the app when they deviate from it."**

This is the invert-the-onus heuristic applied to the swimmer as well as the
coach. A swimmer who trains Mon/Wed/Fri AM says so once at signup. After that
they open the app only to say "not Wednesday this week." Steady state is
**zero taps for everyone**.

---

## 2. Current state — the gaps

### 2.1 Gap A: swimmers see each other's intent, uncontrolled

`IntentService.fetchUpcomingWorkouts()` (lines 89–100) fetches intent by
`workout_id` with **no `swimmer_id` filter**, then collapses:

```swift
.in("workout_id", values: ids)                              // ← no swimmer filter
Dictionary(intents.map { ($0.workoutId, $0) },
           uniquingKeysWith: { first, _ in first })         // ← arbitrary winner
```

RLS-only scoping, arbitrary winner. A swimmer can render *someone else's*
intent as their own toggle state.

**Reframed per user direction:** this is both a bug *and* a missing product
control. Some coaches want swimmers to see who else is coming (team feel,
social accountability); others want it private. So: fix the correctness bug
unconditionally, and expose the visibility as a **squad setting**.

### 2.2 Gap B: intent never reaches the pairing engine

`SessionStartViewModel.lockRoster()` order of operations:

```
line 123  selectedSwimmerIds = selectAll()              ← default is maximally WIDE
line 190  selectedSwimmerIds = coach's manual picks
line 200  fetchRecordedTimes(selectedSwimmerIds)        ← predictor pool
line 228  promoteConfirmedToRoster(...)  → returns Void ← intent arrives, goes nowhere
line 258  buildWavePreview(selectedSwimmerIds)          ← still manual
line 447  INSERT wave_assignments                       ← still manual
```

`promoteConfirmedToRoster` upserts `session_roster` and returns nothing.
`selectedSwimmerIds` never updates. `TimingViewModel` reads `wave_assignments`
→ **the pairing engine's candidate pool is the coach's hand-picks.** A swimmer
who marked "out" remains a pairing candidate. A swimmer who marked "in" but
wasn't hand-picked gets no wave slot, so no lap can ever reach them.

---

## 3. Objective

Make attendance the **source of truth for the pairing candidate pool**, driven
by a standing weekly schedule so that in steady state *nobody taps anything*.

### Success criteria

| # | Criterion | Verified by |
|---|---|---|
| S1 | A swimmer sets a standing weekly schedule (e.g. Mon/Wed/Fri AM); it persists | DB rows in `swimmer_training_schedule` |
| S2 | A workout matching a swimmer's standing schedule shows as **attending by default**, with no tap | Swimmer UI screenshot + resolver unit test |
| S3 | A swimmer opts out of one session; only that session flips | DB: 1 intent row, `intent='out'`; schedule untouched |
| S4 | A swimmer never sees another swimmer's intent when squad visibility is `private` | 2-swimmer unit test |
| S5 | When squad visibility is `squad`, a swimmer sees the attending roster | UI screenshot |
| S6 | Swimmers see only workouts for squads they belong to | Query test w/ 2 groups |
| S7 | Coach opens Today; badge reads "N of M attending" with zero coach input | Screenshot |
| S8 | Coach taps Start; `selectedSwimmerIds` pre-seeded from resolved attendance, not `selectAll()` | `SessionStartViewModel` unit test |
| S9 | `wave_assignments` contains **only** resolved-attending swimmers | Live DB query post-session |
| S10 | An 'out' swimmer can never receive a lap, even with a decoy time near their prediction | `PairingEngineCLITest` "v1.17 INTENT NARROWING" |
| S11 | Coach override beats both schedule and swimmer intent | Unit test |
| S12 | A workout with zero schedules and zero intents behaves exactly as today | Existing CLI scenarios pass |

---

## 4. Data model

### 4.1 The resolver — the core new concept

"Is swimmer X attending workout W?" is now a **derived** answer with a strict
precedence chain:

```
1. Coach's in-session picker edit          → wins outright (not persisted as intent)
2. Explicit intent row (W, X)              → 'in' or 'out'      [source: swimmer|coach]
3. Standing schedule matches (weekday(W.scheduled_at), W.am_pm) → 'in'
4. Otherwise                                → 'out'
```

Rule 3 is the whole Q3 answer. Rule 4 is Q2. Together they mean: **explicit
beats standing, standing beats nothing, nothing means out.**

Escape hatch (unchanged from v1 D2): if a workout resolves to **zero**
attending swimmers *and* the squad has no schedules and no intents at all,
`SessionStartView` falls back to `selectAll()`. Prevents an empty roster for a
coach who hasn't onboarded swimmers. This is the `spec-to-ship`
"active state prerequisites" rule.

### 4.2a New table: `squad_session_slot` (coach-defined availability)

The coach declares which sessions the squad *offers*. The swimmer's standing
schedule is a **subset of these slots** — not free-form. This removes a whole
class of nonsense (a swimmer marking Sunday PM when the squad never trains
Sunday PM) and gives `MyScheduleView` a real grid to render instead of a blank
7×2 matrix.

```sql
CREATE TABLE squad_session_slot (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id    uuid NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  weekday     smallint NOT NULL CHECK (weekday BETWEEN 0 AND 6),  -- 0=Sunday
  am_pm       text NOT NULL CHECK (am_pm IN ('AM','PM')),
  label       text,          -- optional: "Distance", "Sprint", "Skills"
  active      boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (group_id, weekday, am_pm)
);
```

Coach-owned (RLS: coach writes own squads; squad members read). This is the
**squad's weekly template** — distinct from `workouts`, which are the actual
dated instances the coach schedules and parses.

### 4.2b New table: `swimmer_training_schedule`

```sql
CREATE TABLE swimmer_training_schedule (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  swimmer_id  uuid NOT NULL REFERENCES swimmers(id) ON DELETE CASCADE,
  weekday     smallint NOT NULL CHECK (weekday BETWEEN 0 AND 6),  -- 0=Sunday, matches Cal
  am_pm       text NOT NULL CHECK (am_pm IN ('AM','PM')),
  active      boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (swimmer_id, weekday, am_pm)
);
```

One row per slot the swimmer normally attends. Mon/Wed/Fri AM = 3 rows.
`active` allows a soft pause (injury, off-season) without losing the pattern.

`weekday` + `am_pm` matches the existing `workouts.scheduled_at` (DATE) +
`workouts.am_pm` (`'AM'|'PM'`) pair exactly — no new time model, no timezone
math. `am_pm` is nullable on `workouts` today; a NULL-`am_pm` workout matches
**any** schedule row for that weekday (permissive, since the coach didn't
specify a slot).

### 4.3 Squad scoping (Q1)

```sql
ALTER TABLE workouts ADD COLUMN group_id uuid REFERENCES groups(id) ON DELETE SET NULL;
```

A workout with `group_id IS NULL` is visible to **all** of that coach's
swimmers (backward-compatible: all 14 existing workouts stay visible).
A workout with a `group_id` is visible only to swimmers in that group.

`groups` and `swimmer_groups` are empty, so Slice 1 seeds one default squad
per coach and enrolls all existing swimmers. Nothing changes visibly; the
scaffolding just becomes real.

### 4.4 Squad settings (Gap A)

```sql
ALTER TABLE groups ADD COLUMN settings jsonb NOT NULL DEFAULT '{}'::jsonb;
```

v1 key:

```json
{ "attendance_visibility": "private" }   // "private" | "squad"
```

- `private` (default) — a swimmer sees only their own intent.
- `squad` — a swimmer additionally sees who else is attending each session.

Correctness is **not** governed by this setting. The `swimmer_id` filter is
applied unconditionally to the swimmer's *own* toggle state; `squad` mode adds
a separate read of the roster, it does not loosen the self-scoping.

`groups.settings` rather than `coaches.preferences` because the control is
per-squad — a coach may run an open senior squad and a private junior squad.

---

## 5. Components affected

| File | Change | Slice |
|---|---|---|
| `supabase/migrations/` | `swimmer_training_schedule`, `workouts.group_id`, `groups.settings`, indexes, RLS | 1 |
| `supabase/migrations/` | Seed default squad per coach + enroll swimmers | 1 |
| `Models/` (new) `TrainingSchedule.swift` | Model + weekday enum | 2 |
| `Services/` (new) `ScheduleService.swift` | CRUD on standing schedule | 2 |
| `Services/` (new) `AttendanceResolver.swift` | The §4.1 precedence chain, one function | 3 |
| `Services/IntentService.swift` | `swimmer_id` filter; squad scoping; drop 7-day cap; use resolver | 3 |
| `Services/CoachIntentService.swift` | Return `[String]`; add `fetchResolvedAttendance(workoutId:)` | 4 |
| `ViewModels/SessionStartViewModel.swift` | Seed `selectedSwimmerIds` from resolver; reorder promotion | 5 |
| `Views/SessionStart/SessionStartView.swift` | Chip provenance: standing / marked / coach-added | 5 |
| `Views/Swimmer/SwimmerUpcomingView.swift` | Show resolved state + provenance; squad roster when enabled | 6 |
| `Views/Swimmer/` (new) `MyScheduleView.swift` | Weekly grid to set the standing pattern | 6 |
| `Views/Coach/` (squad settings) | `attendance_visibility` toggle | 7 |
| `Tests/CLI/PairingEngineCLITest.swift` | "v1.17 INTENT NARROWING" scenario | 8 |

**`PairingEngine.swift` and `HungarianMatching.swift` — untouched.** Narrowing
happens upstream by handing the engine a smaller input set.

---

## 6. Design decisions

**D1 — Intent pre-seeds the picker; it does not lock it.** Coach can still add
or remove anyone. Preserves "Coach is the authority" while removing the N taps.
Coach does nothing → the resolved set ships.

**D2 — Explicit beats standing beats nothing.** §4.1. A per-session opt-out is
a single intent row; the standing pattern is never mutated by a one-off.

**D3 — Narrowing enforced at `selectedSwimmerIds`, not in the engine.** One
choke point; roster insert, PB fetch, times fetch, wave preview,
`wave_assignments`, `coarsePredictions` and the cost matrix all already derive
from it. Zero engine risk.

**D4 — Coach override wins, always.** `source='coach'` overwrites the swimmer
row; the picker edit beats both because it is the last write before Start.

**D5 — No notifications in v1.** No push infra. Deferred.

**D6 — No horizon cap (Q3).** The 7-day window is removed. The swimmer sees
every future scheduled workout for their squad. With standing schedules doing
the defaulting, a long list is cheap — the swimmer only touches deviations.

**D7 — Squad visibility never loosens self-scoping.** §4.4. The setting adds a
roster read; it never widens the query that determines the swimmer's own state.

---

## 7. Implementation slices

Each slice = one commit, independently verifiable.
`bash scripts/build-verify.sh` between every slice from Slice 2 onward.

### Slice 1 — Migrations + squad backfill (SQL only)
- `squad_session_slot` table + RLS (coach writes own squads; squad members read).
- `swimmer_training_schedule` table + RLS (swimmer writes own; coach reads own swimmers').
- `workouts.group_id`, `groups.settings jsonb`.
- Indexes: `swimmer_attendance_intent(workout_id)`, `swimmer_training_schedule(swimmer_id)`, `squad_session_slot(group_id)`, `workouts(group_id, scheduled_at)`.
- Seed one default squad per coach; enroll all 15 existing swimmers; seed Mon–Fri AM slots so the swimmer grid is never empty; leave all 14 existing workouts `group_id NULL` (visible to all).
- **Verify:** live queries — tables exist, RLS present, 1 group, 15 `swimmer_groups` rows, 5 slot rows.
- **Commit:** `v1.17 Slice 1: squad session slots, standing schedules, squad scoping + settings`

### Slice 2 — Schedule models + services
- `Models/TrainingSchedule.swift` (`SquadSessionSlot`, `SwimmerTrainingSchedule`, weekday enum).
- `Services/ScheduleService.swift` — squad slots (read) + swimmer standing schedule (fetch / set / clear).
- **Verify:** `build-verify.sh` + live round-trip write/read.
- **Commit:** `v1.17 Slice 2: ScheduleService — squad slots + standing weekly pattern`

### Slice 3 — The resolver + fix the swimmer read
- `Services/AttendanceResolver.swift` implementing §4.1 as one pure function over (workout, intents, schedules).
- `IntentService`: add `.eq("swimmer_id", …)` from `AuthManager`; scope workouts by squad; drop the 7-day cap; drop the `uniquingKeysWith` collapse.
- **Verify:** two-swimmer unit test (S4), resolver truth-table test covering all four precedence rules.
- **Commit:** `v1.17 Slice 3: AttendanceResolver + scope swimmer intent reads correctly`

### Slice 4 — Coach-side resolved attendance
- `CoachIntentService.promoteConfirmedToRoster()` → returns `[String]`.
- New `fetchResolvedAttendance(workoutId:) -> (attending: [String], out: [String], unmarked: [String])` using the resolver.
- `AttendanceBadge` counts come from the resolver (standing-schedule swimmers now counted without an intent row).
- **Verify:** `build-verify.sh` + live query on the scheduled workout.
- **Commit:** `v1.17 Slice 4: coach-side resolved attendance`

### Slice 5 — Seed the picker (the vision slice)
- `SessionStartViewModel.load()`: seed `selectedSwimmerIds` from `fetchResolvedAttendance().attending`; apply the §4.1 zero-attendance fallback.
- Move `promoteConfirmedToRoster` **before** the roster insert; union its result into `selectedSwimmerIds` before `selectedSwimmers` is derived.
- `SessionStartView`: chip provenance — standing schedule / self-marked / coach-added / excluded.
- **Verify:** `build-verify.sh` + S8 unit test.
- **Commit:** `v1.17 Slice 5: seed the session roster from resolved attendance`

### Slice 6 — Swimmer-facing schedule UI + first-run prompt
- `MyScheduleView`: renders the **squad's** `squad_session_slot` grid; tap to toggle which slots you normally attend. Not a blank 7×2 — only sessions the squad actually offers.
- First-run: a swimmer with zero `swimmer_training_schedule` rows sees this once on login, skippable (§10).
- `SwimmerUpcomingView`: resolved state with provenance ("from your schedule" vs "you marked this"); one-tap opt out; squad roster when `attendance_visibility == 'squad'`.
- **Verify:** `build-verify.sh` + screenshots.
- **Commit:** `v1.17 Slice 6: MyScheduleView, first-run prompt, resolved-state upcoming`

### Slice 7 — Coach-side squad settings + session slots
- Coach editor for `squad_session_slot` — the squad's weekly template ("we train Mon/Wed/Fri AM + Tue PM"). This is the prerequisite that makes Slice 6's grid meaningful.
- Toggle for `attendance_visibility` on the squad.
- **Verify:** `build-verify.sh` + round-trip to `squad_session_slot` and `groups.settings`.
- **Commit:** `v1.17 Slice 7: coach-defined squad session slots + visibility setting`

### Slice 8 — Prove the narrowing, then end-to-end
- `PairingEngineCLITest` scenario **"v1.17 INTENT NARROWING"**: 12 swimmers — 6 attending via standing schedule, 2 explicit 'in', 2 explicit 'out', 2 unmarked-and-unscheduled. Assert the engine receives exactly 8, and the 4 excluded appear in **zero** assignments even with a decoy lap placed near their predicted time.
- Then live: invite one seeded swimmer, log in on the simulator, set a standing schedule, opt out of one session, verify badge → picker → `wave_assignments`.
- **Verify:** CLI harness green (new + all prior scenarios) + live DB queries + screenshots.
- **Commit:** `v1.17 Slice 8: CLI narrowing scenario + end-to-end live verification`

---

## 8. Decisions (2026-07-26)

User answers, locked:

| # | Question | Decision |
|---|---|---|
| Gap A | Swimmer-sees-swimmer intent | Fix the correctness bug unconditionally; expose visibility as a **squad setting** (`groups.settings.attendance_visibility`, default `private`) |
| Gap B | Intent → pairing engine | **Ship it.** Slice 5 is the choke point |
| Q1 | Workout visibility | **Squad-scoped.** `workouts.group_id`; NULL = all of the coach's swimmers |
| Q2 | Unmarked swimmer | **Out** — with the standing schedule now supplying the default, and the zero-attendance fallback intact |
| Q3 | Marking horizon | **Unbounded.** Plus a **standing weekly schedule** per swimmer as the default; the swimmer only acts to deviate |
| Q4 | Coach override | **Overwrite.** `source='coach'`, no history table |
| Q5 | Post-start changes | **Allowed, ignored.** Roster is a START snapshot |

### Scope change from v1

Q3's second sentence turned a filter into a subsystem. v1 was 5 slices; v2 is 8.
The added surface is: one table, one service, one resolver, one swimmer-facing
screen. The resolver is the load-bearing piece — everything else is CRUD around it.

---

## 9. Boundaries

**Always:** `scripts/build-verify.sh` between slices · one commit per slice ·
name deviations in the commit message · verify every DB claim with a live query.

**Ask first:** any change to `PairingEngine.swift` / `HungarianMatching.swift` ·
any destructive migration · any change to auth or existing RLS policies ·
anything that would hide existing workouts from existing swimmers.

**Never:** rewrite the pairing engine to "understand" attendance · introduce
coach-facing vocabulary like "intent" / "claim" / "state" (the coach sees
"attending") · a modal sheet for attendance confirmation · delete
`session_roster` rows for a completed session · mutate a swimmer's standing
schedule as a side effect of a one-off opt-out.

---

## 10. First-run schedule setup — DECIDED

**Option 1, locked (2026-07-26).** A swimmer with no standing schedule is
prompted on first login with the squad's weekly grid (from `squad_session_slot`),
taps the slots they normally attend, done. One screen, ~10 seconds, skippable.

**Plus the coach-side prerequisite the user added:** the coach defines the
squad's available sessions (`squad_session_slot`, §4.2a) — the swimmer picks
from that grid rather than a blank 7×2. Coach-side editor ships in Slice 7,
swimmer-side first-run prompt in Slice 6.

Dependency: a squad with **no** `squad_session_slot` rows shows the swimmer an
empty grid. Slice 1 seeds a sensible default (Mon–Fri AM) for the backfilled
default squad so the flow is never dead on arrival. Coach edits from there.

