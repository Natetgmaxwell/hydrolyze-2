# Adaptive Lap Pairing Algorithm — Design Doc

**Author:** Hydrolyze Vision
**Status:** Approved for implementation — dispatch Eng-Manager
**Doc path (local):** `plans/pairing-algorithm-design.md`
**Doc path (group chat):** `plans/pairing-algorithm-design.md`

---

## TL;DR — V1 Recommendation (Updated)

**Algorithm:** Cohort-gated nearest-neighbor heuristic with within-wave fastest-first seating. The wave optimizer sorts swimmers fastest-first within each lane by PB (not round-robin). The pairer gates assignments by wave cohort — once a wave's expected laps are consumed, the pairer advances to the next wave. This disambiguates finish order by structure rather than by heuristic confidence scoring. No training data needed; ships immediately; debuggable on-device.

**Where it runs:** Swift (on-device). Pool-deck wifi is unreliable. Pre-computation runs in the background as soon as roster + workout are locked. Algorithm updates ship with app releases (v1), or Edge Function post-session for batch-mode iteration (v2).

**UI surface:** Session-start roster picker → wave-order preview → Start. Session-end review screen with all assignments pre-filled — coach taps Save unless something looks wrong. No real-time disruption during coaching. Live suggestion mode deferred to v2.

**Ship complexity:** Low-to-medium. Schema additions modest. UI is two screens (roster picker + review). Implementation fits in one sprint.

**All 4 Qs resolved:** Q1 (4/5 wall push), Q2 (wave ordering), Q3 (attendance roster at session start), Q4 (wave ordering eliminates most simultaneous touches).

---

## 1. Design Principles

These principles govern every decision in the system. They are load-bearing — not aspirational prose.

### 1.1 Heavy Lifting Runs In The Background

- **Pre-computation as soon as inputs exist.** Once roster is marked and the workout is parsed, the system eagerly pre-computes per-swimmer expected paces for every `workout_set`, wave-orderings for each timed effort, and confidence thresholds. Coach never sees a "calculating..." spinner on deck.
- **Defaults are smart enough that coach doesn't touch them.** Wave-ordering suggestions are pre-populated; coach taps Start. Review screen has all assignments pre-filled; coach taps Save unless something looks wrong.
- **Surface decisions only when they matter.** If pairer confidence is high across the board, the review screen is a one-tap confirmation. If a lap is genuinely ambiguous (e.g., two swimmers with similar PBs, anomalous time), _that specific lap_ gets coach attention — not all of them.
- **Recovery is graceful.** If coach taps lap once for two simultaneous touches, system detects the gap anomaly and prompts on the review screen ("missing a lap? these two swimmers' predicted times overlap"). Coach doesn't need to know what happened in the moment — they fix it later, in calm.
- **Pool-deck constraints respected.** Time pressure, noise. UI elements that matter on deck (Start, Lap, Stop) are large, high-contrast, no-confirm. UI elements that need coach judgment (review, override) live off-deck — at session end, in the dry.

### 1.2 The Coach's Job Is Coaching, Not Data Entry

- Roster marked **once** at session start. No re-prompting between sets.
- Wave order **suggested**, not designed by coach.
- Lap **just press one button**. No swimmer picker mid-set. No lane picker mid-set. No "which set is this" picker mid-set.
- Pairing **happens after**. Coach doesn't tag swimmers in real time.
- PBs **update automatically** from confirmed paired times.

### 1.3 The System Learns From Every Confirmation

Every time a coach confirms (or overrides) a pairing on the review screen, that's labeled training data for v2. The heuristic isn't a dead end — it's the data-collection mechanism. Coach overrides explicitly teach the system which pace patterns are ambiguous. This is how we get from rule-based v1 to Bayesian v2 without a cold-start problem.

---

## 2. Problem Framing

### 2.1 The Failure Mode We're Preventing

A coach runs a set with 6 swimmers, 40 laps total. At session end, the coach faces a spreadsheet of raw timestamps and must manually tag each lap to a swimmer. This is:

- Error-prone (lap order ≠ swimmer order at the wall)
- Time-consuming (~10 min of manual entry after a workout)
- Degrading to the PB system (wrong attribution → wrong PBs → bad training data)

The pairer's job is to remove this manual step. Not to make the coach's job faster — to make the coach's job **possible** at pool-deck scale.

