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

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { WORD_NUMBERS, SWIM_DISTANCES } from "../../hydrolyze-mobile/lib/constants/swim-constants.ts";
import { LLMError, parseWithLLM, type CoachVocabularyEntry } from "./_llm.ts";
import { extractUnmappedTerms } from "./_dialect-detector.ts";
import { normalizeFragmentDistances } from "./_decimal-distance-fix.ts";

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
  | "percent_range"
  // V0.38 (2026-08-15): 3-minute all-out test marker. rawValue is
  // spelled "3mt" so the free-form intensity_type column accepts it
  // without a CHECK constraint change.
  | "3mt";

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

// Composite-set fragment — each independently-describable swim segment
// inside a parenthesized composite rep like:
//   4 x (75 at race rhythm / :15 Rest / 25 maximal finish)
interface Fragment {
  id: string; // V0.35 (2026-08-12): stamped deterministically in parseWithFallback
  distance: number;
  // V0.53.3 (2026-09-08, jodie-09 display fidelity): mirror of
  // ios-native/supabase/. Populated by normalizeFragmentDistances
  // right before serialization.
  distance_label: string | null;
  stroke: Stroke | null;
  intensity: ParsedIntensity | null;
  note: string | null;
  restAfter: number | null; // seconds of rest AFTER this fragment
  // V0.37 (2026-08-13): per-fragment gear + start_type, matching the LLM
  // fragment shape so the 4-place sync (prototype / _llm.ts / edge / iOS)
  // stays in lockstep. The pairing cost tiers key on the fragment's OWN
  // context, not the parent repGroup's.
  gear: string[] | null;
  start_type: "dive" | "push" | "wall" | null;
  order: number;
}

type ZoneTerm = "easy" | "steady" | "hard" | "sprint";

interface RepGroup {
  reps: number | null;
  distance: number | null;
  stroke: Stroke | null;
  interval: string | null;
  restInterval: boolean; // true = "rest :20" (between reps), false = "@ 1:30" (send-off cycle)
  intensity: ParsedIntensity | null;
  zoneTerm: ZoneTerm | null;
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
  fragments: Fragment[] | null;
  // V0.35 (2026-08-12): the source line this rep group was parsed from.
  // Feeds the deterministic fragment-id stamp (sha1(sourceLine:orderIndex)).
  sourceLine: string;
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
    // strip bullet markers at line start: "* ", "- ", "+ "
    // NOTE: numbered markers ("1. ") are preserved — the main loop's
    // numbered instruction detector needs them to distinguish drill lists
    // (1. Fists / 2. 1 arm) from plain text lines.
    .replace(/^\s*(?:[*+\-])\s+/gm, "")
    // strip bold/italic markdown: **text**, *text*, __text__, _text_
    // ponytail (iter 11, 2026-07-28): insert spaces around stripped markdown
    // so "50**Race-quality" becomes "50 Race-quality" not "50Race-quality".
    .replace(/\*\*([^*]+)\*\*/g, " $1 ")
    .replace(/__([^_]+)__/g, " $1 ")
    .replace(/(?<!\*)\*(?!\*)([^*]+)\*(?!\*)/g, " $1 ")
    .replace(/(?<!_)_(?!_)([^_]+)_(?!_)/g, " $1 ");
  const lines = cleaned.split("\n");
  const rawLines = lines.map((text, index) => ({
    text: text.trim(),
    index,
    isBlank: text.trim() === "",
  }));
  return joinCompositeLines(rawLines);
}

