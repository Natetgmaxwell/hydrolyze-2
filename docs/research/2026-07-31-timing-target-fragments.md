# Timing-Target Fragments: How Coaches Decide Which Part of a Set Gets the Stopwatch

**Research date:** 2026-07-31
**Purpose:** Catalog which fragments within a swim set a coach actually times, so the
Hydrolyze parser can identify timing targets.
**Sources:** Nathan Maxwell's coaching practice (session logs, Mountain Creek sets,
sprint-freestyle methodology); USMS workout-writing guide; Swim Camp set-design guide;
Swimming Wizard workout library; Liquid Tri glossary (K/D/S); Darien YMCA age-group
progression packet; Tritonwear coaching guide.

---

## The Governing Principle

> **The coach times the QUALITY EFFORT — the segment where speed/pace is the
> objective. Technique segments (drill, scull, kick-as-drill) are not timed for pace.
> Rest segments are never timed. When the whole rep is the quality effort, the whole
> rep is timed.**

The stopwatch captures the portion the coach wants to **measure, compare, or hold
accountable**. Everything else — drills, technique kick, recovery, rest — is
either counted (stroke counts) or simply completed.

This maps to a binary classification per fragment:

| Fragment role | Timed? | What the coach tracks instead |
|---|---|---|
| **Swim at pace / race effort** | ✅ YES | Time, splits |
| **Drill** (technique) | ❌ NO | Stroke count, execution cue |
| **Kick (technique)** | ❌ NO | Stroke count, body position |
| **Kick (speed test / "for time")** | ✅ YES | Time |
| **Scull** | ❌ NO | Feel, position |
| **Rest / easy recovery** | ❌ NEVER | — |
| **Pull (at pace)** | ✅ YES | Time + breath/stroke count |
| **Build / descend** | ✅ YES | Time per rep (progression) |

---

## Catalog of Timing-Relevant Fragment Patterns

### 1. Drill/Swim Split

**Notation:** `4×100 as 50 drill/50 swim @ 1:30`
**Also:** `6×50 drill/swim`, `4×75 25 drill + 25 swim`, `catch-up/swim by 25`

**What gets timed:** The **swim** portion (the second 50). The drill is technique work —
you don't race a drill. Nathan's practice confirms this: drills are tracked by **stroke
count** ("26-27 strokes for the 25"), never by time. The swim is where pace matters.

**Edge case — full-rep timing for interval management:** Sometimes the coach times the
*entire* rep (drill + swim together) just to verify the swimmer makes the send-off. But
this is interval management, not quality timing. The quality target is the swim segment.

**Parser signal:** `patternType: "drill_swim"` with `swimMeters` → the swim fragment is
the timing target. The drill fragment is not.

---

### 2. Odds/Evens (Alternating Stroke/Mode)

