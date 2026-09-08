# V0.53.3 — display fragment distance verbatim ("12.5" not "13")

Branch: `fix/fragment-decimal-distance-decode` (already created; same scope)
Status: Approved — greenlit 2026-09-08 (defaults: Q1=A, Q2=A, Q3=A)
Date: 2026-09-08
Owner: ponytail (build session)

## Problem (verbatim from Nathan)

> "This is better, but when it says 4 × 25: 12.5 strong, 12.5 easy. Let's
> actually put 12.5 on the slider instead of 13 and 13."

Coach wrote 12.5; UI should say 12.5. The current "13m" labels come from the
int field that V0.51 (commit 230be54) introduced specifically so Swift's
`JSONDecoder` would not throw `DecodingError.dataCorrupted` on the half-pool
floats the LLM emits. That fix is load-bearing and must not regress.

## Current State

1. The edge function's `_decimal-distance-fix.ts` walks every
   `section.namedSet.repGroup.fragments[]` and rounds `fragment.distance`
   to the nearest integer via `Math.round`. The parent `repGroup.distance`
   stays integer (parseRepDist only emits decimals from explicit `Nx D`
   patterns where D is a recognised half-pool distance; parent set totals
   are still int). The `sourceLine` is preserved verbatim — it carries the
   coach's exact wording ("4 x 25: 12.5 fast / 12.5 easy").
2. The iOS `ParsedFragment` decodes `distance: Int?` (with a defensive
   `decodeFlexibleInt` that also accepts a JSON number and falls back).
3. All fragment-distance render surfaces in `WorkoutPreview.swift`
   interpolate `"\(d)m"` from `fragment.distance`:
   - `segmentLabel` (inside the RepCard segment track) — line 1485
   - `fragmentChipTitle` (recorded-time chip + sheet title + VoiceOver)
     — line 1957
   - `cardAccessibilityLabel` (VoiceOver for the rep card) — line 1518
   - `FragmentCTARow` body — line 1728
   - `UniformRepCard` body — line 2339
   - `ProgressionRepCard` body — line 2578
4. The rep-card HEADER (`PairRepGroupRow.headerLine`, `UniformRepGroupRow.headerLine`,
   `ProgressionRepGroupRow.headerLine`) renders the PARENT distance, which
   is already integer. No change needed there.

## Objective

Make the UI say "12.5m" for fragments parsed from a half-pool source, while
keeping the int field intact on the wire for timing/pairing keys. The fix
must be wire-safe (no floats), decode-safe (old servers stay compatible),
and display-only (timing keys remain `fragment.id`, no logic changes).

Success criteria:
- Live curl of `parse-workout` with `4 x 25: 12.5 strong / 12.5 easy` returns
  `distance: 13, distance_label: "12.5"` on both fragments. No floats anywhere
  in the payload.
- iOS segment track labels read "12.5m strong | 12.5m easy" for the jodie-09
  test case.
- Bench 21/21 still green (the existing 8 jodie files + the 3MT + grammar
  suites — same corpus as V0.53.2 SHIPS).
- Full `xcodebuild` on `macstudio-tailnet` SUCCEEDED.
- DEBUG harness screenshot saved to `/tmp/hydrolyze/` showing the new
  labels on the segment track.
- The "Descend:" caption ABOVE the set (line 327-332 in WorkoutPreview.swift)
  also stops truncating mid-number — same `lineLimit(nil)/fixedSize` treatment
  that landed on the three below-set caption paths in V0.53.2.

## Visual Design

```
4 × 25m Free        @ 1:00
┌──────────────────────────────────────────────────┐
│ 12.5m strong  │  12.5m easy              @ 1:00 ▶│
└──────────────────────────────────────────────────┘
```

(Before: "13m strong | 13m easy" — the rounding leak.)

The proportional split on the segment track is unchanged — it still keys
on `fragment.distance: Int` for layout. Only the label rendering reads
`distance_label` first, then falls back to `distance`.

## Data Model

### Server — `_llm.ts` and `_decimal-distance-fix.ts`

Add `distance_label: string | null` to:

- `LLMFragment` (line 34-51) — `distance_label: string | null`. Initial
  value is null when the LLM emits an int; populated by the validator when
  the LLM emits a half-pool float (12.5, 37.5, 62.5, 87.5).
- `Fragment` in `index.ts` (line 80-94) — mirror.
- `LLMRepGroup` doesn't carry fragment label directly — the label lives on
  the fragment.

Capture rules inside `normalizeFragmentDistances`:

