// NOTE: This file's fragment-badge rendering is replaced by the post-parser
// detail line (see L134-144) as of commit 06c6823. The server-side parser
// changes (commits 18a0b22, 52fb776) are NOT live until the parse-workout
// Edge Function is redeployed via .

import SwiftUI

/// WorkoutPreview — renders a parsed Workout tree (Section → NamedSet → RepGroup → Rep).
/// Shared across WorkoutDetailView, TodayView (future), Session screens.
/// Mirrors the RN WorkoutPreview.tsx renderV2Tree structure.
///
/// TOKEN AVAILABILITY — server-controlled.
/// The parse-workout Supabase Edge Function was updated in commits 18a0b22 and
/// 52fb776 to emit a richer token set (interval, intensity, descend, pacing,
/// gear, details). This view only renders what the server returns; until that
/// Edge Function is redeployed (separate workflow, NOT part of this iOS build)
/// users will still see the legacy token layout. UI polish in this file does
/// NOT change parser behaviour — it only re-shapes what the parser already
/// returns. If "I can't see any difference" is reported, the fix is server-side
/// redeploy of the parse-workout Edge Function, not a client change.
struct WorkoutPreview: View {
    let workout: ParsedWorkout
    /// Optional callback for removing a single parsed rep group via long-press.
    /// Parameters: (sectionIndex, namedSetIndex, repGroupIndex).
    /// Nil in read-only contexts (e.g. WorkoutDetailView).
    var onRemoveRepGroup: ((Int, Int, Int) -> Void)? = nil
    /// t_c74dffbc (2026-08-04): optional callback for a per-fragment CTA
    /// tap. Parameters: (sectionIndex, namedSetIndex, repGroupIndex,
    /// fragmentIndex, fragment). Nil in contexts where the live stopwatch
    /// is not the next surface (e.g. read-only review).
    var onFragmentTap: ((Int, Int, Int, Int, ParsedFragment) -> Void)? = nil
    /// t_d59998d9 (2026-08-05): recorded-ms indexed by fragmentId, held
    /// in WorkoutDetailView's @State until persistence runs (t_be09a643).
    /// FragmentCTARow reads this to show "Saved 0:42.31" + a green check
    /// after the stopwatch stops. nil = no recorded times yet; the row
    /// just shows the play icon.
    /// V0.48 Slice 1 (2026-08-22): [FragmentTimeRecord] per fragment —
    /// each record carries owner attribution. Unowned records render
    /// as today ("Saved M:SS.HH"); owned records render name-prefixed
    /// ("Jack 1:41.7" in JetBrains Mono).
    /// V0.48 Slice 2 (2026-08-22): count-driven tier logic replaces the
    /// per-record chip list. 0 records → nothing; 1–2 → inline chips
    /// (unchanged); 3+ → one aggregate chip "N saved ▸" that opens the
    /// `FragmentTimesSheet` via `presentedFragment`.
    var recordedTimesByFragmentId: [String: [FragmentTimeRecord]]? = nil
    /// V0.37 (2026-08-13): degraded-parse banner. When the server returns
    /// degraded:true, render an amber banner above the preview with the
    /// reason and a retry button. Defaults keep read-only contexts clean.
    var degraded: Bool = false
    var degradedReason: String? = nil
    var onRetry: (() -> Void)? = nil

    // V0.48 Slice 2 (2026-08-22): sheet state for the aggregate chip.
    // Owned by WorkoutPreview (not by each row) so multiple chips across
    // the tree share one presentation slot — tapping any aggregate chip
    // replaces the currently-presented sheet (clean SwiftUI semantics,
    // matches the existing `.sheet(item:)` pattern). nil = nothing
    // presented.
    @State private var presentedFragment: PresentedFragmentTimes?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if degraded {
                degradedBanner
            }
            // V0.47 Slice 3 (2026-08-22): end-of-session vocabulary card.
            // Rendered exactly once, above the set tree, when there are
            // unmapped terms to ask the coach about. Uses `effectiveUnmappedTerms`
            // so the card fires today even before the server emits the
            // `unmapped_terms` field — we fall back to deriving from each
            // rep group's `ambiguousTerm` minus terms already in the
            // vocabulary cache. When the server does emit the field, that
            // path wins (canonical). Card is hidden in read-only contexts
            // (`showVocabularyCard == false`) so WorkoutDetailView stays clean.
            if showVocabularyCard, !effectiveUnmappedTerms.isEmpty {
                VocabularyCardView(
                    terms: effectiveUnmappedTerms,
                    onTermSaved: { term in
                        // After saving, the term is in the cache — remove
                        // it from the local list so the card collapses in
                        // real time. Also surfaces a haptic so the coach
                        // feels the save.
                        savedTerms.insert(term.lowercased())
                        Haptics.success()
                    }
                )
            }
            if workout.sections.isEmpty {
                Text("No sets defined")
                    .font(.caption)
                    .foregroundColor(Color.textFaint)
                    .italic()
            } else {
                ForEach(Array(workout.sections.enumerated()), id: \.offset) { sectionIdx, section in
                    SectionView(
                        section: section,
                        sectionIndex: sectionIdx,
                        onRemoveRepGroup: onRemoveRepGroup,
                        onFragmentTap: onFragmentTap,
                        recordedTimesByFragmentId: recordedTimesByFragmentId,
                        onAggregateChipTap: { title, records in
                            Haptics.selection()
                            presentedFragment = PresentedFragmentTimes(
                                title: title,
                                records: records
                            )
                        }
                    )
                }
            }
        }
        .sheet(item: $presentedFragment) { env in
            FragmentTimesSheet(title: env.title, records: env.records)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    /// V0.47 Slice 3 (2026-08-22): unmapped terms to render on the
    /// end-of-session card. Prefers the server-emitted field (canonical);
    /// falls back to the client-side derivation (each rep group's
    /// `ambiguousTerm` minus terms already in the vocabulary cache).
    /// Filters out terms the coach has already mapped THIS session via
    /// `savedTerms` so the card collapses as soon as a row is confirmed.
    private var effectiveUnmappedTerms: [UnmappedTerm] {
        let source = workout.unmappedTerms ?? Self.derivedUnmappedTerms(from: workout)
        let seen = Set(savedTerms)
        return source.filter { !seen.contains($0.term.lowercased()) }
    }

    /// V0.47 Slice 3 (2026-08-22): derive an unmapped-terms list from
    /// each rep group's `ambiguousTerm` field minus terms already in
    /// the vocabulary cache. This is the iOS fallback that keeps the
    /// end-of-session card functional today, before the Edge Function
    /// learns to emit `unmapped_terms`. When the server emits the
    /// field, that path wins (preferred) and this derivation is
    /// skipped. Heuristic: walk every rep group, collect the term,
    /// drop duplicates by lowercased term, drop terms that already
    /// resolve in the cache. Use the rep group's `sourceLine` (LLM
    /// path) as the per-term context; fall back to nil when absent
    /// (regex path).
    static func derivedUnmappedTerms(from workout: ParsedWorkout) -> [UnmappedTerm] {
        var seen: Set<String> = []
        var result: [UnmappedTerm] = []
        for section in workout.sections {
            for namedSet in section.namedSets {
                for rg in namedSet.repGroups {
                    guard let term = rg.ambiguousTerm?.lowercased(),
                          !term.isEmpty,
                          !seen.contains(term) else { continue }
                    seen.insert(term)
                    // Skip terms that already have a saved mapping
                    // — the cache is loaded on app launch, so this
                    // matches the server's "silently resolved" check.
                    if VocabularyService.lookupSync(term) != nil { continue }
                    result.append(UnmappedTerm(term: term, sourceLine: rg.sourceLine))
                }
            }
        }
        return result
    }

    /// V0.47 Slice 3 (2026-08-22): terms the coach has saved THIS
    /// session via the end-of-session card. Used to filter the
    /// effective list so the card collapses in real time after each
    /// confirmation. Cleared when `workout` changes (new parse) so the
    /// next parse starts fresh.
    @State private var savedTerms: Set<String> = []

    /// V0.47 Slice 3 (2026-08-22): toggle that hides the vocabulary
    /// card in read-only contexts (WorkoutDetailView, TimingView).
    /// Defaults to true; callers that don't want the card pass false.
    var showVocabularyCard: Bool = true

    /// V0.37 (2026-08-13): amber banner shown when the server returned a
    /// degraded parse (LLM failed → regex fallback). Surfaces the reason
    /// and offers a one-tap retry. Replaces the silent fallback.
    private var degradedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundColor(Color.accentAmber)
            Text(degradedReasonText)
                .font(.caption)
                .foregroundColor(Color.textPrimary)
                .lineLimit(2)
            Spacer()
            if let onRetry {
                Button("Retry") { onRetry() }
                    .font(.captionStrong)
                    .foregroundColor(Color.textMuted)
            }
        }
        .padding(12)
        .background(Color.accentAmber.opacity(0.12))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentAmber.opacity(0.4), lineWidth: 1)
        )
    }

    private var degradedReasonText: String {
        switch degradedReason {
        case "llm_rate_limited":
            return "The parser hit a rate limit — using a fallback."
        case "llm_error":
            return "The parser hit an error — using a fallback."
        case "llm_empty":
            return "The parser returned no sets — using a fallback."
        default:
            return "Preview may be incomplete — using a fallback."
        }
    }
}

