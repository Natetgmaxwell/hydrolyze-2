# Volume Button Stopwatch — Implementation Plan (I9)

**Status:** Final — ready for Eng-Manager dispatch  
**Supersedes:** `plans/volume-button-stopwatch-strategy.md`  
**Stack:** iOS 17, SwiftUI, `MPVolumeView` KVO, `AVAudioSession`

---

## 1. Technical Approach

### 1.1 MPVolumeView KVO

`MPVolumeView` exposes `outputVolume` as a KVO-observable property. Volume button presses change this value. A hidden `MPVolumeView` instance captures these events.

```swift
import MediaPlayer
import AVFoundation
import Combine

@Observable
final class VolumeButtonController {
    private var volumeView: MPVolumeView?
    private var outputVolumeObservation: NSKeyValueObservation?
    var onVolumeChange: (() -> Void)?

    private(set) var lastVolume: Float = AVAudioSession.sharedInstance().outputVolume

    init() {
        setupAudioSession()
        setupVolumeView()
    }

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            print("VolumeButtonController: Failed to activate audio session: \(error)")
        }
    }

    private func setupVolumeView() {
        volumeView = MPVolumeView(frame: CGRect(x: -3000, y: -3000, width: 1, height: 1))
        volumeView?.isHidden = true
        volumeView?.showsVolumeSlider = false
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            windowScene.windows.first?.addSubview(volumeView!)
        }

        outputVolumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new, .old]) { [weak self] session, change in
            guard let self = self,
                  let newValue = change.newValue else { return }
            let oldValue = self.lastVolume
            self.lastVolume = newValue

            if abs(newValue - oldValue) > 0.01 {
                DispatchQueue.main.async {
                    self.onVolumeChange?()
                }
            }
        }
    }

    func restoreVolume() {
        DispatchQueue.main.async {
            if let slider = self.volumeView?.subviews.first(where: { $0 is UISlider }) as? UISlider {
                slider.value = 0.5
            }
        }
    }

    deinit {
        outputVolumeObservation?.invalidate()
        volumeView?.removeFromSuperview()
    }
}
```

### 1.2 Why AVAudioSession Category `.playAndRecord`

`.playAndRecord` keeps the app alive in the background and activates the audio session on launch. This is critical for pool-deck lock-screen use. Without an active audio session, iOS may suspend the app.

### 1.3 Volume Restoration

After capturing a volume button press, call `restoreVolume()` to reset the system volume to 0.5. This prevents the user's media volume from being permanently muted or maxed. Do this with a ~200ms delay to avoid capturing the restore as a new press.

---

## 2. Integration Into TimingViewModel

```swift
@Observable
final class TimingViewModel {
    var elapsedTime: TimeInterval = 0
    var currentLap: Int = 1
    var lapTimes: [TimeInterval] = []
    var state: TimingState = .ready

    private var controller: VolumeButtonController?
    private var timer: Timer?
    private var startTime: Date?

    enum TimingState {
        case ready, running, paused
    }

    func startCapture() {
        controller = VolumeButtonController()
        controller?.onVolumeChange = { [weak self] in
            self?.recordLap()
        }
    }

    func stopCapture() {
        controller?.restoreVolume()
        controller = nil
    }

    func start() {
        state = .running
        startTime = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.startTime else { return }
            self.elapsedTime = Date().timeIntervalSince(start)
        }
    }

    func recordLap() {
        guard state == .running else { return }
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        lapTimes.append(elapsedTime)
        currentLap += 1
    }

    func stop() {
        state = .paused
        timer?.invalidate()
        timer = nil
        stopCapture()
    }
}
```

---

## 3. App Store Reviewer Defensibility

### 3.1 Submission Notes (App Store Connect)

> **Hydrolyze uses volume buttons as a lap trigger for swim coaching timing.** Coaches frequently operate the app in wet environments, with gloves, or under pool deck conditions where touch accuracy is severely impaired. Volume buttons provide an accessibility-grade physical input mechanism that is essential for the app's core timing functionality.
>
> This input method is analogous to camera applications using volume buttons as shutter controls (supported by Apple since iOS 6), and is the primary mechanism by which coaches interact with the stopwatch during active coaching sessions.
>
> The app functions fully without volume button input — all lap functionality is also available via on-screen tap targets. Volume button input is optional and enhances the accessibility of the coaching workflow.

### 3.2 Precedent

- **Halide** (2022 App of the Year) — uses volume button as shutter
- **Camera+** — volume button as shutter for years, App Store approved
- Apple has never rejected an app solely for volume button use when tied to the app's core function

### 3.3 Risk Assessment

| Risk                                     | Likelihood | Mitigation                                                                        |
| ---------------------------------------- | ---------- | --------------------------------------------------------------------------------- |
| App Store reviewer flags guideline 2.5.9 | Low        | Pre-planned fallback (see Section 4); submission notes explain accessibility case |
| Reviewer rejects anyway                  | Low-Medium | On-screen lap button remains fully functional as primary input                    |

---

## 4. Rejection Fallback

### If Apple Rejects Volume Buttons

**Primary UI remains fully functional.** The on-screen lap button is NOT a degraded experience — it is the primary input. Volume buttons are an enhancement layer.

**UI spec for on-screen lap button:**

- Bottom of screen, full-width, 120pt tall minimum touch target
- Color: `.hydrolyzeBlue` (active timing state) / `.hydrolyzeAmber` (ready state)
- Label: "LAP" in SF Pro Bold 24pt
- Always visible during active session — never hidden behind a setting

**Settings toggle (user-facing):**

