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
  for (const [re, label] of PROGRESSION_TERMS) {
    if (mapped.has(label)) continue;
    if (re.test(scrubbed)) hits.add(label);
  }

  return [...hits];
}