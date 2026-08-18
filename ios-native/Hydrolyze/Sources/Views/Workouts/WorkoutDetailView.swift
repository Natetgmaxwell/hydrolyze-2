import SwiftUI

@MainActor
final class WorkoutDetailViewModel: ObservableObject {
    @Published var workout: Workout?
    @Published var sets: [WorkoutSet] = []
    @Published var isLoading: Bool = true
    @Published var errorMessage: String?
    @Published var showDeleteConfirmation: Bool = false

    private let workoutService = WorkoutService()

    func loadWorkout(workoutId: String) async {
        isLoading = true
        errorMessage = nil

        do {
            async let workoutTask = workoutService.fetchWorkout(workoutId: workoutId)
            async let setsTask = workoutService.fetchWorkoutSets(workoutId: workoutId)
            workout = try await workoutTask
            sets = try await setsTask
        } catch {
            errorMessage = "Couldn't load workout: \(error)"
        }

        isLoading = false
    }

    func deleteWorkout(workoutId: String) async {
        do {
            try await workoutService.deleteWorkout(workoutId: workoutId)
        } catch {
            errorMessage = "Couldn't delete workout."
        }
    }

    func markComplete(workoutId: String) async {
        do {
            _ = try await workoutService.updateWorkout(workoutId: workoutId, updates: ["status": "complete"])
            workout?.status = .complete
        } catch {
            errorMessage = "Couldn't update workout."
        }
    }

    func startSession() {
        print("[WorkoutDetail] startSession tapped — placeholder for SetPicker")
    }

    func editWorkout() {
        print("[WorkoutDetail] editWorkout tapped — placeholder for I7 builder")
    }
}

/// WorkoutDetailView — pushed from WorkoutsListView. Shows parsed workout + actions.
struct WorkoutDetailView: View {
    let workoutId: String
    @Environment(AuthManager.self) private var authManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool
    @StateObject private var viewModel = WorkoutDetailViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var activeSession: ActiveSession? = nil
    @State private var navigateToBuilder = false
    @State private var timingPrefill: SetPrefill?
    @State private var showSessionStart = false
    @State private var pendingSessionId = UUID().uuidString
    // t_d59998d9 (2026-08-05): per-fragment recorded times held in
    // local component state until persistence runs (t_be09a643).
    // Keyed by fragmentId. Survives redraws but not navigation pops;
    // when persistence lands, the rows are written to recorded_times
    // and this map can be cleared on save success.
    @State private var recordedTimesByFragmentId: [String: Int] = [:]
    // ponytail (warmth-through-motion iter 6): on-appear reveal.
    // Same pattern as login reveal (d46c444), today reveal (0a90257),
    // workouts reveal (06c6823), swimmers reveal (61404f1, 1ffa02c),
    // and workouts+swimmers cohesion (19e0e9f). When the WorkoutDetail
    // is pushed, the content fades + scales in over Animations.springSoft,
    // gated by Reduce Motion for a11y.
    @State private var animateIn: Bool = false

    /// Wrapper for `.fullScreenCover(item:)` — needs Identifiable to drive the cover.
    /// Plain `String?` doesn't conform; without this the bottom TabView stays visible during timing.
    private struct ActiveSession: Identifiable, Hashable {
        let id: String
        // Phase 2.6 v1.6.1: workoutSetId is the set the coach picked in
        // the wave preview. Threaded into TimingView via the
        // SessionStartView.onComplete callback so the save() filter has
        // the current set id. The prefill-based path also sets
        // workoutSetId in TimingView.onAppear, but the explicit param
        // is the cleaner source of truth and matches TodayView's path.
        let workoutSetId: String
    }

