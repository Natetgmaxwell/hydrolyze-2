# Volume-Button Stopwatch Strategy

**Status:** Decision needed — user review
**Author:** Vision
**Date:** 2026-05-16

---

## Bottom Line Up Front

**Do not use volume buttons as the primary stopwatch control on iOS.** The App Store review guidelines (2.5.9) explicitly state: _"Apps that alter or disable the functions of standard switches, such as the Volume Up/Down... will be rejected."_ While camera apps like Camera+ have shipped volume-button shutters (Apple has historically looked the other way for camera apps), Hydrolyze is a swim coaching app — there is no defensible "this is how cameras work" argument. The risk of rejection or removal is real.

The reliable, review-safe alternative: **large on-screen tap target** as primary, with **Apple Watch crown** as the premium eyes-free option (Phase 2 watchOS).

---

## 1. Technical Feasibility on iOS 17+

### Approaches Assessed

**A. `MPVolumeView` hidden + KVO `outputVolume` observation**

- Place a hidden `MPVolumeView` in the view hierarchy, observe `AVAudioSession.sharedInstance().outputVolume` via KVO
- Works — Camera+ and many fitness apps use this
- Problem: the volume HUD still briefly appears on each press (volume actually changes), and the hidden slider approach suppresses it only partially
- Verdict: functional but hacky; App Store risk (see below)

**B. `AVAudioSession` interruption handler only**

- `AVAudioSession` doesn't expose button presses directly — only interruptions (phone calls, etc.)
- Cannot detect volume button presses this way
- Verdict: not viable

**C. `MediaPlayer` framework (`MPRemoteCommandCenter`)**

- Remote command center handles lock screen / Control Center media controls, not hardware volume buttons
- Not applicable
- Verdict: not viable

**D. Private API (`IOHIDEvent`)**

- Apps have been rejected for using private APIs to intercept volume buttons
- App Store review guideline 2.5.1: "Apps may only use public APIs"
- Verdict: not viable, high rejection risk

**E. `MPRemoteCommandCenter` + `MPNowPlayingInfoCenter`**

- For lock screen and Control Center controls (play/pause/seek) — not volume button interception
- Not applicable to this use case
- Verdict: useful for lock screen display, not for input capture

**F. On-screen tap target (primary, App Store safe)**

- Large `TapGesture` or `Button` — SwiftUI tap detection is <16ms latency
- `UIImpactFeedbackGenerator` for haptic confirmation
- Screen stays awake via `UIApplication.shared.isIdleTimerDisabled = true`
- Verdict: **the correct primary input**

**G. Apple Watch (Phase 2)**

- Crown press events via `WKCrownSequencer` — fully public, App Store safe
- Works in Water Lock, works during `HKWorkoutSession`
- Verdict: **the correct eyes-free secondary input**

---

## 2. App Store Review Risk

**Relevant guideline:** Section 2.5.9 — _"Apps that alter or disable the functions of standard switches, such as the Volume Up/Down or Ring/Silent switches... will be rejected."_

This is a hard boundary Apple has drawn. The only reason Camera+ gets away with it is because volume-button-as-shutter is expected camera behavior — the app's entire function depends on it. Hydrolyze as a swim coaching app has no equivalent justification.

**Precedent:** Several stopwatch and fitness apps have attempted volume button capture for one-handed operation. Most either:

- Got rejected at review (2.5.9)
- Got approved but with a Note to Developer asking them to justify it
- Shipped via TestFlight beta only and never went to public App Store review

**Recommendation for App Store notes:** If volume button observation were added, the App Store Connect note would need to explain: "Volume button observation is used solely to allow hands-free stopwatch operation while the coach holds a phone at poolside. The app does not alter or persist volume changes." — but this is unlikely to pass 2.5.9 given the explicit language.

---

## 3. UX Context For The Pool Deck

The user described: **coach holding phone in one hand, often wet, in sunlight, with a stopwatch instinct from physical watches.**

This is a real and valid ergonomic need. The solution that best addresses it:

| Input                       | Eyes-free         | One-handed | Wet hands OK     | App Store safe |
| --------------------------- | ----------------- | ---------- | ---------------- | -------------- |
| On-screen tap               | ❌ (need to look) | ✅         | ⚠️ (wet fingers) | ✅             |
| Volume button               | ✅                | ✅         | ❌               | ⚠️             |
| Watch crown                 | ✅                | ✅         | ✅ (Water Lock)  | ✅             |
| Watch Action Button (Ultra) | ✅                | ✅         | ✅               | ✅             |

**Best pool-deck UX: on-screen tap (primary) + Watch crown (Phase 2 secondary).** The on-screen tap works with wet fingers if the tap target is large enough (80pt minimum, per Apple HIG). Watch crown is the eyes-free option when the phone is in a pocket or on the pool edge.

---

## 4. Recommendation on Plan Structure

### Option A: Drop volume buttons entirely (recommended)

- I9 timing screen uses **large on-screen Lap button** as primary
- Haptic feedback (`UIImpactFeedbackGenerator.medium`) confirms each press
- Keep `isIdleTimerDisabled = true` so screen doesn't sleep
- Phase 2 watchOS adds Crown press as eyes-free enhancement (no App Store risk)

**Pros:** App Store safe, simple, reliable, haptics provide physical confirmation
**Cons:** Requires looking at phone (mitigated by Phase 2 Watch)

### Option B: Add volume button observation as enhancement only

- Primary input: on-screen tap (same as Option A)
- Secondary: `MPVolumeView` KVO observation when app is in foreground
- Feature flag: off by default, user can enable in Settings if they accept the risk
- Never shipped as the primary or sole mechanism

**Pros:** Power users who want it can enable it
**Cons:** Maintenance burden, App Store risk if Apple changes policy, code complexity

**Verdict on Option B:** Not worth it. The feature flag approach reduces but doesn't eliminate App Store risk, and adds ongoing maintenance complexity for marginal ergonomic benefit.

---

## 5. Recommendation

**Bake into I9 as core scope: large on-screen Lap button with haptic feedback. No volume button capture.**

The Phase 2 watchOS companion (Crown press) is the proper solution for eyes-free poolside operation. It's App Store safe, works in Water Lock, and is a genuine hardware button (not a hack).

The on-screen button is not a regression from the current RN app — the RN app's LapButton is also on-screen. The improvement over RN is haptic confirmation and screen-keep-awake behavior.

**Changes needed to I9 spec (timing screen):**

- Add `UIImpactFeedbackGenerator` on lap tap
- Ensure `isIdleTimerDisabled = true` during timing screen active state
- Add a setting in Phase 2 to pair Apple Watch for crown-based lap control

---

## 6. What To Tell The User

The volume button idea is exactly right ergonomically — but Apple has drawn a hard line on volume button interception in its App Store guidelines (section 2.5.9). Camera apps get away with it because it maps to their core function. A swim coaching app doesn't have that defense. We won't risk an App Store rejection over it.

The fix is the Phase 2 Watch app: the Crown press is a real hardware button that works in Water Lock, stays live underwater, and doesn't touch Apple's volume button restriction. It's the right answer to the same ergonomic problem.

For I9: the Lap button is on-screen with haptic feedback. Good enough for now. Great when the Watch app ships in Phase 2.
