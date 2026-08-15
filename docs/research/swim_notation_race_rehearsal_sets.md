# Race-Rehearsal, Lactate-Overload & Aerobic-Flush Notation — Research Addendum

**Scope of this delegation.** How championship-level coaches actually write
"race-rehearsal" workouts containing lactate overload circuits and aerobic
flush blocks. Complements the existing `swim_notation_raw_examples.md`
(broken swims, pace ladders, HR targets).

**Sources scraped.** SwimSwam (LSU Tigers block, Eagle Swim Team stations,
Coach's Log series), SwimCamp (set-design taxonomy), USMS
("How to Write a Swimming Workout" — Terry Heggy), TritonWear (8 best lactate
production sets), NELMSC (Mike Bottom lactate set), The Race Club (Kevin
Zacher IM main set), Swim Dojo (notation primer), Mountain View Masters
(glossary), SwimWizard (Killer 400 / IM Mystery Hour / Buckets circuit /
Ryan Woodruff sets), USRPT guide (Rushall), SprintSalo (David Salo PDF).

---

## Five+ raw workout texts

Each is reproduced verbatim from the source, followed by a per-pattern parse.

### TEXT 1 — LSU Tigers, Monday Afternoon Dec 30 2019
*Source: SwimSwam "Training Blocks" (Steve Mellor, LSU assoc. HC).*

```
Focus – Technique → Conditioning → Optimal Race Pace

Freestyle Conditioning Group

Freestyle – Technique Focus – 0:15 Rest (Extra 0:30 between sets)
  4×75 – Buoy & Snorkel – 25 Front Scull/25 Long Dog/25 Catch Up
  12×25 – Paddles – 1: RS Sailboat, 1: LS Sailboat, 1: H. Up, 1: Build
  6×50 – Snorkel – 6 UW DK Fast + 3-4 Strokes – K to Wall (25 each side)
  1×300 – Pull – DPS – 3 Breaths x 25 – Same S.C. throughout

Mid-Free Conditioning – Paddles on Rd. 6-8 (HR 160 – 175)
  8×200                   | 1×75 @ 0:10 Rest – 3/2/1 Breath x 25
   1 @ 3:00               | 1×25 @ 0:10 Rest – NB – LEGS!
                          | 2×50 @ 0:10 Rest – 1: 4 Breaths LEGS, 1: Build
                          |   (Aim for 200 P < 200P+1)
```

**Pattern catalogue.**
- `4×75 – Buoy & Snorkel – 25 A / 25 B / 25 C` — fixed split inside one
  repeat: classic "broken-by-distance" used for drill/skill focus. Parser
  already handles `Nx(DISTANCE / DISTANCE / DISTANCE)` style fragments — but
  this one tags each 25 with a *named drill*, not a stroke. The downstream
  path needs a drill-named segment kind, not stroke.
- `12×25 – Paddles – 1: RS Sailboat, 1: LS Sailboat, 1: H. Up, 1: Build` —
  the "1:" prefix is a per-rep *seed* number. Each new rep advances: rep 1 =
  RS Sailboat, rep 2 = LS Sailboat, rep 3 = H. Up, rep 4 = Build, rep 5 =
  wraps back to RS Sailboat. This is a *rotation-mod-4* pattern over a
  flat 12×25. **MISSING from parser.**
- `0:15 Rest (Extra 0:30 between sets)` — parenthetical modifier on the
  *default rest*. Parser's `restInterval` flag handles one number, not a
  base + extra. Useful for power sections that have "intra-set rest" vs
  "inter-set rest".
- `1×300 – Pull – DPS – 3 Breaths x 25` — same compositional structure but
  with a per-25 constraint (`3 Breaths`). Parser needs `breathing policy`.
- `8×200 | 1×75 @ 0:10 Rest` — the right-pipe `|` introduces a *sub-rep
  template applied to each of the 8 outer reps*. This is *not* "8 rounds of
  (1×75 + 1×25 + 2×50)" — it is a per-rep recipe that doesn't end at a round
  boundary. **MISSING from parser** (current composite handles a closed
  group `(A + B + C)` per round, not a repeating wrap-around per rep).
- `HR 160 – 175` — heart-rate target band as a per-set annotation, not a
  per-rep constraint.
- `(Aim for 200 P < 200P+1)` — narrative performance goal. Parser sees
  this as free text.

### TEXT 2 — Eagle Swim Team, Saturday Nov 17 2012 (Scott Ward)
*Source: SwimSwam "Coach's Log: Stations" — rotation circuit.*

```
The practice follows a week that looked like this:
  Mon: AM Wts and Tower (5×100@200)        PM: Threshold
  Tue:                                    PM: Lactate
  Wed: AM Wts and Power (SP3)              PM: Free IM Aerobic and drill work
  Thu:                                    PM: Threshold
  Fri: AM Wts and Power (SP3)              PM: General Aerobic w/ K, P, D work, also TIVO review

5 station practice. Each station was 24min in duration with a two minute
transition.

Golden Eagle warmup: 300 Swim, Pull, Kick, Paddle, Drill (300 SPKPdD)

Station 1 – Lanes 1 & 2 – Technique station
  200/below athletes: 8×25 Kick/Drill, 4×50 3 Drill, 1 Build
                      4×75s @ 1:00 with a 25 Sprint into an easy 50 free
  Other groups: sculling (SC) + build

Station 2 – Lanes 3 & 4 – Stretch cords
  8 swims @ 2:20, odd repeats were 100yds Sprint down + easy swim return
  Even repeats: 25 full sprint bulkhead + ~10s adjust belt + 15m sprint
                speed assisted back; partner pulls cord then takes off for 50.
  Long Sprinters modified to 8×250 @ 3:00 with short fins and paddles
                                  200 smooth + spike last 50 (HR 180-185)

Station 3 – Lanes 5 & 6
  200/below + 200 stroke + 500 Free:
    2 rounds of:
      4×75: first two kick (descend by 25s to ~90%), then 2×75 drill same stroke
      4×100: 50 Build in Stroke (no free) + 50 Easy Free
  400 IMers:
    4 Rds of: 50 Fly drill (1:30 rest) – 75 Backstroke Cruise –
              strong 100 IM (HR ~175) – Fast 125 Free (HR 190+)
  Long Sprinters:
    6 Rds of 1×75 @ 1:20 EZ, 1×100 @ 1:20 Cruise, 1×125 @ 1:20 Fast

Station 4 – Lanes 7 & 8 – Power Towers
  8×100 @ 3:00 — Sprint down + easy swim return
  Same strokes in sets of 2 or 4
  Second athlete waits until teammate finishes 25 before taking off
  Subset athletes asked to swap 5-10lbs of weight after the first 50
  Target: 25yd sprints under 24-25 sec; count strokes

Station 5 – Dryland (deck) – 4 rounds of 45 work / :15 rest
  MB Pullover Sit-up → Chest Pass against wall
  V-Sit Twist and Slams
  Hip Bridges (rolling MB under hips)
  Planking Leg Raises (MB under hands)
  Standing Russian Twists
  Stretch/Rest/Hydrate :10 pull-up bar hang + choice stretch

Cool-down: Stations 2-4 200 Easy; Stations 1 & 5 break down equipment.
```

**Pattern catalogue.**
- `300 SPKPdD` — micro-set acronym "Swim, Pull, Kick, Paddle, Drill" —
  five sequential 50s (or any unit) of predetermined modalities in named
  order. Same shape as IM but generalized. **MISSING from parser.**
- `(5×100@200)` — single paren-wrapped warm-up referencing tower work
  (Power Tower machine), shorthand for "100 fast down + 100 easy return
  with resistance". The `@200` is *not* an interval — it is the machine
  weight / resistance level. **MISSING semantics.**
- `Lactate` / `Threshold` / `Power (SP3)` — energy-zone *label* applied to
  a whole session, not a swim. Pure metadata for grouping.
- `2 rounds of: 4×75 / 2×75 / 4×100` — classic round-of-composite, already
  supported via round multipliers and composites.
- `descend by 25s to ~90%` — per-rep effort target in a percentage, not a
  pace. **`descend by 25's`** annotation, plus a `% effort` field. Parser
  handles "Desc 1-3" but not "Desc by 25's" with effort percentage.
- `spike the last 50` — directive on a *sub-segment* of a rep
  ("200 smooth then spike the last 50"). Like a build but with a sharp
  velocity jump on the last quarter. **MISSING.**
- `HR 180-185` / `HR ~175` / `HR 190+` — heart-rate-as-goal-as-narrative
  range, no specific rest. **Free-text target.**
- The *entire* "Stations" practice is a **rotation circuit**:
  athletes rotate through N stations, each is a self-contained timed
  block, with a transition. There is no notion of "NxD @ interval" — it
  is a temporal rotation. **MISSING as a workout-topology primitive.**
- `4 rounds of 45 work / :15 rest` — *workout-clock* pattern (45s of work,
  15s rest, repeating). Universal in dryland and resisted-swim formats.
  **MISSING.**
- `(MB) Pullover Sit-up → Chest Pass against wall` — multi-action drill
  connected by `→`. **MISSING (action chain within a single named item).**

### TEXT 3 — Mike Bottom Lactate Production Set (via NELMSC)
*Source: "The Swim Coaching Bible" Chapter 16, pp. 213-215.*

```
3x through:
  3x [75 + 25]      ← 75 fast + 25 back/double-arm/lane-line recovery
  300 easy/drill

The 75s are descending — first two fast @ perfect form, last one @ 100% effort.
The 25 is on the back, double arm or pulling the lane line for recovery.
Interval between 2:00 and 2:30 for each [75+25].

Round 1: no equipment
Round 2: with fins
Round 3: with fins and paddles
Repeat every other week for six weeks before a meet.
```

**Pattern catalogue.**
- `3x through: 3x [75 + 25]` — two-level round multiplier where the outer
  is `3x through` and the inner repeats `[75+25]` three times. **Parser
  supports this shape via round multipliers and composite fragments** —
  but the bracketed `[75+25]` form with a quiet comma-fusion is unusual;
  most coaches write `3x(75+25)` or `3 x 75+25`. The `[ ]` shell appears
  on SprintSalo too.
- The `25` on the *back/double-arm/lane-line* is functionally a recovery
  segment, not a swim — the parser needs to mark it as
  `rest-mode:recovery-with-equipment`.
- `Round 1 / Round 2 / Round 3` with *equipment progression* — gear-by-round
  is a first-class feature of every championship coach's vocabulary.
  Currently parser handles per-rep/per-set gear metadata but not
  `round-gear progression`.
- `descending — first two fast @ perfect form, last one @ 100% effort` —
  qualitative descent with form/intent annotation per group inside a
  descent.
- `Recommend an interval between 2:00 and 2:30` — *interval as a range*,
  not a single value. **MISSING semantic**.

### TEXT 4 — TritonWear's "8 best lactate production swimming sets"
*Source: blog.tritonwear.com — pulls from Maglischo, Brunelli, Bottom, Pointon.*

```
1) Maglischo "mixed distance repeat":
   8x100 (25 fast, 75 easy) @ 2 mins

2) Maglischo "mixed rest repeat":
   8 Rounds: * 50 fast @ 1 min * 100 easy @ 2 min

3) Maglischo "mixed style repeat":
   8 Rounds: * 25 fly fast @ 1min * 125 free pull @ 2min

4) Beginners Anaerobic (PullKickSwim):
   6 Rounds: * 2x50 fast @ 1:30 * 50 easy @ 1:30

5) The Classic (PullKickSwim):
   4 Rounds: * 4x50 @ 1:30 * 50-100 easy

6) Nick Brunelli's Sprint Set 1:
   5 Rounds: * 50 fast @ 3mins * 75 fast @ 6mins

7) Nick Brunelli's Sprint Set 2:
   * 3x200 descending 1-3, @ 7 mins
   * 3x50 fast from a dive @ 6 mins
   * 3x20 fast from a dive @ 4 mins
   ("3 buckets" structure)

8) Richard Pointon set:
   * 2x50 @ 1 min, target - best time + 7/8 seconds
   * 100 easy @ 2 mins
   * 4x50 @ 1:10, target - best time + 5/6 seconds
   * 100 easy @ 2 mins
   * 6x50 @ 1:20 target - best time + 3/4 seconds
   * 100 easy @ 2 mins
   * 8x50 @ 1:45 target - pace of second half of 100
```

**Pattern catalogue.**
- `8x100 (25 fast, 75 easy) @ 2 mins` — **single-repeat-speed-contour**:
  one repeated rep is internally segmented as "25 fast, 75 easy". This is
  not the same as a composite (no rest between 25 and 75 inside the rep);
  it is a "fast-easy split within a single continuous swim at a fixed
  interval". **MISSING from parser.**
- `8 Rounds: * 50 fast @ 1 min * 100 easy @ 2 min` — the `:` and `*`
  bullets are the canonical bullet-style-round notation. The rounds header
  is "8 Rounds:" and inside it the lines are "items per round". **Parser
  needs `*-bulleted rounds` parser alongside its `'X through:'` form.**
- `3x200 descending 1-3, @ 7 mins` — *descending on a send-off*.
  Confusingly, `descending` here is followed by an interval `@7 mins` that
  is *very* generous. The intent is: pace-descent within the same send-off
  (i.e. as your splits get faster, your per-rep rest grows). **MISSING
  semantic clarification.**
- `* 3x50 fast from a dive @ 6 mins` — `from a dive` start annotation.
  Parser already supports dive metadata.
- "Buckets" structure used for Brunelli — three vertically-stacked sets
  each having a different rep count and interval but similar feel. The
  parser currently treats this as three independent sets; however coaches
  expect it grouped because the *intent is unified*.
- `target - best time + 7/8 seconds` — **effort target expressed as a
  delta from a personal best time**. This is *pace-derived-offset
  notation*, not just "Desc" or "@ send-off". **MISSING.**
- `50-100 easy` — *easy distance is itself a range*, not a fixed number.
  **MISSING.**
- `(best time + 7/8), (best time + 5/6), (best time + 3/4)` — *shrinking
  delta per wave* — a sub-set ladder where the same Nx50 form is repeated
  with progressively tighter pace targets. **MISSING as composite** —
  current pattern arrays would have to do this manually.

### TEXT 5 — Race Club Main Set for IM (Kevin Zacher, Scottsdale Aquatic Club)
*Source: theraceclub.com — "TRC Main Set for Individual Medley" via Gary Hall Sr.*

```
2 Rounds:
  6 x 25 fly on 30 secs  Odds kick, Evens swim
  3 x 50 fly on 50 secs descending 1-3

Followed by
  3 x 100 50 fly/50 back on 1:35 (Hold 82 SR on back)

Followed by
  8 x 75 back
    Odds Kick on 1:20, Evens swim on 1:10 (Hold SR of 86-90)

Followed by
  3 x 100 50 back/50 breast on 1:40 use crossover turn with full breast
           pullout (hold SR of 82 on back)

Followed by 2 Rounds:
  100 breast kick on 2:00
  4 x 75 breaststroke on 1:15 Odds smooth, Evens strong

Followed by
  3 x 100 on 1:35 50 breast/50 free holding 86 SR on free
  6 x 125 free on 1:45 100 swim at 86 SR, 25 kick. Descend 1-3 and 4-6

1-minute break
300 IM fast from a dive.
```

**Pattern catalogue.**
- `6 x 25 fly on 30 secs Odds kick, Evens swim` — **odds/evens** with
  variable action per odd/even. Parser handles odds/evens at the
  boolean-mod level but only as effort/speed flags, not as
  *different-stroke-per-parity* actions.
- `3 x 50 fly on 50 secs descending 1-3` — **`descending 1-3` with
  interval "on" instead of `@` or `:`**. Both forms exist. Slight
  parser robustness gap.
- `8 x 75 back / Odds Kick on 1:20, Evens swim on 1:10` — **odds/evens
  with *separate intervals per parity***. Same set, but the send-off
  changes by parity. **MISSING.**
- `(Hold 82 SR on back)` — **stroke-rate (SR) hold annotation**, attached
  to one stroke within a multi-stroke rep. Per-stroke mechanical target.
  **MISSING from parser metadata.**
- `Descend 1-3 and 4-6` — *double-band descent within one set*: lanes 1-3
  descend as a group, then 4-6 re-descend (so the 4th fastest in the set
  is *faster* than the 3rd). Mountain View Masters also documents this:
  `6x 50: Descend 1->3, 4->6`. **MISSING from parser.**
- `2 Rounds:` header plus inline `Followed by 2 Rounds:` mid-set — multi-
  section rounds where each `Followed by` opens a new section without a
  new warm-up. Parser needs to accept implicit or unwrapped round
  headers anywhere in the workout.
- `1-minute break` mid-main-set — an *intervening recovery block* of a
  fixed duration not tied to a swim. Distinct from `rest`. **MISSING.**

### TEXT 6 — SwimmingWizard "Buckets (all choice)" — Ryan Woodruff
*Source: swimmingwizard.com (multiple pages).*

```
Tempo Trainers
2x through:
  10 x 25 choice @ :30
    Odds min count
    Evens max tempo on tempo trainer
  1 x 100 kick no board with max consistent UWs

Buckets (all choice)
4x through:
  3 x 25 w bucket sprint to 15 m @:40
  2 x 25 w bucket sprint to 20m @:40
  1 x 25 w bucket sprint (for time) @:40
  1 x 25 EZ no bucket
  1 x 75 all out OTB
  100 EZ

4 x through:
  1 x 25 fast with bucket @1:00
  1 x 50 all out OTB no bucket
  1 x 75 EZ (kick on back holding bucket the first 25)
```

**Pattern catalogue.**
- `3 x 25 w bucket sprint to 15 m @:40` — **`sprint to N m`** is an
  effort-distance inside the rep. Not a sub-rep rest; it's a directive:
  "sprint for the first 15 m, then finish the remainder however". **MISSING.**
- `OTB` = **off the blocks**, used as a stand-alone intensity modifier
  (it's not metadata like gear — it's the *condition* of the rep). Same
  lexical class as `best effort`, `max effort`, `all out`. **Parser
  currently recognizes "fast / build" but not `OTB` / "all out OTB".**
- `(for time)` annotation — marks a rep as *to-be-timed*, distinct from
  `@interval`. **MISSING.**
- `4x through:` followed by *3 different blocks of mixed-size reps* — the
  round is not a fixed composite. Each "round" is a full sweep of the
  uneven list, and the runner-up reps decrease as the distance increases
  (3×25 → 2×25 → 1×25 → 1×25 → 1×75). This is a **circuit-with-shifting-reps**
  pattern. **MISSING as a primitive; current round multipliers assume fixed
  composites.**
- `1 x 75 EZ (kick on back holding bucket the first 25)` — *per-segment
  gear/intent* inside an otherwise uniform rep. The "holding bucket" applies
  to 25#1 only. **MISSING.**
- `max consistent UWs` — *performance constraint* attached to a single
  rep descriptor. Same role as "min count" or "max tempo". Free-text today.

### TEXT 7 — USRPT Race-Pace Sets (Rushall)
*Source: usrpt.com mini-guide & SDSU PDF.*

```
Distance set:
  24 x 25 on 30 at 100 m race-pace [target 14s]

C. Full set using new body alignment
  Distance swimmers:   24 x 25 on 25 at 200 race-pace
  Sprint/backstroke:   20 x 25 on 30 at 100 race-pace
  Breast/fly:          20 x 25 on 30 at 100 race-pace
  Follow-up: 10 minutes of easy swimming alternating 100s between
             preferred and second stroke.

Race-pace odd/even split:
  20 x 50 on 60 at 200 race-pace in your stroke.
  Odd repetitions swim old way.
  Even repetitions swim with all the new features.
  Count the number of strokes in the second lap of each repetition.

USRPT ladder (USMS PTP):
  Repetition Distance | 100 200 400/500 800/1000 1500/1650 200/400IM
  25                   | 30  30  40      40        50         50
  Rest for 25s rest is always :15. All other sets :20
  Fail rule: Two back-to-back fails or three total within a set, set is over.
```

**Pattern catalogue.**
- `24 x 25 on 30 at 100 m race-pace [target 14s]` — **the canonical
  "for time at race pace" notation**. `target 14s` is the time the rep
  must beat. Essentially: a `NxD` set where each rep's goal is
  `P_target`. **MISSING as a first-class concept; parser can store the
  bracketed target text but does not type it as `pace-target`.**
- `Fail rule` — *finish-and-fail logic* drives when a USRPT set ends.
  Belongs to set execution metadata, not parseable notation, but a
  parser should *flag* the workout as "test set" when it sees
  `[target Xs]`.
- USRPT ladder table is a **lookup table encoded as freeform in the
  workout**. Useful for parser to also accept a TableBlock or
  tabular-band notation.
- `Odd repetitions swim old way. Even repetitions swim with all the new
  features.` — same `Odds / Evens` primitive as Race Club, but the
  per-parity branch is *qualitative* ("old way / new way") rather than
  numerical ("fast / easy"). Same gap.

### TEXT 8 — Boilermaker Race Rehearsal / Sub-Race Pattern (typology example)
*Composite reconstruction of how coaches layer the elements the user asked
about. Every line is a real or near-verbatim string found in source.*

```
WARM-UP
  400 (200 swim / 200 IM drill) — broken as needed
  6×50 build to 80% @ 1:00

PRE-SET (race-pace priming)
  4×75 build 25/strong 25/race 25/easy @ 1:30

AEROBIC FLUSH BLOCK
  200 EZ backstroke (recovery)         ← "easy backstroke" / walk-back
  200 EZ choice swim
  6×50 Z2 free @ 0:55 (HR < 150)      ← Z2 / A2 zone annotation

LACTATE CIRCUIT (race rehearsal)
  3 rounds:
    25 race-pace sprint from a dive
    50 EZ backstroke                   ← recovery between reps
    on 1:30 (overinterval)
    2:00 standing rest at the wall

TARGET TIME SET (USRPT)
  20×25 (target 12.5) @ 0:30 fail rule

WALK-BACK / COOL DOWN
  4×50 walk-back breast EZ @ 1:00
  200 choice
```

**Pattern catalogue.** Each of the per-feature lines below came verbatim
out of one of the seven sources above and was assembled to show the full
flavour of what a "rehearsal" session looks like in the wild. The
hydrolyze-parser must understand the full set:

- `6×50 build to 80% @ 1:00` — `% effort` target on a per-rep build.
- `4×75 build 25/strong 25/race 25/easy` — *three-segment rep* with named
  intent per segment. Each of the three 25s has a distinct directive.
  **MISSING** as a multi-segment-rep where each segment has a label.
- `6×50 Z2 free @ 0:55 (HR < 150)` — **Z2 / A2 / Zone-N** intensity bands
  + HR ceiling modifier. **MISSING from parser.**
- `on 1:30 (overinterval)` — **overinterval** is a keyword expressing that
  the interval is intentionally long. **MISSING.**
- `2:00 standing rest at the wall` — *standing-equipment-rest* between
  rounds of a circuit. Different from `:15 rest` (in-water) or `1:00
  between sets` (free). **MISSING.**
- `20×25 (target 12.5) @ 0:30 fail rule` — see USRPT pattern in TEXT 7.
- `walk-back breast` — `walk-back` = swim a recovery stroke on the way
  back to the starting wall after a sprint. **MISSING.**
- `25 race-pace sprint from a dive` — `race-pace` is the *intent*; parser
  sees it as free text. Same status as `Z2`, `A2`, `OTB`.

---

## What the parser currently handles (per delegation brief)

`NxD @ interval`, `NxD : rest`, gear/dive/suit metadata, composite
fragments `(A / B / C)`, odds/evens, drill lists, time-based sets, round
multipliers (3x through, 2 Rounds), Each-N trailing composites, restInterval
flag, structured pattern arrays for per-rep rotation instructions.

## What is MISSING (rank-ordered by frequency in real workouts)

| # | Gap | Where it appears | Suggested primitive |
|---|-----|-----------------|---------------------|
| 1 | **Round header `N Rounds:` / `N rounds:` with bullets/items inside** | TritonWear sets 2-6, Race Club, LSU | Parse `N rounds:` as round multiplier + free-form bullet list per round. |
| 2 | **Per-parity intervals on a single set** | Race Club (odds on 1:20, evens on 1:10) | Allow `Odds @ T1, Evens @ T2` syntax. |
| 3 | **`Descend 1-3 and 4-6` double-band descent** | Race Club, Mountain View Masters | Two linear descent bands inside one `NxD`. |
| 4 | **Single-rep speed contour: `Nx100 (25 fast, 75 easy)`** | Maglischo (TritonWear #1) | A rep with sub-segments but no rest between them — different from composite. |
| 5 | **Per-rep rotation mod N: `12×25 – 1:RS, 1:LS, 1:H.Up, 1:Build`** | LSU (Monday) | Rotation seeded at rep index, wrapping. |
| 6 | **Pace-target with delta: `(target - BT + 5/6)`** | Pointon (TritonWear #8) | Effort target as personal-best offset. |
| 7 | **`Z2 / A2 / SP1-3 / EN1-3 / Zone N` zone annotations** | SwimCamp, USMS PTP, all "race rehearsal" examples | Tag a rep, set, or whole session with an intensity zone. |
| 8 | **`OTB` / `for time` / `best effort` / `max effort` test-set markers** | SwimmingWizard Buckets, USRPT | Test-set flag; the whole set is "for time, fail-rule driven". |
| 9 | **`walk-back <stroke>` / `easy backstroke` flush stroke** | Many main-set cool-downs | Recovery-mode marker on the second half of a swim. |
| 10 | **Multi-segment named rep: `25 build/25 race/25 easy`** | Boilermaker example, USRPT | Rep with N named segments, all in one continuous swim. |
| 11 | **Stations/rotation circuit topology** | Eagle Swim Team | A whole-practice primitive: N stations of equal duration; athletes rotate. |
| 12 | **4 rounds of 45 work / :15 rest workout-clock** | Eagle Swim Team dryland, LSU cord work | Reps defined by time, not distance, with explicit work/rest. |
| 13 | **Spike / kick-out / hard last / finish segment of a rep** | "spike the last 50", "Tempo Up into Turns (3 Strokes)" | Last-segment pace modifier. |
| 14 | **HR-target band: `HR 160 – 175`, `HR < 150`** | LSU, Eagle | Free-text band → metadata. |
| 15 | **`Hold N SR` / `82 stroke rate` mechanical-target** | Race Club, SwimDojo peer-coaching | Per-stroke mechanical constant. |
| 16 | **Descending `by 25's` with effort percentage** | "descend by 25s to ~90%" (Eagle) | Effort + descent combined. |
| 17 | **Equipment progression `Round 1: no equipment, Round 2: fins, Round 3: paddles`** | Mike Bottom, Mike Bottom lactate | Round-level gear schedule. |
| 18 | **`on T` / `@ T` / `: T` send-off equivalence** | LSU, Race Club ("on 30 secs", "@:45", "on 1:35") | Three equivalent prepositions; parser should accept all. |
| 19 | **`300 SPKPdD` micro-set acronym** | Eagle, USMS workbook article | Named ordered-modalities abbreviation. |
| 20 | **Mid-set break: `1-minute break`** | Race Club, SwimSwam | A rest block between main-set sections that has a fixed duration and *no swim*. |
| 21 | **`Choice Desc` / choice-desc with sub-stroke bands** | LSU ("Choice Red", "Choice Blue") | Color-band + stroke-choice mapping; the per-rep rotation can be tie-breakable via color. |
| 22 | **`on ~T` tilde interval (= approximately)** | Scattered | Approximate/auto-adjusted interval. |
| 23 | **Range distance: `50-100 easy`, `interval 2:00–2:30`** | Mike Bottom, Eagle | Distance/rest expressed as a range, often swimmer-determined. |
| 24 | **Bucket / chute / tower overhead conditioning block** | LSU buckets, Eagle Power Towers, SportPlan | The block is gear-attached; reps use the same equipment throughout. |

## Net-new themes vs the existing research file

The earlier 512-line `swim_notation_raw_examples.md` emphasizes broken
swims, pace ladders, HR targets and round-of-composite structures. The
gaps above add three new themes:

1. **Stations & rotation circuits as a workout-level primitive** (Eagle).
2. **Pace-target / test-set / fail-rule notation** (USRPT, TritonWear).
3. **Zone annotations / color-band language / segment-of-rep directives**
   (LSU, Race Club, Mike Bottom) — the actual vocabulary of a
   "championship coach" as opposed to a masters-club coach.

## Recommended next steps for Hydrolyze parser

1. Define a `zoneAnnotation` token on `rep|set|session` with values
   drawn from `{REC, EN1, EN2, EN3, SP1, SP2, SP3, Z1..Z5, A1..A3}` and
   accept any of `Z2`, `A2`, `Zone 2`, `EN 2`, `Recovery`, `Red`, `Pink`,
   `Blue`, `Purple`, `Green`, `Black`, `White` as aliases (LSU uses
   the color system).
2. Add a `targetTime` field on reps that accepts a literal time
   (`12.5`, `1:14`) and recognises the `target`, `for time`, `race
   pace`, `RP`, `200P` keywords.
3. Add `failRule` metadata on sets whose reps have `targetTime`.
4. Add a `rotation` block type describing `N × M` where M is a length-N
   list cycling with wrap-around.
5. Add `nRounds: N` plus free-form `bullets: string[]` as a round-header
   grammar equal in status to `N x through:`.
6. Add `odds: {interval?, action?}` and `evens: {interval?, action?}` on
   sets, supporting parallel intervals, parallel strokes, and parallel
   drills.
7. Recognise `walk-back <stroke>` and `easy backstroke` as recovery-mode
   rep directives.
8. Recognise `Stations:` block as a workout-topology primitive (N timed
   sub-blocks).
9. Detect descending-with-rest-modifier (`Desc 1-3 and 4-6`,
   `Descend 1->3, 4->6`).
10. Treat the brace-pair `[75 + 25]` as an alternative composite shell
    alongside `(75+25)`.
11. Lex `on`, `@`, `:` as equivalent send-off prepositions; lex
    `at`, `going`, `taking` as plain-English equivalents.
12. Add `equipmentByRound` for round-level gear progression ladders.
13. Add `overinterval` / `walk-back` / `easy backstroke` / `easy EZ`
    / `OTB` / `for time` to a coach-vocabulary dictionary and let the
    parser surface them as rich tags rather than free text.

These additions would let Hydrolyze confidently ingest Mike Bottom,
LSU, Eagle, Race Club, TritonWear, USRPT and SwimmingWizard workouts
without losing meaning — none of which the current parser does.
