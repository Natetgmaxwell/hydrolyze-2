/**
 * Hydrolyze Design System — React Native tokens
 * Source of truth: /Users/nathanmaxwell/Downloads/DESIGN.md
 *
 * Aesthetic: Poolside Tool — dark, utilitarian, high-contrast.
 * Like a professional timing console.
 */

export const Colors = {
  // Base surfaces
  base:     '#060e18',   // page backgrounds
  surface:  '#0d1b2a',   // cards, section backgrounds
  elevated: '#1a2d42',   // inputs, interactive surfaces
  border:   '#2d3e50',   // dividers, borders

  // Text
  text:  '#e2f4fa',      // primary content
  muted: '#7a9bb0',      // secondary content
  dim:   '#4a6572',      // labels, placeholders, timestamps

  // Accent — use sparingly
  cyan:    '#09d4ee',    // active states, CTAs, primary buttons
  cyanDim: 'rgba(9,212,238,0.12)',  // subtle cyan background tint

  // Semantic
  optimal: '#10b981',   // goal met, positive
  amber:   '#f59e0b',   // off-pace, warning
  danger:  '#ef4444',   // errors, destructive

  // Derived
  dangerSurface: 'rgba(239,68,68,0.12)',
  cyanGlow:      'rgba(6,194,219,0.25)',
} as const

export const FontFamily = {
  mono: 'JetBrainsMono_700Bold',
  monoMedium: 'JetBrainsMono_500Medium',
  ui:   'Inter_400Regular',
  uiMedium: 'Inter_500Medium',
  uiSemiBold: 'Inter_600SemiBold',
} as const

export const FontSize = {
  timer: 72,   // primary timer display
  xl:    24,   // current swimmer name
  lg:    20,   // section headings
  base:  14,   // body, list items
  sm:    12,   // secondary info
  xs:    10,   // labels, uppercase tracking
} as const

export const Space = {
  1:  4,
  2:  8,
  3:  12,
  4:  16,
  6:  24,
  8:  32,
  12: 48,
  16: 64,
} as const

export const Radius = {
  sm: 4,
  md: 8,
  lg: 12,
} as const

export const TouchTarget = {
  min:     44,   // Apple HIG / wet fingers
  swimRow: 56,   // swimmer rows: 44px touch + 6px buffer each side
  lap:     80,   // LAP button: primary action, poolside confidence
} as const

/** Primary CTA button style — cyan gradient, dark text */
export const primaryButton = {
  backgroundColor: Colors.cyan,
  borderRadius: Radius.lg,
  paddingVertical: Space[3],
  paddingHorizontal: Space[5 as keyof typeof Space] ?? Space[4],
  alignItems: 'center' as const,
  // boxShadow for web, elevation for native
  boxShadow: `0 0 12px ${Colors.cyanGlow}`,
  elevation: 4,
} as const

/** Text inside a primary CTA button */
export const primaryButtonText = {
  color: '#000',
  fontFamily: FontFamily.uiSemiBold,
  fontSize: FontSize.base,
  fontWeight: '600' as const,
} as const

/** Secondary button — elevated surface, text-colored */
export const secondaryButton = {
  backgroundColor: Colors.elevated,
  borderRadius: Radius.md,
  borderWidth: 1,
  borderColor: Colors.border,
  paddingVertical: Space[3],
  paddingHorizontal: Space[4],
  alignItems: 'center' as const,
} as const

/** Danger button */
export const dangerButton = {
  backgroundColor: Colors.elevated,
  borderRadius: Radius.md,
  borderWidth: 1,
  borderColor: 'rgba(239,68,68,0.3)',
  paddingVertical: Space[3],
  paddingHorizontal: Space[4],
  alignItems: 'center' as const,
} as const

/** Input field */
export const inputField = {
  backgroundColor: Colors.elevated,
  borderWidth: 1,
  borderColor: Colors.border,
  borderRadius: Radius.md,
  paddingVertical: Space[3],
  paddingHorizontal: Space[4],
  color: Colors.text,
  fontSize: FontSize.base,
} as const

/** Card */
export const card = {
  backgroundColor: Colors.surface,
  borderWidth: 1,
  borderColor: Colors.border,
  borderRadius: Radius.md,
  padding: Space[4],
} as const

/** Label above fields — uppercase, tracked, dim */
export const fieldLabel = {
  color: Colors.dim,
  fontSize: FontSize.xs,
  fontWeight: '600' as const,
  letterSpacing: 0.8,
  textTransform: 'uppercase' as const,
  marginBottom: Space[2],
} as const