1. **If the input fragment.distance is an integer** (or was already
   integer), set `distance_label = String(frag.distance)` — e.g. `"25"`,
   `"100"`. Coaches will still see the number that matches the integer, and
   the field is always present (nil-tolerance becomes a non-issue).
2. **If the input fragment.distance is a non-integer half-pool value**
   (12.5, 37.5, 62.5, 87.5, etc.), preserve the EXACT string the coach
   wrote. Round to int for `distance`. `distance_label` = the original
   string from `sourceLine` if recoverable, else `String(frag.distance)`
   (i.e. `"12.5"`).

Source-text capture strategy (cheapest correct):
- The fragment's source position in `sourceLine` is not directly
  available — `_decimal-distance-fix.ts` only knows the rounded distance
  and the `sourceLine`.
- Take the simpler, equally-correct path: capture the numeric form
  the parser emitted before the round. We have it in
  `frag.distance` (as a float, e.g. 12.5) at the moment of rounding.
  Round → set `distance = Math.round(frag.distance)`. Set
  `distance_label = String(frag.distance)` (the unrounded float).
- This guarantees: integer fragments show "25", "100"; half-pool
  fragments show "12.5", "37.5", "62.5", "87.5". No sourceLine
  parsing needed — the float's `String()` round-trips cleanly for
  the known half-pool distances (the only ones SWIM_DISTANCES admits).
- Edge case: a coach writes "12.50" — `String(12.50)` is `"12.5"` in JS,
  fine. "37.5" — `String(37.5)` is `"37.5"`. Good.

### iOS — `ParsedFragment`

Add `distanceLabel: String?` decoded via `decodeIfPresent` (nil-tolerant;
old servers stay compatible). New CodingKey: `case distanceLabel = "distance_label"`.

Render fallback chain (file-scope helper for reuse):

```swift
func fragmentDistanceText(_ f: ParsedFragment) -> String {
    if let label = f.distanceLabel, !label.isEmpty { return "\(label)m" }
    if let d = f.distance { return "\(d)m" }
    return ""  // distance-unknown fallback — never observed in the corpus
}
```

All six fragment-distance render sites above swap `"\(d)m"` for
`fragmentDistanceText(f)`. The header (parent distance) is unchanged.

### What stays integer-only

- `Fragment.distance` (server) — the int that survives the round. Pairing
  cost tiers key on the rounded int; switching to float would re-introduce
  the V0.51 regression and double-precision rounding noise.
- `ParsedFragment.distance: Int?` — unchanged type. Defensive decoder
  stays. The new field is additive.
- `repGroup.distance` — parent set total, always integer by construction.
  No label needed; coaches see it as "4 × 25m" already.
- Fragment-id stamps (`sha1(sourceLine:orderIndex)`) — unchanged.
- Timing keys (`fragment.id`) — unchanged.

## Components Affected (4-place sync)

| Place | File | Change |
|---|---|---|
| **1. Edge: LLM shape** | `ios-native/supabase/functions/parse-workout/_llm.ts` | Add `distance_label` to `LLMFragment`; populate from validator when LLM emits float. |
| **2. Edge: response builder** | `ios-native/supabase/functions/parse-workout/_decimal-distance-fix.ts` | Round + populate `distance_label` in the same pass. Always set when distance is set. |
| **3. Bench mirror** | `scripts/parser-bench/_decimal-distance-fix.ts` | Mirror the change. Helper is local-only; bench has no `_llm.ts` mirror. |
| **4. iOS decode + render** | `ios-native/Hydrolyze/Sources/Views/Components/WorkoutPreview.swift` | Add `distanceLabel: String?` to `ParsedFragment`; helper `fragmentDistanceText`; swap all 6 render sites. |
| **5. Caption wrap** | `WorkoutPreview.swift:327-332` | Add `lineLimit(nil) + fixedSize(horizontal:false, vertical:true)` to the above-set `(note)` caption in the header HStack. |
| **6. Bench tests** | `scripts/parser-bench/decimal-distance-fix.test.ts` | Add assertions for `distance_label` extraction on each existing test case. New RED test: 37.5 → distance=38, label="37.5". |

## Code Style

- Match the existing V0.53.2/V0.53.1 comments — phase the change
  `V0.53.3 (2026-09-08, jodie-09 display fidelity)` with the rationale.
- The `(note)` caption wrap fix is co-located with the V0.53.2 caption
  fixes; tag it `V0.53.3 caption-wrap completion`.
- No new helper files. All Swift changes land in `WorkoutPreview.swift`.

## Testing Strategy

