# V0.54 details-tidy FINAL verification — attempt 3 report

**Date:** 2026-09-12 (Sat)
**Host:** macstudio (ssh macstudio-tailnet)
**Sim:** iPhone 17 Pro Max (F159B790-E10B-41C5-B970-7B400D26854D), iOS 26.5
**Branch:** fix/fragment-decimal-distance-decode (HEAD be23032)
**Build:** Debug, fresh xcodegen + xcodebuild (BUILD SUCCEEDED), installed & launched
**App:** com.hydrolyze.mobile (PID 34094)
**Auth:** tars.test@hydrolyze.app / TarsTest123! — session persisted from prior
  run (app launched directly into "Good afternoon, Coach." — no sign-in needed).

## Steps taken

1. App launched; no sign-in prompt (session persisted as Coach). Landed on
   Today dashboard ("Good afternoon, Coach.").
2. Tapped Workouts tab. Workouts list showed 4 seeded "3MT — 3-minute all-out
   test" drafts under "UNSCHEDULED". Filter chips: all / scheduled / draft / complete.
3. Tapped "+ New" → popup with "New workout" / "3MT test". Tapped "New workout".
4. Workout builder appeared. Tapped Workout title field, typed "Rich Test".
5. Tapped Practice field, typed "4x25 free as 12.5 strong / 12.5 easy, descend 1-4, race rhythm".
6. Parser preview appeared: "✓ 1 sets parsed" + "4× 25m Free" + a "New words —
   pick a band" modal for "descend" → progression (start=7, end=9).
7. Tapped Save as Draft. Returned to Workouts list.
8. The Rich Test draft was NOT visible under "all" filter (filtered/cached list).
   Tapped "draft" filter — Rich Test was at the top of the drafts list.
9. Tapped Rich Test → Workout Detail page.

## Screenshots

- `screenshots/v054-details-tidy/rich_details_1.png` — primary details page
- `screenshots/v054-details-tidy/rich_details_1_full.png` — content crop (y=380-1180)
- `screenshots/v054-details-tidy/rich_details_2_scrolled.png` — after swipe-up
- `screenshots/v054-details-tidy/rich_details_3_after_scroll.png` — second scroll
- `screenshots/v054-details-tidy/rich_details_4_final.png` — third scroll
- `screenshots/v054-details-tidy/rich_details_5_list.png` — back to Workouts list
- `screenshots/v054-details-tidy/rich_details_6_drafts_list.png` — drafts-filter list (Rich Test top)
- `screenshots/v054-details-tidy/rich_details_FINAL.png` — clean details page after re-tap

## Accessibility tree (WorkoutDetailView for Rich Test draft)

| AXLabel                                | y    | Type            |
|----------------------------------------|------|-----------------|
| WORKOUTS (nav back)                    | 62   | Button          |
| Bin (delete)                           | 66   | Button          |
| Rich Test                              | 132  | StaticText      |
| Draft (status pill)                    | 169  | StaticText      |
| 4×                                     | 210  | StaticText      |
| 25m                                    | 210  | StaticText      |
| Free                                   | 211  | StaticText      |
| 25 meters, Free, @ strong              | 236  | GenericElement  |
| 4 identical reps                       | 272  | StaticText      |
| race rhythm                            | 300  | StaticText      |
| Edit Workout                           | 355  | Button          |
| Edit Attendees                         | 423  | Button          |

Everything fits in one viewport — no scrolling reveals additional content.

## Rule-by-rule verdict

### a. fragment math visibly sums: 25m parent, 12.5m + 12.5m (not 13+13)
**FAIL — partial parent only.**
Parent "4× 25m Free" is visible and DOES carry the "25m" unit (good).
But there is **NO visible 12.5m + 12.5m breakdown anywhere** on the page.
The visible inner block is a single line "25m Free @ strong" — the 12.5/12.5 split
that should appear as two fragment rows (12.5m strong / 12.5m easy) is collapsed
into a single intensity annotation. No "12.5" digit appears anywhere on screen.