### 2.2 How Wave-Ordering Changes The Problem

If swimmers in the same lane start 10 seconds apart and the wave optimizer assigns positions such that predicted touch times are ≥1s apart, the pairer becomes nearly trivial: each lap timestamp falls into exactly one swimmer's predicted window in the normal case. The hard inference problem becomes a simple nearest-neighbor lookup — made possible by the optimizer doing the hard work upstream.

The pairer is still needed for:

- Edge cases where two swimmers' predicted windows overlap despite optimization
- Cold-start swimmers with no PB data
- Anomalous laps (missed touches, rest laps)

### 2.3 Input

A lap event arrives with:

- `elapsed_time` — seconds since the stopwatch started
- `previous_lap_elapsed` — seconds at the prior lap
- `workout_set_id` → joins to `workout_sets` → stroke, distance, interval, intensity, gear, rep-count
- `session_id` → joins to `session_roster` → which swimmers are present (attendance-locked at session start)

Plus per-swimmer profiles (PB dataset, historical recorded times).

### 2.4 Output

Per lap: a ranked list of `(swimmer_id, confidence_score)` sorted descending. Highest-confidence candidate is the tentative assignment.

Confidence thresholds:

- **≥ 85%** — auto-assigned, coach can still override at review
- **60–84%** — suggestion with amber indicator at review
- **< 60%** — ambiguous, requires coach manual selection at review

---

## 3. Wave-Ordering Module

### 3.0 Definition: Wave

A **wave** is a horizontal cohort of swimmers — one per occupied lane — that all push off the wall at the same send-off time. Wave 0 leaves at t=0, Wave 1 leaves at t = send-off interval, Wave 2 at t = 2× send-off interval, and so on. Every swimmer in Wave N shares the same `sendOffOffsetMs = N × sendOffIntervalMs`, regardless of which lane they occupy.

A wave is **not** a per-lane queue. If you have 4 lanes and 12 selected swimmers on a :10 send-off, you have 3 waves of 4 swimmers each, leaving at :00, :10, :20 — not 4 lanes each with their own independent sequence of 3 waves.

### 3.1 WaveOptimizer Ordering Rule

1. Sort all selected swimmers by PB ascending (fastest first). Tiebreaker: alphabetical by name.
2. Chunk into groups of `laneCount`. First chunk → Wave 0. Next → Wave 1. Etc.
3. Within each wave, assign fastest → Lane 1, second-fastest → Lane 2, …, slowest → Lane N.
4. Swimmers with no PB sort to the end and fill the final (possibly partial) wave.
5. Coach may drag-and-drop on the wave-preview screen to override; the saved `wave_assignments` rows reflect whatever the coach confirms.

**Consequence:** within a single lane across waves, you still see fastest-first vertically — but that emerges from rule (3) applied to each chunk, not as a primary ordering rule.

### 3.2 Schema Implication

- `wave_assignments.wave_number` = horizontal cohort index (0, 1, 2, …)
- `wave_assignments.lane` = which lane within that cohort (1 … N)
- `wave_assignments.position_in_lane` = redundant with `wave_number` in the common full-wave case; kept for the partial-wave case (e.g. 10 swimmers in 4 lanes → Wave 0 full, Wave 1 full, Wave 2 only lanes 1–2)
- `wave_assignments.send_off_offset_ms` = `wave_number × sendOffIntervalMs`, identical across all lanes in a given wave

### 3.3 Inputs To The Optimizer

| Input                        | Source                                             |
| ---------------------------- | -------------------------------------------------- |
| Swimmers present             | `session_roster` (attendance-locked)               |
| Each swimmer's expected pace | PB for (stroke, distance) or recent recorded times |
| Set distance                 | `workout_sets.distance`                            |
| Set interval                 | `workout_sets.interval`                            |
| Number of lanes              | Pool configuration (stored in app settings)        |
| Swimmers per lane            | Pool config + roster size                          |

### 3.4 Output From The Optimizer

A `WaveAssignment` per swimmer per set:

```swift
struct WaveAssignment {
    let swimmerId: UUID
    let lane: Int
    let positionInLane: Int  // 1 = first to go within the lane
    let waveNumber: Int       // 0 = first wave to leave, 1 = second wave, etc.
    let sendOffMs: Int       // milliseconds from set start to this wave's send-off
    let predictedTouchMs: Int // milliseconds from set start to expected touch
}
```

