/**
 * _llm.ts — LLM-primary parser, Deno-compatible module for the
 * Supabase Edge Function runtime.
 *
 * Architecture: coach text → MiniMax LLM (structured extraction) →
 * regex validator (intensity/gear/dive/suit/stroke canonicalization)
 * → workout tree in the same shape parseWorkoutV2() returns.
 *
 * Used by index.ts as the primary parser with parseWorkoutV2() as
 * the fallback when MiniMax is down, rate-limited, or returns junk.
 *
 * V0.36 (2026-08-13): provider switched Groq → MiniMax-M3. Groq's
 * free-tier 8K TPM cap silently degraded full-workout parses. MiniMax
 * has no such cap. json_object mode (NOT strict json_schema — MiniMax
 * ignores json_schema and invents its own structure), so the system
 * prompt carries the exact output shape.
 *
 * Env required: MINIMAX_API_KEY (set via `supabase secrets set`).
 * Env optional: MINIMAX_MODEL (default: MiniMax-M3).
 */

const MINIMAX_URL = "https://api.minimax.io/v1/text/chatcompletion_v2";
const MINIMAX_MODEL = Deno.env.get("MINIMAX_MODEL") || "MiniMax-M3";

// ─── Types (output shape matches parseWorkoutV2's Workout) ─────────────────

interface LLMFragment {
  id: string | null; // V0.35 (2026-08-12): stamped deterministically post-validation
  distance: number | null;
  stroke: string | null;
  instruction: string | null;
  // ponytail (2026-08-11): fragment intensity is the pairing engine's
  // key (distance + intensity + start type). The old schema stuffed
  // "fast"/"easy" into stroke and never carried intensity at all —
  // pairing saw "75m @ unknown". Now explicit: {type, label}.
  intensity: { type: string; label: string } | null;
  // V0.37 (2026-08-13): per-fragment gear + start_type, so the pairing
  // engine's cost tiers key on the fragment's OWN context (not just the
  // parent repGroup's). The LLM may emit them; the validator derives them
  // from the fragment's own segment text when absent (same fallback as
  // intensity). start_type ∈ 'dive' | 'push' | 'wall' | null.
  gear: string[] | null;
  start_type: string | null;
}

type ZoneTerm = "easy" | "steady" | "hard" | "sprint";

interface LLMRepGroup {
  reps: number | null;
  distance: number | null;
  stroke: string | null;
  interval: string | null;
  zone_term?: ZoneTerm | null;
  note: string | null;
  fragments: LLMFragment[];
  sourceLine: string;
}

interface LLMSection {
  title: string | null;
  repGroups: LLMRepGroup[];
}

interface LLMOutput {
  sections: LLMSection[];
  // V0.47 (2026-08-22): terms the LLM hit in the workout text that are
  // NOT in COACH VOCABULARY and NOT in the rule-6 general mapping. The
  // iOS end-of-session card surfaces these so the coach can confirm the
  // intended RPE band. The edge function (index.ts) adds the Tier-1
  // terms the LLM failed to report back to this list before returning
  // to the client — defensive: the LLM sometimes forgets.
  unmapped_terms?: string[];
}

// V0.47 (2026-08-22): one row from `coach_vocabulary` for the
// authenticated coach. Loaded by index.ts and injected into the LLM
// prompt as a per-coach context block. The `rpe_low`/`rpe_high` are the
// coach's own values; the LLM uses them literally (rule 7 below).
export interface CoachVocabularyEntry {
  user_term: string;        // surface form, e.g. "easy", "moderate"
  rpe_low: number;
  rpe_high: number;
}

export interface ValidatedRepGroup {
  reps: number;
  distance: number;
  stroke: string | null;
  interval: string | null;
  intensity_type: string | null;
  intensity_label: string | null;
  zone_term: ZoneTerm | null;
  gear: string[] | null;
  dive: boolean;
  suit: boolean;
  note: string | null;
  fragments: LLMFragment[];
  sourceLine: string;
}

export interface ValidatedSection {
  title: string | null;
  repGroups: ValidatedRepGroup[];
}

export interface Workout {
  title: string | null;
  sections: { title: string | null; namedSets: { label: string | null; note: string | null; repGroups: ValidatedRepGroup[] }[] }[];
  // V0.47 (2026-08-22): see LLMOutput.unmapped_terms. Populated when
  // the LLM path succeeds; the regex-fallback path in index.ts returns
  // an empty array (the fallback never generates these — the iOS card
  // shows "no new terms" on a degraded parse).
  unmapped_terms?: string[];
}

// ─── Few-shot examples (2, highest-value; trimmed 2026-08-12 to fit
// the token budget) ──

const FEW_SHOT_EXAMPLES = [
  {
    input: `Speed preparation — 400m

2 rounds:

• 1 × 25m acceleration to 15m, easy to wall @ :50

• 1 × 25m build into a fast finish @ :50

• 1 × 50m as 25m smooth + 25m fast @ 1:10

• 100m easy @ 2:00

Take one additional minute between rounds.`,
    output: {
      sections: [{
        title: "Speed preparation — 400m (2 rounds)",
        repGroups: [
          { reps: 1, distance: 25, stroke: null, interval: "0:50", note: "acceleration to 15m, easy to wall", fragments: [], sourceLine: "1 × 25m acceleration to 15m, easy to wall @ :50" },
          { reps: 1, distance: 25, stroke: null, interval: "0:50", note: "build into a fast finish", fragments: [], sourceLine: "1 × 25m build into a fast finish @ :50" },
          { reps: 1, distance: 50, stroke: null, interval: "1:10", note: "as 25m smooth + 25m fast", fragments: [
            { distance: 25, stroke: null, instruction: "smooth", intensity: { type: "aerobic", label: "smooth" }, gear: null, start_type: null },
            { distance: 25, stroke: null, instruction: "fast", intensity: { type: "sprint", label: "fast" }, gear: null, start_type: null }
          ], sourceLine: "1 × 50m as 25m smooth + 25m fast @ 1:10" },
          { reps: 1, distance: 100, stroke: null, interval: "2:00", note: "easy — Section notes: Take one additional minute between rounds", fragments: [], sourceLine: "100m easy @ 2:00" }
        ]
      }]
    }
  },
  {
    input: `4 x (75 fast / 25 easy)`,
    output: {
      sections: [{
        title: null,
        repGroups: [{
          reps: 4, distance: 100, stroke: null, interval: null, note: null,
          fragments: [
            { distance: 75, stroke: null, instruction: null, intensity: { type: "sprint", label: "fast" }, gear: null, start_type: null },
            { distance: 25, stroke: null, instruction: null, intensity: { type: "easy", label: "easy" }, gear: null, start_type: null }
          ],
          sourceLine: "4 x (75 fast / 25 easy)"
        }]
      }]
    }
  }
];