**Notation:** `8×50 odds kick evens swim`
**Also:** `8×50 odd=fast/easy, even=easy/fast` (Tritonwear example), VP block
"1-4 then 4-8" (Nathan's Mountain Creek shorthand)

**What gets timed:** The **evens** (the swim). Kick reps are rarely timed for pace in
this context — they're active recovery or technique work. The swim reps are the quality
effort.

**Nuance — odds/evens with intensity flip:** `8×50 odd=fast/easy, even=easy/fast` —
the "fast" half of EACH rep is timed (the 25 fast portion). The "easy" half is recovery.
This is a within-rep split, not a between-rep split.

**VP block (Nathan's "1-4 then 4-8"):** The "fast" rounds (5-8 in easy→fast progression)
are timed. The "easy" rounds (1-4) are not timed for quality — they're the setup.

**Parser signal:** `patternType: "odd_even"` → the even reps (or the explicitly
intensity-marked reps) are timing targets.

---

### 3. K/D/S (Kick/Drill/Swim)

**Notation:** `6×75 K/D/S` (= 25 kick + 25 drill + 25 swim, per rep)

**What gets timed:** The **swim** (third 25). Liquid Tri glossary confirms: "Swim means
just that. It is time to put everything together." The kick and drill are setup for the
quality swim. The coach may time the full 75 for interval management, but the swim
segment is the pace target.

**Parser signal:** A three-way drill_swim variant. The "swim" segment is the timing
target; kick and drill are not. (The parser currently models this as sub-reps but
doesn't distinguish K/D/S ordering — it's an extension point.)

---

### 4. Broken Swims

**Notation:** `1×800, broken by 10 seconds rest at each 100`
**Also:** `4×100 50 400 pace / 50 200 pace`, `200 broken 5 seconds at each 50`

**What gets timed:** The **total swim time** (sum of all segments, MINUS rest). A broken
swim is designed to simulate race pace — the coach wants either:
- The aggregate time (all 100s summed, rest excluded), OR
- Individual segment splits (each 100 or each 50 timed separately)

**Critical:** Rest segments are **never** part of the timed effort. USMS: "broken by 10
seconds rest at each 100, steady pace throughout" — the 10s rest is explicitly excluded
from the quality measure.

**Parser signal:** `Fragment[]` with `restAfter` — each swim fragment is independently
timeable; the `restAfter` fragment is never a timing target. The composite-set design
already handles this correctly (fragments are separate `workout_sets` rows).

---

### 5. Pace-Target / Race-Pace Sets

**Notation:** `8×100 @ 400 pace`, `10×50 race pace @ 1:00`, `4×50 @ target 28s`

**What gets timed:** The **whole rep**. The entire distance is the quality effort at a
target pace. Every rep is timed.

**Parser signal:** `intensity.type: "pace_target"` or `intensity.type: "race_pace"` →
the whole rep is the timing target. No sub-fragment selection needed.

---

### 6. Descend / Build Sets

**Notation:** `4×100 descend 1-4`, `3×100s descend 1-3`, `8×50 build`

**What gets timed:** **Each rep** (the progression is the point). The coach times every
rep to verify the descent. Descend 1-4 means rep 1 is slowest, rep 4 is fastest — all
four times matter.

**Parser signal:** `descend` field or `patternType: "descending"` → every rep is a
timing target.

---

### 7. "For Time" / "Best Average" / All-Out

**Notation:** `4×50 fast for time`, `20×50 best average`, `100 for time`

**What gets timed:** The **whole rep**. This is the purest case — the entire distance is
the timing target. "Best average" (USMS) means the coach wants every rep timed and the
average tracked.

**Parser signal:** `note: "fast for time"` or `intensity.type: "sprint"` → whole rep is
the timing target.

---

### 8. Pull Breath Progression (Nathan's Pattern)

**Notation:** `8×25 pull descending breaths 4→3→2→1 per 25m`

**What gets timed:** The **whole 25**. The breath count is a *constraint*, not a timing
target. Time + stroke count together tell the story (fewer breaths + same speed =
efficiency improvement). The coach times the 25 and counts the breaths separately.

**Parser signal:** The whole rep is timed; the breath count is a `note`/coaching cue,
not a timing fragment.

---

### 9. Composite / Parenthetical Sets

**Notation:** `4 × (75 at race rhythm / :15 Rest / 25 maximal finish)`

**What gets timed:** **Each swim segment independently.** The 75 @ race rhythm is one
timing target; the 25 @ maximal is another. The :15 rest is never timed.

**Parser signal:** `Fragment[]` — each swim fragment (with distance + intensity) is a
timing target. Rest fragments (`restAfter`) are never targets. The composite-set design
already models this correctly.

---

### 10. Odd Lengths Hard (Within-Rep Intensity)

**Notation:** `5×200 IM, rest 45, odd lengths hard`

**What gets timed:** The **whole 200** is timed (it's a continuous swim). The "odd
lengths hard" is an intensity instruction within the rep, not a separate timing target.
The coach may note which lengths were faster, but the stopwatch captures the full 200.

**Parser signal:** `note: "odd lengths hard"` — the whole rep is the timing target; the
intensity instruction doesn't create sub-fragments.

---

### 11. Kick for Time (Test Sets)

**Notation:** `500-1000 Kick for time` (Darien YMCA), `15 minute kick (count laps)`

**What gets timed:** The **whole kick distance** — but ONLY when explicitly marked "for
time" or as a test set. This is the exception to "kick is never timed." Kick test sets
are benchmark efforts, not technique work.

**Parser signal:** `stroke: "Kick"` + `note: "for time"` → the whole rep is a timing
target. Without the "for time" marker, kick is assumed technique work (not timed).

---

### 12. Scull/Swim by 25

**Notation:** `4×50 scull-swim by 25`, `4×50s choice on 1:15, scull-swim by 25`

**What gets timed:** The **swim** 25. Scull is feel/technique work — not timed. The swim
segment is the quality portion.

**Parser signal:** Similar to drill/swim — the "swim" segment is the timing target.

---

## Summary: Timing-Target Decision Tree

```
Is there a rest segment? ────── YES ──→ NEVER time the rest. Skip it.
│
NO
│
Is it a broken swim? ────────── YES ──→ Time each swim segment. Sum = total effort.
│                                         (rest excluded)
NO
│
Does the rep have a drill/swim ─ YES ──→ Time the SWIM segment. Drill is technique
or K/D/S split?                          (count strokes, not time).
│
NO
│
Is it odds/evens or VP block? ── YES ──→ Time the quality reps (swim / fast /
│                                         intensity-marked). Skip the easy/kick.
NO
│
Is the whole rep at a target ── YES ──→ Time the WHOLE REP. No sub-fragment
pace, race pace, "for time",             selection needed.
descend, or sprint?
│
NO
│
Is it kick "for time" / test ── YES ──→ Time the whole kick (exception: kick IS
set?                                    timed when explicitly a test).
│
NO
│
DEFAULT: Time the whole rep. If intensity instructions exist within the rep
(odd lengths hard, 50 fast/50 smooth), note them but time the continuous swim.
```

---

## Implications for the Hydrolyze Parser

### What the parser already models correctly

1. **`Fragment[]` with `restAfter`** — composite sets already distinguish swim segments
   from rest segments. Rest is never a timing target. ✅
2. **`patternType: "drill_swim"`** — the swim portion is implicitly the timing target. ✅
3. **`patternType: "odd_even"`** — the even (swim) reps are the timing targets. ✅
4. **`intensity.type`** — race_pace / pace_target / sprint / threshold all signal
   "the whole rep is timed." ✅

### What's missing / could be added

1. **No explicit `timingTarget` field.** The parser currently infers timing targets
   from pattern type + intensity, but doesn't flag it explicitly. A `timingTarget:
   "swim_segment" | "whole_rep" | "each_fragment" | null` field would make the timing
   intent machine-readable downstream (pairing engine, prediction, UI).

2. **K/D/S pattern not detected as a distinct type.** The parser handles drill/swim
   splits but doesn't recognize the three-way kick/drill/swim ordering. An extension
   would add `patternType: "kds"` or generalize to a multi-segment drill pattern.

3. **Kick "for time" not distinguished from kick-as-technique.** Both produce
   `stroke: "Kick"` but only the "for time" variant is a timing target. The `note`
   field captures this but it's not structured.

4. **Within-rep intensity splits** (odd lengths hard, 50 fast/50 smooth) don't create
   sub-fragments. This is correct (the coach times the continuous swim), but the parser
   could surface the intensity instruction for the UI.

5. **VP block "1-4 then 4-8"** — the parser detects odd_even patterns but Nathan's VP
   shorthand is a half-set intensity flip, not a per-rep alternation. The timing target
   is rounds 5-8 (the fast half), which the parser doesn't currently flag.
