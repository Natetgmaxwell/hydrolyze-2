// ─── Shared Swim Constants ─────────────────────────────────────────────────────

/**
 * Maps spoken/written number words to numeric values.
 * Used by workout parsers to normalize natural language inputs.
 */
export const WORD_NUMBERS: Record<string, number> = {
  one: 1,
  two: 2,
  three: 3,
  four: 4,
  five: 5,
  six: 6,
  seven: 7,
  eight: 8,
  nine: 9,
  ten: 10,
  eleven: 11,
  twelve: 12,
  thirteen: 13,
  fourteen: 14,
  fifteen: 15,
  sixteen: 16,
  seventeen: 17,
  eighteen: 18,
  nineteen: 19,
  twenty: 20,
}

/**
 * Standard swim distances in metres.
 * Used to validate distance values during parsing.
 */
export const SWIM_DISTANCES = new Set([
  15, 25, 50, 75, 100, 125, 150, 200, 300, 400, 500, 600, 800, 1000, 1500, 1650,
])