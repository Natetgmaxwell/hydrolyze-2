# Hydrolyze 2 — Vision

**Status:** Approved
**Last updated:** 2026-05-04

---

## The Feel

**Information-rich effortlessness.** A professional tool that acts as a coaching companion. It doesn't try to be smarter than the coach — it formalizes and digitizes what the coach already knows. The goal is zero added stress on pool deck. The app should feel like it was built by someone who understands what it's like to coach at 5am with 24 swimmers in the water.

---

## The Core Loop (Phase 1)

1. Coach writes a workout in natural language → parsed into set components
2. Coach schedules it to AM or PM slot
3. At practice: mark swimmers present → select set → run stopwatch → times auto-assigned → next set → repeat → session summary
4. Done. Data is now digitized, not forgotten.

Times are captured on the Hydrolyze mobile app. The stopwatch uses the device's **volume button** for LAP taps — keeping the coach's eyes on the pool, not on the screen.

---

## Pairing Philosophy

The engine looks at historical data and suggests which swimmer got which time. **Default-to-assign, override only when wrong.** The coach doesn't confirm — they only change when the engine gets something wrong. If it looks right, they move on. No friction.

Z-score ranking drives the assignment. No confidence percentages — they add clutter and imply precision the engine doesn't have.

---

## Timing Screen UX

**Current rep only.** Times for the current rep displayed, cleared between reps. This keeps the coach focused on what's happening now, not a scrolling list of past laps. Between reps: a brief moment of calm before the next one starts.

---

## The Data Center (Phase 2)

Downstream from a solid timing workflow. Once coaches are comfortable collecting data, the app reveals its value:

- **Recent trend** — are they getting faster or slower over the last 4 weeks?
- **Training load** — what sets has this swimmer been doing? Inferred from tracked workout data, no extra logging required.

Progression visualization (vs PB, vs last same-set, etc.) deferred until Phase 1 is rock solid.

---

## What Hydrolyze Is NOT

- Not a lap timer with extra steps — it's a workout management system with a timer built in
- Not a meet app — this is practice, not competition
- Not a black box — the coach is always the authority
- Not overwhelming — information surfaces when needed, not all at once

---

## Design Principles

| Principle              | Meaning                                                                                                           |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------- |
| Coach is the authority | The engine suggests, the coach decides. Never the other way around.                                               |
| Effortlessness         | Zero added stress on pool deck. The app adapts to the coach's rhythm, not the other way.                          |
| Default-to-assign      | If the engine got it right, the coach shouldn't have to do anything. Only act on wrong assignments.               |
| Information-rich       | Data is never lost. Times, PBs, trends — all formalized and accessible. But surfaced when needed, not fire-hosed. |
| Calibration matters    | Gear, intensity, distance — all dimensions the algorithm uses to make apples-to-apples comparisons.               |
