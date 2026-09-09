# V0.54 S3.3 — PRE round 2: progressive disclosure + chip-to-typography

Status: Draft → Approved (greenlit by task directive, 2026-09-09)
Branch: `fix/fragment-decimal-distance-decode` (HEAD 7384ba3 "V0.54 S3.2")
Scope: SessionConsoleView PRE body + `WorkoutPreview` PRE rendering only. LIVE/BETWEEN untouched.

## Problem

The S3.1/S3.2 pass killed the dual representation but the screen still
competes with itself: 12 outlined chip badges, two filled pace-bar pills,
and four per-rep percentage chip pills. Warm-up and warm-down take the
same vertical real estate as the four main sets they bookend. Nathan's
verbatim: "that's better but try and simplify the UI more, use some UI
trickery to accomplish it."

The S3.1/S3.2 must-not-lose list still applies verbatim: 12.5m, race
rhythm, Each:, ladder, send-offs, gear, dive/suit, breadcrumb, single CTA.

## Objective

Three UI tricks, applied surgically to PRE only:

1. **Progressive disclosure** — collapse warm-up (set 0) and warm-down
   (set 5) to a single quiet row with chevron. Tap expands.
2. **Chips → typography** — outlined `MetadataBadge`/`GearBadge` boxes
   become: zone (text color), send-off (quiet mono inline), gear/DIVE/SUIT
   (SF Symbols caption-sized), DESCEND (small-caps text).
3. **One hairline, no boxes** — a single Divider + 12pt intra-set / 20pt
   inter-set rhythm replaces the pace-bar pill backgrounds and the
   per-rep percentage chip outlines.

## Visual Design

### Before (S3.2)
```
400 Free [Easy]                          ← warm-up, full row
4× 50m Free on 1:00 [Pull] [DIVE]         ← set 1 header (5 chips visible)
[25m race rhythm | 25m easy] @ 1:00       ← filled pill
× 4
6× 100m Free [Steady] [on 1:30] [Pull]   ← set 3 header (3 chips)
Each: 50 @ 65% / 70% / 75%                ← italic caption
4× 50m Free [Pull] [on 1:00] [DESCEND]   ← set 4 header (3 chips)
1/4 [70%]                                 ← filled chip
↘
2/4 [75%]
↘
3/4 [80%]
↘
4/4 [85%]
8×25 Free [Easy]                          ← warm-down, full row
```

### After (S3.3)
```
400 Free ›                                ← collapsed (warm-up) — tap to expand
4× 50m Free on 1:00  pull  dive            ← gear/dive as SF symbols
25m race rhythm │ 25m easy       × 4
6× 100m Free  on 1:30  pull                ← 65-75% text already in row
Each: 50 @ 65% / 70% / 75%
4× 50m Free  on 1:00  pull  DESCEND        ← DESCEND small-caps text
1/4                              70%      ← % in mono text, no chip
↘
2/4                              75%
↘
3/4                              80%
↘
4/4                              85%
8×25 Free ›                                ← collapsed (warm-down)
```

### Zone color mapping
- `easy` → `textPrimary` (default cool)
- `steady` → `accentAmber` (warm)
- `hard` → `accentAmber` (same family, more emphatic)
- `sprint` → `accentAction` (coral, the loudest)

Easy keeps the muted primary text — adding a tint to "easy" would
*create* the loud the trick removes. Only Steady/Hard/Sprint get the
amber/coral treatment; the colored distance text carries the zone
without a chip.

### SF Symbol mapping
- `pull` → `hand.raised.fill` (the closest SF Symbol to a paddle)
- `dive` → `figure.dive` (available iOS 16+, matches the dive action)
- `suit` → `figure.pool.swim` (silhouette wearing a wetsuit)
- All three at `.caption` size + `textMuted` color, 8pt HStack spacing.