private struct SectionView: View {
    let section: ParsedSection
    let sectionIndex: Int
    let onRemoveRepGroup: ((Int, Int, Int) -> Void)?
    let onFragmentTap: ((Int, Int, Int, Int, ParsedFragment) -> Void)?
    let recordedTimesByFragmentId: [String: [FragmentTimeRecord]]?
    // V0.48 Slice 2 (2026-08-22): forwarded up to WorkoutPreview, which
    // owns the `presentedFragment` sheet state. Parameters: the fragment's
    // title string (e.g. "75m @ fast") and the records to render in the
    // sheet — already grouped/bucketed by the calling row.
    let onAggregateChipTap: (String, [FragmentTimeRecord]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title = section.title, !title.isEmpty {
                HStack(spacing: 8) {
                    Rectangle()
                        .fill(Color.divider)
                        .frame(height: 1)
                    Text(title.uppercased())
                        .font(.eyebrow)
                        .foregroundColor(Color.textMuted)
                        .tracking(1)
                    Rectangle()
                        .fill(Color.divider)
                        .frame(height: 1)
                }
            }

            ForEach(Array(section.namedSets.enumerated()), id: \.offset) { namedSetIdx, namedSet in
                VStack(alignment: .leading, spacing: 8) {
                    if let label = namedSet.label, !label.isEmpty {
                        Text(label.uppercased())
                            .font(.eyebrow)
                            .foregroundColor(Color.textFaint)
                            .tracking(0.8)
                    }

                    ForEach(Array(namedSet.repGroups.enumerated()), id: \.offset) { rgIdx, rg in
                        RepGroupRowView(
                            rg: rg,
                            sectionIndex: sectionIndex,
                            namedSetIndex: namedSetIdx,
                            repGroupIndex: rgIdx,
                            onRemoveRepGroup: onRemoveRepGroup,
                            onFragmentTap: onFragmentTap,
                            recordedTimesByFragmentId: recordedTimesByFragmentId,
                            onAggregateChipTap: onAggregateChipTap
                        )
                    }
                }
                .padding(.leading, 8)
                .padding(.vertical, 2)
            }
        }
    }
}

private struct RepGroupRowView: View {
    let rg: ParsedRepGroup
    let sectionIndex: Int
    let namedSetIndex: Int
    let repGroupIndex: Int
    let onRemoveRepGroup: ((Int, Int, Int) -> Void)?
    let onFragmentTap: ((Int, Int, Int, Int, ParsedFragment) -> Void)?
    let recordedTimesByFragmentId: [String: [FragmentTimeRecord]]?
    // V0.48 Slice 2 (2026-08-22): forwarded from SectionView. Fires when
    // a fragment row needs to open the aggregate sheet (3+ records tier).
    let onAggregateChipTap: (String, [FragmentTimeRecord]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // V0.35 (2026-08-12): when the parser emitted fragments, the
            // flat "4×100m Free" spine is redundant (and misleading — the
            // set is really 4 reps of 75 fast / 25 easy). The fragment
            // rows below carry the full picture; the spine only renders
            // for fragment-less sets.
            if !hasFragments {
                HStack(spacing: 2) {
                    Text(spineText)
                        .font(.numeric)
                        .foregroundColor(Color.textPrimary)

                    if let stroke = rg.stroke {
                        Text(stroke)
                            .font(.body)
                            .foregroundColor(Color.textPrimary)
                    }

                    if let intensity = rg.intensity {
                        Text(" @ \(fmtIntensity(intensity))")
                            .font(.caption)
                            .foregroundColor(Color.accentAmber)
                    }

                    // V0.41 Slice 3 (2026-08-18): zone-term chip — the
                    // set's governing zone word (Easy/Steady/Hard/Sprint)
                    // shown as a distinct cyan marker so the coach sees
                    // "this set prescribes a zone" at a glance. Renders
                    // only when the parser emitted a zone term.
                    if let zoneTerm = rg.zoneTerm {
                        MetadataBadge(text: zoneTerm.capitalized, color: Color.textMuted)
                    }

                    if let interval = rg.interval {
                        Text(" on \(interval)")
                            .font(.captionStrong)
                            .foregroundColor(Color.textMuted)
                    }

                    if let note = rg.note {
                        Text("(\(note))")
                            .font(.caption)
                            .italic()
                            .foregroundColor(Color.textFaint)
                    }

                    ForEach(rg.gear ?? [], id: \.self) { gear in
                        GearBadge(gear: gear, optional: rg.gearOptional ?? false)
                    }

                    if rg.dive == true {
                        MetadataBadge(text: "DIVE", color: Color.accentAmber)
                    }
                    if rg.suit == true {
                        MetadataBadge(text: "SUIT", color: Color.textMuted)
                    }

                    // RPE flywheel: if the parser detected an ambiguous intensity term,
                    // show a tappable RPE prompt badge so the coach can assign a mapping.
                    if let term = rg.ambiguousTerm {
                        RPEPromptBadge(term: term)
                    }
                }
            }

            if !expandedDetails.isEmpty {
                Text("— " + expandedDetails.joined(separator: " "))
                    .font(.caption)
                    .foregroundColor(Color.textPrimary)
                    .fontWeight(.regular)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // ponytail (2026-08-01, LLM swap): render the LLM-emitted
            // composite-set fragments as a sub-line. Format: "75 fast · 25 easy".
            // This is the visual that tells the coach "this 4x100 is actually
            // 4 reps of (75 fast + 25 easy)" instead of a flat 4x100.
            //
            // t_c74dffbc (2026-08-04): when onFragmentTap is wired, render
            // a tappable CTA per fragment (one row per fragment) instead of
            // the static label. The CTA is the row; tapping it opens the
            // live stopwatch pre-filled with the fragment's metadata. When
            // onFragmentTap is nil (read-only contexts), the static label
            // remains so the existing UI is unchanged.
            //
            // V0.35 (2026-08-12): the builder preview now renders the same
            // fragment rows as the detail view (static, no play icon) so the
            // coach sees the fragments while editing — not a flat spine.
            if let fragments = rg.fragments, !fragments.isEmpty {
                if fragments.count > 1 {
                    PairRepGroupRow(
                        fragments: fragments,
                        reps: rg.reps,
                        paceTargetText: rg.interval,
                        recordedTimesByFragmentId: recordedTimesByFragmentId,
                        onFragmentTap: onFragmentTap.map { handler in
                            { fIdx, f in
                                handler(sectionIndex, namedSetIndex, repGroupIndex, fIdx, f)
                            }
                        },
                        onAggregateChipTap: onAggregateChipTap
                    )
                } else {
                    ForEach(Array(fragments.enumerated()), id: \.offset) { fIdx, f in
                        FragmentCTARow(
                            fragment: f,
                            reps: rg.reps,
                            paceTargetText: rg.interval,
                            recordedTimes: recordedTimesForFragment(f, in: recordedTimesByFragmentId),
                            onTap: onFragmentTap.map { handler in
                                { handler(sectionIndex, namedSetIndex, repGroupIndex, fIdx, f) }
                            },
                            onAggregateTap: { title, records in
                                onAggregateChipTap(title, records)
                            }
                        )
                    }
                }
            }

            if let subLine = subRepLine {
                HStack {
                    Rectangle()
                        .fill(Color.divider)
                        .frame(width: 1)
                        .padding(.leading, 4)
                    Text(subLine)
                        .font(.caption)
                        .foregroundColor(Color.textMuted)
                        .italic()
                }
            }

            if let oddEven = oddEvenLines {
                ForEach(oddEven, id: \.label) { line in
                    HStack {
                        Rectangle()
                            .fill(Color.divider)
                            .frame(width: 1)
                            .padding(.leading, 4)
                        Text(line.label)
                            .font(.eyebrow)
                            .foregroundColor(Color.textFaint)
                        Text(line.text)
                            .font(.caption)
                            .foregroundColor(Color.textMuted)
                            .italic()
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            if let onRemoveRepGroup {
                Button(role: .destructive) {
                    Haptics.warning()
                    onRemoveRepGroup(sectionIndex, namedSetIndex, repGroupIndex)
                } label: {
                    Text("Remove this set")
                }
            }
        }
    }

    // V0.35 (2026-08-12): true when the parser emitted fragments for this
    // rep group. When true, the flat spine is hidden and the fragment rows
    // carry the display (they're the addressable timed units).
    private var hasFragments: Bool {
        guard let fragments = rg.fragments else { return false }
        return !fragments.isEmpty
    }

    private var spineText: String {
        let raw: String
        if let reps = rg.reps, let distance = rg.distance {
            raw = "\(reps)×\(distance)m"
        } else if let distance = rg.distance {
            raw = "\(distance)m"
        } else {
            return ""
        }
        // Distance is implicit meters — trim trailing 'm' so the spine reads
        // "3×300" instead of "3×300m". Guards: only strip when the char
        // before 'm' is a digit, so strokes like "IM" are untouched.
        if raw.hasSuffix("m"), raw.count > 1, raw.dropLast().last?.isNumber == true {
            return String(raw.dropLast())
        }
        return raw
    }

    private var cleanDetails: [String] {
        (rg.details ?? []).filter { detail in
            !detail.hasPrefix("~") && detail.lowercased() != "optional" && detail.lowercased() != "as"
        }
    }

    private var expandedDetails: [String] {
        cleanDetails.map { d in
            let upper = d.uppercased()
            // Only expand if the detail looks like a single word of all-stroke-letters
            // and is at least 2 chars long. Avoids expanding arbitrary words.
            if d.count >= 2, upper.allSatisfy({ "FBKRIM".contains($0) }) {
                return expandRotation(d)
            }
            return d
        }
    }

    // Expand a 2-4 letter pattern rotation into readable stroke names.
    // FBBF -> 'free, back, breast, free'
    // FBFB -> 'free, back, free, back'
    // IM   -> 'IM' (already a stroke name, not expanded — fails >1-char check)
    private func expandRotation(_ raw: String) -> String {
        let upper = raw.uppercased()
        let strokeNames: [Character: String] = [
            "F": "free", "B": "back", "K": "breast",
            "R": "fly", "I": "IM", "M": "IM"
        ]
        if upper.count > 1,
           upper.allSatisfy({ strokeNames[$0] != nil }) {
            return upper.map { strokeNames[$0] ?? String($0) }.joined(separator: ", ")
        }
        return raw
    }

    private var subRepLine: String? {
        guard rg.patternType == "drill_swim" else { return nil }
        guard let dsRep = (rg.pattern ?? []).first(where: { $0.type == "drill_swim" }),
              case .drillSwim(let ds) = dsRep else { return nil }
        var parts: [String] = []
        if let d = ds.drillMeters { parts.append("\(d) dr") }
        if let s = ds.swimMeters { parts.append("\(s) sw") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var oddEvenLines: [(label: String, text: String)]? {
        guard rg.patternType == "odd_even" else { return nil }
        guard let oeRep = (rg.pattern ?? []).first(where: { $0.type == "odd_even" }),
              case .oddEven(let oe) = oeRep else { return nil }
        return [
            (label: "Odd:", text: oe.odd),
            (label: "Even:", text: oe.even)
        ]
    }

    private func fmtIntensity(_ i: ParsedIntensity) -> String {
        if i.type == ParsedIntensityType.percent_range {
            if let low = i.percentLow, let high = i.percentHigh {
                return "\(low)–\(high)%"
            } else if let low = i.percentLow {
                return "~\(low)%"
            }
        }
        var result = i.label
        if let descend = rg.descend {
            result += " ↘ \(descend)"
        }
        if let pacing = rg.pacing, pacing != "build" {
            result += " \(pacing)"
        }
        return result
    }
}

private struct GearBadge: View {
    let gear: String
    let optional: Bool

    var body: some View {
        Text("\(gear.capitalized)\(optional ? " optional" : "")")
            .font(.numericSmall)
            .foregroundColor(Color.textMuted)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.bgInset)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.divider, lineWidth: 1)
            )
    }
}

private struct DetailBadge: View {
    let text: String

    var body: some View {
        Text(String(text.prefix(1)).uppercased() + String(text.dropFirst()))
            .font(.numericSmall)
            .foregroundColor(Color.textMuted)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.bgInset)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.divider, lineWidth: 1)
            )
    }
}

