/**
 * parse-workout Edge Function
 * Input: { workoutText: string }
 * Output: parsed v2 workout tree (Workout → Section → NamedSet → RepGroup → Rep)
 *
 * Full port of hydrolyze-mobile/lib/workout-parser-v2.ts (917 LOC)
 * to Deno-compatible TypeScript.
 *
 * Architecture: four composable passes over the raw input text.
 * Pass 1: tokenize into raw lines (preserve blank lines as separators)
 * Pass 2: group lines into Sections (detect section headers)
 * Pass 3: within each Section, extract NamedSet labels and parse RepGroups
 * Pass 4: resolve Rep patterns (drill/swim, odd/even, simple)
 */

// Bench engine — standalone copy of the edge function for testing.
// Inline the constants so there's no import path issue.
const WORD_NUMBERS: Record<string, number> = {
  one: 1, two: 2, three: 3, four: 4, five: 5, six: 6, seven: 7,
  eight: 8, nine: 9, ten: 10, eleven: 11, twelve: 12, thirteen: 13,
  fourteen: 14, fifteen: 15, sixteen: 16, seventeen: 17, eighteen: 18,
  nineteen: 19, twenty: 20,
};
const SWIM_DISTANCES = new Set<number>([
  12, 12.5, 15, 25, 37.5, 50, 62.5, 75, 87.5, 100, 125, 150, 175, 200,
  225, 300, 350, 400, 450, 500, 550, 600, 700, 800, 900, 1000, 1100, 1500, 1650,
  2000, 3000, 4000, 4400, 5000,
]);
// ─── Types ───────────────────────────────────────────────────────────────────

type Stroke =
  | "Free"
  | "Back"
  | "Breast"
  | "Fly"
  | "IM"
  | "Form"
  | "Pull"
  | "Choice";

type IntensityType =
  | "easy"
  | "aerobic"
  | "threshold"
  | "race_pace"
  | "pace_target"
  | "sprint"
  | "descend"
  | "build"
  | "negative_split"
  | "percent_range";

interface ParsedIntensity {
  type: IntensityType;
  label: string;
  paceDistance?: number;
  percentLow?: number;
  percentHigh?: number;
}

type Rep =
  | {
      type: "drill_swim";
      drillMeters: number | null;
      swimMeters: number | null;
      drillStroke: Stroke | null;
      swimStroke: Stroke | null;
      rawText?: string;
    }
  | { type: "odd_even"; odd: string; even: string }
  | {
      type: "simple";
      meters: number;
      stroke: Stroke | null;
      note?: string;
      pacing?: string;
      intensity?: ParsedIntensity;
    };

interface RepGroup {
  reps: number | null;
  distance: number | null;
  stroke: Stroke | null;
  interval: string | null;
  intensity: ParsedIntensity | null;
  pacing: string | null;
  pattern: Rep[];
  patternType:
    | "simple"
    | "drill_swim"
    | "odd_even"
    | "ascending"
    | "descending"
    | null;
  connectors: Array<"and" | "+">;
  note: string | null;
  gear: string[] | null;
  gearOptional: boolean;
  descend: string | null;
  details: string[] | null;
  dive: boolean;
  suit: boolean;
  ambiguousTerm: string | null;
  defaultRpe: { low: number; high: number } | null;
}

interface NamedSet {
  label: string | null;
  note: string | null;
  repGroups: RepGroup[];
}

interface Section {
  title: string | null;
  namedSets: NamedSet[];
}

interface Workout {
  title: string | null;
  sections: Section[];
}

// ─── Constants ─────────────────────────────────────────────────────────────────

const STROKE_PATTERNS: Array<[RegExp, Stroke]> = [
  [/\b(?:freestyle|free|crawl|front\s*crawl|fists?|catch[\s-]?up|swim)\b/i, "Free"],
  [/\b(?:backstroke|back)\b/i, "Back"],
  [/\b(?:breaststroke|breast)\b/i, "Breast"],
  [/\b(?:butterfly|fly|butter)\b/i, "Fly"],
  [/\b(?:i\.?m\.?|individual\s+medley|medley)\b/i, "IM"],
  [/\b(?:form|stroke\s+(?:work|set|drill))\b/i, "Form"],
  [/\b(?:pull)\b/i, "Pull"],
  [/\b(?:kick|kick\s+drill|flutter\s+kick|flutter|dolphin\s+kick)\b/i, "Kick"],
  [/\b(?:drill)\b/i, "Drill"],
  [/\b(?:choice|free[\s-]?choice)\b/i, "Choice"],
  // ponytail (iter 11, 2026-07-28): scull is a drill-like stroke
  [/\b(?:scull)\b/i, "Form"],
];

// ─── Dive / Suit detection ───────────────────────────────────────────────────

const DIVE_PATTERNS: RegExp[] = [
  /\bfrom\s+a\s+dive\b/i,
  /\bdive\s+start\b/i,
  /\boff\s+the\s+blocks?\b/i,
  /\bblock\s+start\b/i,
  /\bracing\s+dive\b/i,
  /\bdive\s+entry\b/i,
  /\bdive\b(?!.*(?:drill|kick|recover|depth))/i,
  // ponytail (iter 11, 2026-07-28): push start variants
  /\bfrom\s+a\s+push\b/i,
  /\bpush\s+start\b/i,
  /\bdive\s+or\s+race[-\s]?specific\s+start\b/i,
];

const SUIT_PATTERNS: RegExp[] = [
  /\bin\s+a\s+suit\b/i,
  /\btech\s*suit\b/i,
  /\braced?\s+in\s+(?:a\s+)?suit\b/i,
  /\bsuit\s+on\b/i,
  /\b(?:full[-\s]?body|jaked|arena|speedo\s+lzr)\b/i,
];

function parseDive(text: string): boolean {
  return DIVE_PATTERNS.some((re) => re.test(text));
}

function parseSuit(text: string): boolean {
  return SUIT_PATTERNS.some((re) => re.test(text));
}

const GEAR_PATTERNS: Array<[RegExp, string]> = [
  [/\bfins\b/i, "fins"],
  [/\bflippers\b/i, "fins"],
  // ponytail (iter 11, 2026-07-28): fix duplicate — 'pull paddle' must
  // match before 'paddles' to avoid double-counting. Use negative
  // lookbehind for 'pull ' to skip 'pull paddle'.
  [/\bpull\s*paddle\b/i, "pull_paddle"],
  [/(?<!pull\s)paddles?\b/i, "paddles"],
  [/\b(?:pull[\s-]?buoy|buoy)\b/i, "pull_buoy"],
  [/\bPB\b/i, "pull_buoy"], // PB = pull buoy in gear context
  [/\bkickboard\b/i, "kickboard"],
  [/\bkick\s*board\b/i, "kickboard"],
  [/\bKBO\b/i, "kickboard"], // KBO = Kick Board Order
  [/\bsnorkel\b/i, "snorkel"],
  [/\bdrum\s*parachute\b/i, "parachute"],
  [/\bparachute\b/i, "parachute"],
  [/\bresistance\s*(?:band|cord|tubing)\b/i, "resistance_band"],
  [/\bbungees?\b/i, "resistance_band"],
  [/\bbands?\b/i, "resistance_band"], // 'Band swings' context
  [/\bpower\s*tower\b/i, "power_tower"],
  [/\bweight\s*belt\b/i, "weight_belt"],
  [/\b(?:tennis|golf)\s*balls?\b/i, "tennis_balls"],
  [/\bankle\s*bands?\b/i, "ankle_band"],
  [/\bfinger\s*paddle\b/i, "finger_paddle"],
  [/\bdrag\s*(?:suit|shorts?)\b/i, "drag_suit"],
  [/\bdrags?\b/i, "drag_suit"], // 'Bungees then drags'
  [/\bstretchcordz\b/i, "stretchcordz"],
];

// ─── Helpers ───────────────────────────────────────────────────────────────────

function normalize(text: string): string {
  let out = text.toLowerCase().trim();
  // Strip commas from numbers: "4,000" -> "4000"
  out = out.replace(/(\d),(?=\d{3}\b)/g, "$1");
  for (const [word, num] of Object.entries(WORD_NUMBERS)) {
    out = out.replace(new RegExp(`\\b${word}\\b`, "g"), String(num));
  }
  out = out.replace(/(\d+)\s+and\s+a\s+half/g, (_m, n) =>
    String(parseFloat(n) + 0.5),
  );
  // ponytail (autoresearch iter 4, 2026-07-15): coaches write
  // intervals as "1.20", "4.30" (dot-separated, ambiguous with English
  // decimal). The colonMatch regex requires a literal ":". Normalize
  // any "<digits>.<two-digits>" pattern to "<digits>:<two-digits>".
  // The \b at the end prevents eating decimal numbers like "1.5".
  //
  // ponytail (iter 11, 2026-07-28): half-distance guard. Coaches write
  // "12.5" as a half-pool distance. The dot→colon conversion turns it
  // into "12:5", killing the distance. Guard: skip conversion when the
  // number (as a decimal) is a known swim distance (12.5, 37.5, 62.5, etc.).
  out = out.replace(/(\d+)\.(\d{2})\b/g, (match, p1, p2) => {
    const asDecimal = parseFloat(match);
    if (SWIM_DISTANCES.has(asDecimal)) return match; // keep as-is (12.5, 37.5, etc.)
    return `${p1}:${p2}`;
  });
  // ponytail (iter 11, 2026-07-28): compact interval conversion. Coaches
  // write "140" meaning "1:40", "230" meaning "2:30". Only convert 3-4
  // digit numbers where the first 1-2 digits are < 60 (minutes) and the
  // last 2 digits are < 60 (seconds). Must be in interval context (after
  // @, on, or at the end of a set line). We do a conservative pass here
  // — the interval parser will validate.
  // CRITICAL: \b before 'on' to prevent matching the end of words like
  // "position" which ends with "on" + space + digits.
  out = out.replace(/(?:@|\bon\s+)(\d)(\d{2})\b/g, (match, prefix, rest) => {
    const mins = parseInt(prefix, 10);
    const secs = parseInt(rest, 10);
    if (mins > 0 && mins < 60 && secs < 60) {
      return match.replace(/(\d)(\d{2})\b/, `$1:$2`);
    }
    return match;
  });
  out = out.replace(/–/g, "-");
  // ponytail (iter 11, 2026-07-28): normalise gear preposition "w/" to "with"
  // so gear patterns like "w/ paddles" get detected.
  out = out.replace(/\bw\/\s*/g, "with ");
  return out;
}

