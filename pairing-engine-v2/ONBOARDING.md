# Data Maturity & Onboarding — Design Doc

## The problem

A coach downloads Hydrolyze. The roster is empty or has just swimmers with names.
No times. No history. The pairing engine has nothing to work with.

**The coach needs to know:**
1. Is the engine working right now, or is it guessing?
2. How do they get it to work better?
3. When can they trust it?

**The current engine has 3 layers:**
- Layer 1: Recorded times (your actual data — best quality)
- Layer 2: Speed curve from PBs (estimated — medium quality)
- Layer 3: Population average (cold start — low quality)

**The coach doesn't see this complexity.** They see green/yellow/red indicators and want to know if they can trust the assignment.

---

## Data Maturity Tiers

For any swimmer × stroke × distance × intensity combination:

| Tier | Samples | Source | Reliability | What the coach sees |
|---|---|---|---|---|
| **Seed** | 0 | Population avg | Low | Orange — "Estimating from population data" |
| **Curve** | 0 PBs | Speed curve | Medium | Yellow — "Based on PB estimates" |
| **Learning** | 1–5 | Recorded | Growing | Green with count — "3 times recorded" |
| **Reliable** | 6–15 | Recorded | Good | Green — "9 times recorded — reliable" |
| **Mature** | 16+ | Recorded | Excellent | Solid green — "23 times recorded — excellent" |

**Design rules:**
- 0 samples → clearly show the engine is estimating (not guessing)
- 1–5 samples → show exact count, say "learning"
- 6+ samples → show count, say "reliable" or "excellent"
- PBs alone → yellow tier, not green (estimated, not actual)
- IM strokes → always manual assignment (no tier needed)

---

## Per-Swimmer Maturity Dashboard

Accessible from Roster → swimmer name → "Stats" tab.

Shows a grid:
```
Stroke     25m    50m    100m    200m    400m
────────────────────────────────────────────
Free       [12✓]  [5●]   [0–]    [0–]    [3●]
Back       [0–]   [1●]   [0–]    [0–]    [0–]
Fly        [0–]   [0–]   [0–]    [0–]    [0–]
```

Legend:
- **12✓** (dark green) — Mature (≥16 samples). Engine fully reliable.
- **9✓** (green) — Reliable (6–15). Engine good.
- **3●** (light green) — Learning (1–5). Engine improving.
- **0–** (gray) — No data. Engine uses population estimate.
- **PB** (yellow) — PB exists, no training times. Engine uses speed curve.

Coach sees at a glance which swimmers are "ready" and which need more data.

---

## Onboarding Flow

### Step 1: Empty state — coach creates first workout

**Screen:** Home → "Create Workout"

**Coach sees:**
> "You have no recorded times yet. That's normal — it takes a few sessions to build your swimmers' profiles."
>
> **What happens next:**
> Run your first practice. Every time you tap LAP, Hydrolyze records it. After 4–6 sessions, the engine will start making reliable assignments automatically."
>
> [Get started →]

**Why this works:**
- No shame about empty data. It's expected.
- Gives a clear timeline: 4–6 sessions.
- Frames the engine as something that builds over time, not something that works instantly.

---

### Step 2: After first practice — data status card

**Screen:** Roster → "Your team" tab

After the first workout is saved, the coach sees a summary card:

```
Team Data Status
────────────────────────────────────────
6 swimmers · 23 times recorded this week

Swimmers with reliable predictions:
  Marcus (50m Free), Jake (50m Free), Sofia (50m Free)
  — 3 of 6 swimmers have 6+ recorded times

Swimmers still learning:
  Emma (50m Free): 3 times
  Lily (50m Free): 1 time
  Ryan: no times yet

[Add times →] — swim more, get better predictions
```

**Why this works:**
- Positive framing: shows what's working, not what's broken.
- Numbers are specific ("3 times", "6+ recorded").
- Clear CTA: swim more = get better predictions.

---

### Step 3: During timing — data source indicator

**Screen:** Timing screen (session/timing.tsx)

When coach taps LAP, the assignment shows a small badge:

```
┌─────────────────────────────────┐
│ ✓ 27.8s — Jake         [RECORDED] │  ← solid badge = real data
│   8 times recorded                        │
└─────────────────────────────────┘
```

vs. a seed assignment:

```
┌─────────────────────────────────┐
│ ~ 31.2s — Emma        [ESTIMATED] │  ← dashed badge = population
│   No times recorded. Based on 50m avg.   │
└─────────────────────────────────┘
```

**Why this works:**
- Coach sees immediately whether the engine is working with real data or estimates.
- "8 times recorded" is specific — coach trusts numbers, not just labels.
- "No times recorded" explains why the assignment might be less reliable.

---

### Step 4: Swimmer stat card — full maturity display

**Screen:** Roster → swimmer → "Stats" tab