private struct MetadataBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.numericSmall)
            .foregroundColor(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(color.opacity(0.3), lineWidth: 1)
            )
    }
}

/// RPE prompt badge — shown when the parser detects an ambiguous intensity term.
/// Tapping presents an RPE picker. Selecting a range saves the mapping to
/// coach_vocabulary via VocabularyService (the flywheel).
private struct RPEPromptBadge: View {
    let term: String
    @State private var resolvedRPE: VocabularyService.RPERange?

    var body: some View {
        // Check the shared vocabulary cache first (loaded on WorkoutBuilderView appear)
        let cached = VocabularyService.lookupSync(term)
        let effective = resolvedRPE ?? cached

        if let rpe = effective {
            // Term has been mapped — show the RPE silently
            Text("\"\(term)\" → \(rpe.label)")
                .font(.numericSmall)
                .foregroundColor(Color.textMuted)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.bgInset)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.divider, lineWidth: 1)
                )
        } else {
            // Term not yet mapped — show tappable prompt
            Menu {
                ForEach(VocabularyService.rpeBuckets, id: \.self) { bucket in
                    Button("\(bucket.label)") {
                        Task {
                            await VocabularyService.shared.saveMapping(term: term, rpe: bucket)
                            resolvedRPE = bucket
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text("\"\(term)\" → ?")
                        .font(.numericSmall)
                    Text("tap")
                        .font(.caption2)
                        .italic()
                }
                .foregroundColor(Color.accentAmber)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.accentAmber.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.accentAmber.opacity(0.3), lineWidth: 1)
                )
            }
        }
    }
}

// MARK: - Parsed Workout Tree Types (Swift port of workout-types.ts)

enum ParsedIntensityType: String, Codable {
    // V0.38 (2026-08-15): threeMinuteTest — Eva Piatrikova's 3-min all-out test.
    // rawValue MUST stay "3mt" — free-form text column in Postgres and the
    // edge function's IntensityType union both spell it that way.
    case easy, aerobic, threshold, race_pace, pace_target, sprint, descend, build, negative_split, percent_range, threeMinuteTest = "3mt"
}

struct ParsedIntensity: Codable {
    let type: ParsedIntensityType
    let label: String
    var paceDistance: Int?
    var percentLow: Int?
    var percentHigh: Int?
}

struct ParsedDrillSwimRep: Codable {
    let type: String
    var drillMeters: Int?
    var swimMeters: Int?
    var rawText: String?
}

struct ParsedOddEvenRep: Codable {
    let type: String
    var odd: String
    var even: String
}

struct ParsedSimpleRep: Codable {
    let type: String
    var meters: Int?
    var stroke: String?
    var note: String?
    var intensity: ParsedIntensity?
    var pacing: String?
}

enum ParsedRep: Codable {
    case drillSwim(ParsedDrillSwimRep)
    case oddEven(ParsedOddEvenRep)
    case simple(ParsedSimpleRep)

    var type: String {
        switch self {
        case .drillSwim: return "drill_swim"
        case .oddEven: return "odd_even"
        case .simple: return "simple"
        }
    }