function isKnownDistance(n: number): boolean {
  return SWIM_DISTANCES.has(n);
}

function parseIntSafe(s: string): number | null {
  const n = parseInt(s, 10);
  return isNaN(n) ? null : n;
}

// ponytail (iter 11, 2026-07-28): parseFloatSafe for half-pool distances
// (12.5, 37.5, 62.5, 87.5) that parseInt would truncate.
function parseFloatSafe(s: string): number | null {
  const n = parseFloat(s);
  return isNaN(n) ? null : n;
}

function lastWord(text: string): string {
  return text.trim().split(/\s+/).pop() ?? "";
}

function firstWord(text: string): string {
  return text.trim().split(/\s+/)[0] ?? "";
}

// ─── Pass 1: Tokenize ─────────────────────────────────────────────────────────

interface RawLine {
  text: string;
  index: number;
  isBlank: boolean;
}

function tokenize(input: string): RawLine[] {
  // ponytail (autoresearch iter 9, 2026-07-22): strip markdown
  // formatting BEFORE tokenizing so coaches can paste a full
  // workout with # / ## headers, --- separators, * bullets, and
  // indented sub-bullets. The parser was built for plain text;
  // without this, raw markdown input returns 0 repGroups.
  const cleaned = input
    // strip horizontal-rule separators (---, ***, ___ on own line)
    .replace(/^\s*(?:[-*_]\s*){3,}$/gm, "")
    // strip heading hashes: "# Title", "## Title", etc.
    .replace(/^\s*#{1,6}\s+/gm, "")
    // strip bullet markers at line start: "* ", "- ", "+ ", "1. "
    .replace(/^\s*(?:[*+\-]|\d+\.)\s+/gm, "")
    // strip bold/italic markdown: **text**, *text*, __text__, _text_
    // ponytail (iter 11, 2026-07-28): insert spaces around stripped markdown
    // so "50**Race-quality" becomes "50 Race-quality" not "50Race-quality".
    .replace(/\*\*([^*]+)\*\*/g, " $1 ")
    .replace(/__([^_]+)__/g, " $1 ")
    .replace(/(?<!\*)\*(?!\*)([^*]+)\*(?!\*)/g, " $1 ")
    .replace(/(?<!_)_(?!_)([^_]+)_(?!_)/g, " $1 ");
  const lines = cleaned.split("\n");
  return lines.map((text, index) => ({
    text: text.trim(),
    index,
    isBlank: text.trim() === "",
  }));
}

// ─── Pass 2: Section detection ───────────────────────────────────────────────

const SECTION_HEADERS = new Set([
  "warm up",
  "warmup",
  "warm-up",
  "main",
  "main set",
  "cool down",
  "cooldown",
  "cool-down",
  "pre-set",
  "pre set",
  "warmdown",
  // ponytail (iter 11, 2026-07-28): new section headers from real coach inputs
  "race warm up",
  "race warm-up",
  "race warmup",
  "drill progression",
  "drill set",
  "drills",
  "aerobic finish",
  "aerobic set",
  "aerobic flush",
  "recovery",
  "finish",
  "swim down",
  "swimdown",
  "swim-down",
  "broken",
  "emphasis",
  "focus",
  // ponytail (iter 13, 2026-07-28): new section headers from inputs 11-17
  "open water",
  "sd",
  "activation set",
  "activation",
  "skills finish",
  "technique set",
  "stroke connection",
  "race priming",
  "turn and breakout preparation",
  "general warm-up",
  "deck activation",
  "race-skills finish",
  "common race-skills finish",
  "warm-down",
  "important quality controls",
]);

function isSectionHeader(line: RawLine): boolean {
  if (line.isBlank) return false;
  const t = normalize(line.text);
  // ponytail (autoresearch iter 10, 2026-07-22): rewrite to match
  // real coach section headers. The previous version rejected any
  // line containing a digit or em-dash, which kills every race-prep
  // header ("Pool warm-up — 1,000m", "Main set A — 100/200m
  // swimmers", "Part 1: Race-segment 75s — 900m", "Main set — 2,600m")
  // — they all have digits and em-dashes. Allow them.
  if (/\d+\s*[x×]\s*\d+/.test(t)) return false; // set line
  // ponytail (iter 12, 2026-07-28): don't reject "N Rounds" or
  // "N x through" as set lines — they're round multipliers.
  if (/^\d+\s+rounds?\s*(:|$)/i.test(t)) return true;
  if (/^\d+\s*[x×]\s*(thru|through)\s*$/i.test(t)) return true;
  if (/^\d+\s/.test(t)) return false; // starts with a number
  if (/^odds?\s*:/i.test(t)) return false; // odd: / odds:
  if (/^evens?\s*:/i.test(t)) return false;
  if (/^\d+\.\s/.test(t)) return false; // numbered list "1. foo"
  // Filter out interval/annotation lines like "@ 1:30", "@ :45"
  if (/^@\s/.test(t)) return false;
  const words = t.split(/\s+/).filter((w) => w.length > 0);
  if (words.length === 0 || words.length > 10) return false;
  // Pattern: "Name — Nm" or "Name — description" with em-dash.
  // Coaches use this for: "Pool warm-up — 1,000m",
  // "Race activation — 400m", "Main set A — 100/200m swimmers",
  // "Part 1: Race-segment 75s — 900m", "Warm-down — 500m".
  const emDashMatch = t.match(/^([\w\s\-:/]+?)\s+—\s+(.+)$/);
  if (emDashMatch) {
    const left = emDashMatch[1].trim();
    if (left.length >= 3 && !/\d+\s*[x×]/.test(left)) {
      return true;
    }
  }
  // Pattern: "Part N: Title" — round markers
  if (/^part\s+\d+\s*:/i.test(t)) return true;
  // Pattern: "Two rounds:", "Three rounds:", "One round:"
  if (/^(two|three|four|five|one)\s+rounds?\s*:/i.test(t)) return true;
  // ponytail (iter 12, 2026-07-28): "N Rounds", "N rounds of:",
  // "Two Rounds" (without colon), "2 x through", "Each round"
  if (/^\d+\s+rounds?\s*(:|$)/i.test(t)) return true;
  if (/^(two|three|four|five|one)\s+rounds?\s*$/i.test(t)) return true;
  if (/^\d+\s*[x×]\s*(thru|through)\s*$/i.test(t)) return true;
  if (/^each\s+round\s*$/i.test(t)) return true;
  if (/^repeat\s*(the\s+entire\s+round|round)?\s*\.?$/i.test(t)) return true;
  // ponytail (iter 12, 2026-07-28): "Warm-up N" / "swim down N" —
  // section header with total distance. Don't emit as a set.
  if (/^(warm[\s-]?up|warm[\s-]?down|swim[\s-]?down|cool[\s-]?down)\s+\d+/i.test(t)) return true;
  // ponytail (iter 13, 2026-07-28): "Option N: <name>" and
  // "Group A/B/C/D — <name>" as section headers.
  if (/^option\s+\d+\s*:/i.test(t)) return true;
  if (/^group\s+[a-d]\s*[—\-]/i.test(t)) return true;
  // ponytail (iter 13, 2026-07-28): "SD - N" (Swim Down abbreviation)
  if (/^sd\s*[-–]\s*\d+/i.test(t)) return true;
  // "Part N: <title>" already handled above.
  // "N. <title>" numbered section (e.g. "2. Aerobic flush", "3. Stroke connection")
  if (/^\d+\.\s+[a-z]/i.test(t) && !/\d+\s*[x×]\s*\d+/.test(t)) return true;
  // Legacy: bare keywords like "warm up", "main set", "cool down"
  if (SECTION_HEADERS.has(t)) return true;
  // Title-cased multi-word line without set pattern.
  // "Open-water variation", "Main set B — 200/400m swimmers".
  const strokeWords = new Set([
    "free",
    "back",
    "breast",
    "fly",
    "kick",
    "pull",
    "drill",
    "easy",
    "warm",
    "cool",
    "down",
    "set",
    "build",
    "descend",
    "max",
    "rest",
    "hold",
    "race",
    "pace",
    "round",
    "meters",
  ]);
  // Filter out words that start with "@" or are pure punctuation
  const meaningfulWords = words.filter((w) => /^[A-Za-z0-9]/.test(w));
  if (meaningfulWords.length === 0) return false;
  // ponytail (iter 11, 2026-07-28): reject pure number ranges like
  // "27.5-28.0" or "12.8-13.2" that leak through as false section headers.
  const hasTextWord = meaningfulWords.some((w) => /[A-Za-z]/.test(w));
  if (!hasTextWord) return false;
  const titleCased = meaningfulWords.every(
    (w) =>
      /^[A-Z0-9\d,/:]+$/.test(w) ||
      (w[0] === w[0].toUpperCase() && !strokeWords.has(w.toLowerCase())),
  );
  if (titleCased && meaningfulWords.length <= 8) return true;
  return false;
}

interface SectionBlock {
  title: string | null;
  lines: RawLine[];
}

function detectSections(tokens: RawLine[]): SectionBlock[] {
  const result: SectionBlock[] = [];
  let current: SectionBlock = { title: null, lines: [] };

  for (const line of tokens) {
    if (line.isBlank) {
      current.lines.push(line);
      continue;
    }

    if (isSectionHeader(line)) {
      if (current.lines.length > 0) {
        result.push(current);
      }
      current = { title: line.text, lines: [] };
    } else {
      current.lines.push(line);
    }
  }

  if (current.lines.length > 0) {
    result.push(current);
  }

  return result;
}

// ─── Pass 3 & 4: Label extraction + RepGroup parsing ──────────────────────────

const START_SET_RE =
  /^(\d+\s*[x×]\s*\d+|\d+\s*(?:m|yards?|meters?)?)(?=\s|\s*[,‌@:]|$)/i;

const SET_LINE_RE =
  /(\d+)\s*[x×]\s*(\d+)|\b(\d+)\s*(?:\d+)?\s*(?:m|yards?|meters?)?/i;

function isSetLine(text: string): boolean {
  return START_SET_RE.test(text) || /\d+\s+[x×]\s*\d+/.test(text);
}

function extractLabel(text: string): { label: string; rest: string } {
  const startSetMatch = text.match(START_SET_RE);
  if (startSetMatch) {
    return { label: "", rest: text };
  }
  const setIdx = text.search(SET_LINE_RE);
  if (setIdx > 0) {
    const restCandidate = text.slice(setIdx).trim();
    if (/^\([^)]+\)$/.test(restCandidate)) {
      return { label: text, rest: "" };
    }
    return {
      label: text.slice(0, setIdx).trim(),
      rest: restCandidate,
    };
  }
  if (setIdx === 0) {
    return { label: "", rest: text };
  }
  return { label: text, rest: "" };
}