// ─── System prompt (coach's grammar) ───────────────────────────────────────

const SYSTEM_PROMPT = `You are an expert swimming workout parser. Convert raw coach-written workout text into structured JSON. Coaches write in a compact grammar — understand the structure and intent, don't just match numbers.

## Critical rules

1. **Hierarchy**: Numbered sub-items (1. 2. 3.) that follow a set DESCRIBE the content of each rep — they are NOT standalone sets. Attach as notes or fragments to the parent set. Exception: numbered lists under a header like "Round emphasis" are section notes, not sets.
2. **Time-based sets**: "Free - 8:00 kick on side" = freestyle kicking for 8 minutes. distance=null, the time is a DURATION.
3. **Per-rep-range instructions**: "1-2 = 2 uw kicks + 2 fast arms" after "10 x 25 @ 30" describes specific reps. Attach to the parent set's note.
4. **Implicit inheritance (ditto)**: A quote mark (") means "same as above." Resolve it — do not pass the literal quote through.
5. **Round multipliers**: "twice through" / "2 x through" AFTER a block means repeat the block. "N rounds:" BEFORE a block means the block runs N times. Neither creates a set, neither multiplies reps.
6. **Composite sets / fragments**:
   - Inline parens: "4 x (75 fast / 25 easy)" → 1 repGroup, reps=4, distance=100, fragments=[{distance:75, stroke:null, intensity:{type:"sprint",label:"fast"}}, {distance:25, stroke:null, intensity:{type:"easy",label:"easy"}}]
   - "Each N: 25 Drill/25 Build/.../25 Easy" → 4 fragments on the parent repGroup (the slash-separated distance-prefixed pattern is ALWAYS composite — see rule 18).
   - "as X + Y" / "X into Y" / "X to Y" / "X → Y" within a set → fragments for each segment
   - "stroke1/stroke2 by 25m" → fragments alternating strokes
   - Sub-segments sum to the parent's distance.
   - **Fragment intensity is CRITICAL**: each fragment carries its own intensity {type,label}. Map the coach's word: fast/sprint/all-out/max → sprint; easy/recovery/warm-up/mod → easy; moderate/steady/cruise/smooth/aerobic/strong/mod → aerobic; tempo/threshold → threshold; race pace/race rhythm/r.p./"100 pace"/"200 pace"/"800 pace" → race_pace; descend → descend; build/acceleration/progressive → build. label is the coach's exact word lowercased ("fast", "maximal finish", "race rhythm", "mod"). Pure intensity words ("fast", "easy", "mod") go in intensity — NOT in stroke. Stroke stays null unless a real stroke is stated.
   - **Per-fragment intensity completeness**: when a composite set's sub-segment text names an intensity word (e.g. "25 strong / 25 easy" or "15 m MAX + 35 m very easy" or "12.5 fast / 12.5 easy"), EVERY such fragment MUST carry its own intensity {type,label}. The validator does NOT silently backfill — your output is the pairing engine's signal. When a sub-segment's text contains no intensity word (e.g. "25 scull", "25 hold that rate", "25 perfect swimming", "300 settle", "50 tapping"), emit intensity: null.
   - **Per-fragment gear + start_type propagation**: gear and start_type apply to the SPECIFIC fragment whose text names them. When the text says "12.5 MAX Fly + easy" with an off-the-blocks context, the first fragment carries start_type "dive". When the parent's gear applies to all fragments ("4 × 50 with paddles: 25 strong + 25 easy"), emit gear on EVERY fragment. Otherwise (no gear/start on the segment) emit null.
7. **Coach vocabulary (per-coach overrides)**: the system message at the top of this prompt carries a "COACH VOCABULARY" block listing this coach's own word→RPE mappings. For any term that appears in BOTH the workout text AND that block, use the block's RPE band literally — even when rule 6 above would have mapped it differently. For progressions (build/descend/desc/progressive) the block may use the form "start RPE N → end RPE M"; emit the fragment's intensity as { type: "build" or "descend", label: "start N → end M" }. For any term that appears in the workout text but is in NEITHER the COACH VOCABULARY block NOR the rule-6 general mapping, include its surface form in the response's unmapped_terms array — one entry per unique word (dedup, lowercased).
   - **NEVER include in unmapped_terms**:
     (a) zone codes: A1, A2, A3, Z1, Z2, Z3, Z4, Z5, EN1–3, SP1–3, MD1–3, IM1–3 (e.g. "200 A1 → 200 A2 → 200 strong A2" — A1/A2 are zone markers, not intensity words)
     (b) training shorthand / abbreviations: `mod` (moderate), `fnt` (front), `dr` (drill), `pb` (pull buoy), `kbo` (kickboard)
     (c) descriptive efficiency cues: `DPS` (distance per stroke), `BO` (breakout), `UW` (underwater), `LT` (lactate threshold — `threshold` itself is in DEFAULT_RPE and already silent), `SPS` (strokes per second)
     (d) any word that resolves via the engine's DEFAULT_RPE_BY_TERM (easy, recovery, smooth, threshold, race pace, sprint, blast, max, fast, all-out, moderate, mod, strong, relaxed). These never ask — the engine already silently resolves them.
   - **NEVER ask twice**: once the COACH VOCABULARY block carries an entry for a term, that term is resolved silently forever across re-parses. The iOS card asks once per coach, not once per workout.
   - **NEVER emit unmapped_terms from a section title**: words like "Activation set", "Activation", "Drill set", "Aerobic finish", "Race priming", "Swim-down" are section labels — not intensity words. Do NOT surface them in unmapped_terms even if the bare word matches a Tier-1 regex.
8. **Strokes**: free, back, breast, fly, IM, kick, drill, choice, pull. "uw" = underwater kick. "scull" = a drill. "drill/swim", "kick/swim", "scull/swim" = combo sets — stroke is the first (drill/kick/scull), the combo goes in the note. If multiple strokes, use the first mentioned.
9. **Intervals**: Pass through exactly as written ("1.50", "1:30", ":40", "@ 30"). The validator normalizes.
10. **Single swims**: "400 free" with no "x" is reps=1.
11. **Section headers**: "Warm up", "Main Set", "Cool down" start new sections. Keep the full header as the title, including any em-dash distance ("Main set — 1,400m"). Append "(N rounds)" when the section has a round block.
12. **Pattern shorthand (FBBF, FBF)**: F=Free, B=Back, K=Breast, R=Fly, I=IM, M=Medley. Set stroke to the FIRST letter, put the pattern in the note. "same as above" / "same" inherits the pattern.
13. **Multi-swim lines**: A single line may contain multiple separate swims, like "400 kick for body/head position 100 free 100 back". These are THREE separate repGroups: (1) 400 kick, (2) 100 free, (3) 100 back. Split on distance boundaries.
14. **Start types**: "start or push", "push start", "from a dive", "off the blocks" describe the start. Keep in the note — the validator detects dive/push.
15. **3-minute all-out test (3MT)**: when a set line contains "3MT", "3-MT", "3 MT", "3-min all-out", "3 min all out", "3-minute all-out", "3min all out", "3 min test", "3-minute test", or "3min test", emit a single repGroup with intensity { type: "3mt", label: "3-minute all-out" }, reps=1, distance=25 (the split distance the coach taps LAP at), and no interval — the 3:00 swim is continuous, not interval-based. Stroke parses from any remaining text (e.g. "3MT free" → Free); default is Free. The "3MT" marker wins over the generic "all-out" → sprint mapping. "all-out" alone is NOT a 3MT marker.
16. **Composite fragment completeness (re-emphasis)**: when a set has 2+ fragments, EVERY fragment whose segment text names an intensity word carries its own intensity {type,label}. Do NOT collapse segments to a single shared intensity — the pairing engine keys on per-fragment intensity to predict per-swimmer pace targets. Examples that frequently get this wrong (verify each one):
    - "4 × 50 @ 1:00 — 25 strong / 25 easy" → fragments [{25, null→aerobic strong}, {25, easy}] — first fragment MUST carry intensity from "strong".
    - "12.5 power kick / 12.5 easy" → fragments [{12.5, intensity from "power"}, {12.5, easy}]. "power" is effortful-aerobic; map to {type:"aerobic", label:"power"}.
    - "25 strong / 25 easy" inside a kick set → fragments [{25, aerobic strong}, {25, easy}]. Don't drop the "strong".
    - "25 mod / 25 tapping" (Jodie's shorthand) → fragments [{25, aerobic mod}, {25, null}]. "mod" is `moderate`, the engine silently maps.
    - "50 surge / 50 settle" → fragments [{50, sprint (surge = sprint-class effort)}, {50, aerobic settle}].
17. **Per-fragment gear + start_type propagation (re-emphasis)**: when a composite set's segments share a parent gear (e.g. "4 × 50 with paddles: 25 strong + 25 easy"), emit that gear on EVERY fragment. When a parent start_type applies ("4 × 50 Dive → 35 m race quality → shut down"), emit a single repGroup with dive=true; if instead the parent has 3 distinct sub-segments each with their own start ("15 m off blocks + 35 m from wall"), emit per-fragment start_type: [{15, dive}, {35, wall}]. Empty/unknown start on a segment → null, never inherit the parent's start_type.
18. **Composite vs. per-rep-instruction boundary**: when a line under a set looks like `25 [word1] / 25 [word2] / 25 [word3]` (slash-separated sub-segments WITH a distance prefix on each segment), emit COMPOSITE fragments, NOT per-rep notes. The distinguishing signal is `N m + intensity/segment-word` patterns (e.g. `25 scull`, `25 build`, `25 DPS`, `25 perfect swimming`). Numbered list patterns (`1. fists / 2. catch-up`) are per-rep instructions and stay as notes. **The slash-separated distance-prefixed pattern is ALWAYS composite, regardless of whether the segments above are simple or compound words.** A common failure mode (Jodie 2026-09-08 audit): `4 × 100 / 25 scull / 25 DPS / 25 build / 25 easy` → must emit 4 fragments, not collapse to a single repGroup with the sub-list in `note`.
19. **Multi-set summary lines**: lines that read like `400 [stroke] + 4 × 100 [stroke] + 4 × 50 [stroke]` (two or more rep-style expressions joined by `+` or `&`) are SECTION SUMMARIES — coaches use them as round totals. Do NOT emit a repGroup for them. Capture the line as a section-level note (or attach to the previous repGroup's note when the previous rg has the matching reps×distance). Examples: `400 swim + 4 × 100 pull + 4 × 50`, `100 easy + 4 × 50 strong`.
20. **Inter-round / inter-rep directives**: lines like `Take [N] sec/min rest per rep`, `Take one additional minute between rounds`, `If athlete is flat → remove these`, `Then aerobic recovery.`, `Later in the macrocycle this session becomes...` are SET-LEVEL DIRECTIVES, not new sets. Preserve the text in the previous repGroup's `note` field or as a section note when no repGroup precedes. Do NOT create new repGroups from them.
21. **Pace-target context disambiguation**: when a pace-target phrase is anchored to a distance qualifier (`faster than 800 pace`, `at 200 pace`, `400 pace`, `at 100m tempo`), the qualifier anchors the phrase to THAT race distance. Default `race_pace` (not sprint). Reserve `sprint` (and the `faster than race pace` Tier-1) for phrases with NO distance qualifier OR explicit `race pace` modifier. Examples:
    - "4 × 50 faster than 800 pace" → race_pace (1–2% faster than 800m race pace; NOT sprint).
    - "3 × broken 100: 50 at 200 pace :10, 50 at or slightly faster than 200 pace" → race_pace race_pace.
    - "75 @ 100 pace DIVE" → race_pace (the `cleanFragmentIntensity` validator already maps `@ NNN pace` to race_pace).
    - "50 at 200-race rhythm" → race_pace.
    - "8 × 25 @ 1:15 MAX velocity" → sprint (no distance qualifier, MAX is the intensity).
    - "faster than race pace" (no distance) → Tier-1 (engine default sprint / RPE 9-10).

## Output shape (MUST follow exactly)

Return a single JSON object:

{
  "sections": [
    {
      "title": "Section header or null",
      "repGroups": [
        {
          "reps": 8,
          "distance": 100,
          "stroke": "free",
          "interval": "1:30",
          "note": "instructions or null",
          "zone_term": "steady",
          "fragments": [
            { "distance": 75, "stroke": null, "instruction": null, "intensity": { "type": "sprint", "label": "fast" } }
          ],
          "sourceLine": "the exact source line(s)"
        }
      ]
    }
  ],
  "unmapped_terms": ["moderate", "Jodie's strong"]
}

- fragments: empty array [] for simple sets; one entry per sub-segment for composite sets.
- intensity: {type, label} or null. type ∈ easy|aerobic|threshold|race_pace|pace_target|sprint|descend|build|negative_split|percent_range|3mt. label = the coach's exact word lowercased ("3-minute all-out" for 3MT).
- zone_term: "easy" | "steady" | "hard" | "sprint" | null. The set's governing zone word when the set text states exactly one of the four zone words (standalone intensity word); null when there is no zone word OR more than one distinct zone word. The zone_term is SEPARATE from intensity — "Steady" yields zone_term "steady" AND intensity type "aerobic". The 3MT marker never yields a zone_term.
- stroke: null when no stroke is stated. Pure intensity words ("fast", "easy") go in intensity, NOT stroke.
- reps: 1 for single swims. distance: null for time-based sets ("Free - 8:00 kick").
- Every repGroup MUST include all keys: reps, distance, stroke, interval, note, fragments, sourceLine.
- unmapped_terms: array of unique surface forms (lowercased) that the LLM hit in the workout text but could not resolve via COACH VOCABULARY or rule 6 — see rule 7 above. Empty array [] when the workout has no such terms.

## What NOT to create sets from
- Lines that are purely instructions/notes for a set above (rep-range breakdowns, "Each N:" descriptions)
- "twice through" / "N rounds:" / round multiplier lines
- "Round emphasis" lists and other section-level notes
- Lines that are choices/options ("Choose from:", "Drill choices")`;

