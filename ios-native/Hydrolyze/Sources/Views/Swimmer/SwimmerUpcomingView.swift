import SwiftUI

/// SwimmerUpcomingView — the Upcoming tab for the swimmer home.
/// Shows the next 7 days of scheduled sessions; the swimmer taps
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
    @State private var sessions: [UpcomingSession] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var togglingSessionId: String?

    private var service: IntentService { IntentService() }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "060e18").ignoresSafeArea()

                content
            }
            .navigationTitle("Upcoming")
            .toolbarBackground(Color(hex: "060e18"), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .task {
                await load()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && sessions.isEmpty {
            // PhasedProgressView already exists; matches the v1.16
            // loading vocabulary.
            PhasedProgressView()
        } else if let error = errorMessage, sessions.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundStyle(Color(hex: "f59e0b"))
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    Task { await load() }
                }
                .buttonStyle(.bordered)
            }
        } else if sessions.isEmpty {
            // No upcoming sessions this week.
            EmptyStateView()
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(sessions) { session in
                        UpcomingSessionRow(
                            session: session,
                            isToggling: togglingSessionId == session.id,
                            onMarkIn: {
                                Task { await markIntent(session, intent: "in") }
                            },
                            onMarkOut: {
                                Task { await markIntent(session, intent: "out") }
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
        guard let swimmerId = authManager.currentSwimmer?.id else {
            errorMessage = "No swimmer profile linked."
            isLoading = false
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            let upcoming = try await service.fetchUpcomingSessions()
            // Filter to the swimmer's relevant sessions only — the
            // service already returns the next 7 days. Ponytail: if
            // we ever need to filter by group / event, promote this
            // out of the view.
            _ = swimmerId  // referenced for future filter
            sessions = upcoming
            isLoading = false
        } catch {
            errorMessage = "Couldn't load upcoming sessions.\n\(error.localizedDescription)"
            isLoading = false
        }
    }

    private func markIntent(_ session: UpcomingSession, intent: String) async {
        guard let swimmerId = authManager.currentSwimmer?.id else { return }
        togglingSessionId = session.id

        // Optimistic update — flip the local row first, then write.
        // The Realtime channel will reconcile if the write fails.
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx] = UpcomingSession(
                id: sessions[idx].id,
                date: sessions[idx].date,
                slot: sessions[idx].slot,
                swimmerCount: sessions[idx].swimmerCount,
                myIntent: intent
            )
        }

        Haptics.tap()

        do {
            try await service.markIntent(
                sessionId: session.id,
                swimmerId: swimmerId,
                intent: intent
            )
        } catch {
            // Revert on failure
            if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
                sessions[idx] = UpcomingSession(
                    id: sessions[idx].id,
                    date: sessions[idx].date,
                    slot: sessions[idx].slot,
                    swimmerCount: sessions[idx].swimmerCount,
                    myIntent: session.myIntent
                )
            }
            errorMessage = "Couldn't save. Try again."
            Haptics.error()
        }

        togglingSessionId = nil
    }
}

/// UpcomingSessionRow — one row per upcoming session. Shows date,
/// AM/PM slot, planned squad size, and the two intent pills.
/// ponytail: pills are side-by-side, ~half width each, no icons.
/// Already-marked state shows the chosen pill filled.
private struct UpcomingSessionRow: View {
    let session: UpcomingSession
    let isToggling: Bool
    let onMarkIn: () -> Void
    let onMarkOut: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(formattedDate)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(session.slot)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color(hex: "f59e0b"))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(hex: "f59e0b").opacity(0.18))
                    )
                Spacer()
                if session.swimmerCount > 0 {
                    Text("\(session.swimmerCount) planned")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                IntentPill(
                    label: "I'm in",
                    isSelected: session.myIntent == "in",
                    isDisabled: isToggling,
                    accent: Color(hex: "06b6d4"),
                    action: onMarkIn
                )
                IntentPill(
                    label: "Can't make it",
                    isSelected: session.myIntent == "out",
                    isDisabled: isToggling,
                    accent: Color(hex: "71717a"),
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
        guard let date = ISO8601DateParser.parse(session.date) else {
            return session.date
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
                .foregroundStyle(isSelected ? Color(hex: "060e18") : .white)
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