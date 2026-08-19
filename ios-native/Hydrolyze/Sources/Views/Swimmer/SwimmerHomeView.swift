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
            Color.bgBase.ignoresSafeArea()

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

                    SwimmerUpcomingView()
                        .tabItem {
                            Label("Upcoming", systemImage: "calendar")
                        }

                    ProfileTab()
                        .tabItem {
                            Label("Profile", systemImage: "gearshape.fill")
                        }
                }
                .tint(Color.textMuted)
            } else {
                ProgressView()
                    .tint(Color.textMuted)
            }
        }
        .task {
            #if DEBUG
            // V0.46 Slice 5: screenshot harness — the swimmer surface
            // gates on authManager.currentSwimmer; seed it plus the
            // VM's sessions + PBs. No network.
            if ProcessInfo.processInfo.arguments.contains("-v46-demo-swimmer") {
                viewModel.seedV46DemoSwimmerData()
                return
            }
            #endif
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
                    if viewModel.isLoading && viewModel.recentSessions.isEmpty {
                        ProgressView()
                            .tint(Color.textMuted)
                            .padding(.top, 40)
                    } else if viewModel.recentSessions.isEmpty {
                        emptyState
                    } else {
                        ForEach(viewModel.recentSessions) { session in
                            sessionSection(session)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle("My Swims")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(Color.bgBase, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    private func sessionSection(_ session: SwimmerHomeViewModel.SessionEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(sessionHeaderTitle(for: session))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color.textPrimary)
                Spacer()
                Text(sessionHeaderDate(for: session))
                    .font(.system(size: 11))
                    .foregroundColor(Color.textMuted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.bgDeep)
            .cornerRadius(8)

            ForEach(session.times) { entry in
                SwimTimeRow(entry: entry)
            }
        }
    }

    private func sessionHeaderTitle(for session: SwimmerHomeViewModel.SessionEntry) -> String {
        if let title = session.title, !title.isEmpty {
            return title
        }
        return "Practice"
    }

    private func sessionHeaderDate(for session: SwimmerHomeViewModel.SessionEntry) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let base = formatter.string(from: session.date)
        // When every time inside the session is the same calendar day, just show the date.
        // If the session spans midnight somehow, append the relative day from the newest time.
        let calendar = Calendar.current
        let newest = session.times.map(\.createdAt).max() ?? session.date
        let oldest = session.times.map(\.createdAt).min() ?? session.date
        if calendar.isDate(newest, inSameDayAs: oldest) {
            return base
        }
        return "\(base) · \(session.times.first?.relativeDate ?? "")"
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "stopwatch")
                .font(.system(size: 32))
                .foregroundColor(Color.textFaint)
            Text("No swims recorded yet")
                .font(.headline)
                .foregroundColor(Color.textMuted)
            Text("Once your coach records your times at practice, they'll show up here.")
                .font(.caption)
                .foregroundColor(Color.textFaint)
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
                .font(.numeric)
                .foregroundColor(Color.textPrimary)
                .frame(width: 80, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(entry.distance)m \(entry.stroke)")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color.textPrimary)
                Text(entry.relativeDate)
                    .font(.system(size: 11))
                    .foregroundColor(Color.textMuted)
            }

            Spacer()
        }
        .padding(12)
        .background(Color.bgDeep)
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
                            .tint(Color.textMuted)
                            .padding(.top, 40)
                    } else if viewModel.pbs.isEmpty {
                        Text("No personal bests yet")
                            .font(.headline)
                            .foregroundColor(Color.textMuted)
                            .padding(.top, 40)
                    } else {
                        ForEach(groupedPBs, id: \.0) { stroke, pbs in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(stroke)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(Color.textMuted)
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
            .toolbarBackground(Color.bgBase, for: .navigationBar)
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
                .font(.numeric)
                .foregroundColor(Color.textPrimary)
                .frame(width: 50, alignment: .leading)

            Text(formatMs(pb.timeMs))
                .font(.numeric)
                .foregroundColor(isPersonalBest ? Color.statusSuccess : Color.textPrimary)

            Spacer()

            if isPersonalBest {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 14))
                    .foregroundColor(Color.statusSuccess)
            }
        }
        .padding(12)
        .background(Color.bgDeep)
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
            .toolbarBackground(Color.bgBase, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    private var coachCard: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(Color.bgInset)
                .frame(width: 56, height: 56)
                .overlay(
                    Text(initials)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(Color.textMuted)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text("Your coach")
                    .font(.system(size: 11))
                    .tracking(0.8)
                    .foregroundColor(Color.textMuted)
                Text("Coach Nathan")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Color.textPrimary)
            }

            Spacer()
        }
        .padding(14)
        .background(Color.bgDeep)
        .cornerRadius(10)
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color.textPrimary)

            Text("Your coach has invited you to Hydrolyze so you can see your times and personal bests. They'll record your swims at practice.")
                .font(.caption)
                .foregroundColor(Color.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.bgDeep)
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
            .toolbarBackground(Color.bgBase, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Account")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color.textPrimary)

            if let swimmer = authManager.currentSwimmer {
                profileRow(label: "Name", value: swimmer.fullName)
                // Email is on authManager.currentUser?.email (the auth.users row),
                // not on the swimmers table. The swimmers row has no email column
                // until Phase 2.8 — invite-code onboarding writes it there
                // post-redeem, but the canonical source for the swimmer-side
                // sign-in surface is the Supabase auth user.
                if let email = authManager.currentUser?.email,
                   !email.isEmpty {
                    profileRow(label: "Email", value: email)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.bgDeep)
        .cornerRadius(10)
    }

    private func profileRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(Color.textMuted)
            Spacer()
            Text(value)
                .font(.captionStrong)
                .foregroundColor(Color.textPrimary)
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
                .font(.bodyEmphasis)
                .foregroundColor(Color.statusError)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.bgDeep)
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}