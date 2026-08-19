import SwiftUI

/// SquadSessionsEditor — the coach's editor for the squad's weekly session
/// template (slice 7). Tapping an inactive cell activates it; tapping an
/// active cell opens an inline label editor; an empty delete control on
/// each row removes the slot outright.
///
/// Swimmers cannot mark themselves in for a slot that doesn't exist here,
/// so this view is the prerequisite for the entire attendance flow: if
/// the squad has no slots, the standing grid in MyScheduleView renders
/// an empty state and every workout resolves to "out".
struct SquadSessionsEditor: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    let group: CoachGroup

    @State private var slots: [SquadSessionSlot] = []
    @State private var visibility: CoachGroup.Settings.AttendanceVisibility
    @State private var loadingError: String?
    @State private var saving = false
    @State private var editingLabel: SquadSessionSlot? = nil
    @State private var hasLoaded = false

    init(group: CoachGroup) {
        self.group = group
        self._visibility = State(initialValue: group.settings.attendanceVisibility)
    }

    private var service: ScheduleService { ScheduleService() }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bgBase.ignoresSafeArea()
                content
            }
            .navigationTitle("Squad sessions")
            .toolbarBackground(Color.bgBase, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.textPrimary)
                }
            }
            .task { await load() }
            .sheet(item: $editingLabel) { slot in
                SlotLabelEditor(
                    initial: slot.label ?? "",
                    onCommit: { newLabel in
                        Task { await updateLabel(slot: slot, label: newLabel) }
                    }
                )
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !hasLoaded && loadingError == nil {
            ProgressView()
                .tint(Color.textMuted)
        } else if let loadingError {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.accentAmber)
                Text(loadingError)
                    .font(.caption)
                    .foregroundStyle(Color.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("Retry") { Task { await load() } }
                    .font(.caption)
                    .foregroundStyle(Color.textMuted)
            }
            .padding(.top, 60)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    intro
                    grid
                    visibilitySection
                }
                .padding(.vertical, 16)
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Which sessions does this squad run?")
                .font(.titleSmall)
                .foregroundStyle(Color.textPrimary)
            Text("Swimmers can only mark themselves in for sessions you turn on here. Tap a row to label it, or use the toggle to pause it temporarily.")
                .font(.caption)
                .foregroundStyle(Color.textMuted)
        }
        .padding(.horizontal, 16)
    }

    /// One row per Mon..Fri day the squad is configured to train. Cells
    /// render as the active toggle + an inline label field.
    private var grid: some View {
        VStack(spacing: 8) {
            ForEach(Weekday.displayOrder, id: \.self) { day in
                HStack(spacing: 8) {
                    Text(day.shortLabel)
                        .font(.eyebrow)
                        .foregroundStyle(Color.textFaint)
                        .frame(width: 44, alignment: .leading)
                    ForEach(SessionSlot.allCases, id: \.self) { slot in
                        if let existing = slots.first(where: { $0.day == day && $0.slot == slot }) {
                            cell(for: existing)
                        } else {
                            emptyCell(for: day, slot: slot)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func cell(for slot: SquadSessionSlot) -> some View {
        Button {
            Haptics.tap()
            editingLabel = slot
        } label: {
            VStack(spacing: 2) {
                Text(slot.slot.label)
                    .font(.monoChipBold)
                Text(slot.label ?? slot.day.shortLabel)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(slot.active ? Color.textPrimary : Color.textMuted)
            .background(slot.active ? Color.bgSelected : Color.bgRaised)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit label") { editingLabel = slot }
            Button(slot.active ? "Pause" : "Activate") {
                Task { await toggleActive(slot) }
            }
            Button("Delete", role: .destructive) {
                Task { await deleteSlot(slot) }
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.75), value: slot.active)
    }

    private func emptyCell(for day: Weekday, slot: SessionSlot) -> some View {
        Button {
            Haptics.tap()
            Task { await addSlot(for: day, slot: slot) }
        } label: {
            Text("+")
                .font(.title2)
                .foregroundStyle(Color.textFaint)
                .frame(width: 58, height: 44)
                .background(Color.bgRaised.opacity(0.5))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var visibilitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Attendance visibility")
                .font(.eyebrow)
                .foregroundStyle(Color.textMuted)
            Picker("Visibility", selection: $visibility) {
                ForEach(CoachGroup.Settings.AttendanceVisibility.allCases, id: \.self) { v in
                    Text(v == .private ? "Private" : "Squad")
                        .tag(v)
                }
            }
            .pickerStyle(.segmented)
            Text(visibility == .private
                 ? "Swimmers see only their own attendance."
                 : "Swimmers can also see who else is attending each session.")
                .font(.caption)
                .foregroundStyle(Color.textFaint)
        }
        .padding(.horizontal, 16)
        .onChange(of: visibility) { _, newValue in
            Task { await saveVisibility(newValue) }
        }
    }

    // MARK: - data flow

    private func load() async {
        do {
            slots = try await service.fetchAllSquadSlots(groupId: group.id)
            hasLoaded = true
        } catch {
            loadingError = "Couldn't load this squad's sessions."
            hasLoaded = true
        }
    }

    private func addSlot(for day: Weekday, slot: SessionSlot) async {
        saving = true
        defer { saving = false }
        do {
            try await service.setSquadSlot(
                groupId: group.id, weekday: day, amPm: slot,
                label: nil, active: true
            )
            await load()
        } catch {
            loadingError = "Couldn't add that session. Try again."
        }
    }

    private func updateLabel(slot: SquadSessionSlot, label: String) async {
        do {
            try await service.setSquadSlot(
                groupId: group.id, weekday: slot.day, amPm: slot.slot,
                label: label, active: slot.active
            )
            await load()
        } catch {
            loadingError = "Couldn't save the label. Try again."
        }
    }

    private func toggleActive(_ slot: SquadSessionSlot) async {
        do {
            try await service.setSquadSlotActive(slotId: slot.id, active: !slot.active)
            await load()
        } catch {
            loadingError = "Couldn't change that session. Try again."
        }
    }

    private func deleteSlot(_ slot: SquadSessionSlot) async {
        do {
            try await service.deleteSquadSlot(slotId: slot.id)
            await load()
        } catch {
            loadingError = "Couldn't delete that session. Try again."
        }
    }

    private func saveVisibility(_ v: CoachGroup.Settings.AttendanceVisibility) async {
        var settings = group.settings
        settings.attendanceVisibility = v
        do {
            try await service.updateGroupSettings(groupId: group.id, settings: settings)
        } catch {
            loadingError = "Couldn't save the visibility setting. Try again."
        }
    }
}

/// Label editor — a single text field on a small sheet. Kept inline so the
/// coach doesn't leave the grid to relabel a slot.
private struct SlotLabelEditor: View {
    @Environment(\.dismiss) private var dismiss
    let initial: String
    let onCommit: (String) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            TextField("Label", text: $text)
                .textInputAutocapitalization(.words)
                .padding(16)
                .background(Color.bgRaised)
                .focused($focused)
                .navigationTitle("Session label")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            onCommit(text.trimmingCharacters(in: .whitespaces))
                            dismiss()
                        }
                    }
                }
                .onAppear {
                    text = initial
                    focused = true
                }
                .presentationDetents([.height(200)])
        }
    }
}
