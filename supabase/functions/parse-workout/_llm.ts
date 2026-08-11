/**
 * _llm.ts — LLM-primary parser, Deno-compatible module for the
 * Supabase Edge Function runtime.
 *
 * Architecture: coach text → Groq LLM (structured extraction) →
 * regex validator (intensity/gear/dive/suit/stroke canonicalization)
 * → workout tree in the same shape parseWorkoutV2() returns.
 *
 * Used by index.ts as the primary parser with parseWorkoutV2() as
 * the fallback when Groq is down, rate-limited, or returns junk.
 *
 * Env required: GROQ_API_KEY (set via `supabase secrets set`).
 * Env optional: GROQ_MODEL (default: openai/gpt-oss-20b).
 */

const GROQ_URL = "https://api.groq.com/openai/v1/chat/completions";
const GROQ_MODEL = Deno.env.get("GROQ_MODEL") || "openai/gpt-oss-20b";

// ─── Types (output shape matches parseWorkoutV2's Workout) ─────────────────

interface LLMFragment {
  distance: number | null;
  stroke: string | null;
  instruction: string | null;
  // ponytail (2026-08-11): fragment intensity is the pairing engine's
  // key (distance + intensity + start type). The old schema stuffed
  // "fast"/"easy" into stroke and never carried intensity at all —
  // pairing saw "75m @ unknown". Now explicit: {type, label}.
  intensity: { type: string; label: string } | null;
}

