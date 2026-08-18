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
   - "Each N: 25 Drill/25 Build/..." → fragments on the parent repGroup
   - "as X + Y" / "X into Y" / "X to Y" within a set → fragments for each segment
   - "stroke1/stroke2 by 25m" → fragments alternating strokes
   - Sub-segments sum to the parent's distance.
   - **Fragment intensity is CRITICAL**: each fragment carries its own intensity {type,label}. Map the coach's word: fast/sprint/all-out/max → sprint; easy/recovery/warm-up → easy; moderate/steady/cruise/smooth/aerobic → aerobic; tempo/threshold → threshold; race pace/race rhythm/r.p. → race_pace; descend → descend; build/acceleration → build. label is the coach's exact word lowercased ("fast", "maximal finish", "race rhythm"). Pure intensity words ("fast", "easy") go in intensity — NOT in stroke. Stroke stays null unless a real stroke is stated.
   - **Per-fragment gear + start_type**: each fragment carries its OWN gear: string[] | null and start_type: string | null derived from that fragment's segment text, NOT the parent set. gear values: fins, pull_paddle, finger_paddle, paddles, pull_buoy, kickboard, snorkel, parachute, resistance_band, ankle_band, power_tower, weight_belt, tennis_balls, drag_suit, stretchcordz. start_type: 'dive' | 'push' | 'wall' (from "from a dive"/"off the blocks" → dive; "push start"/"start or push" → push; "off the wall"/"push off the wall" → wall). Leave gear:null / start_type:null when the segment states neither.
7. **Strokes**: free, back, breast, fly, IM, kick, drill, choice, pull. "uw" = underwater kick. "scull" = drill. "drill/swim", "kick/swim", "scull/swim" = combo sets — stroke is the first (drill/kick/scull), the combo goes in the note. If multiple strokes, use the first mentioned.
8. **Intervals**: Pass through exactly as written ("1.50", "1:30", ":40", "@ 30"). The validator normalizes.
9. **Single swims**: "400 free" with no "x" is reps=1.
10. **Section headers**: "Warm up", "Main Set", "Cool down" start new sections. Keep the full header as the title, including any em-dash distance ("Main set — 1,400m"). Append "(N rounds)" when the section has a round block.
11. **Pattern shorthand (FBBF, FBF)**: F=Free, B=Back, K=Breast, R=Fly, I=IM, M=Medley. Set stroke to the FIRST letter, put the pattern in the note. "same as above" / "same" inherits the pattern.
12. **Multi-swim lines**: A single line may contain multiple separate swims, like "400 kick for body/head position 100 free 100 back". These are THREE separate repGroups: (1) 400 kick, (2) 100 free, (3) 100 back. Split on distance boundaries.
13. **Start types**: "start or push", "push start", "from a dive", "off the blocks" describe the start. Keep in the note — the validator detects dive/push.
14. **3-minute all-out test (3MT)**: when a set line contains "3MT", "3-MT", "3 MT", "3-min all-out", "3 min all out", "3-minute all-out", "3min all out", "3 min test", "3-minute test", or "3min test", emit a single repGroup with intensity { type: "3mt", label: "3-minute all-out" }, reps=1, distance=25 (the split distance the coach taps LAP at), and no interval — the 3:00 swim is continuous, not interval-based. Stroke parses from any remaining text (e.g. "3MT free" → Free); default is Free. The "3MT" marker wins over the generic "all-out" → sprint mapping. "all-out" alone is NOT a 3MT marker.

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
  ]
}

