# Hydrolyze

> Swim coaching, timed.

A mobile-first coaching companion for swim practice. Captures lap times with a single tap, automatically assigns them to the right swimmer, and turns a chaotic set into clean data — without the coach ever taking their eyes off the pool.

**Private repository.** All rights reserved. See [LICENSE](./LICENSE).

---

## What this is

At swim practice, the coach holds a stopwatch and calls lap times as swimmers finish. With six or ten swimmers touching the wall within seconds of each other, writing down who swam what is error-prone and distracting. The coach ends up watching the clipboard instead of watching technique.

Hydrolyze removes that friction. The coach taps **LAP** as each swimmer touches the wall; the app does the attribution. No lane sensors, no expensive hardware — just a phone, a stopwatch, and the coach's existing knowledge of their swimmers.

The stopwatch uses the device's **volume button** for LAP taps, so the coach never has to look at the screen.

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
├── hydrolyze-mobile/    React Native (Expo) — primary iOS app
├── ios-native/          Swift / Xcode mirror (downstream)
├── pairing-engine/      Core pairing algorithm (v1)
├── pairing-engine-v2/   Pairing algorithm v2 (current)
├── web-dashboard/       Coach-facing web UI
├── supabase/            Postgres schema, migrations, edge functions
├── plans/               Design specs (workout builder, timing screen, etc.)
├── docs/                Higher-level docs (coach flow, ops)
└── scripts/             Repo-local scripts
```

Each subproject has its own `README.md` (where applicable) and is treated as an independent unit for development. The monorepo ties them together.

---

## Stack

- **Mobile** — React Native (Expo, TypeScript)
- **iOS native** — Swift, Xcode, SwiftPM (mirror of the mobile app for hardware integration)
- **Backend** — Supabase (Postgres, auth, edge functions)
- **Pairing** — z-score matching against PB-derived or Welford-accumulated swimmer profiles
- **Web** — see `web-dashboard/`

---

## Status

Active development. The mobile app's core timing and pairing flow is complete. Volume-button hardware integration requires an EAS development build (not supported in Expo Go). Pairing v2 is the current algorithm; v1 is retained for reference.

Phase 2 (data center: trend lines, training load, progression) is downstream from a rock-solid Phase 1 timing workflow.

---

## Development setup

```bash
# Mobile
cd hydrolyze-mobile
npm install
cp .env.local.example .env.local   # then fill in EXPO_PUBLIC_SUPABASE_URL + anon key
npm run start                      # launches Expo dev server

# iOS native
cd ios-native
xcodegen generate                  # if project.yml changed
open Hydrolyze.xcodeproj
```

See the README in each subproject for full instructions.

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
