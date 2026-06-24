/**
 * Workout Parser V2 — produces a tree: Workout → Section → NamedSet → RepGroup → Rep
 *
 * Architecture: four composable passes over the raw input text.
 * Each pass is a pure function. No mutable state machine.
 *
 * Pass 1: tokenize into raw lines (preserve blank lines as separators)
 * Pass 2: group lines into Sections (detect section headers)
 * Pass 3: within each Section, extract NamedSet labels and parse RepGroups
 * Pass 4: resolve Rep patterns (drill/swim, odd/even, simple)
 */

import type { Stroke } from "./ml-pairing";
import type {
  Workout,
  Section,
  NamedSet,
  RepGroup,
  Rep,
  ParsedIntensity,
  IntensityType,
} from "./workout-types";
import { intensityColor, intensityTypeToLevel } from "./workout-types";
import { WORD_NUMBERS, SWIM_DISTANCES } from "./constants/swim-constants";

const STROKE_PATTERNS: Array<[RegExp, Stroke]> = [
  [/\b(?:freestyle|free|crawl|front\s*crawl)\b/i, "Free"],
  [/\b(?:backstroke|back)\b/i, "Back"],
  [/\b(?:breaststroke|breast)\b/i, "Breast"],
  [/\b(?:butterfly|fly|butter)\b/i, "Fly"],
  [/\b(?:i\.?m\.?|individual\s+medley|medley)\b/i, "IM"],
  [/\b(?:form|stroke\s+(?:work|set|drill))\b/i, "Form"],
  [/\b(?:pull)\b/i, "Pull"],
  [/\b(?:choice|free[\s-]?choice)\b/i, "Choice"],
];

const GEAR_PATTERNS: Array<[RegExp, string]> = [
  [/\bfins\b/i, "fins"],
  [/\bflippers\b/i, "fins"],
  [/\bpaddles?\b/i, "paddles"],
  [/\bpull[\s-]?buoy\b/i, "pull_buoy"],
  [/\bbuoy\b(?!\s*rate)/i, "pull_buoy"],
  [/\bkickboard\b/i, "kickboard"],
  [/\bkick\s*board\b/i, "kickboard"],
  [/\bdrag\s*suit\b/i, "dragSuit"],
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
  // Normalize dashes
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
  text: string; // original casing, trimmed
  index: number; // position in original input
  isBlank: boolean;
}

function tokenize(input: string): RawLine[] {
  const lines = input.split("\n");
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
  // Short line (≤4 words), title-cased or all-caps, no digits, often standalone
  const words = t.split(/\s+/);
  if (words.length > 4) return false;
  if (/\d/.test(t)) return false;
  // Must not look like a set line (no reps notation)
  if (/\d+\s*[x×]\s*\d+/.test(t)) return false;
  // Must not look like an inline set (no leading number)
  if (/^\d+\s/.test(t)) return false;
  // Lines with dashes are named-set descriptions (e.g. "Main - Sprint"), not section headers
  if (/[–—-]/.test(t)) return false;
  // Match known header or title-case heuristic
  if (SECTION_HEADERS.has(t)) return true;
  // Title-case: each word capitalized, not a known stroke
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
  ]);
  if (
    words.every(
      (w) => w.length > 0 && w[0] === w[0].toUpperCase() && !strokeWords.has(w),
    )
  ) {
    return words.length <= 3;
  }
  return false;
}

interface SectionBlock {
  title: string | null; // null = implicit (no header line)
  lines: RawLine[];
}

