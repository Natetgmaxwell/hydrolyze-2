import SwiftUI

/// SwimmerDetailViewModel — view model for swimmer profile screen.
/// Loads swimmer data, groups, PBs, and progression; drives archive/delete/
/// form-stroke-picker/group-toggle actions.
@MainActor
final class SwimmerDetailViewModel: ObservableObject {
    @Published var swimmer: Swimmer?
    @Published var allGroups: [CoachGroup] = []
    @Published var swimmerGroupIds: Set<String> = []
    @Published var personalBests: [SwimmerPB] = []
    @Published var progressionTimes: [RecordedTime] = []
    /// V0.42 Slice 2 (2026-08-18): per-swimmer recovery signature
    /// (median first-strike rep + rates + averages). Nil when the
    /// swimmer has no strike rows in the 8-week window — the view
    /// hides the recovery section entirely when nil (data-absent =
    /// hidden; no "no data yet" chrome).
    @Published var recoverySignature: RecoverySignature?
    /// V0.42 Slice 2 (2026-08-18): per-week strike counts +
    /// strikes-per-100-reps for the sparkline. Empty when no data;
    /// the sparkline hides unless `weeklyStrain.count >= 8` (see
    /// `hasEightWeeksOfData`).
    @Published var weeklyStrain: [WeeklyStrainPoint] = []
    /// V0.42 Slice 3 (2026-08-18): inline coach-facing flag when
    /// the coach reverts > 30% of this swimmer's extensions. Nil
    /// when below threshold or when the signature is empty. Engine
    /// never auto-adjusts standards — the flag is advisory only.
    @Published var revertFlag: String?
    @Published var isLoading: Bool = true
    @Published var errorMessage: String?

    var swimmerId: String

    private let swimmerService = SwimmerService()
    private let chartDataService = ChartDataService()
    /// V0.42 Slice 2 (2026-08-18): Supabase fetch layer for
    /// `set_rest_events`. Reads only — never writes (V0.39 owns
    /// the writes via `TimingService.saveRestEvents(...)`).
    private let recoveryService = RecoveryService()
    /// V0.42 spec §Decisions row 2 (2026-08-18): 8-week window.
    /// Matches the analytics brainstorm default.
    private let recoveryWindowWeeks: Int = 8

    init(swimmerId: String) {
        self.swimmerId = swimmerId
    }

    var initials: String {
        guard let swimmer = swimmer else { return "??" }
        let first = swimmer.firstName.prefix(1)
        let last = (swimmer.lastName ?? "").prefix(1)
        if last.isEmpty { return String(swimmer.firstName.prefix(2)).uppercased() }
        return "\(first)\(last)".uppercased()
    }