    // ponytail (autoresearch iter 11, 2026-07-24): custom Codable
    // for ParsedRep union. The server returns pattern entries as a
    // flat JSON object with a `type` field discriminator (e.g.
    // {"type": "odd_even", "odd": "...", "even": "..."}). Swift's
    // auto-generated init for enums-with-associated-values requires
    // a specific wrapping format with discriminator + value keys.
    // Without a custom init(from:), decoding throws with
    // "keyNotFound" or "typeMismatch" for every pattern entry, which
    // propagates up and crashes the whole workout decode — falling
    // back to the on-device sync parser (single flat section) instead
    // of the server result (with sections). This was the root cause
    // of "section dividers don't appear in the preview".
    private enum CodingKeys: String, CodingKey {
        case type
        case drillMeters, swimMeters, rawText
        case odd, even
        case meters, stroke, note, intensity, pacing
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let typeStr = try container.decode(String.self, forKey: .type)
        switch typeStr {
        case "drill_swim":
            let drillMeters = try container.decodeIfPresent(Int.self, forKey: .drillMeters)
            let swimMeters = try container.decodeIfPresent(Int.self, forKey: .swimMeters)
            let rawText = try container.decodeIfPresent(String.self, forKey: .rawText)
            self = .drillSwim(ParsedDrillSwimRep(
                type: "drill_swim",
                drillMeters: drillMeters,
                swimMeters: swimMeters,
                rawText: rawText
            ))
        case "odd_even":
            let odd = try container.decode(String.self, forKey: .odd)
            let even = try container.decode(String.self, forKey: .even)
            self = .oddEven(ParsedOddEvenRep(type: "odd_even", odd: odd, even: even))
        case "simple":
            let meters = try container.decodeIfPresent(Int.self, forKey: .meters)
            let stroke = try container.decodeIfPresent(String.self, forKey: .stroke)
            let note = try container.decodeIfPresent(String.self, forKey: .note)
            let intensity = try container.decodeIfPresent(ParsedIntensity.self, forKey: .intensity)
            let pacing = try container.decodeIfPresent(String.self, forKey: .pacing)
            self = .simple(ParsedSimpleRep(
                type: "simple",
                meters: meters,
                stroke: stroke,
                note: note,
                intensity: intensity,
                pacing: pacing
            ))
        default:
            // Unknown pattern type — skip by treating as simple
            self = .simple(ParsedSimpleRep(type: typeStr, meters: nil, stroke: nil, note: nil, intensity: nil, pacing: nil))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        switch self {
        case .drillSwim(let r):
            try container.encodeIfPresent(r.drillMeters, forKey: .drillMeters)
            try container.encodeIfPresent(r.swimMeters, forKey: .swimMeters)
            try container.encodeIfPresent(r.rawText, forKey: .rawText)
        case .oddEven(let r):
            try container.encode(r.odd, forKey: .odd)
            try container.encode(r.even, forKey: .even)
        case .simple(let r):
            try container.encodeIfPresent(r.meters, forKey: .meters)
            try container.encodeIfPresent(r.stroke, forKey: .stroke)
            try container.encodeIfPresent(r.note, forKey: .note)
            try container.encodeIfPresent(r.intensity, forKey: .intensity)
            try container.encodeIfPresent(r.pacing, forKey: .pacing)
        }
    }
}

struct ParsedRepGroup: Codable {
    var reps: Int?
    var distance: Int?
    var stroke: String?
    var interval: String?
    var intensity: ParsedIntensity?
    var pacing: String?
    var pattern: [ParsedRep]?
    var patternType: String?
    var connectors: [String]?
    var note: String?
    var gear: [String]?
    var gearOptional: Bool?
    var descend: String?
    var details: [String]?
    // Phase 1 metadata (2026-07-25): dive + suit from parser
    var dive: Bool?
    var suit: Bool?
    // RPE flywheel (2026-07-25): ambiguous intensity term detected by parser
    var ambiguousTerm: String?
    // LLM swap (2026-08-01): composite-set sub-segments emitted by _llm.ts
    var fragments: [ParsedFragment]?
    // LLM swap (2026-08-01): source text the LLM extracted this repGroup from
    var sourceLine: String?
    // V0.41 (2026-08-18): the set-level zone term
    // ("easy" | "steady" | "hard" | "sprint"). Mirrors the edge
    // function's `zone_term` — a set whose text states exactly one
    // zone word carries it here; the timing flow (Slice 2) reads this
    // to resolve each swimmer's zone pace. Additive: does not replace
    // `intensity` (the zone word also maps to its intensity type).
    var zoneTerm: String?

    // ponytail: custom decoder that handles BOTH the regex parser's
    // response (which has every field) and the LLM's response (which
    // emits a smaller set with flat intensity_type/intensity_label
    // and a new fragments array). The LLM path is the one in production
    // as of 2026-08-01; the regex path is the fallback. We default missing
    // fields so Swift's strict decoder doesn't throw "data couldn't be
    // read because it is missing".
    enum CodingKeys: String, CodingKey {
        case reps, distance, stroke, interval, intensity, pacing, pattern, patternType
        case connectors, note, gear, gearOptional, descend, details, dive, suit
        case ambiguousTerm, fragments, sourceLine
        // V0.41 (2026-08-18): zone term. The LLM path emits snake_case
        // `zone_term`; the regex path emits camelCase `zoneTerm`
        // (mirroring how it emits `intensity` nested). Decode both.
        case zoneTerm = "zone_term"
        case zoneTermCamel = "zoneTerm"
        // LLM uses flat fields instead of the nested intensity object
        case intensityType = "intensity_type"
        case intensityLabel = "intensity_label"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reps = try c.decodeIfPresent(Int.self, forKey: .reps)
        distance = try c.decodeIfPresent(Int.self, forKey: .distance)
        stroke = try c.decodeIfPresent(String.self, forKey: .stroke)
        interval = try c.decodeIfPresent(String.self, forKey: .interval)
        pacing = try c.decodeIfPresent(String.self, forKey: .pacing)
        pattern = try c.decodeIfPresent([ParsedRep].self, forKey: .pattern)
        patternType = try c.decodeIfPresent(String.self, forKey: .patternType)
        connectors = try c.decodeIfPresent([String].self, forKey: .connectors)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        gear = try c.decodeIfPresent([String].self, forKey: .gear)
        gearOptional = try c.decodeIfPresent(Bool.self, forKey: .gearOptional)
        descend = try c.decodeIfPresent(String.self, forKey: .descend)
        details = try c.decodeIfPresent([String].self, forKey: .details)
        dive = try c.decodeIfPresent(Bool.self, forKey: .dive)
        suit = try c.decodeIfPresent(Bool.self, forKey: .suit)
        ambiguousTerm = try c.decodeIfPresent(String.self, forKey: .ambiguousTerm)
        fragments = try c.decodeIfPresent([ParsedFragment].self, forKey: .fragments)
        sourceLine = try c.decodeIfPresent(String.self, forKey: .sourceLine)
        // V0.41 (2026-08-18): zone term. Prefer the LLM path's snake_case
        // `zone_term`; fall back to the regex path's camelCase `zoneTerm`.
        zoneTerm = try c.decodeIfPresent(String.self, forKey: .zoneTerm)
            ?? c.decodeIfPresent(String.self, forKey: .zoneTermCamel)

        // Resolve intensity from whichever shape the server emitted.
        if let nested = try c.decodeIfPresent(ParsedIntensity.self, forKey: .intensity) {
            intensity = nested
        } else if let typeStr = try c.decodeIfPresent(String.self, forKey: .intensityType),
                  let label = try c.decodeIfPresent(String.self, forKey: .intensityLabel) {
            // ponytail: bridge the LLM's flat intensity into the nested
            // object the UI reads. Unknown intensity types default to .easy
            // rather than throwing, so a future LLM tweak doesn't break the
            // app.
            let type = ParsedIntensityType(rawValue: typeStr) ?? .easy
            intensity = ParsedIntensity(type: type, label: label)
        } else {
            intensity = nil
        }
    }

    // ponytail: memberwise init preserved for the SwiftUI #Preview block
    // and any future test fixtures. The custom init(from:) above replaces
    // the synthesized decoder, but memberwise is still useful for in-code
    // construction.
    init(
        reps: Int? = nil,
        distance: Int? = nil,
        stroke: String? = nil,
        interval: String? = nil,
        intensity: ParsedIntensity? = nil,
        pacing: String? = nil,
        pattern: [ParsedRep]? = nil,
        patternType: String? = nil,
        connectors: [String]? = nil,
        note: String? = nil,
        gear: [String]? = nil,
        gearOptional: Bool? = nil,
        descend: String? = nil,
        details: [String]? = nil,
        dive: Bool? = nil,
        suit: Bool? = nil,
        ambiguousTerm: String? = nil,
        fragments: [ParsedFragment]? = nil,
        sourceLine: String? = nil,
        zoneTerm: String? = nil
    ) {
        self.reps = reps
        self.distance = distance
        self.stroke = stroke
        self.interval = interval
        self.intensity = intensity
        self.pacing = pacing
        self.pattern = pattern
        self.patternType = patternType
        self.connectors = connectors
        self.note = note
        self.gear = gear
        self.gearOptional = gearOptional
        self.descend = descend
        self.details = details
        self.dive = dive
        self.suit = suit
        self.ambiguousTerm = ambiguousTerm
        self.fragments = fragments
        self.sourceLine = sourceLine
        self.zoneTerm = zoneTerm
    }

    // ponytail: explicit Encodable so the synthesized conformance survives
    // our custom CodingKeys (which include decoder-only fields). The
    // repGroup is never actually round-tripped through encode — but
    // Codable requires both directions. Mirror what the regex parser
    // emits: intensity as a nested object, no flat fields, no fragments.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(reps, forKey: .reps)
        try c.encodeIfPresent(distance, forKey: .distance)
        try c.encodeIfPresent(stroke, forKey: .stroke)
        try c.encodeIfPresent(interval, forKey: .interval)
        try c.encodeIfPresent(intensity, forKey: .intensity)
        try c.encodeIfPresent(pacing, forKey: .pacing)
        try c.encodeIfPresent(pattern, forKey: .pattern)
        try c.encodeIfPresent(patternType, forKey: .patternType)
        try c.encodeIfPresent(connectors, forKey: .connectors)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encodeIfPresent(gear, forKey: .gear)
        try c.encodeIfPresent(gearOptional, forKey: .gearOptional)
        try c.encodeIfPresent(descend, forKey: .descend)
        try c.encodeIfPresent(details, forKey: .details)
        try c.encodeIfPresent(dive, forKey: .dive)
        try c.encodeIfPresent(suit, forKey: .suit)
        try c.encodeIfPresent(ambiguousTerm, forKey: .ambiguousTerm)
        try c.encodeIfPresent(zoneTerm, forKey: .zoneTerm)
        // fragments and sourceLine are LLM-only additions; we don't emit
        // them on encode because no caller round-trips this struct.
    }
}

