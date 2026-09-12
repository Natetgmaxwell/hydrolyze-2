// _dialect-detector.ts — V0.47 (2026-08-22) pure-function detector for
// the dialect-terms flywheel. Shared between the edge function (Deno
// runtime) and the bench prototype (Node runtime); no Deno-only imports
// so both can `import { extractUnmappedTerms } from "./_dialect-detector"`.
//
// Tier-1 source of truth: ./_dialect-terms.ts (consumed by edge index.ts
// + this module). The Node bench prototype has its own mirror at
// scripts/parser-bench/_dialect-terms.ts — kept in sync by hand per
// V0.47 §5 ("the 4-place sync invariant"). When a term moves between
// tiers, update _dialect-terms.ts FIRST, then this module.

import {
  TIER1_TERMS,
  PROGRESSION_TERMS as PROGRESSION_LABELS,
  PROGRESSION_SURFACE_FORMS,
  TIER2_ABBREVIATION_EXCLUSIONS,
  TIER2_LLM_OVER_EMIT_EXCLUSIONS,
} from "./_dialect-terms.ts";

export interface CoachVocabularyEntry {
  user_term: string;
  rpe_low: number;
  rpe_high: number;
}

// Tier-1 ambiguous terms (re-exported from _dialect-terms.ts so
// detectAmbiguousTerm() and extractUnmappedTerms() use the same list).
export const AMBIGUOUS_INTENSITY_TERMS: ReadonlyArray<readonly [RegExp, string]> = TIER1_TERMS;

// Tier-2 silent defaults. The engine resolves these without asking —
// they never belong in unmapped_terms. Single source-of-truth lives
// here; engine.ts and index.ts both inline this list too (the
// detectAmbiguousTerm + defaultRPEForTerm pair), kept in sync by hand.
//
// V0.47 (2026-08-22) drift fix: EVERY term that appears in TIER1_TERMS
// has been removed — the two lists must be disjoint (Tier-1 = ASK,
// Tier-2 = silent default). The pre-V0.47 state had them overlapping,
// which made the regex fallback silently resolve Tier-1 words that the
// spec explicitly wanted asked. Spec §3 row 2 (`easy`), row 1
// (`build`/`descend`), and the rest now flow through the ASK path.
//
// V0.52 (2026-09-08) Jodie audit rollback: expanded this list with the
// words that appear in 6+ Jodie workouts and have one defensible
// industry-standard RPE band. These never ask; the engine silently
// resolves them. The end-of-session card is reserved for words the
// coach genuinely disagrees with industry — not for words every coach
// uses the same way (the audit showed `easy`, `strong`, `relaxed`,
// `moderate`, `max`, `fast`, `all-out` all fell in the latter bucket).
//
// IMPORTANT: words in DEFAULT_RPE_BY_TERM must NEVER appear in
// TIER1_TERMS — they're disjoint by construction.
export const DEFAULT_RPE_BY_TERM: Readonly<Record<string, { low: number; high: number }>> = {
  // Aerobic zone — industry-standard, no coach variance
  "aerobic": { low: 5, high: 7 },
  "smooth": { low: 5, high: 7 },
  "moderate": { low: 5, high: 7 },   // V0.52: pulled from TIER1 (Jodie audit)
  // Quality-effort aerobic (the "strong aerobic" 2-word compound in
  // jodie-07). One band up from pure aerobic — coach means "effortful
  // but still aerobic ceiling", not sprint.
  "strong": { low: 6, high: 8 },      // V0.52: pulled from TIER1 (Jodie audit)
  "relaxed": { low: 4, high: 5 },     // V0.52: pulled from TIER1 (warm-up language)
  "mod": { low: 5, high: 7 },         // V0.52: abbreviation for "moderate" — engine silently maps
  // Easy zone — universal
  "easy": { low: 4, high: 5 },        // V0.52: pulled from TIER1 (the audit showed re-asking on every parse)
  "recovery": { low: 3, high: 4 },
  // Threshold zone — derived; if a coach says "threshold" they mean LT
  "threshold": { low: 8, high: 9 },
  // Race pace zone — industry term
  "race pace": { low: 8, high: 9 },
  // V0.52 (2026-09-08): `race rhythm` resolves via rule 6 to
  // race_pace. Without this entry the engine-side detector thinks
  // `race rhythm` is a Tier-1 ask (it's in TIER1_TERMS) when the LLM
  // emits it as `race rhythm` in unmapped_terms. Add it to the
  // silent set so the dedup catches it.
  "race rhythm": { low: 8, high: 9 },
  // Sprint — pure-sprint effort, no coach variance
  "sprint": { low: 9, high: 10 },
  "blast": { low: 9, high: 10 },
  "max": { low: 9, high: 10 },        // V0.52: pulled from TIER1 (Jodie's MAX velocity)
  "fast": { low: 8, high: 9 },        // V0.52: pulled from TIER1 (Jodie's "fast breakout")
  "all-out": { low: 9, high: 10 },    // V0.52: pulled from TIER1 (synonym for max/sprint)
};