function detectSections(tokens: RawLine[]): SectionBlock[] {
  const result: SectionBlock[] = [];
  let current: SectionBlock = { title: null, lines: [] };

  for (const line of tokens) {
    if (line.isBlank) {
      // Blank line between sections — skip
      current.lines.push(line);
      continue;
    }

    if (isSectionHeader(line)) {
      // Save previous section if it has content
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

// ─── Pass 3: Extract NamedSet labels + parse set lines ────────────────────────

// Regex to detect if text STARTS with a set pattern (no $ anchor needed,
// because we only need to know the line starts with NxM or N meters/yards).
// Must use lookahead ?= to avoid consuming trailing content.
const START_SET_RE =
  /^(\d+\s*[x×]\s*\d+|\d+\s+(?:m|yards?|meters?)?)(?=\s|\s*[,@:]|$)/i;

// Full-width regex to find a set pattern anywhere in text (for search/index).
// For the label-splitting case, this is what we search for.
const SET_LINE_RE =
  /(\d+)\s*[x×]\s*(\d+)|\b(\d+)\s+(?:\d+)?\s*(?:m|yards?|meters?)?/i;

function isSetLine(text: string): boolean {
  return START_SET_RE.test(text) || /\d+\s+[x×]\s*\d+/.test(text);
}

// Extract inline label from a set line.
// "Stroke Activation 4x100 as ..." → "Stroke Activation"
// "Aerobic Build (400m)" on its own line → the whole line is the label (no set on this line)
// "4x50 free @1:00" → no label, whole line is rest (no leading label text)
function extractLabel(text: string): { label: string; rest: string } {
  // Check if line STARTS with a set pattern — if so, no label, rest is whole line.
  const startSetMatch = text.match(START_SET_RE);
  if (startSetMatch) {
    return { label: "", rest: text };
  }
  // Otherwise, find where the set pattern begins and split there.
  // e.g. "Stroke Activation 4x100 as ..." → label="Stroke Activation", rest="4x100 as ..."
  const setIdx = text.search(SET_LINE_RE);
  if (setIdx > 0) {
    // Check if "rest" is a parenthetical — e.g. "(600m)" in "Warm-Up (600m)".
    // Parenthetical distances are labels, not set data. Treat whole line as label.
    const restCandidate = text.slice(setIdx).trim();
    if (/^\([^)]+\)$/.test(restCandidate)) {
      return { label: text, rest: "" };
    }
    // Set pattern found after some label text — split there.
    return {
      label: text.slice(0, setIdx).trim(),
      rest: restCandidate,
    };
  }
  if (setIdx === 0) {
    // Line starts with set pattern but START_SET_RE didn't match
    // (e.g. "200 easy" — no unit word, just bare number). Treat as no-label.
    return { label: "", rest: text };
  }
  // No set pattern found — treat entire line as label (no set on this line)
  return { label: text, rest: "" };
}

// Parse a "NxM" or "N x M" rep×distance
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
  // "400" standalone — digits at start, optionally followed by a stroke/meters word
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

  // Percent range: "~75%" → 70-80, "80-85%" → 80-85, "85–90%" → 85-90
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
  // "75%" bare
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

  // Pace target: "at 200 pace"
  const paceMatch = n.match(/(?:at|on|@)\s*(\d+)\s*m?\s*(?:pace|effort)/);
  if (paceMatch) {
    const d = parseIntSafe(paceMatch[1]);
    if (d !== null && isKnownDistance(d))
      return { type: "pace_target", label: `${d} pace`, paceDistance: d };
  }

  // Descend
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

  // Negative split
  if (/\bneg(?:ative)?\s*split\b/i.test(raw)) {
    return { type: "negative_split", label: "negative split" };
  }

  // Build
  if (/\bbuild(?:ing)?\b/i.test(raw)) return { type: "build", label: "build" };

  // Sprint
  if (
    /\b(?:sprint|all[\s-]?out|max(?:\s+effort)?|blast|fast|atp)\b/i.test(raw)
  ) {
    return { type: "sprint", label: "ATP" };
  }

  // Race pace
  if (/\b(?:race(?:\s+pace)?|r\.?p\.?)\b/i.test(raw)) {
    return { type: "race_pace", label: "race pace" };
  }

  // Threshold
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

  // Easy — preserve original word (EZ, recovery, etc.)
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
  const detected: string[] = [];
  for (const [re, gear] of GEAR_PATTERNS) {
    if (re.test(text)) detected.push(gear);
  }
  return detected.length > 0 ? detected : null;
}

// ─── Inline note extraction ──────────────────────────────────────────────────

// "(Paddles optional)" at end of line → note + possible gear
function extractInlineNote(text: string): {
  cleaned: string;
  note: string | null;
} {
  const m = text.match(/^(.+?)\s*\(([^)]+)\)\s*$/);
  if (!m) return { cleaned: text, note: null };
  const note = m[2].trim();
  const before = m[1].trim();
  // Check if the note itself contains a gear keyword
  const gearInNote = parseGear(note);
  // Return cleaned text without the note
  return { cleaned: before, note };
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

// Extract inline parenthetical note from a chunk: "pull (long strokes)" → note="long strokes"
function extractMiniNote(chunk: string): {
  cleaned: string;
  note: string | undefined;
} {
  const m = chunk.match(/^(.+?)\s*\(([^)]+)\)\s*$/);
  if (!m) return { cleaned: chunk, note: undefined };
  return { cleaned: m[1].trim(), note: m[2].trim() };
}