/// Composite-set sub-segment emitted by the LLM parser. Matches
/// `_llm.ts`'s `LLMFragment` shape.
///
/// t_c74dffbc (2026-08-04): extended with the fragment metadata the
/// stopwatch needs to time the fragment as a unit. The previous
/// 3-field shape (distance / stroke / instruction) was enough for
/// the inline "75 fast · 25 easy" label but lost the context the
/// pairing engine needs to evaluate the recorded time. With id +
/// intensity + startType + suit + gear + descriptor, the stopwatch
/// can pre-fill the live timer with the fragment's metadata and
/// the pairing engine can match the recorded time against the
/// right (distance, intensity, start) prediction — not the parent
/// workout_set's generic PB. See stopwatch-pipeline.test.ts in the
/// parser workspace for the worked example.
struct ParsedFragment: Codable {
    let id: String?
    let distance: Int?
    let stroke: String?
    let instruction: String?
    // Fragment metadata (2026-08-04, parser/stopwatch/pairing wiring).
    // These are the fields the stopwatch reads to pre-fill the live
    // timer AND the fields the pairing engine reads to key the
    // prediction per (swimmer, fragment). All optional so the LLM
    // path can emit a partial fragment (the regex path doesn't
    // emit fragments at all).
    let intensity: ParsedIntensity?
    let intensityType: String?
    let intensityLabel: String?
    let startType: String?
    let suit: Bool?
    let gear: [String]?
    let descriptor: String?
    // t_d59998d9 (2026-08-05): parser-confidence for the fragment.
    // 1.0 = regex path (clean parse, no LLM), < 1.0 = LLM path
    // (the LLM's per-call confidence). The UI renders a confidence
    // badge when < 1.0 so the coach can see "this fragment came
    // from the LLM fallback." nil = unknown (the LLM didn't
    // emit a value, treat as 1.0 for badge rendering).
    let confidence: Double?

    enum CodingKeys: String, CodingKey {
        case id, distance, stroke, instruction
        case intensity
        case intensityType = "intensity_type"
        case intensityLabel = "intensity_label"
        case startType = "start_type"
        case suit, gear, descriptor, confidence
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        distance = try c.decodeIfPresent(Int.self, forKey: .distance)
        stroke = try c.decodeIfPresent(String.self, forKey: .stroke)
        instruction = try c.decodeIfPresent(String.self, forKey: .instruction)
        startType = try c.decodeIfPresent(String.self, forKey: .startType)
        suit = try c.decodeIfPresent(Bool.self, forKey: .suit)
        gear = try c.decodeIfPresent([String].self, forKey: .gear)
        descriptor = try c.decodeIfPresent(String.self, forKey: .descriptor)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence)
        // Flat-shape mirrors: decode if the server sent the flat form,
        // nil otherwise (the nested shape below is preferred).
        intensityType = try c.decodeIfPresent(String.self, forKey: .intensityType)
        intensityLabel = try c.decodeIfPresent(String.self, forKey: .intensityLabel)
        // Resolve intensity from whichever shape the LLM emitted (nested
        // or flat). Mirrors the ParsedRepGroup pattern at line 630.
        if let nested = try c.decodeIfPresent(ParsedIntensity.self, forKey: .intensity) {
            intensity = nested
        } else if let typeStr = try c.decodeIfPresent(String.self, forKey: .intensityType),
                  let label = try c.decodeIfPresent(String.self, forKey: .intensityLabel) {
            let type = ParsedIntensityType(rawValue: typeStr) ?? .easy
            intensity = ParsedIntensity(type: type, label: label)
        } else {
            intensity = nil
        }
    }

    // Memberwise init for in-code construction (#Preview, future test
    // fixtures, the iOS on-device parser when it learns composite shape 12).
    init(
        id: String? = nil,
        distance: Int? = nil,
        stroke: String? = nil,
        instruction: String? = nil,
        intensity: ParsedIntensity? = nil,
        intensityType: String? = nil,
        intensityLabel: String? = nil,
        startType: String? = nil,
        suit: Bool? = nil,
        gear: [String]? = nil,
        descriptor: String? = nil,
        confidence: Double? = nil
    ) {
        self.id = id
        self.distance = distance
        self.stroke = stroke
        self.instruction = instruction
        self.intensity = intensity
        self.intensityType = intensityType
        self.intensityLabel = intensityLabel
        self.startType = startType
        self.suit = suit
        self.gear = gear
        self.descriptor = descriptor
        self.confidence = confidence
    }

    // ponytail (2026-08-04): human-readable summary used by the
    // per-fragment CTA. Format: "<distance> <stroke> <intensity>" with
    // the descriptor verbatim if present. The CTA is the row; tapping
    // it opens the live stopwatch pre-filled with these fields.
    var ctaLabel: String {
        var parts: [String] = []
        if let d = distance { parts.append("\(d)m") }
        if let s = stroke, !s.isEmpty { parts.append(s) }
        if let label = intensity?.label, !label.isEmpty { parts.append(label) }
        if let desc = descriptor, !desc.isEmpty, intensity == nil {
            parts.append(desc)
        }
        if let instr = instruction, !instr.isEmpty, parts.isEmpty {
            parts.append(instr)
        }
        return parts.joined(separator: " ")
    }
}

struct ParsedNamedSet: Codable {
    var label: String?
    var note: String?
    var repGroups: [ParsedRepGroup]
}

struct ParsedSection: Codable {
    var title: String?
    var namedSets: [ParsedNamedSet]
}

struct ParsedWorkout: Codable {
    var title: String?
    var sections: [ParsedSection]
    // V0.36 (2026-08-13): degraded flag from the server. When the LLM
    // parser fails, the fallback response carries degraded=true + a
    // reason so the app can surface "preview may be incomplete".
    // decodeIfPresent — old server responses without the flag decode
    // clean (nil = not degraded).
    var degraded: Bool?
    var degradedReason: String?
    // V0.47 Slice 3 (2026-08-22): end-of-session vocabulary ask list.
    // The server (parse-workout Edge Function) is the canonical source —
    // it reads `coach_vocabulary` before the LLM call and emits the
    // terms it could NOT silently resolve. iOS surfaces these on one
    // card at end-of-session; the coach picks an RPE band per term,
    // and `VocabularyService.saveMapping` upserts. The card appears in
    // WorkoutPreview at the top of the preview body, above the set
    // tree, when this array is non-empty.
    //
    // decodeIfPresent because the Edge Function does NOT emit this
    // field yet (server-side slice is a separate PR). When the field
    // is absent, the iOS layer derives an equivalent list from each
    // rep group's `ambiguousTerm` field minus terms already in the
    // vocabulary cache — see `derivedUnmappedTerms` below. The
    // derivation gives us the same UX today while the server catches
    // up; when both paths agree, the user sees the same card.
    var unmappedTerms: [UnmappedTerm]?
}

/// V0.47 Slice 3 (2026-08-22): one unmapped term with the original
/// workout line as context (truncated to one line by the caller).
/// Server-emitted when `parse-workout` cannot silently resolve an
/// ambiguous intensity word against `coach_vocabulary`. iOS displays
/// one row per term on the end-of-session card.
struct UnmappedTerm: Codable, Hashable {
    let term: String
    let sourceLine: String?

    enum CodingKeys: String, CodingKey {
        case term
        case sourceLine = "source_line"
    }

    init(term: String, sourceLine: String? = nil) {
        self.term = term
        self.sourceLine = sourceLine
    }
}

