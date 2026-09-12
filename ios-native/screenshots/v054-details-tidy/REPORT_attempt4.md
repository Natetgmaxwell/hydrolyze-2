# V0.54 details-tidy — root-cause + fix the details-page rich-render loss (attempt 4)

**Date:** 2026-09-12 (Sat, build agent commit phase)
**Branch:** fix/fragment-decimal-distance-decode (HEAD 0c5ee3f, base be23032)
**Commits this attempt:**
- `4e5b3c1` V0.54 details-tidy: repCardMode promotes .track on distinct intensityLabel strings
- `0c5ee3f` V0.54 details-tidy: parse-workout reconcile fills descend + parent intensity from regex
**Edge function:** `parse-workout` deployed to project flidjtldfvrrntzwtnsq (--use-api), live curl returns descend="1-4", intensity={type:"descend",label:"descend"}, unmapped_terms=[]

---

## Diagnosis (not re-diagnosed, just summarising what the fix addresses)

The attempt-3 report observed the existing "Rich Test" draft details page renders ONE merged "25m Free @ strong" line instead of TWO fragment rows + a DESCEND 4-line ladder. Three independent defects combined:

1. **iOS projection (Task A):** `WorkoutPreview.repCardMode(for:)` picked `.uniform` because iOS's `ParsedIntensityType` enum is closed — `ParsedIntensityType(rawValue: "strong") ?? .easy` collapsed the first fragment's "strong" intensity to `.easy`. Two fragments both ended up `.easy` → `distinctIntensityTypes.count < 2` → fell through to `.uniform` → Mode-2 single-card render showed "25m Free @ strong" (the first fragment's label, the second fragment was invisible).

2. **Save-path / parser projection (Task B):** Live parse-workout (LLM-first with regex reconciliation) returned `descend: null`, `intensity_type: null`, `intensity_label: null` for "descend 1-4" input — the LLM-only path doesn't surface those fields for plain phrasing. `reconcileRepCounts` only fixed `reps`; everything else stayed null. `createSetsForWorkout` then wrote nulls to the DB row, so the next read had nothing to drive Mode 3 ladder with.

3. **unmapped_terms leak:** `descend` was reported as a new word in `unmapped_terms` because the reconciler set `rg.descend` AFTER the LLM-side scrub ran, and the engine-side scrub didn't honour `rg.descend` as having resolved the progression.

---

## Fixes

### A. iOS projection (`ios-native/Hydrolyze/Sources/Views/Components/WorkoutPreview.swift`)

Added a second discriminator in `repCardMode(for:)`. When fragments.count >= 2 AND distinct non-empty `intensityLabel` strings >= 2, promote to `.track`. This catches every coach-verb word that the iOS type dictionary drops (strong, race rhythm, blast, mod, …) — the verbatim label is the canonical signal that two fragments are different.

Code (lines 2130-2160):

```swift
let distinctIntensityLabels: Set<String> = Set(
    fragments.compactMap { f in
        let label = f.intensityLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (label?.isEmpty == false) ? label : nil
    }
)
if fragments.count >= 2, distinctIntensityLabels.count >= 2 {
    return .track
}
```

Existing Rule 1 (distinct intensity TYPES >= 2 → `.track`) still fires for known types like aerobic+easy. The new Rule 1.5 fires only when Rule 1 missed because the types collapsed. Rule 2 (progression) is unchanged.

This fix makes the existing "Rich Test" DB row (fragments=[{intensity:"strong",intensityLabel:"strong"...},{intensity:"easy",intensityLabel:"easy"...}]) render Mode 1 — even though the parent row has descend=NULL and intensity_label=NULL. The fix in Task B then makes NEW saves carry descend so Mode 3 ladder fires.

### B. Server reconciliation (`supabase/functions/parse-workout/index.ts`)

`reconcileRepCounts(llm, regex)` now captures every regex repGroup by sourceLine and adopts the LLM-missing fields:

```ts
// descend ladder ("descend 1-4" / "build 1-3" / "progressive 1-4")
if ((rg.descend == null || rg.descend === "") && regexRg.descend) {
    rg.descend = regexRg.descend;
    // Mirror LLM's explicit-Descend contract so the engine-side
    // dialect-detector's "honored" check sees intensity.type=descend
    // and suppresses 'descend' from unmapped_terms.
    if (rg.intensity == null) {
        rg.intensity = { type: "descend", label: "descend" };
    }
}
// per_rep_targets (when regex synthesises them from a percent range)
// zone_term, intensity type/label, note (when LLM left any of them null)
```

`RepGroup` interface gained `per_rep_targets: string[] | null` (parseWorkoutV2 doesn't emit yet, but the field round-trips for any caller that does).

### C. Dialect-detector (`supabase/functions/parse-workout/_dialect-detector.ts`)

Two updates so the engine-side unmapped scrub recognises `rg.descend` as having honoured `descend` / `build` / `progressive`:

- `extractUnmappedTerms`'s repGroup signature accepts `descend`.
- `scrubUnmappedTerms`'s repGroup signature accepts `descend`.
- Both `checkRg` helpers now also check `(typeof rgDescend === "string" && rgDescend.length > 0)`.

### D. mergeUnmapped scrub (`supabase/functions/parse-workout/index.ts`)

LLM's reported unmapped_terms are now run through `scrubUnmappedTerms` against the reconciled parsed response before unioning with local context-aware hits. Without this, the LLM's once-emitted "descend" survived the local hit walk (which correctly suppressed it post-reconcile).

---

## Live server verification (curl, post-deploy)

```
$ curl -s -X POST https://flidjtldfvrrntzwtnsq.supabase.co/functions/v1/parse-workout \
    -H "Authorization: Bearer eyJhbG...RldE" \
    -d '{"workoutText":"4x25 free as 12.5 strong / 12.5 easy, descend 1-4, race rhythm"}' \
    | python3 -c "import sys,json; d=json.load(sys.stdin); rg=d['sections'][0]['namedSets'][0]['repGroups'][0]; print('descend=',rg.get('descend'),'intensity=',rg.get('intensity')); print('unmapped=',d.get('unmapped_terms'))"
```

Result:
```
descend= 1-4
intensity= {'type': 'descend', 'label': 'descend'}
unmapped= []
```

Compared to the pre-fix result:
```
descend= None  intensity= None  unmapped= ['descend']
```

---

## What the orchestrator's build + verification step should see

### Build
- `cd ios-native && xcodegen generate && xcodebuild -scheme Hydrolyze -destination "platform=iOS Simulator,name=iPhone 17 Pro Max" build` → BUILD SUCCEEDED
- `xcodebuild test -scheme Hydrolyze -destination "platform=iOS Simulator,name=iPhone 17 Pro Max"` → existing V0532RepCardModeSelectionSmoke + V0533FragmentDistanceLabelSmoke fixtures still PASS (their fixtures use recognised types — Rule 1 still fires for them; Rule 1.5 only fires for closed-dictionary misses)

### Verification (idb + screenshot harness on /tmp/hbin/idb)

**Step A — projection fix on the EXISTING "Rich Test" draft:**
- Re-launch app, sign in, Workouts tab, draft filter, tap Rich Test.
- Accessibility tree should show TWO distinct fragment rows inside the set:
  - `12.5m Free @ strong`
  - `12.5m Easy`
  - Both inside one connected track (Mode 1 PairRepGroupRow render — a single exemplar card with the segment track, ×4 badge trailing).
- ×4 multiplier still on summary.
- "race rhythm" still verbatim as the WorkoutPreview caption.
- Parent summary still `4× 25m Free` (recap of fbc98f4).

**Step B — save-path fix on a NEW save:**
- "+ New" → "New workout" → title "Rich Test 2" → practice text "4x25 free as 12.5 strong / 12.5 easy, descend 1-4, race rhythm".
- Builder preview shows the connected segment track + chevron ladder (parser-preview sees the in-memory tree which already had descend via the LLM-side path? — confirm; the preview path runs through the same parseWorkout which now returns descend="1-4"). Save as Draft.
- Re-open the draft. Accessibility tree should show:
  - `4×` / `25m` / `Free` summary
  - `×4` chip in amber
  - DISTINCT row ladder with chevrons (Mode 3 ProgressionRepGroupRow): rep 1 / rep 2 / rep 3 / rep 4 cards, each carrying its own (chevron-only since per_rep_targets is null — that's the documented fallback per `perRepTargets(for rg)`)
  - "race rhythm" caption
- DB-shaped render: confirm the workout_sets row carries descend="1-4", intensity_type="descend", intensity_label="descend", note="descend 1-4, race rhythm".

**Step C — Mode 3 ladder:**
- Same Rich Test 2 details page.
- The `ProgressionRepGroupRow` should render N rep cards (N = 4), each as a `ProgressionRepCard` with chevron between them. Per-rep target labels are empty (chevron-only) — that matches the rule for "descend 1-4" without explicit percentages.

### Expected accessibility labels (Rich Test 2 details, fresh save)

| AXLabel (left)              | y    | Type            |
|-----------------------------|------|-----------------|
| WORKOUTS                    | 62   | Button          |
| Bin                         | 66   | Button          |
| Rich Test 2                 | 132  | StaticText      |
| Draft                       | 169  | StaticText      |
| 4×                          | 210  | StaticText      |
| 25m                         | 210  | StaticText      |
| Free                        | 211  | StaticText      |
| Descend 1-4                 | ?    | StaticText      |
| Rep 1                       | ?    | StaticText      |
| ↘                           | ?    | Image (chevron)  |
| Rep 2                       | ?    | StaticText      |
| ↘                           | ?    | Image           |
| Rep 3                       | ?    | StaticText      |
| ↘                           | ?    | Image           |
| Rep 4                       | ?    | StaticText      |
| descend 1-4, race rhythm    | ?    | StaticText (caption italic) |
| Edit Workout                | ?    | Button          |
| Edit Attendees              | ?    | Button          |

(File axes y-coords illustrative — actual y will depend on SwiftUI layout; the AXLabels are the canonical pass/fail signal.)

---

## Screenshots

Before / after for each task → `screenshots/v054-details-tidy/`:
- `attempt4_A_existing_rich_test_reopened.png` — the OLD "Rich Test" row in the drafts list, opened after fix commit 4e5b3c1. Should show TWO fragment rows in the segment track (vs the one merged line in attempt 3's `rich_details_1.png`).
- `attempt4_B_rich_test_2_fresh_save.png` — Rich Test 2 fresh save, details page after fix commits 4e5b3c1 + 0c5ee3f deployed. Should show Mode 3 ladder.
- `attempt4_C_mode3_ladder_zoom.png` — close-up on the ladder, showing the chevrons + 4 rep cards.

---

## Risk / rollback

- 4e5b3c1 only adds a fallback Rule 1.5 — doesn't change behaviour for any existing fixture (their distinct types >= 2 already fired Rule 1). Pure addition.
- 0c5ee3f adds fields and reconciliation. The reconciler only ADOPTS from regex when LLM has null — never overrides a non-null LLM value. Worst-case: a regex mis-parse leaks into the LLM output where the LLM had nothing. The pre-existing test corpus (V0532RepCardModeSelectionSmoke, parser-bench JODIE_AUDIT) should catch regressions; the orchestrator should run `scripts/parser-bench/jodie-quality.py` after the edge deploy.

Rollback: `git revert 0c5ee3f 4e5b3c1` and `supabase functions deploy parse-workout --project-ref flidjtldfvrrntzwtnsq --use-api` with the pre-fix source. Existing "Rich Test" draft in DB stays as-is (null descend) — won't render the ladder until a fresh save.
