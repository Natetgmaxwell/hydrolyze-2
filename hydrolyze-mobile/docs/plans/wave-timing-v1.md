# Wave Timing v1

**Status:** drafted, awaiting user review
**Branch:** `coach-app-v2`
**Driver:** Office Hours (formerly Orchestrator)

> When a coach has more swimmers than lanes (e.g. 7 swimmers, 4 lanes), the
> swimmers must be sent in waves with a coach-set delay between them. v1 makes
> that flow first-class on `timing.tsx`: PB-based seeding, a single master
> clock, sacred volume-button laps, an explicit on-screen "Send Wave 2" launch,
> and a post-heat reconciliation screen that turns rough taps into clean,
> attributed times.

---

## 1. User flow (the spine)

One coach, one set, one heat — end to end. Every screen and every interaction
in the rest of this document hangs off this walkthrough.

### Pre-heat

1. Coach finishes attendance and picks a set on `set-picker.tsx`. The app
   computes how many waves are needed: `ceil(present_swimmers / lanes)`.
2. App routes to a new pre-heat screen, **`app/session/wave-setup.tsx`**, that
   shows a PB-proposed seeding for this set's stroke + distance:
   - Fastest swimmers in wave 1, slowest in the last wave.
   - Each row: swimmer name, lane, seed time, seed source badge (`PB`,
     `coach estimate`, `unseeded`).
   - For swimmers with no PB at this stroke + distance, the row shows an
     "estimate" input. Coach can type a number or tap a "use closest PB"
     suggestion derived from `swimmer_pbs` (e.g. their 100 free PB scaled).
3. Coach can:
   - Drag a swimmer between waves or lanes (this changes the assignment, not
     the seed).
   - Edit any seed time inline (changes seed source to `coach edit`).
   - Set the inter-wave delay (default 30s, configurable per-set).
4. Coach taps **Confirm wave plan** → assignment rows are persisted, app
   navigates to `timing.tsx` in `ready` state.

### Wave 1 live

5. `timing.tsx` shows: master clock at zero, "Wave 1 ready — N swimmers" header,
   compact list of wave 1 swimmers with their lanes (no per-card interactivity
   — this is a recording instrument, not a dashboard).
6. Coach taps **GO**. Master clock starts. Volume buttons are armed for laps.
   Haptic confirmation on each tap.
7. As wave 1 swimmers finish, coach taps the volume button on each touch.
   Eyes stay on the water. Each tap writes a row to `recorded_times` with
   `wave_number = 1` and `time_ms = elapsed_at_tap`.
8. While the master clock runs, an on-screen **Send Wave 2** button is visible
   and enabled. The default delay countdown is shown next to it for reference,
   but firing is manual — the coach decides the moment.

### Wave 2 launch

