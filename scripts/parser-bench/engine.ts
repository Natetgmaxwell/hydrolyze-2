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

const WORD_NUMBERS: Record<string, number> = {
  one: 1, two: 2, three: 3, four: 4, five: 5, six: 6, seven: 7,
  eight: 8, nine: 9, ten: 10, eleven: 11, twelve: 12, thirteen: 13,
  fourteen: 14, fifteen: 15, sixteen: 16, seventeen: 17, eighteen: 18,
  nineteen: 19, twenty: 20,
};
const SWIM_DISTANCES = new Set<number>([
  15, 25, 50, 75, 100, 125, 150, 200, 300, 400, 500, 600, 800, 1000, 1500, 1650,
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
];

const GEAR_PATTERNS: Array<[RegExp, string]> = [
  [/\bfins\b/i, "fins"],
  [/\bflippers\b/i, "fins"],
  [/\bpaddles?\b/i, "paddles"],
  // ponytail (opus-1, 2026-07-19): consolidate pull_buoy / buoy into
  // a single match. The previous "buoy" fallback matched "pull buoy"
  // twice (once via the pull[\s-]?buoy pattern, once via bare buoy).
  [/\b(?:pull[\s-]?buoy|buoy)\b/i, "pull_buoy"],
  [/\bkickboard\b/i, "kickboard"],
  // ponytail (opus-1): consolidate kick\s*board into the main
  // kickboard match to avoid duplicate matches.
  [/\bkick\s*board\b/i, "kickboard"],
  [/\bdrag\s*suit\b/i, "dragSuit"],
  // ponytail (opus-1): snorkel (a common gear for breathing drills).
  [/\bsnorkel\b/i, "snorkel"],
];

// ─── Helpers ───────────────────────────────────────────────────────────────────

function normalize(text: string): string {
  let out = text.toLowerCase().trim();
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
  out = out.replace(/(\d+)\.(\d{2})\b/g, "$1:$2");
  out = out.replace(/–/g, "-");
  return out;
}

function isKnownDistance(n: number): boolean {
  return SWIM_DISTANCES.has(n);
}

function parseIntSafe(s: string): number | null {
  const n = parseInt(s, 10);
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
    .replace(/\*\*([^*]+)\*\*/g, "$1")
    .replace(/__([^_]+)__/g, "$1")
    .replace(/(?<!\*)\*(?!\*)([^*]+)\*(?!\*)/g, "$1")
    .replace(/(?<!_)_(?!_)([^_]+)_(?!_)/g, "$1");
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
  const titleCased = meaningfulWords.every(
    (w) =>
      /^[A-Z0-9\d,/:]+$/.test(w) ||
      (w[0] === w[0].toUpperCase() && !strokeWords.has(w.toLowerCase())),
  );
  if (titleCased && meaningfulWords.length <= 8) return true;
  return false;
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
  // ponytail (autoresearch iter 4, 2026-07-19): no set pattern
  // in the line. The previous behavior returned { label: text, rest: "" }
  // which funneled every plain-text line into the "label-only" branch
  // (and the free-text note branch never fired). Return the line as
  // 'rest' with an empty label so the new free-text-note attachment
  // can pick it up.
  if (setIdx === -1) {
    return { label: "", rest: text };
  }
  return { label: text, rest: "" };
}

function parseRepDist(raw: string): {
  reps: number | null;
  distance: number | null;
} {
  const n = normalize(raw);
  const m = n.match(/(\d+)\s*[x×]\s*(\d+)/);
  if (m) {
    const a = parseIntSafe(m[1]);
    const b = parseIntSafe(m[2]);
    if (a !== null && b !== null) {
      if (isKnownDistance(b)) return { reps: a, distance: b };
      if (isKnownDistance(a)) return { reps: b, distance: a };
      return { reps: Math.min(a, b), distance: Math.max(a, b) };
    }
  }
  const solo = n.match(/^(\d+)\s*/);
  if (solo) {
    const d = parseIntSafe(solo[1]);
    if (d !== null && isKnownDistance(d)) return { reps: 1, distance: d };
  }
  return { reps: null, distance: null };
}

// ─── Pass 4: Intensity ─────────────────────────────────────────────────────────

function parseIntensity(raw: string): ParsedIntensity | null {
  const n = normalize(raw);

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

  const paceMatch = n.match(/(?:at|on|@)\s*(\d+)\s*m?\s*(?:pace|effort)/);
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
  const colonMatch = n.match(
    /(?:on\s+)?(\d+):(\d{2})(?:\s+(?:interval|rest|i\/?)?)?/,
  );
  if (colonMatch) return `${colonMatch[1]}:${colonMatch[2]}`;
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
  // ponytail (opus-1, 2026-07-19): dedup detected gear. The
  // GEAR_PATTERNS array may have multiple regexes that match the
  // same text (e.g. "kickboard" and "kick\s*board" both match
  // "kickboard"). Without dedup, gear: ["kickboard","kickboard"].
  const detected: string[] = [];
  for (const [re, gear] of GEAR_PATTERNS) {
    if (re.test(text) && !detected.includes(gear)) detected.push(gear);
  }
  return detected.length > 0 ? detected : null;
}

// ─── Inline note extraction ──────────────────────────────────────────────────

function extractInlineNote(text: string): {
  cleaned: string;
  note: string | null;
} {
  // First check for parenthetical notes like "(focus on form)"
  const paren = text.match(/^(.+?)\s*\(([^)]+)\)\s*$/);
  if (paren) {
    return { cleaned: paren[1].trim(), note: paren[2].trim() };
  }
  // ponytail (autoresearch iter 3, 2026-07-19): also catch
  // trailing natural-language notes like "fast for time",
  // "for time", "as fast as possible", "descend 1-4", "no breath",
  // "kick drill on board". These come AFTER the set definition
  // (reps, distance, stroke, interval) and aren't (parenthesized).
  // Heuristic: a trailing token sequence of 2+ words that doesn't
  // start with a known stroke word, gear word, or intensity word.
  //
  // Examples:
  //   "4 x 50 free @ 1:00 fast for time"          -> note="fast for time"
  //   "1 x 400 FBFB fast for time"                -> note="fast for time"
  //   "8 x 50 free descend 1-4"                   -> note="descend 1-4"
  //   "4 x 100 free no breath"                    -> note="no breath"
  //
  // We split on the FIRST set's tail (after @interval) and look for
  // any trailing 2+ word sequence.
  const trailing = text.match(
    /\b(?:fast\s+for\s+time|for\s+time|as\s+fast\s+as\s+possible|descend\s+\d+\s*(?:-|to)\s*\d+|no\s+breath(?:ing)?|kick\s+drill(?:\s+on\s+board)?|board(?:\s+kicks)?|side\s+stroke|build\s+to\s+(?:fast|sprint|max)|negative\s+split(?:\s+1st\s+half\s+faster)?|1st\s+half\s+faster|2nd\s+half\s+faster|hold[\s-]+best[\s-]+average|(?:on[\s:]+(\d+:\d+)\s*)?race\s*pace|send[\s-]+off|strong\s+finish|odds\s+build\s+even\s+fast|fast\s+from\s+the\s+gun)\b[\s.,;:@\d]*(?:\s*@?\s*\d+:\d+(?:\.\d+)?)?\s*$/i
  );
  if (trailing) {
    // ponytail (opus-2, 2026-07-19): re-attach a trailing interval
    // to cleaned so parseInterval can still find it. The trailing
    // match consumed both the note phrase AND the interval; we
    // need the interval back in cleaned.
    const trailingText = trailing[0];
const capturedInterval = trailing?.[1];  // capture group 1 (e.g. "1:30" from "on 1:30 race pace")
const intervalInTrailing = capturedInterval || trailingText.match(/\s*@?\s*(\d+:\d+(?:\.\d+)?)\s*$/)?.[1];
    const noteText = (() => {
      let n = trailingText;
      // ponytail (opus-2 fix, 2026-07-19): strip a trailing interval
      // (e.g. "send-off 1:20" -> "send-off") AND a captured interval
      // anywhere in the trailing (e.g. "on 1:30 race pace" -> "race
      // pace"). The captured-interval case has the interval in the
      // MIDDLE of trailing, not at the end.
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
  // Skip empty or label-style lines (we don't want to attach them
  // as notes to a previous set)
  if (trimmed.length === 0) return null;
  if (/^[A-Z][A-Z0-9 \-/&]+$/.test(trimmed)) return null; // ALL-CAPS header
  // Free-text note patterns:
  //   "fast for time", "for time", "as fast as possible"
  //   "descend 1-4" (or 1 to 4)
  //   "no breath" / "no breathing"
  //   "kick drill on board" / "board kicks"
  //   "side stroke"
  //   "build to fast" / "build to sprint"
  // ponytail (opus-2, 2026-07-19): expanded to cover more real
  // coach shorthand. Each pattern matches a phrase the coach
  // writes as a free-text annotation. We capture the whole line
  // as the note (so the original wording is preserved).
  if (
    /\b(?:fast\s+for\s+time|for\s+time|as\s+fast\s+as\s+possible|descend\s+\d+\s*(?:-|to)\s*\d+|no\s+breath(?:ing)?|kick\s+drill(?:\s+on\s+board)?|board(?:\s+kicks)?|side\s+stroke|build\s+to\s+(?:fast|sprint|max)|negative\s+split(?:\s+1st\s+half\s+faster)?|1st\s+half\s+faster|2nd\s+half\s+faster|hold[\s-]+best[\s-]+average|on\s+\d+:?\d*\s*race\s*pace|send[\s-]+off|strong\s+finish|odds\s+build\s+even\s+fast|fast\s+from\s+the\s+gun)\b/i.test(trimmed)
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

  const { cleaned, pacing } = extractPacing(text);
  const { cleaned: cleaned2, note } = extractMiniNote(cleaned);

  // ponytail (autoresearch iter 7, 2026-07-19): handle the
  // "as N.stroke[/swim]" notation. Examples:
  //   "1.fists/swim"   -> 1 sub-rep with stroke="Free" (fists)
  //   "2. catch up/swim" -> 1 sub-rep with stroke="Free" (catch up)
  //   "3. swim"        -> 1 sub-rep with stroke="Free"
  //   "1.kick"         -> 1 sub-rep with stroke="Kick"
  //   "2.drill"        -> 1 sub-rep with stroke="Drill"
  // The format is "<digits>.<word or phrase>[/<swim>]" where the word
  // is a stroke descriptor. We extract the FIRST "<digits>.<words>"
  // segment, then look for the next one with a separate regex.
  const firstAsMatch = cleaned2.match(/^(\d+)\.\s*(\S+(?:\s+\S+)?)(?:\/(?:swim|s))?/i);
  if (firstAsMatch) {
    const stroke = parseStroke(firstAsMatch[2]);
    if (stroke !== null) {
      // Also look for additional "<N>.stroke" tokens in the rest
      // of the chunk. They may run together without commas.
      const subReps: SubRep[] = [
        {
          type: "simple",
          meters: 0,
          stroke,
          note: undefined,
          pacing: pacing ?? undefined,
        },
      ];
      const rest = cleaned2.slice(firstAsMatch[0].length);
      const moreMatches = [...rest.matchAll(/(\d+)\.\s*(\S+(?:\s+\S+)?)(?:\/(?:swim|s))?/gi)];
      for (const m of moreMatches) {
        const s = parseStroke(m[2]);
        if (s !== null) {
          subReps.push({
            type: "simple",
            meters: 0,
            stroke: s,
            note: undefined,
            pacing: pacing ?? undefined,
          });
        }
      }
      if (subReps.length > 0) {
        return subReps;
      }
    }
  }

  const simpleMatch = cleaned2.match(/^(\d+)\s+(.+)$/);
  if (simpleMatch) {
    const meters = parseIntSafe(simpleMatch[1]);
    const stroke = parseStroke(simpleMatch[2]);
    if (meters !== null) {
      return [
        {
          type: "simple",
          meters,
          stroke: stroke ?? null,
          note,
          pacing: pacing ?? undefined,
        },
      ];
    }
  }

  const distOnly = cleaned2.trim().match(/^(\d+)\s*$/);
  if (distOnly) {
    const meters = parseIntSafe(distOnly[1]);
    if (meters !== null) {
      return [
        {
          type: "simple",
          meters,
          stroke: null,
          note: undefined,
          pacing: pacing ?? undefined,
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
    t = t.replace(/\d+\s*(?:meters?|yards?|yds?)?\b/gi, "");
    t = t.replace(
      /\b(?:free|back|breast|fly|IM|medley|freestyle|backstroke|breaststroke|butterfly|pull)\b/gi,
      "",
    );
    t = t.replace(
      /\b(?:easy|moderate|aerobic|threshold|sprint|descend|negative[\s-]?split|race[\s-]?pace|hard|maximum|vo2)\b/gi,
      "",
    );
    // ponytail (opus-1, 2026-07-19): strip detected gear words from
    // the details leftover so they don't appear twice (once in
    // rg.gear, once in rg.details). Build a single union regex from
    // all GEAR_PATTERNS' first-capture-group alternatives.
    const gearAlternatives = GEAR_PATTERNS
      .map(([re]) => {
        // Convert /(?:foo|bar)/i to (?:foo|bar)
        const src = re.source.replace(/^\(\?:/, "").replace(/\)$/, "");
        return src;
      })
      .join("|");
    t = t.replace(new RegExp("\\b(?:" + gearAlternatives + ")\\b", "gi"), "");
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
    const words = t
      .split(/\s+/)
      .filter((w) => w.length > 2 && !/^\d+$/.test(w));
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
    // Pick the first rotation match (capture group 1)
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

  // Cast SubRep[] to Rep[]
  const reps: Rep[] = subReps.map((s) => {
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
  });

  return {
    reps: rd.reps,
    distance: rd.distance,
    stroke,
    interval,
    intensity: intensityOverride ?? intensity ?? null,
    pacing,
    note,
    gear,
    gearOptional,
    descend,
    details,
    pattern: reps,
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

export function parseWorkoutV2(input: string): Workout {
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
          // Find the last rep group across all namedSets and attach
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
          // ponytail (autoresearch iter 7, 2026-07-19): bugfix — the first
          // rg was parsed from `rest` (the full line text), so its stroke
          // came from parseStroke() matching the LAST stroke word in the
          // line. Re-parse the first segment (text BEFORE match[1]) to
          // recover the correct first-set stroke, then overwrite rg.stroke.
          // Other rg fields (reps/distance/interval) are correct as-is.
          const firstStart = allSetMatches[0].index!;
          const firstEnd = allSetMatches[1].index!;
          const firstReParse = parseRepGroup(line.text.slice(firstStart, firstEnd));
          if (firstReParse && firstReParse.stroke) {
            rg.stroke = firstReParse.stroke;
          }
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

