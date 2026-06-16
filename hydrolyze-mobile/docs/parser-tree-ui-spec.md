# Parser Tree UI Spec — Workout Preview (WorkoutBuilder)

**Big idea: The workout is a document, not a tree widget.** A coach reads a printed workout the same way they read a text message — line by line, down a single spine. Each line has one thing it wants to communicate (reps × distance) and a short supporting cast of metadata. The design should feel like a beautifully typeset coach's clipboard, not a VS Code debug panel.

---

## Layout Principle

**One column, one spine, visual hierarchy by weight not by nesting depth.**

Instead of indenting deeper for nested content (which pushes content off the right edge and creates visual clutter), use:

- **Bold/weight** to indicate the primary "thing" (reps × distance)
- **Color and italics** to indicate metadata and description
- **Collapsed sub-rows** for drill/swim and odd/even patterns — hidden by default, visible on tap
- **Separators** (thin lines, not section backgrounds) to distinguish named blocks

---

## Typography

| Element                | Font                    | Size | Weight     | Color                                                          |
| ---------------------- | ----------------------- | ---- | ---------- | -------------------------------------------------------------- |
| Section title          | `FontFamily.uiSemiBold` | 11pt | 600        | `Colors.dim` uppercase                                         |
| Named set label        | `FontFamily.uiSemiBold` | 14pt | 600        | `Colors.cyan`                                                  |
| Rep group primary line | `FontFamily.ui`         | 15pt | 400        | `Colors.text`                                                  |
| Sub-rep / pattern line | `FontFamily.ui`         | 13pt | 400        | `Colors.muted`                                                 |
| Intensity / interval   | `FontFamily.ui`         | 13pt | 500        | `Colors.amber`                                                 |
| Gear badge             | `FontFamily.uiSemiBold` | 11pt | 600        | `Colors.cyan` on `Colors.cyanDim` bg                           |
| Note / detail          | `FontFamily.ui`         | 12pt | 400 italic | `Colors.dim`                                                   |
| Descend badge          | `FontFamily.uiSemiBold` | 11pt | 600        | `Colors.surface` bg, `Colors.border` border, `Colors.dim` text |

---

## Per-Level Rendering

### RepGroup row (the main line)

The primary line shows the workout's "spine" — the one thing a coach scans for:

```
4 × 100m  Free  @ 80–85%  on 1:30
```

**Format:** `[reps] × [distance]m  [stroke]  @ [intensity]  on [interval]`

- `reps × distance` uses `FontFamily.monoMedium` 15pt — the numeric spine
- Stroke: `FontFamily.ui` 14pt `Colors.text` — only shown if stroke is specified
- Intensity: `FontFamily.uiMedium` 13pt `Colors.amber` — if present
- Interval: `FontFamily.ui` 13pt `Colors.muted` — right-aligned or inline
- Gear: inline badge after interval — small pill `Colors.cyanDim` bg, `Colors.cyan` text
- Descend: small badge to the right of the row — neutral `Colors.surface` bg

**Inline metadata pattern (defended):** Use dot separators for metadata that lives on the same line, and small pills for categorical data (gear, descend). This follows TrainingPeaks and Garmin: intensity and interval are inline words, gear is a small tag. No chip stacks — if there are 3 gear items, show one pill with "gear" and expand on tap.

**Rules:**

- When a field is absent, the space for it disappears entirely — no empty chips or "—" placeholders
- Intensity shows the label (e.g., "80–85%") not the internal type
- Percent ranges always show the range (e.g., "75–80%") not "hard"

---

### Drill/Swim breakdown (collapsed sub-row)

For `as: 25 drill + 75 swim`, show a collapsible sub-row below the main line:

```
  25 drill  ·  75 swim
```

- Rendered as: `[n] [type]` joined by `·`
- `type` is "drill" or "swim" — always lowercase, italic
- Indented 12px from left, `Colors.border` left border 1px
- If not parseable as drill/swim split, show the raw pattern string instead

**Expand/collapse:** Tap the main row to expand sub-reps. A small `‹` chevron on the right shows it's tappable. Default: collapsed (the drill/swim is informational, not a timing trigger).

---

### Odd/Even pattern (two sub-rows)

```
  Odd:  underwater dolphin kick (breakout + easy to wall)
  Even: freestyle kick build to strong
```

