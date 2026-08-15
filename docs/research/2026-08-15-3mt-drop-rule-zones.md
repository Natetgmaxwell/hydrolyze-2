# 3MT + Drop Rule + Zones — Implementation Deep-Dive for Hydrolyze

**Research date:** 2026-08-15
**Purpose:** Turn the Eva Piatrikova podcast (ASP SWIM Ep. 30) into an implementation-ready
spec for Hydrolyze: the 3-minute all-out test as a first-class session type, the drop rule
as default-to-assign applied to rest, and 4-zone training zones derived from critical speed.
**Sources:** Podcast transcript (brain: `inbox/clippings/using-sports-science-to-change-swimming-and-optimize-caeleb-dressel-eva-piatrikova-ep-30.md`); Vanhatalo, Doust & Burnley 2007 [1]; Piatrikova et al. 2019 IJSPP [2]; Piatrikova et al. 2019 JSCR (zone demarcation) [3]; Piatrikova 2019 clinic slides (protocol + formulas) [4]; Phlex zone guide [5]; TritonWear/Form/SwimmingStrong product pages [6][7][8]; Hydrolyze repo (V0.35–V0.37 SPECs, VISION.md, `ios-native/Hydrolyze/Sources/Services/`, `supabase/`).

---

## 1. The 3MT protocol & math, precisely

### 1.1 What the test is

The 3-minute all-out test (3MT) is a single-bout maximal effort: the swimmer goes all-out
from the first push-off and holds maximal effort for 3 minutes. The speed-time curve that
results has a characteristic shape — **peak speed → decay → plateau** — and that shape
contains three physiological parameters [2][4]:

| Parameter | What it is | Coach vocabulary |
|---|---|---|
| Peak speed | Highest speed reached, first 25m | "Top speed" |
| Critical speed (CS) | The plateau — highest speed metabolically sustainable | "Threshold pace" |
| D′ (D-prime) | Distance capacity above CS — the area under the curve above the plateau | "Battery" (unit: meters) |

The theory: an all-out effort depletes the anaerobic work capacity (the "battery") within
~2–3 minutes; once depleted, the highest speed the swimmer can maintain is the critical
speed — the boundary between the heavy and severe exercise domains [1][4]. The 3MT was
developed for cycling by Vanhatalo, Doust & Burnley (2007): end power from the 3-min
all-out (287 ± 55 W) was not significantly different from, and nearly perfectly correlated
with, critical power from conventional multi-trial tests (287 ± 56 W; r = 0.99; SE ≈ 6 W);
the W′ estimate agreed within 5 kJ in 8 of 10 cases [1]. Piatrikova was the first to apply
it to swimming (Exeter MRes, ~2017), validated it against step tests, and published the
swimming validation in IJSPP 2019 [2].

### 1.2 The exact protocol (how Eva runs it)

From the podcast and her 2019 clinic slides [4]:

1. **Equipment:** one stopwatch, 11 plastic cones, a 50m tape measure, one person to
   measure distance, one person to take splits. That's it — "you just don't need anything,
   just a stopwatch" (transcript 14:04).
2. **Setup:** cones mark 10m intervals along the pool. The swimmer swims continuously for
   3 minutes; the recorder logs the distance covered at each 10m mark (or, in Hydrolyze's
   case, the time of each 25m wall touch — see §1.4).
3. **Pacing instruction:** all-out from the first push-off. "You go all out from the
   beginning of the test" (12:58). The swimmer must NOT pace — the test only works if the
   battery is actually depleted. Eva re-tests swimmers who didn't go all-out (the
   "didn't work hard enough" case, 33:13).
4. **Duration:** 180s. The power/speed output declines to a steady level within ~135s in
   cycling [1]; the final 30s is the plateau window.
5. **Group format:** Eva runs it as a social event — pairs, stopwatches, cheer each other
   on. ~6 min per stroke per swimmer; ~20 swimmers tested and analysed in 2 hours [4].
6. **Familiarisation is mandatory:** "Most swimmers need 2 trials before using the data
   for training" [4]. The first 1–2 attempts are learning trials — the curve shape is
   unreliable until the swimmer learns to pace the all-out correctly.

### 1.3 The math (from the cycling/swimming literature)

**Critical speed (CS):** the mean speed over the final 30s of the test [2]. In Eva's
formulation from the clinic slides [4]:

```
CS = (D180s − D150s) / 30s
```

