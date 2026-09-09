# V0.54 S3.1 — Console PRE de-busy pass

**Surface:** `SessionConsoleView` PRE body (renders `WorkoutPreview` with
`context: .preview`). LIVE / BETWEEN / POST untouched unless noted.
**Branch:** `fix/fragment-decimal-distance-decode` (HEAD 1c9280f).
**Spec status:** Approved (S3 follow-up, no separate sign-off — S3 was the
last greenlit slice; S3.1 is a tight visual pass requested 2026-09-09
immediately after the S3 evidence screenshot).

---

## 1. Problem

Nathan's verbatim direction (2026-09-09, on `v54-s3/pre-jodie09.png`):

> "this page look way too busy. let's use the UI and layout to simplify the
> page without loosing any detail that the coach might need or want. delete
> redundant elements and elements that don't need to be there."

What he rejected two days ago (2026-09-08, jodie-09): flat one-liner
"◯ N | ZONE | label" rows. Rich anatomy (segment tracks, verbatim 12.5m
labels, send-offs, mode-3 ladder) is non-negotiable.

**Tension to hold:** information density stays the same — visual density
must drop. Repetition is the target, not information.

---

## 2. Current state — what's busy

From the `v54-s3/pre-jodie09.png` vision check (and code):

| Set | Type | Current render | Problem |
|-----|------|-----------------|---------|
| 0 | 400 free easy (warm-up) | One line "400 Free [Easy]" | OK — fragmentless, single row |
| 1 | 4×50 @ 1:00 Mode 1 (.track) — 25 race_rhythm / 25 easy | **4 cards** identical (segment track + send-off `@ 1:00` × 4 + gear badge × 4) | Collapse to 1 card × "×4" |
| 2 | 4×25 @ 1:00 Mode 1 (.track) — 12.5 strong / 12.5 easy | **4 cards** identical | Collapse to 1 card × "×4" |
| 3 | 6×100 @ 1:30 Mode 2 (uniform) — `Each: 50 @ 65% / 70% / 75%` caption | Compact one-liner + italic caption | Range `@ 65-75%` rendered twice (header + intensity field); pull chip repeats on every set. Trim redundancy. |
| 4 | 4×50 Mode 3 (DESCEND ladder) — 70/75/80/85 | Compact one-liner + 4 cards × `1/4` ... `4/4` | KEEP — Mode 3 reps differ. **But:** the header shows `@ 70-85%` + `[Hard]` + `↘ 1-4`; per directive rule 3, when `perRepTargets` is populated the ladder implies the range + zone, so the range text + `[Hard]` chip are redundant. |
| 5 | 8×25 free easy (warm-down) | One line "8×25 Free [Easy]" | OK — fragmentless, single row |

**Timing chrome** (set-1 footer `0:00.00 READY` + volume-button hint):
**NOT currently in PRE** — confirmed by vision on the screenshot. PRE
renders only `header → preWorkoutPreview → breadcrumb → startButton`.
**No stopwatch chrome leak.** Rule 5 is satisfied by the existing code;
no change needed. (Documentation of the check, not a code change.)

**Set 1 / Set 2 header-line duplication observed in screenshot:** the
vision report describes a "partially-clipped `... 400 Free [Easy]`" sit­ting
above Set 1 / Set 2 — that's actually **Set 0** (the 400 free warm-up)
being cropped by the workout-title area / overlap with the top bar. Not a
duplicate-render bug; it's the Set 0 fragmentless row above the Set 1
expanded cards. Acceptable — but I'll confirm visually in the post-fix
screenshot.

---

## 3. Objective

Reduce visual density of the PRE surface without losing information. The
fix is repetition collapse + per-set header dedupe + zone/ladder
disambiguation. Five rules, one commit, one screenshot, self-checked
against the must-NOT-lose list.

---

## 4. Dedupe rules (the pass)

### Rule 1 — Exemplar rep card for identical rep groups
If every rep in the group is identical (same fragments, same send-off),
render the rep card ONCE with a ×N multiplier badge. Exception: DESCEND /
progression sets (Mode 3) keep all rep rows because each rep DIFFERS.

