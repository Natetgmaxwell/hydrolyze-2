# Jodie Corpus Live Audit — 2026-09-08

**Goal:** Diagnose why Nathan says the parser is "still not doing the best job" despite the bench reporting 1.0/1.0.

**Method:** Live calls to the deployed `parse-workout` edge function (project `flidjtldfvrrntzwtnsq`) for all 8 `commit-jodie-*.txt` files, **no Authorization header** so `coach_vocabulary=[]` (baseline worst-case for unmapped-terms detection). Per-file responses captured at `/tmp/jodie-parse-*.json`. Companion regex-engine dump via `_diagnose.ts`.

## TL;DR

- **Bench said 1.0/1.0 because it's blind to this corpus.** `score.ts` only scores 16 hand-annotated `real-input-*.txt` files against `expected.ts`; the 8 Jodie files have **no entries in `expected.ts`**. The 21/21 score is the regex engine, not the LLM. `commit-coverage.ts` returns 0/0 on the same Jodie files (regex engine produces 0 set-like captures).
- **The live LLM path parses all 8 cleanly** — 0 HTTP errors, 0 JSON-float regressions, every file emits sections + repGroups. Latency 4–8s/call (one outlier: jodie-03 at 26s).
- **Real quality issues are below the bench's resolution**: per-fragment intensity gets lost on half the composite sets, per-fragment `gear`/`start_type` are always null even when the LLM gets them right at the rg level, several "Then:" / "After kick:" sub-blocks collapse into a single rg's note, and `unmapped_terms` is leaking 5 noise tokens (`a1`, `a2`, `dps`, `fnt`, `mod`) that should never reach the iOS card.
- **The dialect-terms flywheel is being asked the wrong questions** for Jodie. `easy`/`strong`/`build`/`descend` appear in 6 of 8 workouts — Jodie will see "ask" prompts for words she uses every single session. That's the "still not doing the best job" feeling: the prompt is generating more end-of-session questions than it should because Tier-1 lists were built top-down, not from the corpus.

## Per-workout findings (live parse vs. coach expectation)

### commit-jodie-01-sep (Sep 4 — recovery, 13 rgs / 0 fragments)
- ✅ "4 × 150 @ 2:30–2:45" → 4×150 reps/distance/interval preserved.
- ✅ "8 × 50 @ 1:10" + bodyline/side-kick/streamline/drill note → 8×50 with note attached.
- ✅ "3 rounds" directive consumed; "4 × 50 @ 1:00" emits 4×50 not 12×50 (correct round-handling).
- ❌ "200–400 down-regulation" → rg with `distance=0`, `reps=1`, `note='Rule: You leave feeling better...'`. **Lost as a set.** Should be a free-text section note, not a zero-distance rg.
- ❌ `unmapped_terms: ['easy']` — `easy` is in TIER1_TERMS (V0.47 drift-fix). Engine already silently resolves `easy` to RPE 4–5; the spec said **don't ask `easy` again** (decision #4 says "ask once, then map" — but the prompt is asking on every parse, not on first occurrence). This is the single biggest UX bug: every Jodie parse pops a vocabulary card for `easy`.

### commit-jodie-02-sep (Sep 3 — 6 event groups, 25 rgs / 15 fragments)
- ✅ "4 × 100 25 kick / 25 swim" → fragments=[{25,kick}, {25,free}].
- ✅ "8 × 50 @ 1:00–1:10 25 strong kick / 25 aerobic" → 2 fragments, first labelled `{type: build, label: strong}` — coach said "strong" not "build". **First fragment intensity wrong**: `parseIntensity` doesn't have a "strong" → aerobic mapping; the validator falls back to `build` because `build` came later in the regex alternation. **Bug:** `strong` should map to `aerobic` (Tier-1 spec §3 row 5), not `build`.
- ❌ "4 × 50 underwater → breakout → easy" → single rg, `dive=True`, `intensity_type='sprint'` (because `underwater` matched the sprint regex via `breakout` — false positive). Should be 3 fragments (underwater / breakout / easy) with NO sprint intensity on the breakout fragment.
- ❌ "600 sustained aerobic/threshold" + 5-sub-breakdown (`100 strong / 300 settle / 50 surge / 100 settle / 50 strong`) → emits 5 fragments but every fragment intensity is `null` — should carry `strong`/`settle`/`surge` (or at minimum mark the 2×50 surge as sprint-class). The coach wrote it as a structured break for a reason.
- ❌ `unmapped_terms: ['build', 'descend', 'easy', 'max', 'strong']`. `max` is **never** in the corpus outside this list — it's the LLM's surface-form echo for `MAX velocity`, which the engine already resolves to `sprint`. **Tier-2 leak**: `max` should be in DEFAULT_RPE_BY_TERM (sprint, RPE 9-10), not Tier-1.