where D180s and D150s are the distances covered at 180s and 150s. With 25m split data
(Hydrolyze's case), CS = mean speed of the splits whose time window falls in the last 30s
(equivalently: the speed of the plateau, estimated as the average of the final 1–2 splits).

**D′ (battery):** the speed-time integral above CS [2][4]:

```
D′ = (D150s / 150s − CS) × 150s
```

i.e. the area between the speed curve and the CS line, expressed in **meters** — which is
why "Ariana's battery is 12m" is the correct coach-facing unit. It is the swimming
analogue of W′ (the curvature constant of the power-duration relationship).

**Peak speed:** the maximum speed observed — with 25m splits, the fastest 25m split
converted to m/s.

**Validation numbers (Piatrikova et al. 2019, IJSPP 13(9):1190–1198) [2]:**
- 13 highly trained swimmers (16 ± 2 y), 4 time trials + 2 × 3MT over 2 weeks.
- CS₃MT (1.33 ± 0.06 m·s⁻¹) did not differ from CS from conventional methods
  (1.33 ± 0.06 m·s⁻¹) and correlated nearly perfectly (r = 0.95, p < 0.0001).
- D′₃MT (19.50 ± 3.52 m) was **lower** than D′ from distance-time trials
  (23.30 ± 6.24 m, p < 0.05) — the 3MT systematically underestimates D′ by ~16%.
  Correlation still very large (r = 0.79).
- Test-retest: CS r = 0.97, CV = 0.9%; D′ r = 0.87, CV = 9.1%. CS is highly reliable;
  D′ is reliable but noisier — treat battery changes > ~10% as real signal.
- Conclusion: "The 3MT is a valid protocol for estimation of CS and produces high
  test-retest reliability for CS and D′ in highly trained swimmers."

**Zone demarcation (Piatrikova et al. 2019, JSCR — the step-test comparison) [3][4]:**
3MT-derived speeds vs incremental step test (IST) thresholds, 16 highly trained swimmers:

| IST parameter (actual) | 3MT prediction | Correlation | % of CS |
|---|---|---|---|
| 1st threshold (lactate/aerobic) | 1.21 ± 0.06 m·s⁻¹ | Nearly perfect (r = 0.92) | **89%** |
| 2nd threshold (anaerobic/CS) | 1.33 ± 0.07 m·s⁻¹ | Nearly perfect (r = 0.90) | **98%** |
| vVO₂max (Smax) | 1.40 ± 0.07 m·s⁻¹ | Very large (r = 0.88) | **103.5%** |

The beats-below-HRmax method (the common club alternative) correlated only r = 0.63–0.89
and systematically mis-predicted thresholds — the 3MT is the better no-hardware tool [4].

### 1.4 Computing from 25m split data (Hydrolyze's input)

Hydrolyze captures 25m wall-touch splits (LAP per wall touch). The mapping:

1. **Convert each split to speed:** vᵢ = 25 / tᵢ (m/s), where tᵢ is the i-th 25m split time.
2. **Peak speed** = max(vᵢ).
3. **CS** = mean speed over the final 30s of the test. With 25m splits, the final 30s
   covers the last 1–2 splits; use the mean of the splits whose cumulative time lands in
   [150s, 180s]. For a 25m-pool 3MT (~7 splits for a 1.4 m/s swimmer), that's the last
   split or the average of the last two. **Smoothing:** stopwatch tap error (±0.2–0.5s per
   touch) makes single-split CS noisy; average the final 2 splits (or fit a plateau to the
   last 30–45s of the curve).
4. **Battery (D′)** = Σᵢ (vᵢ − CS) × tᵢ over all splits where vᵢ > CS — the discrete
   integral of speed-above-CS over time, in meters. (Equivalent to Eva's
   (D150/150 − CS) × 150 formulation when the curve is sampled finely enough.)
5. **Curve shape** (the story): sprinter = big peak + big drop (large D′ relative to CS);
   distance swimmer = small peak, levels off quickly. The ratio D′/CS is the "sprinter
   index" — the same threshold with different batteries above it is exactly Eva's
   "10 swimmers with the same threshold, different characteristics above" point (15:23).

### 1.5 Data quality checks (the "didn't go all-out" detector)

Eva's practice: if the curve doesn't show the characteristic shape, the swimmer paced —
re-test. Concrete, implementable checks:

1. **Peak-speed sanity:** the fastest 25m split should be within ~5% of the swimmer's
   25m PB speed (or Layer-2 speed-curve prediction at 25m). A peak well below that
   suggests pacing or a bad start.
2. **Early-acceleration check:** if split 1 is slower than split 2 or 3, the swimmer
   didn't go all-out from the first push-off (the protocol's explicit instruction).
