//
//  WorkoutStructureView.swift
//  Hydrolyze
//
//  V0.55 S1 (2026-09-13): single shared render surface for the
//  workout's parsed structure.
//
//  Before S1:
//    - WorkoutBuilderView and WorkoutDetailView each rendered a
//      `WorkoutPreview` directly, calling `WorkoutPreviewBuilder
//      .fromWorkoutAndSets` (WorkoutDetailView via a 2-line private
//      `buildParsedWorkout(from:sets:)` wrapper, WorkoutBuilderView
//      via its own ViewModel-built `parsedWorkout`).
//    - Two render surfaces × one shared projection = two drift sites.
//      If a future session adds a field to the projection, only one
//      surface will pick it up until the other is touched by hand.
//
//  After S1:
//    - Both surfaces render through this `WorkoutStructureView`.
//    - The init takes the DB-row shape (`Workout` + `[WorkoutSet]`)
//      and internally calls `WorkoutPreviewBuilder.fromWorkoutAndSets`
//      exactly once. One projection function, one caller, one render
//      component.
//    - Surface-specific knobs (degraded banner, onFragmentTap, etc.)
//      are forwarded through.
//
//  This is NOT a re-design of the visual layout — S1a owns the
//  rep-identity card rework. S1 extracts the existing rendering
//  into a single surface so S2/S3/S4 can build on it without the
//  drift risk.
//

import SwiftUI

/// V0.55 S1: the shared render surface for the workout's parsed
/// structure. Routes through `WorkoutPreviewBuilder.fromWorkoutAndSets`
/// for the DB-row → ParsedWorkout projection and renders the existing
/// `WorkoutPreview` with `.preview` context (no live stopwatch, no
/// long-press removal — those are owned by their respective hosts).
struct WorkoutStructureView: View {
    private let parsed: ParsedWorkout
    private let onRemoveRepGroup: ((Int, Int, Int) -> Void)?
    private let onFragmentTap: ((Int, Int, Int, Int, ParsedFragment) -> Void)?
    private let recordedTimesByFragmentId: [String: [FragmentTimeRecord]]?
    private let degraded: Bool
    private let degradedReason: String?
    private let onRetry: (() -> Void)?
    /// V0.47 Slice 3: end-of-session vocabulary card. Detail view
    /// passes `false` (it has its own edit affordance); builder
    /// preview leaves the default so the production rule applies.
    private let showVocabularyCard: Bool

    /// Preferred initializer — accepts the DB-row shape so callers
    /// don't construct the `ParsedWorkout` themselves. Single source
    /// of truth for the projection.
    init(
        workout: Workout,
        sets: [WorkoutSet],
        onRemoveRepGroup: ((Int, Int, Int) -> Void)? = nil,
        onFragmentTap: ((Int, Int, Int, Int, ParsedFragment) -> Void)? = nil,
        recordedTimesByFragmentId: [String: [FragmentTimeRecord]]? = nil,
        degraded: Bool = false,
        degradedReason: String? = nil,
        onRetry: (() -> Void)? = nil,
        showVocabularyCard: Bool = false
    ) {
        // V0.55 S1: the single canonical projection site. Both
        // WorkoutDetailView and WorkoutBuilderView feed the same
        // DB-row inputs through this helper. Adding a field here
        // (e.g. a future zone-term round-trip) propagates to both
        // surfaces with zero risk of drift.
        self.parsed = WorkoutPreviewBuilder.fromWorkoutAndSets(workout, sets: sets)
        self.onRemoveRepGroup = onRemoveRepGroup
        self.onFragmentTap = onFragmentTap
        self.recordedTimesByFragmentId = recordedTimesByFragmentId
        self.degraded = degraded
        self.degradedReason = degradedReason
        self.onRetry = onRetry
        self.showVocabularyCard = showVocabularyCard
    }

    /// Direct initializer — accepts a pre-built `ParsedWorkout`.
    /// Reserved for callers that already hold a parsed tree (e.g.
    /// the builder preview's `viewModel.parsedWorkout` from the
    /// parser pipeline). Routes through the same render path.
    init(
        parsedWorkout: ParsedWorkout,
        onRemoveRepGroup: ((Int, Int, Int) -> Void)? = nil,
        onFragmentTap: ((Int, Int, Int, Int, ParsedFragment) -> Void)? = nil,
        recordedTimesByFragmentId: [String: [FragmentTimeRecord]]? = nil,
        degraded: Bool = false,
        degradedReason: String? = nil,
        onRetry: (() -> Void)? = nil,
        showVocabularyCard: Bool = false
    ) {
        self.parsed = parsedWorkout
        self.onRemoveRepGroup = onRemoveRepGroup
        self.onFragmentTap = onFragmentTap
        self.recordedTimesByFragmentId = recordedTimesByFragmentId
        self.degraded = degraded
        self.degradedReason = degradedReason
        self.onRetry = onRetry
        self.showVocabularyCard = showVocabularyCard
    }

    var body: some View {
        // V0.55 S1: delegate to the existing `WorkoutPreview` render
        // surface with `.preview` context (the default — no live
        // elevation, no completed-set dimming). The detail view's
        // recorded-times map and the builder preview's degraded
        // banner both forward through unchanged.
        //
        // S1 mutates WorkoutPreview's public surface to accept an
        // explicit `showVocabularyCard` parameter — the production
        // rule already reads `showVocabularyCard` (a public `var`
        // on WorkoutPreview since V0.47 Slice 3), but S0a's detail
        // page was passing it via an unlabeled slot. Promoting it
        // to an explicit init parameter keeps the same contract but
        // makes the forwarder's intent visible at the call site.
        WorkoutPreview(
            workout: parsed,
            onRemoveRepGroup: onRemoveRepGroup,
            onFragmentTap: onFragmentTap,
            recordedTimesByFragmentId: recordedTimesByFragmentId,
            degraded: degraded,
            degradedReason: degradedReason,
            onRetry: onRetry,
            showVocabularyCard: showVocabularyCard
        )
    }
}