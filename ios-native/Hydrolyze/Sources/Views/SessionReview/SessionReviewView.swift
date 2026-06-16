import SwiftUI

/// SessionReviewView — post-timing review screen.
/// Coach sees all laps with swimmer names, confidence badges, lane/wave context.
/// Tap a row → bottom sheet to reassign. "Needs Review" tab is default.
struct SessionReviewView: View {
    @StateObject private var viewModel = SessionReviewViewModel()
    let sessionId: String

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "060e18").ignoresSafeArea()

                VStack(spacing: 0) {
                    filterTabs
                    rowsList
                    confirmButton
                }
            }
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $viewModel.showReassignSheet) {
                if let row = viewModel.selectedRow {
                    ReassignSheet(
                        row: row,
                        allSwimmerNames: viewModel.rows.map { ($0.id, $0.swimmerName) },
                        onSelect: { swimmerId in
                            Task {
                                await viewModel.reassign(timeId: UUID(uuidString: row.id) ?? UUID(), toSwimmerId: swimmerId)
                            }
                        }
                    )
                }
            }
            .alert("Unconfirmed Rows", isPresented: $viewModel.showConfirmWarning) {
                Button("Cancel", role: .cancel) {}
                Button("Confirm Anyway", role: .destructive) {
                    Task { await viewModel.confirmAll(force: true) }
                }
            } message: {
                Text("\(viewModel.effectiveUnconfirmedCount) row(s) have low confidence. Confirm anyway, or tap individual rows to reassign.")
            }
        }
        .task {
            await viewModel.load(sessionId: sessionId)
        }
    }

    private var filterTabs: some View {
        HStack(spacing: 0) {
            ForEach(SessionReviewViewModel.Filter.allCases, id: \.rawValue) { f in
                Button {
                    viewModel.filter = f
                } label: {
                    Text(f.rawValue)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(viewModel.filter == f ? Color(hex: "09d4ee") : Color(hex: "4a6572"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            viewModel.filter == f ?
                            Color(hex: "0d2847") : Color.clear
                        )
                        .cornerRadius(8)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var rowsList: some View {
        ScrollView {
            if viewModel.isLoading && viewModel.rows.isEmpty {
                // Loading state — visible feedback so the user knows the
                // page is fetching, not stuck.
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(Color(hex: "09d4ee"))
                    Text("Loading review…")
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "4a6572"))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 64)
            } else if let error = viewModel.errorMessage {
                Text(error)
                    .font(.system(size: 15))
                    .foregroundColor(Color.red)
                    .padding()
            } else if viewModel.filteredRows.isEmpty {
                // Empty state — different message depending on which
                // tab the user is on. "All" empty means the session has
                // no laps (data issue). "Needs Review" empty means
                // everything is green (good — coach can confirm).
                VStack(spacing: 8) {
                    Image(systemName: viewModel.filter == .needsReview ? "checkmark.seal" : "tray")
                        .font(.system(size: 32, weight: .light))
                        .foregroundColor(Color(hex: "4a6572"))
                    Text(viewModel.filter == .needsReview ? "Nothing needs review" : "No laps recorded")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Color(hex: "4a6572"))
                    if viewModel.filter == .needsReview {
                        Text("All pairings are high confidence. Switch to All to see them.")
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "4a6572"))
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 64)
                .padding(.horizontal, 32)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.filteredRows) { row in
                        ReviewRowView(
                            row: row,
                            isAcceptedByCoach: viewModel.coachConfirmedRowIds.contains(row.id)
                        ) {
                            viewModel.selectedRow = row
                            viewModel.showReassignSheet = true
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 80)
            }
        }
    }

    private var confirmButton: some View {
        VStack(spacing: 8) {
            if viewModel.effectiveUnconfirmedCount > 0 {
                Text("\(viewModel.effectiveUnconfirmedCount) row(s) need review")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "4a6572"))
            }

            Button {
                Task { await viewModel.confirmAll() }
            } label: {
                Text(viewModel.effectiveUnconfirmedCount > 0 ? "Confirm Anyway" : "Confirm All")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    // Always enabled — the user can always proceed, the
                    // "force" path inside confirmAll() will either succeed
                    // immediately (no unconfirmed rows) or show the
                    // warning alert. Previously the button was disabled
                    // when unconfirmed > 0, which stranded the user with
                    // no way to proceed.
                    .background(Color(hex: "09d4ee"))
                    .foregroundColor(Color(hex: "060e18"))
                    .cornerRadius(12)
            }
        }
        .padding(16)
        .background(Color(hex: "0d1f33"))
    }
}

// MARK: - Review Row

struct ReviewRowView: View {
    let row: SessionReviewViewModel.ReviewRow
    var isAcceptedByCoach: Bool = false   // Phase 2.6 v1.1: coach explicitly accepted despite low confidence
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Circle()
                    .fill(row.confidenceLevel.color)
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.swimmerName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Color(hex: "e2f4fa"))

                    HStack(spacing: 8) {
                        if let lane = row.lane {
                            Text("Lane \(lane)")
                                .font(.system(size: 12))
                                .foregroundColor(Color(hex: "4a6572"))
                        }
                        if let wave = row.wave {
                            Text("Wave \(wave)")
                                .font(.system(size: 12))
                                .foregroundColor(Color(hex: "4a6572"))
                        }
                        Text("\(row.confidence)%")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(row.confidenceLevel.color)
                    }
                }

                Spacer()

                Text(TimingSession.formatMs(row.recordedTime.timeMs))
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(hex: "e2f4fa"))

                if isAcceptedByCoach {
                    // Visual confirmation that the coach has accepted
                    // this low-confidence pairing. Distinct from the
                    // auto-paired high-confidence green.
                    Image(systemName: "hand.thumbsup.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "09d4ee"))
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "4a6572"))
                }
            }
            .padding(12)
            .background(row.confidenceLevel.backgroundColor)
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
        .contextMenu {
            // Long-press to accept a low-confidence pairing without
            // opening the reassign sheet. Useful when the coach knows
            // the pairing is correct but the engine has high variance.
            if row.confidence < 50 && !isAcceptedByCoach {
                Button {
                    // The view doesn't have a direct reference to the VM;
                    // the parent owns it. We post a notification via
                    // a callback hook — but to keep this minimal v1, we
                    // rely on the existing onTap (reassign) flow. The
                    // 'Confirm Anyway' path on the bottom button is
                    // the v1 escape hatch.
                    onTap()
                } label: {
                    Label("Reassign swimmer", systemImage: "person.crop.circle.badge.exclamationmark")
                }
            }
        }
    }
}

// MARK: - Reassign Sheet

struct ReassignSheet: View {
    let row: SessionReviewViewModel.ReviewRow
    let allSwimmerNames: [(String, String)]
    let onSelect: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "060e18").ignoresSafeArea()

                List {
                    ForEach(allSwimmerNames, id: \.0) { pair in
                        let swimmerId = UUID(uuidString: pair.0) ?? UUID()
                        Button {
                            onSelect(swimmerId)
                            dismiss()
                        } label: {
                            HStack {
                                Text(pair.1)
                                    .foregroundColor(Color(hex: "e2f4fa"))
                                Spacer()
                                if pair.0 == row.id {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(Color(hex: "09d4ee"))
                                }
                            }
                        }
                        .listRowBackground(Color(hex: "0d1f33"))
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Assign Swimmer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(Color(hex: "09d4ee"))
                }
            }
        }
        .presentationDetents([.medium])
    }
}

#Preview {
    SessionReviewView(sessionId: "test")
}