    var ageText: String? {
        guard let swimmer = swimmer, let bd = swimmer.birthdate else { return nil }
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: bd + "T00:00:00") else { return nil }
        let ageComponents = Calendar.current.dateComponents([.year], from: date, to: Date())
        guard let years = ageComponents.year, years > 0 else { return nil }
        let dobStr = DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)
        return "DOB: \(dobStr)  ·  \(years) years"
    }

    /// Best (lowest) timeMs in the current progression window, for the rule mark.
    var bestProgressionTimeMs: Int? {
        progressionTimes.map { $0.timeMs }.min()
    }

    func load(coachId: String?) async {
        guard let coachId = coachId else { return }
        isLoading = true
        do {
            let swimmer = try await swimmerService.fetchSwimmer(swimmerId: swimmerId)
            self.swimmer = swimmer
            let groupIds = try await swimmerService.fetchSwimmerGroupIds(swimmerId: swimmerId)
            swimmerGroupIds = Set(groupIds)
            allGroups = try await swimmerService.fetchGroups(coachId: coachId)
            personalBests = try await swimmerService.fetchPersonalBests(swimmerId: swimmerId)
            await loadProgression()
            await loadRecovery()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// V0.42 Slice 2 + 3 (2026-08-18): fetch the recovery
    /// signature + weekly trend for the last `recoveryWindowWeeks`
    /// (8) weeks. Wrapped in its own do/catch so a fetch failure
    /// here does NOT fail the whole `load(...)` — data absent =
    /// hidden is the contract; the section simply doesn't render
    /// when these come back empty.
    ///
    /// `revertFlag` is derived from `recoverySignature.revertRate`
    /// once the signature is in. The `> 0.30` threshold is hard-
    /// coded inside `RecoveryAggregator.coachRevertFlag(...)` (a
    /// LOCKED decision per V0.42 §Decisions row 3).
    private func loadRecovery() async {
        let since = Calendar.current.date(
            byAdding: .weekOfYear, value: -recoveryWindowWeeks, to: Date()
        ) ?? Date()
        do {
            async let sigTask = recoveryService.fetchSignature(swimmerId: swimmerId, since: since)
            async let trendTask = recoveryService.fetchWeeklyTrend(
                swimmerId: swimmerId, since: since, weeks: recoveryWindowWeeks
            )
            let (sig, trend) = try await (sigTask, trendTask)
            self.recoverySignature = sig
            self.weeklyStrain = trend
            // V0.42 Slice 3 (2026-08-18): derive the inline coach
            // flag from the just-fetched revert rate. Uses the
            // swimmer's firstName — already loaded by the parent
            // `load(...)` (we have `self.swimmer`).
            self.revertFlag = RecoveryAggregator.coachRevertFlag(
                sig.revertRate,
                firstName: self.swimmer?.firstName ?? ""
            )
        } catch {
            // V0.42 Slice 2 (2026-08-18): data-absent = hidden. A
            // fetch failure leaves nil/empty — the view's
            // `recoverySection` short-circuits on the nil line.
            self.recoverySignature = nil
            self.weeklyStrain = []
            self.revertFlag = nil
        }
    }

    /// V0.42 Slice 2 (2026-08-18): coach-facing one-line summary
    /// of the signature (e.g. `"Drops on rep 3 of hard sets."`).
    /// Nil when the signature has no median — the view hides the
    /// section entirely in that case (NEVER shows empty chrome).
    var recoverySignatureLine: String? {
        guard let sig = recoverySignature else { return nil }
        return RecoveryAggregator.coachSignatureLine(sig)
    }

    /// V0.42 Slice 2 (2026-08-18): true iff the swimmer has at
    /// least 8 distinct weeks of strike data — the sparkline only
    /// renders when a full 8 weeks exist (per V0.42 spec §Slice 2:
    /// "A small trend sparkline if 8 weeks of data exist; hidden
    /// otherwise (never greyed-out empty)"). The VM is the gate so
    /// the view never has to reason about the threshold itself.
    var hasEightWeeksOfData: Bool {
        weeklyStrain.count >= 8
    }

    /// Fetch the swimmer's recorded times for the last 30 days.
    /// Used by the ProgressionChart in the swimmer detail view.
    func loadProgression() async {
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        do {
            // If the swimmer has a PB, use that distance. Otherwise show all.
            let distance = personalBests.first?.distance
            let allTimes = try await chartDataService.fetchSpeedCurveData(
                swimmerId: swimmerId, since: thirtyDaysAgo
            )
            if let distance = distance {
                progressionTimes = allTimes.filter { $0.paceDistance == distance || $0.paceDistance == nil }
            } else {
                progressionTimes = allTimes
            }
        } catch {
            progressionTimes = []
        }
    }

    func updateFormStroke(_ stroke: String) async {
        guard let swimmer = swimmer else { return }
        do {
            _ = try await swimmerService.updateSwimmer(swimmerId: swimmer.id, updates: ["form_stroke": stroke])
            self.swimmer?.formStroke = stroke
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateMainStroke(_ stroke: String) async {
        guard let swimmer = swimmer else { return }
        do {
            _ = try await swimmerService.updateSwimmer(swimmerId: swimmer.id, updates: ["main_stroke": stroke])
            self.swimmer?.mainStroke = stroke
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleGroup(_ groupId: String) async {
        if swimmerGroupIds.contains(groupId) {
            do {
                try await swimmerService.removeSwimmerFromGroup(swimmerId: swimmerId, groupId: groupId)
                swimmerGroupIds.remove(groupId)
            } catch {
                errorMessage = error.localizedDescription
            }
        } else {
            do {
                try await swimmerService.assignSwimmerToGroup(swimmerId: swimmerId, groupId: groupId)
                swimmerGroupIds.insert(groupId)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func archiveSwimmer() async {
        do {
            _ = try await swimmerService.archiveSwimmer(swimmerId: swimmerId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSwimmer() async {
        do {
            try await swimmerService.deleteSwimmer(swimmerId: swimmerId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deletePB(_ pb: SwimmerPB) async {
        do {
            try await swimmerService.deletePersonalBest(pbId: pb.id)
            personalBests.removeAll { $0.id == pb.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addPB(distance: Int, stroke: String, timeMs: Int) async {
        do {
            let newPB = try await swimmerService.upsertPersonalBest(swimmerId: swimmerId, distance: distance, stroke: stroke, timeMs: timeMs, gear: nil)
            if let idx = personalBests.firstIndex(where: { $0.distance == distance && $0.stroke == stroke }) {
                personalBests[idx] = newPB
            } else {
                personalBests.append(newPB)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