// Extract pacing qualifier from text: "build", "smooth", "strong", "moderate"
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

// Parse "25 drill + 75 swim" → DrillSwimRep
// Parse "100 smooth free" → SimpleRep (with optional note from parens)
function parseSubReps(text: string): SubRep[] {
  // "25 drill + 75 swim" or "25 drill/swim" (slash or plus)
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

  // Extract pacing qualifier first
  const { cleaned, pacing } = extractPacing(text);

  // "100 smooth free" or "100 pull (long strokes)" → simple
  const { cleaned: cleaned2, note } = extractMiniNote(cleaned);
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

  // Distance-only chunk after pacing strip (e.g. "100 build to ~75%")
  // Still produce a SimpleRep — stroke may be null but pacing + intensity are attached
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

// Parse a "4x100" line and extract RepGroup
function parseRepGroup(lineText: string): RepGroup | null {
  let text = lineText;

  // Remove inline note
  const { cleaned, note } = extractInlineNote(text);
  text = cleaned;

  // Parse rep × distance
  const rd = parseRepDist(text);
  if (rd.reps === null && rd.distance === null) return null;

  const stroke = parseStroke(text);
  const interval = parseInterval(text);

  // Extract pacing qualifier BEFORE intensity (so "build" doesn't get eaten by intensity)
  const pacingMatch = text.match(/\b(build|smooth|strong|moderate)\b/i);
  const pacing: string | null = pacingMatch
    ? pacingMatch[1].toLowerCase()
    : null;

  // Extract descend range
  const descendMatch = text.match(
    /\bdesc(?:end(?:ing)?)?\s*(\d+)\s*[-–]\s*(\d+)/i,
  );
  const descend = descendMatch ? `${descendMatch[1]}-${descendMatch[2]}` : null;

  // Extract gear + detect optional flag
  const gear = parseGear(text);
  const gearOptional = gear !== null && /\boptional\b/i.test(text);

  // Build details from remaining words after stripping known patterns
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
    t = t.replace(/[~]?\d+\s*[-–]\s*\d+\s*%/gi, "");
    t = t.replace(/[~]?\d+\s*%/gi, "");
    t = t.replace(/[,+]/g, " ");
    t = t.replace(/\([^)]*\)/g, "");
    const words = t
      .split(/\s+/)
      .filter((w) => w.length > 2 && !/^\d+$/.test(w));
    details = words.length > 0 ? words : null;
  }

  let intensity = parseIntensity(text);
  let intensityOverride: ParsedIntensity | null = null;

  // Sub-breakdown: "as: 100 smooth, 100 IM drill, 100 pull, 100 build to ~75%"
  const asMatch = text.match(/as[\s:]+(.+)$/i);
  let subReps: SubRep[] = [];
  let patternType: RepGroup["patternType"] = null;

  if (asMatch) {
    // When as: block is present, only parse intensity from the part BEFORE "as:"
    // to avoid bleeding sub-rep intensity (e.g. "85-90%") onto the parent spine
    const mainLineBeforeAs = text.substring(0, text.indexOf(asMatch[0])).trim();
    intensity = parseIntensity(mainLineBeforeAs);
    // Check for drill/swim with + before splitting — preserve as single rep if matched
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
      // Split on comma OR +
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
            (lastRep as any).intensity = intensityOnLast;
          }
          subReps.push(...parsed);
        }
      }
      // Only promote intensity to parent spine if ALL sub-reps share it
      if (
        subReps.length > 0 &&
        subReps.every((s) => "intensity" in s && (s as any).intensity != null)
      ) {
        const lastSub = subReps[subReps.length - 1] as any;
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

  const repGroup: RepGroup = {
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
    pattern: subReps as Rep[],
    patternType: subReps.length > 0 ? (patternType ?? "simple") : null,
    connectors: [],
  };

  return repGroup;
}

