// _dialect-terms.ts — V0.47 single source-of-truth for Tier-1 dialect terms.
// Consumed by: engine.ts (parser-bench), edge index.ts (both copies).
// iOS mirrors via VocabularyService.swift — kept in sync by hand per §3 of
// V0.47_DIALECT.md (the spec, locked 2026-08-21, commit e7e394b).
//
// Do NOT hand-maintain term lists in multiple places. Add a term here, the
// three TS consumers pick it up automatically; the Swift set needs an
// intentional mirror with a comment pointing at this file + the spec.

// Tier 1 — ASK on first occurrence. A real coach-dialect word: wildly
// different between coaches (one coach's "moderate" is another's "hard").
// `label` is the canonical user-visible string the iOS end-of-session card
// keys off.
//
// V0.52 (2026-09-08) Jodie corpus audit trimmed this list to words that
// (a) actually appear in real coach inputs AND (b) genuinely need a coach
// confirmation because the engine's silent default is wrong for at least
// one coach. Words that resolve via DEFAULT_RPE_BY_TERM (the engine's
// industry-standard silent default — see _dialect-detector.ts) were moved
// out of Tier-1: `easy`, `moderate`, `strong`, `relaxed`, `max`, `fast`,
// `all-out`. `progressive` is a progression shape (start RPE → end RPE),
// like `build`/`descend` — moved to PROGRESSION_TERMS so the same
// 2-point-capture flow handles it. `activation` was demoted: it appears
// as a SECTION LABEL ("Activation set") more often than as an intensity
// word, and the regex detector can't tell which — false-positive cost
// exceeded true-positive value.
//
// V0.47 (2026-08-22) drift fix was rolled back here for `easy` (per the
// audit) — engine silent resolution is the right default for `easy`.
// Spec §6 decision #4 ("easy ask-once: Yes") was based on the corpus
// frequency argument; the Jodie audit showed the prompt was asking on
// EVERY parse, not just first occurrence, defeating the flywheel. The
// fix lives in the unmapped_terms prompt rule (rule 7): only ask once,
// and never re-ask after the coach confirms.
export type DialectTermTuple = readonly [RegExp, string];

export const TIER1_TERMS: ReadonlyArray<DialectTermTuple> = [
  // Tier-1 ASK (genuine coach-dialect, 4-bucket ambiguity):
  [/\bmoderate\b/i, "moderate"],
  [/\bhard\b/i, "hard"],
  [/\bsteady\b/i, "steady"],
  [/\bcruise\b/i, "cruise"],
  [/\blight\b/i, "light"],
  [/\btough\b/i, "tough"],
  [/\bmaximal\b/i, "maximal"],
  [/\brace\s+rhythm\b/i, "race rhythm"],
  [/\bfaster\s+than\s+race\s+pace\b/i, "faster than race pace"],
  // Tier-1 ASK only when the coach has NO coach_vocabulary row AND the
  // engine's DEFAULT_RPE_BY_TERM doesn't cover it. These are kept here
  // (rather than DEFAULT_RPE_BY_TERM) because they're genuinely
  // ambiguous — but the engine NEVER asks again after the coach maps
  // them (never-ask-twice invariant, V0.47 §4).
  //
  // ponytail (iter 11, 2026-07-28): ambiguous terms from real coach inputs.
];

// Plain-string labels, in declaration order. iOS mirrors this list. Used by
// any consumer that needs to enumerate the Tier-1 vocabulary without the
// regex (e.g. to populate a prompt-side word list).
export const TIER1_LABELS: ReadonlyArray<string> = TIER1_TERMS.map(
  ([, label]) => label,
);

// PROGRESSION_TERMS — the 2-point capture set. End-of-session card asks for
// start RPE AND end RPE separately (V0.47 §6 decision #2). Currently
// `build` / `descend` / `desc` / `progressive`. NOT included in TIER1_TERMS
// because the detector pattern overlaps `build(ing)?` — the engine picks
// them up via the build/descend fragment path, not the ambiguous-term
// detector.
//
// V0.52 (2026-09-08): `progressive` added. The Jodie corpus shows
// `progressive` is a progression shape, not a Tier-1 intensity word —
// "progressive scull" / "progressive aerobic" / "progressive to
// approximately 90%" all describe a start→end ramp, not a point value.
// Same 2-point capture flow as build/descend.
export const PROGRESSION_TERMS: ReadonlySet<string> = new Set([
  "build",
  "descend",
  "desc",
  "progressive",
]);