9. Coach taps **Send Wave 2**. App captures `actual_offset_ms = clock_now`
   into `session_waves(wave_number=2)`. Volume button arming switches: from now
   on, taps default to wave 2 (the rule: "the most recently launched wave that
   still has unfinished swimmers owns new taps"; see §4.2).
10. Wave 2 swimmers start. Coach continues tapping on touches. Wave 1 stragglers
    can still be tapped; the algorithm interleaves predicted finishers across
    both waves (see §4.1).

### Heat end → reconciliation

11. When all expected swimmers have been tapped (or coach taps **End heat**),
    app routes to **`app/session/reconciliation.tsx`**.
12. Reconciliation shows every tap, attributed to a swimmer using the predicted
    finish queue (seed + offset). Each row carries a confidence indicator:
    - **Green** — tap landed within ±tolerance of the swimmer's predicted finish.
    - **Yellow** — outside tolerance but plausible (slow surge, fast fade).
    - **Red** — impossible split, missing tap, or duplicate.
13. Coach scans for non-green rows. To fix one:
    - Tap the row → tap the lane number it actually belonged to → done.
    - "No tap recorded" rows for missing finishers; coach can mark DNF or enter
      a manual time.
    - Duplicate taps can be deleted.
14. Coach taps **Save heat**. Final attributed `time_ms` values are written to
    `recorded_times` (with `wave_groups` rows holding the raw + corrected pair),
    and the set is marked complete in `workout_set_completions`.

### Between heats / next rep

15. App returns to `timing.tsx` in `ready` state for the next rep, with the
    same wave plan retained. Coach can re-open `wave-setup.tsx` to edit
    seeding mid-set if desired (rare).

---

## 2. Data flow (the second spine)

All state changes traced from coach input → persistence → derived data.

### 2.1 Pre-heat: seeding intent

```
PB lookup (swimmer_pbs) ──┐
                          ├─→ proposed seeding (in-memory)
attendance_list ──────────┘            │
                                       ▼
                          coach edits in wave-setup.tsx
                                       │
                                       ▼
            INSERT session_waves(workout_set_id, wave_number,
                                 planned_offset_ms)             ← one row per wave
            INSERT session_wave_assignments(session_wave_id,
                                            swimmer_id, lane,
                                            seed_time_ms,
                                            seed_source)        ← one row per swimmer
```

`seed_source` is one of: `pb_exact`, `pb_scaled`, `coach_estimate`, `coach_edit`.
Stored so reconciliation can show the coach how the algorithm got there.

### 2.2 Wave launch: actual offsets

```
coach taps "Send Wave 2" at clock_now
            │
            ▼
UPDATE session_waves
   SET actual_offset_ms = clock_now,
       launched_at_ms   = wall_clock_ms
 WHERE workout_set_id = $1 AND wave_number = 2
```

`planned_offset_ms` is the coach's intended delay; `actual_offset_ms` is what
actually happened. Reconciliation always uses `actual_offset_ms` for the math.

### 2.3 Live tap: raw event

```
volume button press
            │
            ▼
INSERT recorded_times(workout_set_id, swimmer_id=NULL,
                      wave_number=current_wave, time_ms=elapsed)
                      ──── swimmer_id deferred to reconciliation
            │
            ▼
INSERT wave_groups(recorded_time_id, wave_number,
                   raw_tap_time_ms=elapsed,
                   corrected_time_ms=NULL)
                  ──── corrected_time_ms filled in step 2.4
```

**Critical:** `swimmer_id` is **NOT** assigned at tap time. It is assigned in
reconciliation. The live screen's job is purely to record timestamps. (This is
the "algorithm vs. UI separation" line — see §4.)

### 2.4 Reconciliation: attribution + correction

```
(taps × seed_assignments) ─→ predicted-finish queue algorithm
                                     │
                                     ▼
                   default attribution + confidence per row
                                     │
                                     ▼
                          coach edits (lane-tap reassign)
                                     │
                                     ▼
UPDATE recorded_times
   SET swimmer_id = $assigned,
       time_ms    = corrected_time_ms     ← raw_tap_time_ms − wave_offset_ms
                                             where wave_number > 1

UPDATE wave_groups
   SET corrected_time_ms = raw_tap_time_ms − actual_offset_ms_for_that_wave
```

`recorded_times.time_ms` is the **displayed** swimmer time (offset-subtracted).
`wave_groups.raw_tap_time_ms` retains the master-clock value forever, so any
attribution can be re-derived if reconciliation needs to be undone.

### 2.5 Set completion

```
INSERT workout_set_completions(workout_set_id, recorded_time_ids=[...])
```

No change from current behavior; the array now includes wave-2 swimmers'
corrected rows.

---

## 3. Schema additions

### 3.1 New table: `session_waves`

Per-set, per-wave configuration (intent + actuals).

```sql
CREATE TABLE IF NOT EXISTS session_waves (
  id                  uuid    NOT NULL DEFAULT gen_random_uuid(),
  workout_set_id      uuid    NOT NULL REFERENCES workout_sets(id) ON DELETE CASCADE,
  wave_number         integer NOT NULL,
  planned_offset_ms   integer NOT NULL DEFAULT 0,    -- coach's intended delay
  actual_offset_ms    integer,                       -- captured at launch
  launched_at_ms      bigint,                        -- wall-clock at launch
  created_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (workout_set_id, wave_number)
);
```

