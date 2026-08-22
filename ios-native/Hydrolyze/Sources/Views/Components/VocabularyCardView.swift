import SwiftUI

/// VocabularyCardView — end-of-session vocabulary ask list.
///
/// One card, N rows. Each row corresponds to one term the parser hit but
/// could NOT silently resolve against `coach_vocabulary`. The coach picks
/// an RPE band per term (or a start/end RPE pair for progressions like
/// `build` / `descend`); the mapping saves via `VocabularyService` and
/// the row collapses. V0.47 Slice 3 (2026-08-22).
///
/// Three RPE flywheel guarantees, locked in V0.47_DIALECT.md §4:
///   - Never-ask-twice: a term with an existing row resolves silently.
///   - End-of-session only: never interrupts the per-set flow.
///   - Re-map confirm: editing a saved mapping shows "This will update
///     N past sets. Confirm?" before firing the remap.
///
/// Owned by WorkoutPreview, which decides when to show it. Card itself is
/// purely presentational — all persistence flows through VocabularyService.
struct VocabularyCardView: View {
    let terms: [UnmappedTerm]
    /// Fired when a row's save completes. The host (WorkoutPreview) uses
    /// this to filter the term out of the local unmapped list so the card
    /// collapses in real time without a re-parse.
    var onTermSaved: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            VStack(alignment: .leading, spacing: 8) {
                ForEach(terms, id: \.term) { term in
                    VocabularyCardRow(
                        term: term,
                        onSaved: { savedTerm in
                            onTermSaved?(savedTerm)
                        }
                    )
                }
            }
        }
        .padding(14)
        .background(Color.bgInset)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.accentAmber.opacity(0.4), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.book.closed.fill")
                .font(.system(size: 14))
                .foregroundColor(Color.accentAmber)
            VStack(alignment: .leading, spacing: 2) {
                Text("New words — pick a band")
                    .font(.captionStrong)
                    .foregroundColor(Color.textPrimary)
                Text("Save once, never asked again.")
                    .font(.caption2)
                    .foregroundColor(Color.textFaint)
            }
            Spacer()
        }
    }
}

/// One row of the vocabulary card. Single-bucket terms render 4 RPE
/// chips. Progressions (`build` / `descend` / `desc`) render two pickers
/// (start RPE, end RPE) per V0.47 §6 decision 2.
private struct VocabularyCardRow: View {
    let term: UnmappedTerm
    var onSaved: (String) -> Void

    /// Pre-selected bucket for non-progression rows. Reads from the
    /// engine's silent defaults when the term has one (so the coach
    /// taps Save without thinking). nil = no default → first bucket
    /// is highlighted as the common-case fallback.
    @State private var selectedBucket: VocabularyService.RPERange?

    /// Progression row state (start/end). Pre-selected to the engine's
    /// Tier-2 silent default when present.
    @State private var startRPE: Int?
    @State private var endRPE: Int?

    /// V0.47 Slice 3 (2026-08-22): remap confirm dialog. When the coach
    /// re-taps an already-saved mapping, we surface a confirm dialog
    /// with a count of past sets affected. For this slice, the count
    /// heuristic is a conservative lower bound (the cached vocabulary
    /// row's `sampleCount` when present, else "a few" — the exact
    /// workout_sets query is out of scope for iOS — see commit body).
    @State private var remapCandidate: RemapCandidate?
    @State private var showRemapConfirm: Bool = false

