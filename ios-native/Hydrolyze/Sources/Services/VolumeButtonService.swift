import Foundation
import MediaPlayer
import AVFoundation

/// VolumeButtonService — captures hardware volume-up presses via MPVolumeView.
///
/// Two observation paths for iOS 17+ reliability:
///   1. KVO on `AVAudioSession.outputVolume` (primary — system-level)
///   2. KVO on the hidden UISlider subview of MPVolumeView (fallback —
///      iOS 17+ sometimes silences the session KVO; the slider always fires)
///
/// Either path calls the callback. We accept multiple callbacks per
/// press (debounced) and ignore programmatic resets to 0.5.
///
/// PHASE 2.6 v1.15.0: hardened for iOS 17+. The iOS 17.0 release
/// introduced subtle changes to `AVAudioSession.outputVolume` KVO
/// that made the v1.6 service unreliable on iOS 17+ devices. The
/// fix adds the slider subview as a second observation path AND
/// uses a more permissive `.ambient` audio session category.
final class VolumeButtonService {
    private var volumeView: MPVolumeView?
    private var outputVolumeObservation: NSKeyValueObservation?
    private var sliderObservation: NSKeyValueObservation?
    private weak var activeSlider: UISlider?

    /// The target volume we aggressively reset to. 0.5 ensures
    /// maximum headroom for presses in both directions.
    private let neutralVolume: Float = 0.5

    /// The user's actual volume when `start()` was called — restored
    /// on `stop()`.
    private var originalUserVolume: Float = 0.5

    /// Timestamp of the last accepted press — used for debounce.
    private var lastAcceptedPress: CFTimeInterval = 0

    /// Minimum interval between accepted presses (seconds).
    /// 100ms allows fast sequential taps while rejecting hardware bounce.
    private let debounceInterval: CFTimeInterval = 0.1

    /// Called when the volume-up button is pressed (and accepted past debounce).
    var onVolumeUp: (() -> Void)?

    private(set) var isRunning: Bool = false

    // MARK: - Public

    /// Start capturing volume button presses. Adds hidden MPVolumeView
    /// to window hierarchy and sets up both observation paths.
    func start() {
        guard !isRunning else { return }
        originalUserVolume = AVAudioSession.sharedInstance().outputVolume

        setupAudioSession()
        setupVolumeView()
        isRunning = true

        // Force volume to the neutral midpoint immediately so there's
        // room for up presses. Defer to next runloop so the slider
        // subview is in the view hierarchy first.
        DispatchQueue.main.async { [weak self] in
            self?.restoreVolume()
            self?.setupSliderObservation()
        }
    }

    /// Stop capturing. Removes hidden MPVolumeView, invalidates KVO,
    /// deactivates audio session.
    func stop() {
        guard isRunning else { return }
        outputVolumeObservation?.invalidate()
        outputVolumeObservation = nil
        sliderObservation?.invalidate()
        sliderObservation = nil

        // Restore the user's original volume before tearing down
        if let slider = activeSlider {
            slider.value = originalUserVolume
        }

        volumeView?.removeFromSuperview()
        volumeView = nil
        activeSlider = nil
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
        // PHASE 2.6 v1.15.0: use `.ambient` instead of `.playback`.
        // `.playback` requires the app to be the primary audio source;
        // `.ambient` lets the volume change KVO fire reliably even
        // when music is playing in the background. The iOS 17+
        // behavior change made `.playback` + `mixWithOthers` flaky
        // for `outputVolume` KVO.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            print("[VolumeButtonService] Failed to activate audio session: \(error)")
        }
    }

    private func setupVolumeView() {
        let view = MPVolumeView(frame: CGRect(x: -3000, y: -3000, width: 1, height: 1))
        view.isHidden = false
        view.alpha = 0.01
        // NOTE: Do NOT set showsVolumeSlider = false — we need the
        // UISlider subview to exist so we can observe its value
        // (the iOS 17+ fallback path). The view is off-screen and
        // physically invisible.
        self.volumeView = view

        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })?
            .windows.first(where: { $0.isKeyWindow }) ?? UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first?.windows.first
        else {
            print("[VolumeButtonService] Could not find key window — volume button will not work until stopwatch is foregrounded again")
            return
        }

        window.addSubview(view)

        // PRIMARY PATH: KVO on AVAudioSession.outputVolume. This is
        // what the system uses to detect hardware volume button presses.
        // Works in iOS 16 and most iOS 17+ scenarios. Fires when the
        // OS changes the system volume (the hardware button event).
        outputVolumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new, .old]) { [weak self] _, change in
            guard let self = self,
                  let newValue = change.newValue,
                  let oldValue = change.oldValue else { return }
            self.handleVolumeChange(new: newValue, old: oldValue)
        }
    }

    /// FALLBACK PATH (PHASE 2.6 v1.15.0): KVO on the hidden UISlider's
    /// `value`. iOS 17+ sometimes silences the session KVO (especially
    /// after the audio session category change to `.ambient`), but the
    /// slider subview's KVO always fires. We set this up after the
    /// view is in the window hierarchy (deferred from start()).
    private func setupSliderObservation() {
        guard let slider = volumeSlider else {
            // Try once more next runloop — sometimes the slider is
            // added asynchronously by MPVolumeView.
            DispatchQueue.main.async { [weak self] in
                self?.setupSliderObservation()
            }
            return
        }
        activeSlider = slider
        sliderObservation = slider.observe(\.value, options: [.new, .old]) { [weak self] _, change in
            guard let self = self,
                  let newValue = change.newValue,
                  let oldValue = change.oldValue else { return }
            self.handleVolumeChange(new: newValue, old: oldValue)
        }
    }

    /// Common volume-change handler used by both observation paths.
    /// Ignores programmatic resets to neutralVolume; only fires
    /// onVolumeUp for genuine hardware up-presses (new > old).
    private func handleVolumeChange(new newValue: Float, old oldValue: Float) {
        // 1. Ignore programmatic resets back to neutralVolume.
        // If the volume is arriving at 0.5, it was our code doing it,
        // not a user press.
        if abs(newValue - neutralVolume) < 0.001 { return }

        // 2. We only care about hardware Volume UP (newValue > oldValue).
        let isVolumeUp = newValue > oldValue

        // 3. Immediately reset volume back to 0.5 on ANY hardware press
        // (up or down). This prevents the volume from drifting to 0 or 1.
        DispatchQueue.main.async { [weak self] in
            self?.restoreVolume()
        }

        // 4. If it was a genuine UP press, check debounce and fire callback.
        if isVolumeUp && abs(newValue - oldValue) > 0.01 {
            let now = CACurrentMediaTime()
            if (now - lastAcceptedPress) >= debounceInterval {
                lastAcceptedPress = now
                DispatchQueue.main.async { [weak self] in
                    self?.onVolumeUp?()
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
    /// By keeping it at exactly 0.5, we guarantee both UP and DOWN
    /// presses can be detected, and we can completely ignore KVO
    /// notifications that land at exactly 0.5.
    private func restoreVolume() {
        guard let slider = activeSlider ?? volumeSlider else { return }
        // Only set if needed to avoid redundant UI updates
        if abs(slider.value - neutralVolume) > 0.001 {
            slider.value = neutralVolume
        }
    }
}