**Applies to:** Mode 1 (`.track`) and Mode 2 (`.uniform`) when `reps ≥ 2`.
**Mode 3 (`.progression`) keeps all cards** (each has distinct per-rep
target).
**Fragmentless repGroups (Mode 2 single-fragment fallback) keep all
cards** because each card shows the same summary row anyway — but the
repCard count there is normally 1 (reps drives the count, not fragments).

Mechanism: when `count == 1 && reps ≥ 2` for Mode 1 / Mode 2, render the
single card with an additional "×4" badge trailing the send-off. The
collapsed `count == 1 && reps > 8` affordance from V0.53.1 (text "× N")
stays — but it now also fires at `reps == 2..≤8` when the rep set is
internally identical (the new case).

**Identification of "identical reps":** the repGroup's `fragments` list is
the same across all reps by construction (the rg is the parent of all
reps; one fragments list, N repetitions). The collapse fires on Mode 1
and Mode 2 paths by default — the per-rep-targets flag is what makes
Mode 3 stay expanded.

### Rule 2 — Say it once at the set header
Stroke, gear, zone chip, send-off belong to the SET header. The
exemplar rep card drops the repeated `@ 1:00` (it's on the header), drops
the repeated stroke word, drops the repeated gear chips.

Mechanism: render the set-level headerLine (×N + parent distance +
stroke + zone + interval + gear + dive/suit) ABOVE the exemplar card.
The single card omits the send-off (it's in the header) and the gear
chips (also in the header). Mode 3 is unchanged because its per-card
content already varies.

**Already partially in place:** `PairRepGroupRow.headerLine` already
shows ×N + distance + stroke. The directive asks for the full set-level
context — add gear + zone chip + interval.

### Rule 3 — Range OR ladder, never both
When `perRepTargets` is populated (Mode 3 ladder), the header shows
`DESCEND` and DROPS:
- the `@ 70-85%` range text (the ladder implies it)
- the `[Hard]` zone chip (the ladder implies it)

Mechanism: in `ProgressionRepGroupRow.headerLine`, guard the `intensity`
text + `zoneTerm` chip behind `perRepTargets == nil`. The set's range
lives implicitly in the 70/75/80/85 cards below — coach reads the
ladder, not the header range.

### Rule 4 — Kill duplicated compact row above expanded sets
Currently `RepGroupRowView.body` gates the compact `HStack` (the
`spineText` + intensity + zone + interval + gear + dive/suit row) on
`!hasFragments` — so for sets WITH fragments (Mode 1 / Mode 2 with
multiple fragments / Mode 3) the compact row does NOT render. No
duplication.

For Mode 2 single-fragment (or no-fragment) repGroups, the compact row
DOES render, but there's no expanded card below it (the single-
fragment fallback path renders the FragmentCTARow + the `Each:` note).
No duplication either.

**No code change needed for rule 4.** Documented.

### Rule 5 — No timing chrome on PRE
**Already satisfied.** PRE body has no stopwatch footer. Confirmed by
vision on the existing screenshot. Documented.

### Rule 6 — Quiet the hierarchy
Set index as a small mono numeral (1, 2, 3…) instead of wordy labels;
secondary text contrast bumped one step; headers carry the set spine;
captions stay italic below.

Mechanism:
- The `headerLine` ×N token already uses `.font(.numeric)` and
  `.foregroundColor(Color.accentAmber)` — this is the existing visual
  hierarchy. Keep it.
- The Set 3 compact one-liner currently renders `@ 65-75%` as the
  intensity text in amber — the directive asks to keep the range
  (because perRepTargets is nil), so keep the amber range.
- Set 4 (Mode 3) ladder renders each card's per-rep target as an
  amber-pill chip — that's already the "set spine" the directive names.
- The "rep N / 4 ×" legibility nit: the `totalReps` path in
  `ProgressionRepCard` uses `.font(.numericSmall)` + `Color.textFaint`.
  The directive asks to bump contrast one step. Use `.font(.caption)`
  + `Color.textMuted` instead. ONE step up, not to textPrimary (would
  compete with the per-rep target pill).

---

## 5. Acceptance — must NOT lose

Verbatim 12.5m fragment labels ("12.5m strong", "12.5m easy"),
segment intensity words ("race rhythm", "strong", "easy"), `Each:`
captions, DESCEND ladder values (70/75/80/85), send-offs (`@ 1:00`,
`@ 1:30`), gear (`[Pull]`, `[SUIT]`), DIVE markers, warm-up/warm-down
rows (400 free, 8×25), attendance breadcrumb, single START SESSION CTA,
one primary CTA invariant.

---

## 6. Components affected

- `ios-native/Hydrolyze/Sources/Views/Components/WorkoutPreview.swift`
  - `PairRepGroupRow` (Mode 1) — set-level headerLine, exemplar card path,
    gear + zone + send-off dedupe to header.
  - `UniformRepGroupRow` (Mode 2) — same exemplar/header dedupe as Mode 1.
  - `ProgressionRepGroupRow` (Mode 3) — drop range + zone chip when ladder
    is populated (rule 3).
  - `ProgressionRepCard` — bump `n/total` contrast one step (rule 6).

- `ios-native/Hydrolyze/Tests/V0541RepCardExemplarCollapseSmoke.swift`
  - New file: contract for `repCardCount(...)` extended to collapse
    Mode 1/2 identical reps at `reps == 2..≤8` (not just `> 8`).
  - Existing V0.53.1 smoke stays; new smoke is additive.

No DB / no service changes. No schema. No preview-Xcode body change.

---

## 7. Code style

Match existing patterns in `WorkoutPreview.swift`. Update V0.54 S3.1
comments with provenance (date + jodie-09 feedback chain).

---

## 8. Testing strategy

- **Standalone smoke** (`swift` of the new smoke file) — verifies
  `repCardCount(reps: 2..8)` returns 1 for Mode 1/2 paths (the new
  exemplar collapse).
- **`xcodebuild` on macstudio-tailnet** (Gate 1).
- **Screenshot** (`-v54-demo-console-jodie09` on iPhone 17 Pro Max sim,
  F159B790-E10B-41C5-B970-7B400D26854D) → `ios-native/screenshots/v54-
  s31/pre-jodie09.png`.
- **Vision self-check on the screenshot:**
  - (a) every must-NOT-lose item still present (verbatim 12.5m, "race
    rhythm", Each: caption, 70/75/80/85 ladder, send-offs @ 1:00/@ 1:30,
    [Pull], [SUIT], DIVE, 400 free, 8×25, attendance breadcrumb, START
    SESSION);
  - (b) Set 1 = ONE card with ×4 badge (instead of 4 cards);
  - (c) Set 2 = ONE card with ×4 badge (instead of 4 cards);
  - (d) Set 4 (Mode 3) = 4 distinct cards (70/75/80/85) with no @ 70-85%
    range + no [Hard] chip in header.
- Report (b)/(c)/(d) explicitly. Any spec deviation noted in commit.

---

## 9. Boundaries

**Always:** the S3 S3.1 invariant that PRE keeps zero-CTA, rich anatomy.
**Ask first:** any change that touches LIVE/BETWEEN/POST surfaces.
**Never:** drop verbatim labels, drop the Each:/Descend: captions, drop
the ladder, drop gear/DIVE/SUIT, drop the breadcrumb, drop START
SESSION.

---

## 10. Implementation slice

One commit:

```
V0.54 S3.1 — Console PRE de-busy: exemplar rep cards, set-level dedupe, no timing chrome on PRE
```

Files:
- `WorkoutPreview.swift` — 4 surgical edits (PairRepGroupRow,
  UniformRepGroupRow, ProgressionRepGroupRow, ProgressionRepCard).
- `V0541RepCardExemplarCollapseSmoke.swift` — new contract.

---

## 11. Success criteria

1. `swift ios-native/Hydrolyze/Tests/V0541RepCardExemplarCollapseSmoke.swift`
   exits 0.
2. `xcodebuild` on macstudio-tailnet returns `** BUILD SUCCEEDED **`.
3. Screenshot captured. Vision self-check on (a) must-NOT-lose + (b)
   Set 1 = one ×4 card + (c) Set 2 = one ×4 card + (d) Set 4 = ladder
   without range/zone duplication.
4. Tree clean after commit.
