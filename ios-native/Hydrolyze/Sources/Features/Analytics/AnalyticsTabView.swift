import SwiftUI

/// AnalyticsTabView — Phase 4 squad-level coaching brain.
///
/// Replaces the v1 placeholder. Surfaces three signals from the metadata flywheel:
///   1. Training band distribution — is the squad doing enough quality work?
///   2. Gear/suit/dive breakdown — are we training race conditions?
///   3. Top gear usage — what equipment is the squad training in?
///
/// The data comes from AnalyticsService which joins recorded_times → workout_sets.
/// The gear/suit/dive columns on workout_sets (Phase 1 metadata wiring) make
/// these queries possible.
struct AnalyticsTabView: View {
    @Environment(AuthManager.self) private var authManager
    @State private var timeWindow: TimeWindow = .week
    @State private var bands: [AnalyticsService.TrainingBandStats] = []
    @State private var gearBreakdown: AnalyticsService.GearBreakdown?
    @State private var isLoading = false
    @State private var loadError: String?

    private let service = AnalyticsService()

    enum TimeWindow: String, CaseIterable, Identifiable {
        case week = "7D"
        case month = "30D"
        case quarter = "90D"
        var id: String { rawValue }

        var dateOffset: Date {
            switch self {
            case .week: return Calendar.current.date(byAdding: .day, value: -7, to: Date())!
            case .month: return Calendar.current.date(byAdding: .day, value: -30, to: Date())!
            case .quarter: return Calendar.current.date(byAdding: .day, value: -90, to: Date())!
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bgBase.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        timeWindowPicker

                        if isLoading {
                            HStack {
                                Spacer()
                                ProgressView().tint(Color.accentAction)
                                Spacer()
                            }
                            .padding(.vertical, 40)
                        } else if let error = loadError {
                            errorView(error)
                        } else {
                            trainingBandCard
                            gearBreakdownCard
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Analytics")
            .navigationBarTitleDisplayMode(.large)
        }
        .task { await loadData() }
        .onChange(of: timeWindow) { _, _ in
            Task { await loadData() }
        }
    }

    // MARK: - Time Window Picker

    private var timeWindowPicker: some View {
        Picker("Time Window", selection: $timeWindow) {
            ForEach(TimeWindow.allCases) { window in
                Text(window.rawValue).tag(window)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Training Band Distribution

    private var trainingBandCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TRAINING BAND DISTRIBUTION")
                .font(.eyebrow)
                .foregroundColor(Color.textFaint)
                .tracking(1.2)

            if bands.isEmpty {
                Text("No recorded times in this window.")
                    .font(.caption)
                    .foregroundColor(Color.textMuted)
                    .padding(.vertical, 20)
            } else {
                let totalReps = bands.reduce(0) { $0 + $1.repCount }

                VStack(spacing: 10) {
                    ForEach(bands) { band in
                        bandBar(band, totalReps: totalReps)
                    }
                }

                Divider().padding(.vertical, 4)

                HStack(spacing: 16) {
                    statLabel("Total Reps", value: "\(totalReps)")
                    statLabel("Total Distance", value: "\(bands.reduce(0) { $0 + $1.distanceMeters })m")
                }
            }
        }
        .padding(16)
        .background(Color.bgSunken)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.divider, lineWidth: 1)
        )
    }

    private func bandBar(_ band: AnalyticsService.TrainingBandStats, totalReps: Int) -> some View {
        let fraction = totalReps > 0 ? Double(band.repCount) / Double(totalReps) : 0
        let bandColor = Color(uiColor: UIColor(hex: band.color) ?? UIColor(Color.textFaint))

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(band.band)
                    .font(.captionStrong)
                    .foregroundColor(Color.textPrimary)
                Spacer()
                Text("\(band.repCount) reps · \(Int(fraction * 100))%")
                    .font(.numericSmall)
                    .foregroundColor(Color.textMuted)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.divider.opacity(0.3))
                        .frame(height: 8)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(bandColor)
                        .frame(width: geo.size.width * fraction, height: 8)
                }
            }
            .frame(height: 8)
        }
    }

    // MARK: - Gear/Suit/Dive Breakdown

    private var gearBreakdownCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GEAR · SUIT · DIVE")
                .font(.eyebrow)
                .foregroundColor(Color.textFaint)
                .tracking(1.2)

            if let gb = gearBreakdown, gb.totalReps > 0 {
                HStack(spacing: 12) {
                    breakdownTile(
                        label: "Gear",
                        count: gb.repsWithGear,
                        total: gb.totalReps,
                        color: Color.accentAction
                    )
                    breakdownTile(
                        label: "Suit",
                        count: gb.repsWithSuit,
                        total: gb.totalReps,
                        color: Color.accentAmber
                    )
                    breakdownTile(
                        label: "Dive",
                        count: gb.repsWithDive,
                        total: gb.totalReps,
                        color: Color.statusError
                    )
                }

                if !gb.topGear.isEmpty {
                    Divider().padding(.vertical, 2)

                    Text("TOP GEAR")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color.textFaint)
                        .tracking(1)

                    VStack(spacing: 6) {
                        ForEach(gb.topGear, id: \.gear) { item in
                            HStack {
                                Text(formatGearName(item.gear))
                                    .font(.caption)
                                    .foregroundColor(Color.textPrimary)
                                Spacer()
                                Text("\(item.count)")
                                    .font(.numericSmall)
                                    .foregroundColor(Color.textMuted)
                            }
                        }
                    }
                }
            } else {
                Text("No gear/suit/dive data in this window.")
                    .font(.caption)
                    .foregroundColor(Color.textMuted)
                    .padding(.vertical, 20)
            }
        }
        .padding(16)
        .background(Color.bgSunken)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.divider, lineWidth: 1)
        )
    }

    private func breakdownTile(label: String, count: Int, total: Int, color: Color) -> some View {
        let pct = total > 0 ? Int(Double(count) / Double(total) * 100) : 0
        return VStack(spacing: 6) {
            Text("\(pct)%")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color.textFaint)
                .tracking(0.5)
            Text("\(count)/\(total)")
                .font(.system(size: 9))
                .foregroundColor(Color.textFaint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(color.opacity(0.08))
        .cornerRadius(8)
    }

    // MARK: - Helpers

    private func statLabel(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color.textFaint)
            Text(value)
                .font(.numeric)
                .foregroundColor(Color.textPrimary)
        }
    }

    private func formatGearName(_ gear: String) -> String {
        gear.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundColor(Color.accentAmber)
            Text(message)
                .font(.caption)
                .foregroundColor(Color.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Data Loading

    private func loadData() async {
        isLoading = true
        loadError = nil
        do {
            let coachId = authManager.coachId ?? ""
            async let bands = try service.fetchTrainingBands(
                coachId: coachId,
                since: timeWindow.dateOffset
            )
            async let gear = try service.fetchGearBreakdown(
                coachId: coachId,
                since: timeWindow.dateOffset
            )
            self.bands = try await bands
            self.gearBreakdown = try await gear
        } catch {
            loadError = "Failed to load analytics: \(error.localizedDescription)"
        }
        isLoading = false
    }
}

// MARK: - UIColor Hex Extension

extension UIColor {
    convenience init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard hex.count == 6 else { return nil }
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        self.init(
            red: CGFloat((int >> 16) & 0xFF) / 255,
            green: CGFloat((int >> 8) & 0xFF) / 255,
            blue: CGFloat(int & 0xFF) / 255,
            alpha: 1
        )
    }
}

#Preview {
    AnalyticsTabView()
        .environment(AuthManager())
}
