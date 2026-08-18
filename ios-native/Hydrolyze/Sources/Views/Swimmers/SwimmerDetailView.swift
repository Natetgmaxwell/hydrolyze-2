import SwiftUI
import Charts

/// SwimmerDetailView — single swimmer profile with PB management and group toggling.
/// Presented by NavigationLink push from SwimmersListView.
struct SwimmerDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthManager.self) private var authManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool
    @StateObject private var viewModel: SwimmerDetailViewModel
    @State private var showEditSheet = false
    @State private var showPBSheet = false
    @State private var showInviteSheet = false
    @State private var showArchiveAlert = false
    @State private var showDeleteAlert = false
    @State private var showTransferSheet = false
    // ponytail (warmth-through-motion iter 6): on-appear reveal.
    // Same pattern as login reveal (d46c444), today reveal (0a90257),
    // workouts reveal (06c6823), swimmers reveal (61404f1, 1ffa02c),
    // and workouts+swimmers cohesion (19e0e9f). When the SwimmerDetail
    // is pushed, the content fades + scales in over Animations.springSoft,
    // gated by Reduce Motion for a11y.
    @State private var animateIn: Bool = false

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
                        // V0.40 Slice 3 (2026-08-18): training
                        // zones section. Shown ONLY when the VM
                        // has a derived `trainingZones` value
                        // (the swimmer has a usable profile —
                        // trial ≥ 2, no learning flag). The
                        // @ViewBuilder gate inside `zonesSection`
                        // returns `EmptyView` when the property
                        // is nil, so no "no zones yet" chrome
                        // ever appears — the section is hidden
                        // cleanly when the swimmer has no usable
                        // 3MT profile.
                        zonesSection
                        progressionSection
                        // V0.42 Slice 2 + 3 (2026-08-18): recovery
                        // signature + revert flag + sparkline.
                        // Renders ONLY when the VM has a signature
                        // line (data-absent = hidden; never greyed-
                        // out chrome). @ViewBuilder-gated via the
                        // if-let inside `recoverySection` itself.
                        recoverySection
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
        .sheet(isPresented: $showTransferSheet) {
            if let swimmer = viewModel.swimmer {
                TransferSwimmerSheet(swimmer: swimmer, onTransferred: {
                    Task { await viewModel.load(coachId: coachId) }
                })
            }
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
        // ponytail: swimmer detail fade-in on push. Gating by
        // reduceMotion is the standard a11y pattern (matches d46c444,
        // 0a90257, 06c6823, 61404f1, 1ffa02c, 19e0e9f).
        .opacity(animateIn ? 1.0 : 0.0)
        .scaleEffect(animateIn ? 1.0 : 0.98)
        .animation(reduceMotion ? nil : Animations.springSoft, value: animateIn)
        .onAppear { animateIn = true }
    }

    // MARK: - Header

    private func headerSection(_ swimmer: Swimmer) -> some View {
        VStack(spacing: 12) {
            Text(viewModel.initials)
                .font(.titleLarge)
                .foregroundColor(Color.accentCyan)
                .frame(width: 56, height: 56)
                .background(Color.bgInset)
                .clipShape(Circle())

            Text(swimmer.fullName)
                .font(.titleLarge)
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
            Text("Main stroke")
                .font(.eyebrow)
                .foregroundColor(Color.textFaint)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            Button {
                showMainStrokePicker = true
            } label: {
                HStack {
                    Text(swimmer.mainStroke ?? "Not set")
                        .font(.titleSmall)
                        .foregroundColor(Color.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
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
            Text("Form stroke")
                .font(.eyebrow)
                .foregroundColor(Color.textFaint)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            Button {
                showFormStrokePicker = true
            } label: {
                HStack {
                    Text(swimmer.formStroke ?? "Not set")
                        .font(.titleSmall)
                        .foregroundColor(Color.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
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
            Text("Groups")
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
                                    .font(.eyebrow)
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
                Text("Personal bests")
                    .font(.eyebrow)
                    .foregroundColor(Color.textFaint)
                Spacer()
                Button {
                    showPBSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.captionStrong)
                        .foregroundColor(Color.accentCyan)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            if viewModel.personalBests.isEmpty {
                Text("No personal bests yet.")
                    .font(.caption)
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
                // V0.44 Slice 3 (2026-08-18): tell 8 — section expand.
                // Animate the PB row count so newly fetched PBs
                // settle in with Animations.springSoft ("section
                // expand" per the spec table). SwimmerPB isn't
                // Equatable, so the .animation(value:) is driven off
                // the count — covers the async load-from-DB arrival
                // (0→N) and any future add/delete without model
                // surgery. Gated by reduceMotion for a11y.
                .animation(reduceMotion ? nil : Animations.springSoft, value: viewModel.personalBests.count)
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

    // MARK: - V0.40 Training Zones (Slice 3, 2026-08-18)

    /// V0.40 Slice 3 (2026-08-18): training zones section. One
    /// glanceable line per zone (Easy / Steady / Hard / Sprint)
    /// with the per-100m pace from the most recent usable 3MT
    /// profile. Hidden entirely when the VM has no derived
    /// `trainingZones` — the @ViewBuilder gate returns
    /// `EmptyView` and the section is removed from the layout
    /// (no "no zones yet" chrome, no greyed-out rows).
    ///
    /// Sits between `personalBestsSection` and `progressionSection`
    /// per the slice 3 brief — the zones are derived from the
    /// swimmer's 3MT profile, which is conceptually adjacent to
    /// the PBs (per-swimmer derived metrics) and ahead of the
    /// progression chart (which is per-set recorded times).
    ///
    /// Tap-for-detail is explicitly deferred to a future slice
    /// (V0.41 per the spec); the section is read-only.
    @ViewBuilder
    private var zonesSection: some View {
        if let zones = viewModel.trainingZones {
            VStack(alignment: .leading, spacing: 0) {
                Text("Training zones")
                    .font(.eyebrow)
                    .foregroundColor(Color.textFaint)
                    .padding(.horizontal, 16)
                    .padding(.top, 24)
                    .padding(.bottom, 8)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(
                        TrainingZoneService.zoneLineSegments(zones),
                        id: \.label
                    ) { segment in
                        Text("\(segment.label): \(segment.paceString)")
                            .font(.caption)
                            .foregroundColor(Color.textPrimary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                // V0.44 Slice 3 (2026-08-18): tell 8 — section expand.
                // TrainingZones is Equatable (see TrainingZoneService
                // line 41), so the .animation(value:) is driven off
                // the struct directly. The section fires when zones
                // transitions nil → set (the @ViewBuilder gate
                // above); .animation makes the settled-in reveal use
                // Animations.springSoft — matching the spec table's
                // "section expand = springSoft" language. Gated by
                // reduceMotion for a11y.
                .animation(reduceMotion ? nil : Animations.springSoft, value: viewModel.trainingZones)
            }
        }
    }

    // MARK: - Progression Chart (Phase 3)

    private var progressionSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Progression (last 30 days)")
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

    // MARK: - V0.42 Recovery Signature (Slice 2 + 3, 2026-08-18)
//
// Pure pass-through from the VM. The section is `@ViewBuilder`
// (the if-let returns EmptyView when the line is nil) so the
// gating matches the V0.42 spec: data-absent = section does not
// appear at all. The sparkline inside is gated on
// `hasEightWeeksOfData` (8 distinct weeks of strike rows) —
// otherwise hidden. The revert flag is a single inline line in
// `Color.accentAmber`, no modal surface.

@ViewBuilder
private var recoverySection: some View {
    if let line = viewModel.recoverySignatureLine {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recovery strain")
                .font(.eyebrow)
                .foregroundColor(Color.textFaint)
                .padding(.horizontal, 16)
                .padding(.top, 24)
                .padding(.bottom, 4)

            Text(line)
                .font(.body)
                .foregroundColor(Color.textPrimary)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)

            if viewModel.hasEightWeeksOfData {
                // Sparkline: small, ~48pt tall. LineMark over the
                // week-start x-axis vs strikes-per-100-reps y-axis.
                // Colors reuse the existing palette (`accentCyan`
                // matches ProgressionChart/TrendChart). The x-axis
                // labels would be unreadable at this height, so we
                // hide them — the eyebrow + signature line above
                // tell the coach what they're looking at.
                Chart(viewModel.weeklyStrain) { point in
                    LineMark(
                        x: .value("Week", point.weekStartISO),
                        y: .value("Strain", point.strikesPer100Reps)
                    )
                    .foregroundStyle(Color.accentCyan)
                    .interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartPlotStyle { plot in
                    plot.background(Color.bgInset.opacity(0.4))
                        .cornerRadius(6)
                }
                .frame(height: 48)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            if let flag = viewModel.revertFlag {
                // Slice 3 (2026-08-18): one inline line in
                // `accentAmber`, `caption` type, never modal. The
                // VM gates this on `revertRate > 0.30` (a LOCKED
                // threshold inside `RecoveryAggregator`); we just
                // render the resulting copy.
                Text(flag)
                    .font(.caption)
                    .foregroundColor(Color.accentAmber)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
        }
    }
}

// MARK: - Action Buttons

    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button {
                showTransferSheet = true
            } label: {
                Text("Transfer to Coach")
                    .font(.body)
                    .foregroundColor(Color.accentCyan)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.bgInset)
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.accentCyan, lineWidth: 1)
                    )
            }

            Button {
                showArchiveAlert = true
            } label: {
                Text("Archive Swimmer")
                    .font(.titleSmall)
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
                    .font(.titleSmall)
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
            .font(.monoChipBold)
            .foregroundColor(intensityColor(intensity))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(intensityColor(intensity).opacity(0.18))
            .cornerRadius(4)
    }

    @ViewBuilder
    private func gearBadge(_ gear: String) -> some View {
        Text(gear)
            .font(.monoChip)
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
                                .font(.titleSmall)
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

// MARK: - TransferSwimmerSheet

/// TransferSwimmerSheet — coach transfers a swimmer to another coach.
/// Lists all coaches on the platform; the current coach picks one and
/// confirms. The RPC removes the swimmer from their current squad and
/// updates coach_id. PBs follow; historical times stay with old coach.
private struct TransferSwimmerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthManager.self) private var authManager
    let swimmer: Swimmer
    let onTransferred: () -> Void

    @State private var coaches: [Coach] = []
    @State private var selectedCoach: Coach?
    @State private var isLoading = false
    @State private var isTransferring = false
    @State private var errorMessage: String?

    private var swimmerService: SwimmerService { SwimmerService() }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bgBase.ignoresSafeArea()
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Transfer \(swimmer.fullName) to a different coach. Their PBs and profile move with them. Historical times stay with you. They'll be removed from their current squad — the new coach can assign them to one of their squads.")
                                .font(.caption)
                                .foregroundColor(Color.textMuted)
                                .padding(.horizontal, 16)
                                .padding(.top, 16)

                            if isLoading {
                                ProgressView()
                                    .tint(Color.accentCyan)
                                    .padding(.top, 40)
                            } else {
                                ForEach(coaches) { coach in
                                    Button {
                                        Haptics.selection()
                                        selectedCoach = coach
                                    } label: {
                                        HStack(spacing: 12) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(coach.name ?? "Unknown coach")
                                                    .font(.body)
                                                    .foregroundColor(Color.textPrimary)
                                            }
                                            Spacer()
                                            if selectedCoach?.id == coach.id {
                                                Image(systemName: "checkmark")
                                                    .foregroundColor(Color.accentCyan)
                                            }
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 12)
                                        .background(
                                            selectedCoach?.id == coach.id
                                                ? Color.accentCyan.opacity(0.1)
                                                : Color.bgRaised
                                        )
                                        .cornerRadius(10)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(
                                                    selectedCoach?.id == coach.id ? Color.accentCyan : Color.divider,
                                                    lineWidth: 1
                                                )
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.horizontal, 16)
                                }
                            }
                        }
                    }

                    VStack(spacing: 12) {
                        if let errorMessage {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundColor(Color.statusError)
                        }
                        Button {
                            Task { await transfer() }
                        } label: {
                            Text("Transfer Swimmer")
                                .font(.body)
                                .foregroundColor(Color.textOnAccent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(selectedCoach != nil ? Color.accentCyan : Color.bgInset)
                                .cornerRadius(10)
                        }
                        .disabled(selectedCoach == nil || isTransferring)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .padding(.top, 12)
                    .background(Color.bgBase)
                }
            }
            .navigationTitle("Transfer Swimmer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(Color.accentCyan)
                }
            }
        }
        .task { await loadCoaches() }
    }

    private func loadCoaches() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await swimmerService.supabase
                .from("coaches")
                .select()
                .execute()
            coaches = try JSONDecoder().decode([Coach].self, from: response.data)
                .filter { $0.id != authManager.coachId }
        } catch {
            errorMessage = "Couldn't load coaches: \(error.localizedDescription)"
        }
    }

    private func transfer() async {
        guard let target = selectedCoach else { return }
        isTransferring = true
        errorMessage = nil
        defer { isTransferring = false }
        do {
            _ = try await swimmerService.transferSwimmer(
                swimmerId: swimmer.id,
                toCoachId: target.id
            )
            onTransferred()
            dismiss()
        } catch {
            errorMessage = "Transfer failed: \(error.localizedDescription)"
        }
    }
}