interface LLMRepGroup {
  reps: number | null;
  distance: number | null;
  stroke: string | null;
  interval: string | null;
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

// ─── JSON Schema for Groq structured output (strict mode) ─────────────────

const WORKOUT_SCHEMA = {
  type: "object",
  properties: {
    sections: {
      type: "array",
      items: {
        type: "object",
        properties: {
          title: { type: ["string", "null"], description: "Section header like 'Warm up', 'Main Set', or null if untitled" },
          repGroups: {
            type: "array",
            items: {
              type: "object",
              properties: {
                reps: { type: ["integer", "null"], description: "Number of repetitions. 8 for '8 x 100'. 1 for single swims." },
                distance: { type: ["integer", "null"], description: "Distance in meters per rep. 100 for '8 x 100'." },
                stroke: { type: ["string", "null"], description: "Primary stroke as written: 'free', 'back', 'breast', 'fly', 'IM', 'kick', 'drill', 'choice', 'pull'. First mentioned if multiple. Null if unspecified." },
                interval: { type: ["string", "null"], description: "Interval exactly as written: '1.50', '1:30', ':40', '@ 30'. Include the @ if present." },
                note: { type: ["string", "null"], description: "Instructions, descriptions, or notes attached to this set. Include technique focus, breathing patterns, rep-range instructions." },
                fragments: {
                  type: "array",
                  description: "Sub-segments for composite sets. '4 x (75 fast / 25 easy)' → fragments [{distance:75, stroke:null, intensity:{type:'sprint',label:'fast'}}, {distance:25, stroke:null, intensity:{type:'easy',label:'easy'}}]. 'Each 100: 25 Drill/25 Build/25 Race Skill/25 Easy' → 4 fragments. Empty array for simple sets.",
                  items: {
                    type: "object",
                    properties: {
                      distance: { type: ["integer", "null"], description: "Sub-segment distance in meters" },
                      stroke: { type: ["string", "null"], description: "Sub-segment stroke if stated ('free', 'back', 'drill', 'kick'). NULL for pure intensity segments like 'fast' or 'easy' — those go in intensity, not stroke." },
                      instruction: { type: ["string", "null"], description: "Specific instruction for this sub-segment" },
                      intensity: {
                        type: ["object", "null"],
                        description: "Intensity of this sub-segment: {type, label}. type ∈ easy|aerobic|threshold|race_pace|pace_target|sprint|descend|build|negative_split|percent_range. label is the coach's exact word ('fast', 'easy', 'maximal finish', 'race rhythm', '75%'). NULL when the segment has no intensity word.",
                        properties: {
                          type: { type: "string", description: "One of: easy, aerobic, threshold, race_pace, pace_target, sprint, descend, build, negative_split, percent_range" },
                          label: { type: "string", description: "The coach's exact intensity word or phrase, lowercased" }
                        },
                        required: ["type", "label"],
                        additionalProperties: false
                      }
                    },
                    required: ["distance", "stroke", "instruction", "intensity"],
                    additionalProperties: false
                  }
                },
                sourceLine: { type: "string", description: "The source text line(s) this repGroup was extracted from." }
              },
              required: ["reps", "distance", "stroke", "interval", "note", "fragments", "sourceLine"],
              additionalProperties: false
            }
          }
        },
        required: ["title", "repGroups"],
        additionalProperties: false
      }
    }
  },
  required: ["sections"],
  additionalProperties: false
} as const;

// ─── Few-shot examples (5, ordered hardest-first) ─────────────────────────

const FEW_SHOT_EXAMPLES = [
  {
    input: `400 kick for body/head position 100 free 100 back - floppy feet

3 x 300 FBBF (free,back,breast, free) @ 4:30
3 x 300 free @ 4.30 as 1.fists/swim, 2. catch up/swim 3. swim
3 x 200 FBF @ 2:50 by
3 x 200 free @ 2:50 same as above`,
    output: {
      sections: [{
        title: null,
        repGroups: [
          { reps: 1, distance: 400, stroke: "kick", interval: null, note: "for body/head position - floppy feet", fragments: [], sourceLine: "400 kick for body/head position" },
          { reps: 1, distance: 100, stroke: "free", interval: null, note: null, fragments: [], sourceLine: "100 free" },
          { reps: 1, distance: 100, stroke: "back", interval: null, note: null, fragments: [], sourceLine: "100 back" },
          { reps: 3, distance: 300, stroke: "free", interval: "4:30", note: "FBBF pattern (free, back, breast, free)", fragments: [], sourceLine: "3 x 300 FBBF (free,back,breast, free) @ 4:30" },
          { reps: 3, distance: 300, stroke: "free", interval: "4:30", note: "as 1.fists/swim, 2. catch up/swim, 3. swim", fragments: [], sourceLine: "3 x 300 free @ 4.30 as 1.fists/swim, 2. catch up/swim 3. swim" },
          { reps: 3, distance: 200, stroke: "free", interval: "2:50", note: "FBF pattern (free, back, free)", fragments: [], sourceLine: "3 x 200 FBF @ 2:50 by" },
          { reps: 3, distance: 200, stroke: "free", interval: "2:50", note: "same as above (FBF pattern inherited)", fragments: [], sourceLine: "3 x 200 free @ 2:50 same as above" }
        ]
      }]
    }
  },
  {
    input: `3 x 100 free @ 1:30 descend 1-4
4 x 50 kick with fins @ 1:10`,
    output: {
      sections: [{
        title: null,
        repGroups: [
          { reps: 3, distance: 100, stroke: "free", interval: "1:30", note: "descend 1-4", fragments: [], sourceLine: "3 x 100 free @ 1:30 descend 1-4" },
          { reps: 4, distance: 50, stroke: "kick", interval: "1:10", note: null, fragments: [], sourceLine: "4 x 50 kick with fins @ 1:10" }
        ]
      }]
    }
  },
  {
    input: `8 x 100 @ 2:00
Each 100:
25 Drill/25 Build/25 Race Skill/25 Easy - race skill = breakout timing, breathing pattern`,
    output: {
      sections: [{
        title: null,
        repGroups: [{
          reps: 8, distance: 100, stroke: null, interval: "2:00",
          note: "race skill = breakout timing, breathing pattern",
          fragments: [
            { distance: 25, stroke: "drill", instruction: null, intensity: null },
            { distance: 25, stroke: "build", instruction: null, intensity: { type: "build", label: "build" } },
            { distance: 25, stroke: "race skill", instruction: null, intensity: null },
            { distance: 25, stroke: "easy", instruction: null, intensity: { type: "easy", label: "easy" } }
          ],
          sourceLine: "8 x 100 @ 2:00 / Each 100: 25 Drill/25 Build/25 Race Skill/25 Easy"
        }]
      }]
    }
  },
  {
    input: `Warm up
8 x 100 :20
1. 50 free breathe 3 / 50 free catch up drill
2. 50 free breathe 5 / 50 Breast 3 kick + 1 pull`,
    output: {
      sections: [{
        title: "Warm up",
        repGroups: [{
          reps: 8, distance: 100, stroke: null, interval: "0:20",
          note: "Each 100 is two 50s: (1) 50 free breathe 3 / 50 free catch up drill; (2) 50 free breathe 5 / 50 Breast 3 kick + 1 pull",
          fragments: [],
          sourceLine: "8 x 100 :20 / numbered sub-items 1-4 describe the content of each 100"
        }]
      }]
    }
  },
  {
    input: `4 x 25 uw kick to 10m @30
3 x 25 " kick to 12.5m
2 x uw " kick to 15m`,
    output: {
      sections: [{
        title: null,
        repGroups: [
          { reps: 4, distance: 25, stroke: "kick", interval: "0:30", note: "uw kick to 10m", fragments: [], sourceLine: "4 x 25 uw kick to 10m @30" },
          { reps: 3, distance: 25, stroke: "kick", interval: null, note: 'uw kick to 12.5m (ditto " = same as above)', fragments: [], sourceLine: '3 x 25 " kick to 12.5m' },
          { reps: 2, distance: 25, stroke: "kick", interval: null, note: "uw kick to 15m (inherits 25m, ditto stroke)", fragments: [], sourceLine: '2 x uw " kick to 15m' }
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
            { distance: 75, stroke: null, instruction: null, intensity: { type: "sprint", label: "fast" } },
            { distance: 25, stroke: null, instruction: null, intensity: { type: "easy", label: "easy" } }
          ],
          sourceLine: "4 x (75 fast / 25 easy)"
        }]
      }]
    }
  }
];