`sendOffMs` = `waveNumber * sendOffIntervalMs` (default sendOffIntervalMs = 10,000, i.e., 10 seconds).

`predictedTouchMs` = `sendOffMs + (expectedPaceSeconds * 1000)`.

The optimizer computes these for all swimmers once roster is locked and workout is selected. No user-visible spinner.

### 3.5 Wave Preview — Drag-and-Drop Interaction

**Layout:** Lane columns (Lane 1, Lane 2, ...) × position rows (0s, 10s, 20s...). Swimmer chips in cells. One swimmer per cell. Optimizer output is pre-filled; coach overrides by dragging chips between cells.

**Initial state:** WaveOptimizer-assigned positions pre-populate every cell.

**Drag interaction:**

- Long-press a swimmer chip → chip lifts with haptic feedback
- Drag over any cell → drop target highlights
- Release → chip snaps to new position
- If manual override creates a <1s predicted gap between adjacent swimmers, show an inline amber warning: "⚠ Position likely to cause a tied touch" — but allow the drop (coach owns the override)

**"Reset to suggested" button:** Restores WaveOptimizer output, discarding manual changes.

**"Start" CTA:** Bottom of screen, disabled if any lane is empty.

### 3.6 Pre-Computation Timing

Wave assignments are computed as soon as:

1. Attendance roster is locked (session start)
2. Workout is selected and parsed

The coach sees a brief wave-order preview (<1s), then taps Start. No spinners during timing.

---

## 4. Algorithm Shape

### 4.1 V1 — Cohort-Gated Nearest-Neighbor

The pairer operates in strict wave-cohort order. It advances to the next wave only after the current wave's expected lap count has been satisfied (or a grace timeout fires).

**State machine:**

```swift
struct PairingState {
    var lapsConsumedByWave: [Int: Int] = [:]  // waveNumber → laps consumed
    var swimmersInWave: [Int: [UUID]] = [:]    // waveNumber → [swimmerIds]
    var assignedLaps: [UUID: Int] = [:]        // swimmerId → laps assigned this set
    var activeWave: Int = 0
    var setComplete: Bool = false
}
```

**Matching algorithm per lap:**

1. **Advance gate:** Check if `lapsConsumedByWave[activeWave] >= swimmersInWave[activeWave].count`. If true, advance `activeWave += 1` (consume the gap — this handles DNFs and skips gracefully).

2. **Candidate window:** For the active wave only, find swimmers in `swimmersInWave[activeWave]` whose `predictedTouchMs ± 800ms` contains `lap.elapsedMs`. That's the candidate set.

3. **Single candidate:** Exactly one candidate → assign, confidence = 95.

4. **Multiple candidates:** Two or more candidates in the same wave (rare, only if PB variance is tiny within a wave):
   - Score by `|predictedTouchMs - elapsedMs|` — closer wins
   - Tie-break: swimmer with fewer assigned laps in this set
   - Confidence = `max(70, 95 - overlapMs / 100)` — clamped to [70, 84]

5. **No candidate in active wave:** Look at adjacent waves (activeWave - 1 and activeWave + 1) with a wider ±2000ms window. If found in adjacent wave, assign with confidence = 50 and flag for review. If not found anywhere → confidence = 20, flagged red at review.

6. **Cold start:** No PB and no history → confidence = 20, flagged red.

7. **Post-assignment:** Increment `lapsConsumedByWave[activeWave]` and `assignedLaps[swimmerId]`.

**Grace timeout:** If `activeWave` has consumed 0 laps for more than 45 seconds after the session start time, auto-advance to the next wave. This handles DNFs and missed starts without manual intervention.

**Confidence scoring (0–100):**

```
if candidate in active_wave and exactly_1: confidence = 95
elif candidate in active_wave and overlap < 500ms: confidence = 88
elif candidate in active_wave and overlap < 1000ms: confidence = 82
elif candidate in adjacent_wave: confidence = 50  # cross-wave, needs review
elif cold_start: confidence = 20  # manual required
# Clamped to [0, 100]
```

**Note on recalibration:** Defer recalibration to post-dogfood. The cohort-gated structure is so constrained that the thresholds above are starting points, not calibrated numbers. Real session data (coach confirmations + overrides) will tell us whether 95/88/82 needs tightening or loosening.