// V0.47 (2026-08-22): turn the coach's vocabulary rows into the
// "COACH VOCABULARY" block the LLM prompt expects. One line per term,
// progressions formatted as "start RPE N → end RPE M" when the caller
// pre-encoded them (current v1 stores rpe_low/rpe_high as a flat band;
// the slice-3 card handles the 2-point case at write time). Keep the
// block tight — every line costs tokens in the cold path (V0.37 lesson).
// The LLM hits this block on the first system message and never on the
// few-shot exchanges.
export function buildCoachVocabularyBlock(
  vocabulary: ReadonlyArray<CoachVocabularyEntry>,
): string {
  if (vocabulary.length === 0) return "";
  const lines = vocabulary
    .slice()
    .sort((a, b) => a.user_term.localeCompare(b.user_term))
    .map((v) => `  ${v.user_term} → RPE ${v.rpe_low}-${v.rpe_high}`);
  return [
    "COACH VOCABULARY (this coach's own words — override the general rules below when one of these appears):",
    ...lines,
    "When one of these words appears, use this RPE unless the surrounding text clearly contradicts it.",
    "",
  ].join("\n");
}

// ─── Build prompt messages ────────────────────────────────────────────────

function buildMessages(
  workoutText: string,
  coachVocabulary: ReadonlyArray<CoachVocabularyEntry> = [],
) {
  const vocabBlock = buildCoachVocabularyBlock(coachVocabulary);
  const systemContent = vocabBlock ? `${vocabBlock}${SYSTEM_PROMPT}` : SYSTEM_PROMPT;
  const messages: Array<{ role: string; content: string }> = [
    { role: "system", content: systemContent }
  ];
  for (const ex of FEW_SHOT_EXAMPLES) {
    messages.push({ role: "user", content: `Parse this swimming workout into the JSON object described above:\n\n${ex.input}` });
    messages.push({ role: "assistant", content: JSON.stringify(ex.output) });
  }
  messages.push({ role: "user", content: `Parse this swimming workout into the JSON object described above:\n\n${workoutText}` });
  return messages;
}