// Parse odd/even sub-lines
// "Odd: underwater dolphin kick (breakout + easy to wall)" + "Even: freestyle kick build to strong"
// Returns an OddEvenRep or null
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

      // Skip section header line — clear any pending label
      if (isSectionHeader(line)) {
        pendingLabel = null;
        i++;
        continue;
      }

      // Odd/Even block — clear pending label after attaching
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

      // Extract label + rest
      const { label, rest } = extractLabel(line.text);

      if (!rest) {
        // Label-only line — hold it as pendingLabel for the next set line.
        // Skip blank/empty content lines.
        if (label.length > 0 && label.trim().length > 0) {
          pendingLabel = label;
        }
        i++;
        continue;
      }

      // Check for "NxM" or standalone distance
      const rd = parseRepDist(rest);
      if (rd.reps === null && rd.distance === null) {
        pendingLabel = null;
        i++;
        continue;
      }

      // Build the NamedSet — prefer pending label, then current label, then null
      const effectiveLabel = label.length > 0 ? label : (pendingLabel ?? null);
      if (label.length > 0 && pendingLabel !== null) {
        pendingLabel = null;
      }

      const namedSet: NamedSet = {
        label: effectiveLabel,
        note: null,
        repGroups: [],
      };

      // Parse the first rep group
      const rg = parseRepGroup(rest);
      if (rg) {
        namedSet.repGroups.push(rg);
      }

      // Check for "+" compound notation on the SAME line
      // But skip if the first part contains "as:" — parseRepGroup already handled
      // the as: block and produced all sub-reps; splitting would create an orphan RG
      const plusMatch = rest.match(/^(.+?)\s*\+\s*(.+)$/);
      if (plusMatch && !/\bas[\s:]/i.test(plusMatch[1])) {
        const secondRg = parseRepGroup(plusMatch[2].trim());
        if (secondRg) {
          // Second RG inherits interval + intensity from first if it doesn't have its own
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

// ─── Convenience formatters ──────────────────────────────────────────────────

export function formatRepGroup(rg: RepGroup): string {
  const parts: string[] = [];
  if (rg.reps !== null && rg.distance !== null)
    parts.push(`${rg.reps}×${rg.distance}m`);
  else if (rg.distance !== null) parts.push(`${rg.distance}m`);
  if (rg.stroke) parts.push(rg.stroke);
  if (rg.intensity) parts.push(`@ ${rg.intensity.label}`);
  if (rg.interval) parts.push(`on ${rg.interval}`);
  return parts.join(" ") || "(unparsed)";
}

export function formatWorkoutV2(w: Workout): string {
  return w.sections
    .map((s, si) => {
      const header = s.title ? `[${s.title}]` : `[Section ${si + 1}]`;
      const sets = s.namedSets
        .map((ns) => {
          const label = ns.label ?? "(set)";
          const reps = ns.repGroups.map((rg) => formatRepGroup(rg)).join(" + ");
          return `  ${label}: ${reps}`;
        })
        .join("\n");
      return `${header}\n${sets}`;
    })
    .join("\n");
}
