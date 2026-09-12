import SwiftUI

/// PhasedProgressView — a 3-dot (or 1-3 dot) cyan phased indicator
/// for async work in progress. Used by TimingView.savingView
/// (3 phases: fetching / pairing / saving) and SessionReviewView
/// rowsList loading state (1 phase: loading).
///
/// Visual: dots connected by horizontal lines. The active dot is
/// cyan and pulses (scale 1.0 → 1.2 → 1.0, 0.8s, repeatForever).
/// Completed dots are filled cyan. Future dots are gray.
///
/// Phase labels appear below the dots in JetBrains Mono for the
/// technical / data-dense feel that matches the existing aesthetic
/// (see TimingView's `formattedLaps` for the mono treatment).
///
/// Micro-interaction: a single visual element that turns "waiting"
/// into "watching progress." Same warmth-through-motion principle
/// as the v1.16 START button breathing ([[concepts/warmth-through-motion]]).
struct PhasedProgressView: View {
    /// Number of phases. 1-5 supported. For TimingView's saving
    /// state, the model has 5 active phases (fetching → predicting
    /// → pairing → saving → complete), so the typical use case
    /// is phaseCount: 5. For SessionReviewView's loading state,
    /// a single phase (loading) is enough.
    let phaseCount: Int
    /// Zero-indexed current phase. If >= phaseCount, the indicator
    /// shows all-complete (all dots filled cyan, no pulsing).
    let currentPhase: Int
    /// Labels for each phase. Optional — if empty, no labels
    /// are rendered (single-phase loading case).
    let phaseLabels: [String]
    /// Optional one-line description below the phase label.
    /// Used by TimingView to surface the most recent saveLog line.
    let currentDescription: String?

    /// Dot diameter scales with phase count so 5-dot layouts stay
    /// compact. 12pt for 1-2 phases, 10pt for 3, 8pt for 4-5.
    private var dotDiameter: CGFloat {
        switch phaseCount {
        case 1, 2: return 12
        case 3: return 10
        default: return 8
        }
    }

    /// Max-width for the indicator. Wider for fewer phases, narrower
    /// for more (so 5-dot layouts fit on iPhone SE).
    private var maxWidth: CGFloat {
        switch phaseCount {
        case 1, 2: return 200
        case 3: return 220
        default: return 260
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            // The phased indicator with connecting lines. Each dot
            // is dotDiameter pt; connecting lines are 1pt gray.
            // Total width is bounded by maxWidth.
            HStack(spacing: 6) {
                ForEach(0..<phaseCount, id: \.self) { index in
                    dotView(for: index)

                    if index < phaseCount - 1 {
                        Rectangle()
                            .fill(Color.textFaint.opacity(0.3))
                            .frame(height: 1)
                            .frame(maxWidth: 16)
                    }
                }
            }
            .frame(maxWidth: maxWidth)

            // Phase label (JetBrains Mono uppercase tracking — matches
            // TimingView's `formattedLaps` and the SAVING/READY labels
            // in the running view). The label animates in/out per
            // phase change via .id() + .transition(.opacity).
            if let label = currentPhaseLabel {
                Text(label)
                    .font(.jetBrainsMono(size: 13, weight: .bold))
                    .foregroundColor(Color.accentAction)
                    .tracking(2)
                    .id("phase-label-\(currentPhase)")
                    .transition(.opacity)
            }

            // Optional description (e.g., the current saveLog tail).
            if let desc = currentDescription, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 12))
                    .foregroundColor(Color.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .lineLimit(2)
            }
        }
        .animation(Animations.gentle, value: currentPhase)
    }

    /// A single dot in the indicator. The dot's color and scale
    /// reflect its state (future / active / complete) via the
    /// `dotState(for:)` helper. The active dot pulses via
    /// `repeatForever(autoreverses: true)` so the user sees
    /// continuous motion without the LLM having to manually
    /// toggle a @State boolean per phase.
    @ViewBuilder
    private func dotView(for index: Int) -> some View {
        let state = dotState(for: index)
        Circle()
            .fill(state.color)
            .frame(width: dotDiameter, height: dotDiameter)
            .scaleEffect(state.scale)
            .modifier(ActivePulseModifier(isActive: state.isActive))
    }

    /// Compute the dot's visual state (color + scale + active flag)
    /// based on its index relative to currentPhase.
    private func dotState(for index: Int) -> (color: Color, scale: CGFloat, isActive: Bool) {
        if currentPhase >= phaseCount {
            // All complete — all dots filled cyan at normal scale.
            return (Color.accentAction, 1.0, false)
        }
        if index < currentPhase {
            return (Color.accentAction, 1.0, false)  // Completed
        }
        if index == currentPhase {
            return (Color.accentAction.opacity(0.7), 1.15, true)  // Active (pulses)
        }
        return (Color.textFaint.opacity(0.3), 1.0, false)  // Future
    }

    /// Optional label for the current phase. Empty string when
    /// currentPhase >= phaseCount (all complete) or when
    /// phaseLabels is empty (single-phase case with no label).
    private var currentPhaseLabel: String? {
        guard currentPhase < phaseCount else { return nil }
        guard !phaseLabels.isEmpty, currentPhase < phaseLabels.count else { return nil }
        return phaseLabels[currentPhase]
    }
}

/// Modifies a view to pulse (scale 1.0 → 1.15 → 1.0) when active,
/// no-op otherwise. Extracted as a modifier so the dot's main
/// configuration stays readable.
private struct ActivePulseModifier: ViewModifier {
    let isActive: Bool
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isActive && isPulsing ? 1.2 : 1.0)
            .animation(
                isActive ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default,
                value: isPulsing
            )
            .onAppear {
                if isActive {
                    isPulsing = true
                }
            }
            .onChange(of: isActive) { _, active in
                isPulsing = active
            }
    }
}

#Preview {
    VStack(spacing: 32) {
        // 3-phase example (Saving state)
        PhasedProgressView(
            phaseCount: 3,
            currentPhase: 1,
            phaseLabels: ["FETCHING", "PAIRING", "SAVING"],
            currentDescription: "Matching taps to swimmers via the pairing engine."
        )

        // 1-phase example (Loading state)
        PhasedProgressView(
            phaseCount: 1,
            currentPhase: 0,
            phaseLabels: [],
            currentDescription: nil
        )

        // All-complete example
        PhasedProgressView(
            phaseCount: 3,
            currentPhase: 3,
            phaseLabels: ["FETCHING", "PAIRING", "SAVING"],
            currentDescription: "Session saved successfully."
        )
    }
    .padding()
    .background(Color.bgBase)
}