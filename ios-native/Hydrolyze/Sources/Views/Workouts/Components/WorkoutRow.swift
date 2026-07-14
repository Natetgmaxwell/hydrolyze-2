import SwiftUI

/// WorkoutRow — single row in the WorkoutsListView.
/// Shows date, title, AM/PM badge, status label, chevron.
/// Used inside a List with NavigationLink.
struct WorkoutRow: View {
    let workout: WorkoutRowData

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                if let date = workout.scheduledAt {
                    Text(Self.formatDate(date))
                        .font(.system(size: 11))
                        .foregroundColor(Color.textFaint)
                        .tracking(0.5)
                }

                Text(workout.title ?? "Untitled")
                    .font(.titleSmall)
                    .foregroundColor(Color.textPrimary)

                Text(Self.statusLabel(for: workout.status))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Self.statusColor(for: workout.status))
                    .tracking(0.5)
            }

            Spacer()

            if let amPm = workout.amPm {
                Text(amPm)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color.accentAmber)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentAmber.opacity(0.15))
                    .cornerRadius(4)
            }

            Text("›")
                .font(.system(size: 20))
                .foregroundColor(Color.divider)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MMM d"
        return formatter.string(from: date).uppercased()
    }

    private static func statusLabel(for status: WorkoutStatus) -> String {
        switch status {
        case .draft: return "Draft"
        case .scheduled: return "Scheduled"
        case .inProgress: return "In Progress"
        case .complete: return "Complete"
        }
    }

    private static func statusColor(for status: WorkoutStatus) -> Color {
        switch status {
        case .draft: return Color.accentAmber
        case .scheduled: return Color.accentCyan
        case .inProgress: return Color.accentCyan
        case .complete: return Color.statusSuccess
        }
    }
}

#Preview {
    let workout = Workout(
        id: "1",
        coachId: "coach_1",
        title: "Main Set",
        scheduledAt: "2026-05-17",
        amPm: "AM",
        status: .scheduled,
        createdAt: "",
        updatedAt: ""
    )
    List {
        WorkoutRow(workout: WorkoutRowData(from: workout))
    }
    .background(Color.bgBase)
}