### 4.2 Edge Cases

**Edge 1 — Wave 0 swimmer DNFs:** The grace timeout (45s after session start) auto-advances the active wave gate. No manual "mark wave done" needed. The DNF lap is simply absent from the log — pairer advances and treats the next lap as Wave 1. On the review screen, the gap is visible and the missed-lap banner may fire if two swimmers' predicted times overlap across the gate.

**Edge 2 — Mid-set cool-down lap:** If a Wave 0 swimmer finishes their reps and starts a cool-down lap, that lap arrives outside the expected `repCount * interval` window for Wave 0. The pairer will not have a candidate in active wave (gate already advanced to Wave 1) and will find no adjacent-wave match either. Confidence = 20, flagged red — on the review screen the coach sees "unmatched lap at 4:32" and can manually tag it to the correct swimmer.

**Edge 3 — Same-PB tie within a wave:** Two swimmers with identical PB for (stroke, distance) in the same wave. Fastest-first ordering is undefined by PB alone. Resolution: alphabetical by first name. This is deterministic and requires no manual intervention. The coach can override on the wave-preview screen by dragging to reorder — the algorithm then uses that manual order as the tiebreak.

**Edge 4 — No-PB swimmers in a wave:** A swimmer with no PB for (stroke, distance) gets `predictedTouchMs` assigned from the wave's median PB. They are placed at the back of their wave (highest position number within the wave). Matching confidence is reduced by 15 for no-PB swimmers regardless of window fit.

**Edge 5 — Manual override on wave preview screen:** Coach drags a slow swimmer ahead of a fast swimmer in the same lane. The amber warning fires ("⚠ Position likely to cause a tied touch"). The coach confirms the drop. The algorithm accepts the manual order as ground truth for that session — pairer uses it as tiebreak order, not PB order. This is intentional: coaches know their athletes better than the algorithm does.

### 4.3 V2 — Bayesian Model

After 3+ months of coach-confirmed assignments, train Bayesian priors over each swimmer's pace distribution per (stroke, distance, intensity). Wave-order predicted times become Bayesian priors. The optimizer still produces the ordering, but the pairer refines confidence scores with posterior distributions. Every coach override is a labeled training example. The v1 heuristic is the training data source.

### 4.4 V3 — Sequence Model (further out)

Lap sequences across a set have structure. HMM or small LSTM over the lap sequence catches missed-lap clustering, pacing consistency, rest detection. Not v1 scope.

---

## 5. Output Shape + UI Surface

### 5.1 Session-Start Flow (3 taps to begin timing)

**Step 1 — Roster Picker:**

- Full-screen list of all team swimmers, sorted alphabetically
- Search bar at top (filters as coach types)
- Each row: swimmer name + checkbox (multi-select)
- "Select All" / "Clear All" buttons at top of list
- Empty state: "No swimmers on your team yet. Add swimmers in the Swimmers tab."
- Primary CTA: "Lock Roster" — disabled until ≥1 swimmer selected
- On lock: `session_roster` rows written with `attendance_marked_at = now()`, navigation advances to wave preview

**Step 2 — Workout selection:** Coach picks a saved workout or builds a new one. Standard workout selection flow (already built in I6/I7).

**Step 3 — Wave-order preview:** System shows swimmer → lane → position assignments per timed set. Drag-and-drop spec in Section 3.4. Taps "Start Session."

**Step 4 — Timing:** Coach runs the workout. Lap button only. No picker mid-set.

### 5.2 Session-End Review Flow

1. Coach taps "End Session" → `PairingService.runPairer(sessionId:)` runs on-device (<1s)
2. **SessionReviewView** opens with **Needs Review** tab selected by default

**Filter tabs (sticky header):**

- **Needs Review** _(default)_ — amber + red rows only; what requires coach attention
- **All** — every lap, grouped by set with sticky set headers
- **Auto** — green rows only; for spot-checking the easy confirmations

**Lap row anatomy:**

- Swimmer pill (tap → reassign via bottom sheet) · elapsed time · set context · confidence dot (green / amber / red)
- Set context headers are sticky as user scrolls: "Set 2: 4 × 100 Free @ 1:30"

**Swimmer reassignment — bottom sheet:**