### commit-jodie-03-sep (Sep 2 — LC-specific warm-up + speed + aerobic + finishing test, 21 rgs / 32 fragments)
- ✅ "4 × 150 @ 2:30 — Each: 50 swim; 25 scull + 25 swim; 50 descend within the 50" → 4 fragments (50 + 25+25 + 50), last fragment has `descend` intensity. **Best composite parse of the corpus.**
- ❌ "15 m MAX + 35 m very easy. Alternate: 1. Push, 2. Dive, 3. Push, 4. Dive etc." → fragments=[{15,sprint,label=max}, {35,easy,label='very easy'}], **`start_type=null` on both fragments**. The LLM got the rg-level `dive=True` right but didn't propagate per-fragment `start_type`. Per V0.37, fragments carry their OWN context — coach wants to time the 15m max effort off a dive, not the 35m cruise.
- ❌ "Then: 4 × 100 @ 1:40 — 25 build stroke rate; 25 hold that rate without shortening; 25 DPS; 25 strong through the wall" → 4 fragments, but **fragments 2 and 3 (`hold that rate`, `DPS`) carry intensity=null**. Both are quality-of-effort markers the coach uses to dial the rep — losing them means iOS pairing can't pace them.
- ❌ "400 swim + 4 × 100 pull + 4 × 50" → single rg, `reps=1, distance=400, note='400 swim + 4 × 100 pull + 4 × 50'`. **Lost two of the three sets.** Coach wrote this as a summary line, not a set — should be a section note, not a 400m rep.
- ❌ "2 × 600 as: 200 aerobic, 50 surge, 150 aerobic, 50 surge, 100 aerobic, 50 strong" → 6 fragments, but **3 of the 6 fragments have `intensity=null`** (the 50 surges and the 50 strong). The whole point of this composite is the gear-changes; null-intensity fragments erase the signal.
- ❌ `unmapped_terms: ['a1', 'a2', 'build', 'descend', 'easy', 'fast', 'max', 'progressive', 'race rhythm', 'strong']`. **10 unmapped terms — the most in the corpus.** `'a1'`, `'a2'` are **noise** (zone codes from "200 A1 → 200 A2 → 200 strong A2"); they will never resolve to RPE because they're not intensity words. Same for `'progressive'` which is a **progression shape**, not a Tier-1 ask — the spec §3 row 11 explicitly handles it, but the regex pattern `\bprogressive\b/i` in TIER1_TERMS catches the fragment text and emits it. Same for `'race rhythm'` — engine already resolves to `race_pace`, doesn't belong in unmapped_terms.