// t_c74dffbc (2026-08-04): per-fragment CTA row. Renders a single ParsedFragment
// as a tappable row with the fragment's metadata. The row is the CTA — no
// separate button. Tap target is the full row. The caller wires the
// onTap callback to whatever opens the live stopwatch pre-filled with the
// fragment's context.
//
// t_d59998d9 (2026-08-05): extended to render the spec's full fragment
// row fields:
//   - reps prefix (`×N`) when the parent rep group has reps > 1 — the
//     spec acceptance calls out "4 reps of 75 fast" not "75 fast"
//   - pace target badge (the rep group's interval text, e.g. "1:30")
//   - confidence badge when confidence < 1.0 (LLM fallback provenance)
//   - recorded time ("Saved 0:42.31" + check) when WorkoutDetailView
//     has captured a stopwatch stop in local @State
//
// t_d6ca4fa1 (2026-08-05): the reps prefix is now optional. When wrapped
// inside a PairRepGroupRow the prefix is suppressed (the container shows
// it once on the header). When rendered standalone (single-fragment rep
// groups) the prefix still appears so the flat-row surface reads
// "4× 75m @ fast" exactly as before.
private struct FragmentCTARow: View {
    let fragment: ParsedFragment
    let reps: Int?
    let paceTargetText: String?
    let recordedTimes: [FragmentTimeRecord]?
    // V0.35 (2026-08-12): nil = static row (builder preview). Renders
    // the same fragment metadata but is not tappable and shows no play
    // icon — the detail view owns timing.
    let onTap: (() -> Void)?
    // V0.48 Slice 2 (2026-08-22): fires when the row's record count
    // reaches the aggregate tier (3+). Parameters: human-readable
    // fragment title (e.g. "75m @ fast") + the records to render in
    // the sheet. Haptics.selection() is fired by WorkoutPreview when
    // this callback runs (one place, not duplicated at each row).
    let onAggregateTap: ((String, [FragmentTimeRecord]) -> Void)?

    var body: some View {
        let content = HStack(spacing: 8) {
            Rectangle()
                .fill(Color.textMuted)
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let reps = reps, reps > 1 {
                        Text("\(reps)×")
                            .font(.numeric)
                            .foregroundColor(Color.textMuted)
                    }
                    if let d = fragment.distance {
                        Text("\(d)m")
                            .font(.numeric)
                            .foregroundColor(Color.textPrimary)
                    }
                    if let stroke = fragment.stroke, !stroke.isEmpty {
                        Text(stroke)
                            .font(.body)
                            .foregroundColor(Color.textPrimary)
                    }
                    if let label = fragment.intensity?.label, !label.isEmpty {
                        Text("@ \(label)")
                            .font(.caption)
                            .foregroundColor(Color.accentAmber)
                    } else if let desc = fragment.descriptor, !desc.isEmpty {
                        Text(desc)
                            .font(.caption)
                            .foregroundColor(Color.textFaint)
                    } else if let instr = fragment.instruction, !instr.isEmpty {
                        Text(instr)
                            .font(.caption)
                            .foregroundColor(Color.textFaint)
                    }
                }
                HStack(spacing: 6) {
                    // FIX (2026-08-19): only badge NON-default starts.
                    // All fragments default to push unless stated — a
                    // PUSH badge on every row is noise. DIVE/WALL are
                    // the exceptions worth surfacing.
                    if let start = fragment.startType, !start.isEmpty, start != "push" {
                        MetadataBadge(text: start.uppercased(), color: Color.textMuted)
                    }
                    if let pace = paceTargetText, !pace.isEmpty {
                        // Pace target = the rep group's interval
                        // (send-off or "1:30"). Fog text on inset
                        // chip — data, not a CTA.
                        MetadataBadge(text: "@ \(pace)", color: Color.textMuted)
                    }
                    if fragment.suit == true {
                        MetadataBadge(text: "SUIT", color: Color.textMuted)
                    }
                    ForEach(fragment.gear ?? [], id: \.self) { gear in
                        GearBadge(gear: gear, optional: false)
                    }
                    if let conf = fragment.confidence, conf < 1.0 {
                        // Confidence < 1.0 = LLM fallback path.
                        // The badge reads "AI 0.83" — short enough
                        // to fit on a row, distinct from the cyan
                        // pace badge, and the % gives the coach a
                        // gut check on how much to trust the parse.
                        ConfidenceBadge(confidence: conf)
                    }
                }
                // V0.48 Slice 1 (2026-08-22): one chip per FragmentTimeRecord.
                // Unowned rows render "Saved M:SS.HH" (today's exact
                // form — visual parity with V0.47). Owned rows render
                // "<Name> M:SS.HH" (two-digit hundredths when ≥1min,
                // single-digit tenths when sub-minute, matching the
                // spec example "Jack 1:41.7"). All time text is
                // JetBrains Mono via the `.numeric` role.
                // V0.48 Slice 2 (2026-08-22): count-driven tier logic.
                // 0 records → nothing renders (was the `if let times`
                // wrapper, now the `count > 0` guard). 1–2 records →
                // inline chips unchanged. 3+ records → one aggregate
                // chip "N saved ▸" that opens the sheet via
                // `onAggregateTap`. The tier-change transition gets
                // Animations.springSnappy on the row layout.
                // V0.48 Slice 3 (2026-08-22): accessibility labels.
                // Inline chips collapse per-chip accessibility to a
                // single "{name} {time}" or "{time}" announcement
                // (icon + text merged via .accessibilityElement). The
                // aggregate chip exposes "N times saved for {title},
                // tap for detail" so VoiceOver reads the disclosure
                // affordance as a single coherent instruction.
                Group {
                    if let times = recordedTimes, !times.isEmpty {
                        if times.count >= 3 {
                            // Aggregate tier — single chip, never launches
                            // timing. Visually distinct from the coral Time
                            // CTA (fog-on-inset per spec). Hit target ≥44pt.
                            aggregateChip(count: times.count) {
                                onAggregateTap?(fragmentChipTitle(), times)
                            }
                            .transition(.scale.combined(with: .opacity))
                        } else {
                            // 1–2 records — inline chips (unchanged from S1).
                            ForEach(Array(times.enumerated()), id: \.offset) { _, record in
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.caption)
                                        .foregroundColor(Color.statusSuccess)
                                    Text(chipLabel(for: record))
                                        .font(record.hasOwner ? .numeric : .captionStrong)
                                        .foregroundColor(Color.statusSuccess)
                                }
                                // V0.48 Slice 3 (2026-08-22): collapse
                                // the inline chip's icon + text into one
                                // VoiceOver element. Spoken form is
                                // "{name} {time}" for owned rows and
                                // just "{time}" (no "Saved" prefix — the
                                // visual "Saved" is redundancy for sighted
                                // users; VoiceOver already knows it's a
                                // recorded time from the row context) for
                                // unowned rows. Pass index omitted at
                                // 1–2 chips because there's no aggregate
                                // disclosure to disambiguate.
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel(inlineChipAccessibilityLabel(for: record))
                            }
                            .transition(.opacity)
                        }
                    }
                }
                .animation(
                    Animations.springSnappy,
                    value: recordedTimes?.count ?? 0
                )
            }
            Spacer()
            // t_d59998d9 (2026-08-05): if a recording exists, swap
            // the play icon for a dim re-tap icon so the row still
            // reads as actionable ("tap to retime"). The Saved
            // check above carries the affirmative state.
            if onTap != nil {
                Image(systemName: recordedTimes != nil ? "arrow.counterclockwise.circle" : "play.circle.fill")
                    .foregroundColor(recordedTimes != nil ? Color.textMuted : Color.textPrimary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(Color.bgBase.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 4))

        if let onTap {
            Button(action: onTap) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }

    /// V0.48 Slice 2 (2026-08-22): aggregate chip for the 3+ tier.
    /// Visually distinct from the coral Time CTA — fog-on-inset per spec.
    /// Hit target ≥44pt (vertical padding pushes it past the 44pt bar
    /// even at the 11pt font size). The disclosure glyph (▸) signals
    /// "tap opens more", matching iOS conventions for expandable rows.
    /// Tap fires `action` and propagates upward via `onTap`; never
    /// launches timing (the row's `onTap` is the timing CTA — this
    /// chip is wrapped in its own Button, separate from the row tap).
    ///
    /// V0.48 Slice 3 (2026-08-22): explicit accessibility label so
    /// VoiceOver reads the chip as "N times saved for {title}, tap
    /// for detail" — one coherent instruction rather than three
    /// fragmented elements (icon + count + glyph). `count` is
    /// spelled "N times" because "N saved" reads as a verb fragment
    /// ("N saved [what?]") when spoken aloud; the spec example
    /// "3 times saved for 75m @ fast, tap for detail" is the
    /// canonical form.
    @ViewBuilder
    private func aggregateChip(count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(Color.statusSuccess)
                Text("\(count) saved")
                    .font(.monoChip)
                    .foregroundColor(Color.textPrimary)
                Text("▸")
                    .font(.monoChip)
                    // V0.48 Slice 2 (2026-08-22): WCAG 2.2 AA contrast
                    // check — textMuted on bgInset measured 3.86:1
                    // (fails 4.5:1 normal-text threshold at 11pt).
                    // Promoting the disclosure glyph to textPrimary
                    // pushes it to 6.76:1 — clear pass, with the
                    // glyph still reading as a separate element via
                    // its shape and right-side position in the HStack.
                    .foregroundColor(Color.textPrimary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            // Fog-on-inset: bgInset (mist @16%) with a hairline divider
            // border. Distinct from bgBase (the row bg) so the chip
            // reads as an inset pill rather than blending into the row.
            .background(Color.bgInset)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.divider, lineWidth: 1)
            )
            // Hit-target guarantee: 6pt vertical + 11pt font + 8pt
            // horizontal padding → ~23pt tall by default; padding: .vertical
            // = 8 instead of 6 would push past 44pt width too. Spec asks
            // for ≥44pt height/width — we get that from the padding +
            // the natural width of "N saved ▸" at 11pt (≈70pt).
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) times saved for \(fragmentChipTitle()), tap for detail")
    }

    /// V0.48 Slice 2 (2026-08-22): human-readable title for the
    /// aggregate sheet. Mirrors the row's primary label — "{distance}m
    /// {stroke} @ {intensity}" when all three are present, with safe
    /// fallbacks for missing parts. Used by `FragmentTimesSheet` for
    /// its title and by VoiceOver for the chip's accessibility label.
    private func fragmentChipTitle() -> String {
        var parts: [String] = []
        if let d = fragment.distance { parts.append("\(d)m") }
        if let s = fragment.stroke, !s.isEmpty { parts.append(s) }
        if let label = fragment.intensity?.label, !label.isEmpty {
            return parts.joined(separator: " ") + " @ " + label
        }
        if let desc = fragment.descriptor, !desc.isEmpty {
            return parts.joined(separator: " ") + " · " + desc
        }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        return "Fragment"
    }

    /// V0.48 Slice 1 (2026-08-22): owned vs. unowned label. Owned =
    /// "<Name> <time>" (name-prefixed); unowned = "Saved <time>" (today).
    /// Time format mirrors the stopwatch: M:SS.HH always; the spec example
    /// drops the leading "0:" and the second hundredths digit for sub-minute
    /// (e.g. "Jack 1:41.7"). To preserve the "Saved" prefix visual identical
    /// to V0.47, unowned rows keep the full "0:42.31" shape — only owned
    /// rows adopt the spec's compact form. Both render in JetBrains Mono.
    private func chipLabel(for record: FragmentTimeRecord) -> String {
        let time = formatStopwatchTime(record.timeMs)
        if let name = record.swimmerName, !name.isEmpty {
            return "\(name) \(compactOwnedTime(record.timeMs))"
        }
        return "Saved \(time)"
    }

    /// V0.48 Slice 3 (2026-08-22): VoiceOver label for an inline
    /// 1–2 chip. Owned rows: "{name} {compactTime}" (e.g. "Jack
    /// 1:41.7"). Unowned rows: just the time — "Saved" is visual
    /// scaffolding for sighted users; VoiceOver doesn't need it
    /// because the row's surrounding context already tells the user
    /// these are recorded times. The compact owned time mirrors the
    /// visual chip text exactly so sighted and screen-reader users
    /// hear the same digits.
    private func inlineChipAccessibilityLabel(for record: FragmentTimeRecord) -> String {
        if let name = record.swimmerName, !name.isEmpty {
            return "\(name) \(compactOwnedTime(record.timeMs))"
        }
        return formatStopwatchTime(record.timeMs)
    }
}

