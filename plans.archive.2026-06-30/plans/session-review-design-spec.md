# v1.14 SessionReviewView Design Spec — Polish the pairing review surface

**Chunk:** v1.14 (SessionReviewView UX)
**Date:** 2026-06-18
**Status:** Draft — pending sign-off
**Source:** `Hydrolyze/Sources/Views/SessionReview/SessionReviewView.swift` (v1.13.x working tree, 366 lines); `Hydrolyze/Sources/ViewModels/SessionReviewViewModel.swift` (v1.15.2, 357 lines)

---

## 1. Problem

The pairing engine is solid (V10 algorithm, single-Hungarian, velocity-space cost; 374 lines of CLI tests in the v1.13.2 working tree). The friction is in the **review surface** where the coach deals with the engine's output. Current pain:

- The variance hint on a low-confidence row is **tiny gray text** at the bottom of the row. It's the single most useful diagnostic the engine gives the coach, and it's the least prominent thing on the page.
- The "Confirm" button says **"Confirm Anyway"** when any row needs review. That wording implies defeat ("I give up, accept the mess"). It should reinforce the positive path.
- The **filter is binary** — "All" vs "Needs Review" — so the coach sees a single bucket of "things to deal with." A row at 49% confidence and a row at 0% confidence get equal treatment; they don't deserve it.
- **No bulk action.** The coach can't say "these 4 are all good, save the rest with the issue flagged." They tap one at a time.
- The ReassignSheet is a **flat list of all swimmers** with no visual hierarchy. The coach has to know the answer in their head before they tap; the sheet doesn't help.

These are the surface that the user described as "keeps unpolished." The recent uncommitted working tree (965 lines across 12 files) is iterating on this — the variance hint and Mark-actual-intensity features are recent wins, but the surrounding polish is still rough.

---

## 2. Objective

Make a 20-row review (typical) completable in **≤30 seconds** with **zero ambiguity** on which row the coach must touch. Specifically:

- **Default-to-assign respected:** when the engine has high confidence, the coach does **nothing** — the row is already accepted, the Confirm button just says "Save."
- **Loud variance hint:** when confidence is low, the variance hint is the **loudest** element on the row, not the quietest. The coach understands "why is this flagged" in <1 second per row.
- **Bulk accept for "likely correct":** a single gesture accepts all rows at 40-79% confidence. These are the cases where the engine is right but a noise spike pushed the score down. The coach knows this pattern.
- **Likely-wrong first:** the default review filter surfaces 0-39% confidence rows first. The coach deals with the genuine errors, then one-tap-accepts the noise.

**Non-goals for v1.14:**
- Grouping by swimmer (Tier 3 — significant structural change; deferred to v1.15+)
- Confidence color palette overhaul (the cyan/red is fine; the issue is the variance hint, not the color)
- ReassignSheet rebuild (Tier 2 — included, scoped tight)
- Anything in `PairingEngine.swift` (the algorithm is settled for v1.14)

---

## 3. Visual Design

### 3.1 Color tokens (existing — no new colors)

All colors already in the codebase (`Color(hex: ...)` in the existing view). No new palette entries.

| Token | Hex | Used for |
|---|---|---|
| Background | `#060e18` | Page bg |
| Surface | `#0d1f33` | Bottom sheet bg, confirm button container |
| Cyan accent | `#09d4ee` | Active state, primary button, "Looks good" |
| Text primary | `#e2f4fa` | Body |
| Text dim | `#4a6572` | Secondary labels, lane/wave chips |
| Amber | `#f59e0b` | "Likely correct" low-confidence band (new in v1.14) |
| Red | existing | "Likely wrong" — only for confidence < 30% (new threshold) |
| Green | existing | "Auto-accepted" — confidence ≥ 80% |

### 3.2 Confidence band rework

| Band | Confidence | Visual | Behavior |
|---|---|---|---|
| **Auto-accepted** | 80-100% | Green dot, no hint, no action needed | Row is in "All" only, not in "Needs Review" |
| **Likely correct** | 40-79% | Amber dot, variance hint visible, single-tap "Accept" | Bulk-acceptable; row in "Needs Review" but in sub-filter "Likely correct" |
| **Likely wrong** | 0-39% | Red dot, variance hint **prominent** (large, near top), single-tap "Reassign" | Must be touched individually; default filter shows these first |

### 3.3 Layout (proposed)