### 3.2 New table: `session_wave_assignments`

Per-swimmer-per-wave seeding intent (which swimmer is in which wave/lane with
what seed time).

```sql
CREATE TABLE IF NOT EXISTS session_wave_assignments (
  id                uuid    NOT NULL DEFAULT gen_random_uuid(),
  session_wave_id   uuid    NOT NULL REFERENCES session_waves(id) ON DELETE CASCADE,
  swimmer_id        uuid    NOT NULL REFERENCES swimmers(id) ON DELETE CASCADE,
  lane              integer NOT NULL,
  seed_time_ms      integer NOT NULL,
  seed_source       text    NOT NULL CHECK (seed_source IN
                       ('pb_exact','pb_scaled','coach_estimate','coach_edit')),
  created_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (session_wave_id, swimmer_id),
  UNIQUE (session_wave_id, lane)
);
```

**Why a separate assignment table and not a column on `attendance`:** `attendance`
is keyed by `(workout_id, swimmer_id)` — per-workout, not per-set. A workout
contains many sets, and a swimmer can be in different waves and lanes for
different sets (e.g. wave 1 for the kick set, wave 2 for the swim set). The
seeding intent must be per-set, which forces a new table.

### 3.3 `wave_groups` — keep the table, drop the 10s assumption

The migration comment block at `20260425000001_workout_system.sql:80–84` says:

```
raw_tap_time_ms = what was tapped
corrected_time_ms = raw_tap_time_ms + (wave_number * 10s) — accounts for
  simultaneous-start stagger.
```

That hardcoded 10s rule is wrong for v1. The new rule:

```
corrected_time_ms = raw_tap_time_ms − session_waves.actual_offset_ms
                                       (for that recorded_time's wave_number)
```

Stored offsets per wave, not a global constant. The migration that adds the
two new tables will also include a comment update on `wave_groups` to point at
`session_waves.actual_offset_ms` as the offset source.

### 3.4 `recorded_times.swimmer_id` — relax to nullable

Currently `swimmer_id` is non-null and assigned at tap time via the live
pairing algorithm. v1 defers attribution to reconciliation, which means
`recorded_times` rows can exist briefly with `swimmer_id IS NULL`. Either:

- **(a)** Make the column nullable and add a CHECK that it's non-null after
  set completion, or
- **(b)** Stage taps in a transient table during the heat and only insert into
  `recorded_times` at reconciliation save.

Recommend **(a)** — simpler, lets the live screen reflect the master truth
without a parallel staging concept. The migration adds:

```sql
ALTER TABLE recorded_times ALTER COLUMN swimmer_id DROP NOT NULL;
```

If this conflicts with existing pairing code (`pairTime()` in `lib/ml-pairing`),
the v1 work plan will adapt — pairing becomes a *suggestion* fed into
reconciliation, not the live attribution.

---

## 4. Algorithm vs. UI separation

The single most important rule of this design: **what the algorithm computes
is not the same as what the UI shows during a heat.** The algorithm is rich
(predicted finish queue, confidence scoring, interleaved waves). The live UI
is intentionally dumb (master clock, tap counter, haptic feedback, big visible
"Send Wave 2" button — and that is all).

### 4.1 The algorithm

The predicted-finish queue runs against all assignments at heat start:

```
for each session_wave_assignment a:
  predicted_finish_ms[a.swimmer_id] = a.seed_time_ms + (a.wave_number > 1
                                       ? session_waves[a.wave_number].actual_offset_ms ?? planned_offset_ms
                                       : 0)
```

The queue is a sorted list of `(swimmer_id, predicted_finish_ms)`. Each tap
consumes the top of the queue at attribution time (in reconciliation, not
live). For wave 2 swimmers, the displayed time is
`raw_tap_time_ms − actual_offset_ms`.