Shows:
1. **Maturity badge** — Learning / Reliable / Excellent
2. **Sample count** with target: "8 times recorded · target: 10+ for best accuracy"
3. **Time range** with σ shown: "50m Free · avg 27.8s · σ 0.3s" (coach sees spread)
4. **Recent trend** — "Last 3 times: 27.6, 28.1, 27.8s — consistent ✓" (shows engine has stable data)
5. **How to improve** — contextual tip: "2 more hard-effort 50m Free times would strengthen this profile"

---

### Step 5: Session summary — data contribution report

**Screen:** Session results

After saving a workout, show:

```
This session added 12 new times to your team data.

Strongest contributions:
  Lily: 4 times (50m Free) — now has 5 total ✓
  Ryan: 2 times (50m Back) — first Back data

Predictions improved for:
  Jake (50m Free): 8→10 times — Mature ✓
  Sofia (50m Free): 9→11 times — Reliable
```

**Why this works:**
- Shows that every practice session *matters* — data compounds.
- Specific numbers: "8→10 times" beats vague labels.
- Shows the payoff: more times = more reliable predictions.

---

## Key onboarding principles

1. **Empty data is expected, not a failure.** First-time users aren't greeted with warnings.
2. **Build the mental model: the engine learns.** Coach knows that swimming more → better predictions.
3. **Sample count is the primary signal.** Not "confidence score" or "accuracy percentage" — just "8 times recorded."
4. **Contextual tips are actionable.** "2 more hard-effort 50m Free times" beats "data needed."
5. **Population estimates are acknowledged, not hidden.** Coach knows when the engine is guessing.
6. **Progress is visible.** Coach can see their team getting "smarter" over time.

---

## Maturity thresholds (configurable)

These thresholds can be tuned as we get real usage data:

| Threshold | Value | Rationale |
|---|---|---|
| Learning minimum | 1 sample | First time is always the start |
| Reliable minimum | 6 samples | 6× the minimum; stddev becomes meaningful |
| Excellent minimum | 16 samples | 16+ gives very stable mean + stddev |
| PB → Curve minimum | 1 PB | One PB creates the speed curve |
| Suspicious threshold | 4 seconds | Coach intuition: "that time is way off" |

**Why 6 for reliable, not 10?**
Coach needs to see progress relatively quickly. If we require 10+ times before calling it "reliable," a coach doing 2 sessions/week × 3 sets = 24 times/week might feel like it's taking too long. 6 times is ~2 weeks for a coach actively recording data.

---

## Edge cases

### Coach has PBs but no training times
- **Visual:** Yellow badge "From PB estimate" (not green, not red)
- **Coach sees:** "Based on 100m PB. Add training times to strengthen this profile."
- **Path to green:** Record 6 training times at 50m Free → layer shifts from curve to recorded

### Coach has many times but all at one distance/stroke
- **Visual:** Other stroke/distance cells show gray (no data)
- **Coach sees:** "Good data for 50m Free. Need times at 100m Free to predict 100m assignments."

### New swimmer added mid-season
- **Visual:** Gray cells for new swimmer, green for established swimmers
- **Coach sees:** "New swimmer — will need ~6 sessions to build reliable predictions."
- **Engine works:** Population estimate used until 6+ times recorded.

### Swimmer has data but it's all old
- **Visual:** Green but with a note: "Last recorded: 3 weeks ago. Recent times would improve accuracy."
- **Rationale:** A swimmer's speed changes over time (season, age, training block). Old data is better than no data, but coach should know it's stale.

---

## Technical: how to compute maturity

```typescript
type DataMaturity = 'none' | 'seed' | 'curve' | 'learning' | 'reliable' | 'excellent'

function maturityTier(sampleCount: number, hasPB: boolean, hasRecorded: boolean): DataMaturity {
  if (!hasRecorded && !hasPB) return 'none'
  if (!hasRecorded && hasPB) return 'curve'
  if (!hasRecorded && hasPB) return 'curve'
  if (sampleCount === 0) return 'seed'
  if (sampleCount <= 5) return 'learning'
  if (sampleCount <= 15) return 'reliable'
  return 'excellent'
}

function maturityLabel(tier: DataMaturity, sampleCount: number): string {
  switch (tier) {
    case 'none':    return 'No data — using population estimate'
    case 'seed':     return 'No data — using population estimate'
    case 'curve':    return 'From PB estimate'
    case 'learning': return `${sampleCount} times recorded — learning`
    case 'reliable': return `${sampleCount} times recorded — reliable`
    case 'excellent': return `${sampleCount} times recorded — excellent`
  }
}
```

---

## Summary: coach-facing messages

| Scenario | Message |
|---|---|
| 0 samples, no PBs | "No data yet. Run 4–6 practices to build profiles." |
| 0 samples, has PB | "Based on your PB. Add training times to improve accuracy." |
| 1–5 samples | "[N] times recorded — building reliability. Keep recording!" |
| 6–15 samples | "[N] times recorded — reliable predictions." |
| 16+ samples | "[N] times recorded — excellent accuracy." |
| Assignment suspicious | "All swimmers are off by 4+ seconds. Check the set." |
| Assignment ambiguous | "Top two swimmers are close — coach resolves manually." |