```
┌─────────────────────────────────────┐
│  Review                       [⚙]   │
│                                     │
│  ┌──────┬──────┬───────────────┐   │
│  │ All  │Likely│ Likely Wrong  │   │  ← three tabs
│  │      │Corr. │   (3)         │   │
│  └──────┴──────┴───────────────┘   │
│                                     │
│  ── Likely Wrong (3) ──             │  ← sticky section header
│                                     │
│  ╔═══════════════════════════════╗  │
│  ║ ⚠ Predicted 30.1s, actual    ║  │  ← loud, top-of-row, red
│  ║    39.6s (3.2σ off)          ║  │
│  ║ ─────────────────────────────║  │
│  ║ Fiona · Lane 3 · Wave 1      ║  │
│  ║                    39.6s  →  ║  │
│  ╚═══════════════════════════════╝  │
│                                     │
│  ╔═══════════════════════════════╗  │
│  ║ ⚠ Predicted 28.4s, actual    ║  │
│  ║    35.0s (2.4σ off)          ║  │
│  ║ ─────────────────────────────║  │
│  ║ Sam · Lane 1 · Wave 1        ║  │
│  ║                    35.0s  →  ║  │
│  ╚═══════════════════════════════╝  │
│                                     │
│  ── Likely Correct (2) ──           │
│  ┌───────────────────────────────┐  │
│  │ ℹ  Pred 32.1s, act 32.4s     │  │  ← quiet hint, amber
│  │   (0.3σ)  · Accept?  [✓] [↻] │  │  ← single-tap accept
│  │ Mae · Lane 2 · Wave 1  32.4s  │  │
│  └───────────────────────────────┘  │
│                                     │
│  ─────────────────────────────────  │
│  [  Save 4 with 1 flagged for       │  ← smart button text
│          review                  ]  │
└─────────────────────────────────────┘
```

### 3.4 Confirm button — smart wording

| State | Button label | Tap behavior |
|---|---|---|
| All rows ≥ 80% confidence (everything auto-accepted) | **"Save session"** | Saves immediately, dismisses |
| 1+ likely-correct rows, 0 likely-wrong | **"Accept 3 + save"** | Bulk-accepts likely-correct, saves |
| 0+ likely-correct, 1+ likely-wrong | **"Save 4 with 3 flagged"** | Saves, but flagged rows get a `needs_review: true` flag in the DB for later |
| 0 unconfirmed | (button hidden — no work to do) | — |

This removes the defeatist "Confirm Anyway" wording. The button always says what's about to happen.

---

## 4. Components affected

| File | Change | Slice |
|---|---|---|
| `SessionReviewView.swift` | Layout restructure, new tab strip, smart button | 1, 2, 3 |
| `SessionReviewViewModel.swift` | New `ConfidenceBand` enum, new filter `.likelyWrong` / `.likelyCorrect`, new `bulkAccept()` method | 1, 2 |
| `ReviewRowView` (in same file) | Variance hint promoted to top-of-row for "Likely Wrong" band; quick-action footer for "Likely Correct" | 2, 3 |
| `ReassignSheet` (in same file) | Sort swimmers by predicted-time proximity to the row's actual time (closest first); show predicted-time column | 4 |
| `LapAssignment` model | Add `band: ConfidenceBand` computed property (or derive in view-model) | 1 |

No changes to: `PairingEngine.swift`, `PairingEngineTest.swift`, `Swimmer.swift`, `SwimmerService.swift`, `VolumeButtonService.swift`, `WorkoutService.swift`.

---

## 5. Code Style

- Match existing `Color(hex: ...)` and `Font.system(size:, weight:, design:)` patterns. No new design tokens.
- Match existing computed-property layout for sub-views (`filterTabs`, `rowsList`, `confirmButton`).
- View-model logic stays pure-Swift; no UI imports.
- Confidence-band enum lives in `SessionReviewViewModel.swift` as a `CaseIterable` enum with a `color` and `prompt` property. No separate `ConfidenceBand.swift` file (premature factoring).

---

## 6. Testing Strategy

- **Unit tests** for the new `ConfidenceBand` enum and `bulkAccept()` method in `SessionReviewViewModel`. Mock the rows; assert band classification matches the v1.14 threshold table.
- **Visual verification** via Xcode preview (`#Preview { ... }` in `SessionReviewView.swift`) with three fabricated `ReviewRow` fixtures: one each in auto-accepted / likely-correct / likely-wrong bands.
- **Manual end-to-end** in simulator: run a real 20-row session, time the review flow, confirm ≤30s for the all-green path.
- **No CLI engine test changes** (the algorithm is untouched in v1.14).

---

## 7. Boundaries

- **Always:** Match the existing visual language. No new colors, no new fonts, no new spacing scale entries. Match the existing view-model test patterns. Surface tradeoffs in the response, not in code comments.
- **Ask first:** Changing the confidence thresholds (80/40) is a one-line code change but a product call. Don't tune without sign-off. Adding a new column to `recorded_times` or `sessions` is a DB migration — ask.
- **Never:** Modify `PairingEngine.swift`. Modify any migration file. Touch files outside `Views/SessionReview/`, `ViewModels/SessionReviewViewModel.swift`, and `Models/LapAssignment.swift` (only if the band property belongs there). Commit the uncommitted 12-file working tree without the user's approval.