// ─── System prompt (12 rules) ──────────────────────────────────────────────

const SYSTEM_PROMPT = `You are an expert swimming workout parser. Convert raw coach-written workout text into structured JSON.

## Critical rules

1. **Hierarchy**: Numbered sub-items (1. 2. 3.) that follow a set like "8 x 100" DESCRIBE the content of each rep — they are NOT standalone sets. Attach as notes or fragments to the parent set.

2. **Time-based sets**: "Free - 8:00 kick on side" means freestyle, kicking on side, for 8 minutes. Valid set with distance=null. The "8:00" is a DURATION not an interval.

3. **Per-rep-range instructions**: "1-2 = 2 uw kicks + 2 fast arms" after a set like "10 x 25 @ 30" describes specific reps within that set. Attach to the parent set's note.

4. **Implicit inheritance (ditto)**: A quote mark (") means "same as above." "3 x 25 \\" kick to 12.5m" inherits the stroke from above. "2 x uw \\" kick to 15m" inherits both distance (25) and stroke. Resolve these — do not pass the literal quote through.

5. **Round multipliers**: "twice through" or "2 x through" means repeat the preceding block. Do NOT create a set from it.

6. **Composite sets / fragments**:
   - Inline parens: "4 x (75 fast / 25 easy)" → 1 repGroup with reps=4, distance=100, fragments=[{distance:75, stroke:null, intensity:{type:"sprint",label:"fast"}}, {distance:25, stroke:null, intensity:{type:"easy",label:"easy"}}]
   - "Each N: 25 Drill/25 Build/..." → fragments on the parent repGroup
   - Sub-segments sum to the parent's distance.
   - **Fragment intensity is CRITICAL**: each fragment carries its own intensity {type,label}. Map the coach's word to a type: fast/sprint/all-out/max → sprint; easy/recovery/warm-up → easy; moderate/steady/cruise/aerobic → aerobic; tempo/threshold → threshold; race pace/race rhythm/r.p. → race_pace; descend → descend; build → build. label is the coach's exact word lowercased ("fast", "maximal finish", "race rhythm"). Pure intensity words ("fast", "easy") go in intensity — NOT in stroke. Stroke stays null unless a real stroke is stated.

7. **Strokes**: free, back, breast, fly, IM, kick, drill, choice, pull. "uw" = underwater kick. "scull" = drill. If multiple (e.g. "fly back or free"), use the first mentioned.

8. **Intervals**: Pass through exactly as written ("1.50", "1:30", ":40", "@ 30"). The validator normalizes.

9. **Single swims**: "400 free" with no "x" is reps=1.

10. **Section headers**: "Warm up", "Main Set", "Cool down" start new sections. Everything before the first header goes in a section with title=null.

11. **Pattern shorthand (FBBF, FBF)**: F=Free, B=Back, K=Breast, R=Fly, I=IM, M=Medley. Set stroke to the FIRST letter (F=Free), put the pattern in the note. "same as above" / "same" inherits the pattern.

12. **Multi-swim lines**: A single line may contain multiple separate swims, like "400 kick for body/head position 100 free 100 back". These are THREE separate repGroups: (1) 400 kick, (2) 100 free, (3) 100 back. Split on distance boundaries.

## What NOT to create sets from
- Lines that are purely instructions/notes for a set above (rep-range breakdowns, "Each N:" descriptions)
- "twice through" / round multiplier lines
- Lines that are choices/options ("Choose from:", "Drill choices")`;