// ─── Call MiniMax ─────────────────────────────────────────────────────────

// V0.36 (2026-08-13): typed LLM error — carries the HTTP status so the
// caller can classify rate limits vs other failures for the degraded flag.
export class LLMError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

async function callMiniMax(
  workoutText: string,
  coachVocabulary: ReadonlyArray<CoachVocabularyEntry> = [],
): Promise<LLMOutput> {
  const apiKey = Deno.env.get("MINIMAX_API_KEY");
  if (!apiKey) throw new Error("MINIMAX_API_KEY not set");

  const messages = buildMessages(workoutText, coachVocabulary);
  const body = {
    model: MINIMAX_MODEL,
    messages,
    temperature: 0.1,
    // V0.37 (2026-08-13): MiniMax-M3 is a reasoning model — it emits a
    // large `reasoning_content` BEFORE the JSON `content`. Two problems:
    // (1) with max_tokens 4096 the reasoning consumed the whole budget and
    // content came back empty (finish_reason: "length") on full-workout
    // parses — the root cause of the 5/10 failure rate; (2) even with a
    // bigger budget, reasoning pushed latency to 40-90s, blowing the 30s
    // iOS timeout. This is structured extraction, not a reasoning task —
    // disable thinking so the model emits JSON directly and fast.
    max_tokens: 16384,
    thinking: { type: "disabled" },
    // V0.36 (2026-08-13): json_object mode. MiniMax IGNORES strict
    // json_schema and invents its own structure — the system prompt
    // carries the exact output shape instead.
    response_format: { type: "json_object" }
  };

  // V0.37 (2026-08-13): single retry on transient MiniMax failures.
  // The live 5/10 failure rate was transient 5xx-or-empty responses from
  // api.minimax.io, NOT rate limits (no 429 reason fired). One retry after
  // a 1s constant delay. Retry fires on: 5xx, empty content, empty choices,
  // malformed JSON in content. Do NOT retry 4xx (auth/bad-request are
  // deterministic) or a missing key. If the retry also fails, throw so
  // parseWithFallback falls back to regex.
  let lastErr: unknown = null;
  for (let attempt = 0; attempt < 2; attempt++) {
    if (attempt > 0) {
      // Constant 1s delay before the single retry.
      await new Promise((resolve) => setTimeout(resolve, 1000));
    }
    try {
      return await miniMaxOnce(body);
    } catch (err) {
      lastErr = err;
      if (attempt === 0 && isTransientMiniMaxFailure(err)) continue;
      throw err;
    }
  }
  // Unreachable in practice (the throw above exits on attempt 1); guard the
  // return type.
  throw lastErr instanceof Error ? lastErr : new LLMError(0, "MiniMax call failed");
}