// Progressions — build/descend/desc/progressive. 2-point capture at the
// iOS card (V0.47 §6 decision #2). V0.52: `progressive` joined the set
// (Jodie audit — `progressive` is a progression shape, not a Tier-1
// intensity word). The regex patterns come from
// PROGRESSION_SURFACE_FORMS in _dialect-terms.ts — single source-of-truth
// for both the label set and the detector patterns.
export const PROGRESSION_TERMS: ReadonlyArray<readonly [RegExp, string]> =
  PROGRESSION_SURFACE_FORMS;

// Sanity: PROGRESSION_LABELS ⊂ { user_term vocabulary } — if a coach has
// mapped any progression, we skip emitting it (already enforced inside
// extractUnmappedTerms). This is a one-liner no-op today; kept around
// so future label-set changes surface here rather than silently break.
export const _PROGRESSION_LABEL_SET: ReadonlySet<string> = PROGRESSION_LABELS;

// Pure function. Given the raw workout text and the coach's current
// vocabulary rows, returns the list of surface forms the LLM should be
// told are unmapped (Tier-1 + progressions). Excludes terms that
// resolve via DEFAULT_RPE_BY_TERM (Tier-2 silent defaults) — those
// never need to be asked. Used both by the edge function (to augment
// whatever the LLM reports — it sometimes forgets) and by the bench
// scripts/parser-bench/llm-parser.ts CLI to verify behaviour without
// spinning up Supabase.
//
// V0.52 (2026-09-08) Jodie audit additions:
// - Abbreviation / zone-code exclusions: words like `a1`, `dps`, `mod`
//   that the LLM occasionally surfaces but are NEVER coach-dialect
//   words — they're zone codes (A1/A2/Z1), training shorthand
//   (mod = moderate), or efficiency cues (DPS = distance per stroke).
//   Filtered out BEFORE the Tier-1 / Tier-2 dedup pass so they never
//   reach the iOS card. Pattern set lives in
//   TIER2_ABBREVIATION_EXCLUSIONS (single source-of-truth).
// - Progressive: same 2-point capture flow as build/descend (Jodie
//   uses it identically). Same never-ask-twice invariant.
export function extractUnmappedTerms(
  workoutText: string,
  vocabulary: ReadonlyArray<CoachVocabularyEntry> = [],
  parsed?: { sections?: ReadonlyArray<{ namedSets?: ReadonlyArray<{ repGroups?: ReadonlyArray<{ intensity?: { type?: string } | null; descend?: string | null; fragments?: ReadonlyArray<{ intensity?: { type?: string } | null }> }> }> }> } | null,
): string[] {
  const lower = workoutText.toLowerCase();
  const mapped = new Set(
    vocabulary.map((v) => v.user_term.toLowerCase().trim()).filter((t) => t.length > 0),
  );
  const silent = new Set(
    Object.keys(DEFAULT_RPE_BY_TERM).map((t) => t.toLowerCase()),
  );

  // V0.52: drop abbreviation / zone-code matches from the workout text
  // BEFORE Tier-1 detection runs. Cheap regex pass that prevents
  // `a1`, `a2`, `dps`, `mod`, `fnt` etc. from ever surfacing.
  let scrubbed = lower;
  for (const re of TIER2_ABBREVIATION_EXCLUSIONS) {
    scrubbed = scrubbed.replace(re, " ");
  }

  const hits = new Set<string>();

  // Tier-1 ambiguous terms.
  for (const [re, label] of AMBIGUOUS_INTENSITY_TERMS) {
    const canonical = label.toLowerCase();
    if (mapped.has(canonical)) continue;        // coach has mapped it
    if (silent.has(canonical)) continue;        // engine resolves silently
    if (re.test(scrubbed)) hits.add(canonical);
  }

  // Progressions (build/descend/desc/progressive) — only emitted when
  // the coach has NOT mapped them. When the coach HAS mapped a
  // progression, the context block carries the RPE, the LLM uses it,
  // and the term is NOT in unmapped_terms — that's the never-ask-twice
  // invariant.
  //
  // V0.52.1 (2026-09-08): also skip when the parsed response ALREADY
  // carries the progression type on a parent repGroup or fragment.
  // The "Purposeful Threshold" audit surfaced `descend` in
  // unmapped_terms even though every fragment had
  // `intensity.type="descend"` — the term was already honored, the
  // surface was just leaking through.
  // Schema: rg carries flat `intensity_type`; fragments carry nested
  // `intensity.type`. Check both shapes. Accept either the Workout
  // shape (sections[].namedSets[].repGroups[]) or the LLMOutput /
  // ValidatedSection shape (sections[].repGroups[]).
  for (const [re, label] of PROGRESSION_TERMS) {
    if (mapped.has(label)) continue;
    if (!re.test(scrubbed)) continue;
    if (parsed && (label === "descend" || label === "build" || label === "progressive")) {
      let honored = false;
      const checkRg = (rg: Record<string, unknown>) => {
        const rgType = (rg as { intensity_type?: string | null }).intensity_type;
        const rgIntensity = (rg as { intensity?: { type?: string } | null }).intensity;
        // V0.54 details-tidy (2026-09-12): also honor the rg-level
        // descend field. Without this, the dialect-detector sees
        // "descend" as unmapped even after reconcileRepCounts sets
        // rg.descend="1-4" from the regex engine for plain
        // "descend 1-4" input (the LLM emits fragments only and
        // doesn't surface rg-level intensity.type="descend").
        const rgDescend = (rg as { descend?: string | null }).descend;
        if (
          rgType === label ||
          rgIntensity?.type === label ||
          (typeof rgDescend === "string" && rgDescend.length > 0)
        ) { honored = true; return; }
        for (const f of (rg as { fragments?: ReadonlyArray<{ intensity?: { type?: string } | null }> }).fragments ?? []) {
          if (f.intensity?.type === label) { honored = true; return; }
        }
      };
      for (const sec of parsed.sections ?? []) {
        if (honored) break;
        for (const ns of (sec as { namedSets?: ReadonlyArray<{ repGroups?: ReadonlyArray<Record<string, unknown>> }> }).namedSets ?? []) {
          for (const rg of ns.repGroups ?? []) {
            checkRg(rg);
            if (honored) break;
          }
          if (honored) break;
        }
        if (honored) break;
        for (const rg of (sec as { repGroups?: ReadonlyArray<Record<string, unknown>> }).repGroups ?? []) {
          checkRg(rg);
          if (honored) break;
        }
      }
      if (honored) continue;
    }
    hits.add(label);
  }

  return [...hits];
}

