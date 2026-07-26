import SwiftUI

/// MyScheduleView — the swimmer's standing weekly pattern.
///
/// v1.17 Slice 6. Renders the *squad's* offered sessions (from
/// `squad_session_slot`) and lets the swimmer tap the ones they normally
/// attend. Not a blank 7×2 grid: you can't mark yourself in for a Sunday PM
/// the squad has never trained.
///
/// This is the screen that makes attendance zero-tap. Set it once, and the
/// resolver treats every matching workout as attended without the swimmer
/// opening the app again — they only come back to deviate.
///
/// Two entry points, one view:
///   - first run (`isFirstRun`), shown as a sheet with a Skip affordance
///   - the Upcoming tab's toolbar, for editing later
struct MyScheduleView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    /// First run softens the framing ("set this once") and offers Skip.
    /// Editing later is just Done.
    var isFirstRun: Bool = false
    var onFinish: (() -> Void)? = nil

    @State private var slots: [SquadSessionSlot] = []
    @State private var selected: Set<SlotKey> = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    /// (weekday, am_pm) — what a squad slot and a standing schedule row have
    /// in common. Selection is keyed on this rather than on slot id so the
    /// swimmer's pattern survives the coach recreating a slot.
    private struct SlotKey: Hashable {
        let weekday: Weekday
        let amPm: SessionSlot
    }

    private var service: ScheduleService { ScheduleService() }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bgBase.ignoresSafeArea()
                content
            }
            .navigationTitle(isFirstRun ? "Your week" : "My schedule")
            .toolbarBackground(Color.bgBase, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                if isFirstRun {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Skip") { finish() }
                            .foregroundStyle(Color.textMuted)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Done") {
                        Task { await save() }
                    }
                    .foregroundStyle(Color.accentCyan)
                    .disabled(isSaving || isLoading)
                }
            }
            .task { await load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            PhasedProgressView(
                phaseCount: 1,
                currentPhase: 0,
                phaseLabels: [],
                currentDescription: "Loading your squad's sessions"
            )
        } else if slots.isEmpty {
            // The coach hasn't defined any sessions yet (Slice 7 gives them
            // the editor). Don't show an empty grid the swimmer can't act on.
            VStack(spacing: 12) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.textFaint)
                Text("No sessions yet")
                    .font(.eyebrowLarge)
                    .foregroundStyle(Color.textMuted)
                Text("Your coach hasn't set the squad's training times. You can still mark individual sessions from Upcoming.")
                    .font(.caption)
                    .foregroundStyle(Color.textFaint)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    intro
                    grid
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(Color.statusError)
                            .padding(.horizontal, 16)
                    }
                }
                .padding(.vertical, 16)
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(isFirstRun ? "Which sessions do you usually swim?" : "Your usual sessions")
                .font(.titleSmall)
                .foregroundStyle(Color.textPrimary)
            Text("Set this once. We'll mark you in for these each week — you only need to come back when you can't make one.")
                .font(.caption)
                .foregroundStyle(Color.textMuted)
        }
        .padding(.horizontal, 16)
    }

    /// One row per day the squad trains, with its AM/PM slots. Days the
    /// squad never trains simply don't appear — less to read, and nothing
    /// to tap that wouldn't mean anything.
    private var grid: some View {
        VStack(spacing: 8) {
            ForEach(Weekday.displayOrder, id: \.self) { day in
                let daySlots = slots.filter { $0.day == day }
                if !daySlots.isEmpty {
                    HStack(spacing: 8) {
                        Text(day.shortLabel)
                            .font(.eyebrow)
                            .foregroundStyle(Color.textFaint)
                            .frame(width: 44, alignment: .leading)
                        ForEach(daySlots) { slot in
                            slotChip(slot)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    private func slotChip(_ slot: SquadSessionSlot) -> some View {
        let key = SlotKey(weekday: slot.day, amPm: slot.slot)
        let isOn = selected.contains(key)
        return Button {
            Haptics.tap()
            if isOn { selected.remove(key) } else { selected.insert(key) }
        } label: {
            Text(slot.displayName)
                .font(.monoChip)
                .foregroundStyle(isOn ? Color.textOnAccent : Color.textMuted)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isOn ? Color.accentCyan : Color.bgRaised)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.75), value: isOn)
    }

    // MARK: - data flow

    private func load() async {
        guard let swimmerId = authManager.currentSwimmer?.id else {
            isLoading = false
            return
        }
        do {
            async let slotFetch = service.fetchSlotsForSwimmer()
            async let scheduleFetch = service.fetchSchedule(swimmerId: swimmerId)
            slots = try await slotFetch
            selected = Set(
                try await scheduleFetch
                    .filter(\.active)
                    .map { SlotKey(weekday: $0.day, amPm: $0.slot) }
            )
        } catch {
            errorMessage = "Couldn't load your squad's sessions."
        }
        isLoading = false
    }

    private func save() async {
        guard let swimmerId = authManager.currentSwimmer?.id else { return }
        isSaving = true
        errorMessage = nil
        do {
            try await service.replaceSchedule(
                swimmerId: swimmerId,
                slots: selected.map { ($0.weekday, $0.amPm) }
            )
            Haptics.success()
            finish()
        } catch {
            errorMessage = "Couldn't save your schedule. Try again."
            Haptics.error()
        }
        isSaving = false
    }

    private func finish() {
        onFinish?()
        dismiss()
    }
}