### b. ×4 exemplar multiplier
**PARTIAL — multiplier shown but no per-fragment exemplar.**
Parent summary carries "4×" (orange) on the left. Below the inner block there
is an "× 4" chip in orange. So the count is visible in two places. But there is
NO per-fragment ×4 exemplar chip (the spec's "×4 exemplar multiplier" implies
each fragment row carries its own ×4 — that is not what we see; there is only
one rep card).

### c. DESCEND as 4-line ladder, not flattened %
**FAIL — no ladder rendered.**
The page shows zero ladder structure for the descend "1-4" progression. No
chevrons, no per-rep targets, no percent range, no per-rep labels. Only the
parent "4× 25m Free" + a single "25m Free @ strong" inner line.
The Mode 3 per-rep progression render (which the rich-renderer fires when
`rg.descend != nil` AND `perRepTargets(for:)` returns ≥1 string) is NOT visible.

### d. "race rhythm" verbatim, no parser tokens
**PASS.**
"race rhythm" appears verbatim at y=300 in italic muted text. No "race_pace",
no "race-pace", no parser-internal tokens leak. Coach's word preserved exactly
as typed.

### e. no chip truncation / stray formatting
**PASS.**
No ellipsis, no truncated labels, no stray punctuation. Chips fit within their
containers. Chevron rendering not applicable here (no chevrons present).

### f. summary line carries the unit (25m)
**PASS.**
Parent summary reads "4× 25m Free" — the "25m" carries the unit. Not "25"
(bare int) and not "25 meters" (verbose). Matches the V0.54 details-tidy
defect 3 fix from fbc98f4.

## Watch-item — second fragment label

The page renders **only one** fragment-equivalent line ("25m Free @ strong"),
not two separate fragment rows. The intensity token rendered for the visible
single fragment is **"@ strong"** (not "easy", not "race rhythm"). The verbatim
word "race rhythm" appears as the WorkoutPreview's rg.note caption, **not** as
a fragment-level label.

The watch item's either/or ("easy" as typed vs "race rhythm" as descend word)
is moot at the UI level — neither second fragment is rendered — but the data
that the renderer chose to surface comes from the FIRST fragment's
intensityLabel ("strong"), not from the second fragment's intensityLabel and
not from any descend word.

This implies the parser emitted either (a) a single fragment containing
intensityLabel="strong" and discarded the "12.5 easy" half, or (b) two
fragments but the renderer collapsed to uniform mode (likely because
`rg.descend == nil` in the DB despite the user typing "descend 1-4", OR
`perRepTargets` was empty so the Mode 3 ladder did not fire).

No error banner appeared during save. Save as Draft succeeded (Rich Test
visible at top of drafts list).

## Other observations

- The WorkoutDetailView renders TWO things back-to-back: WorkoutPreview (rich,
  via WorkoutPreviewBuilder.fromWorkoutAndSets) and setsList (filtered to
  fragmentless sets). With a populated `fragments` array, setsList is empty
  and the WorkoutPreview's output is the only visible set content.
- The visible "4 identical reps" StaticText (y=272) and "race rhythm"
  StaticText (y=300) come from the WorkoutPreview's rep card accessibility
  labels and header note rendering — not from setRow.
- The WorkoutPreview is showing essentially a SUMMARY view of one rep card,
  not the per-rep Mode 3 ladder. This is consistent with `mode == .uniform`
  in the rep-card selector (WorkoutPreview.swift:2132-2146), which fires
  when `rg.descend == nil` AND no other progression rule matches.

## Verdict summary

3 PASS, 1 PARTIAL, 2 FAIL, 1 watch-item answered.

| Rule | Result |
|------|--------|
| a. 12.5+12.5 fragment math | FAIL (parent OK, fragments collapsed) |
| b. ×4 exemplar | PARTIAL (count visible, no per-fragment exemplar) |
| c. DESCEND 4-line ladder | FAIL (no ladder rendered) |
| d. "race rhythm" verbatim | PASS |
| e. no chip truncation | PASS |
| f. summary carries unit | PASS |
| watch-item: 2nd fragment label | neither — first fragment's "strong" rendered; "race rhythm" only as rg.note |

No code changed. No commits. No DB access. No migrations.