- Two lines, each indented 12px with a 1px left border
- `Odd:` and `Even:` labels in `FontFamily.uiSemiBold` 11pt `Colors.dim`
- The instruction text in `FontFamily.ui` 13pt italic `Colors.muted`
- No expand/collapse needed — odd/even is always visible (it's a training instruction, not a timing detail)

---

### Descend badge

Small neutral badge — `Colors.surface` background, `Colors.border` border, `Colors.dim` text. Shows "↘ 1–4". Positioned inline after the main line, not as a separate row.

---

### Note / details

If a `note` exists (e.g., "(Paddles optional)", "(very fast)"), render as italic `Colors.dim` 12pt on the line below the main rep group, indented to align with the primary line. Catch-all `details[]` items also shown here as comma-separated italic text.

```
  4 × 75m  Desc 1–4  @ 80–85%  [↘ 1-4]
  (Paddles optional)
```

---

### Compound sets (`4x300 + 8x25`)

Two rep groups shown consecutively with `+` between them — no special grouping container needed. The shared context (interval, intensity) is shown on the first group and implied for the second. If they differ, show both.

```
  4 × 300m  @ ATP  on 1:15   [+]  8 × 25m  ATP  on 1:15
```

---

### Section title

A single thin line (`Colors.border` 1px) with the section name uppercase in `FontFamily.uiSemiBold` 11pt `Colors.dim`. Not a background block — just a typographic separator. A coach can visually skip it at a glance.

```
────────────────────────────────
  WARM UP
────────────────────────────────
```

---

## Color & Spacing

- **Section separator:** 1px `Colors.border` line + section title uppercase, no background
- **Named set indent:** 8px left indent for all rep groups within the named set, no left border
- **Sub-rep indent:** 12px left indent + 1px `Colors.border` left border
- **Row spacing:** 8px between rep groups, 4px between sub-rows
- **No background chips for metadata** — use inline text and small pills only

---

## One Big Cut

**Remove the v2SectionHeader background block** (`Colors.elevated` with cyan left border). Replace with a thin `Colors.border` separator line and uppercase section title. The current background + left border makes each section feel like a sidebar widget. The clean separator makes it feel like a document.

**Add: drill/swim pattern rendering** — the current UI doesn't show drill/swim breakdowns at all. They need to be a visible sub-row.

---

## Complete Render Example

For the input:

```
Aerobic Build (400m)
400 swim as: 100 smooth free, 100 IM drill/swim, 100 pull (long strokes), 100 build to ~75%
Stroke Activation 4x100 as 25 drill + 75 swim @ moderate aerobic
Kick + Oxygen Demand 4 x 50
  Odd: underwater dolphin kick (breakout + easy to wall)
  Even: freestyle kick build to strong
Pull with Pressure 4 x 75 Descend 1-4 to ~80-85% Paddles optional
Aerobic Power Prep 4 x 50 as 25 smooth + 25 build to 85-90%
4x300 + 8x25 ATP 1:15 (very fast)
```

The UI renders as:

```
────────────────────────────────
  AEROBIC BUILD
────────────────────────────────
  4 × 400m  @ 70–80%  on :75
  (smooth free · IM drill/swim · pull · build to ~75%)

  STROKE ACTIVATION
  4 × 100m  @ moderate  on :30  [paddles]
    25 drill  ·  75 swim

  KICK + OXYGEN DEMAND
  4 × 50m  @ aerobic
    Odd:  underwater dolphin kick (breakout + easy to wall)
    Even: freestyle kick build to strong

  PULL WITH PRESSURE
  4 × 75m  @ 80–85%  on :30  [↘ 1-4]  [paddles]
    (Paddles optional)

  AEROBIC POWER PREP
  4 × 50m  @ 85–90%  on :30
    25 smooth  ·  25 build to 85–90%

  4 × 300m  @ ATP  on 1:15  +  8 × 25m  ATP  on 1:15
    (very fast)
```

Key decisions in this render:

- Section titles use a separator line, not a background block
- Named set labels (Aerobic Build, Stroke Activation) are visually prominent but not background-highlighted — they anchor the eye
- The `400 swim as: ...` breakdown is a note line below the main rep group — not a sub-row with indents
- Drill/swim pattern shows as `25 drill · 75 swim` inline below
- Odd/Even shown as two indented sub-lines (always visible)
- Gear shown as a small inline badge `[paddles]`
- Descend shown as `[↘ 1-4]`
- Percent ranges shown as `80–85%` inline, not as a color chip
- Notes in italics below the row
- Compound set `+` joins the two rep lines inline

---

## Implementation Notes

Files to change:

- `app/workout/new.tsx` — replace `renderV2Tree()` with new layout per this spec
- `lib/workout-parser-v2.ts` — no changes (data model is fixed)
- `lib/workout-types.ts` — no changes

New styles needed (all use existing `Colors`, `FontFamily`, `FontSize`, `Space`, `Radius` tokens):

- `v2SectionDivider` — 1px `Colors.border` top border + section title
- `v2NamedSetLabel` — 14pt `FontFamily.uiSemiBold` `Colors.cyan`, no background
- `v2RepGroupLine` — mono numbers + inline metadata
- `v2SubRow` — 13pt italic muted, 12px indent + 1px left border
- `v2DrillSwimRow` — inline `25 drill · 75 swim`
- `v2OddEvenBlock` — two indented sub-lines for odd/even
- `v2Note` — 12pt italic `Colors.dim`
- `v2GearBadge` — small pill (existing pattern, refine)
- `v2DescendBadge` — small neutral pill

Acceptance criteria:

- Section headers render as thin separator lines, not background blocks
- Named set labels are prominent without a background chip
- Rep group shows reps × distance in mono font as the visual spine
- Drill/swim breakdown shows as indented sub-row, collapsed by default
- Odd/Even shows as two visible indented sub-lines
- Gear is a small inline pill, not a row of chips
- Notes are italic text below the main line
- Percent ranges show as numeric labels (e.g., "75–80%"), not abstract intensity chips
- Descend shows as small neutral badge
- All metadata fields disappear entirely when absent (no empty chips)