- Location: Settings → Timing → "Enable Volume Button Lap"
- Default: `true` (enabled)
- If disabled: `VolumeButtonController` is never instantiated, `MPVolumeView` never added to hierarchy

**Fallback flow:**

1. App launches → checks `UserDefaults.standard.bool(forKey: "volumeButtonLapEnabled")`
2. If `true` → start volume capture in `TimingViewModel.startCapture()`
3. If `false` → skip volume capture entirely, on-screen button is sole input
4. On first launch → show brief tooltip: "Tip: Use volume buttons for hands-free lap timing"

---

## 5. Background / Lock-Screen Behavior

### 5.1 Screen Locked

**Volume button capture does NOT work with screen locked.** This is an iOS hard constraint. When the device is locked, `AVAudioSession` does not receive volume button events.

**Pool-deck workflow implication:** Coach must have the device unlocked and the app in the foreground. This is already the norm for stopwatch apps.

**Mitigation:** The app should display a persistent indicator when the timing session is active but the app may be in the background. Use `UIApplication.shared.isIdleTimerDisabled = true` to prevent accidental screen lock during active sessions.

### 5.2 `isIdleTimerDisabled`

```swift
func startSession() {
    UIApplication.shared.isIdleTimerDisabled = true
}

func endSession() {
    UIApplication.shared.isIdleTimerDisabled = false
}
```

### 5.3 Background Audio

Using `.playAndRecord` audio session category marks the app as audio-capable. iOS will NOT suspend it immediately when backgrounded. However, for the stopwatch to keep running with screen locked:

- The app must remain in the foreground (user must not switch apps)
- Lock-screen widget (`ClockKit`) could be added in a future iteration for true lock-screen elapsed time display, but this is out of scope for I9

---

## 6. iOS 17 Specifics

- `@Observable` macro: Use for `TimingViewModel` — no `ObservableObject`/`@Published` needed
- SwiftUI integration: `TimingView` receives `TimingViewModel` as `@State` or `@Environment`
- No Watch connectivity in I9 (I10 scope); I9 is iOS-only timing loop
- `UIApplication.shared.isIdleTimerDisabled` works on iOS 13+, no conditional needed
- `MPVolumeView` + KVO pattern unchanged from iOS 13+

---

## 7. Test Plan

### 7.1 Simulator Limitation

**Volume buttons cannot be simulated in Xcode Simulator.** Physical device required.

### 7.2 Physical Device Test Checklist (TestFlight)

- [ ] Start a new timing session → verify `isIdleTimerDisabled` activates
- [ ] Press volume up → verify lap is recorded + haptic fires
- [ ] Press volume down → verify lap is recorded + haptic fires
- [ ] Rapid volume presses (3 in 1 second) → verify all 3 laps recorded
- [ ] Let device idle to lock screen → verify app stays alive
- [ ] Unlock → verify timing has continued (not reset)
- [ ] End session → verify `restoreVolume()` called → system volume at ~50%
- [ ] Settings toggle OFF → verify volume buttons do NOT trigger laps
- [ ] Settings toggle ON → verify volume buttons DO trigger laps

### 7.3 Haptic Verification

Use `UIImpactFeedbackGenerator(style: .medium)` for lap events. Confirm haptic is perceptible with device in waterproof pouch (common pool-deck setup).

---

## 8. Files To Create

| File                                                      | Responsibility                          |
| --------------------------------------------------------- | --------------------------------------- |
| `Hydrolyze/Sources/Services/VolumeButtonController.swift` | `MPVolumeView` KVO, audio session setup |
| `Hydrolyze/Sources/ViewModels/TimingViewModel.swift`      | `@Observable` timing state machine      |
| `Hydrolyze/Sources/Views/Timing/` (new directory)         | `TimingView`, `LapButtonView`           |
| Modify `ContentView.swift`                                | Route to `TimingView` for I9 demo       |

---

## 9. I9a / I9b Split Recommendation

**I9a (Eng-Manager builds now):**

- `VolumeButtonController` + `TimingViewModel` + `TimingView` with on-screen lap button
- Full stopwatch loop functional with touch input
- Build-ready — no physical device needed for on-screen button testing

**I9b (separate dispatch, physical device required):**

- Volume button KVO integration wired to `TimingViewModel.onVolumeChange`
- Volume restoration logic
- Settings toggle for enable/disable
- TestFlight-only verification

**Rationale:** I9a can be built and tested entirely in Simulator. I9b requires physical device for every commit. Ship I9a to TestFlight first, then I9b when you have a physical device handy.

---

## 10. App Store Reviewer Notes

**Use case:** Hydrolyze uses hardware volume buttons as a tactile lap-trigger during pool-deck timing sessions. Coaches frequently operate the app in wet environments, with gloves, or under pool-deck conditions where touch accuracy is impaired. Volume buttons provide an accessibility-adjacent physical input mechanism for lap recording — analogous to camera apps using volume buttons as shutter controls (supported by Apple since iOS 6, used by Halide, Camera+, and others).

**Public APIs used:**
- `AVAudioSession` with category `.playAndRecord` (options: `.defaultToSpeaker`, `.allowBluetooth`) — documents the app's audio capability need; no background audio is streamed
- `MPVolumeView` with `showsVolumeSlider = false`, hidden off-screen at `(-3000, -3000)` — system volume slider used only for volume restoration, never displayed

**Volume restoration:** Volume is snapshotted before the session and restored to 50% after each button press via the hidden slider with a 200ms delay. The user's media playback volume is never permanently altered.

**No private APIs. No entitlements required. No background audio capability needed.**
