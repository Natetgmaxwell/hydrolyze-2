import SwiftUI

/// TickMarkCelebrationView — the celebration moment that fires after
/// the coach approves all pairing engine matches.
///
/// Visual: a circle draws in (0.0-0.4s), then a tick mark draws inside
/// the circle (0.2-0.6s, overlapping), both stay visible with a gentle
/// breath (0.6-1.1s), then fade out (1.1-1.7s). Total ~1.7s. No text.
/// Cyan stroke on dark background. Haptic.success() fires at the 0.6s
/// mark when both elements are drawn.
///
/// Trigger: SessionReviewView.handleConfirmTap() → after confirmAll
/// resolves. Also fires from the "Confirm Anyway" alert button after
/// confirmAll(force: true) resolves. Both code paths call
/// SessionReviewView.triggerCelebration() to centralize the
/// animation + auto-dismiss sequence.
///
/// Auto-dismiss: the parent view (SessionReviewView) calls dismiss()
/// via @Environment(\.dismiss) after the 1.7s animation completes,
/// popping back to TodayView. The "session approved, you're done"
/// moment is clean and final — no Done button needed.
///
/// Cross-project reuse: the same animation fits Felty's Phoenix
/// badge moment in Felt Faction. Extract to a shared SwiftUI file
/// when the second use case lands. See
/// [[concepts/tick-mark-celebration-pattern]] for the full
/// cross-cutting observation.
struct TickMarkCelebrationView: View {
    @State private var circleProgress: CGFloat = 0
    @State private var tickProgress: CGFloat = 0
    @State private var opacity: Double = 0
    @State private var scale: CGFloat = 0.6

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: circleProgress)
                .stroke(
                    Color.accentAction,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: 80, height: 80)

            TickShape()
                .trim(from: 0, to: tickProgress)
                .stroke(
                    Color.accentAction,
                    style: StrokeStyle(
                        lineWidth: 3,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .frame(width: 40, height: 40)
        }
        .opacity(opacity)
        .scaleEffect(scale)
        .allowsHitTesting(false)
        .onAppear {
            // Phase 1: scale up + circle draws (0.0-0.4s)
            withAnimation(.easeOut(duration: 0.4)) {
                circleProgress = 1.0
                opacity = 1.0
                scale = 1.0
            }

            // Phase 2: tick draws (0.2-0.6s, overlapping circle)
            withAnimation(.easeOut(duration: 0.4).delay(0.2)) {
                tickProgress = 1.0
            }

            // Haptic at the "tick complete" moment (0.6s)
            // The success notification ("ding-ding-rise") is the
            // visceral companion to the visual.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                Haptics.success()
            }

            // Phase 3: fade out (1.1-1.7s)
            withAnimation(.easeInOut(duration: 0.6).delay(1.1)) {
                opacity = 0
                scale = 0.95
            }
        }
        // Accessibility: VoiceOver users get a brief announcement
        // so the celebration moment isn't invisible to them. The
        // visual animation is the primary feedback for sighted
        // users; the announcement is the parallel channel.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Session approved")
    }
}

/// Standard tick mark geometry: starts bottom-left, goes to center,
/// goes to top-right. Drawn as a Path so it can be animated via
/// `.trim(from:to:)` — the standard pattern for stroke-reveal
/// animations in SwiftUI.
private struct TickShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.width * 0.4, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

#Preview {
    ZStack {
        Color.bgBase.ignoresSafeArea()
        TickMarkCelebrationView()
    }
}