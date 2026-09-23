// V0.56 S1 (2026-09-23): native-SwiftUI workout-detail chrome,
// ported from the V0.55 prototype (commit 7269e38, Variant 1
// Native List + HydrolyzeColors tokens). Renders the workout using
// .insetGrouped List + Section per phase, eyebrow headers with
// inline meter totals, mono-digit set titles, verbatim cues,
// fragment math line, and per-rep identity pills for descend sets.
//
// Source of truth for the data is the existing V0.55 S1 projection
// function (WorkoutPreviewBuilder.fromWorkoutAndSets) — the same
// call WorkoutStructureView uses, so the rendering here is fed by
// exactly the same parsed model the builder's WorkoutPreview sees.
//
// This view is a leaf. The scroll container, metadata header,
// bottom CTA, and safe-area inset all live in WorkoutDetailView
// (the host) so the host remains the single owner of the screen
// layout. Native List chrome here; chrome-around-chrome at the
// host.

import SwiftUI

/// One Phase (WARM-UP / MAIN / COOL-DOWN) flattened into a list of
/// rows the new list renders. Each row carries the parsed repGroup
/// AND the source `viewModel.sets` index so the host's
/// `launchFragmentTiming` callback can look up the parent WorkoutSet
/// without re-walking the data.
struct NativeListPhase: Identifiable {
    let id: Int                // phase index in `parsed.sections`
    let title: String?         // "WARM-UP" / "MAIN" / "COOL-DOWN"
    let totalMeters: Int
    let totalReps: Int
    let rows: [NativeListRow]
}

/// One tappable row inside a phase. A row is one repGroup inside
/// one namedSet inside one section.
struct NativeListRow: Identifiable {
    let id = UUID()
    let sourceSetIndex: Int
    let repGroup: ParsedRepGroup
}

struct WorkoutNativeListView: View {
    let phases: [NativeListPhase]
    var onFragmentTap: (Int, ParsedFragment) -> Void