### Hairline rhythm
- Between sets: `Divider()` (1pt, `divider` color) + 20pt spacing.
- Within a set: 12pt spacing, no divider.
- Pace-bar pill backgrounds stay (they carry the visual continuity of
  the rep's two-intensity split) but drop the rounded background fill —
  segments render as 3pt tall bands inside a single hairline-bordered
  container.

## Components Affected

- `ios-native/Hydrolyze/Sources/Views/Components/WorkoutPreview.swift`
  - `RepGroupRowView` body (zone color on distance text, gate the
    collapsible predicate, hairline divider between rg bodies)
  - `PairRepGroupRow.headerLine` (chip → typography)
  - `UniformRepGroupRow.headerLine` (chip → typography, drops
    MetadataBadge for gear/dive/suit)
  - `ProgressionRepGroupRow.headerLine` (same)
  - `ProgressionRepCard` body (percentage chip → mono text)
  - `RepCard` body (drop the trailing `@ pace` chip — set-level already
    carries it once in the header)
  - `MetadataBadge` + `GearBadge` retained (still used by single-fragment
    fallback paths in LIVE; not deleted)
  - New `CollapsibleSetRow` view for the warm-up/warm-down collapsed path

## Implementation

### Slice 1 — Progressive disclosure + collapsible predicate

In `RepGroupRowView`, add:

```swift
private var isCollapsibleWarmupCooldown: Bool {
    // Conservative gate: only collapse truly low-information sets.
    guard context == .preview else { return false }
    guard let zone = rg.zoneTerm, zone == "easy" else { return false }
    guard rg.fragments == nil || rg.fragments?.isEmpty == true else { return false }
    guard rg.gear == nil || rg.gear?.isEmpty == true else { return false }
    guard rg.dive != true, rg.suit != true else { return false }
    guard rg.note == nil || rg.note?.isEmpty == true else { return false }
    guard rg.descend == nil, rg.perRepTargets == nil else { return false }
    guard rg.intensity?.type == .easy || rg.intensity?.type == nil else { return false }
    return true
}
```

Add `@State private var expanded: Bool = false` to `RepGroupRowView`.
The body dispatches between `CollapsibleSetRow` (collapsed default) and
the existing expanded render path.

`CollapsibleSetRow` (new):
- HStack: distance "400 Free" (zone-colored per the map) + Spacer +
  chevron Image(systemName: "chevron.right") rotated 0°/90° on tap.
- `.contentShape(Rectangle())` so the whole row is tappable.
- Tap toggles `expanded`; haptic `selection`.

### Slice 2 — Chips → typography

In each headerLine:
- `MetadataBadge(text: zoneTerm.capitalized, color: ...)` — REMOVED.
  Zone color is applied to the parent distance text instead via the
  zone color map (Slice 3).
- `MetadataBadge(text: "@ \(pace)")` (ProgressionRepGroupRow only — it's
  the only header still wearing the chip) — converted to inline
  `Text("on \(pace)")` with `.font(.captionStrong)` + `.foregroundColor(textMuted)`.
- `MetadataBadge(text: "DIVE", ...)` → `Image(systemName: "figure.dive")`.
- `MetadataBadge(text: "SUIT", ...)` → `Image(systemName: "figure.pool.swim")`.
- `GearBadge` (the outlined box) → `Image(systemName: "hand.raised.fill")`
  at caption + textMuted.
- `MetadataBadge(text: "DESCEND"/"BUILD", color: accentAmber)` → plain
  text with `.font(.caption)` + `.tracking(1.0)` + `.foregroundColor(accentAmber)`,
  no background.

For the inline-rep `RepCard`'s trailing-edge `@ pace` chip (line 3524):
it drops when `paceTargetText` is nil (the header now carries it once
per set). The set-level header path already passes `paceTargetText: nil`
for exemplar cards in Mode 1/2, but the non-exemplar path and the
single-fragment fallback still render the chip — change those callers.

### Slice 3 — Hairline + spacing

In `RepGroupRowView.body`'s outer VStack, replace the `spacing: 2` with
`spacing: 12` and add `.padding(.vertical, 4)` to each rg container.
Between adjacent rg containers in `SectionView`, add a `Divider()` with
20pt vertical padding.

The pace-bar pill backgrounds inside `RepCard` (line 3512) stay — they
carry the within-rep split — but the round-rect `Color.bgInset` fill
drops to a hairline border instead: `RoundedRectangle.stroke(lineWidth: 1)`.

In `ProgressionRepCard` (line 3269), the per-rep percentage pill
(`accentAmber.opacity(0.14)` bg + `accentAmber.opacity(0.35)` stroke)
is removed; the percentage renders as plain mono text
`.font(.numericSmall).foregroundColor(.accentAmber)` right-aligned, no
background, no border.

## Code Style

Match existing patterns: dated `// why` comments, `phase` markers for
each slice, no TODOs, no scope beyond this spec.

## Testing Strategy

- `swiftc -parse` on the modified file (local syntax gate).
- macstudio `xcodebuild` (the canonical gate) — per task directive.
- Two screenshots captured via simctl: one collapsed default, one with
  the warm-down expanded (tap-via-simctl path; if the harness doesn't
  support tap, launch with a `-v54-s33-expand-warmdown` flag to seed
  `expanded = true` for the warm-down only).

## Boundaries

**Always:** S3.1/S3.2 must-not-lose list verbatim — 12.5m, race
rhythm, Each:, ladder, send-offs, gear, dive/suit, breadcrumb, single
CTA. Zero chips on PRE after the pass.

**Ask first:** None. Task directive is explicit on all three tricks.

**Never:** Touch LIVE/BETWEEN state machines. Touch the elevation /
opacity logic in `RepGroupRowView`. Touch `RepCardMode` selection.
Delete `MetadataBadge`/`GearBadge` (LIVE's FragmentCTARow still uses
them for the per-row chrome). Touch unrelated files.

## Success Criteria

- First-glance PRE: warm-up + warm-down are single quiet rows with
  chevrons; main sets render with zone color carried via text color,
  gear/dive/suit as SF Symbols, send-off as inline mono text.
- Zero `MetadataBadge`/`GearBadge` on PRE.
- All S3.1/S3.2 must-not-lose items present and readable.
- Tapping a collapsed row expands it (verified via second screenshot).
- macstudio build: BUILD SUCCEEDED.
- Screenshots in `ios-native/screenshots/v54-s33/` (collapsed + expanded).
- Commit: `V0.54 S3.3 — PRE round 2: progressive disclosure + chip-to-typography`.

## Defaults (if "your defaults" fires)

- Zone color for `easy` → keep `textPrimary` (no tint).
- SF Symbol for `pull` → `hand.raised.fill` (best SF Symbol proxy).
- Pace-bar pill backgrounds → keep but drop fill, hairline border only.
- Collapse predicate → conservative gate (every must-be-false condition
  listed above must hold).
- LIVE/BETWEEN body code → untouched, even where the chips still render.
