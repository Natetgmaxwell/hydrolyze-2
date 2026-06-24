# Hydrolyze Emotional Design Coverage Matrix — v1.17

> **Status:** Approved (slice 5 of [[originals/hydrolyze-emotional-design-implementation-plan]],
> shipped 2026-06-20). Drives the warmth-through-motion work for the
> remaining v1.17 slices.
>
> **Author:** Hermes Agent (build profile). **Approver:** Nathan Maxwell.

## Direction (2026-06-20 user correction)

The user's verbatim voice direction: **"Let's go with 'warm.' We should
try to make it feel welcoming and interactive. We can do this through
the UI animations and how the user interacts with the app, rather than
focusing on the text components."**

This matrix reflects that direction: the audit dimensions are
**motion + interaction** channels, not text microcopy. The clinical
text conventions (`HYDROLYZE`, `REVIEW`, `LAP`, `READY`, `SESSION
COMPLETE`) STAY — they read cleanly on a pool deck at 5am. The warmth
comes from how the app responds.

See [[concepts/warmth-through-motion]] for the cross-cutting principle
(multi-channel voice; the right channel depends on the product's
reading mode).

## Audit dimensions

Each surface × each dimension × a 1-5 rating (1=missing, 5=excellent).

| Dimension | What it measures |
|---|---|
| **Reactive feedback** | Does every tap respond in <16ms with scale-down + haptic + color shift, BEFORE the async work? |
| **Spring transitions** | Are all transitions spring-based (`Animations.springSnappy` / `springSoft`), never plain `easeInOut`? |
| **Idle invitations** | Do key CTAs breathe gently when idle (`phaseAnimator` 1.0 → 1.04 → 1.0, 1.4s cycle)? |
| **State transitions** | When the app changes state, is the transition a smooth crossfade with subtle scale (not a hard cut)? |
| **Row enter/exit** | Do list rows animate in/out with spring physics (not pop in/out instantly)? |
| **Loading choreography** | Does async work get a phased indicator (3-dot cyan trail showing what's happening), not a generic spinner? |
| **Completion moments** | Is the data-integrity milestone (pairing matches approved) acknowledged with motion + haptic, not text? |
| **Empty states** | Does the "no data" surface breathe (the v1.16 house-icon pattern generalized), or sit static? |

## Initial coverage matrix (post v1.16 micro-interaction audit)

| Surface | Reactive | Spring | Idle | State | Rows | Loading | Completion | Empty | Notes |
|---|---|---|---|---|---|---|---|---|---|
| `TimingView` (running) | **5** | 4 | **5** | 2 | 4 | 4 | 5 | n/a | State transitions (.setup → .ready → .running) are hard swaps — **gap** |
| `TimingView` (saving) | 4 | 4 | n/a | 2 | n/a | 2 | 4 | n/a | Loading is generic ProgressView, not phased — **gap** |
| `SessionReviewView` | **5** | **5** | n/a | n/a | **5** | 2 | 2 | n/a | Filter tabs animate; rows transition. Loading state is generic. **Loading gap** |
| `LoginView` | 4 | 4 | n/a | 4 | n/a | n/a | n/a | n/a | Mode swap animates. **Wordmark reveal gap** |
| `TodayView` | 3 | 4 | 4 | n/a | n/a | n/a | n/a | **5** | Empty state breathes; **pull-to-refresh uses default system color, not cyan** |
| `SwimmersListView` | 4 | **5** | n/a | n/a | 2 | n/a | n/a | 1 | Filter pills morph; rows don't animate. **Empty state static. Gap.** |
| `WorkoutCard` | **5** | 4 | **5** | n/a | n/a | n/a | n/a | n/a | AM badge breathes; press feedback done |
| `EmptyStateView` | n/a | n/a | n/a | n/a | n/a | n/a | n/a | **5** | House icon breathes — the reference pattern for other empty states |
| `AuthTextField` | **5** | **5** | n/a | n/a | n/a | n/a | n/a | n/a | Focus animation + haptic done in v1.16 |

**Sum of gaps (the work for the remaining slices):**

1. **State transitions in TimingView** — hard swaps on .setup → .ready → .running → .saving → .finished. Wrap in `withAnimation` + add `.transition()` modifiers.
2. **Loading choreography in TimingView.savingView** — generic `ProgressView()` + log tail. Surface `currentSaveStep` as a 3-dot phased indicator.
3. **Loading choreography in SessionReviewView** — generic `ProgressView()` when rows are fetching. Apply the same 3-dot phased indicator pattern.
4. **Wordmark reveal in LoginView** — `HYDROLYZE` wordmark static. Add a 0.6s opacity + scale reveal on first appear.
5. **Empty state breathing in SwimmersListView** — `person.fill` icon static. Apply the `phaseAnimator` breathing pattern from `EmptyStateView`.
6. **Row enter/exit in SwimmersListView** — rows pop in/out. Add spring-physics enter animation for new rows (add swimmer) and exit for deleted (archive).
7. **Pull-to-refresh cyan tint** — `TodayView`, `SwimmersListView`, `SessionReviewView` use system default. Add `.tint(Color(hex: "09d4ee"))` on the refreshable.

The first 4 are the highest-impact and ship in this turn. Items 5-7
are deferred to a follow-up slice.

## Slice 3: phased loading + saving state (this turn)

**Targets:** Loading dimension for `TimingView.savingView` and
`SessionReviewView` rowsList loading state.

**The pattern: a 3-dot cyan phased indicator.**

```
○━━━●━━━●━━━○
   fetching  pairing   saving
```

Three dots horizontally. The active dot is cyan and pulsing
(`phaseAnimator` 1.0 → 1.2 → 1.0 on a 0.6s cycle). Completed dots
are filled cyan. Future dots are gray. Below the dots: the current
phase name in JetBrains Mono + a one-line description.

**Files touched:**
- `TimingView.swift` savingView (line 438+)
- `SessionReviewView.swift` rowsList loading state (line 92+)

**Implementation:** extract to a `PhasedProgressView` component
(`Sources/Views/Components/PhasedProgressView.swift`). Takes a
`currentPhase: Phase` and renders the 3-dot indicator + label.
Reusable across the codebase (Charts views might want it too).

**Verification:** manual preview during a real save. Verify the
phase indicator updates as `currentSaveStep` changes. Verify the
loading state in SessionReviewView matches the same pattern.

## Slice 1 (partial, this turn): warmth-through-motion changes

**Targets:** State transitions, login wordmark reveal, empty state
breathing for SwimmersListView, pull-to-refresh tint.

**The motion changes (highest impact first):**

1. **TimingView state transition crossfades** — wrap the body
   `switch viewModel.state` in `.animation(Animations.springSoft,
   value: viewModel.state)` and add
   `.transition(.asymmetric(insertion: .opacity.combined(with:
   .scale), removal: .opacity))` to each state's view. The 5-state
   machine becomes a smooth crossfade sequence.

2. **LoginView wordmark reveal** — `HYDROLYZE` text reveals on
   first appear (gentle opacity 0 → 1 + scale 0.95 → 1.0 over
   0.6s). First-impression warmth through motion, NOT through
   "Welcome back, Coach." text.

3. **SwimmersListView empty state breathing** — the `person.fill`
   icon in the empty state gets the same `phaseAnimator` breathing
   pattern as the house icon in `EmptyStateView`.

4. **Pull-to-refresh cyan tint** — add `.tint(Color(hex: "09d4ee"))`
   on the `.refreshable` modifier in `TodayView`,
   `SwimmersListView`, and `SessionReviewView`.

**Files touched:** 4 view files. Small per-file changes
(10-30 LOC each).

## Slice 6+ (deferred, follow-up slice)

The remaining motion work captured here for the next round:

- **Swipe-gesture personality on swimmer rows** — custom swipe
  action colors (cyan for archive, amber for delete) with motion
  that hints at the action before the swipe completes.
- **Matched-geometry transitions** — when a workout card is
  tapped to start a session, the card morphs into the SessionStartView
  header. Same shape, animated position + size.
- **Custom keyboard appearance animations** — when a text field
  becomes first responder, the keyboard rises with a slight
  damped bounce instead of a hard slide-up.
- **Row delete confirmation animation** — when a swimmer is
  archived, the row collapses + fades (already partial via swipe).
- **Timer restart feedback** — when a coach restarts a set mid-session,
  the existing finish line shows a "rewinding" animation.
- **Filter tab transition** — SessionReviewView's filter tab change
  could animate the (N) badge count cross-fading into the new value.

These are higher-LOC motion changes that can ship once Slice 1
establishes the pattern (motion = warmth, restraint = professionalism).

## Verification approach (per change)

Every motion change ships with:

1. `swiftc -parse` cross-file, zero errors
2. Manual preview in Xcode Simulator for the touched surface
3. The "5am pool deck, 24 swimmers" check: does the motion feel
   ALIVE without being DISTRACTING? If a coach would say "the app
   feels nice" without saying "what's that animation doing," the
   motion is right.

## Cross-cutting posture generalization

The "warm through motion" direction generalizes beyond Hydrolyze.
For [[concepts/felty]] in Felt Faction, the right channel is text
(Felty's narration is the warmth). For Hydrolyze, the right channel
is motion + interaction. Same principle, different product, different
channel.

See [[concepts/warmth-through-motion]] for the full principle.

## Source

User verbatim (2026-06-20): "Let's complete the three remaining slices
in terms of voice direction. Let's go with 'warm.' We should try to
make it feel welcoming and interactive. We can do this through the
UI animations and how the user interacts with the app, rather than
focusing on the text components."

Captured per the signal-detector contract (silent). Implementation
plan: [[originals/hydrolyze-emotional-design-implementation-plan]].
Playful direction: [[originals/hydrolyze-feel-direction-playful-v1]].
Framework: [[concepts/emotional-design]]. Utilities:
[[concepts/hydrolyze-micro-interaction-system]].