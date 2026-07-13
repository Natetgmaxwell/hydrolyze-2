# Hydrolyze

> Swim coaching, timed.

A mobile-first coaching companion for swim practice. Captures lap times with a single tap, automatically assigns them to the right swimmer, and turns a chaotic set into clean data — without the coach ever taking their eyes off the pool.

**Private repository.** All rights reserved. See [LICENSE](./LICENSE).

---

## What this is

At swim practice, the coach holds a stopwatch and calls lap times as swimmers finish. With six or ten swimmers touching the wall within seconds of each other, writing down who swam what is error-prone and distracting. The coach ends up watching the clipboard instead of watching technique.

Hydrolyze removes that friction. The coach taps **LAP** as each swimmer touches the wall; the app does the attribution. No lane sensors, no expensive hardware — just a phone, a stopwatch, and the coach's existing knowledge of their swimmers.

The primary LAP control is a large on-screen tap target (Apple Watch crown is a planned premium eyes-free option for Phase 2).

---

## The core loop

1. Coach writes a workout in natural language → parsed into set components
2. Coach schedules it to AM or PM slot
3. At practice: mark swimmers present → select set → run stopwatch → times auto-assigned → next set → repeat → session summary
4. Done. Data is now digitized, not forgotten.

---

## How the pairing works

The engine looks at historical data and suggests which swimmer got which time. **Default-to-assign, override only when wrong.** The coach doesn't confirm — they only change when the engine gets something wrong. If it looks right, they move on.

From each swimmer's personal best (PB), Hydrolyze derives a realistic training time range — swimmers typically train 2–18% slower than PB depending on set intensity. That range becomes the statistical prior. When a LAP tap comes in, the app z-scores the incoming time against every remaining swimmer's expected distribution and assigns the closest match. After five or more real training times, the algorithm switches from PB-derived estimates to actual observed data via Welford's online update. Predictions sharpen automatically as the team trains more.

The coach is always the authority. Every assignment can be overridden. The algorithm is an assistant.

---

## Repository layout

```
.
├── ios-native/                       Swift / SwiftUI — the canonical client
├── supabase/                         Postgres schema, migrations, edge functions
├── plans.archive.2026-06-30/         Historical design specs (read-only archive)
└── docs.archive.2026-06-30/          Historical operational docs (read-only archive)
```

The `*.archive.2026-06-30/` directories hold pre-cleanup material from the
React Native era (the RN app + TS pairing engine + web-dashboard reservation
were all removed). They are frozen — see the `ARCHIVE-NOTE.md` in each.

---

## Stack

- **iOS native** — Swift, SwiftUI, SwiftPM. The single client.
- **Backend** — Supabase (Postgres, auth, edge functions)
- **Pairing** — z-score matching against PB-derived or Welford-accumulated swimmer profiles; lives inline in `ios-native/Hydrolyze/Sources/Services/`

---

## Status

Active development. iOS-native is the sole client. The pairing engine
(`Services/PairingEngine.swift`) is the source of truth for the algorithm.

Phase 2 (data center: trend lines, training load, progression) is downstream
from a rock-solid Phase 1 timing workflow.

---

## Development setup

```bash
# Generate the Xcode project (one-time + after project.yml changes)
cd ios-native
xcodegen generate
open Hydrolyze.xcodeproj
```

Supabase credentials are hardcoded in `ios-native/Hydrolyze/Sources/Services/SupabaseService.swift`.
Replace the placeholder anon key with the real value before shipping.

---

## Design principles

| Principle              | Meaning                                                                                                |
| ---------------------- | ------------------------------------------------------------------------------------------------------ |
| Coach is the authority | The engine suggests, the coach decides. Never the other way around.                                    |
| Effortlessness         | Zero added stress on pool deck. The app adapts to the coach's rhythm, not the other way.               |
| Default-to-assign      | If the engine got it right, the coach shouldn't have to do anything. Only act on wrong assignments.    |
| Information-rich       | Data is never lost. Times, PBs, trends — all formalized and accessible. But surfaced when needed.      |
| Calibration matters    | Gear, intensity, distance — all dimensions the algorithm uses to make apples-to-apples comparisons.    |

---

## License

© Nathan Maxwell. All rights reserved. See [LICENSE](./LICENSE) for the proprietary license terms.
