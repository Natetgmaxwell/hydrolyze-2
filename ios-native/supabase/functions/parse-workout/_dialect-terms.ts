// _dialect-terms.ts — V0.47 single source-of-truth for Tier-1 dialect terms.
// Consumed by: engine.ts (parser-bench), edge index.ts (both copies).
// iOS mirrors via VocabularyService.swift — kept in sync by hand per §3 of
// V0.47_DIALECT.md (the spec, locked 2026-08-21, commit e7e394b).
//
// Do NOT hand-maintain term lists in multiple places. Add a term here, the
// three TS consumers pick it up automatically; the Swift set needs an
// intentional mirror with a comment pointing at this file + the spec.

// Tier 1 — PROMPT. Wildly different between coaches (one coach's "moderate"
// is another's "hard"). Order matches the engine array (line 703-721 in
// engine.ts prior to extraction). `label` is the canonical user-visible
// string the iOS end-of-session card keys off.
export type DialectTermTuple = readonly [RegExp, string];

export const TIER1_TERMS: ReadonlyArray<DialectTermTuple> = [
  [/\bmoderate\b/i, "moderate"],
  [/\bhard\b/i, "hard"],
  [/\bsteady\b/i, "steady"],
  [/\bcruise\b/i, "cruise"],
  [/\blight\b/i, "light"],
  [/\btough\b/i, "tough"],
  [/\bstrong\b/i, "strong"],
  [/\ball[-\s]?out\b/i, "all-out"],
  // ponytail (iter 11, 2026-07-28): new ambiguous terms from real coach inputs
  [/\brelaxed\b/i, "relaxed"],
  [/\bprogressive\b/i, "progressive"],
  [/\bactivation\b/i, "activation"],
  [/\bmaximal\b/i, "maximal"],
  [/\brace\s+rhythm\b/i, "race rhythm"],
  [/\bfaster\s+than\s+race\s+pace\b/i, "faster than race pace"],
  [/\bfast\b/i, "fast"],
  [/\bmax\b/i, "max"],
];

// Plain-string labels, in declaration order. iOS mirrors this list. Used by
// any consumer that needs to enumerate the Tier-1 vocabulary without the
// regex (e.g. to populate a prompt-side word list).
export const TIER1_LABELS: ReadonlyArray<string> = TIER1_TERMS.map(
  ([, label]) => label,
);

// PROGRESSION_TERMS — the 2-point capture set. End-of-session card asks for
// start RPE AND end RPE separately (V0.47 §6 decision #2). Currently
// `build` / `descend` / `desc`. NOT included in TIER1_TERMS because the
// detector pattern overlaps `build(ing)?` — the engine picks them up via
// the build/descend fragment path, not the ambiguous-term detector.
export const PROGRESSION_TERMS: ReadonlySet<string> = new Set([
  "build",
  "descend",
  "desc",
]);
