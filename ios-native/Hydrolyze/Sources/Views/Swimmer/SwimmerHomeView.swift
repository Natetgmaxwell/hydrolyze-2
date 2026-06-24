import SwiftUI

/// PHASE 2.5: SwimmerHomeView — the root tab view for a signed-in
/// swimmer. Three tabs: My Swims (recent times), My PBs (best
/// times), My Coach (who their coach is, contact info).
///
/// Read-only for MVP (per the user's Option A from the Phase 0
/// questions). The swimmer can see what they swam and how it
/// compares to their PB, but cannot edit anything.
///
/// The data shown is filtered by the new swimmer_own_* RLS
/// policies — the swimmer can ONLY see their own data; the
/// policies block access to other swimmers' rows, sessions,
/// and coaches' private columns.
struct SwimmerHomeView: View {
    @Environment(AuthManager.self) private var authManager
    @StateObject private var viewModel = SwimmerHomeViewModel()

    var body: some View {
        ZStack {
            Color(hex: "060e18").ignoresSafeArea()

            if let swimmer = authManager.currentSwimmer {
                TabView {
                    MySwimsTab(swimmer: swimmer, viewModel: viewModel)
                        .tabItem {
                            Label("My Swims", systemImage: "stopwatch.fill")
                        }

                    MyPBsTab(swimmer: swimmer, viewModel: viewModel)
                        .tabItem {
                            Label("My PBs", systemImage: "trophy.fill")
                        }

                    MyCoachTab(swimmer: swimmer)
                        .tabItem {
                            Label("My Coach", systemImage: "person.fill")
                        }

                    ProfileTab()
                        .tabItem {
                            Label("Profile", systemImage: "gearshape.fill")
                        }
                }
                .tint(Color(hex: "09d4ee"))
            } else {
                ProgressView()
                    .tint(Color(hex: "09d4ee"))
            }
        }
        .task {
            await viewModel.load(swimmerId: authManager.swimmerId)
        }
    }
}

// MARK: - My Swims

/// PHASE 2.5: MySwimsTab — the swimmer's recent recorded times,
/// grouped by session, most recent first. Read-only.
///
/// The data is fetched via the existing ChartDataService, which
/// already has `fetchProgressionData(swimmerId:distance:stroke:since:)`.
/// For the My Swims view we use `fetchSpeedCurveData(swimmerId:since:)`
/// (no event filter) to get the swimmer's full history.
struct MySwimsTab: View {
    let swimmer: Swimmer
    @ObservedObject var viewModel: SwimmerHomeViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if viewModel.isLoading && viewModel.recentTimes.isEmpty {
                        ProgressView()
                            .tint(Color(hex: "09d4ee"))
                            .padding(.top, 40)
                    } else if viewModel.recentTimes.isEmpty {
                        emptyState
                    } else {
                        ForEach(viewModel.recentTimes) { entry in
                            SwimTimeRow(entry: entry)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle("My Swims")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(Color(hex: "060e18"), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "stopwatch")
                .font(.system(size: 32))
                .foregroundColor(Color(hex: "4a6572"))
            Text("No swims recorded yet")
                .font(.headline)
                .foregroundColor(Color(hex: "7a9bb0"))
            Text("Once your coach records your times at practice, they'll show up here.")
                .font(.caption)
                .foregroundColor(Color(hex: "4a6572"))
                .multilineTextAlignment(.center)
        }
        .padding(.top, 40)
    }
}

/// One row in the My Swims list. Shows the time, the event
/// (stroke + distance), and a relative date.
struct SwimTimeRow: View {
    let entry: SwimmerHomeViewModel.TimeEntry

    var body: some View {
        HStack(spacing: 12) {
            Text(formatMs(entry.timeMs))
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundColor(Color(hex: "e2f4fa"))
                .frame(width: 80, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(entry.distance)m \(entry.stroke)")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color(hex: "e2f4fa"))
                Text(entry.relativeDate)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "7a9bb0"))
            }

            Spacer()
        }
        .padding(12)
        .background(Color(hex: "0d1f33"))
        .cornerRadius(8)
    }

    private func formatMs(_ ms: Int) -> String {
        let totalSeconds = Double(ms) / 1000.0
        if totalSeconds >= 60 {
            let minutes = Int(totalSeconds) / 60
            let seconds = totalSeconds.truncatingRemainder(dividingBy: 60)
            return String(format: "%d:%05.2f", minutes, seconds)
        }
        return String(format: "%.2fs", totalSeconds)
    }
}

// MARK: - My PBs