// PROGRESSION_SURFACE_FORMS — the regex patterns the detector uses to
// catch `build(ing)?` / `desc(end)?` / `progressive` in workout text.
// Kept separate from PROGRESSION_TERMS so the labels (used by the
// vocabulary override path) stay clean strings while the detector
// matches flexible surface forms.
export const PROGRESSION_SURFACE_FORMS: ReadonlyArray<readonly [RegExp, string]> = [
  [/\bbuild(?:ing)?\b/i, "build"],
  [/\bdesc(?:end)?\b/i, "descend"],
  [/\bprogressive\b/i, "progressive"],
];

// V0.52 (2026-09-08): Tier-2 abbreviations that look like intensity
// words but aren't — never surface in `unmapped_terms`. Jodie corpus
// audit showed these are zone codes / shorthand / efficiency cues.
// Keys are regex patterns, values are the human-readable form (for
// logging only — never surfaced to iOS).
export const TIER2_ABBREVIATION_EXCLUSIONS: ReadonlyArray<RegExp> = [
  // Zone codes (A1, A2, A3, Z1, Z2, Z3, Z4, Z5, EN1, EN2, EN3, SP1, etc.)
  /\b(?:[AZ]\d|EN\d|SP\d|MD\d|IM\d)\b/i,
  // Training shorthand / stroke abbreviations
  /\bmod\b/i,        // abbreviation for "moderate" — Tier-1 word, but "mod" alone is shorthand; engine silently resolves to moderate
  /\bfnt\b/i,        // front (drill rotation)
  /\bdr\b/i,         // drill
  /\bpb\b/i,         // pull buoy (already a gear token via extractGear)
  /\bkbo\b/i,        // kickboard order
  // Descriptive efficiency cues (not intensities)
  /\bdps\b/i,        // distance per stroke
  /\bbo\b/i,         // breakout
  /\buw\b/i,         // underwater
  /\blt\b/i,         // lactate threshold (the word "threshold" IS in DEFAULT_RPE_BY_TERM)
  /\bsps\b/i,        // strokes per second
  // Descriptive / kinematic words the LLM occasionally over-emits as
  // Tier-1 (post-deploy audit 2026-09-08). These describe EFFORT
  // QUALITY or a SEGMENT TYPE, not an intensity tier. The validator
  // already attaches them to note/label when they appear in workout
  // text — never ask the coach for an RPE band on them.
  //
  // IMPORTANT: these run as a SECOND scrub pass against the LLM's
  // `unmapped_terms` output specifically (not against the workout
  // text), because some of them appear INSIDE legitimate intensity
  // contexts (e.g. "fast breakout" is a real intensity marker, "MAX
  // velocity" is the sprint label). Scrubbing from text would erase
  // real signal; scrubbing from unmapped_terms only removes the
  // false-positive Tier-1 ask. See `scrubUnmappedTerms()` below.
];

// V0.52 (2026-09-08): Words the LLM over-emits into unmapped_terms
// after the Tier-1/Tier-2 dedup. These describe EFFORT QUALITY or a
// SEGMENT TYPE, not an intensity tier — coaches never get asked for an
// RPE band on them. Applied as a SECOND scrub pass against the
// LLM-reported unmapped_terms (after the engine-side dedup) to remove
// false-positive asks without erasing legitimate intensity signal from
// the workout text itself.
export const TIER2_LLM_OVER_EMIT_EXCLUSIONS: ReadonlyArray<RegExp> = [
  /\b(?:breakout|genuine|velocity|turnover|shutdown|finish(?:ing)?|controlled|pursuit|acceleration|execution|order|target|hold|settle|surge|rhythm|slightly)\b/i,
  // V0.52.5 (2026-09-23): drill / body-position cues. The LLM picks
  // these up from the workout text and re-emits as unmapped_terms.
  // They're not intensity words — they're movement cues the LLM should
  // never surface to the coach as "unknown". jodie-05 leaked `hips`
  // on the bench (D_noise 1.0 -> 0.5). Single-word body cues.
  /\b(?:hips|kick(?:\s+timing)?|catch(?:ing)?|bodyline|body\s+line|body\s+position|shoulder(?:s)?|elbow(?:s)?|rotation|body\s+roll|streamline|extension|finish(?:es|ing)?)\b/i,
  // "race" alone (without "rhythm"/"pace") isn't a tier-1 — it's a
  // generic modifier.
  /^\s*race\s*$/i,
];