### commit-jodie-04-sep (Sep 1 — Threshold, 19 rgs / 6 fragments)
- ✅ "4 × 100 @ 1:35" + later "50 drill / 50 build ( single arm Fingers on shoulder) (catch pause drill)" → 1 rg, 2 fragments, drill fragment has no intensity, build fragment has `build`. **Round modifier + parenthetical drill name preserved in note.**
- ❌ "4 × 50 @ 1:00 / 25 strong / 25 easy" → 2 fragments, **first fragment has `intensity=null`**. Same `strong` bug as jodie-02 (validator maps "strong" → "build" via regex alternation order, but the fragment-level instruction didn't carry "strong" in the LLM output).
- ❌ `unmapped_terms: ['build', 'descend', 'easy', 'strong']`. **`descend` appears in 4 of 8 workouts** — Jodie uses it as a shape ("Descend 1–4 to strong"), the spec already calls this out as a 2-point capture (§6 decision #2) but the prompt is asking Jodie to map it on every session instead of asking once and remembering.

### commit-jodie-05-aug (Aug 31 — MAX velocity + fly speed, 10 rgs / 0 fragments)
- ❌ "4 × 100 @ 1:40 / 25 scull / 25 DPS / 25 build / 25 easy" → single rg, **0 fragments**. The "Each 100: 25 scull / 25 DPS / 25 build / 25 easy" sub-line was attached to the parent note instead of becoming 4 fragments. This is rule 6 (composite sets / fragments) — the LLM is mis-applying the numbered-instruction rule (rule 1) and demoting a real composite.
- ❌ "8 × 15 m MAX @ 1:15–1:30 / Mix: dive / push / breakout / event stroke" → 8×15 with `dive=True`, but **no fragments** and no per-fragment `start_type`. Coach wants to alternate dive/push/breakout/event across the 8 reps.
- ❌ "8 × 50 @ 1:20–1:30 / 25 Fly strong technically / 25 Free very easy" → rg intensity='easy' (from "very easy"), but the **first 25 should be Fly-stong** (sprint-class). No fragments emitted.
- ❌ `unmapped_terms: ['activation', 'build', 'dps', 'easy', 'max', 'relaxed', 'strong']`. **7 noise/leak terms.** `'dps'` is "distance per stroke" — coaches' efficiency cue, NOT a Tier-1 ask. `'activation'` is in TIER1_TERMS but is a section label ("Activation set"), not an intensity word in this context. `'relaxed'` is in the corpus twice (Aug 31 + Aug 27) — coach-style "warm-up language" — engine already silently resolves via `easy` regex, shouldn't be asked.

### commit-jodie-06-aug (Aug 28 — recovery / kick technique, 6 rgs / 3 fragments)
- ❌ "16×25 R:I 20 dolphin kick fins odds side dolphin evens on back hands by side" → 16×25, gear=['fins'], but **no fragments** for "odds/evens" alternation, and `start_type=null` despite the alt-direction description.
- ❌ "16 x 25 freestyle or back stroke with fins (not stabby arms). ODDS: Long dog freestyle (or double arm for back). EVENS: 'Easy' fast – no more than 80% effort" → 16×25, gear=['fins'], `intensity='sprint'` (because LLM picked "fast" → sprint), `zone='easy'`. **Both intensities wrong**: the odd reps are `Long dog freestyle` (technical drill, no intensity), the even reps are `~80% effort` (aerobic threshold, ~7-8 RPE). LLM collapsed a 2-alternation set into a single "fast" label.
- ❌ `unmapped_terms: ['easy', 'fast', 'progressive']`. `'fast'` is **already in TIER1_TERMS** but `parseIntensity`'s regex maps it to `sprint` (RPE 8-9) — it should silently resolve and NOT be in unmapped_terms. **`fast` belongs in DEFAULT_RPE_BY_TERM, not TIER1_TERMS**.

### commit-jodie-07-aug (Aug 27 — race-pace intro + back-end speed, 18 rgs / 5 fragments)
- ✅ "4 × 50 build 1–4 @ 1:00" → 4×50 with `build` intensity.
- ✅ "3 × broken 100: 50 at 200 pace :10, 50 at or slightly faster than 200 pace" → 2 fragments, both `race_pace` — **best pace-target parse of the corpus.**
- ❌ "6 × 100 @ moderate aerobic - 25 strong / 50 smooth / 25 strong" → 3 fragments, ALL labelled `aerobic`. Coach means: **first and third fragments are STRONG-aerobic** (not pure aerobic), middle is smooth. The two-word compound `moderate aerobic` / `strong aerobic` collapses to `aerobic` and loses the "strong" qualifier. **This is the single most important dialect issue in the corpus.**
- ❌ "4 × 50 faster than 800 pace" → 4×50, `intensity='sprint'` (because LLM matched `faster than` to the "faster than race pace" Tier-1 regex and the validator mapped to `sprint`). Coach meant **race_pace**, not sprint — the spec §3 row 4 says "faster than race pace = overspeed, RPE 9-10" but this workout's context is 800 pace (race-pace distance), so "faster than 800 pace" = **race_pace** (1–2% faster), not sprint. **Context disambiguation missing.**
- ❌ `unmapped_terms: ['all-out', 'build', 'easy', 'fast', 'moderate', 'race rhythm', 'relaxed', 'strong']`. **8 leaks.** `'moderate'` is the **canonical dialect word** (spec §3 row 13, the reason this whole flywheel exists) — should be in DEFAULT_RPE_BY_TERM for the first-ask flow until the coach maps it. `'all-out'` is the engine-silent sprint synonym and shouldn't be asked at all.

### commit-jodie-08-aug (Aug 26 — main set with descending structure, 9 rgs / 4 fragments)
- ❌ "6 x 50 kick 25 mod / 25 tapping 1:10" → kick stroke (correct), but **first fragment labelled `intensity='easy', label='mod'`**. `'mod'` is Jodie's abbreviation for `'moderate'` (her shorthand — appears 6+ times in the corpus). The validator mapped "mod" → "easy" via the fallback regex (`easy/recovery/warm-up/ez/relaxed` doesn't include `mod`, but the alternation order in `parseIntensity` short-circuits on `mod` → aerobic → but then "moderate aerobic" Tier-1 wins? No — `'mod'` doesn't match `\bmoderate\b` regex because of the trailing characters. **Need a regex `\bmod(?:erate)?\b/i` in TIER1_TERMS / DEFAULT_RPE_BY_TERM.**
- ❌ "4 x 50 25 progressive scull / 25 swim" → fragments=[{drill, build, label='progressive'}, {swim, null}]. `'progressive'` is a **progression shape** like `build`/`descend`, NOT an intensity word — spec §3 row 11 already says so. It belongs in PROGRESSION_TERMS or DEFAULT_RPE_BY_TERM, not TIER1_TERMS.
- ❌ `unmapped_terms: ['descend', 'fnt', 'mod', 'progressive']`. **`'fnt'` is a noise token** ("front" abbreviation in the warm-up rotation "EO/FNT/DRILL/Swim") — never an intensity word, never in any coach vocabulary. Need an exclusion list for known non-intensity abbreviations.

---

## Prompt-fix priority list

Ordered by impact (most-coach-visible wins first):

### P0 — unmapped_terms noise / leaks (kills the flywheel's UX)

The `unmapped_terms` array is what the iOS end-of-session card reads. Every noise entry degrades coach trust in the card ("why is it asking me about `a1`?"). 5 false-positive categories found:

1. **Zone codes / abbreviations** — `a1`, `a2`, `fnt`, `dps`, `mod`. Add an exclusion set the prompt explicitly tells the LLM NOT to surface:
   > "Do not include in `unmapped_terms`: zone codes (A1, A2, A3, Z1, Z2, Z3, Z4, Z5), training abbreviations (`mod` for moderate, `fnt`, `dr` for drill, `pb` for pull-buoy), descriptive cues (`DPS` = distance per stroke, `BO` = breakout, `UW` = underwater, `LT` = lactate threshold), or any word that appears as part of a stroke/distance/gear/equipment name."
2. **Tier-2 words that should silently resolve** — `max`, `fast`, `all-out`, `moderate`, `easy`, `strong`, `relaxed`. Move from TIER1_TERMS to DEFAULT_RPE_BY_TERM:
   - `max` → sprint, RPE 9-10
   - `fast` → sprint, RPE 8-9 (engine-side override only)
   - `all-out` → sprint, RPE 9-10
   - `moderate` → aerobic, RPE 6-7 (DEFAULT_RPE; first ask still surfaces, but ONLY on first parse)
   - `easy` → easy, RPE 4-5 (DEFAULT_RPE; never ask after the first confirmation)
   - `strong` → aerobic, RPE 7-8
   - `relaxed` → easy, RPE 4-5
3. **Progression shapes currently in TIER1** — `progressive` is a shape (start RPE → end RPE), not a point value. Move it next to `build`/`descend` in PROGRESSION_TERMS. The card already asks 2-point for `build`/`descend`; same flow.
4. **`unmapped_terms` dedup** — already in rule 7 ("one entry per unique word"), but the LLM emits both `easy` and `relaxed` even though they both resolve via DEFAULT_RPE_BY_TERM. Add a hard sentence: "**Tier-2 words that resolve via DEFAULT_RPE_BY_TERM NEVER belong in unmapped_terms** — your job is to identify only Tier-1 words that NEITHER the COACH VOCABULARY block NOR rule 6 mapped."

### P1 — per-fragment intensity, gear, start_type

The LLM emits fragments with intensity but **often forgets intensity on the first half of "X strong / Y easy" composite sets**. Add a focused rule:

> **Rule 16 — Composite fragment completeness**: when a set has composite fragments (e.g. `25 strong / 25 easy`, `15 m MAX + 35 m very easy`, `12.5 fast / 12.5 easy`), EVERY fragment MUST carry its own `intensity` object when the segment text states an intensity word. The validator does NOT silently backfill — your output is the only signal the pairing engine keys on. When a segment's text contains no intensity word (e.g. `25 scull`, `25 hold that rate`, `25 perfect swimming`), emit `intensity: null` and the validator falls back to the segment text.

For per-fragment gear + start_type — the LLM emits them at the rg level but **always** nulls at the fragment level. Add:

> **Rule 17 — Per-fragment gear + start_type propagation**: when the parent repGroup has gear or start_type AND the composite text contains a sub-segment that mentions the gear or start, emit that gear / start_type on the SPECIFIC fragment that mentions it. e.g. `8 × 25: 12.5 MAX Free + easy / 12.5 MAX Fly + easy` (the LLM should emit `gear: null` on each fragment because none is named — but `4 × 25 @ 1:00 — 15 m MAX off blocks + 35 m easy` should emit `start_type: "dive"` on the first fragment). When the gear / start applies to ALL fragments (e.g. `4 × 50 with paddles: 25 strong + 25 easy`), emit it on EVERY fragment.

### P2 — composite set detection (jodie-05 / 4×100 lost fragments)

Jodie-05's `4 × 100 / 25 scull / 25 DPS / 25 build / 25 easy` lost all 4 fragments. The LLM treated the second line as a "per-rep instruction" (rule 1). Clarify the boundary:

> **Rule 18 — Composite vs. per-rep-instruction**: When a line under a set looks like `25 [word1] / 25 [word2] / 25 [word3]` (slash-separated sub-segments with distance prefix), treat as **composite fragments**, not per-rep instructions. The distinguishing signal is `N m + intensity-word` patterns (e.g. `25 scull`, `25 build`, `25 DPS`). Numbered list patterns (`1. fists / 2. catch-up`) are per-rep instructions and stay as notes. **The slash-separated distance-prefixed pattern is ALWAYS composite, regardless of whether the segments above are simple or compound words.**

### P3 — multi-set summary lines (jodie-03)

`400 swim + 4 × 100 pull + 4 × 50` shouldn't be parsed as a single 400m rep — it's a section summary. Add:

> **Rule 19 — Multi-set summary lines**: Lines that read like `400 [stroke] + 4 × 100 [stroke] + 4 × 50 [stroke]` (two or more rep-style expressions joined by `+`) are section notes — coaches use them as round totals. Do NOT emit a repGroup for them. Capture the line as a section-level note (or attach to the previous repGroup's note when the previous rg has the matching reps×distance).

### P4 — section directive preservation (jodie-02, jodie-04)

`"Then aerobic recovery."`, `"Take one additional minute between rounds."`, `"Take 20-25s rest per rep."` get collapsed into rg notes. Add:

> **Rule 20 — Inter-round / inter-rep directives**: Lines like `Take [N] sec/min rest per rep`, `Take one additional minute between rounds`, `If athlete is flat → remove these`, `Athletes trying to move toward...` are **set-level directives**, not new sets. Preserve the text in the previous repGroup's `note` field but do NOT create new repGroups. `Then aerobic recovery` followed by no set structure becomes a section note.

### P5 — intensity disambiguation by context (jodie-07)

`4 × 50 faster than 800 pace` was mis-mapped to `sprint`. Add:

> **Rule 21 — Pace-target vs. intensity context**: When a pace-target phrase is followed by a distance qualifier (e.g. `faster than 800 pace`, `at 200 pace`, `400 pace`), the qualifier anchors the phrase to that race distance. `faster than 800 pace` = `race_pace` for the 800 (overspeed, RPE 8-9, not sprint). Reserve `sprint` (and the `faster than race pace` Tier-1) for phrases with NO distance qualifier OR explicit `race pace` modifier. Same logic for `at 200 pace` (= race_pace), `at 100 pace` (= race_pace).

### P6 — validator-level fix: `strong` → `aerobic` (engine-side, not prompt)

`parseIntensity` should map `strong` to `{type: 'aerobic', label: 'strong'}` (engine-side, before the regex alternation hits `build`). Current regex order: `descend → build → negative_split → sprint → race_pace → threshold → easy → aerobic`. Move `strong` into the `aerobic` group as a labelled variant. This is a 1-line patch in `_llm.ts` `parseIntensity`.

---

## Bench / scorer blind spots (the bench said 1.0 — it lied)

These are the things the current bench CANNOT catch, that today hide regressions:

1. **`score.ts` doesn't score the LLM path** — only `parseWorkoutV2` (regex). The 21/21 score is a regex score, irrelevant to what Jodie sees in production.
2. **`expected.ts` has no Jodie entries** — the 8 commit-jodie files are un-scored. Any change to the LLM path can silently degrade them.
3. **`commit-coverage.ts` returns 0/0** — the regex engine produces 0 set-like captures on the Jodie corpus (regex can't parse Jodie's "as-pattern" / fragmented structure). The "≥90% coverage" bar is meaningless.
4. **`unmapped_terms` quality is un-asserted** — the bench doesn't check for noise leaks (`a1`, `dps`, etc.) or for asking `easy` repeatedly.
5. **Per-fragment intensity/gear/start_type completeness is un-asserted** — bench only checks reps/distance/interval/stroke at the rg level.
6. **The live ladder (`verify-parse-ladder.sh`) only checks for JSON-float regressions**, not structural quality.

### Scorer tightening (planned)

A new **`expected.jodie.ts`** with hand-annotated expected outputs for all 8 commit-jodie files (reps, distance, interval, section title, fragment count, fragment intensities where they matter, unmapped_terms expected set). Plus a Jodie-specific coverage test that hits the **deployed LLM endpoint** (not the regex path) and asserts:
- Every set-like line emitted a repGroup.
- Section structure matches expected title count.
- `unmapped_terms` ⊆ expected unmapped_terms (no false-positive noise).
- Per-fragment intensity is non-null whenever the segment text names an intensity word.
- Per-fragment gear / start_type is non-null when the segment names them.

---

## Files to modify

1. **`ios-native/supabase/functions/parse-workout/_llm.ts`** — SYSTEM_PROMPT rules 16–21 (P0–P5), `parseIntensity` strong→aerobic fix (P6), and update `surfaceToIntensityType` for the Tier-2 moves (P0-2).
2. **`ios-native/supabase/functions/parse-workout/_dialect-terms.ts`** — add Tier-2 words (`max`, `fast`, `all-out`, `moderate`, `easy`, `strong`, `relaxed`) to DEFAULT_RPE_BY_TERM (in `_dialect-detector.ts`); move `progressive` to PROGRESSION_TERMS; remove `easy` from TIER1_TERMS.
3. **`ios-native/supabase/functions/parse-workout/_dialect-detector.ts`** — update `DEFAULT_RPE_BY_TERM` accordingly; add the exclusion-pattern pass so zone codes / abbreviations never reach `unmapped_terms`.
4. **`scripts/parser-bench/expected.jodie.ts`** — new file, hand-annotated expected outputs for the 8 Jodie files.
5. **`scripts/parser-bench/_llm-bench.ts`** — extend to score `unmapped_terms` cleanliness + per-fragment intensity/gear completeness.
6. **Mirror** in `supabase/functions/parse-workout/` (V0.47 §5 4-place sync) once the deploy goes green.

## Re-verify recipe (post-prompt-fix)

1. **Bench**: extend `commit-coverage.ts` to use `expected.jodie.ts` and score LLM responses against it (or write a parallel `_jodie-quality.ts` that hits the live endpoint and asserts the new rules). Run after each edit; green = all 8 files ≥ 0.85 score on the new rubric.
2. **Live ladder**: `AUTH=<jwt> bash scripts/verify-parse-ladder.sh` → 14/14 cases clean, zero floats.
3. **Live re-audit**: re-run `_live-jodie-audit.py` after deploy. Expect `unmapped_terms` to drop from avg 6.5/file to 2–3/file (only true Tier-1 words), and per-fragment intensity to be non-null on every segment that names an intensity word.
