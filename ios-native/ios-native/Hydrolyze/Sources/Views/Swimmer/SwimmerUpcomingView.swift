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
    /// v1.17 Slice 6: first-run prompt. A swimmer with no standing pattern
    /// resolves to "out" for everything (spec Q2), which is correct but a
    /// cold-start cliff — so we ask once, on the screen where it matters.
    @State private var showSchedule = false
    @State private var isFirstRunPrompt = false
    @State private var didPromptThisSession = false
    /// v1.17 Slice 8d: visible attendance roster per workout. RLS-gated,
    /// so an empty array here means "this squad is private" or "no one has
    /// marked in yet" — both render identically (the row simply doesn't
    /// appear). The swimmer does not see the absence of a feature.
    @State private var rosters: [String: [IntentService.RosterEntry]] = [:]

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
            .sheet(isPresented: $showSchedule) {
                MyScheduleView(isFirstRun: isFirstRunPrompt) {
                    // Reload: the standing pattern the swimmer just set
                    // changes what every upcoming row resolves to.
                    Task { await load() }
                }
                .environment(authManager)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Haptics.selection()
                        isFirstRunPrompt = false
                        showSchedule = true
                    } label: {
                        Image(systemName: "calendar.badge.clock")
                    }
                    .foregroundStyle(Color.accentAction)
                    .accessibilityLabel("My schedule")
                }
            }
            .task {
                await load()
                await promptForScheduleIfNeeded()
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
                            roster: rosters[workout.id] ?? [],
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

    /// Ask once per app session, and only when the swimmer genuinely has no
    /// standing pattern. Deliberately NOT persisted to UserDefaults: if they
    /// skip and later wonder why nothing is pre-marked, seeing the prompt
    /// again next launch is the fix, not a bug. A swimmer who sets even one
    /// slot never sees it again.
    private func promptForScheduleIfNeeded() async {
        guard !didPromptThisSession,
              let swimmerId = authManager.currentSwimmer?.id else { return }
        didPromptThisSession = true
        guard let hasSchedule = try? await ScheduleService().hasSchedule(swimmerId: swimmerId),
              !hasSchedule else { return }
        isFirstRunPrompt = true
        showSchedule = true
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        // v1.17 Slice 3: the fetch is now swimmer-scoped. Without an
        // identity there is nothing to resolve, so show the empty state
        // rather than a list built from someone else's rows.
        guard let swimmerId = authManager.currentSwimmer?.id else {
            workouts = []
            isLoading = false
            return
        }
        do {
            workouts = try await service.fetchUpcomingWorkouts(swimmerId: swimmerId)
            // Slice 8d: rosters in parallel. Each fetch is gated by
            // swimmer_squad_attendance_read; a private squad returns
            // [] silently, so the row just doesn't render.
            rosters = await withTaskGroup(of: (String, [IntentService.RosterEntry]).self) { group in
                for w in workouts {
                    let id = w.id
                    group.addTask { (id, (try? await self.service.fetchRoster(forWorkoutId: id)) ?? []) }
                }
                var result: [String: [IntentService.RosterEntry]] = [:]
                for await (id, entries) in group { result[id] = entries }
                return result
            }
            isLoading = false
        } catch {
            errorMessage = "Couldn't load upcoming workouts.\n\(error.localizedDescription)"
            isLoading = false
        }
    }

    private func markIntent(_ workout: UpcomingWorkout, intent: String) async {
        guard let swimmerId = authManager.currentSwimmer?.id else { return }
        togglingWorkoutId = workout.id

        // Optimistic update — flip the local row first, then write. An
        // explicit mark beats the standing pattern, so `marked` flips the
        // reason too and the row keeps its shape on reload.
        if let idx = workouts.firstIndex(where: { $0.id == workout.id }) {
            workouts[idx] = workout.marked(intent)
        }

        Haptics.tap()

        do {
            try await service.markIntent(
                workoutId: workout.id,
                swimmerId: swimmerId,
                intent: intent
            )
        } catch {
            // Revert to exactly what the server last told us.
            if let idx = workouts.firstIndex(where: { $0.id == workout.id }) {
                workouts[idx] = workout
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
    let roster: [IntentService.RosterEntry]
    let isToggling: Bool
    let onMarkIn: () -> Void
    let onMarkOut: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(workout.title)
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)
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

            // v1.17 Slice 6: why this row looks the way it does. A swimmer
            // whose "I'm in" is filled by their standing pattern should see
            // that it wasn't them tapping it — otherwise the one case that
            // matters ("I can't make Wednesday") looks already handled.
            if workout.isFromStandingSchedule {
                Text("From your usual schedule")
                    .font(.caption)
                    .foregroundStyle(Color.textFaint)
            }

            // v1.17 Slice 8d: who else is in. RLS-gated — an empty array
            // means the squad is private (default) or nobody has marked in
            // yet. Both render identically: the row simply doesn't appear.
            // No "this is hidden by your settings" caption, no
            // affordance suggesting the swimmer can change it (they can't).
            if !roster.isEmpty {
                RosterLine(roster: roster)
            }

            HStack(spacing: 10) {
                IntentPill(
                    label: "I'm in",
                    isSelected: workout.isAttending,
                    isDisabled: isToggling,
                    accent: Color.accentActionDim,
                    action: onMarkIn
                )
                IntentPill(
                    label: "Can't make it",
                    isSelected: !workout.isAttending && workout.hasMarked,
                    isDisabled: isToggling,
                    accent: Color.textFaint,
                    action: onMarkOut
                )
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.textPrimary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.textPrimary.opacity(0.06), lineWidth: 1)
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

/// RosterLine — the "X others attending" line under the pills.
///
/// Shows the first three names, with a "+N" suffix if there are more.
/// Three is the right cap: long lists in a single-line caption become
/// unreadable on a phone, and the swimmer's only actionable takeaway
/// is "people are coming". The coach's view has the full list; this
/// is the lightweight version for the swimmer's own decision-making.
private struct RosterLine: View {
    let roster: [IntentService.RosterEntry]

    private static let maxNames = 3

    private var caption: String {
        let firstNames = roster.prefix(Self.maxNames).map { ($0.firstName?.nonEmpty) ?? "—" }
        let shown = firstNames.joined(separator: ", ")
        let extra = roster.count - firstNames.count
        if extra > 0 {
            return "\(shown) + \(extra) more"
        }
        return shown
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.2.fill")
                .font(.caption)
                .foregroundStyle(Color.textFaint)
            Text(caption)
                .font(.caption)
                .foregroundStyle(Color.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

private extension String {
    /// Empty-string → nil, so displayName joins cleanly.
    var nonEmpty: String? { isEmpty ? nil : self }
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
                .foregroundStyle(isSelected ? Color.textOnAccent : Color.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? accent : Color.textPrimary.opacity(0.08))
                )
        }
        .buttonStyle(PressFeedbackStyle())
        .disabled(isDisabled)
    }
}