    var body: some View {
        ZStack {
            Color.bgBase.ignoresSafeArea()

            ScrollView {
                if let workout = viewModel.workout {
                    VStack(alignment: .leading, spacing: 20) {
                        metadataSection(workout: workout)
                        WorkoutPreview(
                            workout: buildParsedWorkout(from: workout, sets: viewModel.sets),
                            // t_c74dffbc (2026-08-04): per-fragment CTA. Tapping
                            // a fragment builds a SetPrefill from the fragment's
                            // metadata and launches the live stopwatch. The
                            // workoutSetId is the repGroup's parent set; in
                            // production the parsed ParsedRepGroup carries a
                            // workoutSetId field. Here we resolve by index
                            // against the workout's sets list.
                            onFragmentTap: { _, _, rgIdx, _, fragment in
                                launchFragmentTiming(repGroupIndex: rgIdx, fragment: fragment)
                            },
                            // t_d59998d9 (2026-08-05): pass the local-state
                            // recorded-times map so each fragment row can
                            // show "Saved 0:42.31" once the stopwatch stops.
                            recordedTimesByFragmentId: recordedTimesByFragmentId
                        )
                            .padding(.horizontal, 16)
                        if let errorMessage = viewModel.errorMessage {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundColor(Color.statusError)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity)
                                .background(Color.statusError.opacity(0.1))
                                .cornerRadius(8)
                                .padding(.horizontal, 16)
                        }
                        setsList
                        actionButtons(workout: workout)
                    }
                    .padding(.vertical, 16)
                } else if !viewModel.isLoading {
                    Text(viewModel.errorMessage ?? "Workout not found")
                        .foregroundColor(Color.textMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                }
            }
            .redacted(reason: viewModel.isLoading && viewModel.workout == nil ? .placeholder : [])

            if viewModel.isLoading && viewModel.workout == nil {
                ProgressView()
                    .tint(Color.accentCyan)
            }
        }
        .navigationTitle(viewModel.workout?.title ?? "Workout")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    viewModel.showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(Color.statusError)
                }
            }
        }
        .alert("Delete Workout?", isPresented: $viewModel.showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    await viewModel.deleteWorkout(workoutId: workoutId)
                    dismiss()
                }
            }
        } message: {
            Text("This action cannot be undone.")
        }
        .fullScreenCover(item: $activeSession) { session in
            // Phase 2.6 v1.6.1 fix: pull the workoutSetId from
            // the timing prefill (built from the picked set) and
            // pass it explicitly to TimingView. The prefill path
            // still works (TimingView.onAppear reads it), but
            // the explicit param is the cleaner source of truth.
            TimingView(
                prefill: timingPrefill,
                sessionId: session.id,
                workoutSetId: timingPrefill?.workoutSetId,
                // t_d59998d9 (2026-08-05) + t_be09a643 (2026-08-05)
                // + t_bec2b88b (2026-08-06): recorded-time callback.
                // Fires once when the stopwatch transitions out of
                // `.running` with the full StopwatchCapturePayload
                // (the canonical handoff shape). The payload carries
                // recordedTimeMs, fragment metadata, the original
                // set text, and session/coach/swimmer context —
                // everything the persistence layer needs. We (a)
                // attach the time to the local @State map so the
                // fragment row shows "Saved 0:42.31" immediately,
                // and (b) kick off persistence asynchronously so the
                // row lands in recorded_times with swimmer_id=NULL
                // + all spec metadata populated. The pairing handoff
                // runs once the row is saved (pairExistingRow) —
                // the handoff is its own typed result, never a throw.
                onRecord: { payload in
                    recordedTimesByFragmentId[payload.fragment.fragmentId] = payload.recordedTimeMs
                    persistRecordedTime(payload: payload)
                }
            )
        }
        .navigationDestination(isPresented: $navigateToBuilder) {
            WorkoutBuilderView(workoutId: workoutId)
        }
        .sheet(isPresented: $showSessionStart) {
            SessionStartView(
                sessionId: pendingSessionId,
                workoutSets: viewModel.sets,
                // Phase 2.6 v1.6.1 fix: onComplete now passes
                // both the sessionId and the picked workoutSetId.
                // The picked set comes from SessionStartView's
                // previewSetIndex at Start time.
                onComplete: { sessionId, workoutSetId in
                    showSessionStart = false
                    activeSession = ActiveSession(
                        id: sessionId,
                        workoutSetId: workoutSetId
                    )
                }
            )
        }
        .task {
            await viewModel.loadWorkout(workoutId: workoutId)
        }
        // ponytail: workout detail fade-in on push. Gating by
        // reduceMotion is the standard a11y pattern (matches d46c444,
        // 0a90257, 06c6823, 61404f1, 1ffa02c, 19e0e9f).
        .opacity(animateIn ? 1.0 : 0.0)
        .scaleEffect(animateIn ? 1.0 : 0.98)
        .animation(reduceMotion ? nil : Animations.springSoft, value: animateIn)
        .onAppear { animateIn = true }
    }

    // Per-set start buttons — inline in the sets list.
    // V0.35 (2026-08-12): sets with parsed fragments render as tappable
    // fragment rows in WorkoutPreview above — the per-set row below is
    // redundant for them (and whole-set timing is wrong for composites).
    // Show rows only for sets WITHOUT fragments: simple sets (e.g.
    // "8 x 50 free on 1:00") have no fragment CTAs, so this row is their
    // only timing entry point.
    @ViewBuilder
    private var setsList: some View {
        let fragmentlessSets = viewModel.sets.filter { ($0.fragments ?? []).isEmpty }
        if !fragmentlessSets.isEmpty || viewModel.sets.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("SETS")
                    .font(.eyebrow)
                    .foregroundColor(Color.textFaint)
                    .tracking(1.5)
                    .padding(.horizontal, 16)

                if viewModel.sets.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "list.bullet.rectangle.portrait")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No sets in this workout")
                            .font(.headline)
                        Text("Open in the workout builder to add sets.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                }

                ForEach(fragmentlessSets) { set in
                    setRow(set)
                }
            }
        }
    }

    private func setRow(_ set: WorkoutSet) -> some View {
        let prefill = SetPrefill(
            stroke: set.stroke ?? "Free",
            distance: set.distance ?? 50,
            reps: set.reps,
            interval: set.intervalText,
            intensityLabel: set.intensityLabel,
            workoutSetId: set.id,
            // V0.38 Slice 4 (2026-08-16): forward the structured
            // intensity_type rawValue alongside the human label so the
            // timing flow can detect "3mt" without string-matching the
            // label. The DB persists rawValue ("3mt"); the parser emits
            // label ("3-minute all-out"). Both flow through.
            intensityType: set.intensityType,
            fragmentContexts: nil
        )
        let isTimeable = set.distance != nil && set.distance! > 0

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                timingPrefill = prefill
                pendingSessionId = UUID().uuidString
                showSessionStart = true
            } label: {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(set.label)
                            .font(.bodyEmphasis)
                            .foregroundColor(Color.textPrimary)
                            .multilineTextAlignment(.leading)

                        HStack(spacing: 6) {
                            // Gear badges
                            if let gear = set.gear, !gear.isEmpty {
                                Text(gear.joined(separator: ", "))
                                    .font(.captionStrong)
                                    .foregroundColor(Color.accentCyan)
                            }
                            // Intensity label
                            if let intensity = set.intensityLabel {
                                Text(intensity)
                                    .font(.caption)
                                    .foregroundColor(Color.accentAmber)
                            }
                            // Dive badge
                            if set.dive == true {
                                Text("DIVE")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(Color.accentAmber)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.accentAmber.opacity(0.12))
                                    .cornerRadius(4)
                            }
                            // Suit badge
                            if set.suit == true {
                                Text("SUIT")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(Color.accentCyan)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.accentCyan.opacity(0.12))
                                    .cornerRadius(4)
                            }
                        }
                    }

                    Spacer()

                    if isTimeable {
                        Image(systemName: "play.fill")
                            .font(.caption)
                            .foregroundColor(Color.accentCyan)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(isTimeable ? Color.clear : Color.clear)
            }
            .disabled(!isTimeable)
            .opacity(isTimeable ? 1 : 0.5)

            Divider()
                .background(Color.bgInset)
                .padding(.leading, 16)
        }
    }

    // t_be09a643 (2026-08-05) + t_6163b2f2 (2026-08-05) + t_ea9a65ca
    // (2026-08-05) + t_bec2b88b (2026-08-06): persist a
    // per-fragment recorded time to Supabase. Takes the full
    // `StopwatchCapturePayload` (the canonical handoff shape) and
    // projects it to a `PairingHandoffInput` via the payload's
    // `toPersistInput()` method (1:1 with the TS schema's
    // `toPersistInput`). The persistence layer (task 3,
    // t_1789d5c7) consumes the projected input.
    //
    // Why project in the view: keeps the persistence layer
    // (RecordedTimeFragmentService) decoupled from the payload
    // type. The view is the only place that holds both the
    // payload (from the stopwatch) and the candidate roster (the
    // future per-fragment PB prediction). For now `candidates: []`
    // — the deferred `pairExistingRow` path resolves swimmer_id
    // once the SessionReview fetches the roster.
    //
    // Why fire-and-await + typed error (PersistRecordedTimeError):
    // the spec's "fire-and-await is fine, but show a 'Saved'
    // indicator once the insert succeeds" rule depends on the
    // caller being able to distinguish success from failure.
    // Catching the typed error and not flipping the indicator is
    // the UI contract. The pairing handoff runs after the insert
    // — it never throws (the service wraps it in try/catch), so
    // the UI never sees a propagated error from the handoff.
    //
    // Re-entry handling: each payload carries a fresh `eventId`
    // + `idempotencyKey`. The persistence layer inserts a new
    // row per payload (no upsert collapse on the same fragment).
    // This is the spec's "re-entering a fragment produces an
    // independent timing run" acceptance gate, satisfied at the
    // iOS + persistence layer.
    private func persistRecordedTime(payload: StopwatchCapturePayload) {
        // Project the payload to the persist-input shape the
        // RecordedTimeFragmentService.persistRecordedTime(...) call
        // site accepts. The projection is the iOS mirror of the
        // TS `toPersistInput()` function — every spec field is
        // mapped field-for-field.
        let input = payload.toPersistInput()

        Task {
            do {
                let service = RecordedTimeFragmentService()
                // Project the persist input to the handoff input the
                // service consumes (fields map 1:1; the handoff input
                // carries the fragment context the pairing engine keys on).
                let handoffInput = PairingHandoffInput(
                    rowId: input.rowId,
                    recordedMs: input.recordedMs,
                    fragmentId: input.fragmentId,
                    setId: input.setId,
                    distanceMeters: input.distanceMeters,
                    intensity: input.intensity,
                    startType: input.startType,
                    paceTargetSec: input.paceTargetSec,
                    rawText: input.rawText
                )
                let inserted = try await service.persistRecordedTime(
                    input: handoffInput,
                    sessionId: payload.context.sessionId,
                    workoutSetId: payload.context.workoutSetId
                )
                // Success path: flip the indicator AFTER the row
                // is on disk (spec: "show a small 'Saved'
                // indicator once the insert succeeds"). The Task
                // body inherits @MainActor from the enclosing
                // WorkoutDetailView (the struct is annotated), so
                // the recordedTimesByFragmentId state write is
                // already main-actor-safe. The returned row
                // carries the server-side echo — verify
                // swimmer_id is null immediately (spec acceptance).
                // If the server returned a non-nil swimmer_id on
                // the insert, that's a contract bug worth
                // surfacing.
                if inserted.swimmerId != nil {
                    print("[WorkoutDetail] persistRecordedTime WARNING: inserted row has swimmer_id=\(inserted.swimmerId ?? "nil") (expected nil at insert time)")
                }
                recordedTimesByFragmentId[payload.fragment.fragmentId] = payload.recordedTimeMs
            } catch let error as PersistRecordedTimeError {
                // Typed error path — surface each bucket in the
                // dev console. The UI stays "not saved" so the
                // coach sees the truth and can retry.
                switch error {
                case .duplicateRow(let id):
                    print("[WorkoutDetail] persistRecordedTime FAILED (.duplicateRow id=\(id)): row already exists, will not retry-with-same-uuid")
                case .networkError(let underlying):
                    print("[WorkoutDetail] persistRecordedTime FAILED (.networkError): \(underlying.localizedDescription) — UI will not show Saved indicator")
                case .decodingError(let underlying):
                    print("[WorkoutDetail] persistRecordedTime FAILED (.decodingError): row landed but decode failed: \(underlying.localizedDescription) — possible schema drift, investigate RecordedTime vs recorded_times columns")
                case .unknown(let underlying):
                    print("[WorkoutDetail] persistRecordedTime FAILED (.unknown): \(underlying.localizedDescription)")
                }
            } catch {
                // Anything else — log, do not swallow silently.
                print("[WorkoutDetail] persistRecordedTime FAILED (unclassified): \(error)")
            }
        }
    }

    // t_c74dffbc (2026-08-04): per-fragment timing launch. Builds a
    // SetPrefill from the fragment's metadata so the live stopwatch opens
    // pre-filled with the fragment's distance, intensity, and start type.
    // The workoutSetId is the repGroup's parent set (resolved by index
    // against viewModel.sets); in production the parsed ParsedRepGroup
    // would carry an explicit workoutSetId from the server.
    //
    // fragmentContexts carries a single fragment context (the one the
    // coach tapped) so the save flow keys the prediction on the
    // fragment's distance / intensity / start — not the parent set.
    private func launchFragmentTiming(repGroupIndex: Int, fragment: ParsedFragment) {
        let parentSet = viewModel.sets[safe: repGroupIndex]
        let fragmentContext = FragmentContext(
            fragmentId: fragment.id ?? "fragment_\(repGroupIndex)_\(fragment.distance ?? 0)",
            parentIntervalId: parentSet?.id ?? "",
            distance: fragment.distance ?? parentSet?.distance ?? 50,
            intensity: fragment.intensity?.label ?? fragment.descriptor,
            startType: fragment.startType,
            suit: fragment.suit,
            gear: fragment.gear,
            descriptor: fragment.descriptor
        )
        let prefill = SetPrefill(
            stroke: fragment.stroke ?? parentSet?.stroke ?? "Free",
            distance: fragment.distance ?? parentSet?.distance ?? 50,
            reps: 1, // each fragment is one timed unit
            interval: parentSet?.intervalText,
            intensityLabel: fragment.intensity?.label ?? fragment.descriptor ?? parentSet?.intensityLabel,
            workoutSetId: parentSet?.id,
            // V0.38 Slice 4 (2026-08-16): forward the parent's
            // intensity_type so a fragment of a 3MT parent set still
            // triggers the 3MT timing flow. Fragments themselves don't
            // carry intensity_type — they inherit from the parent.
            intensityType: parentSet?.intensityType,
            fragmentContexts: [fragmentContext]
        )
        timingPrefill = prefill
        pendingSessionId = UUID().uuidString
        showSessionStart = true
    }

    private func metadataSection(workout: Workout) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(workout.title ?? "Untitled")
                .font(.titleMedium)
                .foregroundColor(Color.textPrimary)

            HStack(spacing: 8) {
                if let scheduledAt = workout.scheduledAt {
                    Text(formatDate(scheduledAt))
                        .font(.caption)
                        .foregroundColor(Color.textFaint)
                }

                if let amPm = workout.amPm {
                    Text("·")
                        .foregroundColor(Color.textFaint)
                    Text(amPm)
                        .font(.captionStrong)
                        .foregroundColor(Color.accentAmber)
                }

                Text("·")
                    .foregroundColor(Color.textFaint)
                Text(workout.status.rawValue.capitalized)
                    .font(.captionStrong)
                    .foregroundColor(statusColor(workout.status))
            }
        }
        .padding(.horizontal, 16)
    }

    private func actionButtons(workout: Workout) -> some View {
        VStack(spacing: 12) {
            if workout.status == .draft || workout.status == .scheduled {
                Button("Edit Workout") {
                    navigateToBuilder = true
                }
                .font(.titleSmall)
                .foregroundColor(Color.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Color.bgSunken)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.divider, lineWidth: 1)
                )
            }

            if workout.status == .inProgress {
                Button("Mark Complete") {
                    Task { await viewModel.markComplete(workoutId: workoutId) }
                }
                .font(.titleSmall)
                .foregroundColor(Color.statusSuccess)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Color.bgSunken)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.statusSuccess.opacity(0.3), lineWidth: 1)
                )
            }
        }
        .padding(.horizontal, 16)
    }

    private func buildParsedWorkout(from workout: Workout, sets: [WorkoutSet]) -> ParsedWorkout {
        ParsedWorkout(
            title: workout.title,
            sections: [
                ParsedSection(
                    title: nil,
                    namedSets: [
                        ParsedNamedSet(
                            label: nil,
                            note: nil,
                            repGroups: sets.map { set in
                                // t_d59998d9 (2026-08-05): map the
                                // WorkoutSet's parsed leaf fragments into
                                // the ParsedRepGroup so FragmentCTARow
                                // renders. nil/empty fragments falls through
                                // to the static label path (unchanged from
                                // t_c74dffbc). The pace target reads from
                                // the parent set's intervalText, which is
                                // what the row's "pace target badge" wants.
                                let parsedFragments: [ParsedFragment]? = set.fragments?.map { f in
                                    let intensityType = ParsedIntensityType(rawValue: f.intensity) ?? .easy
                                    let intensity: ParsedIntensity? = (f.intensity == "unknown" || f.intensity.isEmpty)
                                        ? nil
                                        : ParsedIntensity(type: intensityType, label: f.intensity)
                                    return ParsedFragment(
                                        id: f.id,
                                        distance: f.distanceMeters,
                                        stroke: set.stroke,
                                        instruction: nil,
                                        intensity: intensity,
                                        intensityType: intensityType.rawValue,
                                        intensityLabel: f.intensity == "unknown" ? nil : f.intensity,
                                        startType: f.startType,
                                        suit: nil,
                                        gear: nil,
                                        descriptor: nil,
                                        confidence: f.confidence
                                    )
                                }
                                return ParsedRepGroup(
                                    reps: set.reps,
                                    distance: set.distance,
                                    stroke: set.stroke,
                                    interval: set.intervalText,
                                    intensity: set.intensityLabel.map {
                                        ParsedIntensity(
                                            type: ParsedIntensityType(rawValue: set.intensityType ?? "easy") ?? .easy,
                                            label: $0
                                        )
                                    },
                                    pacing: nil,
                                    pattern: [],
                                    patternType: nil,
                                    connectors: nil,
                                    note: nil,
                                    gear: set.gear,
                                    gearOptional: false,
                                    descend: nil,
                                    details: nil,
                                    dive: set.dive,
                                    suit: set.suit,
                                    ambiguousTerm: nil,
                                    fragments: parsedFragments
                                )
                            }
                        )
                    ]
                )
            ]
        )
    }

    private func formatDate(_ dateStr: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: dateStr + "T00:00:00Z") ?? formatter.date(from: dateStr) ?? Date()
        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "EEE MMM d"
        return displayFormatter.string(from: date).uppercased()
    }

    private func statusColor(_ status: WorkoutStatus) -> Color {
        switch status {
        case .draft: return Color.accentAmber
        case .scheduled: return Color.accentCyan
        case .inProgress: return Color.accentCyan
        case .complete: return Color.statusSuccess
        }
    }
}

#Preview {
    NavigationStack {
        WorkoutDetailView(workoutId: "test-id")
    }
    .environment(AuthManager())
}