- Tap a swimmer pill → bottom sheet slides up showing session roster sorted by proximity heuristic (swimmers already assigned to nearby laps appear first)
- Tap a swimmer name → sheet dismisses → lap reassigned, confidence set to "coach-confirmed"

**Missed-lap detection banner:**

- If a gap anomaly is detected within a set (e.g., two swimmers' predicted times overlap but only one lap was recorded), show an inline banner at the top of the affected set: "We detected a missed lap between [Swimmer A] and [Swimmer B] at 1:08.4 — add it?"
- Tap "Add" → inserts a placeholder row; coach assigns swimmer + estimates time
- Tap "Dismiss" → ignores the prompt

**Confirm-All guard:**

- If any amber or red rows exist and coach has not yet reviewed them → "Confirm All" button is **disabled** with tooltip: "Tap each flagged item to review before confirming"
- Once every amber/red row has been confirmed or reassigned → "Confirm All" enables
- All-green session → "Confirm All" is enabled immediately

### 5.3 Why Not Live Suggestions?

Real-time suggestions during timing are disruptive on the pool deck. The coach is wet, noisy, moving. Interrupting to ask "was that lap Sarah or Mike?" breaks coaching flow. Batched review is friction-reduced — coach handles it when the set is done, not during it. Live suggestion mode is v2 material.

---

## 6. Where It Runs

### 6.1 V1 — On-Device (Swift)

Pool-deck wifi is unreliable — no network dependency. On-device is instant with no round-trip latency. Wave optimizer + pairer both run locally. Algorithm updates ship with app releases, acceptable for v1.

### 6.2 V2 — Edge Function (Supabase) As Second Pass

After session syncs, run pairer as Supabase Edge Function server-side. Benefits: algorithm updates without app release, cross-session pace trend data. V1 on-device pairer is source of truth; Edge Function is future augmentation.

---

## 7. Data Plumbing Gaps

### 7.1 Migration 1: `session_roster` — `20260522000001_session_roster.sql`

```sql
CREATE TABLE session_roster (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id UUID NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    swimmer_id UUID NOT NULL REFERENCES swimmers(id) ON DELETE CASCADE,
    lane TEXT,
    position_in_lane INTEGER,
    attendance_marked_at TIMESTAMPTZ DEFAULT now() NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
    UNIQUE(session_id, swimmer_id)
);

CREATE INDEX idx_session_roster_session ON session_roster(session_id);
CREATE INDEX idx_session_roster_swimmer ON session_roster(swimmer_id);

ALTER TABLE session_roster ENABLE ROW LEVEL SECURITY;
CREATE POLICY session_roster_coach_policy ON session_roster
    FOR ALL USING (auth.uid() = (
        SELECT coach_id FROM sessions WHERE id = session_roster.session_id
    ));
```

`attendance_marked_at` timestamps when the coach locked the roster; used to filter laps recorded before roster finalization.

### 7.2 Migration 2: `wave_assignments` — `20260522000002_wave_assignments.sql`

```sql
CREATE TABLE wave_assignments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id UUID NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    swimmer_id UUID NOT NULL REFERENCES swimmers(id) ON DELETE CASCADE,
    workout_set_id UUID NOT NULL REFERENCES workout_sets(id) ON DELETE CASCADE,
    lane INTEGER NOT NULL,
    position_in_lane INTEGER NOT NULL,
    wave_number INTEGER NOT NULL,
    send_off_offset_ms INTEGER NOT NULL,
    predicted_touch_ms INTEGER NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now() NOT NULL
);

CREATE INDEX idx_wave_assignments_session ON wave_assignments(session_id);
CREATE INDEX idx_wave_assignments_set ON wave_assignments(workout_set_id);

ALTER TABLE wave_assignments ENABLE ROW LEVEL SECURITY;
CREATE POLICY wave_assignments_coach_policy ON wave_assignments
    FOR ALL USING (auth.uid() = (
        SELECT coach_id FROM sessions WHERE id = wave_assignments.session_id
    ));
```

`send_off_offset_ms` = `wave_number * sendOffIntervalMs` (default 10,000ms). Stored explicitly so non-uniform send-offs (:00, :10, :25) are supported without schema changes. `predicted_touch_ms` = `send_off_offset_ms + (expectedPaceSeconds * 1000)`.

**Note on `sendOffIntervalMs`:** Default is 10,000ms (10 seconds). The optimizer uses this for wave assignment computation. If a coach needs a different interval for a specific set, the per-set `workout_sets.interval` value is used as `sendOffIntervalMs` for that set's wave computation.

### 7.3 Migration 3: `recorded_times.lap_order` — `20260522000003_add_lap_order.sql`

```sql
ALTER TABLE recorded_times ADD COLUMN lap_order INTEGER NOT NULL DEFAULT 0;
CREATE INDEX idx_recorded_times_lap_order ON recorded_times(lap_order);

-- lap_order derivation: for laps within a session, lap_order = row number
-- when ordered by elapsed_ms ASC. The application sets this on insert.
-- For multi-lane interleaving, assign lap_order based on elapsed_ms ordering
-- across all lanes in the session.
```

### 7.4 Migration 4: `recorded_times.paired_swimmer_id` — `20260522000004_add_paired_swimmer_id.sql`

```sql
ALTER TABLE recorded_times ADD COLUMN paired_swimmer_id UUID REFERENCES swimmers(id) ON DELETE SET NULL;
CREATE INDEX idx_recorded_times_paired ON recorded_times(paired_swimmer_id);

ALTER TABLE recorded_times ENABLE ROW LEVEL SECURITY;
CREATE POLICY recorded_times_coach_policy ON recorded_times
    FOR ALL USING (auth.uid() IN (
        SELECT coach_id FROM coaches WHERE id = auth.uid()
    ));
```

### 7.5 Migration 5: `recorded_times.confidence` — `20260522000005_add_confidence.sql`

```sql
ALTER TABLE recorded_times ADD COLUMN confidence SMALLINT
    CHECK (confidence IS NULL OR confidence BETWEEN 0 AND 100);
-- 0-100 scale. NULL = unpaired/unconfirmed. Set by PairingService on assignment.
```

### 7.6 New Swift Services

```swift
struct WaveAssignment: Identifiable {
    var id: UUID
    let sessionId: UUID
    let swimmerId: UUID
    let workoutSetId: UUID
    let lane: Int
    let positionInLane: Int
    let waveNumber: Int
    let sendOffMs: Int
    let predictedTouchMs: Int
}

@Observable
final class WaveOptimizer {
    func optimize(roster: [Swimmer], sets: [WorkoutSet], poolConfig: PoolConfig) -> [WaveAssignment]
}

@Observable
final class PairingService {
    func runPairer(sessionId: UUID, roster: [Swimmer], laps: [RecordedTime], waveAssignments: [WaveAssignment]) -> [LapAssignment]
    func confirmAssignment(lapId: UUID, swimmerId: UUID)
    func confirmAll(sessionId: UUID)
}
```

---

## 8. Top Risks

### Risk 1 — Cold-Start Swimmers

A swimmer with no PB and no history for (stroke, distance) gets confidence = 20, flagged red. No-PB swimmers are placed at the back of their wave with `predictedTouchMs` from the wave's median PB, and matching confidence is reduced by 15 regardless of window fit. Mitigation: prompt coach to add PBs before first session. Historical `recorded_times` in same (stroke, distance) bucket serves as proxy PB.

### Risk 2 — Coach Forgets To Mark Attendance / Marks Wrong Roster

If coach starts timing without marking attendance, `session_roster` is empty. System detects this and prompts before timing begins. Roster is editable mid-session via a settings menu, but pairer filters out laps recorded before the most recent roster edit.

### Risk 3 — Review Screen Drop-Off

If the review screen is cumbersome, coaches skip it. Laps stay unpaired, PBs don't get written, training data loop never starts. UX must be fast: wave-order preview is one screen before timing, review screen has "Confirm All" as one tap. Minimal friction.

### Risk 4 — Wave Optimizer Fails To Separate Two Swimmers

If two swimmers have identical PBs and the pool has only 1 lane, optimizer cannot achieve 1s separation. Flag both as "tight pair" — both assignments shown with amber flags at review, coach resolves manually. System doesn't guess.

---

## 9. Implementation Scope For V1 Dispatch

### Files to create/modify:

| File                                                        | Change                                                                         |
| ----------------------------------------------------------- | ------------------------------------------------------------------------------ |
| `supabase/migrations/...session_roster.sql`                 | New table with `attendance_marked_at` + `position_in_lane`                     |
| `supabase/migrations/...wave_assignments.sql`               | New table                                                                      |
| `supabase/migrations/...add_lap_order.sql`                  | New column on `recorded_times`                                                 |
| `Hydrolyze/Sources/Models/SessionRoster.swift`              | New model with `attendanceMarkedAt`, `positionInLane`                          |
| `Hydrolyze/Sources/Models/WaveAssignment.swift`             | New model                                                                      |
| `Hydrolyze/Sources/Services/WaveOptimizer.swift`            | New service — wave ordering logic                                              |
| `Hydrolyze/Sources/Services/PairingService.swift`           | New service — nearest-neighbor pairer                                          |
| `Hydrolyze/Sources/ViewModels/SessionStartViewModel.swift`  | New — roster picker + workout selection flow                                   |
| `Hydrolyze/Sources/Views/Start/SessionStartView.swift`      | New — roster picker + wave preview + start                                     |
| `Hydrolyze/Sources/ViewModels/SessionReviewViewModel.swift` | New — batch review logic                                                       |
| `Hydrolyze/Sources/Views/Review/SessionReviewView.swift`    | New — review screen UI                                                         |
| Modify `TimingViewModel`                                    | Call `PairingService.runPairer()` on session end; route to `SessionReviewView` |
| Modify `ContentView`                                        | Route to `SessionStartView` before timing; `SessionReviewView` after timing    |

### Not in scope for V1:

- Multi-lane support beyond what wave optimizer handles (v2)
- Live suggestion during timing (v2)
- Edge Function pairer (v2)
- Bayesian learned parameters (needs training data, v2+)

### Open Questions Resolved:

- **Q1 (stopwatch start):** 4/5 wall-push default; first-lap confidence rule handles mid-set case
- **Q2 (wave ordering):** Wave optimizer assigns positions; ≥1s touch-time separation per lane
- **Q3 (roster selection):** Attendance marked at session start; persists for session
- **Q4 (simultaneous touches):** Wave ordering eliminates most; tight pairs flagged at review

---

## v1.16 Update (2026-06-18) — Addendum

The v1 design above described a "Cohort-gated nearest-neighbor heuristic." The current production code in `ios-native/Hydrolyze/Sources/Services/PairingEngine.swift` (v1.10 refactor, 280 lines) uses a **single global Hungarian** with wave-relative time as the cost-function dimension:

```swift
// wave-relative time = the multi-wave handling
let waveRelativeTime = lap.elapsedMs - wa.sendOffOffsetMs
cost[i][j] = velocitySpaceCost(actualTimeMs: waveRelativeTime, prediction: pred)
```

**Why this works for N waves:** the wave structure is implicit in the cost function. A wave 0 lap at 25s has wave-relative=25s (low cost vs ~25s prediction); a wave 1 lap at 25s has wave-relative=15s (high cost); a wave 2 lap at 25s has wave-relative=5s (very high cost). The Hungarian finds the global optimum across all N waves in one pass. This is the "column-shift invariant" property of the Hungarian algorithm: subtracting the send-off offset from all rows of the wave-column preserves the optimal assignment.

**The pivot point (v1.6 → v1.10):** the pre-v1.6 design used per-wave time windows (`[sendOffN, sendOffN + maxSwim + 5s)`) and per-wave Hungarian solves. That had a structural bug: adjacent wave windows overlap (wave 0 [0, 35s) and wave 1 [10, 47.8s) overlap in [10, 35s)), so a wave 0 lap at 28s would be claimed by both wave 0's and wave 1's Hungarian. The v1.10 refactor eliminates this by making wave structure implicit in the cost function, not enforced as hard windows.

**Where the v1 design's nearest-neighbor approach is preserved:** the v0→v10 algorithm progression is preserved verbatim in `ios-native/pairing_research/algorithms.swift` (research record, 199 lines, 11 algorithm versions). V10 ("Combined Best", tuned ghost-tap gate = 5.0) is the production algorithm pattern; the V10 cost function is reproduced in the iOS engine's `velocitySpaceCost` method.

**For the multi-wave (3+ waves) hardening plan and the line-finish / false-start / invalidation design forward path, see:** `plans/multi-wave-pairing-hardening.md` (greenlit 2026-06-18, 6 vertical slices, 4 deferred to v1.17+).