function parseRepDist(raw: string): {
  reps: number | null;
  distance: number | null;
} {
  const n = normalize(raw);
  // ponytail (iter 11, 2026-07-28): support decimal distances (12.5, 37.5)
  // in the distance slot. Reps are always integers.
  const m = n.match(/(\d+)\s*[x×]\s*(\d+(?:\.\d+)?)/);
  if (m) {
    const a = parseIntSafe(m[1]);
    const b = parseFloatSafe(m[2]);
    if (a !== null && b !== null) {
      if (isKnownDistance(b)) return { reps: a, distance: b };
      if (isKnownDistance(a)) return { reps: b, distance: a };
      return { reps: Math.min(a, b), distance: Math.max(a, b) };
    }
  }
  const solo = n.match(/^(\d+(?:\.\d+)?)\s*/);
  if (solo) {
    const d = parseFloatSafe(solo[1]);
    if (d !== null && isKnownDistance(d)) {
      // ponytail (iter 12, 2026-07-28): trailing × N or x N multiplier
      // after a bare distance. "100 Back × 2" → reps=2, dist=100.
      // Note: no \b before x/× because × (U+00D7) is not a word char.
      const trailingMult = n.match(/(?:x|×)\s*(\d+)\s*$/);
      if (trailingMult) {
        const r = parseIntSafe(trailingMult[1]);
        if (r !== null) return { reps: r, distance: d };
      }
      return { reps: 1, distance: d };
    }
  }
  return { reps: null, distance: null };
}

// ─── Pass 4: Intensity ─────────────────────────────────────────────────────────