Confidence per row is computed as `abs(raw_tap_time_ms − predicted_finish_ms) /
seed_time_ms`. Tolerance bands:

- **Green:** within 5%
- **Yellow:** 5–15%
- **Red:** > 15%, OR impossible split (negative corrected time, duplicate tap
  for same swimmer, etc.)

### 4.2 The live UI

During a heat, the UI exposes exactly:

- Master clock (read-only).
- Tap counter ("3 of 7 recorded").
- Haptic on every tap.
- A static list of swimmers in the current wave, with lanes (no interactivity).
- A big visible **Send Wave 2** button (active until tapped, then disabled).
- An **End heat** button at the bottom.

The UI does **not** expose:

- A predicted finish queue.
- Per-swimmer cards that update during the heat.
- Drag-to-reorder.
- Live attribution of any kind.

Coach eyes are on the water. The phone is a recording instrument. Everything
clever happens after the heat.

### 4.3 Wave ownership of new taps

When wave 2 launches mid-heat, new taps default to `wave_number = 2`. Wave 1
stragglers are still tapped on the same volume button. That looks like an
ambiguity, but it isn't — at reconciliation, the queue algorithm interleaves
both waves' predicted finishers in time order, so a slow wave-1 swimmer
finishing after fast wave-2 swimmers is correctly attributed by elapsed time.
The on-tap `wave_number` field is just a hint; reconciliation can re-classify.

The implementation rule for the live screen: tag new taps with the most
recently launched wave that still has unfinished swimmers. If wave 2 is
launched but all wave 2 swimmers have already been tapped, new taps go to
wave 1. If wave 1 is fully tapped first, all subsequent taps go to wave 2.

---

## 5. Failure modes and recovery

All eight cases the team flagged. Each one has a defined behavior so the
implementation does not have to invent an answer at a meet.

### 5.1 Coach taps volume button in idle state (accidental press)

**Behavior:** Volume button is unarmed in `ready` and `rep_done` states.
`VolumeManager` listener gates on `timingState === 'running'`. Accidental
presses do nothing and do not appear in any log.

### 5.2 Coach taps button mid-lap when a wave-2 swimmer hasn't finished yet

**Behavior:** Use the wave-ownership rule (§4.3). The tap is tagged with the
wave whose swimmers are still finishing — if both waves have unfinished
swimmers, the most recently launched wave wins. Reconciliation can re-classify
either way. The coach is not asked to make a wave decision live.

### 5.3 Sub-tap-latency finishes (~0.3s gap, two swimmers within human reaction)

**Behavior:** Two taps land within 300ms. The algorithm cannot distinguish
order from order-of-tap alone (human latency is in this range). At
reconciliation, both taps are flagged yellow, and the coach is shown both
candidates side-by-side with their predicted finish times so they can pick.
Default attribution is by predicted-finish queue order; the coach swaps if
their visual memory says otherwise. **No live UI attempts to disambiguate.**

### 5.4 Missed tap (coach blinked, sneezed, missed a touch)

**Behavior:** Heat ends with N taps but M > N expected swimmers. Reconciliation
shows all expected swimmers; the unmatched one(s) are shown as **No tap
recorded — DNF or manual time?** Coach can:

- Mark DNF (writes a row with `time_ms = NULL` and a `dnf=true` flag, OR
  simply omits the row — TBD with the data team).
- Enter a manual time (last-resort path: coach watched a manual stopwatch).

### 5.5 Double tap (volume button bounced, accidental second press)

**Behavior:** A 150ms hardware debounce in `timing.tsx` discards taps that
fall within the window of a prior tap. If two real touches happen within
150ms (extremely rare), they collapse to one tap and are flagged red in
reconciliation as "possibly missed second swimmer" — coach can split and add
the missing one manually.

### 5.6 Out-of-order finish vs. seed (slow swimmer surges, fast swimmer fades)