---

## 8. Implementation slices (vertical, testable)

Each slice is a self-contained, build-and-preview-able increment. Commit after each.

### Slice 1 — `ConfidenceBand` enum + tab restructure (foundation)
- Add `ConfidenceBand` enum to `SessionReviewViewModel.swift` with `auto` / `likelyCorrect` / `likelyWrong` cases
- Add `.likelyCorrect` and `.likelyWrong` to the `Filter` enum
- Update `filterTabs` to render three tabs with band-aware counts
- Update `filteredRows` to apply the new filter logic
- **Verify:** preview shows the three tabs; filter selection changes the visible rows
- **Estimate:** ~50 lines + tests

### Slice 2 — Variance hint promotion (the "loud" fix)
- In `ReviewRowView`, when `row.band == .likelyWrong`, render the variance hint as the **first** child of the row, in **red** (`#f59e0b` amber for now per color decision), with a 13pt semibold weight instead of the current 11pt
- Move the existing 11pt gray variant into the `.likelyCorrect` band
- **Verify:** preview shows three rows with three different hint treatments
- **Estimate:** ~40 lines

### Slice 3 — Smart Confirm button + bulk-accept
- Replace the binary "Confirm Anyway" / "Confirm All" with the four-state smart wording (see §3.4)
- Add `bulkAccept()` method to `SessionReviewViewModel` that moves all `.likelyCorrect` rows into `coachConfirmedRowIds`
- Add a single-tap accept button on `.likelyCorrect` rows (✓ icon, inline)
- **Verify:** preview shows the right button label for each state; tapping the ✓ on a likely-correct row moves it to confirmed
- **Estimate:** ~80 lines + tests

### Slice 4 — ReassignSheet sort by predicted-time proximity
- In `ReassignSheet`, when the row is `.likelyWrong`, sort the swimmer list by `|predictedTime - actualTime|` ascending (closest first)
- Show a small "Pred: X.Xs" suffix on each row so the coach can see why it's sorted this way
- **Verify:** preview with a fabricated `actualTime` shows the sorted list with predicted times visible
- **Estimate:** ~60 lines + tests

### Slice 5 — Polish + commit working tree
- Visual sweep: spacing, hit areas (44pt minimum for tap targets), dark-mode sanity check
- **Commit the uncommitted 12-file working tree** (v1.13.0 variance hint, v1.13.1 mark-intensity, v1.15.1 multi-set bugfix, v1.15.2 code cleanup) as the v1.13.x baseline. This is **prerequisite** to the polish work — the spec builds on top of v1.13.x.
- **Verify:** clean working tree, v1.14 work-in-progress on a new branch
- **Estimate:** ~30 minutes

---

## 9. Success Criteria

A v1.14 SessionReviewView is "polished" when:

- **All-green path (most common):** coach opens review, sees "Save session" button, taps once, done. ≤5 seconds.
- **Likely-correct path:** coach opens review, sees "Likely Wrong (3) — Likely Correct (2)" tabs, taps the ✓ on the two likely-correct rows, taps "Save 4 with 3 flagged", done. ≤15 seconds.
- **Likely-wrong path:** coach opens review, sees 3 wrong rows with the variance hint **prominent**, taps each, picks the right swimmer from a **sorted** ReassignSheet, taps save. ≤30 seconds.
- **No defeatist wording** in the visible UI ("Confirm Anyway" is gone).
- **The 12-file working tree is committed** before this lands — the v1.13.x baseline is preserved.

## 10. Open questions (need user input before slicing)

1. **Commit the 12-file working tree first?** It's the prerequisite for the v1.14 work. I can do this as Slice 5, but the spec says "ask first" on out-of-scope commits. *(My recommendation: yes — it's the foundation.)*
2. **Threshold for the new "likely correct" band — 40% or 50%?** The v1.13.0 code uses 50% for "needs review" cutoff; the spec proposes 40% for the new band. Tighter = more rows need touching; looser = more rows auto-accepted. *(My recommendation: start at 50%, can tune after a real session.)*
3. **ReassignSheet scope (Slice 4) — in or out for v1.14?** It's the most structural change. Cutting it leaves the coach using a flat list until v1.15. *(My recommendation: in, but only the sort + predicted-time column. Save a full sheet redesign for v1.15.)*
4. **The "Likely Correct" quick-accept button — inline on the row, or in a sticky footer?** Inline is more discoverable per row; footer is one global action. *(My recommendation: both — inline for the per-row action, footer for the "Accept all" bulk action.)*
5. **Are Tier 3 changes (grouping by swimmer, color overhaul) deferred?** Spec says yes, but flagging in case the user disagrees. *(My recommendation: deferred to v1.15+ — they're each their own design problem.)*