3. **Plateau check:** CS must be below peak speed by a plausible margin (typically
   10–20% for swimmers [2]: 1.33 vs ~1.5 peak). A flat curve from the start = paced.
4. **Familiarisation flag:** mark trial number per swimmer (1st, 2nd, 3rd...). Per Eva,
   do not surface zones/prescription from trials 1–2; show the numbers but flag
   "learning trial — repeat before using for zones" (coach vocabulary, not jargon).
5. **Battery caveat:** D′₃MT underestimates D′ from time trials by ~16% [2]. Never mix
   battery values across test types; trend only 3MT-vs-3MT. The coach-facing line:
   "battery is measured the same way every time — watch the trend, not the number."

---

## 2. Mapping onto Hydrolyze's existing engine

### 2.1 What exists today (read from source)

| Service | What it does | 3MT relevance |
|---|---|---|
| `SpeedCurveFitter.swift` | Log-log power-law fit of PBs: speed = a × distance^b (Riegel-based, b = −0.165 default). Predicts race pace at any distance. | **Not the 3MT curve.** This fits speed vs *distance*; the 3MT curve is speed vs *time*. Different model, different fit. Reused only for the peak-speed sanity check (§1.5.1) and for pairing predictions. |
| `HistoricalTimePredictor.swift` | 3-layer prediction (Layer 1: recorded stats ≥5 samples; Layer 2: PB speed curve; Layer 3: population seed). Maturity tiers: learning (1–5), reliable (6–15), excellent (16+). Sigma floor 1500ms (Layer 1). | **The drop-rule standard** (§4). Also supplies per-swimmer expected 25m split pace for 3MT pairing. |
| `PairingEngine.swift` | Single global Hungarian solve on velocity-space Gaussian cost; ghost-tap threshold 5.0. | **Reused for 3MT split assignment** — each wall touch is a lap; predicted touch k = k × expected 25m split time (from the predictor at 25m, intensity race). Same cost function, same threshold. |
| `WaveAllocator.swift` | Wave/lane assignment minimizing close finishes (500ms floor). | **Not needed for 3MT** (continuous swim, no waves). But its close-finish insight applies: in a group 3MT, two swimmers touching within <0.5s is a tap-collision — the pairing engine's ghost-tap threshold handles the aftermath; the coach can also stagger starts by lane. |
| `TimingService.swift` / `RecordedTimeFragmentService.swift` | Persist laps to `recorded_times`; per-fragment metadata + pairing handoff. | **Reused as-is.** 3MT splits are recorded_times rows with pace_distance = 25, rep_index = split index. The fragment service's `PairingHandoff` is the single-row resolution path for 3MT splits. |
| `WorkoutParser.swift` | Natural-language workout → sets; parses `m:ss` interval strings. | **Extended:** parse "3MT" / "3-min all-out" as a session-type marker; parse the drop-rule's base interval (already works: "on 4:30"). |

### 2.2 What's new vs extended

**New — `ThreeMinuteTestAnalyzer` (new service, `Services/ThreeMinuteTestAnalyzer.swift`):**
the curve math lives here, NOT in SpeedCurveFitter. Input: `[Lap]` (25m splits, elapsed
times) + pool length. Output: `ThreeMinuteTestResult { peakSpeedMps, criticalSpeedMps,
batteryMeters, curveShape: [Double], qualityFlags: [QualityFlag], trialNumber }`.
Pure function, no DB — same pattern as WaveAllocator. Quality flags: `.pacedStart`,
`.peakBelowExpected`, `.flatCurve`, `.learningTrial(trial: 1)`.

Why a new service rather than extending SpeedCurveFitter: the two curves are different
models (speed-vs-distance power law vs speed-vs-time all-out decay). SpeedCurveFitter is
load-bearing for pairing predictions everywhere; bolting a time-domain fitter onto it
would blur two contracts. The analyzer is small, pure, and unit-testable in isolation.

**Extended — `WorkoutParser`:** recognize "3MT" / "3-minute all-out" / "3 min test" in
workout text → emit a session-type marker (see §3.1). The interval parser already
handles "on 4:30" for the drop rule's base rest.