    var body: some View {
        if phases.isEmpty {
            emptyState
        } else {
            setsList
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle.portrait")
                .font(.largeTitle)
                .foregroundStyle(Color.textMuted)
            Text("No sets in this workout")
                .font(.headline)
                .foregroundStyle(Color.textPrimary)
            Text("Open in the workout builder to add sets.")
                .font(.subheadline)
                .foregroundStyle(Color.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .listRowBackground(Color.bgBase)
    }

    private var setsList: some View {
        List {
            ForEach(phases) { phase in
                Section {
                    ForEach(phase.rows) { row in
                        nativeSetRow(row: row)
                    }
                } header: {
                    sectionHeader(phase: phase)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.bgBase)
    }

    @ViewBuilder
    private func sectionHeader(phase: NativeListPhase) -> some View {
        let displayTitle = (phase.title?.isEmpty == false ? phase.title! : "SETS").uppercased()
        HStack(spacing: 8) {
            Text(displayTitle)
                .font(.footnote.monospaced().weight(.semibold))
                .tracking(1.0)
                .foregroundStyle(Color.textFaint)
            Spacer(minLength: 8)
            Text("\(phase.totalMeters) M")
                .font(.footnote.monospaced().weight(.semibold))
                .foregroundStyle(Color.textFaint)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .listRowBackground(Color.bgBase)
    }

    @ViewBuilder
    private func nativeSetRow(row: NativeListRow) -> some View {
        let rg = row.repGroup
        let isActiveRow = isActiveRow(rg)
        let fragmentActiveRepIdx = activeRepIdx(in: rg)
        VStack(alignment: .leading, spacing: 6) {
            // Title row: reps × distance + stroke + send-off.
            // One multiplier per set (say-it-once). Mono digits
            // stay mono so distances/times don't shift across reps.
            HStack(spacing: 6) {
                Text("\(rg.reps ?? 1)×")
                    .font(.system(.title3, design: .default).weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.textPrimary)
                if let d = rg.distance {
                    Text("\(d) m")
                        .font(.system(.title3, design: .default).weight(.semibold).monospacedDigit())
                        .foregroundStyle(Color.textPrimary)
                }
                if let s = rg.stroke, !s.isEmpty {
                    Text(s)
                        .font(.callout)
                        .foregroundStyle(Color.textMuted)
                }
                Spacer(minLength: 8)
                if let iv = rg.interval, !iv.isEmpty {
                    Text(iv)
                        .font(.footnote.monospaced())
                        .foregroundStyle(Color.textMuted)
                }
            }
            // Fragment math + verbatim cues (composite sets only).
            // The verbatim line shows what the coach wrote
            // ("12.5 strong / 12.5 easy"); the math line confirms
            // ("12.5 + 12.5 = 25 m"). mono digits in the math line
            // so the sum reads as a measurement, not copy.
            if let frags = rg.fragments, !frags.isEmpty {
                let verbatim = verbatimFragmentLine(frags)
                Text(verbatim)
                    .font(.footnote)
                    .foregroundStyle(Color.textMuted)
                let sumLine = fragmentSumLine(frags)
                if !sumLine.isEmpty {
                    Text(sumLine)
                        .font(.footnote.monospaced().weight(.semibold))
                        .foregroundStyle(Color.textPrimary)
                }
            }
            // Note + intensity + pacing verbatim lines.
            if let note = rg.note, !note.isEmpty {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(Color.textMuted)
            }
            // Per-rep identity strip. Active sets get the coral pill
            // (accentAction) AND the bgSelected row lift so the
            // active set reads at glance without exceeding the 20%
            // coral budget — coral is reserved for the active rep
            // pill + the bottom CTA only.
            if shouldShowRepPills(rg) {
                HStack(spacing: 6) {
                    let reps = rg.reps ?? 1
                    ForEach(0..<reps, id: \.self) { i in
                        repPill(ordinal: i + 1, isActive: i == fragmentActiveRepIdx)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 6)
        .listRowBackground(isActiveRow ? Color.bgSelected : Color.clear)
    }

    @ViewBuilder
    private func repPill(ordinal: Int, isActive: Bool) -> some View {
        Text("\(ordinal)")
            .font(.system(.headline, design: .monospaced).weight(.semibold))
            .frame(width: 48, height: 36)
            .background(isActive ? Color.accentAction : Color.bgRaised)
            .foregroundStyle(isActive ? Color.textOnAccent : Color.textPrimary)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func isActiveRow(_ rg: ParsedRepGroup) -> Bool {
        if let d = rg.descend, !d.isEmpty { return true }
        if let f = rg.fragments, !f.isEmpty { return true }
        return false
    }

    /// The active rep inside a descend set is rep 2 — matches the
    /// prototype (commit 7269e38, "rep 2 of 4"). For larger
    /// ladders the prototype's rule was "floor((reps-1)/2)+1" so
    /// the active rep is the lower-middle of the ladder. For
    /// non-descend sets we don't surface a rep pill (the active
    /// rep is the rep itself).
    private func activeRepIdx(in rg: ParsedRepGroup) -> Int? {
        guard let reps = rg.reps, reps > 1 else { return nil }
        if rg.descend != nil { return (reps - 1) / 2 }  // 4 reps → 1, 6 reps → 2
        return nil
    }

    private func verbatimFragmentLine(_ fragments: [ParsedFragment]) -> String {
        fragments.map { frag -> String in
            var pieces: [String] = []
            let label = frag.distanceLabel ?? frag.distance.map { "\($0)" }
            if let l = label { pieces.append("\(l)m") }
            if let d = frag.descriptor, !d.isEmpty { pieces.append(d) }
            else if let lbl = frag.intensity?.label, !lbl.isEmpty { pieces.append(lbl) }
            return pieces.joined(separator: " ")
        }
        .joined(separator: " / ")
    }

    private func fragmentSumLine(_ fragments: [ParsedFragment]) -> String {
        let values: [Double] = fragments.compactMap { f in
            if let s = f.distanceLabel, let v = Double(s) { return v }
            if let i = f.distance { return Double(i) }
            return nil
        }
        guard !values.isEmpty else { return "" }
        let sum = values.reduce(0, +)
        let parts = values.map { formatNumber($0) }
        let totalText = formatNumber(sum)
        return parts.joined(separator: " + ") + " = \(totalText) m"
    }

    private func formatNumber(_ d: Double) -> String {
        if d.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(d))
        }
        return String(d)
    }

    private func shouldShowRepPills(_ rg: ParsedRepGroup) -> Bool {
        let reps = rg.reps ?? 1
        guard reps > 1 else { return false }
        if let d = rg.descend, !d.isEmpty { return true }
        if let f = rg.fragments, !f.isEmpty { return true }
        return false
    }
}

/// Host-side helper. Walks viewModel.sets + the parsed projection
/// once, recording each repGroup's source-array index so the new
/// chrome's tap callback can resolve the parent WorkoutSet. Pure
/// function — no view-model state. The host calls it during
/// `body` evaluation.
///
/// Mapping policy: parsed.sections preserves the order of the
/// source `viewModel.sets` (verified V0.55 S1 behaviour). For
/// composite sets where multiple parsed repGroups share a single
/// source WorkoutSet, each row points at the same source index —
/// the callback's parentSet lookup still resolves to the same
/// parent via that index.
func nativeListPhases(
    parsed: ParsedWorkout,
    sets: [WorkoutSet]
) -> [NativeListPhase] {
    var phases: [NativeListPhase] = []
    var setIndex = 0
    for (sectionIdx, section) in parsed.sections.enumerated() {
        var rows: [NativeListRow] = []
        var totalMeters = 0
        var totalReps = 0
        for namedSet in section.namedSets {
            for rg in namedSet.repGroups {
                rows.append(NativeListRow(sourceSetIndex: setIndex, repGroup: rg))
                totalMeters += (rg.distance ?? 0) * (rg.reps ?? 1)
                totalReps += (rg.reps ?? 1)
                setIndex += 1
            }
        }
        phases.append(NativeListPhase(
            id: sectionIdx,
            title: section.title,
            totalMeters: totalMeters,
            totalReps: totalReps,
            rows: rows
        ))
    }
    return phases
}