- fragments: empty array [] for simple sets; one entry per sub-segment for composite sets.
- intensity: {type, label} or null. type ∈ easy|aerobic|threshold|race_pace|pace_target|sprint|descend|build|negative_split|percent_range|3mt. label = the coach's exact word lowercased ("3-minute all-out" for 3MT).
- zone_term: "easy" | "steady" | "hard" | "sprint" | null. The set's governing zone word when the set text states exactly one of the four zone words (standalone intensity word); null when there is no zone word OR more than one distinct zone word. The zone_term is SEPARATE from intensity — "Steady" yields zone_term "steady" AND intensity type "aerobic". The 3MT marker never yields a zone_term.
- stroke: null when no stroke is stated. Pure intensity words ("fast", "easy") go in intensity, NOT stroke.
- reps: 1 for single swims. distance: null for time-based sets ("Free - 8:00 kick").
- Every repGroup MUST include all keys: reps, distance, stroke, interval, note, fragments, sourceLine.

## What NOT to create sets from
- Lines that are purely instructions/notes for a set above (rep-range breakdowns, "Each N:" descriptions)
- "twice through" / "N rounds:" / round multiplier lines
- "Round emphasis" lists and other section-level notes
- Lines that are choices/options ("Choose from:", "Drill choices")`;

// ─── Build prompt messages ────────────────────────────────────────────────

function buildMessages(workoutText: string) {
  const messages: Array<{ role: string; content: string }> = [
    { role: "system", content: SYSTEM_PROMPT }
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

async function callMiniMax(workoutText: string): Promise<LLMOutput> {
  const apiKey = Deno.env.get("MINIMAX_API_KEY");
  if (!apiKey) throw new Error("MINIMAX_API_KEY not set");

  const messages = buildMessages(workoutText);
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
  if (/\bbuild\b/i.test(text)) return { type: "build", label: "build" };
  if (/\bneg(?:ative)?\s*split\b/i.test(text)) return { type: "negative_split", label: "negative split" };
  if (/\b(?:sprint|all[\s-]?out|max(?:\s+effort)?|blast|atp|fast|maximal|breakout)\b/i.test(text)) return { type: "sprint", label: "ATP" };
  if (/\b(?:race\s+pace|race\s+rhythm|r\.?p\.?)\b/i.test(text)) return { type: "race_pace", label: "race pace" };
  if (/\b(?:threshold|css|t[\s-]?pace)\b/i.test(text)) return { type: "threshold", label: "threshold" };
  if (/\b(?:easy|recovery|warm[\s-]?up|ez|relaxed)\b/i.test(text)) return { type: "easy", label: "easy" };
  if (/\b(?:aerobic|steady|cruise|moderate|smooth)\b/i.test(text)) {
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

function validateLLMOutput(llmOutput: LLMOutput): ValidatedSection[] {
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
        fragments: (rg.fragments || []).map((f) => {
          const segText = [f.stroke, f.instruction].filter(Boolean).join(" ");
          return {
            ...f,
            id: f.id ?? null,
            intensity: f.intensity ?? parseIntensity(segText),
            gear: f.gear ?? extractGear(segText),
            start_type: f.start_type ?? deriveStartType(segText)
          };
        }),
        sourceLine: rg.sourceLine
      };
    })
  }));
}

function addIntensity(sections: ValidatedSection[]): ValidatedSection[] {
  for (const section of sections) {
    for (const rg of section.repGroups) {
      // ponytail: skip intensity derivation when the repGroup has fragments —
      // the fragments carry per-segment intensity as `stroke` ("fast", "easy").
      // Deriving at the parent level overwrites the meaningful per-segment signal.
      if (rg.fragments && rg.fragments.length > 0) continue;
      const text = [rg.note, rg.sourceLine].filter(Boolean).join(" ");
      const intensity = parseIntensity(text);
      if (intensity) {
        rg.intensity_type = intensity.type;
        rg.intensity_label = intensity.label;
      }
    }
  }
  return sections;
}

// ─── Public API ────────────────────────────────────────────────────────────

export async function parseWithLLM(workoutText: string): Promise<Workout> {
  const llmOutput = await callMiniMax(workoutText);
  const validated = addIntensity(validateLLMOutput(llmOutput));
  return {
    title: null,
    sections: validated.map((s) => ({
      title: s.title,
      namedSets: [{ label: null, note: null, repGroups: s.repGroups }]
    }))
  };
}