**Extended — `HistoricalTimePredictor`:** expose the maturity tier on the prediction
(already exists: `Prediction.Maturity`) — the drop rule reads it directly. No new
prediction logic needed; the 25m prediction at race intensity is the drop standard.

**Extended — `PairingEngine`/`PairingHandoff`:** no code change required for 3MT — the
caller supplies predictions built from the predictor at 25m. One nuance: during a 3MT the
coach taps LAP per swimmer per wall touch, and the *same swimmer* appears 6–8 times.
The pairing engine assigns each touch independently; the per-swimmer identity constraint
("Ariana's 3rd touch must be Ariana's") is enforced by the existing velocity-space cost
(consecutive touches for one swimmer are ~25–30s apart; cross-swimmer touches are
distinguishable by the cumulative-time prediction). Flag for v1: if two swimmers are
within ~0.5s of the same wall at the same moment, the coach taps both — the engine may
swap identities for that rep. Acceptable for v1 (review surface catches it); a
per-swimmer split-sequence constraint (touch k for swimmer S must be ≥ touch k−1 + 15s)
is a v2 hardening.

### 2.3 Where the session flow lives

3MT is a **session type** (approved decision), not a special mode. The flow:

1. Coach creates a workout with a 3MT set (or a standalone 3MT session).
2. Roster locked at start (one-mark-per-workout invariant — unchanged).
3. Timing screen: same LAP muscle memory; the set's distance is 25m (splits), reps = 7
   (3 min / ~25s per 25m) — but the stopwatch runs 3 minutes continuous, not per-rep.
   **New UI element:** a 3:00 countdown display alongside the stopwatch (the only
   countdown in the app today is the stopwatch itself — there is no rest timer; see §4.1).
4. On stop: splits → `ThreeMinuteTestAnalyzer` → result per swimmer.
5. Save: recorded_times rows (pace_distance = 25) + `swimmer_test_profiles` row (§3.2).
6. Review surface: per-swimmer curve + the three numbers in coach vocabulary.

---

## 3. Schema implications

### 3.1 Session type

`workouts` has no session-type column today (status: draft/scheduled/in_progress/complete).
Add:

```sql
ALTER TABLE workouts
  ADD COLUMN IF NOT EXISTS session_type text NOT NULL DEFAULT 'training'
    CHECK (session_type IN ('training', '3mt'));
```

