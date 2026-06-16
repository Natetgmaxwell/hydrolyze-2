import SwiftUI

/// SwimmerDetailView — single swimmer profile with PB management and group toggling.
/// Presented by NavigationLink push from SwimmersListView.
struct SwimmerDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthManager.self) private var authManager
    @StateObject private var viewModel: SwimmerDetailViewModel
    @State private var showEditSheet = false
    @State private var showPBSheet = false
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
            Color(hex: "060e18").ignoresSafeArea()

            if viewModel.isLoading {
                ProgressView()
                    .tint(Color(hex: "09d4ee"))
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
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { showEditSheet = true }
                    .foregroundColor(Color(hex: "09d4ee"))
            }
        }
        .sheet(isPresented: $showEditSheet) {
            SwimmerSheetView(swimmerId: viewModel.swimmerId, onSave: {
                Task { await viewModel.load(coachId: coachId) }
            })
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
                .foregroundColor(Color(hex: "09d4ee"))
                .frame(width: 56, height: 56)
                .background(Color(hex: "1a2d42"))
                .clipShape(Circle())

            Text(swimmer.fullName)
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(Color(hex: "e2f4fa"))

            if let ageText = viewModel.ageText {
                Text(ageText)
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "7a9bb0"))
            }

            if let notes = swimmer.notes, !notes.isEmpty {
                Text(notes)
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "4a6572"))
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(hex: "4a6572"))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            Button {
                showMainStrokePicker = true
            } label: {
                HStack {
                    Text(swimmer.mainStroke ?? "Not set")
                        .font(.system(size: 17))
                        .foregroundColor(Color(hex: "e2f4fa"))
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "4a6572"))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(hex: "0d1b2a"))
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(hex: "4a6572"))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            Button {
                showFormStrokePicker = true
            } label: {
                HStack {
                    Text(swimmer.formStroke ?? "Not set")
                        .font(.system(size: 17))
                        .foregroundColor(Color(hex: "e2f4fa"))
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "4a6572"))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(hex: "0d1b2a"))
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(hex: "4a6572"))
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
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundColor(isMember ? Color(hex: "060e18") : Color(hex: "7a9bb0"))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(isMember ? Color(hex: "09d4ee") : Color(hex: "1a2d42"))
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
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: "4a6572"))
                Spacer()
                Button {
                    showPBSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(hex: "09d4ee"))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            if viewModel.personalBests.isEmpty {
                Text("No personal bests yet.")
                    .font(.system(size: 14))
                    .foregroundColor(Color(hex: "4a6572"))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            } else {
                ForEach(viewModel.personalBests) { pb in
                    pbRow(pb)
                }
            }
        }
    }

    private func pbRow(_ pb: SwimmerPB) -> some View {
        HStack {
            Text("\(pb.distance)m \(pb.stroke)")
                .font(.system(size: 15))
                .foregroundColor(Color(hex: "e2f4fa"))
            Spacer()
            Text(formatTimeMs(pb.timeMs))
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .foregroundColor(Color(hex: "e2f4fa"))
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(hex: "4a6572"))
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
                    .foregroundColor(Color(hex: "f59e0b"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color(hex: "1a2d42"))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(hex: "f59e0b"), lineWidth: 1)
                    )
            }

            Button {
                showDeleteAlert = true
            } label: {
                Text("Delete Swimmer")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Color(hex: "ef4444"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color(hex: "1a2d42"))
                    .cornerRadius(12)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 24)
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
                Color(hex: "060e18").ignoresSafeArea()
                List {
                    ForEach(strokes, id: \.self) { stroke in
                        Button {
                            selectedStroke = stroke
                            dismiss()
                        } label: {
                            HStack {
                                Text(stroke)
                                    .font(.system(size: 17))
                                    .foregroundColor(Color(hex: "e2f4fa"))
                                Spacer()
                                if selectedStroke == stroke {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(Color(hex: "09d4ee"))
                                }
                            }
                        }
                        .listRowBackground(Color(hex: "0d1b2a"))
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(Color(hex: "09d4ee"))
                }
            }
        }
    }
}