// RPE flywheel: terms split into two tiers based on industry-standard meaning.
//
// TIER 1 — PROMPT: the coach should map these because they're wildly different
// between coaches (one coach's "moderate" is another's "hard").
const AMBIGUOUS_INTENSITY_TERMS: Array<[RegExp, string]> = [
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

// TIER 2 — AUTO-RESOLVE: industry-standard swimming vocabulary. Don't prompt;
// the parser resolves to a default RPE range that the coach can override
// later by mapping the term in coach_vocabulary.
// ponytail (iter 11, 2026-07-28): expanded from 2 to 30+ terms covering
// the full intensity vocabulary observed in real coach inputs (6-10).
const DEFAULT_RPE_BY_TERM: Record<string, { low: number; high: number }> = {
  // Recovery / easy zone
  "easy": { low: 4, high: 5 },
  "relaxed": { low: 3, high: 4 },
  "recovery": { low: 3, high: 4 },
  "light": { low: 4, high: 5 },
  // Aerobic zone
  "moderate": { low: 5, high: 6 },
  "aerobic": { low: 5, high: 7 },
  "steady": { low: 6, high: 7 },
  "cruise": { low: 6, high: 7 },
  "progressive": { low: 6, high: 7 },
  "activation": { low: 5, high: 6 },
  // Threshold zone
  "tempo": { low: 8, high: 9 },
  "threshold": { low: 8, high: 9 },
  "hard": { low: 7, high: 8 },
  "tough": { low: 7, high: 8 },
  "strong": { low: 7, high: 8 },
  // Race pace zone
  "race pace": { low: 8, high: 9 },
  "race rhythm": { low: 8, high: 9 },
  "faster than race pace": { low: 9, high: 10 },
  // Sprint / max zone
  "all-out": { low: 9, high: 10 },
  "max": { low: 9, high: 10 },
  "maximal": { low: 9, high: 10 },
  "sprint": { low: 9, high: 10 },
  "fast": { low: 8, high: 9 },
  "blast": { low: 9, high: 10 },
  // Build / descend (intensity progression)
  "build": { low: 7, high: 8 },
  "descend": { low: 7, high: 8 },
};

function detectAmbiguousTerm(raw: string): string | null {
  for (const [re, term] of AMBIGUOUS_INTENSITY_TERMS) {
    if (re.test(raw)) return term;
  }
  return null;
}

function defaultRPEForTerm(term: string): { low: number; high: number } | null {
  return DEFAULT_RPE_BY_TERM[term.toLowerCase()] ?? null;
}

function parseIntensity(raw: string): ParsedIntensity | null {
  const n = normalize(raw);

  // ponytail (iter 13, 2026-07-28): "Zone N" or "Zone N-low Zone M"
  // as aerobic intensity. Coaches use heart-rate zones 1-5.
  const zoneMatch = n.match(/zone\s+(\d)(?:\s*[-–]\s*(?:low\s+)?zone\s+(\d))?/i);
  if (zoneMatch) {
    const low = parseIntSafe(zoneMatch[1]) ?? 1;
    const high = zoneMatch[2] ? parseIntSafe(zoneMatch[2]) ?? low : low;
    return { type: "aerobic", label: `Zone ${low}-${high}` };
  }

  // ponytail (iter 13, 2026-07-28): "RPE: N-N/10" or "N/10" as RPE.
  const rpeMatch = n.match(/rpe\s*:?\s*(\d+)\s*[-–]\s*(\d+)\s*\/\s*10/i);
  if (rpeMatch) {
    const low = parseIntSafe(rpeMatch[1]) ?? 5;
    const high = parseIntSafe(rpeMatch[2]) ?? 6;
    return { type: "percent_range", label: `RPE ${low}-${high}/10`, percentLow: low * 10, percentHigh: high * 10 };
  }
  // Bare "N/10" RPE rating (e.g. "8/10" after interval)
  const bareRpeMatch = n.match(/\b(\d+)\s*\/\s*10\b/);
  if (bareRpeMatch) {
    const v = parseIntSafe(bareRpeMatch[1]) ?? 5;
    return { type: "percent_range", label: `RPE ${v}/10`, percentLow: v * 10 - 5, percentHigh: v * 10 + 5 };
  }

  const percentMatch = n.match(/(~?)(\d+)\s*[-–]\s*(\d+)\s*%/);
  if (percentMatch) {
    const low = parseIntSafe(percentMatch[2]) ?? 0;
    const high = parseIntSafe(percentMatch[3]) ?? 0;
    const approx = percentMatch[1] === "~";
    const label = approx ? `${low}-${high}%` : `${low}-${high}%`;
    if (approx)
      return {
        type: "percent_range",
        label,
        percentLow: low - 5,
        percentHigh: high + 5,
      };
    return { type: "percent_range", label, percentLow: low, percentHigh: high };
  }

  const barePct = n.match(/(~?)(\d+)\s*%/);
  if (barePct) {
    const v = parseIntSafe(barePct[2]) ?? 0;
    const approx = barePct[1] === "~";
    const label = `${v}%`;
    if (approx)
      return {
        type: "percent_range",
        label,
        percentLow: v - 5,
        percentHigh: v + 5,
      };
    return {
      type: "percent_range",
      label,
      percentLow: v - 5,
      percentHigh: v + 5,
    };
  }

  // Slash-separated broken-swim segments: "50 400 pace/50 200 pace"
  // Each segment is a sub-distance with its own pace. Parse this FIRST
  // so the single-pace regex below doesn't grab only the first segment.
  if (n.includes("/")) {
    const segments = n.split("/").map((s) => s.trim()).filter((s) => s.length > 0);
    if (segments.length >= 2) {
      const hasPace = segments.some((s) => /\bpace\b/i.test(s));
      if (hasPace) {
        return {
          type: "pace_target",
          label: segments.map((s) => {
            const m = s.match(/(\d+)\s*m?\s*pace/);
            return m ? `${m[1]} pace` : s;
          }).join(" / "),
          paceDistance: undefined,
        };
      }
    }
  }

  // Pace target: "400 pace", "at 400 pace", "on 200 pace", "@100 pace"
  // The bare form (no preposition) is common in broken-swim notation.
  // ponytail (iter 13, 2026-07-28): "goal pace" variants —
  // "at goal 200m pace", "at goal 400m pace", "goal 200m pace"
  const goalPaceMatch = n.match(/(?:at\s+)?goal\s+(\d+)\s*m?\s*pace/);
  if (goalPaceMatch) {
    const d = parseIntSafe(goalPaceMatch[1]);
    if (d !== null && isKnownDistance(d))
      return { type: "pace_target", label: `goal ${d} pace`, paceDistance: d };
  }
  // "goal race pace" (no distance)
  if (/\bgoal\s+race\s+pace\b/i.test(raw)) {
    return { type: "race_pace", label: "goal race pace" };
  }

  const paceMatch = n.match(/(?:at\s+|on\s+|@\s*)?(\d+)\s*m?\s*(?:pace|effort)/);
  if (paceMatch) {
    const d = parseIntSafe(paceMatch[1]);
    if (d !== null && isKnownDistance(d))
      return { type: "pace_target", label: `${d} pace`, paceDistance: d };
  }

  const descendMatch = n.match(
    /\bdesc(?:end(?:ing)?)?\s*(?:(\d+)\s*[-–]\s*(\d+))?/,
  );
  if (descendMatch) {
    const label =
      descendMatch[1] && descendMatch[2]
        ? `descend ${descendMatch[1]}–${descendMatch[2]}`
        : "descend";
    return { type: "descend", label };
  }

  if (/\bneg(?:ative)?\s*split\b/i.test(raw)) {
    return { type: "negative_split", label: "negative split" };
  }

  if (/\bbuild(?:ing)?\b/i.test(raw)) return { type: "build", label: "build" };

  if (
    /\b(?:sprint|all[\s-]?out|max(?:\s+effort)?|blast|fast|atp)\b/i.test(raw)
  ) {
    return { type: "sprint", label: "ATP" };
  }

  if (/\b(?:race(?:\s+pace)?|r\.?p\.?)\b/i.test(raw)) {
    return { type: "race_pace", label: "race pace" };
  }

  if (/\b(?:threshold|css|critical\s+swim\s+speed|t[\s-]?pace)\b/i.test(raw)) {
    return { type: "threshold", label: "threshold" };
  }

  // Aerobic — preserve original word label
  if (/\b(?:aerobic|steady|cruise|moderate|hard|maximum|vo2)\b/i.test(raw)) {
    const match = raw.match(
      /\b(aerobic|steady|cruise|moderate|hard|maximum|vo2)\b/i,
    );
    return {
      type: "aerobic",
      label: match ? match[1].toLowerCase() : "aerobic",
    };
  }

  // Easy — preserve original word (EZ, recovery, etc.)
  if (
    /\b(?:easy|recovery|recover|warm[\s-]?up|loossen|ez|hard|maximum)\b/i.test(
      raw,
    )
  ) {
    const match = raw.match(
      /\b(easy|recovery|recover|warm[\s-]?up|loossen|ez|hard|maximum)\b/i,
    );
    const label = match ? match[1].toLowerCase() : "easy";
    return { type: "easy", label };
  }

  if (/\b(?:easy|recovery|recover|warm[\s-]?up|loosen|ez)\b/i.test(raw)) {
    const match = raw.match(
      /\b(easy|recovery|recover|warm[\s-]?up|loosen|ez)\b/i,
    );
    const label = match ? match[1].toLowerCase() : "easy";
    return { type: "easy", label };
  }

  // Tempo — industry-standard threshold term. Auto-resolved to RPE 8-9.
  if (/\b(?:tempo|race[\s-]?tempo|threshold[\s-]?tempo)\b/i.test(raw)) {
    return { type: "threshold", label: "tempo" };
  }

  return null;
}

// ─── Interval ─────────────────────────────────────────────────────────────────

function parseInterval(text: string): string | null {
  const n = normalize(text);
  // ponytail (autoresearch iter 8, 2026-07-22): bare-seconds
  // intervals like "@ :40", "@ :45", "@ :50" — coaches omit the
  // leading zero. Require the @ prefix to avoid matching the
  // seconds part of "1:40" or "2:50".
  const bareSecMatch = n.match(/@\s*:(\d{2})\b/);
  if (bareSecMatch) return `0:${bareSecMatch[1]}`;

  // ponytail (iter 11, 2026-07-28): bare :NN without @ prefix.
  // Coaches write "8 x 50 strong :55" or "4 x 25 @ :40" — the :NN
  // appears at end of line without @. Match :(NN) preceded by space
  // or start, but NOT inside a larger time like 1:40 (has digits before :).
  const bareSecNoAt = n.match(/(?:^|\s):(\d{2})\b/);
  if (bareSecNoAt) return `0:${bareSecNoAt[1]}`;

  // ponytail (iter 11, 2026-07-28): interval ranges like "2:20-2:30",
  // "1:40-1:50", ":50-1:00", "1:15-1:30". Take the first value as
  // the interval; store the range in the label later.
  const rangeMatch = n.match(
    /(?:on\s+|@\s*)?(\d+):(\d{2})\s*[-–]\s*(\d+):(\d{2})/,
  );
  if (rangeMatch) return `${rangeMatch[1]}:${rangeMatch[2]}`;

  // ponytail (iter 11, 2026-07-28): rest intervals like ":15 Rest",
  // ":10 Rest" — bare seconds followed by "rest". Must come before
  // the bare :NN match above to attach the "rest" keyword.
  const restSecMatch = n.match(/:(\d{2})\s*rest\b/i);
  if (restSecMatch) return `0:${restSecMatch[1]}`;

  // ponytail (iter 11, 2026-07-28): "N s rest" or "N-N s rest" like
  // "10-15 s rest" or "15 s rest"
  const restSecRangeMatch = n.match(/(\d+)\s*[-–]\s*(\d+)\s*s(?:ec)?\s*rest/i);
  if (restSecRangeMatch) {
    const s = parseIntSafe(restSecRangeMatch[1]) ?? 0;
    return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
  }
  const restSecSingleMatch = n.match(/(\d+)\s*s(?:ec)?\s*rest/i);
  if (restSecSingleMatch) {
    const s = parseIntSafe(restSecSingleMatch[1]) ?? 0;
    return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
  }

  // ponytail (iter 11, 2026-07-28): "Send off @ N:NN" or "send-off @ N:NN"
  const sendOffMatch = n.match(/send[\s-]?off\s+@?\s*(\d+):(\d{2})/i);
  if (sendOffMatch) return `${sendOffMatch[1]}:${sendOffMatch[2]}`;

  const colonMatch = n.match(
    /(?:on\s+)?(\d+):(\d{2})(?:\s+(?:interval|rest|i\/?)?)?/,
  );
  if (colonMatch) return `${colonMatch[1]}:${colonMatch[2]}`;

  // ponytail (iter 11, 2026-07-28): bare "N s" or "Ns" seconds interval
  // (e.g. "6 x 100 @ 15 s" or "4 x 50m @ 10-15 s rest")
  const bareSecsMatch = n.match(/(?:@|on\s+)(\d+)\s*s\b/);
  if (bareSecsMatch) {
    const s = parseIntSafe(bareSecsMatch[1]) ?? 0;
    return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
  }

  const minSecMatch = n.match(/on\s+(\d+)\s*min(?:ute)?s?\s+(\d+)/);
  if (minSecMatch)
    return `${minSecMatch[1]}:${minSecMatch[2].padStart(2, "0")}`;
  const decimalMinMatch = n.match(/on\s+(\d+\.5)\s*min(?:ute)?s?/);
  if (decimalMinMatch) {
    const total = parseFloat(decimalMinMatch[1]);
    return `${Math.floor(total)}:${String(Math.round((total % 1) * 60)).padStart(2, "0")}`;
  }
  const minMatch = n.match(/on\s+(\d+)\s*min(?:ute)?s?(?:\s|$)/);
  if (minMatch) return `${minMatch[1]}:00`;
  const secMatch = n.match(/on\s+(\d+)\s*s(?:ec(?:ond)?s?)?(?:\s|$)/);
  if (secMatch) {
    const s = parseInt(secMatch[1], 10);
    return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
  }
  return null;
}

// ─── Stroke ─────────────────────────────────────────────────────────────────

function parseStroke(text: string): Stroke | null {
  for (const [re, stroke] of STROKE_PATTERNS) {
    if (re.test(text)) return stroke;
  }
  return null;
}

// ─── Gear ────────────────────────────────────────────────────────────────────

function parseGear(text: string): string[] | null {
  const detected: string[] = [];
  for (const [re, gear] of GEAR_PATTERNS) {
    if (re.test(text)) detected.push(gear);
  }
  return detected.length > 0 ? detected : null;
}

// ─── Inline note extraction ──────────────────────────────────────────────────

function extractInlineNote(text: string): {
  cleaned: string;
  note: string | null;
} {
  const paren = text.match(/^(.+?)\s*\(([^)]+)\)\s*$/);
  if (paren) {
    return { cleaned: paren[1].trim(), note: paren[2].trim() };
  }
  const trailing = text.match(
    /\b(?:fast\s+for\s+time|for\s+time|as\s+fast\s+as\s+possible|descend\s+\d+\s*(?:-|to)\s*\d+|no\s+breath(?:ing)?|kick\s+drill(?:\s+on\s+board)?|board(?:\s+kicks)?|side\s+stroke|build\s+to\s+(?:fast|sprint|max)|negative\s+split(?:\s+1st\s+half\s+faster)?|1st\s+half\s+faster|2nd\s+half\s+faster|hold[\s-]+best[\s-]+average|(?:on[\s:]+(\d+:\d+)\s*)?race\s*pace|send[\s-]+off|strong\s+finish|odds\s+build\s+even\s+fast|fast\s+from\s+the\s+gun)\b[\s.,;:@\d]*(?:\s*@?\s*\d+:\d+(?:\.\d+)?)?\s*$/i,
  );
  if (trailing) {
    const trailingText = trailing[0];
    const capturedInterval = trailing?.[1];
    const intervalInTrailing = capturedInterval || trailingText.match(/\s*@?\s*(\d+:\d+(?:\.\d+)?)\s*$/)?.[1];
    const noteText = (() => {
      let n = trailingText;
      n = n.replace(/\s*@?\s*\d+:\d+(?:\.\d+)?\s*$/, "");
      if (capturedInterval) {
        n = n.replace(capturedInterval, "").replace(/^on\s+/, "");
      } else {
        n = n.replace(/^on\s+/, "");
      }
      return n.replace(/\s+/g, " ").trim();
    })();
    const intervalSuffix = intervalInTrailing ? " @ " + intervalInTrailing : "";
    return {
      cleaned: (text.slice(0, trailing.index!).trim() + intervalSuffix).trim(),
      note: noteText || trailingText.trim()
    };
  }
  return { cleaned: text, note: null };
}