// Pre-processing pass: join multi-line parenthetical composite reps into
// a single logical line so the existing single-pass parser can handle them.
function joinCompositeLines(lines: RawLine[]): RawLine[] {
  const result: RawLine[] = [];
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    const parenIdx = line.text.indexOf("(");
    const closeIdx = line.text.indexOf(")");
    const hasOpener =
      /\d+\s*[x\u00d7]\s*\(/.test(line.text) &&
      parenIdx !== -1 &&
      (closeIdx === -1 || closeIdx < parenIdx);

    if (hasOpener) {
      const afterParen = line.text.slice(parenIdx + 1).trim();
      const prefix = line.text.slice(0, parenIdx).trim();

      const segments: string[] = [];
      if (afterParen.length > 0) segments.push(afterParen);

      let endIdx = i + 1;
      let closed = false;
      while (endIdx < lines.length) {
        const segLine = lines[endIdx];
        let segText = segLine.text.trim();
        if (segText.endsWith(")")) {
          segText = segText.slice(0, -1).trim();
          if (segText.length > 0) segments.push(segText);
          closed = true;
          endIdx++;
          break;
        }
        if (segText === ")") {
          closed = true;
          endIdx++;
          break;
        }
        if (segText.length > 0) segments.push(segText);
        endIdx++;
      }
      if (closed && segments.length >= 2) {
        const joined = `${prefix} (${segments.join(" / ")})`;
        result.push({ text: joined, index: line.index, isBlank: false });
        i = endIdx;
        continue;
      }
    }
    result.push(line);
    i++;
  }
  return result;
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

// V0.38 (2026-08-15): 3-minute all-out test marker. "3MT" / "3-MT" /
// "3 MT" literal OR "3 [-] min(ute)?(s)? all-out|test" with min/minute/
// mins/minutes and hyphen/space variants of "all-out" / "all out".
// "all-out" alone is NOT a 3MT marker. Module scope — used by
// isSectionHeader, parseIntensity, and the set-line short-circuit.
const THREE_MT_RE =
  /\b3\s*[-]?\s*m(?:in(?:ute)?s?)?\s+(?:all[\s-]?out|test)\b|\b3\s*[-]?\s*mt\b/i;

function isSectionHeader(line: RawLine): boolean {
  if (line.isBlank) return false;
  const t = normalize(line.text);
  // V0.38 (2026-08-15): a 3MT marker line is a SET, never a section
  // header. Bare "3MT" is title-cased and digit-free after normalize,
  // so it falls through to the title-case branch below and gets swallowed
  // as a header — dropping the set entirely.
  if (THREE_MT_RE.test(t)) return false;
  // ponytail (autoresearch iter 10, 2026-07-22): rewrite to match
  // real coach section headers. The previous version rejected any
  // line containing a digit or em-dash, which kills every race-prep
  // header ("Pool warm-up — 1,000m", "Main set A — 100/200m
  // swimmers", "Part 1: Race-segment 75s — 900m", "Main set — 2,600m")
  // — they all have digits and em-dashes. Allow them.
  if (/\d+\s*[x×]\s*\d+/.test(t)) return false; // set line
  // NOTE: Round multipliers are NOT section headers. They're handled by
  // the round-multiplier detector in parseWorkoutV2.
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
  // Pattern: "Part N: Title" — section markers
  if (/^part\s+\d+\s*:/i.test(t)) return true;
  // NOTE: Round multipliers are handled by the round-multiplier detector
  // in parseWorkoutV2, not here.
  // ponytail (iter 12, 2026-07-28): "Warm-up N" / "swim down N" —
  // section header with total distance. Don't emit as a set.
  if (/^(warm[\s-]?up|warm[\s-]?down|swim[\s-]?down|cool[\s-]?down)\s+\d+/i.test(t)) return true;
  // ponytail (iter 13, 2026-07-28): "Option N: <name>" and
  // "Group A/B/C/D — <name>" as section headers.
  if (/^option\s+\d+\s*:/i.test(t)) return true;
  if (/^group\s+[a-d]\s*[—\-]/i.test(t)) return true;
  // 2026-07-31: Colon-form section headers. Coaches write:
  //   "Warm-Up:" / "Warm Up:" / "Warmup:"
  //   "Cool-Down:" / "Cool Down:" / "Cooldown:"
  //   "Main Set:" / "Main Set (Lactate Overload):"
  //   "Aerobic Flush Block:" / "Pre-Set:" / "Drill Set:"
  // The colon terminator distinguishes these from sets ("N x 100 @ 1:30").
  if (/^(warm[\s-]?up|cool[\s-]?down|main\s+set|main\s+set\b.*|pre[\s-]?set|drill\s+set|activation\s+set|pre[\s-]?activation|build\s+set|activation|warm[\s-]?down|cool[\s-]?down|aerobic\s+flush|lactate\s+overload|finish\s+set|cool[\s-]?down|cool[\s-]?up|technique\s+set)\s*[^\d]*$/i.test(t)) {
    return true;
  }
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
  if (titleCased && meaningfulWords.length <= 8) {
    // Don't treat round multipliers as section headers
    if (/^\d+\s*times?\s+through/i.test(t)) return false;
    if (/^\d+\s+rounds?\s*:?/i.test(t)) return false;
    if (/^(two|three|four|five|one)\s+rounds?/i.test(t)) return false;
    if (/^\d+\s*[x×]\s*(?:thru|through)/i.test(t)) return false;
    return true;
  }
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
// V0.47: single source-of-truth in _dialect-terms.ts. Edge used to inline
// a 17-row literal array here; now consumes the shared list. Mirror lives
// at scripts/parser-bench/_dialect-terms.ts (Node) and is intentionally
// duplicated into ios-native/supabase/functions/parse-workout/ per the
// 4-place sync invariant (V0.47_DIALECT.md §5).
import { TIER1_TERMS } from "./_dialect-terms.ts";
const AMBIGUOUS_INTENSITY_TERMS: Array<[RegExp, string]> = TIER1_TERMS.map(
  (t) => [t[0], t[1]],
);

// TIER 2 — AUTO-RESOLVE: industry-standard swimming vocabulary. Don't prompt;
// the parser resolves to a default RPE range that the coach can override
// later by mapping the term in coach_vocabulary.
// ponytail (iter 11, 2026-07-28): expanded from 2 to 30+ terms covering
// the full intensity vocabulary observed in real coach inputs (6-10).
// V0.47 (2026-08-22) drift fix: every term in TIER1_TERMS removed — the
// two lists must be disjoint (Tier-1 = ASK, Tier-2 = silent default).
// Mirror of _dialect-detector.ts DEFAULT_RPE_BY_TERM — kept in lockstep
// by hand since the engine's defaultRPEForTerm() consumes this list.
const DEFAULT_RPE_BY_TERM: Record<string, { low: number; high: number }> = {
  // Aerobic zone — industry-standard, no coach variance
  "aerobic": { low: 5, high: 7 },
  "smooth": { low: 5, high: 7 },
  // Threshold zone — derived; "threshold" means LT for most coaches
  "threshold": { low: 8, high: 9 },
  // Race pace zone — industry term
  "race pace": { low: 8, high: 9 },
  // Recovery zone
  "recovery": { low: 3, high: 4 },
  // Sprint — pure-sprint effort, no coach variance
  "sprint": { low: 9, high: 10 },
  "blast": { low: 9, high: 10 },
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

function parseZoneTerm(raw: string): ZoneTerm | null {
  if (THREE_MT_RE.test(raw)) return null;
  const matches = [...raw.matchAll(/\b(easy|steady|hard|sprint)\b/gi)];
  const terms = new Set(matches.map((match) => match[1].toLowerCase() as ZoneTerm));
  return terms.size === 1 ? [...terms][0] : null;
}

function parseIntensity(raw: string): ParsedIntensity | null {
  const n = normalize(raw);

  // V0.38 (2026-08-15): 3-minute all-out test. Must run BEFORE generic
  // intensity matches so the marker wins over "all-out" (sprint) and
  // "test" (no match elsewhere). Shared module-scope THREE_MT_RE.
  if (THREE_MT_RE.test(raw)) {
    return { type: "3mt", label: "3-minute all-out" };
  }

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
    /\b(?:sprint|all[\s-]?out|max(?:\s+effort)?|blast|fast|maximal|atp)\b/i.test(raw)
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
  // R:I / R:I. / RI — Rest Interval marker (Swim Richmond glossary).
  // "R:I 20" means "Rest Interval of 20 seconds". The restInterval
  // flag in parseRepGroup checks for "R:I" presence to set the flag.
  // Match: optional @, then R:I or R:I. or RI, then a value.
  // E.g. "@ R:I 20", "@ R:I. 20", "@ RI 20", "@ R:I :20".
  const riMatch = n.match(/(?:@|on\s+)?\s*(?:r:?i\.?)\s*(\d+):?(\d{2})?/);
  if (riMatch) {
    const mins = parseIntSafe(riMatch[1]);
    const secs = parseIntSafe(riMatch[2]);
    if (mins !== null && secs !== null) {
      return mins + ":" + String(secs).padStart(2, "0");
    }
    if (mins !== null && riMatch[2] === undefined) {
      return "0:" + String(mins).padStart(2, "0");
    }
  }
  // Bare-seconds form: "R:I 20" without minutes
  const riBareSec = n.match(/(?:@|on\s+)?\s*(?:r:?i\.?)\s*(\d{1,2})\b/);
  if (riBareSec) {
    const s = parseIntSafe(riBareSec[1]);
    if (s !== null && s < 60) {
      return "0:" + String(s).padStart(2, "0");
    }
  }

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

// V0.37 (2026-08-13): per-fragment start_type, matching the LLM fragment
// shape (prototype / _llm.ts / edge / iOS 4-place sync). Values 'dive' |
// 'push' | 'wall' | null. Check wall (can contain "push") before push.
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

// Parse a rest segment: ":15 Rest", "15 seconds rest", "30 sec rest".
function parseRestSegment(text: string): number | null {
  const bareColon = text.match(/^:(\d+)\s*(?:rest)?$/i);
  if (bareColon) {
    const s = parseIntSafe(bareColon[1]);
    if (s !== null) return s;
  }
  const secRest = text.match(
    /^\d+\s*(?:seconds?|sec|minutes?|min)\s+rest$/i,
  );
  if (secRest) {
    const n = text.match(/^(\d+)/);
    if (n) {
      const v = parseIntSafe(n[1]);
      if (v !== null) {
        return /min/i.test(text) ? v * 60 : v;
      }
    }
  }
  return null;
}

// Parse composite-set fragments from parenthetical content.
function parseCompositeFragments(
  segments: string[],
  parentStroke: Stroke | null,
): Fragment[] | null {
  const fragments: Fragment[] = [];
  let order = 0;

  for (const seg of segments) {
    const trimmed = seg.trim();
    const rest = parseRestSegment(trimmed);
    if (rest !== null) {
      if (fragments.length > 0) {
        fragments[fragments.length - 1].restAfter = rest;
      }
      continue;
    }
    const rd = parseRepDist(trimmed);
    if (rd.distance === null) continue;

    const intensity = parseIntensity(trimmed);
    const stroke = parseStroke(trimmed) ?? parentStroke;
    let segNote: string | null = null;
    {
      let t = trimmed;
      t = t.replace(/\d+\s*[x\u00d7]\s*\d+\s*m*/gi, "");
      t = t.replace(/\d+(?:\.\d+)?\s*m?\b/gi, "");
      if (intensity) {
        const labelRe = new RegExp(
          intensity.label.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"),
          "gi",
        );
        t = t.replace(labelRe, "");
      }
      t = t.replace(/\bat\b/gi, "").trim();
      if (t.length > 2) segNote = t;
    }

    fragments.push({
      id: "", // placeholder — stamped in parseWithFallback
      distance: rd.distance,
      // V0.53.3 (2026-09-08, jodie-09 display fidelity): placeholder;
      // normalizeFragmentDistances overwrites this with String(distance)
      // right before serialization. Mirror of ios-native/supabase/.
      distance_label: null,
      stroke,
      intensity,
      note: segNote,
      restAfter: null,
      order: order++,
      // V0.37 (2026-08-13): per-fragment gear + start_type derived from the
      // fragment's own segment text — the pairing cost tiers key on the
      // fragment's context, not the parent repGroup's.
      gear: parseGear(trimmed),
      start_type: deriveStartType(trimmed),
    });
  }

  const swimCount = fragments.filter((f) => f.distance > 0).length;
  return swimCount >= 2 ? fragments : null;
}

function parseRepGroup(lineText: string): RepGroup | null {
  let text = lineText;
  let note: string | null = null;

  // Composite-set detection runs FIRST — before extractInlineNote,
  // because extractInlineNote would strip the "(...)" content as a note,
  // leaving just the prefix "4 x".
  let fragments: Fragment[] | null = null;
  let isComposite = /\d+\s*[x\u00d7]\s*\(/.test(text);
  // 2026-07-31: "by NN's" / "by NN" / "broken by NN" broken-swim notation.
  // "4 x 100 by 25's" = each rep broken into 100/25 = 4 segments of 25m.
  // Convert to the parenthetical composite form so the existing fragment
  // path handles it: "4 x 100 (25 / 25 / 25 / 25)".
  if (!isComposite) {
    const byMatch = text.match(/\b(?:broken\s+)?by\s+(\d+)\s*m?\s*'?s?\b/i);
    if (byMatch) {
      const segDist = parseIntSafe(byMatch[1]);
      // Get the parent distance from the prefix before "by"
      const prefix = text.substring(0, byMatch.index!).trim();
      const prefixRd = parseRepDist(prefix);
      if (segDist !== null && prefixRd.distance !== null && prefixRd.distance % segDist === 0) {
        const numSegs = prefixRd.distance / segDist;
        const slashForm = Array(numSegs).fill(segDist + "m").join(" / ");
        // Replace the "by NN's" suffix with a parenthetical composite
        text = prefix + " (" + slashForm + ")" + text.substring(byMatch.index! + byMatch[0].length);
        isComposite = true;
      }
    }
  }
  if (isComposite) {
    const compositeMatch = text.match(/\(\s*(.+?)\s*\)/);
    if (compositeMatch) {
      const inner = compositeMatch[1];
      const segments = inner
        .split(/[\/,]/)
        .map((s) => s.trim())
        .filter((s) => s.length > 0);
      const preParen = text.split("(")[0];
      const parentStroke = parseStroke(preParen);
      fragments = parseCompositeFragments(segments, parentStroke);
    }
  } else {
    const inlineNote = extractInlineNote(text);
    text = inlineNote.cleaned;
    note = inlineNote.note;
  }

  const rd = parseRepDist(text);
  if (rd.reps === null && rd.distance === null && fragments === null) {
    return null;
  }

  let reps = rd.reps;
  if (fragments !== null && reps === null) {
    const prefixReps = text.match(/(\d+)\s*[x\u00d7]\s*\(/);
    reps = prefixReps ? parseIntSafe(prefixReps[1]) : null;
  }

  const preAsText = text.match(/as[\s:]/i) ? text.split(/as[\s:]/i)[0] : text;
  const stroke = parseStroke(preAsText);
  const interval = fragments !== null ? null : parseInterval(text);
  // restInterval = true means "rest between reps" (not a send-off cycle).
  // True when:
  //   (a) no @-prefixed or on-prefixed send-off pattern is present, AND
  //   (b) the text DOES contain a Rest Interval marker (R:I, RI, etc.)
  //       OR a bare rest pattern (:NN, :NN rest)
  const hasRestMarker =
    /(?:r:?i\.?|ri)\s*:?\s*\d/i.test(text) || // R:I, R:I., RI (Swim Richmond glossary)
    /:(\d{2})\s*rest\b/i.test(text) ||             // ":15 rest"
    /(\d+)\s*s(?:ec)?\s*rest\b/i.test(text) ||      // "15s rest" / "15 sec rest"
    /\brest\s*:?\s*\d/i.test(text);                 // "rest :20" (rest keyword before value)
  const restInterval =
    interval !== null &&
    fragments === null &&
    hasRestMarker &&
    // Send-off patterns: @ N:NN or on N:NN. Exclude lines with "rest"
    // keyword so "@ :20 rest" is NOT classified as send-off.
    !/@\s*\d(?!.*\brest)/.test(text) &&
    !/@\s*:(?!.*\brest)/.test(text) &&
    !/\bon\s+\d(?!.*\brest)/.test(text);



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

    // Fallback: if as-notation was detected but produced no sub-reps
    // (e.g. "as 1.fists 2.1-arm" — drill names with no distances),
    // capture the content as a per-rep note.
    if (asMatch && subReps.length === 0) {
      const asContent = asMatch[1].trim();
      const drillParts = asContent
        .split(/\s+(?=\d+\.)/)
        .map((s) => s.replace(/^\d+\.\s*/, "").trim().replace(/[,;]+$/, "").trim())
        .filter((s) => s.length > 0);
      if (drillParts.length >= 2) {
        const drillNote = drillParts
          .map((d, i) => `Rep ${i + 1}: ${d}`)
          .join("; ");
        note = note ? `${note}; ${drillNote}` : drillNote;
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
    reps: reps ?? rd.reps,
    distance:
      fragments !== null
        ? fragments.reduce((sum, f) => sum + f.distance, 0)
        : rd.distance,
    stroke,
    interval,
    restInterval,
     intensity: intensityOverride ?? intensity ?? null,
     zoneTerm: parseZoneTerm(text),
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
    fragments,
    sourceLine: lineText,
  };
}

// Parse odd/even sub-lines
// ponytail (iter 14, 2026-07-29): support both "odd:" (colon) and
// "Odd -" (dash) separators. Coaches use both interchangeably.
function parseOddEvenBlock(
  lines: RawLine[],
  startIdx: number,
): { rep: Rep; endIdx: number } | null {
  if (startIdx >= lines.length) return null;

  const first = lines[startIdx];
  // Accept "odd: <text>" or "odd - <text>" or "odd–<text>"
  const oddMatch = first.text.match(/^odd\s*[:–-]\s*(.+)/i);
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
    // Accept "even: <text>" or "even - <text>" or "even–<text>"
    const evenMatch = line.text.match(/^even\s*[:–-]\s*(.+)/i);
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
    let roundMultiplier = 1;

    while (i < block.lines.length) {
      const line = block.lines[i];

      if (line.isBlank) {
        // Blank lines are FORMAT ONLY — do not reset the round multiplier.
        i++;
        continue;
      }

      if (isSectionHeader(line)) {
        pendingLabel = null;
        roundMultiplier = 1;
        i++;
        continue;
      }

      // Round multiplier detection
      const roundMatch =
        line.text.match(/^(\d+)\s*times?\s+through\s*:?\s*$/i) ||
        line.text.match(/^(\d+)\s+rounds?\s*:?\s*$/i) ||
        line.text.match(/^(\d+)\s*[x\u00d7]\s*(?:thru|through)\s*:?\s*$/i) ||
        line.text.match(/^(two|three|four|five|one)\s+rounds?\s*:?\s*$/i);
      if (roundMatch) {
        const wordToNum: Record<string, number> = { two: 2, three: 3, four: 4, five: 5, one: 1 };
        const captured = roundMatch[1];
        roundMultiplier = parseIntSafe(captured) ?? wordToNum[captured?.toLowerCase() ?? ""] ?? 1;
        pendingLabel = null;
        i++;
        continue;
      }
      if (/^repeat\s*(?:the\s+entire\s+round|round)?\s*\.?$/i.test(line.text) ||
          /^each\s+round\s*$/i.test(line.text)) {
        roundMultiplier = 2;
        pendingLabel = null;
        i++;
        continue;
      }

      // ponytail (iter 14, 2026-07-29): match both "odd:" and "Odd -"
      if (/^odd\s*[:–-]/i.test(line.text)) {
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

      // Multi-line odds/evens without colon separator:
      //   odds kick / evens swim
      if (/^odds?\s+/i.test(line.text) && !/^\d+\s*[x\u00d7]\s*\d+/.test(line.text)) {
        const oddText = line.text.replace(/^odds?\s+/i, "").trim();
        let evenText = "";
        let endIdx = i + 1;
        while (endIdx < block.lines.length) {
          const evLine = block.lines[endIdx];
          if (evLine.isBlank) { endIdx++; continue; }
          const evMatch = evLine.text.match(/^evens?\s+(.+)/i);
          if (evMatch) {
            evenText = evMatch[1].trim();
            endIdx++;
            break;
          }
          break;
        }
        if (evenText.length > 0) {
          const currentNs = namedSets[namedSets.length - 1];
          if (currentNs && currentNs.repGroups.length > 0) {
            const lastRg = currentNs.repGroups[currentNs.repGroups.length - 1];
            const noteText = `odds: ${oddText}; evens: ${evenText}`;
            if (!lastRg.note) {
              lastRg.note = noteText;
            } else {
              lastRg.note = lastRg.note + "; " + noteText;
            }
            lastRg.patternType = "odd_even";
          }
          pendingLabel = null;
          i = endIdx;
          continue;
        }
      }

      // Composite-set trailing description: "Each 100:" followed by
      // segment lines. Attach as fragments to the most recent rep group
      // whose distance matches the "Each N" value.
      const eachMatch = line.text.match(/^each\s+(\d+)\s*m?\s*:/i);
      if (eachMatch) {
        const eachDist = parseIntSafe(eachMatch[1]);
        const segLines: string[] = [];
        let endIdx = i + 1;
        while (endIdx < block.lines.length) {
          const segLine = block.lines[endIdx];
          const segText = segLine.text.trim();
          if (segLine.isBlank) { endIdx++; continue; }
          if (isSectionHeader(segLine)) break;
          if (/\d+\s*[x\u00d7]\s*\d+/.test(segText)) break;
          if (/^each\s+\d+/i.test(segText)) break;
          segLines.push(segText);
          endIdx++;
        }
        if (segLines.length > 0 && eachDist !== null) {
          const joined = segLines.join(" / ");
          const segments = joined
            .split(/[\/]/)
            .map((s) => s.trim())
            .filter((s) => s.length > 0);
          const frags = parseCompositeFragments(segments, null);
          if (frags !== null && frags.length >= 2) {
            for (let si = namedSets.length - 1; si >= 0; si--) {
              const ns = namedSets[si];
              for (let ri = ns.repGroups.length - 1; ri >= 0; ri--) {
                const rg = ns.repGroups[ri];
                if (rg.distance === eachDist && !rg.fragments) {
                  rg.fragments = frags;
                  break;
                }
              }
            }
          }
          pendingLabel = null;
          i = endIdx;
          continue;
        }
      }

      // Numbered per-rep instructions: "1. 50 free breathe 3 / 50 free catch up drill"
      // These describe how each rep of the PREVIOUS set should be performed.
      // Attach as a structured note AND build a pattern array when the
      // numbered lines have slash-separated segments summing to the parent
      // rep distance (composite per-rep rotation).
      const numberedMatch = line.text.match(/^(\d+)\.\s+(.+)/);
      if (numberedMatch && !/\d+\s*[x×]\s*\d+/.test(line.text)) {
        const repNum = numberedMatch[1];
        const repDesc = numberedMatch[2].trim();
        for (let si = namedSets.length - 1; si >= 0; si--) {
          const ns = namedSets[si];
          if (ns.repGroups.length > 0) {
            const lastRg = ns.repGroups[ns.repGroups.length - 1];
            // Existing note-based behavior (always)
            const prefix = `Rep ${repNum}: ${repDesc}`;
            if (!lastRg.note) {
              lastRg.note = prefix;
            } else {
              lastRg.note = lastRg.note + "; " + prefix;
            }
            // New: collect into a temporary batch for pattern building.
            // The batch is cleared when a non-numbered line is seen (handled
            // after the main loop). For now, stash on a module-level array.
            // Use the rg object itself as the carrier — store the batch on
            // a WeakMap-like pattern using the rg's pattern array.
            if (!Array.isArray((lastRg as any).__numberedBatch)) {
              (lastRg as any).__numberedBatch = [];
            }
            (lastRg as any).__numberedBatch.push({ num: repNum, desc: repDesc });
            break;
          }
        }
        pendingLabel = null;
        i++;
        continue;
      }

      // ponytail (iter 14, 2026-07-29): instruction-line guard.
      // Runs BEFORE extractLabel to catch "Build each 50" (which
      // extractLabel would split into label="Build each" rest="50",
      // creating a false set). Uses line.text directly.
      const lineText = line.text.trim();
      const isInstructionLine =
        !THREE_MT_RE.test(lineText) && // V0.38: a 3MT line is a SET, never an instruction
        !/\d+\s*[x×]\s*\d+/.test(lineText) && // no NxM pattern
        // ponytail (2026-08-11): composite-set openers (N x (...) ) are
        // SET LINES, never instructions. Without this, "4 x (75 fast /
        // 25 easy)" matches Pattern 2 (leading digit ≤25 + fast/easy
        // coaching words) and the whole set is swallowed as a note.
        !/\d+\s*[x×]\s*\(/.test(lineText) &&
        (
          // Pattern 1: starts with a coaching word → instruction
          /^\s*(?:build|descend|hold|focus|maintain|strong|smooth|underwater|breakout|streamline|dolphin|easy|fast|slow|controlled|relaxed|perfect|race|quality|explosive|turn|push|dive|kick|drill|scull|breathe|negative|positive|long|short|tall|high|low|tight|loose|steady|consistent|gradual|progressive|activation|recovery)\b/i.test(lineText) ||
          // Pattern 2: starts with "N m" where N ≤ 25 + coaching words
          (/^(\d+)\s*m?\b/.test(lineText) &&
            (parseIntSafe(lineText.match(/^(\d+)\s*m?\b/)?.[1] ?? "") ?? 999) <= 25 &&
            /\b(?:breakout|underwater|uw|streamline|dolphin|kick|turn|wall|drill|scull|breathe|smooth|build|fast|easy|slow|strong|controlled|relaxed|skill|recovery|effort)\b/i.test(lineText))
        );

      if (isInstructionLine) {
        for (let si = namedSets.length - 1; si >= 0; si--) {
          const ns = namedSets[si];
          if (ns.repGroups.length > 0) {
            const lastRg = ns.repGroups[ns.repGroups.length - 1];
            if (!lastRg.note) {
              lastRg.note = lineText;
            } else {
              lastRg.note = lastRg.note + "; " + lineText;
            }
            break;
          }
        }
        pendingLabel = null;
        i++;
        continue;
      }

      // Time-based sets: "Free - 8:00 kick on side, 1 shoulder out"
      const timeSetMatch = line.text.match(
        /^(free|back|breast|fly|im|choice)\s*[-\u2013]\s*(\d+):(\d{2})\s+(.+)/i,
      );
      if (timeSetMatch) {
        const stroke = parseStroke(timeSetMatch[1]);
        const duration = `${timeSetMatch[2]}:${timeSetMatch[3]}`;
        const activity = timeSetMatch[4].trim();
        const namedSet: NamedSet = {
          label: null,
          note: null,
          repGroups: [],
        };
        namedSet.repGroups.push({
          reps: 1,
          distance: null,
          stroke,
          interval: duration,
          restInterval: false,
           intensity: null,
           zoneTerm: null,
           pacing: null,
          pattern: [],
          patternType: null,
          connectors: [],
          note: activity.length > 0 ? activity : null,
          gear: null,
          gearOptional: false,
          descend: null,
          details: null,
          dive: false,
          suit: false,
          ambiguousTerm: null,
          defaultRpe: null,
          fragments: null,
          sourceLine: line.text,
        });
        namedSets.push(namedSet);
        pendingLabel = null;
        i++;
        continue;
      }

      // Per-rep variant instructions: slash-separated segments summing
      // to the parent distance. Attach as note to previous rep group.
      if (line.text.includes("/")) {
        const lastNs = namedSets[namedSets.length - 1];
        if (lastNs && lastNs.repGroups.length > 0) {
          const lastRg = lastNs.repGroups[lastNs.repGroups.length - 1];
          const parentDist = lastRg.distance;
          if (parentDist !== null && lastRg.reps && lastRg.reps > 1) {
            const segments = line.text.split("/").map((s) => s.trim());
            const segDists = segments
              .map((s) => {
                const m = s.match(/(\d+)\s*m?\b/);
                return m ? parseIntSafe(m[1]) : null;
              })
              .filter((d): d is number => d !== null);
            const segSum = segDists.reduce((a, b) => a + b, 0);
            if (segSum === parentDist && segDists.length >= 2) {
              const noteText = line.text.trim();
              if (!lastRg.note) {
                lastRg.note = noteText;
              } else if (!lastRg.note.includes(noteText)) {
                lastRg.note = lastRg.note + "; " + noteText;
              }
              pendingLabel = null;
              i++;
              continue;
            }
          }
        }
      }

      // Per-rep variant instructions: slash-separated segments summing
      // to the parent distance. Attach as note to previous rep group.
      if (line.text.includes("/")) {
        const lastNs = namedSets[namedSets.length - 1];
        if (lastNs && lastNs.repGroups.length > 0) {
          const lastRg = lastNs.repGroups[lastNs.repGroups.length - 1];
          const parentDist = lastRg.distance;
          if (parentDist !== null && lastRg.reps && lastRg.reps > 1) {
            const segments = line.text.split("/").map((s) => s.trim());
            const segDists = segments
              .map((s) => { const m = s.match(/(\d+)\s*m?\b/); return m ? parseIntSafe(m[1]) : null; })
              .filter((d): d is number => d !== null);
            const segSum = segDists.reduce((a, b) => a + b, 0);
            if (segSum === parentDist && segDists.length >= 2) {
              const noteText = line.text.trim();
              if (!lastRg.note) { lastRg.note = noteText; }
              else if (!lastRg.note.includes(noteText)) { lastRg.note = lastRg.note + "; " + noteText; }
              pendingLabel = null;
              i++;
              continue;
            }
          }
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

      // (iter 14 instruction-line guard moved BEFORE extractLabel above)

      // V0.38 (2026-08-15): 3-minute all-out test short-circuit.
      // Mirrors the Swift parser. A bare "3MT" line carries no
      // reps×distance structure, so parseRepDist returns nil and
      // the line would be dropped (the bug class this fixes).
      // When the 3MT marker is present and parseRepDist yields
      // nothing, inject a synthetic "1 x 25" rep group with the
      // 3MT intensity override so the line emits as a 3MT set.
      // The stroke word (e.g. "free" in "3MT free") parses from
      // the original rest text and is preserved on the rg.
      const is3MTLine = THREE_MT_RE.test(rest);

      const rd = parseRepDist(rest);
      const isCompositeSet = /\d+\s*[x\u00d7]\s*\(/.test(rest);
      if (rd.reps === null && rd.distance === null && !isCompositeSet && !is3MTLine) {
        // ponytail (autoresearch iter 4, 2026-07-19): a bare
        // "fast for time" / "for time" / "no breath" line (no reps,
        // no distance) should be attached to the PREVIOUS rep
        // group as a note. Without this, the "1 x 400 FBFB" set
        // on one line and "fast for time" on the next lose the
        // note attribution.
        const freeTextNote = parseFreeTextNote(line.text);

        // ponytail (iter 14, 2026-07-29): BROADER trailing-comment
        // attachment. If a line has no set pattern, isn't a section
        // header, and looks like a short instruction (≤ 80 chars,
        // not a paragraph), attach it as a note to the previous rg.
        // This catches "Build each 50", "Strong streamline off every
        // wall", "Underwater dolphin to 10-15m", "Focus on catch", etc.
        const trimmed = line.text.trim();
        // 2026-07-31: Skip the short-instruction guard when the line
        // contains distance-stroke patterns (e.g. "400 kick ... 100 free").
        // Those are multi-set lines, not trailing instructions.
        const hasSetPattern = /\b\d+\s*m?\s+(?:free|back|breast|fly|im|kick|pull|choice|swim|drill|form)\b/i.test(trimmed);
        const isShortInstruction =
          trimmed.length > 0 &&
          trimmed.length <= 80 &&
          !/^[A-Z][A-Z0-9 \-/&]+$/.test(trimmed) && // not ALL-CAPS header
          !hasSetPattern && // not a multi-set line
          /[a-z]/.test(trimmed); // has lowercase (real text)

        if (freeTextNote || isShortInstruction) {
          const noteText = freeTextNote ?? trimmed;
          for (let si = namedSets.length - 1; si >= 0; si--) {
            const ns = namedSets[si];
            if (ns.repGroups.length > 0) {
              const lastRg = ns.repGroups[ns.repGroups.length - 1];
              if (!lastRg.note) {
                lastRg.note = noteText;
              } else {
                // Append to existing note with separator
                lastRg.note = lastRg.note + "; " + noteText;
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

      // V0.38 (2026-08-15): 3MT short-circuit. When the line carries
      // a 3MT marker but no reps/distance structure, prepend a
      // synthetic "1 x 25" so parseRepGroup emits reps=1, distance=25.
      // parseIntensity sees the 3MT marker in the rewritten rest and
      // returns { type: "3mt", label: "3-minute all-out" } — the rest
      // of the pipeline is then a normal set parse. Stroke parses
      // from the original text (e.g. "free" survives in
      // "1 x 25 3MT free").
      let parsedRest = rest;
      if (is3MTLine && (rd.reps === null || rd.distance === null)) {
        parsedRest = `1 x 25 ${rest}`.trim();
      }

      const rg = parseRepGroup(parsedRest);
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
        // Apply round multiplier to reps
        if (roundMultiplier > 1 && rg.reps !== null) {
          rg.reps = rg.reps * roundMultiplier;
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

        // 2026-07-31: Multi-set detection on one line. Two paths:
        //   (a) Slash-separated: "400 Swim / 200 Pull / 100 Kick"
        //   (b) Space-separated with `<N> m? <STROKE>` patterns:
        //       "400 kick for body/head position 100 free 100 back"
        // Don't split inside "as N.fists/swim" notation.
        const isAsNotation = /\bas\s/i.test(line.text);
        if (!isAsNotation) {
          // (a) Slash-separated — only if the slash is surrounded by
          // spaces (a set separator, not part of a compound word like
          // "body/head") and each side has a distance-stroke pattern.
          let slashProduced = false;
          if (/\s\/\s|\s\/$|^\/\s/.test(line.text)) {
            const slashSegments = line.text
              .split("/")
              .map((s) => s.trim())
              .filter((s) => /\b\d+\s*m?\s+(?:free|back|breast|fly|im|kick|pull|choice|swim|drill|form)\b/i.test(s));
            if (slashSegments.length > 1) {
              slashProduced = true;
              for (let si = 1; si < slashSegments.length; si++) {
                const subRep = parseRepGroup(slashSegments[si]);
                if (subRep) {
                  if (!subRep.interval) subRep.interval = rg.interval;
                  if (!subRep.intensity) subRep.intensity = rg.intensity;
                  namedSet.repGroups.push(subRep);
                }
              }
            }
          }
          // (b) Space-separated distance-stroke patterns — only if slash
          // path didn't already produce multiple segments.
          if (!slashProduced) {
            const STROKE_RE = /(?:free|back|breast|fly|im|kick|pull|choice|form|swim|kick|drill)/i;
            const allSetMatches = [...line.text.matchAll(new RegExp("\\b(\\d+)\\s*m?\\s+(?=" + STROKE_RE.source + ")", "gi"))];
            if (allSetMatches.length > 1) {
              for (let mi = 1; mi < allSetMatches.length; mi++) {
                const m = allSetMatches[mi];
                let subText = line.text.slice(m.index!);
                // Stop at next comma, slash, or " - "
                const stopIdx = subText.search(/\s*[,/]|\s+-\s+/);
                if (stopIdx > 0) subText = subText.slice(0, stopIdx);
                const subRep = parseRepGroup(subText);
                if (subRep) {
                  if (!subRep.interval) subRep.interval = rg.interval;
                  if (!subRep.intensity) subRep.intensity = rg.intensity;
                  namedSet.repGroups.push(subRep);
                }
              }
            }
          }
        }

        // ponytail (iter 12, 2026-07-28): comma-separated multi-set

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

    // Post-processing: convert numbered-instruction batches into structured
    // pattern arrays. A batch is "valid" when each item's slash-separated
    // segments sum to the parent rep group's distance (composite structure).
    for (const ns of namedSets) {
      for (const rg of ns.repGroups) {
        const batch = (rg as any).__numberedBatch as
          | Array<{ num: string; desc: string }>
          | undefined;
        if (!batch || batch.length < 2) continue;
        if (rg.distance === null || rg.distance === undefined) continue;
        const patternItems: any[] = [];
        let allValid = true;
        for (const item of batch) {
          // Parse each numbered line as a composite sub-rep
          const parts = item.desc.split("/").map((s) => s.trim());
          const segDists = parts
            .map((s) => {
              const m = s.match(/(\d+)\s*m?\b/);
              return m ? parseIntSafe(m[1]) : null;
            })
            .filter((d): d is number => d !== null);
          const segSum = segDists.reduce((a, b) => a + b, 0);
          if (segSum !== rg.distance || segDists.length < 2) {
            allValid = false;
            break;
          }
          // Build a "simple" pattern item per segment
          for (let i = 0; i < parts.length; i++) {
            const part = parts[i];
            const meters = segDists[i];
            const stroke = parseStroke(part);
            patternItems.push({
              type: "simple",
              meters,
              stroke,
              note: part.replace(/\d+\s*m?\b/, "").trim() || undefined,
            });
          }
        }
        if (allValid && patternItems.length > 0) {
          rg.pattern = patternItems;
          rg.patternType = "simple";
        }
        // Clean up the temp batch field
        delete (rg as any).__numberedBatch;
      }
    }

    return {
      title: block.title,
      namedSets,
    };
  });

  return { title: null, sections };
}

// ─── Handler ───────────────────────────────────────────────────────────────

// V0.38 (2026-08-15): workout-level 3MT flag. True when any repGroup
// carries the 3mt intensity — the app uses this to set workouts.session_type
// when saving. Handles BOTH response shapes: the regex parser's nested
// `intensity: {type}` and the LLM path's flat `intensity_type` field
// (ValidatedRepGroup is structurally cast onto Workout).
export function workoutIs3MT(workout: Workout): boolean {
  for (const section of workout.sections) {
    for (const ns of section.namedSets) {
      for (const rg of ns.repGroups) {
        const nested = (rg as unknown as { intensity?: { type?: string } }).intensity;
        if (nested && nested.type === "3mt") return true;
        const flat = (rg as unknown as { intensity_type?: string }).intensity_type;
        if (flat === "3mt") return true;
      }
    }
  }
  return false;
}

// V0.35 (2026-08-12): deterministic fragment ids. Runs on the final
// tree so BOTH paths (regex parseCompositeFragments and LLM-validated
// output) get stamped. id = "frag-" + sha1(sourceLine + ":" + orderIndex)
// truncated to 12 hex chars. Re-parsing unchanged text yields identical
// ids — replaceSetsForWorkout deletes + re-inserts sets, so previously
// recorded times keyed by fragment_id survive a re-save.
function stampFragmentIds(workout: Workout): Workout {
  for (const section of workout.sections) {
    for (const ns of section.namedSets) {
      for (const rg of ns.repGroups) {
        if (!rg.fragments || rg.fragments.length === 0) continue;
        const sourceLine = rg.sourceLine ?? "";
        // Array index = fragment order within the group (regex fragments
        // carry `order` == index; LLM fragments have no order field, so
        // the index is the only stable ordering both paths share).
        for (let i = 0; i < rg.fragments.length; i++) {
          rg.fragments[i].id = "frag-" + sha1Hex(sourceLine + ":" + i).slice(0, 12);
        }
      }
    }
  }
  return workout;
}

// Synchronous SHA-1 (pure TS) — deterministic across Deno (edge function)
// and Node (bench harness). crypto.subtle.digest is async-only in both,
// so a sync implementation keeps the stamp pass trivial.
function sha1Hex(input: string): string {
  const bytes = new TextEncoder().encode(input);
  const ml = bytes.length * 8;
  const padded = new Uint8Array((((bytes.length + 8) >> 6) + 1) * 64);
  padded.set(bytes);
  padded[bytes.length] = 0x80;
  const dv = new DataView(padded.buffer);
  dv.setUint32(padded.length - 4, ml >>> 0);
  dv.setUint32(padded.length - 8, Math.floor(ml / 0x100000000));

  let h0 = 0x67452301, h1 = 0xefcdab89, h2 = 0x98badcfe, h3 = 0x10325476, h4 = 0xc3d2e1f0;
  const w = new Uint32Array(80);
  for (let i = 0; i < padded.length; i += 64) {
    for (let j = 0; j < 16; j++) w[j] = dv.getUint32(i + j * 4);
    for (let j = 16; j < 80; j++) {
      const n = w[j - 3] ^ w[j - 8] ^ w[j - 14] ^ w[j - 16];
      w[j] = (n << 1) | (n >>> 31);
    }
    let a = h0, b = h1, c = h2, d = h3, e = h4;
    for (let j = 0; j < 80; j++) {
      let f: number, k: number;
      if (j < 20) { f = (b & c) | (~b & d); k = 0x5a827999; }
      else if (j < 40) { f = b ^ c ^ d; k = 0x6ed9eba1; }
      else if (j < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8f1bbcdc; }
      else { f = b ^ c ^ d; k = 0xca62c1d6; }
      const temp = (((a << 5) | (a >>> 27)) + f + e + k + w[j]) >>> 0;
      e = d; d = c; c = (b << 30) | (b >>> 2); b = a; a = temp;
    }
    h0 = (h0 + a) >>> 0; h1 = (h1 + b) >>> 0; h2 = (h2 + c) >>> 0;
    h3 = (h3 + d) >>> 0; h4 = (h4 + e) >>> 0;
  }
  const hex = (n: number) => n.toString(16).padStart(8, "0");
  return hex(h0) + hex(h1) + hex(h2) + hex(h3) + hex(h4);
}

// V0.36 (2026-08-13): degraded flag. When the LLM path fails, the
// fallback response carries { degraded: true, degradedReason } so the
// app can surface "preview may be incomplete" instead of silently
// showing the regex parse. Success omits the flag (app treats missing
// as false). Reasons: llm_rate_limited (429), llm_error (5xx/network/
// validation), llm_empty (LLM returned 0 repGroups).
type DegradedReason = "llm_rate_limited" | "llm_error" | "llm_empty";

interface ParseResult extends Workout {
  degraded?: boolean;
  degradedReason?: DegradedReason;
  // V0.47 (2026-08-22): see _llm.ts Workout.unmapped_terms. Always
  // present in the edge response (defaults to []) so iOS can decode it
  // without decodeIfPresent gymnastics — iOS treats missing as empty.
  unmapped_terms: string[];
}

// V0.47 (2026-08-22): PROGRESSION_TERMS_RE + extractUnmappedTerms now
// live in _dialect-detector.ts (pure, runtime-agnostic). Imported at
// the top of this file.

// ponytail: LLM-first, regex-fallback. Cost on the LLM path is ~1.5-3s
// for MiniMax-M3 warm. Cost on the fallback path is the existing ~50ms
// parseWorkoutV2. We always check the LLM result for a non-empty tree
// before returning it — MiniMax returning 200 with 0 repGroups counts
// as junk.
async function parseWithFallback(
  workoutText: string,
  coachVocabulary: ReadonlyArray<CoachVocabularyEntry> = [],
): Promise<ParseResult> {
  // V0.47 (2026-08-22): defensive union of whatever the LLM reported
  // plus whatever our local detector catches. The LLM sometimes
  // forgets — running both gates guarantees we never miss a Tier-1
  // word the coach actually wrote.
  //
  // V0.52.1 (2026-09-08): pre-LLM localHits is a safety net — the
  // LLM-side scrub (parseWithLLM → scrubUnmappedTerms) is
  // context-aware (drops `descend` when the rg/fragments carry
  // intensity.type="descend"). When the LLM result is honored, we
  // re-run local detection WITH the parsed response so the same
  // context-aware suppression applies. Without this, localHits
  // always re-adds `descend` even when the LLM correctly dropped it.
  const localHitsPre = extractUnmappedTerms(workoutText, coachVocabulary);
  const mergeUnmapped = (
    llmTerms: string[] | undefined,
    parsedForContext?: { sections?: ReadonlyArray<{ namedSets?: ReadonlyArray<{ repGroups?: ReadonlyArray<Record<string, unknown>> }>; repGroups?: ReadonlyArray<Record<string, unknown>> }> } | null,
  ): string[] => {
    const set = new Set<string>();
    // V0.52.1 (2026-09-08): when we have the parsed response, re-run
    // local detection with it so context-aware suppression kicks in.
    // Without this, raw localHitsPre re-adds `descend` even when the
    // LLM scrub correctly dropped it.
    if (parsedForContext) {
      const contextAware = extractUnmappedTerms(workoutText, coachVocabulary, parsedForContext);
      for (const t of contextAware) set.add(t);
    } else {
      for (const t of localHitsPre) set.add(t);
    }
    for (const t of llmTerms || []) {
      const v = String(t).toLowerCase().trim();
      if (v.length > 0) set.add(v);
    }
    return [...set];
  };

  try {
    // ponytail: structural cast. The shapes are identical at runtime;
    // the LSP can't unify them across the module boundary without
    // exporting Workout from _llm.ts (which would couple them).
    const llmResult = await parseWithLLM(workoutText, coachVocabulary) as unknown as Workout;
    const totalRgs = llmResult.sections.reduce(
      (acc, s) => acc + s.namedSets.reduce((a, ns) => a + ns.repGroups.length, 0),
      0
    );
    if (totalRgs > 0) {
      const stamped = stampFragmentIds(llmResult);
      return {
        ...stamped,
        // V0.52.1 (2026-09-08): pass the LLM's parsed response so the
        // context-aware local detector suppresses `descend` (and other
        // progression terms) when the rg/fragments already carry them.
        unmapped_terms: mergeUnmapped(llmResult.unmapped_terms, llmResult),
      };
    }
    console.error(`[parse] LLM returned 0 repGroups, falling back to regex`);
    const fallback = stampFragmentIds(parseWorkoutV2(workoutText));
    return {
      ...fallback,
      degraded: true,
      degradedReason: "llm_empty",
      // V0.47 (2026-08-22): regex fallback never generates unmapped
      // terms. The iOS card renders "no new terms" on a degraded parse.
      unmapped_terms: [],
    };
  } catch (err) {
    const status = err instanceof LLMError ? err.status : 0;
    const reason: DegradedReason = status === 429 ? "llm_rate_limited" : "llm_error";
    console.error(`[parse] LLM failed, falling back to regex:`, err instanceof Error ? err.message : err);
    const fallback = stampFragmentIds(parseWorkoutV2(workoutText));
    return {
      ...fallback,
      degraded: true,
      degradedReason: reason,
      unmapped_terms: [],
    };
  }
}

serve(async (req) => {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    });
  }

  try {
    const { workoutText } = await req.json();

    if (!workoutText || typeof workoutText !== "string") {
      return new Response(
        JSON.stringify({ error: "workoutText is required" }),
        {
          status: 400,
          headers: { "Content-Type": "application/json" },
        },
      );
    }

    // V0.47 (2026-08-22): fetch this coach's `coach_vocabulary` rows so
    // we can (a) inject the per-coach context block into the LLM prompt
    // and (b) tell iOS which Tier-1 terms in this workout still need a
    // mapping (unmapped_terms). We forward the request's Authorization
    // header so the same JWT that lets the coach hit this function also
    // RLS-scopes the vocabulary select to their rows. If the header is
    // missing (CLI / smoke tests), vocabulary defaults to [] — iOS
    // gets an unmapped_terms list populated from local detection.
    const coachVocabulary = await loadCoachVocabulary(req);

    // ponytail: LLM-first with regex fallback. LLM handles the failure
    // modes the regex structurally can't (composite parens, numbered
    // sub-items, ditto marks, round multipliers, input shape variance).
    // If MiniMax is down/rate-limited/junk, parseWorkoutV2 catches it
    // and the degraded flag tells the app the preview may be incomplete.
    const parsed = await parseWithFallback(workoutText, coachVocabulary);

    // V0.38 (2026-08-15): stamp the workout-level session type so the app
    // knows to route the 3MT timing flow. Additive top-level field — old
    // clients ignore it; Swift decodes it via decodeIfPresent in V0.38.
    //
    // ponytail (2026-09-08): normalizeFragmentDistances runs on the FINAL
    // tree right before serialization. The LLM (and regex fallback) can
    // emit half-pool fragment distances (12.5, 37.5, 62.5, 87.5) when the
    // coach writes "12.5 fast / 12.5 easy" inside a 25m rep. iOS's
    // ParsedFragment.distance is typed `Int?` and Swift's JSONDecoder
    // throws DecodingError.dataCorrupted on a fractional number — the
    // exact error Nathan hit on Jodie's threshold workout. The helper
    // rounds each fragment.distance to the nearest integer via
    // Math.round (12.5 → 13, 37.5 → 38) without touching the parent
    // repGroup.distance (always int), the sourceLine (preserves the
    // coach's exact wording), or non-composite repGroups (no fragments).
    // Tests in scripts/parser-bench/decimal-distance-fix.test.ts.
    const normalized = normalizeFragmentDistances(parsed);
    const response = {
      ...normalized,
      session_type: workoutIs3MT(normalized) ? "3mt" : "training",
    };

    return new Response(JSON.stringify(response), {
      status: 200,
      headers: {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*",
      },
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : "Parse error";
    return new Response(JSON.stringify({ error: `Parse failed: ${message}` }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});

// V0.47 (2026-08-22): load this coach's vocabulary rows. Pure REST
// against PostgREST so RLS does the access control — the JWT in the
// request header scopes the select to the authenticated user. Any
// fetch / network error returns [] so a Supabase blip doesn't kill the
// parse path (the LLM still works without the context block).
async function loadCoachVocabulary(req: Request): Promise<CoachVocabularyEntry[]> {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const authHeader = req.headers.get("Authorization");
  if (!supabaseUrl || !authHeader) return [];

  try {
    const url = `${supabaseUrl}/rest/v1/coach_vocabulary?select=user_term,rpe_low,rpe_high&order=user_term`;
    const resp = await fetch(url, {
      headers: {
        "Authorization": authHeader,
        "apikey": Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      },
    });
    if (!resp.ok) {
      console.error(`[parse] coach_vocabulary fetch failed: ${resp.status}`);
      return [];
    }
    const rows = await resp.json();
    if (!Array.isArray(rows)) return [];
    return rows
      .filter((r): r is { user_term: unknown; rpe_low: unknown; rpe_high: unknown } =>
        r && typeof r === "object" &&
        typeof r.user_term === "string" &&
        typeof r.rpe_low === "number" &&
        typeof r.rpe_high === "number"
      )
      .map((r) => ({
        user_term: r.user_term,
        rpe_low: r.rpe_low,
        rpe_high: r.rpe_high,
      }));
  } catch (err) {
    console.error(`[parse] coach_vocabulary fetch threw:`, err instanceof Error ? err.message : err);
    return [];
  }
}