// V0.52 (2026-09-08): second-pass scrub against the LLM's
// reported unmapped_terms. The LLM sometimes over-emits
// descriptive/kinematic words that look like Tier-1 but aren't
// (breakout, genuine, velocity, etc.). Run AFTER
// extractUnmappedTerms so we catch whatever the LLM reported
// even when our own detector wouldn't have surfaced it.
//
// Pass in the raw `unmapped_terms` from the LLM response; returns
// the cleaned list (Tier-1 + progressions that survived). Dedup
// preserved.
//
// V0.52.1 (2026-09-08) — context-aware scrub: when the LLM emits a
// progression term (descend/build/progressive) but the parsed response
// already carries the matching intensity.type on a parent repGroup
// OR fragment, drop it. The "Purposeful Threshold" audit surfaced
// `descend` in unmapped_terms even though every fragment already
// carried `intensity.type="descend"` — the LLM failed to suppress
// the term in unmapped despite honoring it on the fragments. The
// engine-side pass closes this gap regardless of what the LLM emits.
export function scrubUnmappedTerms(
  terms: ReadonlyArray<string>,
  parsed?: { sections?: ReadonlyArray<{ namedSets?: ReadonlyArray<{ repGroups?: ReadonlyArray<{ intensity?: { type?: string } | null; fragments?: ReadonlyArray<{ intensity?: { type?: string } | null }> }> }>; repGroups?: ReadonlyArray<{ intensity?: { type?: string } | null; intensity_type?: string | null; fragments?: ReadonlyArray<{ intensity?: { type?: string } | null }> }> }> } | null,
): string[] {
  if (!Array.isArray(terms)) return [];
  const out = new Set<string>();
  for (const raw of terms) {
    const t = String(raw).toLowerCase().trim();
    if (t.length === 0) continue;
    // Reject multi-word phrases (any whitespace inside = reject).
    if (/\s/.test(t)) continue;
    let keep = true;
    // V0.52 (2026-09-08): apply BOTH exclusion sets. The
    // LLM-over-emit list catches descriptive words the LLM
    // emits. The abbreviation list catches zone codes /
    // shorthand / efficiency cues that the engine-side
    // detector would have scrubbed from the workout text but
    // the LLM still echoes back as unmapped_terms.
    for (const re of TIER2_LLM_OVER_EMIT_EXCLUSIONS) {
      if (re.test(t)) { keep = false; break; }
    }
    if (keep) {
      for (const re of TIER2_ABBREVIATION_EXCLUSIONS) {
        if (re.test(t)) { keep = false; break; }
      }
    }
    // V0.52.1 (2026-09-08): context-aware progression suppression.
    // If the LLM emits `descend`/`build`/`progressive` as an unmapped
    // term AND the parsed response already carries that progression
    // type on a parent repGroup OR on any fragment, the engine has
    // honored it — drop the term from unmapped_terms.
    // Schema note (ValidatedRepGroup vs ValidatedFragment): the rg
    // carries intensity as flat `intensity_type` / `intensity_label`
    // (top-level keys); fragments carry it as nested
    // `intensity: { type, label }`. The scrub checks both shapes so
    // either path triggers the suppression.
    //
    // The `parsed` argument may be in either the LLMOutput shape
    // (`sections[].repGroups[]`) or the Workout shape
    // (`sections[].namedSets[].repGroups[]`) — both are accepted so the
    // function works at every call site.
    if (keep && parsed && (t === "descend" || t === "build" || t === "progressive")) {
      let honored = false;
      const checkRg = (rg: Record<string, unknown>) => {
        const rgType = (rg as { intensity_type?: string | null }).intensity_type;
        const rgIntensity = (rg as { intensity?: { type?: string } | null }).intensity;
        // V0.54 details-tidy (2026-09-12): also honor the rg-level
        // descend field (reconcileRepCounts may set rg.descend="1-4"
        // from the regex engine when the LLM left it null — without
        // this, the dialect-detector would still see "descend" as
        // unmapped because neither rg.intensity.type nor fragments
        // carry the progression type for plain "descend 1-4" input).
        // rg.descend is set for descend / build / progressive ladder
        // headers alike (parseWorkoutV2's descendMatch regex fires
        // for "desc N-M", "build N-M", "progressive N-M" alike — see
        // _dialect-terms.ts:90), so honor it for every progression
        // term without per-type branching.
        const rgDescend = (rg as { descend?: string | null }).descend;
        if (
          rgType === t ||
          rgIntensity?.type === t ||
          (typeof rgDescend === "string" && rgDescend.length > 0)
        ) {
          honored = true;
          return;
        }
        for (const f of (rg as { fragments?: ReadonlyArray<{ intensity?: { type?: string } | null }> }).fragments ?? []) {
          if (f.intensity?.type === t) { honored = true; return; }
        }
      };
      for (const sec of parsed.sections ?? []) {
        if (honored) break;
        // Workout shape: sections[].namedSets[].repGroups[]
        for (const ns of (sec as { namedSets?: ReadonlyArray<{ repGroups?: ReadonlyArray<Record<string, unknown>> }> }).namedSets ?? []) {
          for (const rg of ns.repGroups ?? []) {
            checkRg(rg);
            if (honored) break;
          }
          if (honored) break;
        }
        if (honored) break;
        // LLMOutput / ValidatedSection shape: sections[].repGroups[]
        for (const rg of (sec as { repGroups?: ReadonlyArray<Record<string, unknown>> }).repGroups ?? []) {
          checkRg(rg);
          if (honored) break;
        }
      }
      if (honored) keep = false;
    }
    if (keep) out.add(t);
  }
  return [...out];
}