// ─── Rep pattern resolution ───────────────────────────────────────────────────

type SubRep =
  | {
      type: "simple";
      meters: number;
      stroke: Stroke | null;
      note?: string;
      pacing?: string;
    }
  | {
      type: "drill_swim";
      drillMeters: number | null;
      swimMeters: number | null;
      drillStroke: Stroke | null;
      swimStroke: Stroke | null;
    }
  | { type: "odd_even"; odd: string; even: string };

function extractMiniNote(chunk: string): {
  cleaned: string;
  note: string | undefined;
} {
  const m = chunk.match(/^(.+?)\s*\(([^)]+)\)\s*$/);
  if (!m) return { cleaned: chunk, note: undefined };
  return { cleaned: m[1].trim(), note: m[2].trim() };
}

// ponytail (autoresearch iter 4, 2026-07-19): extract a
// free-text note from a line that has NO rep/distance pattern.
// Returns the note text or null if the line is empty/header/etc.
function parseFreeTextNote(text: string): string | null {
  const trimmed = text.trim();
  if (trimmed.length === 0) return null;
  if (/^[A-Z][A-Z0-9 \-/&]+$/.test(trimmed)) return null; // ALL-CAPS header
  if (
    /\b(?:fast\s+for\s+time|for\s+time|as\s+fast\s+as\s+possible|descend\s+\d+\s*(?:-|to)\s*\d+|no\s+breath(?:ing)?|kick\s+drill(?:\s+on\s+board)?|board(?:\s+kicks)?|side\s+stroke|build\s+to\s+(?:fast|sprint|max))\b/i.test(trimmed)
  ) {
    return trimmed;
  }
  return null;
}

function extractPacing(text: string): {
  cleaned: string;
  pacing: string | undefined;
} {
  const match = text.match(/\b(build|smooth|strong|moderate)\b/i);
  if (match) {
    return {
      cleaned: text.replace(match[0], "").trim(),
      pacing: match[1].toLowerCase(),
    };
  }
  return { cleaned: text, pacing: undefined };
}

function parseSubReps(text: string): SubRep[] {
  // ponytail (opus-3, 2026-07-22): handle the implicit-split case
  // "drill/swim" without explicit meters. The user's input "6 x 50
  // drill/swim" was parsing as plain Free with no sub-rep breakdown
  // because the original regex required explicit "25 drill / 25 swim"
  // meters. Now we detect "drill/swim" (no numbers) and return a
  // drill_swim sub-rep with null meters; the caller fills them in
  // from the parent rep distance.
  const drillSwimMatch = text.match(
    /(\d+)\s*(?:drill|dr)\s*[\/+]\s*(\d+)\s*(?:swim|s)/i,
  );
  if (drillSwimMatch) {
    const drillM = parseIntSafe(drillSwimMatch[1]);
    const swimM = parseIntSafe(drillSwimMatch[2]);
    if (drillM !== null && swimM !== null) {
      const drillStroke = parseStroke(text.replace(/swim/i, ""));
      const swimStroke = parseStroke(text);
      return [
        {
          type: "drill_swim",
          drillMeters: drillM,
          swimMeters: swimM,
          drillStroke,
          swimStroke,
        },
      ];
    }
  }
  const implicitDrillSwim = text.match(
    /(?:drill|dr)\s*[\/+]\s*(?:swim|s)\b/i,
  );
  if (implicitDrillSwim) {
    const drillStroke = parseStroke(text.replace(/swim/i, ""));
    const swimStroke = parseStroke(text);
    return [
      {
        type: "drill_swim",
        drillMeters: null,
        swimMeters: null,
        drillStroke,
        swimStroke,
      },
    ];
  }

  // ponytail (autoresearch iter 9, 2026-07-22): fallback for
  // plain "Ndm stroke" or "Ndm" forms — used when neither the
  // drill_swim nor the as-notation paths matched. Previously this
  // referenced an undefined `cleaned2` variable (dead code from
  // an earlier refactor). Use `text` directly.
  const simpleMatch = text.match(/^(\d+)\s+(.+)$/);
  if (simpleMatch) {
    const meters = parseIntSafe(simpleMatch[1]);
    const stroke = parseStroke(simpleMatch[2]);
    if (meters !== null) {
      return [
        {
          type: "simple",
          meters,
          stroke: stroke ?? null,
          note: undefined,
          pacing: undefined,
        },
      ];
    }
  }

  const distOnly = text.trim().match(/^(\d+)\s*$/);
  if (distOnly) {
    const meters = parseIntSafe(distOnly[1]);
    if (meters !== null) {
      return [
        {
          type: "simple",
          meters,
          stroke: null,
          note: undefined,
          pacing: undefined,
        },
      ];
    }
  }

  return [];
}

// ─── RepGroup parsing ─────────────────────────────────────────────────────────

