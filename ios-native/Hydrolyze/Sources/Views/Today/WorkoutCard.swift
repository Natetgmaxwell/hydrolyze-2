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
    let workout: Workout
    let setCount: Int
    let swimmerCount: Int
    let onStartSession: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(workout.amPm ?? "AM")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(hex: "f59e0b"))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(hex: "f59e0b").opacity(0.15))
                        .cornerRadius(4)
                        // Soft breathing on the amber chip — the
                        // card "feels scheduled" not "filed."
                        .phaseAnimator([0.15, 0.25], trigger: true) { content, opacity in
                            content.background(Color(hex: "f59e0b").opacity(opacity))
                        } animation: { _ in
                            .easeInOut(duration: 1.8)
                        }

                    Text(workout.title ?? "Workout")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(Color(hex: "e2f4fa"))
                }
                Spacer()
            }

            Text(setDescription)
                .font(.system(size: 13))
                .foregroundColor(Color(hex: "7a9bb0"))
                .lineLimit(1)

            Text("\(swimmerCount) swimmers · \(setCount) sets")
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "4a6572"))

            PrimaryButton(title: "Start Session", isLoading: false, action: onStartSession)
        }
        .padding(16)
        .background(Color(hex: "0d1b2a"))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(hex: "2d3e50"), lineWidth: 1)
        )
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
    .background(Color(hex: "060e18"))
}