**Behavior:** This is the common case; reconciliation is built for it. The
queue algorithm's first guess will be wrong; rows fall in yellow or red.
Coach uses the lane-tap reassign UI to swap. No live correction, no
mid-heat queue display, no swiping. **Designing reconciliation to be fast
for this case is the single most important UI investment in v1.**

### 5.7 Unsedded swimmer / no PB for this event

**Behavior:** At seed time, the row shows `unseeded` and presents three
options:

- A scaled estimate from a related PB (e.g. swimmer's 100 free PB → estimated
  100 fly via a per-stroke ratio constant). Source: `pb_scaled`.
- A coach-typed estimate. Source: `coach_estimate`.
- "Use slowest swimmer's seed + 5%" as a one-tap fallback. Source:
  `coach_estimate`.

The seed must be set before the coach can tap **Confirm wave plan**. There is
no truly unseeded path into a heat — the algorithm needs a number, even a bad
one, to place the swimmer in the queue.

### 5.8 Wave-2 launch slips (intended 30s, actually 38s)

**Behavior:** This is the whole reason `actual_offset_ms` exists.
`planned_offset_ms` is what the coach asked for; `actual_offset_ms` is what
got captured at the moment of the **Send Wave 2** tap (clock-now). All
attribution math uses `actual_offset_ms`. The planned value is retained for
post-set review only ("you intended 30s, you sent at 38s").

---

## 6. Out of scope for v1

To be explicit about what is **not** in this plan, so reviewers do not chase
ghosts:

- **Audio touch detection.** Per-lane microphones / audio fingerprinting that
  could remove human tap latency. Belongs to v2+.
- **Per-lane hardware buttons.** A second physical input. Out of scope.
- **More than 2 waves.** The schema supports N waves (any `wave_number`), but
  the v1 UI only renders 2 waves. Three-wave heats are post-v1.
- **Mid-heat re-seeding.** Coach cannot edit seeds after **GO**. Edits resume
  at reconciliation.
- **Saving the wave plan as a template.** A nice future feature; not in v1.
- **Video review / replay.** Out of scope.

---

## 7. Implementation plan (rough order)

Not the full execution plan — that lands in the work tickets — but a sequencing
sketch so reviewers can see the path.

1. Migration: create `session_waves`, `session_wave_assignments`, relax
   `recorded_times.swimmer_id` to nullable, update `wave_groups` comment.
2. PB scaler utility: `lib/seeding.ts` with `proposedSeed(swimmer, stroke,
   distance) → { time_ms, source }`.
3. New screen: `app/session/wave-setup.tsx` — proposed seeding, edit, confirm.
4. Update `SessionContext` with wave plan, current wave, actual offsets,
   per-tap wave tagging.
5. `timing.tsx` rework: master-clock-only display, **Send Wave 2** button,
   defer attribution.
6. New screen: `app/session/reconciliation.tsx` — confidence-coded rows,
   lane-tap reassign, save.
7. Wire `results.tsx` and trends to read the corrected `time_ms` (already
   correct since `recorded_times.time_ms` becomes corrected after
   reconciliation).
8. Tests: pairing math, wave-ownership rule, reconciliation round-trip.

---

## 8. Open questions for the user

These are things the plan takes a position on but the user might want to
revisit:

1. **`recorded_times.swimmer_id` nullable** vs. transient staging table.
   Plan picks nullable (§3.4); flag if the data team prefers staging.
2. **DNF representation** — `time_ms NULL` vs. a `dnf` boolean column. Plan
   leaves this open; needs a data-team decision before the migration is
   written.
3. **PB scaling ratios** — does the team have stroke-to-stroke ratio constants
   already, or do we need to seed sane defaults (e.g. 100 fly ≈ 1.10 × 100
   free) and let coaches override per-swimmer?
4. **3-wave heats** — confirmed out of v1, but the schema supports them. Is
   that the right call, or do you want the UI to handle N waves from day one?
