import SwiftUI

/// WorkoutCard — shows a single scheduled workout with AM/PM badge, title, set summary,
/// swimmer/set counts, and a "Start Session" CTA button.
///
/// Micro-interactions: the AM/PM amber badge has a soft breathing
/// glow so the card reads as "live, scheduled for today" rather
/// than "static metadata." The card itself is not tappable —
/// the explicit Start Session button is the action surface (no
/// tap ambiguity).
struct WorkoutCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool
    @State private var animateIn: Bool = false

    let workout: Workout
    let setCount: Int
    let swimmerCount: Int
    let onStartSession: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(workout.amPm ?? "AM")
                        .font(.numericSmall)
                        .foregroundColor(Color.accentAmber)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentAmber.opacity(0.15))
                        .cornerRadius(4)
                        // Soft breathing on the amber chip — the
                        // card "feels scheduled" not "filed."
                        .phaseAnimator([0.15, 0.25], trigger: animateIn && !reduceMotion) { content, opacity in
                            content.background(Color.accentAmber.opacity(opacity))
                        } animation: { _ in
                            .easeInOut(duration: 1.8)
                        }

                    Text(workout.title ?? "Workout")
                        .font(.titleSmall)
                        .foregroundColor(Color.textPrimary)
                }
                Spacer()
            }

            Text(setDescription)
                .font(.caption)
                .foregroundColor(Color.textMuted)
                .lineLimit(1)

            Text("\(swimmerCount) swimmers · \(setCount) sets")
                .font(.caption)
                .foregroundColor(Color.textFaint)

            PrimaryButton(title: "Start Session", isLoading: false, action: onStartSession)
        }
        .padding(16)
        .background(Color.bgSunken)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.divider, lineWidth: 1)
        )
        .onAppear { animateIn = true }
    }

    private var setDescription: String {
        "Tap to view sets"
    }
}

#Preview {
    WorkoutCard(
        workout: Workout(
            id: "1",
            coachId: "c1",
            title: "Main Set",
            description: nil,
            scheduledAt: nil,
            amPm: "AM",
            completedAt: nil,
            status: .scheduled,
            createdAt: "",
            updatedAt: ""
        ),
        setCount: 8,
        swimmerCount: 6,
        onStartSession: {}
    )
    .padding()
    .background(Color.bgBase)
}