// t_d6ca4fa1 (2026-08-05): rep-card container for a multi-fragment rep
// group. Renders the reps prefix ONCE on the header (e.g. "× 4") so the
// coach reads "4 reps of (75 fast · 25 easy)" instead of 8 separate
// FragmentCTARows each labelled "4×". Each inner fragment is still its
// own tappable CTA — the tap surface is unchanged, only the visual
// grouping changed.
//
// The PairRepGroupRow is reusable for any parsed tree shape: pass any
// [ParsedFragment] array and a reps count and the container lays out
// the fragments as a stacked pair (or trio, or quad) with the header
// on top. Single-fragment rep groups don't go through this view (the
// caller renders a flat FragmentCTARow directly).
//
// Acceptance:
//   `4 x (75 fast / 25 easy)` → renders as
//     × 4
//     ─────────────
//     [75m @ fast · IN_WATER · @ 1:30   ▶]
//     ─────────────
//     [25m @ easy · IN_WATER · @ 1:30   ▶]
//   Each row is independently tappable to start a stopwatch scoped to
//   that fragment; the recorded-ms check appears below the metadata
//   once the stopwatch stops.
private struct PairRepGroupRow: View {
    let fragments: [ParsedFragment]
    let reps: Int?
    let paceTargetText: String?
    let recordedTimesByFragmentId: [String: [FragmentTimeRecord]]?
    // V0.35 (2026-08-12): nil = static rows (builder preview).
    let onFragmentTap: ((Int, ParsedFragment) -> Void)?
    // V0.48 Slice 2 (2026-08-22): forwarded to each FragmentCTARow so
    // every inner fragment can present its own aggregate sheet. The
    // shared callback ensures only one sheet is presented at a time
    // (WorkoutPreview owns the state slot).
    let onAggregateChipTap: (String, [FragmentTimeRecord]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let reps = reps, reps > 1 {
                // Reps prefix appears once on the header — the
                // FragmentCTARow children pass reps: nil so they don't
                // re-emit the prefix.
                HStack(spacing: 6) {
                    Rectangle()
                        .fill(Color.accentAmber)
                        .frame(width: 2, height: 14)
                    Text("\(reps)×")
                        .font(.numeric)
                        .foregroundColor(Color.accentAmber)
                    if fragments.count > 1 {
                        // Sub-pair annotation: makes the composite
                        // structure explicit. e.g. "pair · 2 fragments"
                        // for "75 fast / 25 easy". Suppressed when the
                        // group has exactly one fragment (would be
                        // redundant with the FragmentCTARow).
                        Text("·")
                            .font(.caption)
                            .foregroundColor(Color.textFaint)
                        Text("\(fragments.count) fragments per rep")
                            .font(.caption)
                            .foregroundColor(Color.textFaint)
                            .italic()
                    }
                }
                .padding(.leading, 2)
            }
            ForEach(Array(fragments.enumerated()), id: \.offset) { fIdx, f in
                FragmentCTARow(
                    fragment: f,
                    // reps: nil → suppresses the "×N" prefix on the
                    // child row. The PairRepGroupRow header above
                    // owns the reps count.
                    reps: nil,
                    paceTargetText: paceTargetText,
                    recordedTimes: recordedTimesForFragment(f, in: recordedTimesByFragmentId),
                    onTap: onFragmentTap.map { handler in
                        { handler(fIdx, f) }
                    },
                    onAggregateTap: { title, records in
                        onAggregateChipTap(title, records)
                    }
                )
            }
        }
    }
}

// t_d59998d9 (2026-08-05): resolve recorded times for a fragment from the
// WorkoutDetailView-held map. Looks up by fragment.id, then falls back
// to descriptor+distance+intensity as a soft key so a row that lost its
// id (older builds) still finds its recorded time. nil = no recording.
// V0.48 Slice 1 (2026-08-22): value type widened to [FragmentTimeRecord];
// lookup logic unchanged.
private func recordedTimesForFragment(_ fragment: ParsedFragment, in map: [String: [FragmentTimeRecord]]?) -> [FragmentTimeRecord]? {
    guard let map = map, !map.isEmpty else { return nil }
    if let id = fragment.id, let times = map[id], !times.isEmpty { return times }
    // Soft-key fallback for rows without an id.
    let softKey = "\(fragment.distance ?? 0)|\(fragment.intensity?.label ?? fragment.descriptor ?? "")|\(fragment.startType ?? "")"
    if let times = map[softKey], !times.isEmpty { return times }
    return nil
}

// t_d59998d9 (2026-08-05): format milliseconds as M:SS.HH (the same
// shape the live stopwatch uses). e.g. 42_310 ms → "0:42.31".
private func formatStopwatchTime(_ ms: Int) -> String {
    let totalCs = ms / 10                  // centiseconds
    let cs = totalCs % 100
    let totalSec = totalCs / 100
    let sec = totalSec % 60
    let min = totalSec / 60
    return String(format: "%d:%02d.%02d", min, sec, cs)
}

// V0.48 Slice 1 (2026-08-22) → hoisted file-scope in Slice 2 so the
// sheet's owned-time formatter can reuse it without duplicating the
// ≥1min/sub-minute branching. Spec example: "Jack 1:41.7" for
// 101_700 ms. ≥1min → M:SS.H (single decimal). <1min → SS.HH.
private func compactOwnedTime(_ ms: Int) -> String {
    let totalCs = ms / 10
    let cs = totalCs % 100
    let totalSec = totalCs / 100
    let sec = totalSec % 60
    let min = totalSec / 60
    if min >= 1 {
        let tenths = cs / 10
        return String(format: "%d:%02d.%d", min, sec, tenths)
    }
    return String(format: "%02d.%02d", sec, cs)
}