3MT as a session type (approved) means the workout itself is the test — one 3MT set,
roster locked, splits captured. A 3MT set inside a normal workout (e.g. "warm-up, then
3MT, then cool-down") is also expressible: the set-level marker is
`workout_sets.intensity_type = '3mt'` (the column already exists, free-form text).

### 3.2 New table: `swimmer_test_profiles`

One row per 3MT per swimmer. This is the per-swimmer profile the analytics view reads
(Feature 1's "per-swimmer profile, year-over-year trend").

```sql
CREATE TABLE swimmer_test_profiles (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  swimmer_id      uuid NOT NULL REFERENCES swimmers(id) ON DELETE CASCADE,
  session_id      uuid REFERENCES sessions(id) ON DELETE SET NULL,
  workout_set_id  uuid REFERENCES workout_sets(id) ON DELETE SET NULL,
  stroke          text NOT NULL DEFAULT 'Free',
  pool_length     integer NOT NULL DEFAULT 25,
  test_date       timestamptz NOT NULL DEFAULT now(),
  trial_number    integer NOT NULL DEFAULT 1,      -- familiarisation counter
  peak_speed_mps  double precision NOT NULL,
  critical_speed_mps double precision NOT NULL,
  battery_m       double precision NOT NULL,        -- D′ in meters
  quality_flags   jsonb NOT NULL DEFAULT '[]',      -- paced_start / flat_curve / ...
  created_at      timestamptz DEFAULT now()
);
CREATE INDEX idx_test_profiles_swimmer ON swimmer_test_profiles(swimmer_id, stroke, test_date);
```

RLS: same pattern as swimmer_pbs (coach sees profiles for their swimmers).

**Zone paces are derived, not stored.** LT ≈ 0.89 × CS, vVO₂max ≈ 1.035 × CS [3][4] —
computed at read time from the latest *usable* profile (trial ≥ 2). Storing derived
percentages invites drift when the underlying physiology changes; storing CS/D′/peak
keeps one source of truth. (If a future coach-tunable zone model lands, it's a view, not
a migration.)

### 3.3 Drop-rule rest extension

Today `workout_set_completions` (workout_set_id PK, recorded_time_ids jsonb,
completed_at) tracks set completion. Rest is **display-only metadata** — `interval_text`
on workout_sets, parsed to a string, never timed. There is no rest countdown in the app
(verified: no countdown/restTimer anywhere in Sources). The drop rule therefore builds
the first rest-timer surface AND needs persistence for the flywheel.

New table — `set_rest_events` (one row per rest-extension decision):

```sql
CREATE TABLE set_rest_events (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id        uuid NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  workout_set_id    uuid NOT NULL REFERENCES workout_sets(id) ON DELETE CASCADE,
  swimmer_id        uuid NOT NULL REFERENCES swimmers(id) ON DELETE CASCADE,
  rep_index         integer NOT NULL,               -- the rep that dropped
  rep_time_ms       integer NOT NULL,
  standard_ms       integer NOT NULL,               -- predicted or rep-1 standard
  base_rest_sec     integer NOT NULL,               -- interval before extension
  extended_rest_sec integer NOT NULL,               -- interval after extension
  delta_sec         integer NOT NULL,                -- +30 or +60
  strike_count      integer NOT NULL DEFAULT 1,      -- 1st or 2nd strike
  standard_source   text NOT NULL CHECK (standard_source IN ('predicted', 'rep1')),
  reverted          boolean NOT NULL DEFAULT false,  -- coach tapped revert
  created_at        timestamptz DEFAULT now()
);
CREATE INDEX idx_rest_events_swimmer ON set_rest_events(swimmer_id, workout_set_id);
```

Why a table, not a JSONB column on workout_set_completions: the recovery-signature
flywheel (Feature 3) queries *per swimmer across sets and weeks* — "how many reps at what
rest before times fall". A JSONB blob on the completion row is write-only; a table is
queryable. The `reverted` flag preserves coach-is-authority: a reverted extension is
recorded (the engine learns the coach disagreed) but the rest was not extended.

Alternative considered: `workout_set_completions.rest_events jsonb` — rejected for
queryability, same reasoning as the fragments-JSONB decision on workout_sets (that one is
read-back for rendering; this one is read-back for analytics).

### 3.4 Migration path

One migration, additive only (house style: `supabase/migrations/YYYYMMDDHHMMSS_*.sql`):

1. `ALTER TABLE workouts ADD COLUMN session_type` (§3.1)
2. `CREATE TABLE swimmer_test_profiles` (§3.2)
3. `CREATE TABLE set_rest_events` (§3.3)
4. RLS policies for the two new tables (copy the swimmer_pbs pattern)
5. No backfill needed — all three are forward-only (NULL/absent until features ship).

`recorded_times` needs **no new columns**: 3MT splits are rows with pace_distance = 25,
rep_index = split index, intensity = 'race'. The fragment-metadata columns
(fragment_id, distance_meters, start_type, pace_target_sec) are already there from
V0.35-era migrations.

---

## 4. The drop rule implementation

### 4.1 Where it lives

**There is no rest countdown today.** `TimingSession.interval` is a `String?` carried
from the parsed set ("4:30") and displayed; nothing counts it down. The drop rule
therefore introduces:

- **`RestCountdownModel`** (new, in `ViewModels/` or as a struct in TimingViewModel):
  holds baseRestSec, remainingSec, extendedRestSec, strikeCount, per-swimmer state.
  Driven by the existing 10ms `Timer.publish` cadence in TimingViewModel (line ~459) —
  no new timer machinery.
- **TimingViewModel:** owns the drop-rule state machine. On each rep completion
  (LAP → rep time finalized), evaluate the drop rule per swimmer:
  - Compute standard: predicted time (from HistoricalTimePredictor at this set's
    distance/intensity/gear) **if maturity ≥ .reliable (6+ samples)**; else rep 1
    (approved decision: "predicted time, fallback to rep 1 when prediction immature").
    The 1500ms sigma floor is irrelevant here (that's the pairing cost floor) — the
    drop threshold is a fixed delta, not a sigma multiple. Note the asymmetry: the
    predictor's Layer-1 sigma floor exists to stop overconfident *pairing*; the drop
    rule uses the *mean* prediction, which is stable.
  - Strike if rep time > standard + threshold (0.5s for 50m, 0.25s for 25m — Eva's
    linear scaling, transcript 27:07–27:12).
  - Strike 1 → rest = base + 30s. Strike 2 → rest = base + 60s (Eva's Dressel rule:
    "if he hits two strikes, then we extend by a minute", 19:56). Strikes reset when
    the swimmer hits the standard again ("he's allowed two strikes again", 20:10).
  - **Per-swimmer:** the engine knows who dropped ("Ariana +30s, Jack holding") — v1
    uses a common clock + per-swimmer flags (approved decision); the countdown shown
    is the common clock, and each swimmer's flag shows their personal extension.
- **TimingView:** the non-intrusive surface. Inline badge next to the countdown:
  "Rep 3: 27.8, +0.6 → rest 5:00" with a one-tap revert. Never a modal (non-intrusive
  confirmation surface principle). The badge is the *only* new chrome; the countdown
  itself is the natural place a coach looks between reps.
- **Revert:** one tap on the badge → rest back to base, `reverted = true` written to
  set_rest_events. Coach is authority; the engine never silently extends.

### 4.2 The predicted-time standard (Hydrolyze-unique twist)

Eva's standard is rep 1 ("on the first one, on the second one you get 27.5" — the first
rep is the reference). Hydrolyze's standard is the **predicted time** — the
HistoricalTimePredictor's expected time at this set's (distance, intensity, gear,
calibration). This is strictly smarter: rep 1 can be a bad push-off, a slow start, or a
flyer; the prediction is the swimmer's *expected* time from 5+ real samples of this exact
context. The maturity gate:

| Maturity | Samples | Drop standard |
|---|---|---|
| none / learning | 0–5 | Rep 1 (Eva's rule) |
| reliable / excellent | 6+ | Predicted time |

Edge cases:
- **Prediction absent** (IM, no data, no fallback): rep 1.
- **Calibration factors** (suit/start): the predictor already applies them — the drop
  standard inherits them for free.
- **Gear:** the predictor's gear multipliers apply; a paddles set gets a slower standard
  automatically. Eva's rule has no gear concept; Hydrolyze's does — another
  smarter-than-source-material point.

### 4.3 Zone-awareness (Feature 4 hook)

The drop rule only fires on **anaerobic sets** (intensity_label ∈ {hard, race} — or,
once zones exist, sets whose target pace is above CS). Aerobic sets don't get
individualized rest — Eva's exact point ("what I think most coaches get wrong is the
anaerobic capacity, because they just give too little rest", 17:34). v1 gate: fire the
drop rule only when set intensity is hard/race; the zone-aware refinement lands with
Feature 4.

---

## 5. Zone derivation

### 5.1 The anchors (from the literature)

Eva's model: 4 zones, 2 thresholds [3][4][5]. The 3MT gives CS directly; the other
boundaries are percentages of CS from the JSCR step-test comparison:

| Zone | Boundaries | Physiology (Eva's words) | Coach vocabulary |
|---|---|---|---|
| 1 | < 0.89 × CS | Below aerobic threshold — mitochondria/capillaries, volume work | "Easy" |
| 2 | 0.89 × CS – CS | Between thresholds — high oxygen cost, sustainable | "Steady" |
| 3 | CS – 1.035 × CS | Above 2nd threshold — metabolite accumulation, time-to-exhaustion | "Hard" |
| 4 | > 1.035 × CS | vVO₂max and above — sprint ceiling | "Sprint" |

Anchors: LT ≈ 89% of CS (r = 0.92), CS = 100% (the 2nd threshold itself), vVO₂max ≈
103.5% of CS (r = 0.88) [3][4]. Peak speed from the 3MT is the top of zone 4 — the
sprint ceiling. "There is no more than four zones. It's just we like to make our life
complicated" (32:08).

Caveat: the 89%/103.5% anchors are from one study of 16 highly trained swimmers [3].
They're the best published no-hardware anchors available, and they're *derived at read
time* — if Eva or the literature refines them, it's a constant change, not a migration.
The zone boundaries should be stored as the *derived* CS (the anchor), never as
hard-coded paces per swimmer.

### 5.2 Display

Per-swimmer, in the analytics view, after a 3MT exists (approved decision). Coach
vocabulary only: zone names (Easy/Steady/Hard/Sprint), each with the pace per 100m
("Steady: 1:12/100m"). The set-writer surface (Feature 4) lets the coach write sets in
zone terms ("8×100 Steady on 1:30") — the parser maps zone words to paces via the
swimmer's profile. Rest rule becomes zone-aware: anaerobic (zone 3–4) sets get the drop
rule; aerobic (zone 1–2) sets don't.

---

## 6. Competitive landscape

| Product | What it is | Price | 3MT? | Coach-side pairing? | Moat threat |
|---|---|---|---|---|---|
| **SwimmingStrong** (Eva's own) [8] | Web 3MT calculator: enter splits → PDF report with age-group comparison | Free | ✅ (the calculator) | ❌ | **Direct competitor for the calculator, zero threat to the workflow.** It's a post-hoc web form — no stopwatch, no roster, no pairing, no history. Hydrolyze owns the capture; SwimmingStrong owns the report. |
| **FORM Smart Swim goggles** [6] | In-goggle HUD: pace, splits, stroke rate; per-swimmer device | $109–189 | ❌ | ❌ | Per-swimmer hardware cost scales with headcount; built for self-coached individuals, not a coach timing a squad. No pairing engine. |
| **TritonWear** [7] | Head-worn sensor + AI platform; 30 metrics, team dashboards, TPR meetings | $31/athlete/mo ($287/yr) | ❌ | ❌ | The closest "sport scientist in a box" — but hardware + per-athlete subscription prices it out of club land, and it tracks *swimmers*, not the coach's stopwatch workflow. |
| **Moxy** | NIRS muscle-oxygen sensor (Eva's test 3) | ~$500+ sensor | ❌ | ❌ | Hardware for the elite lab; explicitly out of scope for v1. |
| **EO hand paddles** | Instrumented paddles (power/watts) | ~$300+ | ❌ | ❌ | Hardware; per-swimmer; Eva uses them for economy work, not the 3MT. |
| **Phlex** | Apple Watch swim tracking + HR zones | Watch + sub | ❌ | ❌ | HR-based zones (the method Eva showed is *less* accurate than 3MT: r = 0.63–0.89 vs 0.90–0.92 [4]). No coach pairing. |
| **CSS calculators** (MyProCoach, Topend) | 200/400 TT → CSS + zones | Free | ❌ (2-TT method) | ❌ | Different test (Wakayoshi 2-TT), no capture, no history. |

**The moat:** pairing engine + per-swimmer identity + history + zero hardware. Every
competitor is either (a) a calculator with no capture (SwimmingStrong, CSS calculators),
(b) per-swimmer hardware that scales with headcount and serves the swimmer, not the
coach (FORM, TritonWear, Moxy, EO), or (c) HR-based zones that are measurably worse than
3MT-derived ones (Phlex). Hydrolyze is the only product where the coach's existing
stopwatch workflow *is* the test — the 3MT needs nothing but a stopwatch, and Hydrolyze
is the stopwatch that knows who's swimming. The flywheel (per-swimmer profiles,
year-over-year trends, recovery signatures) is data no hardware device can accumulate,
because no hardware device sits in the coach's hand at the wall.

---

## 7. Vision alignment

Checked against VISION.md [9] and the veteran-practitioner UX principles [10]:

| Feature | Principle | Verdict |
|---|---|---|
| 3MT as session type | One-mark-per-workout invariant | ✅ Roster locked at start; splits flow through the existing save/review pipeline. No new marking. |
| 3MT split capture | Effortlessness / information-rich | ✅ Same LAP muscle memory; the curve math is everything *after* the last wall touch — zero added deck effort. |
| Battery/threshold/top-speed vocabulary | Coach vocabulary, never jargon | ✅ "Battery is 12m" — no "anaerobic capacity", no "area under the curve", no "D′". |
| Drop rule auto-extension | Default-to-assign applied to rest | ✅ Engine suggests the extension; coach reverts in one tap if wrong. Never silent (inline badge). |
| Drop rule badge | Non-intrusive confirmation surface | ✅ Inline badge, never modal — the coach's eyes stay on the pool. |
| Per-swimmer rest flags | Invert-the-onus | ✅ The system tracks who dropped; the coach doesn't tally strikes in their head. |
| Zones in analytics | One actionable signal per swimmer | ✅ Per-swimmer zone paces after a 3MT; glanceable, tap for detail. |
| Recovery signature flywheel | Information-rich (data never lost) | ✅ The drop rule's byproduct is a per-swimmer recovery profile — learned from stopwatch data alone. |
| Democratizing HP testing | Product mission (AIS/QAS model) | ✅ The 3MT is the one test needing no hardware; Hydrolyze becomes the sport scientist in the coach's pocket. |

Anti-patterns explicitly avoided: no modal for rest extension; no confidence percentages
on the 3MT result (the numbers are the numbers — CS/D′/peak are direct measurements, not
probabilities); no new vocabulary; no mid-session roster churn; the engine never implies
it's smarter than the coach (the familiarisation flag says "repeat before using", it
doesn't say "your swimmer didn't try").

---

## 8. Recommendation summary

**Build order (ranked):**

1. **3MT mode** (Nathan's rec — he'll use it this week). Session type + split capture +
   `ThreeMinuteTestAnalyzer` + `swimmer_test_profiles` + analytics surface.
   - Effort: **M–L** (new session type, new pure service, one migration, one analytics
     view). The analyzer is the smallest piece (pure function, ~150 lines); the session
     flow and review surface are the bulk.
   - Risks: familiarisation (mitigate: trial_number + learning flag); tap-collision in
     group 3MTs (mitigate: existing review surface; v2 split-sequence constraint);
     battery underestimation vs time trials (mitigate: 3MT-vs-3MT trending only, coach
     vocabulary line).
2. **Drop rule** (independent smaller slice). RestCountdownModel + drop state machine +
   inline badge + revert + `set_rest_events`.
   - Effort: **S–M**. No schema risk (additive table), no new prediction logic (maturity
     tier already exists), the countdown reuses the 10ms timer.
   - Risks: the app has no rest countdown today — this is the first one, so the UX is
     greenfield; keep it badge-only and revertible. Zone-gating (anaerobic-only) is a
     one-line intensity check for v1.
3. **Recovery signature flywheel.** Analytics over `set_rest_events` — per-swimmer
   "reps-at-rest-before-dropping" pattern.
   - Effort: **S** once the drop rule has shipped and accumulated data. No new capture;
   - pure analytics. Risk: needs weeks of data before it's meaningful — ship the
     surface early, let it fill.
4. **Zones.** Derivation (0.89/1.0/1.035 × CS) + analytics display + zone-aware rest
   gating + zone-term set writing.
   - Effort: **S–M** (derivation is a read-time constant; the set-writer surface is the
     work). Depends on 3MT data existing (order after 1). Risk: the 89%/103.5% anchors
     are single-study — keep them as constants, revisit with literature.

**What to build first: 3MT mode.** It's the wedge (Nathan uses it this week), it creates
the data the other three features consume (zones need CS; the flywheel needs drop events
which need the rest timer; the rest timer is independently useful), and it's the
democratization story — the one test that needs no hardware, owned by the stopwatch that
knows who's swimming.

---

## Sources

[1] Vanhatalo A, Doust JH, Burnley M. Determination of critical power using a 3-min
all-out cycling test. Med Sci Sports Exerc. 2007;39(3):548–55. doi:10.1249/mss.0b013e31802dd3e6. PMID 17473782.
[2] Piatrikova E, Sousa AC, Gonzalez JT, Williams S. Validity and reliability of the
3-minute all-out test in national and international competitive swimmers. Int J Sports
Physiol Perform. 2019;13(9):1190–8. doi:10.1123/ijspp.2018-0018.
[3] Piatrikova E, Sousa AC, Willsmer NJ, Gonzalez JT, Williams S. Demarcating exercise
intensity domains in freestyle swimming: is there an alternative to incremental step
test and beats below HRmax method? J Strength Cond Res. 2019. (Zone percentages: LT 89%,
CS 98%, vVO₂max 103.5% of CS; r = 0.88–0.92.)
[4] Piatrikova E. Closing the gap between science and practice in swimming testing,
monitoring and training prescription. Clinic slides, 2019-09-09 (svoem.org). (Protocol,
equipment, CS/D′ formulas, familiarisation, BBM comparison.)
[5] Phlex Swim. The Importance of Training Zones and How to Individualize Training. 2023.
[6] FORM Smart Swim goggles — product site (formswim.com), 2026 pricing.
[7] TritonWear — product site (tritonwear.com), 2026 pricing ($31/athlete/mo, $287/yr).
[8] Swimming Strong (swimmingstrong.co.uk) — 3MT physiology + calculator.
[9] Hydrolyze 2 VISION.md (docs.archive.2026-06-30/VISION.md).
[10] hydrolyze-product-framing skill (v1.3.0) — veteran-practitioner UX principles.
