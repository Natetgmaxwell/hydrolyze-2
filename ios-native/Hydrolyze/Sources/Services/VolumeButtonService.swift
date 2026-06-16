import Foundation
import MediaPlayer
import AVFoundation

/// VolumeButtonService — captures hardware volume-up presses via MPVolumeView KVO.
///
/// A hidden MPVolumeView is placed off-screen. Observing `AVAudioSession.outputVolume`
/// detects button presses. Only volume-up fires the callback; volume-down is ignored.
///
/// After each accepted press the volume is restored to its pre-session level via the
/// hidden slider so the device volume doesn't drift to 0 or max over repeated presses.
///
/// Includes a 100ms debounce to reject accidental double-taps / hardware bounce while
/// allowing fast sequential taps for tight finishes.
final class VolumeButtonService {
    private var volumeView: MPVolumeView?
    private var outputVolumeObservation: NSKeyValueObservation?

    /// The target volume we aggressively reset to. 0.5 ensures maximum headroom for presses.
    private let neutralVolume: Float = 0.5
    
    /// The user's actual volume when `start()` was called — restored on `stop()`.
    private var originalUserVolume: Float = 0.5

    /// Timestamp of the last accepted press — used for debounce.
    private var lastAcceptedPress: CFTimeInterval = 0

    /// Minimum interval between accepted presses (seconds). 100ms allows fast taps.
    private let debounceInterval: CFTimeInterval = 0.1

    /// Called when the volume-up button is pressed (and accepted past debounce).
    var onVolumeUp: (() -> Void)?

    private(set) var isRunning: Bool = false

    // MARK: - Public

    /// Start capturing volume button presses. Adds hidden MPVolumeView to window hierarchy.
    func start() {
        guard !isRunning else { return }
        originalUserVolume = AVAudioSession.sharedInstance().outputVolume

        setupAudioSession()
        setupVolumeView()
        isRunning = true

        // Force volume to the neutral midpoint immediately so there's room for up presses.
        restoreVolume()
    }

    /// Stop capturing. Removes hidden MPVolumeView, invalidates KVO, deactivates audio session.
    func stop() {
        guard isRunning else { return }
        outputVolumeObservation?.invalidate()
        outputVolumeObservation = nil

        // Restore the user's original volume before tearing down
        if let slider = volumeSlider {
            slider.value = originalUserVolume
        }

        volumeView?.removeFromSuperview()
        volumeView = nil
        isRunning = false

        // Deactivate audio session so we don't interfere with other audio
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("[VolumeButtonService] Failed to deactivate audio session: \(error)")
        }
    }

    // MARK: - Private Setup

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            print("[VolumeButtonService] Failed to activate audio session: \(error)")
        }
    }

    private func setupVolumeView() {
        let view = MPVolumeView(frame: CGRect(x: -3000, y: -3000, width: 1, height: 1))
        view.isHidden = false
        view.alpha = 0.01
        // NOTE: Do NOT set showsVolumeSlider = false — we need the UISlider subview
        // to exist so we can programmatically restore volume. The view is off-screen
        // and physically invisible.
        self.volumeView = view

        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })?
            .windows.first(where: { $0.isKeyWindow }) ?? UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first?.windows.first
        else { return }

        window.addSubview(view)

        outputVolumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new, .old]) { [weak self] _, change in
            guard let self = self,
                  let newValue = change.newValue,
                  let oldValue = change.oldValue else { return }

            // 1. Ignore programmatic resets back to neutralVolume.
            // If the volume is arriving at 0.5, it was our code doing it, not a user press.
            if abs(newValue - self.neutralVolume) < 0.001 { return }

            // 2. We only care about hardware Volume UP (newValue > oldValue).
            let isVolumeUp = newValue > oldValue
            
            // 3. Immediately reset volume back to 0.5 on ANY hardware press (up or down).
            // This prevents the volume from drifting to 0 or 1.
            DispatchQueue.main.async { self.restoreVolume() }

            // 4. If it was a genuine UP press, check debounce and fire callback.
            if isVolumeUp && abs(newValue - oldValue) > 0.01 {
                let now = CACurrentMediaTime()
                if (now - self.lastAcceptedPress) >= self.debounceInterval {
                    self.lastAcceptedPress = now
                    DispatchQueue.main.async {
                        self.onVolumeUp?()
                    }
                }
            }
        }
    }

    // MARK: - Volume Restore

    /// Convenience accessor for the hidden UISlider inside MPVolumeView.
    private var volumeSlider: UISlider? {
        volumeView?.subviews.first(where: { $0 is UISlider }) as? UISlider
    }

    /// Restore volume to the perfectly safe midpoint (0.5).
    /// By keeping it at exactly 0.5, we guarantee both UP and DOWN presses can be detected,
    /// and we can completely ignore KVO notifications that land at exactly 0.5.
    private func restoreVolume() {
        guard let slider = volumeSlider else { return }
        // Only set if needed to avoid redundant UI updates
        if abs(slider.value - neutralVolume) > 0.001 {
            slider.value = neutralVolume
        }
    }
}