- **RED then GREEN** for the bench. Add a `distance_label` assertion to
  each existing RED test in `decimal-distance-fix.test.ts` (cases 1, 2, 3,
  4, 5 — the null/37.5/integer/null-fragments/null-rg cases). Add a new
  RED test: `distance: 87.5` → `distance=88, distance_label="87.5"`.
- **Smoke**: write a small Swift test (or use the existing V0531 /
  V0532 smoke harness pattern in `ios-native/Hydrolyze/Tests/`) that:
  - Decodes a JSON payload with both shapes (with and without
    `distance_label`) and asserts `distanceLabel` is the right value.
  - Calls `fragmentDistanceText(f)` with the various shapes and asserts
    the right `"12.5m"` / `"25m"` / `""` strings.
- **Live curl** (post-deploy): exercise `4 × 25: 12.5 strong / 12.5 easy`
  via the live edge function. Grep the JSON for `distance` — confirm
  no floats on the wire. Confirm `distance_label: "12.5"` on both
  fragments.
- **DEBUG harness screenshot**: re-run the V0.53.2 harness against the
  jodie-09 purposeful-threshold test input. Save to `/tmp/hydrolyze/`.
  Screenshot must show "12.5m strong | 12.5m easy" on the segment track.
- **iPad screenshot**: optional — the change is rendering-only, no
  layout risk. Skip unless something breaks.
- **xcodebuild on macstudio-tailnet**: full Debug build must succeed.
- **Bench 21/21**: re-run after each mirror update. Same corpus as V0.53.2.

## Boundaries

### Always

- Mirror server changes to `scripts/parser-bench/_decimal-distance-fix.ts`
  before running the bench.
- Mirror server changes to BOTH `ios-native/supabase/functions/parse-workout/`
  AND `supabase/functions/parse-workout/` (the deploy path is
  `ios-native/supabase/`, per V0.51 §4-place sync).
- Deploy edge function via `supabase functions deploy parse-workout --use-api`
  from `ios-native/supabase/`.
- Set `distance_label` whenever `distance` is set (no silent nulls).

### Ask first

- Changing the wire type of `distance` from int to anything else.
- Adding a label field to `repGroup` (not needed — the parent distance is
  always integer and the header already renders correctly).
- Touching anything outside the 6 sites listed.

### Never

- Adding floats to the wire (re-introduces V0.51 regression).
- Changing `ParsedFragment.distance: Int?` to `Double?`.
- Bypassing the defensive `decodeFlexibleInt` decoder (still needed for
  stale deploys).
- Removing the existing caption-wrap fix on the three below-set paths.

## Implementation Slices

This is a 4-place sync. Two slices, each buildable + screenshot-able:

### Slice A — server side (deploy-able, no client change yet)
1. Patch `ios-native/supabase/functions/parse-workout/_llm.ts`
   (`LLMFragment` gains `distance_label: string | null`; validator
   populates when LLM emits float).
2. Patch `ios-native/supabase/functions/parse-workout/_decimal-distance-fix.ts`
   (round + set label in one pass; always when distance is set).
3. Mirror to `supabase/functions/parse-workout/_decimal-distance-fix.ts`.
4. Mirror to `scripts/parser-bench/_decimal-distance-fix.ts`.
5. Add `distance_label` assertions to
   `scripts/parser-bench/decimal-distance-fix.test.ts` + new RED case.
6. Bench 21/21 must stay green.
7. Deploy via `supabase functions deploy parse-workout --use-api` from
   `ios-native/supabase/`.
8. Live curl jodie-09 → confirm `distance: 13, distance_label: "12.5"`,
   no floats anywhere.

### Slice B — iOS decode + render + caption wrap
1. Patch `WorkoutPreview.swift:1132-1249` (`ParsedFragment` gains
   `distanceLabel: String?` with `decodeIfPresent`; new memberwise init
   param with default nil).
2. Add file-scope helper `fragmentDistanceText(_ f: ParsedFragment) ->
   String` near `segmentLabel` (line 1483).
3. Swap the 6 render sites: `segmentLabel` (1485), `fragmentChipTitle`
   (1957), `FragmentCTARow.body` (1728), `UniformRepCard.body` (2339),
   `ProgressionRepCard.body` (2578), `cardAccessibilityLabel` uses
   `segmentLabel` so it inherits the swap automatically.
4. Caption wrap completion: `WorkoutPreview.swift:327-332` — add
   `lineLimit(nil) + fixedSize(horizontal:false, vertical:true)` (same
   treatment the V0.53.2 caption-wrap fix applied to the 3 below-set
   paths).
