# Hydrolyze

> Swim coaching, timed.

---

## What it is

Hydrolyze is a coaching tool for timing swim sets and automatically assigning recorded times to the correct swimmer. The coach taps a button once per swimmer who touches the wall. The app figures out who swam what.

No lane sensors. No expensive hardware. Just a phone, a stopwatch, and the coach's existing knowledge of their swimmers.

---

## The problem

At swim practice, the coach holds a stopwatch and calls lap times as swimmers finish. With six or ten swimmers touching the wall within seconds of each other, writing down who swam what time is error-prone and distracting. The coach ends up watching the clipboard instead of watching technique.

Hydrolyze removes that friction. Times are captured with a single tap. The app does the attribution.

---

## How it works

### Personal bests as the prior

The coach enters each swimmer's personal best (PB) for each stroke and distance they train. That's the only setup required.

From a PB, Hydrolyze derives a realistic training time range — swimmers typically train at 2–18% slower than their PB depending on the set intensity. That range becomes the statistical prior for each swimmer.

### Prediction at the wall

When the coach taps LAP, the app has a time but not a name. It z-scores the incoming time against every remaining swimmer's expected distribution and assigns the closest match. The swimmer is removed from the candidate pool. The next tap matches against whoever is left.

The result: a predicted name with a confidence level. High confidence (85–95%) means the time fit one swimmer's profile well and didn't fit anyone else's. Low confidence (55–65%) means the assignment is uncertain — the coach can tap to correct it.

### Getting smarter over time

Every time a session is saved, the recorded times feed back into each swimmer's statistical profile via an incremental mean and standard deviation update (Welford's algorithm). After five or more real training times, the algorithm switches from PB-derived estimates to actual observed data. Predictions sharpen automatically as the team trains more.

### Manual override always available

The algorithm is an assistant, not an authority. Every assignment can be overridden. Times flagged as uncertain or unassigned surface at the top of the results screen so the coach can review them before saving.

---

## The workflow

```
Define set  →  Mark attendance  →  Time the rep  →  Review  →  Save
```

1. **Define set** — type or speak the set naturally ("4 x 50 free on 1:30"). The parser extracts reps, distance, stroke, interval, and intensity.
2. **Mark attendance** — select which swimmers are in the water for this set.
3. **Time the rep** — tap LAP each time a swimmer touches the wall. The clock runs; names appear alongside each time.
4. **Review** — at the end of the rep, review assignments. Correct anything that looks wrong. Advance to the next rep.
5. **Save** — when the set is done, all times sync to Supabase. Swimmer stats update automatically.

---

## Design principles

**One-handed operation.** The coach may be holding a clipboard or whistle. Every primary action must be reachable with a thumb.

**Poolside legibility.** Dark background, high-contrast text, large touch targets. Numbers in JetBrains Mono — the same font used on professional timing displays.

**Speed over polish.** A coach timing a set has no time to navigate menus. The critical path (define → attend → time → save) is a linear four-screen flow with no dead ends.

**No friction for the common case.** The algorithm handles attribution automatically. Manual correction is always available but should rarely be needed once the team has a session or two of data.

---

## Stack

- React Native (Expo) — iOS
- Supabase — Postgres database, REST API
- TypeScript throughout
- Statistical pairing: z-score against PB-derived or Welford-accumulated swimmer profiles

---

## Status

Active development. Core timing and pairing flow is complete. Volume button hardware integration requires an EAS development build (not supported in Expo Go).