// One MiniMax fetch + parse. Transient failures surface as LLMError with
// status >= 500 (5xx from MiniMax) or status 0 (empty/ malformed content);
// deterministic failures surface as LLMError with a 4xx status.
async function miniMaxOnce(body: Record<string, unknown>): Promise<LLMOutput> {
  const apiKey = Deno.env.get("MINIMAX_API_KEY")!;
  const resp = await fetch(MINIMAX_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${apiKey}`
    },
    body: JSON.stringify(body)
  });

  if (!resp.ok) {
    const errText = await resp.text();
    throw new LLMError(resp.status, `MiniMax API error ${resp.status}: ${errText}`);
  }

  const data = await resp.json() as {
    choices: Array<{ message: { content: string } }>;
    usage: { prompt_tokens: number; completion_tokens: number; total_tokens: number };
  };

  const content = data.choices?.[0]?.message?.content;
  if (!content) {
    throw new LLMError(0, "MiniMax returned empty content / empty choices");
  }

  try {
    return JSON.parse(content) as LLMOutput;
  } catch (err) {
    throw new LLMError(0, `MiniMax returned malformed JSON: ${err instanceof Error ? err.message : String(err)}`);
  }
}

// Transient MiniMax failures worth one retry: 5xx responses and empty or
// malformed content. 4xx (auth, bad request) are deterministic and NOT
// retried. Missing key throws before this is reached.
function isTransientMiniMaxFailure(err: unknown): boolean {
  if (!(err instanceof LLMError)) return false;
  return err.status >= 500 || err.status === 0;
}

// ─── Validator (reused patterns; Deno-port from the Node prototype) ───────

const STROKE_MAP: Record<string, string> = {
  "free": "Free", "freestyle": "Free", "crawl": "Free", "front crawl": "Free",
  "fist": "Free", "fists": "Free", "catch-up": "Free", "catch up": "Free", "catchup": "Free", "swim": "Free",
  "back": "Back", "backstroke": "Back",
  "breast": "Breast", "breaststroke": "Breast",
  "fly": "Fly", "butterfly": "Fly", "butter": "Fly",
  "im": "IM", "i.m.": "IM", "individual medley": "IM", "medley": "IM",
  "kick": "Kick", "kickboard": "Kick", "flutter": "Kick", "dolphin": "Kick", "uw kick": "Kick", "uw": "Kick",
  "drill": "Drill", "scull": "Drill",
  "pull": "Pull",
  "choice": "Choice",
};

function canonicalizeStroke(raw: string | null): string | null {
  if (!raw) return null;
  const lower = raw.toLowerCase().trim();
  if (STROKE_MAP[lower]) return STROKE_MAP[lower];
  for (const [key, val] of Object.entries(STROKE_MAP)) {
    if (lower.includes(key)) return val;
  }
  return null;
}

function normalizeInterval(raw: string | null): string | null {
  if (!raw) return null;
  let s = raw.trim().replace(/^@\s*/, "");
  if (/^\d+\.\d{2}$/.test(s)) s = s.replace(".", ":");
  if (/^:(\d{2})$/.test(s)) s = `0:${s.slice(1)}`;
  if (/^\d{2}$/.test(s) && parseInt(s) < 60) s = `0:${s}`;
  const compact = s.match(/^(\d)(\d{2})$/);
  if (compact) s = `${compact[1]}:${compact[2]}`;
  return s.replace(/^@/, "").trim() || null;
}

const GEAR_PATTERNS: Array<[RegExp, string]> = [
  [/\bfins\b/i, "fins"], [/\bflippers\b/i, "fins"],
  [/\bpull\s*paddles?\b/i, "pull_paddle"], [/\bfinger\s*paddles?\b/i, "finger_paddle"],
  [/(?<!\bfinger\s)(?<!pull\s)paddles?\b/i, "paddles"],
  [/\b(?:pull[\s-]?buoy|buoy)\b/i, "pull_buoy"], [/\bPB\b/, "pull_buoy"],
  [/\bkickboard\b/i, "kickboard"], [/\bkick\s*board\b/i, "kickboard"], [/\bKBO\b/, "kickboard"],
  [/\bsnorkel\b/i, "snorkel"],
  [/\bdrum\s*parachute\b/i, "parachute"], [/\bparachute\b/i, "parachute"],
  [/\bresistance\s*(?:band|cord|tubing)\b/i, "resistance_band"], [/\bbungees?\b/i, "resistance_band"],
  [/\bankle\s*bands?\b/i, "ankle_band"], [/(?<!ankle\s)\bbands?\b/i, "resistance_band"],
  [/\bpower\s*tower\b/i, "power_tower"], [/\bweight\s*belt\b/i, "weight_belt"],
  [/\b(?:tennis|golf)\s*balls?\b/i, "tennis_balls"],
  [/\bdrag\s*(?:suit|shorts?)\b/i, "drag_suit"], [/\bdrags?\b/i, "drag_suit"],
  [/\bstretchcordz\b/i, "stretchcordz"],
];

function extractGear(text: string): string[] | null {
  const detected: Set<string> = new Set();
  for (const [re, gear] of GEAR_PATTERNS) {
    if (re.test(text)) detected.add(gear);
  }
  return detected.size > 0 ? [...detected] : null;
}

const DIVE_RE = /\b(?:from\s+a\s+dive|dive\s+start|off\s+the\s+blocks?|block\s+start|racing\s+dive|dive\s+entry|dive|from\s+a\s+push|push\s+start|start\s+or\s+push|push\s+acceleration)\b/i;
const SUIT_RE = /\b(?:in\s+a\s+suit|tech\s*suit|raced?\s+in\s+(?:a\s+)?suit|suit\s+on|full[\s-]?body|jaked|arena|speedo\s+lzr)\b/i;

// V0.37 (2026-08-13): per-fragment start_type. The pairing engine's cost
// tiers key on (distance, stroke, gear, intensity) per swimmer_pbs row, but
// a dive/push/wall start shifts the expected time. Values: 'dive' | 'push' |
// 'wall' | null. Order matters — check wall (which can contain "push") before
// push, and pure dive words before "dive" alone.
const START_TYPE_RULES: Array<[RegExp, "dive" | "push" | "wall"]> = [
  [/\b(?:off\s+the\s+wall|from\s+the\s+wall|wall\s+start|push\s+off\s+the\s+wall|turn\s+start)\b/i, "wall"],
  [/\b(?:from\s+a\s+dive|dive\s+start|off\s+the\s+blocks?|block\s+start|racing\s+dive|dive\s+entry|dive)\b/i, "dive"],
  [/\b(?:from\s+a\s+push|push\s+start|start\s+or\s+push|push\s+acceleration|push)\b/i, "push"],
];

function deriveStartType(text: string): "dive" | "push" | "wall" | null {
  for (const [re, type] of START_TYPE_RULES) {
    if (re.test(text)) return type;
  }
  return null;
}

function detectDive(text: string): boolean { return DIVE_RE.test(text); }
function detectSuit(text: string): boolean { return SUIT_RE.test(text); }

const THREE_MT_RE =
  /\b3\s*[-]?\s*m(?:in(?:ute)?s?)?\s+(?:all[\s-]?out|test)\b|\b3\s*[-]?\s*mt\b/i;

function parseIntensity(text: string): { type: string; label: string } | null {
  const t = text.toLowerCase();
  // V0.38 (2026-08-15): 3-minute all-out test marker wins over the
  // generic mappings below. Mirrors index.ts THREE_MT_RE.
  if (THREE_MT_RE.test(text)) {
    return { type: "3mt", label: "3-minute all-out" };
  }
  if (/\brpe\s*:?\s*\d+\s*[-–]\s*\d+\s*\/\s*10/i.test(text)) {
    const m = t.match(/rpe\s*:?\s*(\d+)\s*[-–]\s*(\d+)/);
    if (m) return { type: "percent_range", label: `RPE ${m[1]}-${m[2]}/10` };
  }
  if (/\bzone\s+\d/i.test(text)) {
    const m = t.match(/zone\s+(\d)(?:\s*[-–]\s*(?:low\s+)?zone\s+(\d))?/);
    if (m) return { type: "aerobic", label: `Zone ${m[1]}-${m[2] || m[1]}` };
  }
  if (/\bdesc(?:end)?\b/i.test(text)) return { type: "descend", label: "descend" };
  if (/\bprogressive\b/i.test(text)) return { type: "build", label: "progressive" };
  if (/\bbuild(?:ing)?\b/i.test(text)) return { type: "build", label: "build" };
  if (/\bneg(?:ative)?\s*split\b/i.test(text)) return { type: "negative_split", label: "negative split" };
  // V0.52 (2026-09-08) Jodie audit: `strong` was short-circuiting to
  // `build` via the regex alternation order (it doesn't match the
  // build regex, but the catch-all below then hit `build` from
  // `parseIntensity` callers passing fragment text). Explicit
  // `strong` mapping to aerobic now matches the Tier-2 DEFAULT_RPE
  // band. The `strong` label is preserved verbatim (the coach's word),
  // not collapsed to `aerobic`.
  if (/\bstrong\b/i.test(text)) return { type: "aerobic", label: "strong" };
  if (/\b(?:sprint|all[\s-]?out|max(?:\s+effort)?|blast|atp|fast|maximal|breakout)\b/i.test(text)) return { type: "sprint", label: "ATP" };
  if (/\b(?:race\s+pace|race\s+rhythm|r\.?p\.?|@?\s*\d+\s*(?:m|mtr)?\s*pace)\b/i.test(text)) return { type: "race_pace", label: "race pace" };
  if (/\b(?:threshold|css|t[\s-]?pace)\b/i.test(text)) return { type: "threshold", label: "threshold" };
  // V0.52: `mod` (Jodie's abbreviation for `moderate`) maps to aerobic,
  // matching the Tier-2 DEFAULT_RPE band. The `mod` label is preserved
  // — when the coach expands to `moderate` later, the surface form
  // changes and the engine resolves the same way.
  if (/\b(?:easy|recovery|warm[\s-]?up|ez|relaxed)\b/i.test(text)) return { type: "easy", label: "easy" };
  if (/\b(?:moderate|mod)\b/i.test(text)) return { type: "aerobic", label: "aerobic" };
  if (/\b(?:aerobic|steady|cruise|smooth)\b/i.test(text)) {
    const m = t.match(/\b(aerobic|steady|cruise|moderate|smooth)\b/);
    return { type: "aerobic", label: m ? m[1] : "aerobic" };
  }
  return null;
}

// V0.41 (2026-08-18): the set-level zone term. Mirrors
// index.ts `parseZoneTerm` so the 4-place sync holds — a set with
// exactly one of the four zone words (easy/steady/hard/sprint,
// standalone, word-boundary) carries that zone term; a set with none
// OR with multiple distinct zone words (e.g. a composite "fast/easy"
// fragment set) gets null (the fragments carry per-segment intensity).
// The 3MT marker never yields a zone term.
function parseZoneTerm(raw: string): ZoneTerm | null {
  if (THREE_MT_RE.test(raw)) return null;
  const matches = [...raw.matchAll(/\b(easy|steady|hard|sprint)\b/gi)];
  const terms = new Set(matches.map((match) => match[1].toLowerCase() as ZoneTerm));
  return terms.size === 1 ? [...terms][0] : null;
}

// V0.47 (2026-08-22): when the LLM emits an intensity whose label matches
// a coach_vocabulary row, replace the label with the coach's RPE band.
// The LLM is told to do this in rule 7 of the SYSTEM_PROMPT, but
// json_object mode is non-strict — empirically the LLM sometimes emits
// the surface form anyway. Apply the override defensively here so the
// iOS preview shows the coach's intended band even when the model forgets.
// Returns a map keyed by the canonical term label so we don't re-scan the
// regex list per fragment.
function buildCoachVocabLookup(
  vocabulary: ReadonlyArray<CoachVocabularyEntry>,
): Map<string, { type: string; label: string }> {
  const map = new Map<string, { type: string; label: string }>();
  for (const v of vocabulary) {
    const term = v.user_term.toLowerCase().trim();
    if (term.length === 0) continue;
    // The engine's parseIntensity maps these surface forms to internal
    // type buckets. We mirror that mapping so the override preserves
    // the type key (which iOS / the preview switch on).
    const type = surfaceToIntensityType(term);
    map.set(term, { type, label: `RPE ${v.rpe_low}-${v.rpe_high}` });
  }
  return map;
}

// Map a coach_vocabulary surface form → its engine-side intensity type.
// Mirrors _llm.ts parseIntensity + the V0.47/V0.52 Tier-1/Tier-2 lists.
// Only the cases the LLM is likely to emit land here; unknown terms fall
// through to "easy" as a benign default (the RPE band is what iOS shows).
//
// V0.52 (2026-09-08): expanded to cover the Tier-2 words the Jodie audit
// moved to DEFAULT_RPE_BY_TERM. `mod` → aerobic (shorthand for moderate);
// `strong` → aerobic (the "strong aerobic" 2-word compound); `all-out` /
// `fast` / `max` → sprint (industry-standard for these surface forms).
function surfaceToIntensityType(term: string): string {
  // Exact matches from _llm.ts parseIntensity.
  const lower = term.toLowerCase();
  if (lower === "descend" || lower === "desc") return "descend";
  if (lower === "build" || lower === "building") return "build";
  if (lower === "progressive") return "build";  // V0.52: progressive is a progression shape, type=build
  if (lower === "negative split") return "negative_split";
  if (/^(sprint|all-out|max|atp|fast|maximal|breakout|blast)$/.test(lower)) return "sprint";
  if (/^(race pace|race rhythm|r\.p\.)$/.test(lower)) return "race_pace";
  if (/^(threshold|css|t-pace)$/.test(lower)) return "threshold";
  if (/^(easy|recovery|warm-?up|ez|relaxed)$/.test(lower)) return "easy";
  if (/^(aerobic|steady|cruise|moderate|smooth|mod|strong)$/.test(lower)) return "aerobic";
  if (/^(hard|tough)$/.test(lower)) return "aerobic"; // spec §3 row 5/6 — pre-canonicalization
  return "easy";
}

// V0.47 (2026-08-22): rewrite a fragment's intensity when its label
// matches a coach_vocabulary row. Used by cleanFragmentIntensity so the
// validator output reflects the coach's RPE band, not the LLM's
// surface-form echo.
function applyCoachVocabOverride(
  intensity: { type: string; label: string } | null,
  lookup: Map<string, { type: string; label: string }>,
): { type: string; label: string } | null {
  if (!intensity) return null;
  const key = intensity.label.toLowerCase().trim();
  const hit = lookup.get(key);
  if (!hit) return intensity;
  return { type: hit.type, label: hit.label };
}

function cleanFragmentIntensity(
  intensity: { type: string; label: string } | null,
  segText: string,
  lookup: Map<string, { type: string; label: string }> = new Map(),
): { type: string; label: string } | null {
  if (intensity) {
    // FIX (2026-08-19): "75 @ 100 pace DIVE" — the LLM emits the
    // pace-target as the fragment's intensity label ("@ 100 pace",
    // "100 pace dive", "100m pace"). That's a target, not an
    // intensity word. Map it to race_pace with a tidy label so
    // pairing keys on the effort tier and the preview doesn't show
    // the raw target. The \b allows trailing start/gear words — the
    // start type is carried separately (start_type), so the label
    // doesn't need them. (LLM labels are non-deterministic: verified
    // "100 pace" AND "100 pace dive" from the same input.)
    const paceMatch = intensity.label.match(/^@?\s*(\d+)\s*(?:m|mtr)?\s*pace\b/i);
    if (paceMatch) {
      return { type: "race_pace", label: `${paceMatch[1]} pace` };
    }
    // V0.47 (2026-08-22): coach_vocabulary override — when the LLM
    // emits a surface form that the coach has mapped, rewrite to the
    // coach's RPE band. Runs after the pace-target fix above so a
    // pace-target never accidentally swallows a coach mapping.
    const overridden = applyCoachVocabOverride(intensity, lookup);
    if (overridden !== intensity) return overridden;
    return intensity;
  }
  return parseIntensity(segText);
}

function validateLLMOutput(
  llmOutput: LLMOutput,
  coachVocabulary: ReadonlyArray<CoachVocabularyEntry> = [],
): ValidatedSection[] {
  // V0.47 (2026-08-22): build the lookup once per call so per-fragment
  // override is O(1) instead of an N×M scan.
  const vocabLookup = buildCoachVocabLookup(coachVocabulary);
  return llmOutput.sections.map((section) => ({
    title: section.title,
    repGroups: section.repGroups.map((rg): ValidatedRepGroup => {
      const derivationText = [rg.note, rg.sourceLine, rg.stroke].filter(Boolean).join(" ");
      return {
        reps: rg.reps ?? 1,
        distance: rg.distance ?? 0,
        stroke: canonicalizeStroke(rg.stroke),
        interval: normalizeInterval(rg.interval),
        intensity_type: null,
        intensity_label: null,
        // V0.41 (2026-08-18): zone_term rides on the repGroup. Prefer
        // the LLM's explicit field; fall back to the regex derivation
        // over the note/source text so the 4-place sync holds even when
        // the model omits the field. Null when the set has no single
        // governing zone word.
        zone_term: rg.zone_term ?? parseZoneTerm(derivationText),
        gear: extractGear(derivationText),
        dive: detectDive(derivationText),
        suit: detectSuit(derivationText),
        note: rg.note,
        // ponytail (2026-08-11): fragments carry per-segment intensity.
        // If the LLM left any null, derive it from the segment's own text
        // (stroke/instruction) as a fallback — pairing keys on this.
        // V0.37 (2026-08-13): same fallback for per-fragment gear + start_type —
        // the pairing cost tiers key on (distance, stroke, gear, intensity),
        // so each fragment carries its OWN context, not the parent's.
        // V0.47 (2026-08-22): cleanFragmentIntensity consults the
        // coach_vocabulary lookup so a mapped term (e.g. "easy" → RPE 6-7)
        // shows the coach's band, not the LLM's surface-form echo.
        fragments: (rg.fragments || []).map((f) => {
          const segText = [f.stroke, f.instruction].filter(Boolean).join(" ");
          return {
            ...f,
            id: f.id ?? null,
            // FIX (2026-08-19): cleanFragmentIntensity — the LLM emits
            // pace-targets ("@ 100 pace") as fragment intensities; map
            // them to race_pace so pairing keys on the effort tier.
            intensity: cleanFragmentIntensity(f.intensity ?? null, segText, vocabLookup),
            gear: f.gear ?? extractGear(segText),
            start_type: f.start_type ?? deriveStartType(segText)
          };
        }),
        sourceLine: rg.sourceLine
      };
    })
  }));
}

function addIntensity(
  sections: ValidatedSection[],
  coachVocabulary: ReadonlyArray<CoachVocabularyEntry> = [],
): ValidatedSection[] {
  // V0.47 (2026-08-22): same coach-vocab lookup for the parent repGroup
  // intensity path (no fragments → derive intensity at the rg level).
  const vocabLookup = buildCoachVocabLookup(coachVocabulary);
  for (const section of sections) {
    for (const rg of section.repGroups) {
      // ponytail: skip intensity derivation when the repGroup has fragments —
      // the fragments carry per-segment intensity as `stroke` ("fast", "easy").
      // Deriving at the parent level overwrites the meaningful per-segment signal.
      if (rg.fragments && rg.fragments.length > 0) continue;
      const text = [rg.note, rg.sourceLine].filter(Boolean).join(" ");
      let intensity = parseIntensity(text);
      if (intensity) {
        // V0.47 (2026-08-22): apply the coach's RPE band when the
        // surface form matches a coach_vocabulary row. Mirrors
        // cleanFragmentIntensity's behaviour so parent-level sets
        // get the same override treatment as fragment-level ones.
        const overridden = applyCoachVocabOverride(intensity, vocabLookup);
        if (overridden) intensity = overridden;
        rg.intensity_type = intensity.type;
        rg.intensity_label = intensity.label;
      }
    }
  }
  return sections;
}

// ─── Public API ────────────────────────────────────────────────────────────

export async function parseWithLLM(
  workoutText: string,
  coachVocabulary: ReadonlyArray<CoachVocabularyEntry> = [],
): Promise<Workout> {
  const llmOutput = await callMiniMax(workoutText, coachVocabulary);
  const validated = addIntensity(validateLLMOutput(llmOutput, coachVocabulary), coachVocabulary);
  return {
    title: null,
    sections: validated.map((s) => ({
      title: s.title,
      namedSets: [{ label: null, note: null, repGroups: s.repGroups }]
    })),
    // V0.47 (2026-08-22): pass the LLM-reported unmapped terms straight
    // through. index.ts defensively re-derives Tier-1 hits that the LLM
    // missed (it sometimes returns unmapped_terms: [] for inputs that
    // contain an unmapped Tier-1 word).
    unmapped_terms: Array.isArray(llmOutput.unmapped_terms)
      ? llmOutput.unmapped_terms.map((t) => String(t).toLowerCase()).filter((t) => t.length > 0)
      : [],
  };
}