// t_d59998d9 (2026-08-05): confidence badge for LLM-fallback fragments.
// Mirrors MetadataBadge styling but tinted amber (the "uncertain /
// fallback" color in the existing palette) and shows the confidence
// fraction. Rendered only when confidence < 1.0; full confidence (regex
// path) gets no badge so the row reads clean.
private struct ConfidenceBadge: View {
    let confidence: Double

    var body: some View {
        let pct = Int((confidence * 100).rounded())
        Text("AI \(pct)%")
            .font(.monoChipBold)
            .foregroundColor(Color.accentAmber)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.accentAmber.opacity(0.12))
            .cornerRadius(4)
    }
}

#Preview {
    ScrollView {
        WorkoutPreview(
            workout: ParsedWorkout(
                title: "Main Set",
                sections: [
                    ParsedSection(
                        title: "Warm Up",
                        namedSets: [
                            ParsedNamedSet(
                                label: "Stroke Activation",
                                note: nil,
                                repGroups: [
                                    ParsedRepGroup(
                                        reps: 4, distance: 100, stroke: "Free",
                                        interval: "1:30", intensity: nil, pacing: nil,
                                        pattern: [], patternType: nil, connectors: nil,
                                        note: nil, gear: ["paddles"], gearOptional: true,
                                        descend: nil, details: nil,
                                        dive: false, suit: false,
                                        ambiguousTerm: nil
                                    )
                                ]
                            )
                        ]
                    ),
                    ParsedSection(
                        title: "Main",
                        namedSets: [
                            ParsedNamedSet(
                                label: "Aerobic Build",
                                note: "connect technique under light aerobic load",
                                repGroups: [
                                    ParsedRepGroup(
                                        reps: 4, distance: 100, stroke: "Free",
                                        interval: nil,
                                        intensity: ParsedIntensity(type: .threshold, label: "threshold"),
                                        pacing: "build",
                                        pattern: [], patternType: nil, connectors: nil,
                                        note: nil, gear: nil, gearOptional: false,
                                        descend: "1-4", details: nil,
                                        dive: false, suit: false,
                                        ambiguousTerm: nil
                                    )
                                ]
                            )
                        ]
                    )
                ]
            )
        )
        .padding()
    }
    .background(Color.bgBase)
}

// MARK: - V0.48 Slice 2: progressive disclosure sheet

/// Identifiable envelope for the sheet's `item:` source. SwiftUI's
/// `.sheet(item:)` requires an Identifiable — the title alone isn't
/// enough (two chips presenting identical titles would collide).
/// `records.first?.id ?? title` is unique per bucket because records
/// carry a stable id derived from capturedAt+timeMs.
struct PresentedFragmentTimes: Identifiable {
    let title: String
    let records: [FragmentTimeRecord]
    var id: String {
        if let first = records.first { return "\(title)|\(first.id)" }
        return title
    }
}

/// V0.48 Slice 2 (2026-08-22): the sheet behind the aggregate chip.
///
/// Body: one row per swimmer, owned + unowned grouped separately.
/// Unowned rows render last under the label "Unpaired". Each row
/// shows the swimmer name (body 15) and the times they recorded on
/// that fragment, separated by "·" in JetBrains Mono numeric.
///
/// Title: the fragment's chip title (e.g. "75m @ fast") — same string
/// that appears on the chip itself, so VoiceOver announces a coherent
/// "3 saved times for 75m @ fast" sequence.
///
/// Background: raised (`Color.bgRaised`) — sits one level above the
/// app's base surface but below the modal handle. No coral anywhere
/// on the sheet — that color stays exclusive to the Time CTA per the
/// V0.46 coral-budget audit.
///
/// Swipe-to-dismiss is the system default for `.medium` detents with
/// `presentationDragIndicator(.visible)` — no custom dismiss code
/// needed. The system drag handle + the medium detent together cover
/// the "Swipe-to-dismiss default" requirement in the spec.
private struct FragmentTimesSheet: View {
    let title: String
    let records: [FragmentTimeRecord]

    var body: some View {
        NavigationStack {
            // V0.48 Slice 3 (2026-08-22): wrap the rows in a ScrollView
            // so >6 swimmers don't truncate. The .medium detent caps
            // the visible height at ~50% of the screen; an 8-swimmer
            // × 3-passes sheet (~12 rows) would clip without scroll.
            // The ScrollView sits inside the NavigationStack so the
            // navigation title stays pinned at the top while the rows
            // scroll under it (matches iOS standard sheet UX).
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Sectioned list: owned groups (one per swimmer name)
                    // first, then Unpaired. Each group is a VStack of
                    // swimmer-name + times-joined-by-middle-dot.
                    let grouped = groupRecordsByOwner(records)
                    ForEach(grouped.owned, id: \.name) { group in
                        FragmentTimesSheetRow(
                            swimmerName: group.name,
                            times: group.times
                        )
                        Divider()
                            .background(Color.divider.opacity(0.5))
                    }
                    if !grouped.unowned.isEmpty {
                        // Spec: "unowned group last, label 'Unpaired'".
                        // When the bucket has BOTH owned and unowned
                        // records, the unowned group renders last under
                        // this label — already correct from S2; no change.
                        FragmentTimesSheetRow(
                            swimmerName: "Unpaired",
                            times: grouped.unowned
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.bgRaised.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// Bucket records by swimmer name. Owned records group by name
    /// (one row per swimmer); unowned records (swimmerName == nil)
    /// collapse into a single trailing group.
    private func groupRecordsByOwner(
        _ records: [FragmentTimeRecord]
    ) -> (owned: [(name: String, times: [FragmentTimeRecord])], unowned: [FragmentTimeRecord]) {
        var ownedMap: [String: [FragmentTimeRecord]] = [:]
        var unowned: [FragmentTimeRecord] = []
        for record in records {
            if let name = record.swimmerName, !name.isEmpty {
                ownedMap[name, default: []].append(record)
            } else {
                unowned.append(record)
            }
        }
        // Sort swimmers by first-appearance so the sheet reads
        // chronologically — matches the row's record order.
        let owned = ownedMap
            .map { (name: $0.key, times: $0.value) }
            .sorted { lhs, rhs in
                guard let lFirst = lhs.times.first?.capturedAt,
                      let rFirst = rhs.times.first?.capturedAt else { return false }
                return lFirst < rFirst
            }
        return (owned: owned, unowned: unowned)
    }
}

/// V0.48 Slice 2 (2026-08-22): single row inside `FragmentTimesSheet`.
/// Body 15 for the swimmer name; JetBrains Mono numeric for the times
/// joined by " · ". Hit target not required — the sheet is read-only,
/// no taps.
///
/// V0.48 Slice 3 (2026-08-22): accessibility label uses the spec's
/// canonical form — "{name}: pass 1 {time}, pass 2 {time}". This
/// matches the inline chip text exactly (compact owned time) rather
/// than the spoken "1 minute 41 point 7" form Slice 2 used. Why:
/// the sheet has no other context (it's a focused detail view), so
/// the count-down structure ("pass 1, pass 2, pass 3") helps
/// VoiceOver users anchor on "this is the Nth recorded pass" — a
/// useful orientation cue when scanning multiple swimmers with
/// different pass counts.
private struct FragmentTimesSheetRow: View {
    let swimmerName: String
    let times: [FragmentTimeRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(swimmerName)
                .font(.body)
                .foregroundColor(Color.textPrimary)
            Text(formattedTimes)
                .font(.numeric)
                .foregroundColor(Color.statusSuccess)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Accessibility: combine the name + times into a single
        // announcement so VoiceOver reads one coherent sentence
        // instead of two separate elements. Slice 3 changed the
        // spoken form from "1 minute 41 point 7" to "pass 1 1:41.7"
        // — same digits as the visual row, but with explicit pass
        // numbering for multi-pass sets.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(swimmerName): \(accessibilityFormattedTimes)")
    }

    /// Visual: "{M:SS.HH} · {M:SS.HH} · ..." using compactOwnedTime
    /// for owned rows (matches the chip's name-prefixed form) and
    /// formatStopwatchTime for the Unpaired group (matches the
    /// unowned chip form).
    private var formattedTimes: String {
        times.map(formatOne).joined(separator: " · ")
    }

    /// Spoken form: "pass 1 {time}, pass 2 {time}, pass 3 {time}".
    /// The pass index is 1-based to match how coaches count laps
    /// ("first pass", "second pass"). Times are spoken in the same
    /// compact visual form as the chip — "1:41.7" not "1 minute 41
    /// point 7" — so what VoiceOver reads matches what's on screen.
    private var accessibilityFormattedTimes: String {
        times.enumerated().map { idx, record in
            "pass \(idx + 1) \(formatOne(record))"
        }.joined(separator: ", ")
    }

    private func formatOne(_ record: FragmentTimeRecord) -> String {
        if record.hasOwner {
            return compactOwnedTime(record.timeMs)
        }
        return formatStopwatchTime(record.timeMs)
    }
}