function parseRepGroup(lineText: string): RepGroup | null {
  let text = lineText;

  const { cleaned, note } = extractInlineNote(text);
  text = cleaned;

  const rd = parseRepDist(text);
  if (rd.reps === null && rd.distance === null) return null;

  // ponytail (autoresearch iter 7, 2026-07-19): when there's an
  // "as" notation, the parent's stroke should be parsed from the
  // part BEFORE "as" — otherwise the as-notation's sub-rep strokes
  // (kick, drill, swim, breast) would override the nominal stroke
  // (e.g. IM in "4 x 50 IM @ 1:00 as 1.kick, 2.drill, ...").
  const preAsText = text.match(/as[\s:]/i) ? text.split(/as[\s:]/i)[0] : text;
  const stroke = parseStroke(preAsText);
  const interval = parseInterval(text);

  const pacingMatch = text.match(/\b(build|smooth|strong|moderate)\b/i);
  const pacing: string | null = pacingMatch
    ? pacingMatch[1].toLowerCase()
    : null;

  const descendMatch = text.match(
    /\bdesc(?:end(?:ing)?)?\s*(\d+)\s*[-–]\s*(\d+)/i,
  );
  const descend = descendMatch ? `${descendMatch[1]}-${descendMatch[2]}` : null;

  const gear = parseGear(text);
  const gearOptional = gear !== null && /\boptional\b/i.test(text);
  const dive = parseDive(text);
  const suit = parseSuit(text);
  const ambiguousTerm = detectAmbiguousTerm(text);
  const defaultRpe = ambiguousTerm ? defaultRPEForTerm(ambiguousTerm) : null;

  // ponytail (iter 12, 2026-07-28): #N per-rep intensity modifiers.
  // "#1 moderate #2 build to strong finish" → store as note.
  const perRepIntensity = text.match(/#\d+\s+\w[^#]*/gi);
  const perRepNote = perRepIntensity
    ? perRepIntensity.map((m) => m.trim()).join("; ")
    : null;

  // ponytail (iter 12, 2026-07-28): odds/evens inline pattern.
  // "odds uw fast evens easy back" → store as note.
  const oddsEvensMatch = text.match(
    /\bodds?\s+(.+?)\s+evens?\s+(.+?)\s*(?:@|$)/i,
  );
  const oddsEvensNote = oddsEvensMatch
    ? `odds: ${oddsEvensMatch[1].trim()}; evens: ${oddsEvensMatch[2].trim()}`
    : null;

  let details: string[] | null = null;
  {
    let t = text;
    if (pacing) t = t.replace(new RegExp(`\\b${pacing}\\b`, "gi"), "");
    if (descend) {
      const descRe = descendMatch![0].replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      t = t.replace(new RegExp(descRe, "gi"), "");
    }
    t = t.replace(/\boptional\b/gi, "");
    t = t.replace(/\d+\s*[x×]\s*\d+\s*m*/gi, "");
    t = t.replace(/\bat\s+[\d:]+\b/gi, "");
    // Strip distance+unit from details. Must include bare 'm' (the most
    // common abbreviation) — the original regex had 'meters?' but not 'm'.
    // Also strip 'seconds rest' / 'minutes rest' which are rest lines,
    // not swim distances.
    t = t.replace(/\b\d+\s*(?:m|meters?|yards?|yds?)?\b/gi, "");
    t = t.replace(/\b\d+\s*(?:seconds?|sec|minutes?|min)\s+rest\b/gi, "");
    t = t.replace(
      /\b(?:free|back|breast|fly|IM|medley|freestyle|backstroke|breaststroke|butterfly|pull|kick|drill|form|choice|swim|scull)\b/gi,
      "",
    );
    // ponytail (iter 11, 2026-07-28): strip intensity words that were
    // already consumed by parseIntensity, plus gear/dive/suit words
    // consumed by their parsers. Previously these leaked to details.
    t = t.replace(
      /\b(?:easy|moderate|aerobic|threshold|sprint|descend|negative[\s-]?split|race[\s-]?pace|race[\s-]?rhythm|hard|maximum|vo2|build(?:ing)?|choice|very|each|last|into|the|wall|fast|max|maximal|tough|strong|steady|cruise|light|all[-\s]?out|relaxed|recovery|tempo|activation|progressive|quality|rough|finish)\b/gi,
      "",
    );
    // Strip dive/suit words consumed by parseDive/parseSuit
    t = t.replace(/\b(?:dive|blocks?|start|push|suit|tech)\b/gi, "");
    // Strip gear words consumed by parseGear
    t = t.replace(/\b(?:fins|flippers|paddles?|pull[\s-]?buoy|buoy|kickboard|kick\s*board|snorkel|parachute|resistance\s*(?:band|cord|tubing)|power\s*tower|weight\s*belt|tennis\s*balls?|ankle\s*bands?|pull\s*paddle|finger\s*paddle|drag\s*(?:suit|shorts?)|stretchcordz|bungees?|band|drags|KBO)\b/gi, "");
    // ponytail (iter 12, 2026-07-28): strip #N per-rep intensity and
    // odds/evens patterns consumed by their note extractors.
    t = t.replace(/#\d+\s+\w[^#]*/gi, "");
    t = t.replace(/\bodds?\s+.+?\s+evens?\s+.+?(?:@|$)/i, "");
    t = t.replace(/\b(?:odds?|evens?)\b/gi, "");
    // ponytail (iter 13, 2026-07-28): strip coach-language noise words
    // that leak to details across all real coach inputs (11-17).
    // These are instruction/focus/reference words, not set metadata.
    t = t.replace(
      /\b(?:goal|breathing|stroke|with|silent|approximately|specialists?|BBB|PHF|FR-IM|A1|A2|front|mid|from|speed|end|race|connection|controlled|rest|seconds?|round|specialists?|swimmer|swimmers|athlete|athletes|open|water|surf|tri|school|nationals?|slightly|stronger|faster|slower|easier|harder|attack|lift|lifting|close|closing|rate|count|length|position|timing|execution|technique|explosive|quality|entry|opposite|next|previous|hold|maintain|repeat|opening|target|record|sustainable|technically|pool|sprint|unstructured|fatigue|competition|approaching|successful|valuable|rather|extra|repetitions?|minutes?|additional|before|between|after|first|second|third|fourth|remaining|following|above|below|through|group|part|option|specialists?|approximately|gradually|build(?:ing)?|descend(?:ing)?|negative|positive|smooth|perfect|competition|long|relaxed|underwater|breakout|streamline|turn|dive|push|start|wall|tempo|rhythm|effort|control|pace|focus|should|must|not|no|yes|if|then|than|but|and|or|the|a|an|of|for|to|in|on|at|by|up|down|out|off|over|under|into|onto|from|with|without|each|every|all|both|either|neither|this|that|these|those|which|what|when|where|why|how|who|can|could|would|should|will|shall|may|might|must|need|do|does|did|done|been|being|is|are|was|were|be|have|has|had|get|got|make|made|take|took|give|gave|keep|kept|let|leave|left|put|set|go|come|came|look|took|see|seen|use|used|allow|allowed|avoid|stop|record|recorded|encourage|monitor|choose|complete|emphasise|include|produce|reproduce|maintain|progress|deteriorate|preserve|simulate|adjust|provide|suggest|recommended?|approximately|gradually|throughout|throughout|approach|acceleration|final|included|total|though|racing|toward|four|as|slow|head|retraction|exit|flutter|explode|strokes|raced|dolphin|full|preparation|progression|drills?|silver|gold|only|add|swimming|shared|component|most|relevant|sprinting|breathe|skill|lower|their|heart|relax|best|possible|shape|equal|one|quarter|time|allowing|difference|remain|reflect|middle|section|maintaining|body|while|increasing|progressing|shortening|excessively|beginning|split|within|sec|side|uw|underwater)\b/gi,
      "",
    );
    // Strip pace/effort words so they don't show as details when
    // intensity is already pace_target. Also strip the bare numbers
    // that precede "pace" in broken-swim notation (e.g. "400 pace").
    t = t.replace(/\b\d*\s*pace\b/gi, "");
    t = t.replace(/\b\d*\s*effort\b/gi, "");
    t = t.replace(/[~]?\d+\s*[-–]\s*\d+\s*%/gi, "");
    t = t.replace(/[~]?\d+\s*%/gi, "");
    // ponytail (autoresearch iter 5, 2026-07-17): treat '/' as a
    // token separator so 'body/head' becomes 'body' and 'head' rather
    // than 'body/' and 'head'. Same rationale as the existing comma/plus
    // split. Also treat '–' (en-dash) and '|' as separators since
    // coaches write things like '50 – 100' and 'kick | pull' to mean
    // alternative.
    t = t.replace(/[,+\/\-|–]/g, " ");
    t = t.replace(/\([^)]*\)/g, "");
    // ponytail (iter 13, 2026-07-28): strip plural distance abbreviations
    // like "50s.", "100s" that leak through as details.
    t = t.replace(/\b\d+s\.?\b/gi, "");
    const words = t
      .split(/\s+/)
      .filter((w) => w.length > 2 && !/^\d+$/.test(w) && !/^\d+s\.?$/.test(w));
    details = words.length > 0 ? words : null;
  }

  let intensity = parseIntensity(text);
  let intensityOverride: ParsedIntensity | null = null;

  const asMatch = text.match(/as[\s:]+(.+)$/i);
  let subReps: SubRep[] = [];
  let patternType: RepGroup["patternType"] = null;

  if (asMatch) {
    const mainLineBeforeAs = text.substring(0, text.indexOf(asMatch[0])).trim();
    intensity = parseIntensity(mainLineBeforeAs);
    const drillSwimCheck = asMatch[1].match(
      /(\d+)\s*(?:drill|dr)\s*\+\s*(\d+)\s*(?:swim|s)/i,
    );
    if (drillSwimCheck) {
      const drillM = parseIntSafe(drillSwimCheck[1]);
      const swimM = parseIntSafe(drillSwimCheck[2]);
      if (drillM !== null && swimM !== null) {
        const drillStroke = parseStroke(asMatch[1].replace(/swim/i, ""));
        const swimStroke = parseStroke(asMatch[1]);
        subReps = [
          {
            type: "drill_swim",
            drillMeters: drillM,
            swimMeters: swimM,
            drillStroke,
            swimStroke,
          },
        ];
        patternType = "drill_swim";
      }
    } else {
      const parts = asMatch[1].split(/\s*[,+]\s*/);
      const lastPart = (parts[parts.length - 1] ?? "").trim();
      const intensityOnLast = parseIntensity(lastPart);
      const lastPartStripped = lastPart
        .replace(/(?:^|\s)(?:to\s+)?[~]?\d+\s*[-–]\s*\d+%\s*$/i, "")
        .replace(/(?:^|\s)(?:to\s+)?[~]?\d+%\s*$/i, "")
        .trim();

      for (let i = 0; i < parts.length; i++) {
        const part =
          i === parts.length - 1 ? lastPartStripped : parts[i].trim();
        const parsed = parseSubReps(part);
        if (parsed.length > 0) {
          const lastRep = parsed[parsed.length - 1];
          if (
            i === parts.length - 1 &&
            intensityOnLast &&
            lastRep.type === "simple"
          ) {
            (lastRep as { intensity?: ParsedIntensity }).intensity =
              intensityOnLast;
          }
          subReps.push(...parsed);
        }
      }
      if (
        subReps.length > 0 &&
        subReps.every(
          (s) =>
            "intensity" in s &&
            (s as { intensity?: ParsedIntensity }).intensity != null,
        )
      ) {
        const lastSub = subReps[subReps.length - 1] as {
          intensity?: ParsedIntensity;
        };
        if (lastSub.intensity) {
          intensityOverride = lastSub.intensity;
        }
      }
      if (subReps.length > 0) {
        if (subReps.some((s) => s.type === "drill_swim"))
          patternType = "drill_swim";
        else patternType = "simple";
      }
    }
  }


  // ponytail (opus-3, 2026-07-22): detect a drill/swim split
  // (explicit meters like "25 drill/25 swim", or implicit like
  // "drill/swim" / "catch-up/swim") and turn it into a drill_swim
  // sub-rep. Two forms:
  //   1. Explicit: "(\d+)\s*(?:drill|dr)\s*[\/+]\s*(\d+)\s*(?:swim|s)"
  //      -> use those meters directly
  //   2. Implicit: "(?:drill|dr|catch[\s-]?up)\s*[\/+]\s*(?:swim|s)"
  //      -> split parent rep distance 50/50
  const drillSwimExplicit = text.match(
    /(\d+)\s*(?:drill|dr)\s*[\/+]\s*(\d+)\s*(?:swim|s)\b/i,
  );
  const drillSwimImplicit = text.match(
    /(?:drill|dr|catch[\s-]?up|catchup)\s*[\/+]\s*(?:swim|s)\b/i,
  );
  const drillSwimMatch = drillSwimExplicit || drillSwimImplicit;
  if (drillSwimMatch && !asMatch) {
    const drillStroke = parseStroke(
      text.replace(
        /(\d+\s*)?(?:drill|dr|catch[\s-]?up|catchup)\s*[\/+]\s*(\d+\s*)?(?:swim|s)\b/i,
        "",
      ),
    );
    const swimStroke = parseStroke(
      text.replace(
        /(\d+\s*)?(?:drill|dr|catch[\s-]?up|catchup)\s*[\/+]\s*(\d+\s*)?(?:swim|s)\b/i,
        "free",
      ),
    );
    let drillM: number;
    let swimM: number;
    if (drillSwimExplicit) {
      drillM = parseIntSafe(drillSwimExplicit[1]) ?? 0;
      swimM = parseIntSafe(drillSwimExplicit[2]) ?? 0;
    } else {
      drillM = Math.floor((rd.distance ?? 0) / 2);
      swimM = (rd.distance ?? 0) - drillM;
    }
    const drillSwimIdx = text.search(
      /(?:drill|dr|catch[\s-]?up|catchup)\s*[\/+]\s*(?:swim|s)/i,
    );
    const trailing = drillSwimIdx >= 0 ? text.slice(drillSwimIdx) : "";
    const numberedEntries: Array<{ num: number; stroke: string }> = [];
    const entryRegex = /(\d+)\s*\.?\s+([^\d][^\d]*?)(?=\s*\d+\s*\.?\s|\s*@|\s*$)/g;
    let em: RegExpExecArray | null;
    while ((em = entryRegex.exec(trailing)) !== null) {
      const num = parseIntSafe(em[1]);
      if (num === null) continue;
      numberedEntries.push({ num, stroke: em[2].trim() });
    }
    const useNumberedList = numberedEntries.length >= 2;
    if (useNumberedList) {
      subReps = numberedEntries.map((e) => ({
        type: "drill_swim",
        drillMeters: drillM,
        swimMeters: swimM,
        drillStroke: parseStroke(e.stroke),
        swimStroke,
      }));
    } else {
      subReps = [
        {
          type: "drill_swim",
          drillMeters: drillM,
          swimMeters: swimM,
          drillStroke,
          swimStroke,
        },
      ];
    }
    patternType = "drill_swim";
  }

  // ponytail (autoresearch iter 6, 2026-07-19): detect a pure
  // pattern rotation in the line text and turn it into structured
  // sub-reps. Examples:
  //   "3 x 300 FBBF @ 4:30"          -> pattern: [Free, Back, Breast, Free]
  //   "3 x 100 FBFB@ 1.20"           -> pattern: [Free, Back, Free, Back]
  //   "3 x 200 FBF @ 2:50 by"        -> pattern: [Free, Back, Free]
  // Previously FBBF/FBF/FBFB ended up in details, not in pattern,
  // which meant same-as-above inheritance couldn't see the pattern.
  const ROTATION_RE = /\b[FBKR]{2,}\b/;
  const rotationMatch = text.match(ROTATION_RE);
  if (!asMatch && rotationMatch) {
    const rot = rotationMatch[0].toUpperCase();
    const subRepsFromRotation: SubRep[] = [];
    for (const ch of rot) {
      const strokeMap: Record<string, string> = {
        F: "Free", B: "Back", K: "Breast", R: "Fly", I: "IM", M: "IM"
      };
      subRepsFromRotation.push({
        type: "simple",
        meters: rd.distance ?? 0,
        stroke: strokeMap[ch] ?? null,
        note: undefined,
        pacing: undefined,
      });
    }
    if (subRepsFromRotation.length > 0) {
      subReps = subRepsFromRotation;
      patternType = "simple";
    }
  }

  // ponytail (iter 12, 2026-07-28): merge per-rep intensity and
  // odds/evens notes into the existing note (if any).
  const allNotes = [note, perRepNote, oddsEvensNote].filter(
    (n) => n !== null && n !== undefined,
  );
  const mergedNote = allNotes.length > 0 ? allNotes.join("; ") : null;

  return {
    reps: rd.reps,
    distance: rd.distance,
    stroke,
    interval,
    intensity: intensityOverride ?? intensity ?? null,
    pacing,
    note: mergedNote,
    gear,
    gearOptional,
    descend,
    details,
    dive,
    suit,
    ambiguousTerm,
    defaultRpe,
    // ponytail (autoresearch 2026-07-21): the previous code used a stale
    // `reps` const that was mapped from subReps BEFORE the rotation
    // block had a chance to populate it. That meant FBBF/FBF/FBFB
    // patterns rendered as `pattern: []` in production. Now we map
    // subReps at return time so rotation-set values are included.
    pattern: subReps.map((s) => {
      if (s.type === "drill_swim") {
        return {
          type: "drill_swim" as const,
          drillMeters: s.drillMeters,
          swimMeters: s.swimMeters,
          drillStroke: s.drillStroke,
          swimStroke: s.swimStroke,
        };
      }
      if (s.type === "odd_even") {
        return { type: "odd_even" as const, odd: s.odd, even: s.even };
      }
      return {
        type: "simple" as const,
        meters: s.meters,
        stroke: s.stroke,
        note: s.note,
        pacing: s.pacing,
        intensity: (s as { intensity?: ParsedIntensity }).intensity,
      };
    }),
    patternType: subReps.length > 0 ? (patternType ?? "simple") : null,
    connectors: [],
  };
}

// Parse odd/even sub-lines
function parseOddEvenBlock(
  lines: RawLine[],
  startIdx: number,
): { rep: Rep; endIdx: number } | null {
  if (startIdx >= lines.length) return null;

  const first = lines[startIdx];
  const oddMatch = first.text.match(/^odd\s*:\s*(.+)/i);
  if (!oddMatch) return null;

  const odd = oddMatch[1].trim();
  let even = "";
  let endIdx = startIdx + 1;

  while (endIdx < lines.length) {
    const line = lines[endIdx];
    if (line.isBlank) {
      endIdx++;
      continue;
    }
    const evenMatch = line.text.match(/^even\s*:\s*(.+)/i);
    if (!evenMatch) break;
    even = evenMatch[1].trim();
    endIdx++;
    break;
  }

  return {
    rep: { type: "odd_even", odd, even },
    endIdx,
  };
}

// ─── Main parseWorkoutV2 ─────────────────────────────────────────────────────

function parseWorkoutV2(input: string): Workout {
  const tokens = tokenize(input);
  const blocks = detectSections(tokens);

  const sections: Section[] = blocks.map((block) => {
    const namedSets: NamedSet[] = [];
    let i = 0;
    let pendingLabel: string | null = null;

    while (i < block.lines.length) {
      const line = block.lines[i];

      if (line.isBlank) {
        i++;
        continue;
      }

      if (isSectionHeader(line)) {
        pendingLabel = null;
        i++;
        continue;
      }

      if (/^odd\s*:/i.test(line.text)) {
        const result = parseOddEvenBlock(block.lines, i);
        if (result) {
          const currentNs = namedSets[namedSets.length - 1];
          if (currentNs && currentNs.repGroups.length > 0) {
            const lastRg = currentNs.repGroups[currentNs.repGroups.length - 1];
            lastRg.pattern.push(result.rep);
            lastRg.patternType = "odd_even";
          }
          pendingLabel = null;
          i = result.endIdx;
          continue;
        }
      }

      let { label, rest } = extractLabel(line.text);

      // ponytail (autoresearch iter 6, 2026-07-17): resolve
      // "same as above" / "do previous" / "repeat above" / "as above"
      // cross-references. When a set line ends with one of these
      // suffixes, strip the suffix and copy reps/distance/interval/
      // stroke/pattern from the previous rep-group. Only fires when
      // the rest still parses as a set after stripping — a bare
      // "same as above" line with no leading set falls through to
      // the normal unparseable-line path.
      let sameAsAbovePrev: RepGroup | null = null;
      const saaMatch = rest.match(
        /\s*(same as above|do previous|repeat above|as above)\s*$/i,
      );
      if (saaMatch) {
        const stripped = rest.replace(saaMatch[0], "").trim();
        const strippedRd = parseRepDist(stripped);
        if (strippedRd.reps !== null || strippedRd.distance !== null) {
          for (let si = namedSets.length - 1; si >= 0; si--) {
            const ns = namedSets[si];
            if (ns.repGroups.length > 0) {
              sameAsAbovePrev = ns.repGroups[ns.repGroups.length - 1];
              break;
            }
          }
          if (sameAsAbovePrev) rest = stripped;
        }
      }

      if (!rest) {
        // ponytail (autoresearch iter 6, 2026-07-17): only promote
        // a line to pendingLabel when it actually contains a set
        // pattern. A pure free-text note like
        //   "Float high Body position first, feet on lane rope and
        //    hands on board or noodle or lane rope- breath control-
        //    arms straight"
        // must NOT become the label of the next set. The isSetLine
        // guard also covers the wrap-in-parens case
        //   "Some label (3 x 100 free)"
        // where the original logic correctly retained the parens
        // as a label.
        if (
          label.length > 0 &&
          label.trim().length > 0 &&
          isSetLine(line.text)
        ) {
          pendingLabel = label;
        }
        i++;
        continue;
      }

      // ponytail (iter 12, 2026-07-28): pace table / reference row
      // detection. Lines like "National senior 2:10-2:20 Send off @ 2:30"
      // or "First 200 Aerobic 2:28-2:32" are pace reference tables,
      // not sets. Skip them if the line has 2+ time ranges and no
      // rep pattern (NxM).
      const timeRanges = (rest.match(/\d+:\d{2}\s*[-–]\s*\d+:\d{2}/g) || []).length;
      if (timeRanges >= 2 && !/\d+\s*[x×]\s*\d+/.test(rest)) {
        pendingLabel = null;
        i++;
        continue;
      }

      // ponytail (iter 12, 2026-07-28): false set suppression.
      // "<distance> swimmers" and "<distance> target" are not sets.
      if (/\b\d+\s*(swimmers|target)\b/i.test(rest)) {
        pendingLabel = null;
        i++;
        continue;
      }

      // ponytail (iter 13, 2026-07-28): "N seconds rest" / "N sec rest"
      // is a rest instruction, not a set. 15/10/20 are in SWIM_DISTANCES
      // so they get parsed as sets. Guard: if the line is ONLY a rest
      // instruction (no reps/distance pattern), skip it.
      if (/^\d+\s*(?:seconds?|sec)\s+rest\b/i.test(rest.trim())) {
        pendingLabel = null;
        i++;
        continue;
      }

      const rd = parseRepDist(rest);
      if (rd.reps === null && rd.distance === null) {
        // ponytail (autoresearch iter 4, 2026-07-19): a bare
        // "fast for time" / "for time" / "no breath" line (no reps,
        // no distance) should be attached to the PREVIOUS rep
        // group as a note. Without this, the "1 x 400 FBFB" set
        // on one line and "fast for time" on the next lose the
        // note attribution.
        const freeTextNote = parseFreeTextNote(line.text);
        if (freeTextNote) {
          for (let si = namedSets.length - 1; si >= 0; si--) {
            const ns = namedSets[si];
            if (ns.repGroups.length > 0) {
              const lastRg = ns.repGroups[ns.repGroups.length - 1];
              if (!lastRg.note) {
                lastRg.note = freeTextNote;
              }
              break;
            }
          }
        }
        pendingLabel = null;
        i++;
        continue;
      }

      const effectiveLabel = label.length > 0 ? label : (pendingLabel ?? null);
      if (label.length > 0 && pendingLabel !== null) {
        pendingLabel = null;
      }

      const namedSet: NamedSet = {
        label: effectiveLabel,
        note: null,
        repGroups: [],
      };

      const rg = parseRepGroup(rest);
      if (rg) {
        // ponytail (autoresearch iter 6, 2026-07-17): when a
        // "same as above" suffix was stripped, fill in any missing
        // fields (reps/distance/interval/stroke/pattern) from the
        // previous rep-group. Don't copy details/gear/intensity/
        // descend — those are set-specific and stay on the new rg.
        if (sameAsAbovePrev) {
          if (rg.reps == null) rg.reps = sameAsAbovePrev.reps;
          if (rg.distance == null) rg.distance = sameAsAbovePrev.distance;
          if (rg.interval == null) rg.interval = sameAsAbovePrev.interval;
          if (rg.stroke == null) rg.stroke = sameAsAbovePrev.stroke;
          if (
            (!rg.pattern || rg.pattern.length === 0) &&
            sameAsAbovePrev.pattern &&
            sameAsAbovePrev.pattern.length > 0
          ) {
            rg.pattern = sameAsAbovePrev.pattern.map((p) => ({ ...p }));
            rg.patternType = sameAsAbovePrev.patternType;
          }
        }
        namedSet.repGroups.push(rg);

        // ponytail (autoresearch iter 1, 2026-07-15): detect multiple
        // rep groups on one line. The current parser only emits one rg
        // per line via parseRepGroup(rest). Real coach input often packs
        // multiple sets on one line, e.g.
        //   "400 kick for body/head position 100 free 100 back"
        //   "3 x 300 free @ 4.30 as 1.fists/swim, 2. catch up/swim 3. swim"
        // Strategy: re-scan the line text for "<N> m" distance
        // occurrences beyond the first. For each, build a synthetic
        // sub-line with that one set and parse it. Inherit interval
        // and intensity from the first rg when not specified.
        // Only split on `<N> m? <STROKE_WORD>` patterns. This avoids
        // matching pattern numbers like "1." in "as 1.fists/swim, 2. catch up/swim".
        // ponytail (autoresearch iter 2, 2026-07-15): bugfix — the previous
        // iteration used a regex literal with template concatenation
        // (`'...source...'/gi`) which JS parses as a literal regex
        // containing the STRING `(?=' + STROKE_RE.source + ')` instead
        // of interpolating. Use new RegExp() to build dynamically.
        const STROKE_RE = /(?:free|back|breast|fly|im|kick|pull|choice|form)/i;
        const allSetMatches = [...line.text.matchAll(new RegExp("\\b(\\d+)\\s*m?\\s+(?=" + STROKE_RE.source + ")", "gi"))];
        if (allSetMatches.length > 1) {
          for (let mi = 1; mi < allSetMatches.length; mi++) {
            const m = allSetMatches[mi];
            const subRep = parseRepGroup(line.text.slice(m.index!));
            if (subRep) {
              if (!subRep.interval) subRep.interval = rg.interval;
              if (!subRep.intensity) subRep.intensity = rg.intensity;
              namedSet.repGroups.push(subRep);
            }
          }
        }

        // ponytail (iter 12, 2026-07-28): comma-separated multi-set
        // lines. Coaches write "300m relaxed choice, 100m freestyle,
        // 100m backstroke or choice, 100m freestyle" on one line.
        // Split on commas when each segment has a distance + stroke.
        // Don't split inside "as 1.kick, 2.drill, 3.swim" (the as-notation
        // already handles commas via its own splitter).
        if (!/\bas[\s:]/i.test(rest) && rest.includes(",")) {
          const segments = rest.split(/,(?!\s*(?:and|&)\b)/i).map((s) => s.trim()).filter((s) => s.length > 0);
          if (segments.length > 1) {
            const allHaveDist = segments.every((seg) => {
              const segRd = parseRepDist(seg);
              return segRd.reps !== null || segRd.distance !== null;
            });
            if (allHaveDist) {
              for (let si = 1; si < segments.length; si++) {
                const segRg = parseRepGroup(segments[si]);
                if (segRg) {
                  if (!segRg.interval) segRg.interval = rg.interval;
                  if (!segRg.intensity) segRg.intensity = rg.intensity;
                  namedSet.repGroups.push(segRg);
                }
              }
            }
          }
        }
      }

      const plusMatch = rest.match(/^(.+?)\s*\+\s*(.+)$/);
      if (plusMatch && !/\bas[\s:]/i.test(plusMatch[1])) {
        const secondRg = parseRepGroup(plusMatch[2].trim());
        if (secondRg) {
          if (!secondRg.interval) secondRg.interval = rg?.interval ?? null;
          if (!secondRg.intensity) secondRg.intensity = rg?.intensity ?? null;
          secondRg.connectors.push("+");
          namedSet.repGroups.push(secondRg);
        }
      }

      if (namedSet.repGroups.length > 0) {
        const lastNS = namedSets[namedSets.length - 1];
        if (lastNS && lastNS.label === effectiveLabel) {
          lastNS.repGroups.push(...namedSet.repGroups);
        } else {
          namedSets.push(namedSet);
        }
      }

      i++;
    }

    return {
      title: block.title,
      namedSets,
    };
  });

  return { title: null, sections };
}


// Bench engine export — no HTTP handler needed.
export { parseWorkoutV2 };