5. Add `distanceLabel` to memberwise inits (line 1232) and Preview fixture
   (line 3049+).
6. xcodebuild on macstudio-tailnet (full Debug build).
7. DEBUG harness screenshot → `/tmp/hydrolyze/`.
8. Verify the screenshot reads "12.5m strong | 12.5m easy" on the
   segment track, AND that "Descend: 1 = 70% / 2 = 75% / ..." no
   longer truncates mid-number.

## Success Criteria

- [ ] Live curl payload: `distance: 13, distance_label: "12.5"` for the
      jodie-09 half-pool fragments; no floats anywhere in the JSON.
- [ ] Bench 21/21 green.
- [ ] xcodebuild SUCCEEDED on macstudio-tailnet.
- [ ] Screenshot at `/tmp/hydrolyze/v0533-jodie09-segment-track.png` shows
      "12.5m strong | 12.5m easy" labels.
- [ ] Screenshot confirms "Descend:" caption above the set wraps on
      multiple lines without truncating mid-number.
- [ ] Old-server compat: client decodes payloads without `distance_label`
      (fallback to `distance` Int).
- [ ] No regression to V0.51 (`distance: Int?` decoder still works).
- [ ] No regression to V0.53.2 (caption wrap on below-set paths intact;
      segment-track mode-selection intact).

## Open Questions

### Q1 — `distance_label` capture source: pre-round float or sourceLine regex?

- **Option A (recommended)**: Capture from `String(frag.distance)` at the
  moment of rounding inside `_decimal-distance-fix.ts`. Simplest, no
  sourceLine parsing. Round-trips cleanly for the known half-pool
  distances (12.5, 37.5, 62.5, 87.5). LLM never emits a non-SWIM_DISTANCES
  half-pool, so this covers every case.
- **Option B**: Regex against `sourceLine` to recover the exact original
  wording (catches "12.50", "37.5m", etc.). More fragile, no observed
  benefit — the parser already normalises the spacing.

**Recommendation: Option A.** Cheaper, fewer failure modes, identical
display for every observed case. The LLM only emits the canonical half-pool
distances.

### Q2 — Set `distance_label` even when the value matches the int?

- **Option A (recommended)**: Always set `distance_label` whenever
  `distance` is set. Integer fragments get `distance_label = "25"` /
  `"100"` etc. Cheaper client code (no special-case for nil).
- **Option B**: Set `distance_label` ONLY when it differs from the int
  (i.e. only for half-pool fragments). Smaller payload, but the client
  must nil-fallback on every render.

**Recommendation: Option A.** Payload is small (a few extra string fields
per fragment). Eliminates one branch from the client render code. Old-server
compat is unaffected (clients still nil-fallback).

### Q3 — Commit message + version label

- **Option A (recommended)**: `V0.53.3 FragmentDistanceLabel — display
  verbatim ("12.5" not "13") + caption-wrap completion`
- **Option B**: Two commits — one for the wire-type fix, one for the
  caption wrap.

**Recommendation: Option A.** They're coupled — the screenshot evidence is
the same jodie-09 segment track that exposed both bugs in V0.53.2. Two
commits risks the caption wrap fix landing first and the wire-type fix
slipping. Single commit, named explicitly in the message body.

### Defaults (if you say "your defaults")

| # | Decision | Default |
|---|---|---|
| 1 | Label capture source | Option A — `String(frag.distance)` at the round moment |
| 2 | Set label even when matches int | Option A — always set |
| 3 | Commit shape | Option A — single commit, both fixes |
| 4 | Re-run the bench corpus | Full 21/21 (jodie 8 + 3MT + grammar + decimal-distance + new label cases) |
| 5 | Screenshot target | `/tmp/hydrolyze/v0533-jodie09-segment-track.png` (DEBUG harness) |

## Decisions (2026-09-08)

| # | Decision | Choice |
|---|---|---|
| 1 | Label capture source | Option A — `String(frag.distance)` at the round moment in `_decimal-distance-fix.ts` |
| 2 | Set label even when matches int | Option A — always set; integer fragments get `"25"` / `"100"` |
| 3 | Commit shape | Option A — single commit (wire-type + caption-wrap together) |

## Out of Scope

- Changing the `distance: Int?` wire type. Float-on-the-wire is the
  V0.51 regression we're explicitly avoiding.
- Adding a label field to repGroup. The parent distance is already
  integer and the header renders correctly.
- Touching any other fragment-distance render site outside the 6 listed.
- Re-deploying the iOS on-device parser fallback. The change is server +
  client only.