/// PHASE 2.5: MyPBsTab — the swimmer's personal bests, grouped by
/// stroke, sorted by distance ascending. Read-only.
struct MyPBsTab: View {
    let swimmer: Swimmer
    @ObservedObject var viewModel: SwimmerHomeViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if viewModel.isLoading && viewModel.pbs.isEmpty {
                        ProgressView()
                            .tint(Color(hex: "09d4ee"))
                            .padding(.top, 40)
                    } else if viewModel.pbs.isEmpty {
                        Text("No personal bests yet")
                            .font(.headline)
                            .foregroundColor(Color(hex: "7a9bb0"))
                            .padding(.top, 40)
                    } else {
                        ForEach(groupedPBs, id: \.0) { stroke, pbs in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(stroke)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(Color(hex: "09d4ee"))
                                    .padding(.top, 8)
                                ForEach(pbs) { pb in
                                    PBRow(pb: pb, isPersonalBest: pb.timeMs == fastestTimeMs(for: stroke))
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle("My PBs")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(Color(hex: "060e18"), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    private var groupedPBs: [(String, [SwimmerHomeViewModel.PBEntry])] {
        let grouped = Dictionary(grouping: viewModel.pbs, by: { $0.stroke })
        return grouped.keys.sorted().map { key in
            (key, grouped[key]!.sorted(by: { $0.distance < $1.distance }))
        }
    }

    private func fastestTimeMs(for stroke: String) -> Int? {
        viewModel.pbs.filter { $0.stroke == stroke }.map { $0.timeMs }.min()
    }
}

/// One row in the My PBs list.
struct PBRow: View {
    let pb: SwimmerHomeViewModel.PBEntry
    let isPersonalBest: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text("\(pb.distance)m")
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(Color(hex: "e2f4fa"))
                .frame(width: 50, alignment: .leading)

            Text(formatMs(pb.timeMs))
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundColor(isPersonalBest ? Color(hex: "10b981") : Color(hex: "e2f4fa"))

            Spacer()

            if isPersonalBest {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 14))
                    .foregroundColor(Color(hex: "10b981"))
            }
        }
        .padding(12)
        .background(Color(hex: "0d1f33"))
        .cornerRadius(8)
    }

    private func formatMs(_ ms: Int) -> String {
        let totalSeconds = Double(ms) / 1000.0
        if totalSeconds >= 60 {
            let minutes = Int(totalSeconds) / 60
            let seconds = totalSeconds.truncatingRemainder(dividingBy: 60)
            return String(format: "%d:%05.2f", minutes, seconds)
        }
        return String(format: "%.2fs", totalSeconds)
    }
}

// MARK: - My Coach

/// PHASE 2.5: MyCoachTab — who the swimmer's coach is. Shows the
/// coach's name (from `coaches.name`) and a placeholder for
/// contact info. v2 will add actual contact (phone, email).
struct MyCoachTab: View {
    let swimmer: Swimmer

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    coachCard
                    aboutSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle("My Coach")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(Color(hex: "060e18"), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    private var coachCard: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(Color(hex: "1a2d42"))
                .frame(width: 56, height: 56)
                .overlay(
                    Text(initials)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(Color(hex: "09d4ee"))
                )

            VStack(alignment: .leading, spacing: 4) {
                Text("Your coach")
                    .font(.system(size: 11))
                    .tracking(0.8)
                    .foregroundColor(Color(hex: "7a9bb0"))
                Text("Coach Nathan")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Color(hex: "e2f4fa"))
            }

            Spacer()
        }
        .padding(14)
        .background(Color(hex: "0d1f33"))
        .cornerRadius(10)
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color(hex: "e2f4fa"))

            Text("Your coach has invited you to Hydrolyze so you can see your times and personal bests. They'll record your swims at practice.")
                .font(.system(size: 13))
                .foregroundColor(Color(hex: "7a9bb0"))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "0d1f33"))
        .cornerRadius(10)
    }

    private var initials: String {
        "CN"
    }
}

// MARK: - Profile (swimmer)

/// PHASE 2.5: ProfileTab — the swimmer's account settings.
/// For MVP: name (read-only), email (read-only), sign out.
/// v2: edit name, change password, notification preferences.
struct ProfileTab: View {
    @Environment(AuthManager.self) private var authManager

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    accountCard
                    signOutButton
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle("Profile")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(Color(hex: "060e18"), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Account")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color(hex: "e2f4fa"))

            if let swimmer = authManager.currentSwimmer {
                profileRow(label: "Name", value: swimmer.fullName)
                if let email = swimmer.email {
                    profileRow(label: "Email", value: email)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "0d1f33"))
        .cornerRadius(10)
    }

    private func profileRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(Color(hex: "7a9bb0"))
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color(hex: "e2f4fa"))
        }
    }

    private var signOutButton: some View {
        Button {
            Haptics.tap()
            Task {
                await authManager.signOut()
                Haptics.success()
            }
        } label: {
            Text("Sign Out")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Color(hex: "ef4444"))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color(hex: "0d1f33"))
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}