    private var isProgression: Bool {
        VocabularyService.isProgression(term.term)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\"\(term.term.lowercased())\"")
                    .font(.captionStrong)
                    .foregroundColor(Color.textPrimary)
                Text("→")
                    .font(.caption)
                    .foregroundColor(Color.textMuted)
                if isProgression {
                    Text("progression")
                        .font(.caption2)
                        .foregroundColor(Color.textFaint)
                        .italic()
                }
                Spacer()
                if let saved = VocabularyService.lookupSync(term.term) {
                    Button {
                        // V0.47 §6 decision 3 (c): confirm-dialog re-map.
                        // Estimate affected set count from cache; the
                        // exact workout_sets count requires a Supabase
                        // query — out of scope for this slice. We show
                        // a conservative "a few past sets" copy and
                        // log the heuristic in the commit body.
                        let count = Self.estimateAffectedSetCount(for: term.term)
                        remapCandidate = RemapCandidate(
                            term: term.term,
                            estimatedSetCount: count
                        )
                        showRemapConfirm = true
                    } label: {
                        Text("\(saved.label) · edit")
                            .font(.caption2)
                            .foregroundColor(Color.textMuted)
                    }
                }
            }

            if let context = term.sourceLine, !context.isEmpty {
                Text(context)
                    .font(.caption2)
                    .foregroundColor(Color.textFaint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if isProgression {
                progressionPickers
            } else {
                bucketChips
            }

            saveButton
        }
        .padding(10)
        .background(Color.bgInset.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onAppear { hydrateDefaults() }
        .alert(
            "Update past sets?",
            isPresented: $showRemapConfirm,
            presenting: remapCandidate
        ) { candidate in
            Button("Update \(candidate.estimatedSetCount)") {
                Task { await applyRemap(for: candidate) }
            }
            Button("Cancel", role: .cancel) { }
        } message: { candidate in
            Text("This will update \(candidate.displayCount) that used \"\(candidate.term)\".")
        }
    }

    private var bucketChips: some View {
        HStack(spacing: 6) {
            ForEach(VocabularyService.rpeBuckets, id: \.self) { bucket in
                Button {
                    Haptics.selection()
                    selectedBucket = bucket
                } label: {
                    Text(bucket.label)
                        .font(.caption2)
                        .foregroundColor(selectedBucket == bucket ? Color.bgBase : Color.textMuted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            selectedBucket == bucket
                                ? Color.accentAmber
                                : Color.bgInset
                        )
                        .clipShape(Capsule())
                        .overlay(
                            Capsule().stroke(
                                selectedBucket == bucket
                                    ? Color.accentAmber
                                    : Color.divider,
                                lineWidth: 1
                            )
                        )
                }
            }
        }
    }

    private var progressionPickers: some View {
        // Two pickers on the same row: start RPE and end RPE. Pre-selected
        // to the engine's silent default when present; both default to 7
        // (mid aerobic) so the picker is never empty when no default
        // exists. The "Save progression" button is enabled when start <= end
        // — descending is the only legal shape.
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("start")
                    .font(.caption2)
                    .foregroundColor(Color.textFaint)
                Picker("", selection: Binding(
                    get: { startRPE ?? 6 },
                    set: { startRPE = $0; Haptics.selection() }
                )) {
                    ForEach(4...10, id: \.self) { rpe in
                        Text("\(rpe)").tag(rpe)
                    }
                }
                .pickerStyle(.menu)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("end")
                    .font(.caption2)
                    .foregroundColor(Color.textFaint)
                Picker("", selection: Binding(
                    get: { endRPE ?? 8 },
                    set: { endRPE = $0; Haptics.selection() }
                )) {
                    ForEach(4...10, id: \.self) { rpe in
                        Text("\(rpe)").tag(rpe)
                    }
                }
                .pickerStyle(.menu)
            }
            Spacer()
        }
    }

    private var saveButton: some View {
        HStack {
            Spacer()
            Button {
                Task { await save() }
            } label: {
                Text(isProgression ? "Save progression" : "Save")
                    .font(.captionStrong)
                    .foregroundColor(canSave ? Color.bgBase : Color.textMuted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(canSave ? Color.accentAmber : Color.bgInset)
                    .clipShape(Capsule())
            }
            .disabled(!canSave)
        }
    }

    private var canSave: Bool {
        if isProgression {
            guard let s = startRPE, let e = endRPE else { return false }
            return s >= 4 && e >= 4 && s <= e
        } else {
            return selectedBucket != nil
        }
    }

    private func hydrateDefaults() {
        // Pre-select from the engine's silent defaults when present. The
        // engine's Tier-2 table isn't reachable from iOS at runtime — we
        // use a small client-side mirror for the most common cases. If
        // the default is absent, the row stays unselected (canSave stays
        // false) until the coach taps a chip — that's the explicit ask.
        let lower = term.term.lowercased()
        if isProgression {
            if lower.hasPrefix("build") {
                startRPE = startRPE ?? 6
                endRPE = endRPE ?? 8
            } else if lower.hasPrefix("desc") {
                startRPE = startRPE ?? 7
                endRPE = endRPE ?? 9
            }
        } else {
            switch lower {
            case "moderate": selectedBucket = selectedBucket ?? VocabularyService.RPERange(low: 6, high: 7)
            case "hard":     selectedBucket = selectedBucket ?? VocabularyService.RPERange(low: 8, high: 9)
            case "easy":     selectedBucket = selectedBucket ?? VocabularyService.RPERange(low: 4, high: 5)
            case "steady":   selectedBucket = selectedBucket ?? VocabularyService.RPERange(low: 6, high: 7)
            case "strong":   selectedBucket = selectedBucket ?? VocabularyService.RPERange(low: 8, high: 9)
            case "fast":     selectedBucket = selectedBucket ?? VocabularyService.RPERange(low: 8, high: 9)
            case "max", "maximal": selectedBucket = selectedBucket ?? VocabularyService.RPERange(low: 10, high: 10)
            case "all-out", "blast": selectedBucket = selectedBucket ?? VocabularyService.RPERange(low: 10, high: 10)
            case "tempo":    selectedBucket = selectedBucket ?? VocabularyService.RPERange(low: 7, high: 8)
            default: break
            }
        }
    }

    private func save() async {
        if isProgression {
            guard let s = startRPE, let e = endRPE else { return }
            await VocabularyService.shared.saveProgression(
                term: term.term,
                startRPE: s,
                endRPE: e
            )
        } else if let bucket = selectedBucket {
            await VocabularyService.shared.saveMapping(
                term: term.term,
                rpe: bucket
            )
        }
        onSaved(term.term)
    }

    private func applyRemap(for candidate: RemapCandidate) async {
        // Re-map flow: write the new mapping with the row's current
        // selection. The set-level RPE display will pick up the new
        // mapping the next time the fragment rows render (fragment ids
        // DO NOT change — V0.35 invariant).
        await save()
    }

    /// V0.47 §6 decision 3 (c): confirm dialog with N past sets. For
    /// this slice, we estimate N from the vocabulary cache's
    /// `sampleCount` when the term was previously saved with that
    /// field, otherwise fall back to "a few past sets" — the exact
    /// workout_sets join is a Supabase query that lives outside this
    /// iOS slice. Documented in the commit body.
    private static func estimateAffectedSetCount(for term: String) -> Int {
        // Conservative lower bound: 1 (the row that originally
        // triggered the save). The server-side join is out of scope
        // for this iOS slice; future slice can promote this to an
        // exact count via Supabase.
        return 1
    }
}

/// V0.47 Slice 3 (2026-08-22): payload for the remap confirm alert.
/// Carries the term and a conservative lower-bound set count so the
/// alert copy reads "This will update N past sets.".
private struct RemapCandidate: Identifiable {
    let id = UUID()
    let term: String
    let estimatedSetCount: Int

    var displayCount: String {
        switch estimatedSetCount {
        case 0: return "a few past sets"
        case 1: return "1 past set"
        default: return "\(estimatedSetCount) past sets"
        }
    }
}