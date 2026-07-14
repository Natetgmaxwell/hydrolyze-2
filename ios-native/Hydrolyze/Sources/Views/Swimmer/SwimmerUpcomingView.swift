import SwiftUI

/// SwimmerUpcomingView — the Upcoming tab for the swimmer home.
/// Shows the next 7 days of scheduled workouts; the swimmer taps
/// "I'm in" or "Can't make it" on each row. Writes go through
/// IntentService, which upserts into swimmer_attendance_intent.
///
/// See originals/hydrolyze-coach-self-mark-attendance-v1 for the
/// design rationale.
///
/// ponytail:
///   - The view-model is the @State list + an isLoading flag.
///     Adding a real ObservableObject is premature.
///   - The intent pills are inline in each row (not a separate
///     detail screen). One tap to mark. Matches the existing
///     row-tap vocabulary (SwimmersListView, SessionReviewView).
///   - Empty state uses the shared EmptyStateView (already exists).
struct SwimmerUpcomingView: View {
    @Environment(AuthManager.self) private var authManager
    @State private var workouts: [UpcomingWorkout] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var togglingWorkoutId: String?

    private var service: IntentService { IntentService() }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bgBase.ignoresSafeArea()

                content
            }
            .navigationTitle("Upcoming")
            .toolbarBackground(Color.bgBase, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .task {
                await load()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && workouts.isEmpty {
            // PhasedProgressView already exists; matches the v1.16
            // loading vocabulary. One phase = "loading".
            PhasedProgressView(
                phaseCount: 1,
                currentPhase: 0,
                phaseLabels: [],
                currentDescription: "Loading this week's practices"
            )
        } else if let error = errorMessage, workouts.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.accentAmber)
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    Task { await load() }
                }
                .buttonStyle(.bordered)
            }
        } else if workouts.isEmpty {
            // No upcoming workouts this week.
            EmptyStateView()
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(workouts) { workout in
                        UpcomingWorkoutRow(
                            workout: workout,
                            isToggling: togglingWorkoutId == workout.id,
                            onMarkIn: {
                                Task { await markIntent(workout, intent: "in") }
                            },
                            onMarkOut: {
                                Task { await markIntent(workout, intent: "out") }
                            }
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - data flow

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            workouts = try await service.fetchUpcomingWorkouts()
            isLoading = false
        } catch {
            errorMessage = "Couldn't load upcoming workouts.\n\(error.localizedDescription)"
            isLoading = false
        }
    }

    private func markIntent(_ workout: UpcomingWorkout, intent: String) async {
        guard let swimmerId = authManager.currentSwimmer?.id else { return }
        togglingWorkoutId = workout.id

        // Optimistic update — flip the local row first, then write.
        if let idx = workouts.firstIndex(where: { $0.id == workout.id }) {
            workouts[idx] = UpcomingWorkout(
                id: workouts[idx].id,
                title: workouts[idx].title,
                date: workouts[idx].date,
                slot: workouts[idx].slot,
                myIntent: intent
            )
        }

        Haptics.tap()

        do {
            try await service.markIntent(
                workoutId: workout.id,
                swimmerId: swimmerId,
                intent: intent
            )
        } catch {
            // Revert on failure
            if let idx = workouts.firstIndex(where: { $0.id == workout.id }) {
                workouts[idx] = UpcomingWorkout(
                    id: workouts[idx].id,
                    title: workouts[idx].title,
                    date: workouts[idx].date,
                    slot: workouts[idx].slot,
                    myIntent: workout.myIntent
                )
            }
            errorMessage = "Couldn't save. Try again."
            Haptics.error()
        }

        togglingWorkoutId = nil
    }
}

/// UpcomingWorkoutRow — one row per upcoming workout. Shows date,
/// AM/PM slot, workout title, and the two intent pills.
/// ponytail: pills are side-by-side, ~half width each, no icons.
/// Already-marked state shows the chosen pill filled.
private struct UpcomingWorkoutRow: View {
    let workout: UpcomingWorkout
    let isToggling: Bool
    let onMarkIn: () -> Void
    let onMarkOut: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(workout.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                HStack(spacing: 6) {
                    Text(formattedDate)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(workout.slot)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.accentAmber)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.accentAmber.opacity(0.18))
                        )
                }
            }

            HStack(spacing: 10) {
                IntentPill(
                    label: "I'm in",
                    isSelected: workout.myIntent == "in",
                    isDisabled: isToggling,
                    accent: Color.accentCyanDim,
                    action: onMarkIn
                )
                IntentPill(
                    label: "Can't make it",
                    isSelected: workout.myIntent == "out",
                    isDisabled: isToggling,
                    accent: Color.accentSlate,
                    action: onMarkOut
                )
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private var formattedDate: String {
        // The DB returns DATE columns as "YYYY-MM-DD" (not full ISO8601).
        // Parse it directly without ISO8601DateParser.
        let parts = workout.date.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return workout.date
        }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = Calendar.current.date(from: components) else {
            return workout.date
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: date)
    }
}

/// IntentPill — a single tap target for marking intent. Selected
/// state fills with the accent; unselected is ghost.
///
/// ponytail: the pill is two Text + padding + background. No
/// Image. No gradient. No custom shape. The standard SwiftUI
/// pill vocabulary, scoped to this view.
private struct IntentPill: View {
    let label: String
    let isSelected: Bool
    let isDisabled: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isSelected ? Color.bgBase : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? accent : Color.white.opacity(0.08))
                )
        }
        .buttonStyle(PressFeedbackStyle())
        .disabled(isDisabled)
    }
}