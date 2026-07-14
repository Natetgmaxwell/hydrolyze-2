import SwiftUI

/// SwimmerDetailView — single swimmer profile with PB management and group toggling.
/// Presented by NavigationLink push from SwimmersListView.
struct SwimmerDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthManager.self) private var authManager
    @StateObject private var viewModel: SwimmerDetailViewModel
    @State private var showEditSheet = false
    @State private var showPBSheet = false
    @State private var showInviteSheet = false
    @State private var showArchiveAlert = false
    @State private var showDeleteAlert = false

    private var coachId: String? {
        authManager.coachId
    }

    init(swimmerId: String) {
        _viewModel = StateObject(wrappedValue: SwimmerDetailViewModel(swimmerId: swimmerId))
    }

    var body: some View {
        ZStack {
            Color.bgBase.ignoresSafeArea()

            if viewModel.isLoading {
                ProgressView()
                    .tint(Color.accentCyan)
            } else if let swimmer = viewModel.swimmer {
                ScrollView {
                    VStack(spacing: 0) {
                        headerSection(swimmer)
                        mainStrokeSection(swimmer)
                        formStrokeSection(swimmer)
                        groupsSection
                        personalBestsSection
                        progressionSection
                        actionButtons
                    }
                    .padding(.bottom, 40)
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // PHASE 2.8.3: "Invite to App" share icon — opens the
            // InviteSwimmerSheet. Sits before Edit in the trailing
            // toolbar so it doesn't crowd the existing button.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showInviteSheet = true
                } label: {
                    Image(systemName: "person.crop.circle.badge.plus")
                }
                .foregroundColor(Color.accentCyan)
                .accessibilityLabel("Invite to Hydrolyze")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { showEditSheet = true }
                    .foregroundColor(Color.accentCyan)
            }
        }
        .sheet(isPresented: $showEditSheet) {
            SwimmerSheetView(swimmerId: viewModel.swimmerId, onSave: {
                Task { await viewModel.load(coachId: coachId) }
            })
        }
        .sheet(isPresented: $showInviteSheet) {
            if let swimmer = viewModel.swimmer {
                InviteSwimmerSheet(
                    swimmerId: swimmer.id,
                    swimmerName: swimmer.fullName,
                    onDismiss: {}
                )
            }
        }
        .sheet(isPresented: $showPBSheet) {
            PBAddSheet(swimmerId: viewModel.swimmerId, onSave: {
                Task { await viewModel.load(coachId: coachId) }
            })
        }
        .alert("Archive Swimmer?", isPresented: $showArchiveAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Archive", role: .destructive) {
                Task {
                    await viewModel.archiveSwimmer()
                    dismiss()
                }
            }
        } message: {
            Text("\(viewModel.swimmer?.fullName ?? "This swimmer") will be hidden from the active roster but can be restored from Archived.")
        }
        .alert("Delete Swimmer?", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    await viewModel.deleteSwimmer()
                }
            }
        } message: {
            Text("This will permanently delete \(viewModel.swimmer?.fullName ?? "this swimmer") and all their recorded times. This cannot be undone.")
        }
        .task {
            await viewModel.load(coachId: coachId)
        }
    }

    // MARK: - Header

    private func headerSection(_ swimmer: Swimmer) -> some View {
        VStack(spacing: 12) {
            Text(viewModel.initials)
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(Color.accentCyan)
                .frame(width: 56, height: 56)
                .background(Color.bgInset)
                .clipShape(Circle())

            Text(swimmer.fullName)
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(Color.textPrimary)

            if let ageText = viewModel.ageText {
                Text(ageText)
                    .font(.caption)
                    .foregroundColor(Color.textMuted)
            }

            if let notes = swimmer.notes, !notes.isEmpty {
                Text(notes)
                    .font(.caption)
                    .foregroundColor(Color.textFaint)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .padding(.top, 20)
        .padding(.bottom, 20)
    }

    // MARK: - Main Stroke (swimmer's primary competitive event)

    private func mainStrokeSection(_ swimmer: Swimmer) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("MAIN STROKE")
                .font(.eyebrow)
                .foregroundColor(Color.textFaint)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            Button {
                showMainStrokePicker = true
            } label: {
                HStack {
                    Text(swimmer.mainStroke ?? "Not set")
                        .font(.system(size: 17))
                        .foregroundColor(Color.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 12))
                        .foregroundColor(Color.textFaint)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.bgSunken)
            }
            .padding(.bottom, 16)
        }
        .sheet(isPresented: $showMainStrokePicker) {
            StrokePickerSheet(
                title: "Main Stroke",
                strokes: Swimmer.mainStrokeOptions,
                selectedStroke: Binding(
                    get: { swimmer.mainStroke ?? "Free" },
                    set: { newStroke in Task { await viewModel.updateMainStroke(newStroke) } }
                )
            )
        }
    }

    @State private var showMainStrokePicker = false

    // MARK: - Form Stroke (technique focus, never Free)

    private func formStrokeSection(_ swimmer: Swimmer) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("FORM STROKE")
                .font(.eyebrow)
                .foregroundColor(Color.textFaint)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            Button {
                showFormStrokePicker = true
            } label: {
                HStack {
                    Text(swimmer.formStroke ?? "Not set")
                        .font(.system(size: 17))
                        .foregroundColor(Color.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 12))
                        .foregroundColor(Color.textFaint)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.bgSunken)
            }
            .padding(.bottom, 16)
        }
        .sheet(isPresented: $showFormStrokePicker) {
            StrokePickerSheet(
                title: "Form Stroke",
                strokes: Swimmer.formStrokeOptions,
                selectedStroke: Binding(
                    get: { swimmer.formStroke ?? "Form" },
                    set: { newStroke in Task { await viewModel.updateFormStroke(newStroke) } }
                )
            )
        }
    }

    @State private var showFormStrokePicker = false

    // MARK: - Groups

    private var groupsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("GROUPS")
                .font(.eyebrow)
                .foregroundColor(Color.textFaint)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)
            FlowLayout(spacing: 8) {
                ForEach(viewModel.allGroups) { group in
                    let isMember = viewModel.swimmerGroupIds.contains(group.id)
                    Button {
                        Task { await viewModel.toggleGroup(group.id) }
                    } label: {
                        HStack(spacing: 4) {
                            if isMember {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                            }
                            Text(group.name)
                                .font(.captionStrong)
                        }
                        .foregroundColor(isMember ? Color.bgBase : Color.textMuted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(isMember ? Color.accentCyan : Color.bgInset)
                        .cornerRadius(16)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    // MARK: - Personal Bests

    private var personalBestsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("PERSONAL BESTS")
                    .font(.eyebrow)
                    .foregroundColor(Color.textFaint)
                Spacer()
                Button {
                    showPBSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color.accentCyan)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            if viewModel.personalBests.isEmpty {
                Text("No personal bests yet.")
                    .font(.system(size: 14))
                    .foregroundColor(Color.textFaint)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            } else {
                // PHASE 2.6 v1.14.1: sort PBs so the race PB (max
                // intensity) is at the top of the list, followed by
                // descending intensity. Without this, the order
                // depended on the DB row order, which was random.
                ForEach(viewModel.personalBests.sorted { lhs, rhs in
                    intensitySortKey(lhs.intensity ?? "max") < intensitySortKey(rhs.intensity ?? "max")
                }) { pb in
                    pbRow(pb)
                }
            }
        }
    }

    /// Sort key for intensity ordering (race PB first, easy last).
    private func intensitySortKey(_ intensity: String) -> Int {
        switch intensity.lowercased() {
        case "max", "t5", "sprint", "all-out": return 0
        case "threshold", "hard", "t4": return 1
        case "tempo", "t3": return 2
        case "moderate", "cruise", "t2": return 3
        case "easy", "recovery", "t1": return 4
        default: return 5
        }
    }

    private func pbRow(_ pb: SwimmerPB) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(pb.distance)m \(pb.stroke)")
                    .font(.body)
                    .foregroundColor(Color.textPrimary)
                // PHASE 2.6 v1.14.1: show the intensity the PB was set at.
                // Without this label, multiple PBs at the same
                // (distance, stroke) look identical to the coach —
                // e.g., the race PB and the moderate training PB
                // both read as "50m Free 0:29.80" / "0:33.37".
                // The intensity is the disambiguator.
                HStack(spacing: 6) {
                    intensityBadge(pb.intensity ?? "max")
                    if let gear = pb.gear, gear != "none", !gear.isEmpty {
                        gearBadge(gear)
                    }
                }
            }
            Spacer()
            Text(formatTimeMs(pb.timeMs))
                .font(.numeric)
                .foregroundColor(Color.textPrimary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onLongPressGesture {
            showDeletePBAlert = true
            pbToDelete = pb
        }
        .alert("Delete PB?", isPresented: $showDeletePBAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let pb = pbToDelete {
                    Task { await viewModel.deletePB(pb) }
                }
            }
        }
    }

    @State private var showDeletePBAlert = false
    @State private var pbToDelete: SwimmerPB?

    // MARK: - Progression Chart (Phase 3)

    private var progressionSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("PROGRESSION (LAST 30 DAYS)")
                .font(.eyebrow)
                .foregroundColor(Color.textFaint)
                .padding(.horizontal, 16)
                .padding(.top, 24)
                .padding(.bottom, 8)

            ProgressionChart(
                times: viewModel.progressionTimes,
                personalBestMs: viewModel.bestProgressionTimeMs
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button {
                showArchiveAlert = true
            } label: {
                Text("Archive Swimmer")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Color.accentAmber)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.bgInset)
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.accentAmber, lineWidth: 1)
                    )
            }

            Button {
                showDeleteAlert = true
            } label: {
                Text("Delete Swimmer")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Color.statusError)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.bgInset)
                    .cornerRadius(12)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 24)
    }

    // PHASE 2.6 v1.14.1: small badge that disambiguates multiple PBs at
    // the same (distance, stroke). Color-coded by intensity so the
    // race PB is visually distinct from the training PBs.
    @ViewBuilder
    private func intensityBadge(_ intensity: String) -> some View {
        Text(intensity.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(intensityColor(intensity))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(intensityColor(intensity).opacity(0.18))
            .cornerRadius(4)
    }

    @ViewBuilder
    private func gearBadge(_ gear: String) -> some View {
        Text(gear)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(Color.accentCyan)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentCyan.opacity(0.18))
            .cornerRadius(4)
    }

    /// Map intensity → color. The race PB (max) is the canonical
    /// reference and gets the most prominent color. T-codes and
    /// legacy terms all map to the same palette via the RPE-equivalent
    /// bucket.
    private func intensityColor(_ intensity: String) -> Color {
        switch intensity.lowercased() {
        case "max", "t5", "sprint", "all-out":
            return Color(hex: "ff4d6d")  // red — race effort
        case "threshold", "hard", "t4":
            return Color(hex: "ff8c42")  // orange — comfortably hard
        case "tempo", "t3":
            return Color(hex: "ffd166")  // yellow — tempo
        case "moderate", "cruise", "t2":
            return Color.accentCyan  // cyan — aerobic
        case "easy", "recovery", "t1":
            return Color(hex: "06d6a0")  // green — easy
        default:
            return Color.textFaint  // grey — unknown
        }
    }

    private func formatTimeMs(_ ms: Int) -> String {
        let totalSecs = ms / 1000
        let mins = totalSecs / 60
        let secs = totalSecs % 60
        let centis = (ms % 1000) / 10
        return String(format: "%d:%02d.%02d", mins, secs, centis)
    }
}

/// StrokePickerSheet — picker for any stroke field (main or form).
/// Parameterized: caller provides the title and the list of allowed options.
struct StrokePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedStroke: String
    let title: String
    let strokes: [String]

    init(title: String, strokes: [String], selectedStroke: Binding<String>) {
        self.title = title
        self.strokes = strokes
        self._selectedStroke = selectedStroke
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bgBase.ignoresSafeArea()
                List {
                    ForEach(strokes, id: \.self) { stroke in
                        Button {
                            selectedStroke = stroke
                            dismiss()
                        } label: {
                            HStack {
                                Text(stroke)
                                    .font(.system(size: 17))
                                    .foregroundColor(Color.textPrimary)
                                Spacer()
                                if selectedStroke == stroke {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(Color.accentCyan)
                                }
                            }
                        }
                        .listRowBackground(Color.bgSunken)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(Color.accentCyan)
                }
            }
        }
    }
}