// ─── Build prompt messages ────────────────────────────────────────────────

function buildMessages(workoutText: string) {
  const messages: Array<{ role: string; content: string }> = [
    { role: "system", content: SYSTEM_PROMPT }
  ];
  for (const ex of FEW_SHOT_EXAMPLES) {
    messages.push({ role: "user", content: `Parse this swimming workout into the JSON schema:\n\n${ex.input}` });
    messages.push({ role: "assistant", content: JSON.stringify(ex.output) });
  }
  messages.push({ role: "user", content: `Parse this swimming workout into the JSON schema:\n\n${workoutText}` });
  return messages;
}

// ─── Call Groq ─────────────────────────────────────────────────────────────

async function callGroq(workoutText: string): Promise<LLMOutput> {
  const apiKey = Deno.env.get("GROQ_API_KEY");
  if (!apiKey) throw new Error("GROQ_API_KEY not set");

  const messages = buildMessages(workoutText);
  const body = {
    model: GROQ_MODEL,
    messages,
    temperature: 0.1,
    max_tokens: 4096,
    response_format: {
      type: "json_schema",
      json_schema: { name: "workout", strict: true, schema: WORKOUT_SCHEMA }
    }
  };

  const resp = await fetch(GROQ_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${apiKey}`
    },
    body: JSON.stringify(body)
  });

  if (!resp.ok) {
    const errText = await resp.text();
    throw new Error(`Groq API error ${resp.status}: ${errText}`);
  }

  const data = await resp.json() as {
    choices: Array<{ message: { content: string } }>;
    usage: { prompt_tokens: number; completion_tokens: number; total_tokens: number };
  };

  return JSON.parse(data.choices[0].message.content) as LLMOutput;
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

const DIVE_RE = /\b(?:from\s+a\s+dive|dive\s+start|off\s+the\s+blocks?|block\s+start|racing\s+dive|dive\s+entry|dive|from\s+a\s+push|push\s+start)\b/i;
const SUIT_RE = /\b(?:in\s+a\s+suit|tech\s*suit|raced?\s+in\s+(?:a\s+)?suit|suit\s+on|full[\s-]?body|jaked|arena|speedo\s+lzr)\b/i;

function detectDive(text: string): boolean { return DIVE_RE.test(text); }
function detectSuit(text: string): boolean { return SUIT_RE.test(text); }

function parseIntensity(text: string): { type: string; label: string } | null {
  const t = text.toLowerCase();
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
  if (/\b(?:sprint|all[\s-]?out|max(?:\s+effort)?|blast|atp|fast|maximal)\b/i.test(text)) return { type: "sprint", label: "ATP" };
  if (/\b(?:race\s+pace|r\.?p\.?)\b/i.test(text)) return { type: "race_pace", label: "race pace" };
  if (/\b(?:threshold|css|t[\s-]?pace)\b/i.test(text)) return { type: "threshold", label: "threshold" };
  if (/\b(?:easy|recovery|warm[\s-]?up|ez)\b/i.test(text)) return { type: "easy", label: "easy" };
  if (/\b(?:aerobic|steady|cruise|moderate)\b/i.test(text)) {
    const m = t.match(/\b(aerobic|steady|cruise|moderate)\b/);
    return { type: "aerobic", label: m ? m[1] : "aerobic" };
  }
  return null;
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
        gear: extractGear(derivationText),
        dive: detectDive(derivationText),
        suit: detectSuit(derivationText),
        note: rg.note,
        // ponytail (2026-08-11): fragments carry per-segment intensity.
        // If the LLM left any null, derive it from the segment's own text
        // (stroke/instruction) as a fallback — pairing keys on this.
        fragments: (rg.fragments || []).map((f) => ({
          ...f,
          intensity: f.intensity ?? parseIntensity([f.stroke, f.instruction].filter(Boolean).join(" "))
        })),
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
  const llmOutput = await callGroq(workoutText);
  const validated = addIntensity(validateLLMOutput(llmOutput));
  return {
    title: null,
    sections: validated.map((s) => ({
      title: s.title,
      namedSets: [{ label: null, note: null, repGroups: s.repGroups }]
    }))
  };
}
