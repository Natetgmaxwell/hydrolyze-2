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
    /// V0.54 S2.1 (2026-09-08, jodie-09 user feedback): the top-level
    /// `RepCardContext` flag — `.preview` keeps the zero-CTA invariant
    /// (no play icons, no tap gestures on cards), `.live` is the
    /// Console's LIVE state (play icons visible on timable cards), and
    /// `.finished` is reserved for the POST summary (dimmed). Defaults
    /// to `.preview` so pre-V0.54 call sites keep their behaviour and
    /// the zero-CTA-in-preview contract continues to hold. The
    /// Console's PRE + LIVE bodies both render the full workout
    /// anatomy — only the interactive affordances narrow.
    var context: RepCardContext = .preview
    /// V0.54 S2.1 (2026-09-08): ordered set-id path identifying the
    /// current set when `context == .live`. Forwarded to each
    /// repGroup container so it can apply the "current" elevation
    /// (border + scale + accent bg) only to that one set. Completed
    /// sets (those before this set in `workout.sections[].namedSets
    /// [].repGroups[]` order) render full detail at reduced opacity.
    /// nil = no elevation (all sets render flat — the PRE / read-only
    /// path).
    var currentSetId: String? = nil
    /// V0.54 S2.1 (2026-09-08): the set-ids whose reps have already
    /// been timed (the COMPLETED set ids, in order). Each one renders
    /// full detail at reduced opacity. nil or empty = no completed
    /// sets yet (PRE / first LIVE rep).
    var completedSetIds: [String] = []
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

    /// V0.54 S3.3 (2026-09-09, jodie-09 PRE round 2): optional
    /// set-id set that should render EXPANDED even if they would
    /// otherwise collapse under the progressive-disclosure gate.
    /// Used by the screenshot harness's `-v54-s33-expand-warmdown`
    /// launch arg so the verification shot can capture both the
    /// collapsed default and the expanded state without needing a
    /// simctl tap (which isn't supported by the current harness).
    /// Empty / nil = the default collapsed behaviour holds (the
    /// progressive-disclosure wins).
    var preExpandSetIds: Set<String> = []

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
                        // V0.54 S2.1: thread the context flag + current-set
                        // pointer down to each repGroup container so the
                        // LIVE body can elevate the active set + dim
                        // completed ones. PRE (context == .preview)
                        // ignores these — all sets render flat at full
                        // opacity, the zero-CTA invariant.
                        context: context,
                        currentSetId: currentSetId,
                        completedSetIds: completedSetIds,
                        onAggregateChipTap: { title, records in
                            Haptics.selection()
                            presentedFragment = PresentedFragmentTimes(
                                title: title,
                                records: records
                            )
                        },
                        // V0.54 S3.3: forward the pre-expand set-ids
                        // through to each repGroup so the harness can
                        // seed expanded state for the verification
                        // screenshot.
                        preExpandSetIds: preExpandSetIds
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
    // V0.54 S2.1 (2026-09-08): the console state flag + set-elevation
    // pointer, forwarded down from WorkoutPreview. SectionView ignores
    // them itself (a section is a logical divider, not a set) — it
    // just hands them to each RepGroupRowView so the container can
    // apply elevation/dimming per set.
    let context: RepCardContext
    let currentSetId: String?
    let completedSetIds: [String]
    // V0.48 Slice 2 (2026-08-22): forwarded up to WorkoutPreview, which
    // owns the `presentedFragment` sheet state. Parameters: the fragment's
    // title string (e.g. "75m @ fast") and the records to render in the
    // sheet — already grouped/bucketed by the calling row.
    let onAggregateChipTap: (String, [FragmentTimeRecord]) -> Void
    // V0.54 S3.3: set-ids that should render EXPANDED even if they'd
    // otherwise collapse under the progressive-disclosure gate. See
    // WorkoutPreview.preExpandSetIds for context. Forwarded through
    // to each RepGroupRowView so the @State expansion can be seeded
    // on appear.
    let preExpandSetIds: Set<String>

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
                        // V0.54 S3.3 (2026-09-09, jodie-09 PRE round 2):
                        // single hairline Divider + 20pt vertical padding
                        // between consecutive repGroups (sets). Replaces
                        // the implicit "spacing only" rhythm with a visible
                        // structural rule — whitespace + one hairline does
                        // the grouping the chip chrome used to do. The
                        // first repGroup renders no leading divider (nothing
                        // to separate from), so the ForEach index gates
                        // it. Same divider color + thickness as the section
                        // title rule for visual consistency.
                        if rgIdx > 0 {
                            Divider()
                                .background(Color.divider)
                                .padding(.vertical, 20)
                        }
                        RepGroupRowView(
                            rg: rg,
                            sectionIndex: sectionIndex,
                            namedSetIndex: namedSetIdx,
                            repGroupIndex: rgIdx,
                            onRemoveRepGroup: onRemoveRepGroup,
                            onFragmentTap: onFragmentTap,
                            recordedTimesByFragmentId: recordedTimesByFragmentId,
                            // V0.54 S2.1: forward context + set-elevation
                            // pointer to each rep group container so the
                            // Console's LIVE body can render the active
                            // set with elevation + completed sets dimmed.
                            // PRE / read-only contexts default to
                            // .preview + nil — all sets render flat.
                            context: context,
                            currentSetId: currentSetId,
                            completedSetIds: completedSetIds,
                            onAggregateChipTap: onAggregateChipTap,
                            // V0.54 S3.3: forward pre-expand set-ids
                            // so the harness can seed an "already
                            // expanded" state for the verification
                            // screenshot without simctl tap support.
                            preExpandSetIds: preExpandSetIds
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
    // V0.54 S2.1 (2026-09-08): console context flag + current-set
    // pointer. RepGroupRowView is the elevation boundary: it owns
    // the per-set container so the "current" set's visual
    // treatment (border + scale + accent bg) lives here, not in
    // each child row. Default .preview keeps pre-V0.54 callers
    // (WorkoutDetailView, WorkoutBuilderView) rendering flat.
    let context: RepCardContext
    let currentSetId: String?
    let completedSetIds: [String]
    // V0.48 Slice 2 (2026-08-22): forwarded from SectionView. Fires when
    // a fragment row needs to open the aggregate sheet (3+ records tier).
    let onAggregateChipTap: (String, [FragmentTimeRecord]) -> Void
    // V0.54 S3.3: set-ids that should render EXPANDED even if
    // they'd otherwise collapse. Forwarded from
    // WorkoutPreview.preExpandSetIds via SectionView. Used by the
    // `.onAppear` hook below to seed `expanded = true` when the
    // harness asks for it (via `-v54-s33-expand-warmdown`).
    // Empty = no overrides; the progressive-disclosure gate
    // decides for itself. Declared LAST in the property list
    // because Swift's auto-synthesised init enforces declared
    // argument order — `preExpandSetIds: preExpandSetIds`
    // appears at the end of every call site.
    var preExpandSetIds: Set<String> = []

    /// V0.54 S2.1 (2026-09-08): true iff this repGroup belongs to the
    /// currently-active set in the Console's LIVE state. Drives the
    /// elevation container (border + scale + accent bg). False for
    /// PRE / read-only contexts (`currentSetId == nil`).
    private var isCurrent: Bool {
        guard let currentSetId else { return false }
        return rg.setId == currentSetId
    }

    /// V0.54 S2.1 (2026-09-08): true iff this repGroup's reps have
    /// already been timed. Drives the reduced-opacity container so
    /// completed sets recede without collapsing to one-liners.
    /// False for PRE / read-only contexts.
    private var isCompleted: Bool {
        guard let setId = rg.setId else { return false }
        return completedSetIds.contains(setId)
    }

    /// V0.54 S2.1 (2026-09-08): opacity for the repGroup's container.
    /// 1.0 for the current set; 0.35 for completed sets (strongly
    /// dimmed so the user's eye lands on "what's next" without
    /// losing the workout truth); 1.0 for upcoming sets.
    /// The 0.35 value is below Apple's HIG-recommended 50% minimum
    /// for "disabled" surfaces — but we WANT the set to read as
    /// background context, not a disabled control. The text remains
    /// legible for sighted coaches; VoiceOver still reads the
    /// rep-card contents at full prominence regardless.
    private var elevationOpacity: Double {
        if isCurrent { return 1.0 }
        if isCompleted { return 0.35 }
        return 1.0
    }

    // V0.54 S3.3 (2026-09-09, jodie-09 PRE simplification round 2):
    // progressive disclosure gate. True when this set is a low-information
    // bookend (warm-up / warm-down) that warrants collapsing to a single
    // quiet row in the PRE body — coach doesn't need to read it in detail
    // before tapping Start Session. Conservative gate: every condition
    // below must hold, so any set carrying real swim instructions
    // (fragments, gear, dive, suit, descend ladder, per-rep targets,
    // non-easy intensity, rich note) renders the full anatomy.
    //
    // PRE-only (.preview context). LIVE's elevation logic needs every
    // set's full anatomy rendered so the current/completed treatment
    // stays meaningful — collapsing on LIVE would break the elevation
    // pass-through.
    private var isCollapsibleWarmupCooldown: Bool {
        guard context == .preview else { return false }
        guard rg.zoneTerm?.lowercased() == "easy" else { return false }
        let frags = rg.fragments ?? []
        guard frags.isEmpty else { return false }
        let gear = rg.gear ?? []
        guard gear.isEmpty else { return false }
        guard rg.dive != true else { return false }
        guard rg.suit != true else { return false }
        guard (rg.note ?? "").isEmpty else { return false }
        guard rg.descend == nil else { return false }
        guard rg.perRepTargets == nil || rg.perRepTargets?.isEmpty == true else { return false }
        if let intensityType = rg.intensity?.type, intensityType != .easy { return false }
        guard (rg.pattern ?? []).isEmpty else { return false }
        return true
    }

    /// V0.54 S3.3: per-repGroup expansion state for the collapsible
    /// warm-up / warm-down path. Default false (collapsed) so the
    /// first-glance PRE view shows warm-up + warm-down as quiet rows.
    /// Lives on RepGroupRowView so each set owns its own expansion
    /// state — tapping one warm-down doesn't auto-expand the warm-up.
    @State private var expanded: Bool = false

    /// V0.54 S2.1 (2026-09-08): the elevation container for the
    /// currently-active set. Border + scale + accent background so
    /// the coach reads "this is the set on the stopwatch right now"
    /// without scanning. Renders nothing for non-current sets so
    /// PRE / read-only / upcoming sets stay flat.
    @ViewBuilder
    private var elevationBackground: some View {
        if isCurrent {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentAmber.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.accentAmber.opacity(0.5), lineWidth: 1.5)
                )
        }
    }

    var body: some View {
        // V0.54 S3.3 (2026-09-09, jodie-09 PRE simplification round 2):
        // progressive disclosure. When the set qualifies as a low-information
        // bookend (warm-up / warm-down) AND we're in PRE, render a single
        // collapsed row with a chevron. Tapping the row expands it to the
        // full anatomy. The expanded render path is unchanged below — every
        // LVN invariant (zone color carried via text color, gear as symbols,
        // send-off as inline mono, hairline rhythm) still applies once
        // expanded.
        //
        // The collapse branch lives INSIDE this body so elevation, opacity,
        // and the contextMenu ("Remove this set") still wrap the whole
        // repGroup container — the system reports a single accessibility
        // element, the long-press affordance still works on the collapsed
        // row, and the LIVE elevation pass-through stays a no-op (.preview
        // means the collapse predicate already returns false in LIVE).
        //
        // V0.54 S3.3: `.onAppear` seeds `expanded = true` if the
        // parent forwarded this rg.setId in `preExpandSetIds` (the
        // harness's `-v54-s33-expand-warmdown` path). Without the
        // onAppear seed, the @State would default to false and the
        // harness couldn't capture the expanded screenshot. The
        // seed is one-shot per set: `expanded = true` after the
        // initial render, no animation flash (which would also
        // confuse the screenshot timing).
        let seededExpanded = preExpandSetIds.contains(rg.setId ?? "")
        // V0.54 S3.3 harness debug: track each set's setId +
        // pre-expand match in UserDefaults so the post-screenshot
        // dump confirms the seed flow reached the per-set body.
        // Comment-only — UserDefaults writes were removed because
        // they broke SwiftUI's opaque-return-type inference on
        // `var body`. The match itself is verified via the harness
        // state in SessionConsoleView (UserDefaults
        // `v54s33_preExpandSetIds`). Same SwiftUI inference trap
        // the V0.54 S3.1 `showsLadder` gate documented inline.
        return Group {
            if isCollapsibleWarmupCooldown, !expanded, !seededExpanded {
                CollapsibleSetRow(rg: rg) {
                    Haptics.selection()
                    withAnimation(Animations.springSnappy) {
                        expanded = true
                    }
                }
                .opacity(elevationOpacity)
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
            } else {
                expandedSetBody
                    .onAppear {
                        if seededExpanded, !expanded {
                            expanded = true
                        }
                    }
            }
        }
    }

    /// V0.54 S3.3: the full-render body for a repGroup. Extracted from the
    /// `var body` so the collapsible path above can swap in the collapsed
    /// row when appropriate without duplicating the entire render tree.
    /// Behaviour here is unchanged from pre-S3.3 (S3.1–S3.2 invariants
    /// preserved verbatim); the only S3.3 mutations inside are the
    /// chip→typography conversions in each headerLine and the
    /// ProgressionRepCard's percentage chip demotion.
    private var expandedSetBody: some View {
        // V0.54 S2.1 (2026-09-08): the elevation container.
        //
        // ZStack with `elevationBackground` behind so the border + accent
        // background only paint behind the CURRENT set (zero-width when
        // not current). Wrapped in `opacity(elevationOpacity)` so
        // COMPLETED sets recede without collapsing to one-liners (the
        // user's jodie-09 feedback). PRE / read-only contexts have
        // `currentSetId == nil` + empty `completedSetIds`, so both
        // elevationBackground and opacity pass-through — every set
        // renders at full opacity on the flat background, exactly as
        // before.
        ZStack {
            elevationBackground
            VStack(alignment: .leading, spacing: 2) {
            // V0.35 (2026-08-12): when the parser emitted fragments, the
            // flat "4×100m Free" spine is redundant (and misleading — the
            // set is really 4 reps of 75 fast / 25 easy). The fragment
            // rows below carry the full picture; the spine only renders
            // for fragment-less sets.
            //
            // V0.54 S3.1 (2026-09-09, jodie-09 de-busy pass): the
            // spine ALSO has to be suppressed when the dispatched
            // `*RepGroupRow` (Mode 1 .track, Mode 2 multi-fragment
            // .uniform, Mode 3 .progression) renders its OWN
            // headerLine — otherwise the two stack (Set 4 in the
            // jodie-09 screenshot showed the OUTER compact header
            // AND the new Mode 3 header above the four rep cards,
            // violating rule 4 of the dedupe rules). The dispatched
            // rows carry the full set-level context (×N, distance,
            // stroke, zone, send-off, gear, DIVE/SUIT, ladder
            // badge). The OUTER compact header survives ONLY for
            // the Mode 2 single-fragment fallback path
            // (`UniformRepGroupRow` with fragments.count ≤ 1) —
            // where there's no dispatched row to carry the
            // set-level context, so the OUTER header is the
            // canonical render path.
            let mode = repCardMode(for: rg)
            let mode2MultiFragment = mode == .uniform && (rg.fragments?.count ?? 0) > 1
            let mode1Track = mode == .track
            let mode3Progression = mode == .progression
            let dispatchedRendersHeader = mode1Track || mode2MultiFragment || mode3Progression
            if !hasFragments && !dispatchedRendersHeader {
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

                    // V0.54 S3.3 (2026-09-09, jodie-09 PRE round 2):
                    // zone term no longer renders as a chip badge. The
                    // set's zone now expresses via the distance text
                    // color (see `zoneColor(for:)` and the patched
                    // spineText below). The `[Easy]` / `[Steady]` pill
                    // is removed from PRE — every visible chip on the
                    // screen had to go. The OUTER compact header is
                    // only reached in the Mode 2 single-fragment
                    // fallback path today, so the demotion affects
                    // set 3 (the 6×100) the most.

                    if let interval = rg.interval {
                        Text(" on \(interval)")
                            .font(.captionStrong)
                            .foregroundColor(Color.textMuted)
                    }

                    // V0.54 S3 (2026-09-09, jodie-09 dedupe nit): the
                    // "(note)" caption that V0.53.3 added to the header
                    // HStack has been removed. The V0.53.2 below-set
                    // italic caption (line 665 in this file) is the
                    // canonical render path — matching the V0.53.x
                    // builder convention. Keeping the header-side
                    // duplicate produced a double render of
                    // "Each: 50 @ 65% / 70% / 75%" on the 6×100 set
                    // (the user's repro screenshot showed the caption
                    // twice — once beside the spine, once below the
                    // rep cards). The below-set render handles wrap
                    // and italic identically, so the only loss is the
                    // header-side position. Pure visual dedupe — no
                    // data or accessibility impact.

                    // V0.54 S3.3 (2026-09-09, jodie-09 PRE round 2):
                    // gear + DIVE + SUIT badges converted from outlined
                    // boxes to caption-sized SF Symbols at textMuted.
                    // One consistent style across the row — symbol
                    // differentiates, treatment doesn't. The old
                    // `GearBadge` outlined box was the loudest single
                    // contributor of "chip mush"; a single SF Symbol
                    // per gear reads as data, not chrome.
                    ForEach(rg.gear ?? [], id: \.self) { gear in
                        Image(systemName: gearSymbol(for: gear))
                            .font(.caption)
                            .foregroundColor(Color.textMuted)
                    }

                    if rg.dive == true {
                        Image(systemName: "figure.dive")
                            .font(.caption)
                            .foregroundColor(Color.accentAmber)
                    }
                    if rg.suit == true {
                        Image(systemName: "figure.pool.swim")
                            .font(.caption)
                            .foregroundColor(Color.textMuted)
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
            //
            // V0.53.2 (2026-09-08, jodie-09 user complaint): the
            // segment track is a metaphor for "part of this rep
            // is at intensity X then changes to Y". When that
            // metaphor is false, the track lies — and the user
            // sees a slider on a rep that has no actual split.
            // Selection happens at the repGroup level via
            // `repCardMode(for:)` and dispatches to one of three
            // render paths below. Mode 1 (track) keeps the
            // existing Design A (RepCard segment track). Modes
            // 2 (uniform) and 3 (per-rep progression) are new.
            //
            // V0.53.2 dispatch shape: the mode check happens FIRST
            // (outside the fragments guard), because Mode 3 (per-
            // rep progression) frequently fires for fragmentless
            // repGroups — a Descend ladder like "4 × 50 @ 1:00 —
            // Descend: 1=70% 2=75%..." has no per-rep fragments,
            // it has rg.descend + rg.perRepTargets. If we waited
            // for fragments before checking mode, we'd miss every
            // fragmentless Mode 3 case and render the old rg-level
            // row instead.
            //
            // V0.54 S3.1 (2026-09-09, jodie-09 de-busy pass):
            // `mode` and `fragments` were hoisted to the top of
            // this VStack so the OUTER compact-header gate
            // (`dispatchedRendersHeader`, line 437) could read them.
            // Don't re-declare here — Swift will error on the
            // duplicate `let`.
            let fragments = rg.fragments ?? []

            if mode == .track, fragments.count > 1 {
                // Mode 1 (within-rep intensity change) — the
                // connected segment track per rep card.
                PairRepGroupRow(
                    rg: rg,
                    fragments: fragments,
                    reps: rg.reps,
                    // V0.53 (2026-09-08): forward parent distance
                    // + stroke so the header reads "4 × 50m Free"
                    // instead of just "4 ×". Without these, the
                    // 50 (the actual rep distance) gets buried —
                    // coach reads "two 25s" instead of "one 50 as
                    // 25 + 25". Optional; legacy call sites that
                    // don't pass them render as before.
                    parentDistance: rg.distance,
                    parentStroke: rg.stroke,
                    paceTargetText: rg.interval,
                    recordedTimesByFragmentId: recordedTimesByFragmentId,
                    // V0.54 S2.1: forward the context flag so the
                    // composite card's tap gesture + play icon honor
                    // the .preview zero-CTA contract. PRE / read-only
                    // contexts keep their flat behaviour; LIVE
                    // surfaces the play affordance.
                    context: context,
                    onFragmentTap: onFragmentTap.map { handler in
                        { fIdx, f in
                            handler(sectionIndex, namedSetIndex, repGroupIndex, fIdx, f)
                        }
                    },
                    onAggregateChipTap: onAggregateChipTap,
                    note: rg.note
                )
            } else if mode == .progression {
                // Mode 3 (per-rep progression). Fires for both
                // fragmentless repGroups (Descend ladders, build
                // through sets) and multi-fragment repGroups where
                // any fragment carries a progression type. Each
                // card carries its own target; a chevron between
                // cards shows direction. No within-card track.
                ProgressionRepGroupRow(
                    rg: rg,
                    fragments: fragments,
                    reps: rg.reps,
                    parentDistance: rg.distance,
                    parentStroke: rg.stroke,
                    paceTargetText: rg.interval,
                    perRepTargets: perRepTargets(for: rg),
                    recordedTimesByFragmentId: recordedTimesByFragmentId,
                    // V0.54 S2.1: same context forwarding as Mode 1.
                    context: context,
                    onFragmentTap: onFragmentTap.map { handler in
                        { fIdx, f in
                            handler(sectionIndex, namedSetIndex, repGroupIndex, fIdx, f)
                        }
                    },
                    onAggregateChipTap: onAggregateChipTap,
                    note: rg.note
                )
            } else if mode == .uniform, fragments.count > 1 {
                // Mode 2 (uniform) with multi-fragment repGroup
                // where all fragments share one intensity. Plain
                // summary rows + the wrapping note.
                UniformRepGroupRow(
                    rg: rg,
                    fragments: fragments,
                    reps: rg.reps,
                    parentDistance: rg.distance,
                    parentStroke: rg.stroke,
                    paceTargetText: rg.interval,
                    recordedTimesByFragmentId: recordedTimesByFragmentId,
                    // V0.54 S2.1: context forwarding (Mode 2).
                    context: context,
                    onFragmentTap: onFragmentTap.map { handler in
                        { fIdx, f in
                            handler(sectionIndex, namedSetIndex, repGroupIndex, fIdx, f)
                        }
                    },
                    onAggregateChipTap: onAggregateChipTap,
                    note: rg.note
                )
            } else {
                // Mode 2 (uniform) fallback: single fragment (or no
                // fragments at all). Render the existing
                // FragmentCTARow path. showPaceBadge=true (default)
                // because no parent header owns the pace for
                // single-fragment repGroups.
                //
                // When fragments is empty AND the rg has a note
                // (the Descend/Each: case where the parser
                // collapsed the structure into a single rg with
                // a multi-line note), the note IS the
                // progression instruction — but it lives in
                // Mode 2 (no fragments, no progression descriptor
                // detected). Render the existing FragmentCTARow
                // path for the single row + the note below as
                // italic text (the wrap fix from this slice).
                if !fragments.isEmpty {
                    ForEach(Array(fragments.enumerated()), id: \.offset) { fIdx, f in
                        FragmentCTARow(
                            fragment: f,
                            reps: rg.reps,
                            paceTargetText: rg.interval,
                            showPaceBadge: true,
                            recordedTimes: recordedTimesForFragment(f, in: recordedTimesByFragmentId),
                            // V0.54 S2.1: forward context to FragmentCTARow
                            // (Mode 2 fallback). The card already honors
                            // `context != .preview` for the play CTA,
                            // so the explicit forward here closes the
                            // chain — no behaviour drift between the
                            // Mode 1/2/3 paths and the single-fragment
                            // fallback.
                            onTap: onFragmentTap.map { handler in
                                { handler(sectionIndex, namedSetIndex, repGroupIndex, fIdx, f) }
                            },
                            onAggregateTap: { title, records in
                                onAggregateChipTap(title, records)
                            },
                            context: context
                        )
                    }
                }
                // V0.53.2 (2026-09-08, caption-wrap nit): wrap any
                // rg.note on multiple lines so the "Each: 50 @ 65%
                // / 50 @ 70% / 50 @ 75%" and "Descend: 1 = 70% / 2
                // = 75% / 3 = 80% / 4 = ~85%" captions never
                // truncate mid-number. The previous behaviour was
                // single-line truncation with an ellipsis inside
                // the number — the user-reported bug.
                if let note = rg.note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundColor(Color.textMuted)
                        .italic()
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 8)
                        .padding(.top, 2)
                        .accessibilityLabel(note)
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
        // V0.54 S2.1: opacity pass-through. 1.0 for current + upcoming
        // sets, 0.5 for completed sets, 1.0 for the PRE / read-only
        // path (no completed, no current). See `elevationOpacity`.
        .opacity(elevationOpacity)
    }
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
        // V0.54 S2.2 (2026-09-09, jodie-09 Console parse fidelity):
        // .fixedSize(horizontal: true, vertical: false) stops the
        // "Ea…" ellipsization Nathan saw on Sets 1/6 (zone chips
        // Easy/Steady/Hard/Sprint). The badge lives in a parent
        // HStack that competes for horizontal space with the ×N +
        // parent-distance spine + stroke + intensity + interval
        // text; without fixedSize, SwiftUI squeezes the chip first
        // (the shortest non-essential element) and the zone word
        // truncates to two characters. fixedSize claims the full
        // natural width for the chip — siblings compress instead,
        // which is the right trade for a zone marker the coach
        // needs to read at a glance.
        Text(text)
            .font(.numericSmall)
            .foregroundColor(color)
            .fixedSize(horizontal: true, vertical: false)
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

// V0.53.2 (2026-09-08, jodie-09 user complaint on segment track
// rendering on uniform reps): the segment track is a metaphor for
// "part of this rep is at intensity X then changes to Y". Three
// modes — picked per repGroup by `repCardMode(for:)` below.
enum RepCardMode: Equatable {
    // Connected proportional track per rep card. The metaphor is true.
    // (Existing Design A from f4375d6, unchanged.)
    case track
    // Plain row. Single fragment / all-fragments-share-one-intensity
    // AND no progression descriptor. No track, no chevron — one
    // card, distance + instruction + send-off + play.
    case uniform
    // Per-rep progression. Instruction varies ACROSS reps (Descend
    // 1-4, build through, ascend) but the rep itself is uniform.
    // Each card carries its own target; a chevron shows direction.
    case progression
}

/// V0.54 (2026-09-08): the spec's `RepCard.mode` context flag.
/// Three cases — `.preview` (read-only, no play icon), `.live`
/// (Console LIVE state — expanded rep card with stopwatch + rep
/// data), `.finished` (collapsed one-line summary at the top of
/// the LIVE screen for completed reps).
///
/// Named `RepCardContext` (not `RepCardMode`) to avoid collision
/// with the existing V0.53.2 `RepCardMode` above (visual layout:
/// `.track | .uniform | .progression`). The two enums are
/// orthogonal — `context` says where the row lives; `mode` says
/// how the row looks. See the S2 report's "spec deltas".
enum RepCardContext: Equatable {
    case preview
    case live
    case finished
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
    // V0.53.2 (2026-09-08, jodie-09 per-rep progression): explicit
    // per-rep target labels for Mode 3 renders (e.g. ["70%", "75%",
    // "80%", "~85%"] for a `Descend: 1=70% 2=75% 3=80% 4=~85%`
    // ladder). nil = synthesize from rg.descend + intensity percent
    // range, or fall back to chevron-only render. Server contract:
    // decodeIfPresent — old payloads without this field decode clean.
    var perRepTargets: [String]?
    // V0.54 S2.1 (2026-09-08, jodie-09 Console elevation): the parent
    // WorkoutSet.id, used by the Session Console's LIVE state to
    // identify which repGroup is the currently-active set (border +
    // scale + accent bg) and which have already been timed
    // (reduced opacity). Defaults to nil so the field is optional;
    // when nil, the elevation logic falls back to identity-by-index
    // (the order the repGroups appear in `section.namedSets[].repGroups[]`).
    // Not part of the server contract — populated only by the
    // `WorkoutPreviewBuilder.fromWorkoutAndSets` mapping from DB rows.
    var setId: String?

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
        // V0.53.2 (2026-09-08): per-rep progression target labels.
        // Server emits `per_rep_targets` when the parser detected a
        // per-rep ladder (Descend: 1=N% 2=N% ...). nil = synthesize
        // or chevron-only — see perRepTargets(for:) helper.
        case perRepTargets = "per_rep_targets"
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
        perRepTargets = try c.decodeIfPresent([String].self, forKey: .perRepTargets)
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
        zoneTerm: String? = nil,
        perRepTargets: [String]? = nil,
        setId: String? = nil
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
        self.perRepTargets = perRepTargets
        self.setId = setId
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
        try c.encodeIfPresent(perRepTargets, forKey: .perRepTargets)
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
    // V0.53.3 (2026-09-08, jodie-09 display fidelity): the verbatim
    // source-text form of the fragment's distance (e.g. "12.5",
    // "37.5", "25", "100"). The server's normalizeFragmentDistances
    // populates this right before serialization; the int distance is
    // still the wire type (V0.51 — Swift JSONDecoder rejects
    // fractional JSON numbers as DecodingError.dataCorrupted). When
    // set, render surfaces prefer it ("12.5m strong" instead of
    // "13m strong"). nil-tolerant decode (decodeIfPresent) so old
    // servers without the field keep working — the int distance is
    // the fallback. See plans/v0533-fragment-decimal-distance-label-
    // design-spec.md for the design contract.
    let distanceLabel: String?
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
    // V0.53 (2026-09-08, user complaint on jodie-09 purposeful-threshold):
    // seconds of rest AFTER this fragment, before the next fragment in
    // the same composite rep. nil = continuous with the next fragment
    // (no rest between — the 25 + 25 / 50 case). When set, the
    // PairRepGroupRow renders a "+ :NN rest" annotation between
    // fragments so the coach reads "this is one 50 done as 25 + 25"
    // instead of two independent 25m swims. Server contract:
    // parse-workout/index.ts Fragment.restAfter (line 86). Decoded as
    // Int? for forward-compat with any future server shape change.
    let restAfter: Int?

    enum CodingKeys: String, CodingKey {
        case id, distance, stroke, instruction
        case intensity
        case intensityType = "intensity_type"
        case intensityLabel = "intensity_label"
        case startType = "start_type"
        case suit, gear, descriptor, confidence
        case restAfter = "rest_after"
        // V0.53.3 (2026-09-08): optional wire field set by the server
        // right before serialization. Old servers don't emit it; the
        // decodeIfPresent below returns nil and render falls back to
        // the int distance (the V0.51 contract).
        case distanceLabel = "distance_label"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        // ponytail (2026-09-08): defensive decode for fragment.distance.
        // The server may emit fractional meters (12.5, 37.5, 62.5, 87.5)
        // for half-pool fragments parsed from coach input like
        // `4 x 25: 12.5 fast / 12.5 easy`. The server's
        // normalizeFragmentDistances (ios-native/supabase/functions/
        // parse-workout/_decimal-distance-fix.ts) rounds these to the
        // nearest integer before serialization, so on the wire they
        // arrive as Int — but if a stale deploy, a regression in the
        // helper, or a future engine change emits a float first, the
        // original "decodeIfPresent(Int.self)" path threw
        // `DecodingError.dataCorrupted("The given data was not valid
        // JSON.")` — surfacing as "Server parse failed — using
        // on-device fallback. The data couldn't be read because it is
        // in the wrong format." on the coach's screen. Try Double
        // first (handles 12.5), fall back to Int (handles 13), and
        // round to the nearest integer for the projected Int?.
        // See scripts/parser-bench/decimal-distance-fix.test.ts for the
        // contract the server holds.
        distance = decodeFlexibleInt(c, .distance)
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
        // V0.53 (2026-09-08): decode rest_after if the server emits it.
        // Older server versions (pre-restAfter) don't emit this field —
        // decodeIfPresent returns nil, which PairRepGroupRow treats as
        // "continuous" (the conservative default — fragments always
        // belonged to a single rep; restAfter was an additive field).
        restAfter = try c.decodeIfPresent(Int.self, forKey: .restAfter)
        // V0.53.3 (2026-09-08, jodie-09 display fidelity): decode the
        // optional distance_label string the server sets just before
        // serialization. nil-tolerant so old server builds (pre-V0.53.3)
        // decode without crashing — the render surfaces fall back to
        // the int distance in that case.
        distanceLabel = try c.decodeIfPresent(String.self, forKey: .distanceLabel)
    }

    // Memberwise init for in-code construction (#Preview, future test
    // fixtures, the iOS on-device parser when it learns composite shape 12).
    init(
        id: String? = nil,
        distance: Int? = nil,
        // V0.53.3 (2026-09-08): new optional label for display fidelity.
        // Default nil — old call sites and previews that don't pass it
        // get the int-distance fallback in segmentLabel.
        distanceLabel: String? = nil,
        stroke: String? = nil,
        instruction: String? = nil,
        intensity: ParsedIntensity? = nil,
        intensityType: String? = nil,
        intensityLabel: String? = nil,
        startType: String? = nil,
        suit: Bool? = nil,
        gear: [String]? = nil,
        descriptor: String? = nil,
        confidence: Double? = nil,
        restAfter: Int? = nil
    ) {
        self.id = id
        self.distance = distance
        self.distanceLabel = distanceLabel
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
        self.restAfter = restAfter
    }

    // V0.53.3 (2026-09-08, jodie-09 display fidelity): file-scope helper
// for the fragment-distance label chain. Returns the verbatim string
// form when distance_label is set (e.g. "12.5m", "37.5m"), falls back
// to the int distance ("25m", "100m"), and returns an empty string
// when distance is unknown. The empty-string fallback matches the
// prior `if let d = ... { "\(d)m" }` behaviour on nil — every render
// site was already gated on distance, so the empty path is unreachable
// in practice, but the helper keeps the contract explicit.
//
// Render-site usage: every site that previously read `\(d)m` from
// `fragment.distance` now reads `fragmentDistanceText(fragment)`
// instead. The wire type of distance stays Int? (V0.51 contract);
// the label is the display-side fidelity layer.
//
// (defined at file scope, after `struct ParsedFragment`, so all
// callers — both inside ParsedFragment (via `Self.fragmentDistanceText`)
// and outside it (via `fragmentDistanceText(fragment)`) — resolve.)
//
// ponytail (2026-08-04): human-readable summary used by the
    // per-fragment CTA. Format: "<distance> <stroke> <intensity>" with
    // the descriptor verbatim if present. The CTA is the row; tapping
    // it opens the live stopwatch pre-filled with these fields.
    var ctaLabel: String {
        var parts: [String] = []
        // V0.53.3: prefer the verbatim label ("12.5m") over the rounded
        // int ("13m") when present. Falls back to the int when nil —
        // same behaviour as before this change.
        let dist = fragmentDistanceText(self)
        if !dist.isEmpty { parts.append(dist) }
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

// V0.53.3 (2026-09-08, jodie-09 display fidelity): file-scope helper
// for the fragment-distance label chain. Returns the verbatim string
// form when distance_label is set (e.g. "12.5m", "37.5m"), falls back
// to the int distance ("25m", "100m"), and returns an empty string
// when distance is unknown. The empty-string fallback matches the
// prior `if let d = ... { "\(d)m" }` behaviour on nil — every render
// site was already gated on distance, so the empty path is unreachable
// in practice, but the helper keeps the contract explicit.
//
// (Why file-scope, not a ParsedFragment method: when this was declared
// inside `struct ParsedFragment`, Swift treated `func fragmentDistanceText(_:)`
// as an instance method, making the four external render-side call-sites
// (FragmentCTARow, UniformRepCard, ProgressionRepCard, RepCard) fail to
// resolve `fragmentDistanceText(fragment)`. Moving to file scope lets
// both the internal call (from ParsedFragment.ctaLabel) and the four
// external calls reach the helper with a single identifier.)
//
// Render-site usage: every site that previously read `\(d)m` from
// `fragment.distance` now reads `fragmentDistanceText(fragment)`
// instead. The wire type of distance stays Int? (V0.51 contract);
// the label is the display-side fidelity layer.
func fragmentDistanceText(_ fragment: ParsedFragment) -> String {
    if let label = fragment.distanceLabel, !label.isEmpty {
        return "\(label)m"
    }
    if let d = fragment.distance {
        return "\(d)m"
    }
    return ""
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
    // Server contract (V0.47, deployed 2026-08-22): `unmapped_terms`
    // is a STRING ARRAY of lowercased, deduped surface forms — the
    // server returns the term alone, not the row shape with
    // source_line. We bridge here: decode `unmapped_terms` (string
    // array) and map each entry into an UnmappedTerm with the source
    // line left nil. When the server evolves to emit the richer
    // {term, source_line} shape, the alternative CodingKey + nested
    // decode below keeps the iOS side forward-compatible.
    var unmappedTerms: [UnmappedTerm]?

    enum CodingKeys: String, CodingKey {
        case title, sections
        case degraded, degradedReason
        // String-array shape (current server contract, V0.47 live).
        case unmappedTerms = "unmapped_terms"
        // Richer row shape (future server evolution — struct array).
        case unmappedTermsObjects = "unmapped_terms_objects"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        sections = try c.decode([ParsedSection].self, forKey: .sections)
        degraded = try c.decodeIfPresent(Bool.self, forKey: .degraded)
        degradedReason = try c.decodeIfPresent(String.self, forKey: .degradedReason)

        // Prefer the rich row shape if the server ever emits it; fall
        // back to the string-array shape that's live as of V0.47. The
        // string path is the current contract and the iOS derivedTerms
        // fallback is never triggered when this succeeds.
        if let rich = try c.decodeIfPresent([UnmappedTerm].self, forKey: .unmappedTermsObjects) {
            unmappedTerms = rich.isEmpty ? nil : rich
        } else if let terms = try c.decodeIfPresent([String].self, forKey: .unmappedTerms) {
            unmappedTerms = terms.isEmpty
                ? nil
                : terms.map { UnmappedTerm(term: $0, sourceLine: nil) }
        } else {
            unmappedTerms = nil
        }
    }

    // memberwise init kept so #Preview and tests can construct freely
    init(
        title: String? = nil,
        sections: [ParsedSection],
        degraded: Bool? = nil,
        degradedReason: String? = nil,
        unmappedTerms: [UnmappedTerm]? = nil
    ) {
        self.title = title
        self.sections = sections
        self.degraded = degraded
        self.degradedReason = degradedReason
        self.unmappedTerms = unmappedTerms
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encode(sections, forKey: .sections)
        try c.encodeIfPresent(degraded, forKey: .degraded)
        try c.encodeIfPresent(degradedReason, forKey: .degradedReason)
        try c.encodeIfPresent(unmappedTerms, forKey: .unmappedTermsObjects)
    }
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
// V0.53.1 (2026-09-08): file-scope helper for FragmentCTARow's timing
// gate. Returns false when the fragment's intensity is the canonical
// "easy" type (engine maps `easy | recovery | warm-up | ez | relaxed`
// → type:"easy" at _llm.ts:560). nil intensity = assume timable —
// drills, hold rates, and descriptors don't carry an easy type and
// stay timable as before. Mirrors the contract asserted in
// ios-native/Hydrolyze/Tests/V0531CompositeRepLayoutSmoke.swift.
func isTimableFragment(_ fragment: ParsedFragment) -> Bool {
    guard let intensity = fragment.intensity else { return true }
    return intensity.type != .easy
}

// V0.53.1 (2026-09-08): file-scope helper for the per-fragment pace
// badge. When the row lives inside a PairRepGroupRow, the parent header
// already owns the "@ 1:00" send-off, so the per-fragment badge is
// redundant. The composite call site passes `showPaceBadge: false`;
// the single-fragment call site uses the default (true). nil/empty
// `paceTargetText` → no badge even when allowed. Mirrors the contract
// in V0531CompositeRepLayoutSmoke.swift.
func shouldRenderFragmentPaceBadge(showPaceBadge: Bool, paceTargetText: String?) -> Bool {
    guard showPaceBadge else { return false }
    guard let pace = paceTargetText, !pace.isEmpty else { return false }
    return true
}

// V0.53.1 Design A (2026-09-08, jodie-09 approved direction): how
// many rep cards to render for a composite repGroup. 4 reps → 4
// cards (coach's call). 8 reps → 8 cards (cap). 9+ reps → 1 card +
// "×N" repetition affordance — never paginate, never render 0
// cards. nil/0 reps → 1 card (defensive: the fragment list still
// renders as a single rep so the layout doesn't collapse). Mirrors
// the contract in V0531DesignARepCardLayoutSmoke.swift.
func repCardCount(reps: Int?) -> Int {
    guard let reps = reps, reps >= 1 else { return 1 }
    return reps > 8 ? 1 : reps
}

// V0.54 S3.1 (2026-09-09, jodie-09 de-busy pass): the exemplar
// collapse gate. Returns true when every rep in the repGroup is
// identical (same fragments, same send-off) AND the mode is one of
// the two "within-rep variation" modes (Mode 1 .track and Mode 2
// .uniform). Mode 3 (.progression) is excluded because each card has
// a distinct per-rep target — collapsing would hide the build
// sequence that IS the point of Mode 3. Mode 4 (legacy / fallback)
// is also excluded: the single-fragment or no-fragment path renders
// FragmentCTARow per fragment and there's nothing to collapse.
//
// reps == 1 → false (singletons render one card as before — no
// multiplier badge needed).
//
// reps ≥ 2 → true for Mode 1 / Mode 2: collapse to one exemplar card
// with a ×N trailing badge.
//
// The V0.53.1 `repCardCount` cap (reps > 8 → 1 card + ×N) still
// fires for all modes; the S3.1 exemplar collapse is the
// complementary path that fires at 2 ≤ reps ≤ 8 for Mode 1 / Mode 2.
enum ExemplarCollapseMode {
    case track      // Mode 1 (within-rep intensity change)
    case uniform    // Mode 2 (uniform)
    case progression // Mode 3 — never collapses
}

func shouldCollapseToExemplar(reps: Int?, mode: ExemplarCollapseMode) -> Bool {
    guard mode == .track || mode == .uniform else { return false }
    guard let reps = reps, reps >= 2 else { return false }
    return true
}

// V0.53.1 Design A: the proportional width of one segment inside a
// rep card's connected segment track. Returns a 0..1 fraction by
// distance-over-total. nil distance or zero total → 0 (defensive,
// segment renders at zero width and the layout doesn't crash).
// Sum across all fragments in a rep equals 1.0 when every fragment
// has a distance.
func segmentWidth(fragmentDistance: Int?, totalDistance: Int) -> Double {
    guard let d = fragmentDistance, totalDistance > 0 else { return 0 }
    return Double(d) / Double(totalDistance)
}

// V0.53.1 Design A: which fragment the rep-card play button keys
// on, when the card is tapped. nil = the card carries no play button
// at all (all fragments are easy / feel-based — coaches don't time
// those). The handler routes to the same onFragmentTap machinery
// FragmentCTARow uses, keyed on fragment.id, so the eventual capture
// semantics (feet-on-wall per V0.53_SPEC) land on the right fragment.
func tapFragmentIndex(fragments: [ParsedFragment]) -> Int? {
    for (i, f) in fragments.enumerated() {
        if isTimableFragment(f) { return i }
    }
    return nil
}

// V0.53.1 Design A: label rendered inside / under a segment of the
// rep-card track. Mirrors fragmentChipTitle's fallback chain so the
// sighted and screen-reader breakdown reads the same: "{distance}m
// {intensity.label}" → "{distance}m {descriptor}" → "{distance}m
// {instruction}" → "{distance}m" → "Fragment".
//
// V0.53.3 (2026-09-08, jodie-09 display fidelity): the {distance}
// part now comes from fragmentDistanceText, which prefers the
// verbatim source-text label ("12.5") over the rounded int ("13").
// The fallback chain after that is unchanged — same intensity label,
// descriptor, instruction.
func segmentLabel(fragment: ParsedFragment) -> String {
    var parts: [String] = []
    let dist = fragmentDistanceText(fragment)
    if !dist.isEmpty { parts.append(dist) }
    // V0.54 S2.2 (2026-09-09, jodie-09 Console parse fidelity):
    // prefer the coach's verbatim intensity word ("race rhythm",
    // "easy", "strong") carried in `intensityLabel` over the parser
    // type token ("race_pace") carried in `intensity.label`. The
    // V0.53.1 contract hard-coded the type-token path; the new
    // WorkoutSetFragment.intensityLabel field plumbs the verbatim
    // word through WorkoutPreviewBuilder and onto every
    // ParsedFragment. Render surfaces must read it first so the
    // coach sees their own language, not parser internals.
    if let verbatim = fragment.intensityLabel, !verbatim.isEmpty {
        return parts.joined(separator: " ") + " " + verbatim
    }
    if let label = fragment.intensity?.label, !label.isEmpty {
        return parts.joined(separator: " ") + " " + label
    }
    if let desc = fragment.descriptor, !desc.isEmpty {
        return parts.joined(separator: " ") + " " + desc
    }
    if let instr = fragment.instruction, !instr.isEmpty {
        return parts.joined(separator: " ") + " " + instr
    }
    if !parts.isEmpty { return parts.joined(separator: " ") }
    return "Fragment"
}

// V0.53.1 Design A: VoiceOver label for one rep card. One element
// per card so screen-reader navigation lands on whole reps, not
// individual segments. Includes reps context ("Rep 1 of 4"), the
// rep's distance, the segment breakdown ("25 event rhythm then 25
// easy"), and the interval ("on 1:00") when present. Distinct for
// each rep in the set so VoiceOver never collapses identical cards
// into a single node.
func cardAccessibilityLabel(
    repNumber: Int,
    totalReps: Int,
    parentDistance: Int?,
    segments: [ParsedFragment],
    interval: String?
) -> String {
    var parts: [String] = []
    parts.append("Rep \(repNumber) of \(totalReps)")
    if let d = parentDistance {
        parts.append("\(d) meters")
    }
    let breakdown = segments.map { segmentLabel(fragment: $0) }.joined(separator: " then ")
    if !breakdown.isEmpty {
        parts.append(breakdown)
    }
    if let interval = interval, !interval.isEmpty {
        parts.append("on \(interval)")
    }
    return parts.joined(separator: ", ")
}

// V0.53.2 (2026-09-08, jodie-09 user complaint): the segment track
// is a metaphor for "part of this rep is at intensity X then changes
// to Y". When that metaphor is false — when the rep is uniform, or
// when the instruction varies ACROSS reps instead of WITHIN — the
// track would lie about the structure. Three modes, picked per
// repGroup:
//
//   .track        — Mode 1. Within-rep intensity change. Connected
//                   segment track per rep card. The metaphor is true.
//                   (Existing Design A from f4375d6, unchanged.)
//
//   .uniform      — Mode 2. Plain row. Single fragment, or all
//                   fragments share one intensity, AND no progression
//                   descriptor. The rep is one swim at one descriptor;
//                   a track would falsely imply an intensity split.
//
//   .progression  — Mode 3. Per-rep progression. The instruction
//                   varies across reps (Descend 1-4, build through,
//                   ascend) but the rep itself is uniform. Each card
//                   carries its own target; a chevron shows direction.
//                   No within-card track.
//
// Selection rule, in order:
//
//   1. If rg has ≥2 fragments with ≥2 distinct intensity types →
//      .track. This is the canonical within-rep split.
//
//   2. Else if any of these is true:
//        rg.descend != nil
//        rg.pacing == "build"
//        rg.intensity.type == "descend"
//        rg.zoneTerm == "descend"
//        any fragment.intensity.type == "descend" or "build"
//      → .progression. The instruction varies across reps.
//
//   3. Else → .uniform. Single fragment with no progression, or
//      all-fragments-share-one-intensity, or no fragments at all.
//
// "Progression wins over track": when both apply (rare but possible —
// e.g. a 2-fragment composite where one fragment has pacing "build"),
// the coach's instruction is the progression, not the split. Rule 2
// fires AFTER rule 1's check, so the more-specific intent wins.
//
// Progression-term detection reuses the canonical intensity taxonomy
// the parser uses — `descend` / `build` / `ascend` are server-side
// IntensityType values, not invented here. nil intensity = no
// progression term detected (drills, descriptors, hold rates carry
// no progression type and stay timable).
func repCardMode(for rg: ParsedRepGroup) -> RepCardMode {
    let fragments = rg.fragments ?? []

    // Count distinct intensity types among the fragments. nil
    // intensity fragments don't contribute a type (drills,
    // descriptors, hold rates).
    let distinctIntensityTypes: Set<String> = Set(
        fragments.compactMap { $0.intensity?.type.rawValue }
    )

    // Rule 1: within-rep intensity change.
    if fragments.count >= 2, distinctIntensityTypes.count >= 2 {
        return .track
    }

    // Rule 2: progression descriptor anywhere.
    let rgHasProgression =
        rg.descend != nil ||
        rg.pacing == "build" ||
        rg.intensity?.type == .descend ||
        rg.zoneTerm == "descend"
    // Fragment-level progression: only via intensity type, since
    // ParsedFragment doesn't carry a pacing field (per-fragment
    // pacing is rare in practice — the parser emits "build" as a
    // rg-level pacing, not per-fragment). V0.53.2 narrows to the
    // intensity.type check for the same reason.
    let anyFragmentIsProgression = fragments.contains { f in
        f.intensity?.type == .descend || f.intensity?.type == .build
    }
    if rgHasProgression || anyFragmentIsProgression {
        return .progression
    }

    // Rule 3: uniform.
    return .uniform
}

// V0.53.2: target labels for per-rep progression. Two sources:
//
//   - perRepTargets on the rg (preferred). When the parser / harness
//     supplies explicit per-rep targets like ["70%", "75%", "80%",
//     "~85%"], those flow straight into each card. nil → fall back
//     to chevron-only progression.
//
//   - synthesized from rg.descend + rg.intensity's percent range.
//     When the rg has a descend ladder ("1-4") and a percent-range
//     intensity (low..high), interpolate evenly. The harness can
//     override with perRepTargets when the interpolation wouldn't
//     match the coach's intent (e.g. "Descend: 1=70 2=75 3=80 4=~85"
//     where the last step is ~, not linear).
//
// Returns one target string per rep, in rep order (rep 1 first). The
// caller is responsible for capping to repCardCount(reps) — beyond
// 8 reps, the render collapses to one card with ×N and we
// the per-rep labels. nil = no per-rep targets (chevron-only render).
func perRepTargets(for rg: ParsedRepGroup) -> [String]? {
    // Preferred: explicit per-rep targets from the parser / harness.
    if let explicit = rg.perRepTargets, !explicit.isEmpty {
        return explicit
    }

    // Synthesized: descend ladder + percent range intensity.
    // Parse the rg.descend range like "1-4" → [1, 4]. With a percent
    // intensity of percentLow..percentHigh, interpolate N evenly-
    // spaced targets (N = reps). Only meaningful for percent_range
    // intensities; other intensity types return nil (chevron only).
    guard let descend = rg.descend, let reps = rg.reps, reps >= 2 else {
        return nil
    }
    guard let intensity = rg.intensity,
          intensity.type == .percent_range,
          let low = intensity.percentLow,
          let high = intensity.percentHigh else {
        return nil
    }
    guard let (start, end) = parseDescendRange(descend),
          start >= 1, end >= start else {
        return nil
    }
    let span = end - start
    guard span + 1 == reps else {
        // Mismatch (e.g. "1-4" on a 6×50) — bail. The harness covers
        // the matching case; mismatches get chevron-only.
        return nil
    }
    let percentSpan = high - low
    var result: [String] = []
    for i in 0..<reps {
        let pct = low + (percentSpan * i / max(reps - 1, 1))
        result.append("\(pct)%")
    }
    return result
}

// V0.53.2: parse "1-4" / "1–4" / "1 to 4" → (1, 4). nil on failure.
// Used by perRepTargets above for descend-ladder interpolation.
func parseDescendRange(_ raw: String) -> (Int, Int)? {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    let separators = ["–", "-", " to "]
    for sep in separators {
        let parts = trimmed.components(separatedBy: sep)
        if parts.count == 2,
           let lo = Int(parts[0].trimmingCharacters(in: .whitespaces)),
           let hi = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
            return (lo, hi)
        }
    }
    return nil
}

// V0.54 S3.3 (2026-09-09, jodie-09 PRE simplification round 2):
// zone color mapping. Replaces the old zone-chip badge — the set's
// governing zone (easy / steady / hard / sprint) is now expressed
// via the leading distance text's color instead of an outlined
// "Easy"/"Steady" pill. Easy keeps the muted primary text — adding
// a tint would create the loudness the simplification removes.
// Steady/Hard escalate through amber (warming effort); Sprint hits
// coral (peak intensity — matches accentAction semantics elsewhere).
//
// Caller passes the rg's zoneTerm string (the canonical zone word
// from the parser, lowercased). Unknown / nil values fall back to
// textPrimary — same neutral the distance text already wears, so
// nil zones behave as before.
func zoneColor(for zoneTerm: String?) -> Color {
    switch zoneTerm?.lowercased() {
    case "easy": return Color.textPrimary
    case "steady": return Color.accentAmber.opacity(0.85)
    case "hard": return Color.accentAmber
    case "sprint": return Color.accentAction
    default: return Color.textPrimary
    }
}

// V0.54 S3.3: SF Symbol mapping for set-level gear / start / suit
// signals. Replaces the old MetadataBadge + GearBadge outlined boxes
// with caption-sized symbols at textMuted. One style (caption + muted
// color) for visual consistency — the only differentiation is the
// symbol itself, not its treatment.
//
// `pull` → `hand.raised.fill` (closest SF Symbol proxy for the
// "paddles on hands" affordance; a dedicated paddles symbol doesn't
// exist in SF Symbols).
// `kick` → `figure.kickboxing` (the only SF Symbol with a kicking
// silhouette — close enough to a kickboard leg pattern).
// `drill` → `figure.run` (the generic motion symbol; drill sets
// usually carry a pattern descriptor that the row's note already
// names, so the symbol is the secondary signal).
// `dive` → `figure.dive` (iOS 16+, semantically exact — a diving
// silhouette).
// `suit` → `figure.pool.swim` (the wetsuit-clad swim silhouette;
// matches the parser's "wearing a wetsuit" semantic for set.suit).
//
// Unknown gear strings fall back to `circle.fill` so the row still
// carries a marker (better than dropping the gear entirely and
// silently losing the coach's instruction).
func gearSymbol(for gear: String) -> String {
    switch gear.lowercased() {
    case "pull": return "hand.raised.fill"
    case "kick": return "figure.kickboxing"
    case "drill": return "figure.run"
    case "paddles": return "hand.raised.fill"
    default: return "circle.fill"
    }
}

/// V0.54 S3.3 (2026-09-09, jodie-09 PRE simplification round 2):
/// progressive disclosure — the collapsed warm-up / warm-down row.
/// Renders one quiet HStack: "reps × distance Free" (zone-colored)
/// + Spacer + chevron. Tap fires the `onExpand` closure so the
/// parent RepGroupRowView can flip its `expanded` state and render
/// the full anatomy.
///
/// Visual rhythm matches the S3.3 hairline system: 12pt vertical
/// padding (same as intra-set spacing), no card chrome, no chip
/// outlines. The chevron rotates 90° on tap via the parent's
/// `withAnimation` — the rotation is the single visual signal that
/// the row "opened."
///
/// Accessibility: the row reports as a single button with a label
/// that names the set ("1 × 400 meters Free warm-up, tap to expand").
/// VoiceOver users get the same expand-on-tap affordance as sighted
/// coaches. The `accessibilityHint` explicitly names the action so
/// the user knows what tapping does.
private struct CollapsibleSetRow: View {
    let rg: ParsedRepGroup
    let onExpand: () -> Void

    var body: some View {
        Button(action: onExpand) {
            HStack(spacing: 8) {
                // "1 × 400" — distance colored by the zone, so the
                // warm-up's "easy" reads through the text color
                // instead of the old [Easy] chip.
                if let reps = rg.reps, reps > 1 {
                    Text("\(reps)×")
                        .font(.numeric)
                        .foregroundColor(Color.textPrimary.opacity(0.85))
                }
                if let distance = rg.distance {
                    Text("\(distance)m")
                        .font(.numeric)
                        .foregroundColor(zoneColor(for: rg.zoneTerm))
                }
                if let stroke = rg.stroke, !stroke.isEmpty {
                    Text(stroke)
                        .font(.body)
                        .foregroundColor(Color.textPrimary)
                }
                Spacer()
                // Chevron — SF Symbol, caption size, muted. The
                // 90° rotation is driven by the parent's
                // withAnimation when expanded toggles; this view
                // doesn't track its own rotation state to avoid
                // duplicating the bool.
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(Color.textFaint)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(collapsedAccessibilityLabel)
        .accessibilityHint("Tap to expand")
        .accessibilityAddTraits(.isButton)
    }

    /// VoiceOver label: the set's full readable description in one
    /// breath. Mirrors the verbalisation the expanded header would
    /// render so the collapsed state loses no information for
    /// screen-reader users — just visible chrome.
    private var collapsedAccessibilityLabel: String {
        var parts: [String] = []
        if let reps = rg.reps, reps > 1 {
            parts.append("\(reps) times")
        }
        if let distance = rg.distance {
            parts.append("\(distance) meters")
        }
        if let stroke = rg.stroke, !stroke.isEmpty {
            parts.append(stroke)
        }
        if let zone = rg.zoneTerm, !zone.isEmpty {
            parts.append(zone)
        }
        return parts.joined(separator: " ")
    }
}

private struct FragmentCTARow: View {
    let fragment: ParsedFragment
    let reps: Int?
    let paceTargetText: String?
    // V0.53.1 (2026-09-08, jodie-09 purposeful-threshold): false when
    // the row is a child of PairRepGroupRow — the parent header owns
    // the @-send-off badge, so the per-fragment copy is redundant.
    // Default true preserves the single-fragment call site at
    // RepGroupRowView (line 401) where the row IS the only place the
    // interval appears.
    var showPaceBadge: Bool = true
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
    /// V0.54 (2026-09-08): context flag (spec §4, decision 9).
    /// `.preview` is the read-only context — WorkoutDetailView's
    /// post-session review, the builder preview, the TodayView
    /// card; no play icon, no timing affordance. `.live` is the
    /// V0.54 SessionConsoleView's LIVE state — the rep card
    /// expands with the stopwatch + rep data. `.finished` is the
    /// collapsed one-line summary at the top of the LIVE screen
    /// (completed reps).
    ///
    /// Default `.preview` matches the V0.53 zero-CTA contract for
    /// WorkoutPreview — pre-V0.54 call sites keep the existing
    /// zero-CTA behaviour without opt-in. The Console's LIVE body
    /// (S2) and any future surface that opts into the new mode
    /// flag will pass `.live` or `.finished` explicitly.
    ///
    /// NOTE: this is `RepCardContext` (a NEW V0.54 enum), NOT the
    /// existing V0.53.2 `RepCardMode` at line 809 (`.track |
    /// .uniform | .progression`, a visual-layout choice that's
    /// orthogonal to this context flag). The spec's
    /// `RepCard.mode: RepCardMode` text was a slight collision with
    /// the existing name; the S2 additive change uses
    /// `RepCardContext` to avoid that collision. See the report's
    /// "spec deltas" section.
    var context: RepCardContext = .preview

    // V0.53.1: true unless the fragment's intensity is the canonical
    // "easy" type. Easy fragments are feel-based — coaches don't time
    // them. Suppresses the play button + Button wrap; recorded-time
    // chips still render so previously-captured times stay visible.
    private var isTimable: Bool { isTimableFragment(fragment) }

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
                    // V0.53.3 (2026-09-08, jodie-09 display fidelity):
                    // prefer the verbatim label ("12.5m") over the
                    // rounded int ("13m"). Falls back to the int when
                    // nil — same visible behaviour as before.
                    let dist = fragmentDistanceText(fragment)
                    if !dist.isEmpty {
                        Text(dist)
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
                    // V0.53.1 (2026-09-08, jodie-09 send-off-belong-to-rep):
                    // suppress the per-fragment "@ 1:00" badge when the
                    // row lives inside a PairRepGroupRow — the parent
                    // header already owns the send-off so the child copy
                    // is redundant. Single-fragment call sites (no parent
                    // header) keep `showPaceBadge=true` (default) so the
                    // interval appears once on the row.
                    if shouldRenderFragmentPaceBadge(showPaceBadge: showPaceBadge, paceTargetText: paceTargetText),
                       let pace = paceTargetText {
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
            //
            // V0.53.1 (2026-09-08, jodie-09 no-time-on-easy):
            // suppress the play/retap icon entirely when the fragment
            // is easy (feel-based; coaches don't time it). The row
            // becomes passive description only — no timing CTA,
            // no Button wrap below. Recorded-time chips above still
            // render so any previously-captured times remain visible
            // as a read-only history signal.
            if onTap != nil, isTimable, context != .preview {
                Image(systemName: recordedTimes != nil ? "arrow.counterclockwise.circle" : "play.circle.fill")
                    .foregroundColor(recordedTimes != nil ? Color.textMuted : Color.textPrimary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(Color.bgBase.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 4))

        // V0.53.1: easy fragments are not tappable (no Button wrap).
        // When onTap is nil OR isTimable is false, render the static
        // content. The previous code wrapped unconditionally on onTap,
        // which would still launch timing for easy fragments even
        // though no play icon shows — breaking the "passive description"
        // guarantee.
        //
        // V0.54 (2026-09-08): add `mode != .preview` to the gate so the
        // V0.54 spec §4 / decision 9 zero-CTA-in-preview contract
        // holds even when the parent view wires an `onTap` (the
        // WorkoutDetailView review path passes `onFragmentTap`; in
        // `.preview` mode we want the row static). This is additive —
        // pre-V0.54 call sites default to `.preview` and keep the
        // existing behaviour.
        if let onTap, isTimable, context != .preview {
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
        // V0.53.3 (2026-09-08, jodie-09 display fidelity): prefer the
        // verbatim source-text label over the rounded int. Same call
        // site as segmentLabel — both feed the same fallback chain
        // for sighted + VoiceOver consistency.
        let dist = fragmentDistanceText(fragment)
        if !dist.isEmpty { parts.append(dist) }
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
// V0.53 (2026-09-08, jodie-09 purposeful-threshold complaint):
// PairRepGroupRow now surfaces the parent rep distance + composite
// breakdown so a coach reading `4 × 50 @ 1:00 — 25 event rhythm / 25
// easy` sees the 50 FIRST, with the two 25s described as "each as:
// 25 event rhythm + 25 easy — continuous". The previous render
// buried the 50 (only showed `4×`) and the "2 fragments per rep"
// caption read as jargon; a swimmer/parent read it as two
// independent 25m swims. When the parser emits rest_after between
// fragments, the breakdown renders "+ :15 rest" between the parts so
// the coach sees "with rest between" vs "continuous".
private struct PairRepGroupRow: View {
    // V0.53.2 (2026-09-08): forward the full rg so the body can
    // detect mode + use the rg's perRepTargets / descend / pacing /
    // zoneTerm. Optional so legacy call sites that don't pass it
    // degrade gracefully (mode falls back to .track).
    let rg: ParsedRepGroup?
    let fragments: [ParsedFragment]
    let reps: Int?
    // V0.53: parent rep group's distance + stroke, so the header
    // shows "4 × 50m" instead of just "4 ×". Optional so legacy
    // call sites that don't pass it degrade gracefully.
    let parentDistance: Int?
    let parentStroke: String?
    let paceTargetText: String?
    let recordedTimesByFragmentId: [String: [FragmentTimeRecord]]?
    // V0.54 S2.1 (2026-09-08): the console context flag.
    // .preview hides the play icon + tap gesture on every
    // composite card (zero-CTA invariant); .live/.finished
    // surface them. Default .preview keeps pre-V0.54 call
    // sites rendering flat.
    var context: RepCardContext = .preview
    // V0.35 (2026-08-12): nil = static rows (builder preview).
    let onFragmentTap: ((Int, ParsedFragment) -> Void)?
    // V0.48 Slice 2 (2026-08-22): forwarded to each FragmentCTARow so
    // every inner fragment can present its own aggregate sheet. The
    // shared callback ensures only one sheet is presented at a time
    // (WorkoutPreview owns the state slot).
    let onAggregateChipTap: (String, [FragmentTimeRecord]) -> Void
    // V0.53.2 (2026-09-08, caption-wrap nit): the rg's `note` field
    // (e.g. "Each: 50 @ 65% / 50 @ 70% / 50 @ 75%") when present.
    // For Mode 1 (track) we render it BELOW the rep cards so the
    // coach reads the wrap-around instruction that the track alone
    // can't carry. Wraps multi-line — never truncates mid-number.
    // For Modes 2 (uniform) and 3 (progression), the note is also
    // surfaced by their dedicated rows. nil = no note to render.
    let note: String?

    var body: some View {
        // V0.53.1 Design A (2026-09-08, jodie-09 approved direction):
        // the composite repGroup renders as N rep cards (N = reps,
        // capped at 8 — beyond that one card + "×N" affordance). Each
        // card is one swim; inside the card the segments are a single
        // connected track — no dividers/borders, shared rounded
        // background, proportional widths. The send-off lives at the
        // card's trailing edge; the play affordance is the card itself,
        // never the segments. Easy segments render muted and carry no
        // tap affordance of their own. The header above (×N + parent
        // distance) stays as the parent context; the per-rep breakdown
        // is now visually inherent in the segment track, so the old
        // "each as: 25 + 25 — continuous" caption is GONE — that's
        // the show-not-tell fix the user asked for.
        //
        // V0.54 S3.1 (2026-09-09, jodie-09 de-busy pass): identical
        // reps collapse to ONE exemplar card with a "×N" badge.
        // Rule 1 of the dedupe rules: when every rep is identical
        // (same fragments, same send-off), render one card with the
        // ×N multiplier. Within a single repGroup the fragments list
        // is the same across all reps by construction — the per-rep
        // variation lives ONLY in Mode 3 (`perRepTargets`). So for
        // Mode 1 (.track) and Mode 2 (.uniform) the exemplar collapse
        // is unconditional. Mode 3 stays expanded because each card's
        // target differs. For reps == 1 (singletons like 400 free
        // warm-up) no collapse — single card as before.
        VStack(alignment: .leading, spacing: 6) {
            if reps != nil || fragments.count > 1 {
                headerLine
            }
            // Design A: rep cards. For reps ≤ 8 AND identical reps
            // (Mode 1/2): render ONE exemplar card with ×N badge.
            // For 9+ reps: 1 card + "×N" affordance (V0.53.1 cap).
            // For reps == 1: single card as before.
            //
            // V0.54 S3.1: the exemplar path forwards the rg so the
            // header can carry gear / zone / dive / suit (set-level
            // context that used to repeat per card). The single
            // RepCard no longer needs the send-off badge (it's in the
            // header), the gear badges (also in the header), or the
            // gear-trail — all "say it once at the set header" per
            // rule 2.
            let isExemplar = shouldCollapseToExemplar(reps: reps, mode: .track)
            if isExemplar, let reps = reps {
                RepCard(
                    repNumber: 1,
                    totalReps: reps,
                    parentDistance: parentDistance,
                    fragments: fragments,
                    // V0.54 S3.1: pass nil send-off on the exemplar
                    // card — the set-level headerLine already shows
                    // @ pace. Per rule 2, the send-off lives ONCE.
                    paceTargetText: nil,
                    recordedTimes: recordedTimesForFragment(
                        fragments[tapFragmentIndex(fragments: fragments) ?? 0],
                        in: recordedTimesByFragmentId
                    ),
                    // V0.54 S3.1: no per-card tap on exemplar — the
                    // LIVE state (where the stopwatch is the primary
                    // CTA) keys on the stopwatch, not the exemplar
                    // card. PRE's zero-CTA invariant already prevents
                    // the play icon from rendering; the onFragmentTap
                    // route stays wired so the LIVE elevation surfaces
                    // the stopwatch surface when needed.
                    onTap: makeCardTapHandler(repIdx: 0),
                    context: context,
                    onAggregateTap: { title, records in
                        onAggregateChipTap(title, records)
                    }
                )
                // ×N badge trailing the exemplar. Same amber tint
                // the ×N prefix uses elsewhere — visual continuity
                // with the header's leading ×N. The coach reads "1
                // card + ×4" and knows: one swim shown, four in the
                // set, all identical.
                Text("× \(reps)")
                    .font(.numeric)
                    .foregroundColor(Color.accentAmber)
                    .padding(.leading, 4)
                    .accessibilityLabel("\(reps) identical reps")
            } else {
                // Non-exemplar path (legacy): 4 cards for a 4-rep set
                // when reps differ per-card (today only Mode 3 fires
                // this). Mode 1/2 with reps == 1 also hit this path.
                let count = repCardCount(reps: reps)
                let isCollapsed = count == 1 && (reps ?? 1) > 1
                ForEach(0..<count, id: \.self) { repIdx in
                    let repNumber = repIdx + 1
                    RepCard(
                        repNumber: repNumber,
                        totalReps: reps ?? 1,
                        parentDistance: parentDistance,
                        fragments: fragments,
                        paceTargetText: paceTargetText,
                        recordedTimes: recordedTimesForFragment(
                            fragments[tapFragmentIndex(fragments: fragments) ?? 0],
                            in: recordedTimesByFragmentId
                        ),
                        onTap: makeCardTapHandler(repIdx: repIdx),
                        context: context,
                        onAggregateTap: { title, records in
                            onAggregateChipTap(title, records)
                        }
                    )
                }
                if isCollapsed, let reps = reps {
                    Text("× \(reps)")
                        .font(.numeric)
                        .foregroundColor(Color.accentAmber)
                        .padding(.leading, 4)
                        .accessibilityLabel("\(reps) reps")
                }
            }
            // V0.53.2 (2026-09-08, caption-wrap nit): the rg's `note`
            // (e.g. "Each: 50 @ 65% / 50 @ 70% / 50 @ 75%") — when
            // present — renders BELOW the rep cards so the coach
            // reads the wrap-around instruction that the track alone
            // doesn't carry. Wraps multi-line via .lineLimit(nil) +
            // fixedSize(horizontal:false, vertical:true) so a long
            // caption like the Descend ladder ("Descend: 1 = 70% / 2
            // = 75% / 3 = 80% / 4 = ~85%") never truncates mid-number.
            // For Mode 1 (track), the track itself shows the rep's
            // internal split; this note carries the ACROSS-rep
            // progression instruction that the track can't show.
            if let note = note, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundColor(Color.textMuted)
                    .italic()
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 8)
                    .padding(.top, 2)
                    .accessibilityLabel(note)
            }
        }
    }

    // V0.53.1 Design A: card-level tap handler. When the rep card is
    // tapped, route to onFragmentTap using the timable fragment's
    // index. nil when no fragment is timable (no handler fires — the
    // card is passive description only, mirroring the V0.53.1 easy
    // gating but at the card level).
    //
    // repIdx parameter is reserved for future per-rep distinct
    // behaviour; today every rep in the set keys on the same
    // timable fragment index (the first timable one in the
    // composite). The V0.53.1 captured-time machinery records per
    // fragment.id, so the eventual "rep 2 time was X" view reads
    // correctly when the recorded times land on the right id.
    private func makeCardTapHandler(repIdx: Int) -> (() -> Void)? {
        guard let onFragmentTap = onFragmentTap else { return nil }
        guard let fIdx = tapFragmentIndex(fragments: fragments) else { return nil }
        let fragment = fragments[fIdx]
        return { onFragmentTap(fIdx, fragment) }
    }

    // V0.53: header line. Always shows "4 × 50m [Stroke]".
    //
    // V0.53.1 Design A (2026-09-08, jodie-09 approved direction):
    // the send-off no longer lives here — it has moved to the
    // trailing edge of each rep card (RepCard.swift). And the
    // per-rep "each as: 25 + 25 — continuous" caption is GONE —
    // the segment track inside each card carries that information
    // visually. Header is now just ×N + parent distance + stroke —
    // the parent context for the rep cards below. This is the
    // show-not-tell fix the user asked for in jodie-09.
    //
    // V0.54 S3.1 (2026-09-09, jodie-09 de-busy pass): the header
    // now carries the FULL set-level context — ×N, parent
    // distance, stroke, zone chip, send-off, gear, dive/suit
    // badges. Rule 2 of the dedupe rules: stroke, gear, zone
    // chip, send-off belong to the SET header, not the per-card
    // chrome. The exemplar card (Mode 1/2 collapsed path) drops
    // the per-card send-off because it now lives here once.
    //
    // Rule 3 (range OR ladder, never both) is enforced inside
    // the `showsLadder` gate: when `rg?.perRepTargets` is
    // populated we suppress the intensity-range text and the
    // zone chip — the ladder card-implies both. Today only Mode
    // 3 (ProgressionRepGroupRow) has a populated perRepTargets,
    // so the gate is a no-op here; the Mode 3 row's own
    // headerLine enforces the same rule for its header.
    private var headerLine: some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(Color.accentAmber)
                .frame(width: 2, height: 14)
            if let reps = reps, reps > 1 {
                Text("\(reps)×")
                    .font(.numeric)
                    .foregroundColor(Color.accentAmber)
            }
            // V0.54 S3.3 (2026-09-09, jodie-09 PRE round 2):
            // parent distance wears the zone color. The set's
            // governing zone (easy / steady / hard / sprint)
            // now expresses via this Text's color instead of
            // the removed [Easy] / [Steady] / [Hard] chip.
            // PairRepGroupRow's rg is optional — `rg?.zoneTerm`
            // returns nil for legacy callers, which falls
            // through `zoneColor(for:)` to the textPrimary
            // default (same as pre-S3.3).
            if let d = parentDistance {
                Text("\(d)m")
                    .font(.numeric)
                    .foregroundColor(zoneColor(for: rg?.zoneTerm))
            }
            if let s = parentStroke, !s.isEmpty {
                Text(s)
                    .font(.body)
                    .foregroundColor(Color.textPrimary)
            }
            // V0.54 S3.1 (rule 2): send-off belongs to the SET
            // header, not the per-card chrome. Rendered here
            // exactly once for the whole set. Mode 1 / Mode 2
            // exemplar cards pass paceTargetText: nil so the
            // card itself doesn't double-render it.
            if let pace = paceTargetText, !pace.isEmpty {
                Text("on \(pace)")
                    .font(.captionStrong)
                    .foregroundColor(Color.textMuted)
            }
            // V0.54 S3.3 (2026-09-09, jodie-09 PRE round 2): gear +
            // DIVE + SUIT converted from outlined chips to caption-
            // sized SF Symbols at textMuted. One style — symbol
            // differentiates, treatment doesn't.
            ForEach(rg?.gear ?? [], id: \.self) { gear in
                Image(systemName: gearSymbol(for: gear))
                    .font(.caption)
                    .foregroundColor(Color.textMuted)
            }
            if rg?.dive == true {
                Image(systemName: "figure.dive")
                    .font(.caption)
                    .foregroundColor(Color.accentAmber)
            }
            if rg?.suit == true {
                Image(systemName: "figure.pool.swim")
                    .font(.caption)
                    .foregroundColor(Color.textMuted)
            }
        }
        .padding(.leading, 2)
    }

    // V0.53.1 Design A: the "each as: 25 + 25 — continuous" text
    // caption and its accessibility twin were removed when Design A
    // landed. The show-not-tell segment track inside each RepCard
    // carries the breakdown visually — no text caption needed. The
    // helpers above (segmentLabel / cardAccessibilityLabel) build
    // the same breakdown for VoiceOver.
}

// V0.53.2 (2026-09-08, jodie-09 user complaint): Mode 2 (uniform)
// render path. Used when the segment track would lie — a single
// fragment, or all fragments sharing one intensity, AND no
// progression descriptor. The rep is one swim at one descriptor;
// a track would falsely imply an intensity split.
//
// Visual: one summary row per rep (or one row per rep when
// fragments.count > 1 and all fragments share one intensity),
// carrying ×N + parent distance + stroke + send-off + a chevron/
// arrow only if per-rep targets are present (uniform cases
// usually don't have per-rep targets, so no chevron). The rep
// card is a flat row — no track, no internal divisions.
//
// The single tap target per rep card keys on the timable fragment
// (same rule as RepCard); when ALL fragments are easy, the card
// carries no play affordance and is passive description only
// (mirrors the V0.53.1 easy gating).
private struct UniformRepGroupRow: View {
    let rg: ParsedRepGroup
    let fragments: [ParsedFragment]
    let reps: Int?
    let parentDistance: Int?
    let parentStroke: String?
    let paceTargetText: String?
    let recordedTimesByFragmentId: [String: [FragmentTimeRecord]]?
    // V0.54 S2.1 (2026-09-08): context flag forwarded to
    // UniformRepCard. Same .preview/.live contract as PairRepGroupRow.
    var context: RepCardContext = .preview
    let onFragmentTap: ((Int, ParsedFragment) -> Void)?
    let onAggregateChipTap: (String, [FragmentTimeRecord]) -> Void
    let note: String?

    var body: some View {
        // V0.54 S3.1 (2026-09-09, jodie-09 de-busy pass): identical
        // reps collapse to ONE exemplar card with a "×N" badge.
        // Mode 2 (.uniform) shares the rule with Mode 1 — every
        // rep in the rg has the same fragments + same send-off
        // (the variation Mode 2 catches is WITHIN a single rep,
        // ACROSS its fragments, which the single card already
        // shows). The header carries the set-level context (zone
        // chip, send-off, gear, dive/suit) so the exemplar card
        // drops the per-card chrome (rule 2).
        VStack(alignment: .leading, spacing: 6) {
            if reps != nil || fragments.count > 1 {
                headerLine
            }
            let isExemplar = shouldCollapseToExemplar(reps: reps, mode: .uniform)
            if isExemplar, let reps = reps {
                // Single exemplar card. Send-off + gear live on the
                // header — pass nil to the card so they don't
                // double-render.
                UniformRepCard(
                    rg: rg,
                    fragments: fragments,
                    paceTargetText: nil,
                    recordedTimes: recordedTimesForFirstTimableFragment(in: fragments, map: recordedTimesByFragmentId),
                    onTap: makeCardTapHandler(repIdx: 0),
                    context: context,
                    onAggregateTap: { title, records in
                        onAggregateChipTap(title, records)
                    }
                )
                // ×N trailing badge — same affordance as Mode 1.
                Text("× \(reps)")
                    .font(.numeric)
                    .foregroundColor(Color.accentAmber)
                    .padding(.leading, 4)
                    .accessibilityLabel("\(reps) identical reps")
            } else {
                // Non-exemplar path (legacy / reps == 1): one card
                // per rep. Mode 3 is dispatched separately above, so
                // this path only fires for reps == 1 today.
                let count = repCardCount(reps: reps)
                ForEach(0..<count, id: \.self) { repIdx in
                    UniformRepCard(
                        rg: rg,
                        fragments: fragments,
                        paceTargetText: paceTargetText,
                        recordedTimes: recordedTimesForFirstTimableFragment(in: fragments, map: recordedTimesByFragmentId),
                        onTap: makeCardTapHandler(repIdx: repIdx),
                        context: context,
                        onAggregateTap: { title, records in
                            onAggregateChipTap(title, records)
                        }
                    )
                }
            }
            if let note = note, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundColor(Color.textMuted)
                    .italic()
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 8)
                    .padding(.top, 2)
                    .accessibilityLabel(note)
            }
        }
    }

    private func makeCardTapHandler(repIdx: Int) -> (() -> Void)? {
        guard let onFragmentTap = onFragmentTap else { return nil }
        guard let fIdx = tapFragmentIndex(fragments: fragments) else { return nil }
        let fragment = fragments[fIdx]
        return { onFragmentTap(fIdx, fragment) }
    }

    private var headerLine: some View {
        // V0.54 S3.1 (2026-09-09, jodie-09 de-busy pass): same
        // set-level context as Mode 1's header — ×N, distance,
        // stroke, send-off, gear, dive/suit. Rule 2 again:
        // send-off + gear + zone chip live ONCE at the set
        // header, not on each rep card. Zone chip is omitted
        // here for Mode 2 because Mode 2 fires when the rep is
        // uniform within itself (a `steady` 6×100 already reads
        // the @65-75% range — adding `[Steady]` is noise). The
        // ladder/range disambiguation (rule 3) is a Mode 3
        // concern; Mode 2 doesn't fire perRepTargets today.
        HStack(spacing: 6) {
            Rectangle()
                .fill(Color.accentAmber)
                .frame(width: 2, height: 14)
            if let reps = reps, reps > 1 {
                Text("\(reps)×")
                    .font(.numeric)
                    .foregroundColor(Color.accentAmber)
            }
            // V0.54 S3.3 (2026-09-09, jodie-09 PRE round 2):
            // parent distance wears the zone color. The set's
            // governing zone (easy / steady / hard / sprint)
            // now expresses via this Text's color instead of
            // the removed [Easy] / [Steady] / [Hard] chip.
            // PairRepGroupRow's rg is optional — `rg?.zoneTerm`
            // returns nil for legacy callers, which falls
            // through `zoneColor(for:)` to the textPrimary
            // default (same as pre-S3.3).
            if let d = parentDistance {
                Text("\(d)m")
                    .font(.numeric)
                    .foregroundColor(zoneColor(for: rg.zoneTerm))
            }
            if let s = parentStroke, !s.isEmpty {
                Text(s)
                    .font(.body)
                    .foregroundColor(Color.textPrimary)
            }
            // V0.54 S3.1 (rule 2): send-off at the set header.
            if let pace = paceTargetText, !pace.isEmpty {
                Text("on \(pace)")
                    .font(.captionStrong)
                    .foregroundColor(Color.textMuted)
            }
            // V0.54 S3.3 (2026-09-09, jodie-09 PRE round 2): gear +
            // DIVE + SUIT converted from outlined chips to caption-
            // sized SF Symbols at textMuted.
            ForEach(rg.gear ?? [], id: \.self) { gear in
                Image(systemName: gearSymbol(for: gear))
                    .font(.caption)
                    .foregroundColor(Color.textMuted)
            }
            if rg.dive == true {
                Image(systemName: "figure.dive")
                    .font(.caption)
                    .foregroundColor(Color.accentAmber)
            }
            if rg.suit == true {
                Image(systemName: "figure.pool.swim")
                    .font(.caption)
                    .foregroundColor(Color.textMuted)
            }
        }
        .padding(.leading, 2)
    }
}

// V0.53.2: one uniform-rep card. Plain row, no track, no chevron.
// Distance + intensity label + send-off + play affordance (when
// timable). Mirrors FragmentCTARow's content for single-fragment
// repGroups but as a flat card row instead of a fragment row —
// same visual rhythm as RepCard (rounded background, padding) so
// the design system reads as one family.
private struct UniformRepCard: View {
    let rg: ParsedRepGroup
    let fragments: [ParsedFragment]
    let paceTargetText: String?
    let recordedTimes: [FragmentTimeRecord]?
    let onTap: (() -> Void)?
    // V0.54 S2.1 (2026-09-08): context flag. .preview hides the tap
    // gesture + play icon so the read-only surface stays zero-CTA.
    var context: RepCardContext = .preview
    let onAggregateTap: (String, [FragmentTimeRecord]) -> Void

    private var hasPlayAffordance: Bool {
        onTap != nil && tapFragmentIndex(fragments: fragments) != nil && context != .preview
    }

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.textMuted)
                .frame(width: 2)
            // Distance + intensity + descriptor (mirrors the
            // FragmentCTARow label chain so single-fragment
            // repGroups read the same as before).
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let d = rg.distance {
                        Text("\(d)m")
                            .font(.numeric)
                            .foregroundColor(Color.textPrimary)
                    }
                    if let stroke = rg.stroke, !stroke.isEmpty {
                        Text(stroke)
                            .font(.body)
                            .foregroundColor(Color.textPrimary)
                    }
                    if let label = firstFragmentIntensityLabel() {
                        Text("@ \(label)")
                            .font(.caption)
                            .foregroundColor(Color.accentAmber)
                    }
                }
                HStack(spacing: 6) {
                    if let pace = paceTargetText, !pace.isEmpty {
                        MetadataBadge(text: "@ \(pace)", color: Color.textMuted)
                    }
                    if let fragment = fragments.first, fragment.suit == true {
                        MetadataBadge(text: "SUIT", color: Color.textMuted)
                    }
                }
            }
            Spacer()
            if hasPlayAffordance {
                Image(systemName: recordedTimes != nil ? "arrow.counterclockwise.circle" : "play.circle.fill")
                    .foregroundColor(recordedTimes != nil ? Color.textMuted : Color.textPrimary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(Color.bgBase.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(uniformRepAccessibilityLabel)
        .accessibilityAddTraits(hasPlayAffordance ? .isButton : [])
        // V0.54 S2.1: tap gesture gated on context (zero-CTA
        // invariant for .preview). The play icon above already
        // vanishes in .preview via hasPlayAffordance, so this is
        // the second half of the gate — without it the gesture
        // would still fire even with no visible affordance.
        .onTapGesture { onTap?() }
    }

    private var uniformRepAccessibilityLabel: String {
        var parts: [String] = []
        if let d = rg.distance { parts.append("\(d) meters") }
        if let stroke = rg.stroke, !stroke.isEmpty { parts.append(stroke) }
        if let label = firstFragmentIntensityLabel() { parts.append("@ \(label)") }
        if let pace = paceTargetText, !pace.isEmpty { parts.append("on \(pace)") }
        return parts.joined(separator: ", ")
    }

    // First non-empty intensity label across the fragments; falls
    // back to the rg's intensity. Used by both the visible label
    // and the accessibility label.
    private func firstFragmentIntensityLabel() -> String? {
        for f in fragments {
            if let label = f.intensity?.label, !label.isEmpty {
                return label
            }
            if let label = f.intensityLabel, !label.isEmpty {
                return label
            }
            if let desc = f.descriptor, !desc.isEmpty {
                return desc
            }
        }
        return rg.intensity?.label
    }
}

// V0.53.2: Mode 3 (per-rep progression) render path. Used when
// the instruction varies ACROSS reps (Descend 1-4, build through,
// ascend). The rep itself is uniform, but each card carries its
// own target. A chevron between cards shows progression direction.
//
// Visual: same ×N + parent distance + stroke header as RepCard.
// Then N rep cards, each showing its per-rep target (70%, 75%, …).
// A small ↘ chevron between cards when perRepTargets is non-nil,
// indicating direction. No within-card track.
//
// When perRepTargets is nil (no explicit labels + no synthesized
// descend-ladder targets), the chevron still renders so the
// progression direction is visible — just without the numeric
// labels. The coach reads "Rep 1 → Rep 2 → Rep 3 → Rep 4" as a
// sequence, even without the %s.
private struct ProgressionRepGroupRow: View {
    let rg: ParsedRepGroup
    let fragments: [ParsedFragment]
    let reps: Int?
    let parentDistance: Int?
    let parentStroke: String?
    let paceTargetText: String?
    let perRepTargets: [String]?
    let recordedTimesByFragmentId: [String: [FragmentTimeRecord]]?
    // V0.54 S2.1 (2026-09-08): context flag forwarded to
    // ProgressionRepCard. Same .preview/.live contract as the other
    // row components.
    var context: RepCardContext = .preview
    let onFragmentTap: ((Int, ParsedFragment) -> Void)?
    let onAggregateChipTap: (String, [FragmentTimeRecord]) -> Void
    let note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if reps != nil || fragments.count > 1 {
                headerLine
            }
            let count = repCardCount(reps: reps)
            ForEach(0..<count, id: \.self) { repIdx in
                if repIdx > 0 {
                    // Subtle chevron between cards. ↘ for descend /
                    // build (most common — coaches descend or build
                    // through the set); ↗ for ascend when the
                    // rg's pacing/intensity signals up. Default ↘
                    // covers the corpus's progression cases.
                    Image(systemName: progressionChevron)
                        .font(.caption2)
                        .foregroundColor(Color.textFaint)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 2)
                        .accessibilityHidden(true)
                }
                ProgressionRepCard(
                    repNumber: repIdx + 1,
                    totalReps: reps ?? 1,
                    rg: rg,
                    fragments: fragments,
                    paceTargetText: paceTargetText,
                    perRepTarget: perRepTargets.flatMap { $0.indices.contains(repIdx) ? $0[repIdx] : nil },
                    recordedTimes: recordedTimesForFirstTimableFragment(in: fragments, map: recordedTimesByFragmentId),
                    onTap: makeCardTapHandler(repIdx: repIdx),
                    // V0.54 S2.1: forward context so the per-rep
                    // tap gesture + play icon honor .preview's
                    // zero-CTA invariant.
                    context: context,
                    onAggregateTap: { title, records in
                        onAggregateChipTap(title, records)
                    }
                )
            }
            if let note = note, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundColor(Color.textMuted)
                    .italic()
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 8)
                    .padding(.top, 2)
                    .accessibilityLabel(note)
            }
        }
    }

    // Chevron direction. V0.53.2 ships descend + build as the two
    // detected progression descriptors — both render ↘ ("the
    // numbers go down" / "the numbers build up"). Ascend would
    // render ↗ but isn't a server-side intensity type today
    // (negSplit is the only "up" progression, and it's rarely used
    // in user-facing ladders). Default ↘ for unknown.
    private var progressionChevron: String {
        if rg.pacing == "build" { return "arrow.up.right" }
        if rg.intensity?.type == .negative_split { return "arrow.up.right" }
        return "arrow.down.right"
    }

    private func makeCardTapHandler(repIdx: Int) -> (() -> Void)? {
        guard let onFragmentTap = onFragmentTap else { return nil }
        guard let fIdx = tapFragmentIndex(fragments: fragments) else { return nil }
        let fragment = fragments[fIdx]
        return { onFragmentTap(fIdx, fragment) }
    }

    private var headerLine: some View {
        // V0.54 S3.1 (2026-09-09, jodie-09 de-busy pass): when
        // perRepTargets is populated (the Mode 3 ladder case —
        // 70/75/80/85 cards below), suppress the intensity range
        // and the [Hard] zone chip — the ladder implies both. Rule
        // 3: range OR ladder, never both. The cards carry the
        // numeric targets; the header shows the ladder shape
        // (DESCEND / BUILD badge) and the set-level context (×N,
        // distance, stroke, send-off, gear, dive/suit).
        //
        // Mode 3 keeps all 4 rep cards because each card has a
        // distinct target — collapse would hide the build sequence
        // that IS the point of Mode 3. Rule 1 explicitly excludes
        // Mode 3 from the exemplar collapse.
        HStack(spacing: 6) {
            Rectangle()
                .fill(Color.accentAmber)
                .frame(width: 2, height: 14)
            if let reps = reps, reps > 1 {
                Text("\(reps)×")
                    .font(.numeric)
                    .foregroundColor(Color.accentAmber)
            }
            // V0.54 S3.3 (2026-09-09, jodie-09 PRE round 2):
            // parent distance wears the zone color. The set's
            // governing zone (easy / steady / hard / sprint)
            // now expresses via this Text's color instead of
            // the removed [Easy] / [Steady] / [Hard] chip.
            // PairRepGroupRow's rg is optional — `rg?.zoneTerm`
            // returns nil for legacy callers, which falls
            // through `zoneColor(for:)` to the textPrimary
            // default (same as pre-S3.3).
            if let d = parentDistance {
                Text("\(d)m")
                    .font(.numeric)
                    .foregroundColor(zoneColor(for: rg.zoneTerm))
            }
            if let s = parentStroke, !s.isEmpty {
                Text(s)
                    .font(.body)
                    .foregroundColor(Color.textPrimary)
            }
            // V0.54 S3.1 (rule 3): the intensity range text only
            // renders when the ladder is NOT populated. For a Mode
            // 3 with explicit per-rep targets (the jodie-09 4×50
            // DESCEND 70-85% case), the @70-85% range is implied
            // by the 70/75/80/85 cards and the [Hard] zone is
            // implied by "Hard set, building". Show neither —
            // keep the header clean.
            //
            // Inline intensity formatter (mirrors RepGroupRowView's
            // fmtIntensity(_:) helper, which lives in the OUTER
            // RepGroupRowView — out of scope here). Keeps the
            // descend + pacing suffix that the range text
            // already wears. Pure presentational helper.
            if !showsLadder, let intensity = rg.intensity {
                Text(" @ \(progressionHeaderIntensity(intensity))")
                    .font(.caption)
                    .foregroundColor(Color.accentAmber)
            }
            if !showsLadder, let zoneTerm = rg.zoneTerm {
                // V0.54 S3.3 (2026-09-09, jodie-09 PRE round 2):
                // zone chip demoted to plain text. The leading
                // distance already wears the zone color via
                // `zoneColor(for:)`, so the standalone `[Hard]`
                // pill is one chrome layer too many.
                Text(zoneTerm.uppercased())
                    .font(.caption2)
                    .tracking(0.8)
                    .foregroundColor(Color.accentAmber)
            }
            // V0.54 S3.3: gear + DIVE + SUIT as SF Symbols.
            ForEach(rg.gear ?? [], id: \.self) { gear in
                Image(systemName: gearSymbol(for: gear))
                    .font(.caption)
                    .foregroundColor(Color.textMuted)
            }
            if rg.dive == true {
                Image(systemName: "figure.dive")
                    .font(.caption)
                    .foregroundColor(Color.accentAmber)
            }
            if rg.suit == true {
                Image(systemName: "figure.pool.swim")
                    .font(.caption)
                    .foregroundColor(Color.textMuted)
            }
            // V0.54 S3.3: send-off demoted to inline caption text.
            // Same canonical "on 1:00" verbalisation as Set 3,
            // no chip chrome.
            if let pace = paceTargetText, !pace.isEmpty {
                Text("on \(pace)")
                    .font(.captionStrong)
                    .foregroundColor(Color.textMuted)
            }

            // Progression badge — "DESCEND" / "BUILD" — as plain
            // small-caps text. Amber + uppercase + tracking carry
            // the same discriminator signal without the outlined
            // pill.
            if let badge = progressionBadge {
                Text(badge)
                    .font(.caption2)
                    .tracking(1.0)
                    .foregroundColor(Color.accentAmber)
            }
        }
        .padding(.leading, 2)
    }

    // V0.54 S3.1 (rule 3): the ladder-suppression gate. When
    // perRepTargets is populated, the header suppresses the
    // intensity range + zone chip because the ladder implies
    // both. Extracted to a stored-ish var so `headerLine`'s
    // `some View` opaque-return-type inference can see a single
    // HStack body (Swift's opaque-return rule requires the body's
    // last expression to determine the type — `let` statements at
    // the top break that).
    private var showsLadder: Bool {
        perRepTargets?.isEmpty == false
    }

    private var progressionBadge: String? {
        if rg.descend != nil || rg.intensity?.type == .descend || rg.zoneTerm == "descend" {
            return "DESCEND"
        }
        if rg.pacing == "build" { return "BUILD" }
        return nil
    }

    // V0.54 S3.1 (2026-09-09, jodie-09 de-busy pass): inline the
    // intensity formatter so the Mode 3 headerLine can render the
    // "@ percent-range" text without depending on the OUTER
    // RepGroupRowView's fmtIntensity(_:) helper (which is private
    // to that struct). Mirrors the original helper 1:1 — percent
    // range renders as "low–high%", descend appends " ↘ {descend}",
    // and pacing appends the pacing word when it isn't "build"
    // (build is handled by the DESCEND/BUILD badge).
    private func progressionHeaderIntensity(_ i: ParsedIntensity) -> String {
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

// V0.53.2: one progression-rep card. Carries the per-rep target
// (e.g. "70%", "75%") as a prominent badge on the right, plus
// the rep's distance + intensity descriptor on the left. Same
// play affordance + recorded-time semantics as RepCard.
//
// No track (the rep itself is uniform within itself). The visual
// anchor is the per-rep target badge.
private struct ProgressionRepCard: View {
    let repNumber: Int
    let totalReps: Int
    let rg: ParsedRepGroup
    let fragments: [ParsedFragment]
    let paceTargetText: String?
    let perRepTarget: String?
    let recordedTimes: [FragmentTimeRecord]?
    let onTap: (() -> Void)?
    // V0.54 S2.1 (2026-09-08): context flag. Same .preview/.live
    // contract as the other composite cards.
    var context: RepCardContext = .preview
    let onAggregateTap: (String, [FragmentTimeRecord]) -> Void

    private var hasPlayAffordance: Bool {
        onTap != nil && tapFragmentIndex(fragments: fragments) != nil && context != .preview
    }

    var body: some View {
        HStack(spacing: 8) {
            // Rep number prefix (1/4, 2/4, …) so the coach reads
            // "rep 2 of 4 = 75%" without ambiguity. Sits on the
            // left, muted, so the target badge on the right reads
            // as the primary signal.
            //
            // V0.54 S3.1 (rule 6: quiet the hierarchy): bumped one
            // contrast step from `.numericSmall` / `Color.textFaint`
            // to `.caption` / `Color.textMuted` so the "rep 2 / 4"
            // legibility class reads cleanly on a glance. Was the
            // known low-contrast nit Nathan flagged. One step up,
            // not to textPrimary (would compete with the per-rep
            // target pill on the right).
            if totalReps > 1 {
                Text("\(repNumber)/\(totalReps)")
                    .font(.caption)
                    .foregroundColor(Color.textMuted)
            }
            // V0.54 S3.2 (2026-09-09, jodie-09 de-busy pass): strip
            // per-row distance / stroke / @intensity / send-off.
            // Those are set-level facts — the ProgressionRepGroupRow
            // header carries "4× 50m Free + Pull + DESCEND + on 1:00"
            // once. Each row only varies by rep index + per-rep
            // target badge (70% → 85%). Rule-2 dedupe one level down
            // from S3.1: the row must not repeat the header.
            //
            // Visual stays anchored: the per-rep target badge on the
            // right is still the primary signal, the rep index on
            // the left still disambiguates "rep 2 of 4 = 75%". A
            // subtle Spacer replaces the removed VStack so the badge
            // remains right-aligned in the same horizontal slot.
            Spacer()
            // Per-rep target — the primary visual signal for Mode 3.
            // V0.54 S3.3 (2026-09-09, jodie-09 PRE round 2): chip
            // demoted to plain mono text, right-aligned, no outlined
            // pill. The numeric target reads as data, not chrome.
            // Slightly heavier than the default caption so it still
            // carries the per-rep weight (the only thing that
            // differs across rows in Mode 3).
            if let target = perRepTarget {
                Text(target)
                    .font(.numeric)
                    .foregroundColor(Color.accentAmber)
                    .accessibilityLabel("target \(target)")
            }
            if hasPlayAffordance {
                Image(systemName: recordedTimes != nil ? "arrow.counterclockwise.circle" : "play.circle.fill")
                    .foregroundColor(recordedTimes != nil ? Color.textMuted : Color.textPrimary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(Color.bgBase.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progressionCardAccessibilityLabel)
        .accessibilityAddTraits(hasPlayAffordance ? .isButton : [])
        // V0.54 S2.1: tap gesture gated on context. The play icon
        // above vanishes in .preview via hasPlayAffordance; this
        // is the second half of the zero-CTA gate.
        .onTapGesture { onTap?() }
    }

    private var progressionCardAccessibilityLabel: String {
        // V0.54 S3.2 (rule-2 dedupe): only the per-row-varying facts
        // — rep index + per-rep target. Set-level facts (distance,
        // stroke, intensity, send-off) are announced once at the
        // parent ProgressionRepGroupRow's header line.
        var parts: [String] = []
        if totalReps > 1 {
            parts.append("Rep \(repNumber) of \(totalReps)")
        }
        if let target = perRepTarget { parts.append("target \(target)") }
        return parts.joined(separator: ", ")
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

// V0.53.2 (2026-09-08): safe lookup of the timable fragment's
// recorded times for Mode 2/3 rows. Used when the parent repGroup
// may have ZERO fragments (the Descend-ladder case where the
// per-rep targets live in rg.descend + rg.perRepTargets, not in
// per-rep fragments). Returns nil for empty fragments — never
// indexes fragments[0] on an empty array (the index-out-of-range
// crash that V0.53.2 first shipped).
private func recordedTimesForFirstTimableFragment(
    in fragments: [ParsedFragment],
    map: [String: [FragmentTimeRecord]]?
) -> [FragmentTimeRecord]? {
    guard !fragments.isEmpty else { return nil }
    guard let fIdx = tapFragmentIndex(fragments: fragments) else { return nil }
    return recordedTimesForFragment(fragments[fIdx], in: map)
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

// V0.53.1 Design A (2026-09-08, jodie-09 approved direction): one
// rep card. Renders one rep of the composite repGroup as a single
// connected bar split into horizontal proportional segments. The
// whole bar is one visual unit = one swim. Send-off lives at the
// trailing edge of the card (the rep's edge, not each segment).
// Play affordance is the card itself — segments have no tap of
// their own. Easy segments render muted (lower opacity, smaller
// label). Recorded-time chip + play-or-retap icon both key on the
// rep's timable fragment, so the existing fragment_id-keyed
// captured-time machinery keeps working unchanged.
//
// Visual layout:
//
//   ┌────────────────────────────────────────────────────────┐
//   │ 25 event rhythm │ 25 easy                       @ 1:00 ▶│
//   └────────────────────────────────────────────────────────┘
//
// The two segments share one rounded background (no internal
// dividers, no borders between them) — the proportional split is
// carried by the GeometryReader width fraction and the segment
// label positions itself inside the proportional area. Continuity
// is inherent in the layout — nothing is labelled "continuous".
private struct RepCard: View {
    let repNumber: Int
    let totalReps: Int
    let parentDistance: Int?
    let fragments: [ParsedFragment]
    let paceTargetText: String?
    let recordedTimes: [FragmentTimeRecord]?
    let onTap: (() -> Void)?
    // V0.54 S2.1 (2026-09-08): context flag. .preview hides the tap
    // gesture + play icon — zero-CTA invariant. LIVE surfaces both.
    var context: RepCardContext = .preview
    let onAggregateTap: (String, [FragmentTimeRecord]) -> Void

    // The rep's total distance drives the proportional split. Sum
    // of fragments' distances — fall back to 1 if all fragments
    // lack a distance (defensive; layout still renders at equal
    // 0% per segment, which collapses the bar to the play button
    // column — gracefully degraded).
    private var totalDistance: Int {
        let sum = fragments.reduce(0) { $0 + ($1.distance ?? 0) }
        return sum > 0 ? sum : 1
    }

    // Whether the card shows a play affordance. True iff the
    // handler is wired AND at least one segment is timable AND
    // the context isn't .preview (V0.54 S2.1 zero-CTA invariant).
    private var hasPlayAffordance: Bool {
        onTap != nil && tapFragmentIndex(fragments: fragments) != nil && context != .preview
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                // V0.53.1 Design A: the connected segment track. One
                // GeometryReader so each segment's width is proportional
                // to its distance. No internal dividers/borders — the
                // single rounded background carries the whole track as
                // one visual unit. The accentAmber tint (the existing
                // "data, not CTA" color token) marks the work segment;
                // easy segments render muted (lower opacity + smaller
                // label) so the coach sees the work visually dominant.
                GeometryReader { geo in
                    let trackWidth = geo.size.width
                    // V0.53.1 Design A: segments are laid out in an
                    // HStack inside the GeometryReader so each one
                    // gets its proportional slice of the track.
                    // The whole HStack is then drawn on top of the
                    // shared rounded background so the track reads
                    // as ONE connected container — no internal
                    // dividers/borders. (The first attempt used a
                    // ZStack which collapsed all segments to
                    // x=0 because ZStack alignment is .leading;
                    // segments then overlapped instead of
                    // partitioning the width.)
                    HStack(spacing: 0) {
                        ForEach(Array(fragments.enumerated()), id: \.offset) { idx, f in
                            let width = segmentWidth(fragmentDistance: f.distance, totalDistance: totalDistance) * trackWidth
                            let isEasy = (f.intensity?.type == .easy)
                            // V0.53.1 Design A: visual intensity gradient.
                            // Timable segments (race_pace, threshold,
                            // percent_range, sprint, etc.) tint with
                            // accentAmber at 0.55 opacity. Easy
                            // segments tint at 0.18 opacity so they
                            // read as "the easy part" without
                            // disappearing. nil intensity = assume
                            // work (renders at full accentAmber
                            // opacity, matching the timable-default
                            // rule).
                            let segmentFill: Color = {
                                guard let type = f.intensity?.type else {
                                    return Color.accentAmber.opacity(0.55)
                                }
                                return type == .easy
                                    ? Color.textMuted.opacity(0.18)
                                    : Color.accentAmber.opacity(0.55)
                            }()
                            Rectangle()
                                .fill(segmentFill)
                                .frame(width: width)
                                // V0.53.1 Design A: each segment label
                                // sits inside its proportional slice,
                                // centred horizontally on the segment
                                // midpoint. Easy labels render at smaller
                                // font + lower opacity. Work labels
                                // render at the row's primary type.
                                //
                                // Layout rule: the label is fixed-size
                                // (single line, no wrap), then framed
                                // to the segment width with centre
                                // alignment, and clipped — so a label
                                // wider than its segment ellipsizes
                                // within the segment bounds instead of
                                // bleeding into the next segment.
                                .overlay(
                                    GeometryReader { segGeo in
                                        let label = segmentLabel(fragment: f)
                                        Text(label)
                                            .font(isEasy ? .caption2 : .caption)
                                            .foregroundColor(
                                                isEasy
                                                    ? Color.textMuted.opacity(0.7)
                                                    : Color.textPrimary
                                            )
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                            .minimumScaleFactor(0.5)
                                            .fixedSize(horizontal: true, vertical: false)
                                            .frame(
                                                width: segGeo.size.width,
                                                alignment: .center
                                            )
                                            .clipped()
                                    }
                                )
                        }
                    }
                    .background(
                        // Single shared background drawn underneath
                        // the HStack so the track reads as ONE
                        // connected container. The HStack's segments
                        // paint on top of this; the rounded corners
                        // clip everything to a single rounded shape.
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.bgInset)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .frame(height: 28)

                // V0.54 S3.3 (2026-09-09, jodie-09 PRE round 2):
                // trailing send-off demoted from chip to inline
                // mono text. Same canonical "@ 1:00" verbalisation
                // as the set header, no chip chrome.
                //
                // V0.53.1 Design A: send-off lives at the card's
                // trailing edge. Same fog-on-inset chip the old
                // FragmentCTARow wore, but here it sits once per card
                // — never per segment. The whole rep is on the minute,
                // not each fragment. V0.54 S3.3 demoted the chip to
                // plain mono text — the parent PairRepGroupRow header
                // already carries "on 1:00" inline, so this trailing
                // "@ 1:00" used to be a duplicate. Kept for the
                // non-exemplar path (1 card per rep, no header
                // above) and the legacy fallback when the header is
                // suppressed. Style matches the header's send-off
                // text so the row reads as one system.
                if let pace = paceTargetText, !pace.isEmpty {
                    Text("@ \(pace)")
                        .font(.captionStrong)
                        .foregroundColor(Color.textMuted)
                        .padding(.leading, 6)
                }

                // V0.53.1 Design A: the play affordance. When the card
                // is timable, show the play (or retap if a recording
                // exists) icon. SF Symbol, same as FragmentCTARow uses.
                // When ALL fragments are easy, no icon — the card is
                // passive description.
                if hasPlayAffordance {
                    Image(systemName: recordedTimes != nil ? "arrow.counterclockwise.circle" : "play.circle.fill")
                        .foregroundColor(recordedTimes != nil ? Color.textMuted : Color.textPrimary)
                        .padding(.leading, 6)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(Color.bgBase.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            // V0.53.1 Design A: recorded-time chip (V0.48 S1/S2
            // semantic, 1-2 inline chips OR 3+ aggregate chip). Reads
            // from the rep's timable fragment. Lives BELOW the track
            // so it doesn't compete with the segment labels. Tapping
            // the chip opens the aggregate sheet; tapping the rest of
            // the card opens the stopwatch (when timable).
            if hasPlayAffordance, let times = recordedTimes, !times.isEmpty {
                recordedTimeChip(times: times)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cardAccessibilityLabel(
            repNumber: repNumber,
            totalReps: totalReps,
            parentDistance: parentDistance,
            segments: fragments,
            interval: paceTargetText
        ))
        .accessibilityAddTraits(hasPlayAffordance ? .isButton : [])
        // V0.54 S2.1: tap gesture gated on context (zero-CTA
        // invariant for .preview). The play icon above already
        // vanishes in .preview via hasPlayAffordance, so this is
        // the second half of the gate — without it the gesture
        // would still fire even with no visible affordance.
        .onTapGesture {
            onTap?()
        }
    }

    // V0.53.1 Design A: recorded-time chip rendered below the
    // segment track. Mirrors the V0.48 S2 aggregate chip
    // (count >= 3) and S1 inline chips (count 1-2) so the visual
    // language is identical to the rest of the app.
    @ViewBuilder
    private func recordedTimeChip(times: [FragmentTimeRecord]) -> some View {
        if times.count >= 3 {
            Button(action: {
                onAggregateTap(aggregateTitle(), times)
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(Color.statusSuccess)
                    Text("\(times.count) saved")
                        .font(.monoChip)
                        .foregroundColor(Color.textPrimary)
                    Text("▸")
                        .font(.monoChip)
                        .foregroundColor(Color.textPrimary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.bgInset)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.divider, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(times.count) times saved for \(aggregateTitle()), tap for detail")
        } else {
            HStack(spacing: 8) {
                ForEach(Array(times.enumerated()), id: \.offset) { _, record in
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(Color.statusSuccess)
                        Text(chipLabel(for: record))
                            .font(record.hasOwner ? .numeric : .captionStrong)
                            .foregroundColor(Color.statusSuccess)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(chipAccessibility(for: record))
                }
            }
        }
    }

    // V0.48 S2 chip title for the aggregate sheet — uses the
    // timable fragment's title (so "25m event rhythm" for the
    // race_pace segment, not "Rep 1 of 4").
    private func aggregateTitle() -> String {
        guard let fIdx = tapFragmentIndex(fragments: fragments) else {
            return fragmentChipTitle(fragment: fragments[0])
        }
        return fragmentChipTitle(fragment: fragments[fIdx])
    }

    // V0.48 S1 chip label for owned vs. unowned inline chips —
    // shared with FragmentCTARow (defined below at the file-scope
    // helper section).
    private func chipLabel(for record: FragmentTimeRecord) -> String {
        let time = formatStopwatchTime(record.timeMs)
        if let name = record.swimmerName, !name.isEmpty {
            return "\(name) \(compactOwnedTime(record.timeMs))"
        }
        return "Saved \(time)"
    }

    // V0.48 S3 accessibility label for the inline chip — mirrors
    // FragmentCTARow's helper.
    private func chipAccessibility(for record: FragmentTimeRecord) -> String {
        if let name = record.swimmerName, !name.isEmpty {
            return "\(name) \(compactOwnedTime(record.timeMs))"
        }
        return formatStopwatchTime(record.timeMs)
    }

    // V0.48 S2 chip title helper (shared with FragmentCTARow).
    private func fragmentChipTitle(fragment: ParsedFragment) -> String {
        var parts: [String] = []
        // V0.53.3 (2026-09-08): prefer verbatim label over rounded int.
        let dist = fragmentDistanceText(fragment)
        if !dist.isEmpty { parts.append(dist) }
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

// ponytail (2026-09-08): tolerant numeric decoder for fragment.distance.
// Try Double first (handles half-pool meters like 12.5 that the engine
// emitted before normalizeFragmentDistances landed), fall back to Int
// (handles 13), then string-form (handles "12" from any LLM-emitted
// JSON-quirked variant). Returns nil when the key is absent or null.
// Rounds the projected value via `Int(value.rounded())` so the public
// `distance: Int?` keeps its type without forcing callers to migrate
// to Double. Mirrors the rounding rule in the server's
// normalizeFragmentDistances — both sides land on the same Int.
private func decodeFlexibleInt<K: CodingKey>(
    _ c: KeyedDecodingContainer<K>,
    _ key: K
) -> Int? {
    if c.contains(key) {
        let isNil = (try? c.decodeNil(forKey: key)) ?? false
        if !isNil {
            if let d = try? c.decode(Double.self, forKey: key) {
                return Int(d.rounded())
            }
            if let i = try? c.decode(Int.self, forKey: key) {
                return i
            }
            if let s = try? c.decode(String.self, forKey: key), let d = Double(s) {
                return Int(d.rounded())
            }
        }
    }
    return nil
}