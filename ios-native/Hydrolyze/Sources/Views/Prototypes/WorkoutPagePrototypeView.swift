#if DEBUG
// V0.55 proto: native SwiftUI workout-page prototype (3 variants,
// DEBUG-only). Reachable via `-prototype-workout-page` launch arg
// (ContentView.swift DEBUG block routes to this view).
//
// Reason: HTML sketches are browser renders pretending to be iOS —
// wrong font rendering, wrong safe-area behavior, no Dynamic Type,
// no native materials. This file is the next-three-attempts route:
// render each candidate with the actual iOS component vocabulary
// (List, LazyVStack, Button, safeAreaInset) on the actual simulator
// so Nathan can compare variants 1:1 against production.
//
// Test workout (locked):
//  WARM-UP 400 m  4 × 100 free · on 1:30 · smooth, focus on length
//  MAIN SET 800 m 4 × 25 free · on :45 · 12.5 strong / 12.5 easy ·
//                descend 1–4, race rhythm (ACTIVE, rep 2 of 4)
//                8 × 50 free · on 1:15 · 100 pace (NEXT)
//                3 × 100 IM · on 1:30 · smooth
//  COOL-DOWN 300 m 300 choice · easy
//
// Shared rules across all three variants:
//  - Verbatim coach language. No rewording.
//  - Fragment math visible (12.5 strong + 12.5 easy = 25).
//  - One multiplier per set (say-it-once).
//  - Hero = active rep with units; bottom CTA names the next timeable
//    effort + rest; sections carry inline totals.
//  - DNA: cyan accent (#09d4ee) for active rep + CTA, dark base,
//    status labels in monospaced digits. Native iOS components only —
//    no card-in-disguise if a List row or a Button label earns the slot.

import SwiftUI
import UIKit

// MARK: - Shared palette tokens (cya-from-the-brief + on-brand neutrals)
// These are local to the prototype on purpose — the production
// Hydrolyze palette (HydrolyzeColors.swift) is teal+coral, not cyan.
// Nathan explicitly called cyan #09d4ee as the prototype accent for
// this side-by-side. The CTAs in the prototype use cyan; production
// stays on accentAction. Once a winner is picked the colors fold back
// into HydrolyzeColors under new semantic names.
private enum ProtoPalette {
    static let accent   = Color(red: 0.035, green: 0.831, blue: 0.933) // #09d4ee
    static let bgBase   = Color(red: 0.024, green: 0.055, blue: 0.094) // #060e18
    static let bgRaised = Color.white.opacity(0.05)
    static let divider  = Color.white.opacity(0.08)
    static let textPri  = Color.white
    static let textMuted = Color.white.opacity(0.62)
    static let textFaint = Color.white.opacity(0.42)
    static let past     = Color.white.opacity(0.28) // completed fragments
}

// MARK: - Test workout (locked above)
// Built so each variant renders identically, no variant owns the data.
private struct ProtoRep {
    var ordinal: Int        // 1-based rep index
    var isActive: Bool      // rep the coach is on
    var isCompleted: Bool   // rep done
}

private struct ProtoSet {
    var title: String       // "WARM-UP", "MAIN SET", "COOL-DOWN" + total m
    var reps: Int           // rep count (say-it-once)
    var distance: Int       // per-rep distance
    var stroke: String
    var sendOff: String
    var fragmentText: String? // "12.5 strong / 12.5 easy" or nil for uniform
    var fragmentReps: [ProtoRep]? // when fragmentText != nil, per-fragment reps (4 × 25 strong/easy example is reps=4 distance=25 with per-fragment identity)
    var notes: [String]
    var intensity: String   // "smooth" / "race rhythm" / "100 pace" / "easy"
    var progressState: ProgressState
    enum ProgressState { case past, active(rep: Int, of: Int), next, future }
}

private struct WorkoutFixture {
    let title = "Session — Tuesday"
    let totalM = 1500
    let warmup = [
        ProtoSet(
            title: "WARM-UP · 400 m",
            reps: 4, distance: 100, stroke: "Free",
            sendOff: "on 1:30",
            fragmentText: nil, fragmentReps: nil,
            notes: ["smooth", "focus on length"],
            intensity: "smooth",
            progressState: .past
        )
    ]
    let main = [
        ProtoSet(
            title: "MAIN SET · 800 m",
            reps: 4, distance: 25, stroke: "Free",
            sendOff: "on :45",
            fragmentText: "12.5 strong / 12.5 easy",
            fragmentReps: [
                ProtoRep(ordinal: 1, isActive: false, isCompleted: true),
                ProtoRep(ordinal: 2, isActive: true,  isCompleted: false),
                ProtoRep(ordinal: 3, isActive: false, isCompleted: false),
                ProtoRep(ordinal: 4, isActive: false, isCompleted: false),
            ],
            notes: ["descend 1–4", "race rhythm"],
            intensity: "race rhythm",
            progressState: .active(rep: 2, of: 4)
        ),
        ProtoSet(
            title: "MAIN SET · 800 m",
            reps: 8, distance: 50, stroke: "Free",
            sendOff: "on 1:15",
            fragmentText: nil, fragmentReps: nil,
            notes: ["100 pace"],
            intensity: "100 pace",
            progressState: .next
        ),
        ProtoSet(
            title: "MAIN SET · 800 m",
            reps: 3, distance: 100, stroke: "IM",
            sendOff: "on 1:30",
            fragmentText: nil, fragmentReps: nil,
            notes: ["smooth"],
            intensity: "smooth",
            progressState: .future
        ),
    ]
    let cooldown = [
        ProtoSet(
            title: "COOL-DOWN · 300 m",
            reps: 1, distance: 300, stroke: "Choice",
            sendOff: "",
            fragmentText: nil, fragmentReps: nil,
            notes: ["easy"],
            intensity: "easy",
            progressState: .future
        )
    ]
}

private let fixture = WorkoutFixture()

// MARK: - Entry point — segmented picker routes to each variant
struct WorkoutPagePrototypeView: View {
    @State private var variant: Variant = {
        // V0.55 proto (2026-09-23): default variant chosen by
        // launch arg so each capture is a single relaunch.
        // -prototype-workout-page        → Native List (default)
        // -prototype-workout-page=typed  → Typed Scroll
        // -prototype-workout-page=free   → Free
        let args = ProcessInfo.processInfo.arguments
        for a in args where a.hasPrefix("-prototype-workout-page") {
            let v = a.dropFirst("-prototype-workout-page".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "="))
            switch v {
            case "typed":  return .typedScroll
            case "free":   return .freeChoice
            default:       return .nativeList
            }
        }
        return .nativeList
    }()

    enum Variant: String, CaseIterable, Identifiable {
        case nativeList       = "Native List"
        case typedScroll      = "Typed Scroll"
        case freeChoice       = "Free"
        var id: String { rawValue }
    }

    var body: some View {
        // The picker lives INSIDE the view so a single launch arg can
        // reach all three — switching variants is a single segmented
        // tap instead of relaunching the app three times.
        ZStack {
            ProtoPalette.bgBase.ignoresSafeArea()
            VStack(spacing: 0) {
                picker
                switch variant {
                case .nativeList:  NativeListVariant(workout: fixture)
                case .typedScroll: TypedScrollVariant(workout: fixture)
                case .freeChoice:  FreeChoiceVariant(workout: fixture)
                }
            }
        }
        .statusBarHidden(false)
        .preferredColorScheme(.dark)
    }

    private var picker: some View {
        Picker("Variant", selection: $variant) {
            ForEach(Variant.allCases) { v in
                Text(v.rawValue).tag(v)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(ProtoPalette.bgBase)
    }
}

// MARK: - Variant 1 — Native List
// "Let iOS do the grouping." InsetGrouped List + Section headers give
// us free swipe affordances, free accessibility, free safe area. The
// bottom CTA is `.toolbar` so it respects landscape / Dynamic Island
// without us having to think about insets. Insight here is that a
// structured-data screen actually wants the system look, not custom
// chrome — the chrome competes with the data.
private struct NativeListVariant: View {
    let workout: WorkoutFixture

    var body: some View {
        // Visible bottom-safe CTA — names the next timeable fragment.
        // (List rows end at the safe-area edge; safeAreaInset keeps the
        // CTA reachable with a wet thumb without floating over content
        // mid-scroll.)
        List {
            Section {
                ForEach(Array(workout.warmup.enumerated()), id: \.offset) { _, s in
                    SetRow(set: s)
                }
            } header: {
                Text("WARM-UP · 400 m")
                    .font(.footnote).foregroundStyle(ProtoPalette.textMuted)
            }
            Section {
                ForEach(Array(workout.main.enumerated()), id: \.offset) { _, s in
                    SetRow(set: s)
                }
            } header: {
                Text("MAIN SET · 800 m")
                    .font(.footnote).foregroundStyle(ProtoPalette.textMuted)
            }
            Section {
                ForEach(Array(workout.cooldown.enumerated()), id: \.offset) { _, s in
                    SetRow(set: s)
                }
            } header: {
                Text("COOL-DOWN · 300 m")
                    .font(.footnote).foregroundStyle(ProtoPalette.textMuted)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(ProtoPalette.bgBase)
        .safeAreaInset(edge: .bottom) {
            BottomCTA(workout: workout)
        }
    }
}

private struct SetRow: View {
    let set: ProtoSet

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Reps × distance — say-it-once. (fact 83)
            HStack(spacing: 6) {
                Text("\(set.reps)×")
                    .font(.system(.title3, design: .default).weight(.semibold).monospacedDigit())
                    .foregroundStyle(isActive ? ProtoPalette.accent : ProtoPalette.textPri)
                Text("\(set.distance) m")
                    .font(.system(.title3, design: .default).weight(.semibold).monospacedDigit())
                    .foregroundStyle(isActive ? ProtoPalette.accent : ProtoPalette.textPri)
                Text(set.stroke)
                    .font(.callout).foregroundStyle(ProtoPalette.textMuted)
                Spacer(minLength: 8)
                if !set.sendOff.isEmpty {
                    Text(set.sendOff)
                        .font(.footnote.monospaced())
                        .foregroundStyle(ProtoPalette.textMuted)
                }
            }
            // Fragment math + verbatim cues (live only when present)
            if let f = set.fragmentText {
                Text(f)
                    .font(.footnote)
                    .foregroundStyle(ProtoPalette.textMuted)
                // Visible sum: 12.5 + 12.5 = 25 (per fragment block)
                HStack(spacing: 4) {
                    Text("12.5 strong").foregroundStyle(ProtoPalette.textFaint)
                    Text("+").foregroundStyle(ProtoPalette.textFaint)
                    Text("12.5 easy").foregroundStyle(ProtoPalette.textFaint)
                    Text("= 25 m").foregroundStyle(ProtoPalette.accent)
                }
                .font(.footnote.monospaced())
            }
            ForEach(set.notes, id: \.self) { n in
                Text(n).font(.footnote).foregroundStyle(ProtoPalette.textMuted)
            }
            // Per-fragment identity strip (active set only).
            if let reps = set.fragmentReps {
                HStack(spacing: 4) {
                    ForEach(reps, id: \.ordinal) { r in
                        Text("\(r.ordinal)")
                            .font(.system(.footnote, design: .monospaced).weight(.semibold))
                            .frame(minWidth: 28, minHeight: 28)
                            .background(
                                r.isActive ? ProtoPalette.accent : (r.isCompleted ? ProtoPalette.past : ProtoPalette.bgRaised)
                            )
                            .foregroundStyle(r.isActive ? ProtoPalette.bgBase : ProtoPalette.textPri)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var isActive: Bool {
        if case .active = set.progressState { return true }
        return false
    }
}

private struct BottomCTA: View {
    let workout: WorkoutFixture
    var nextTimeable: ProtoSet? {
        workout.main.first {
            if case .active = $0.progressState { return false }
            if case .next = $0.progressState { return true }
            return false
        }
    }
    var restSeconds: Int { 15 }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            } label: {
                HStack {
                    Image(systemName: "play.fill")
                    Text("Start ")
                        .font(.headline)
                    + Text(nextTimeable.map { "· \($0.reps)×\($0.distance) m \($0.stroke) — \($0.intensity)" }
                            ?? "· next timeable")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 48)
                .padding(.horizontal, 16)
                .background(ProtoPalette.accent)
                .foregroundStyle(ProtoPalette.bgBase)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            VStack(spacing: 2) {
                Text("REST").font(.caption2.weight(.semibold)).foregroundStyle(ProtoPalette.textFaint)
                Text(":\(String(format: "%02d", restSeconds))").font(.title3.monospacedDigit()).foregroundStyle(ProtoPalette.textPri)
            }
            .frame(width: 72, height: 48)
            .background(ProtoPalette.bgRaised)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Variant 2 — Typed ScrollView
// Hero block with system largeTitle weight, monospaced status labels.
// Insight: a typed-scroll archetype proves that "more chrome, more
// good" can backfire on a phone screen — content should dominate
// above the fold, chrome should retreat. If this variant wins, it
// means the data wants presence, not cards.
private struct TypedScrollVariant: View {
    let workout: WorkoutFixture

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero
                ForEach(workout.warmup.indices, id: \.self) { i in
                    section(title: workout.warmup[i].title) {
                        SetBlock(set: workout.warmup[i])
                    }
                }
                ForEach(workout.main.indices, id: \.self) { i in
                    section(title: workout.main[i].title) {
                        SetBlock(set: workout.main[i])
                    }
                }
                ForEach(workout.cooldown.indices, id: \.self) { i in
                    section(title: workout.cooldown[i].title) {
                        SetBlock(set: workout.cooldown[i])
                    }
                }
                Spacer(minLength: 32)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .background(ProtoPalette.bgBase)
        .safeAreaInset(edge: .bottom) {
            BottomCTA(workout: workout)
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("NOW")
                .font(.caption.weight(.semibold))
                .foregroundStyle(ProtoPalette.accent)
                .monospaced()
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("REP 2 OF 4")
                    .font(.system(.largeTitle, design: .default).weight(.semibold))
                    .foregroundStyle(ProtoPalette.accent)
                    .monospacedDigit()
                Text("· 25 m free")
                    .font(.title3)
                    .foregroundStyle(ProtoPalette.textPri)
            }
            Text("race rhythm · :45 send-off")
                .font(.subheadline)
                .foregroundStyle(ProtoPalette.textMuted)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.footnote.weight(.semibold))
                .foregroundStyle(ProtoPalette.textMuted)
                .monospaced()
            Divider().overlay(ProtoPalette.divider)
            content()
        }
    }
}

private struct SetBlock: View {
    let set: ProtoSet
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(set.reps)×")
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(isActive ? ProtoPalette.accent : ProtoPalette.textPri)
                Text("\(set.distance) m")
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(isActive ? ProtoPalette.accent : ProtoPalette.textPri)
                Text(set.stroke)
                    .font(.callout)
                    .foregroundStyle(ProtoPalette.textMuted)
                Spacer(minLength: 8)
                Text(set.sendOff)
                    .font(.footnote.monospaced())
                    .foregroundStyle(ProtoPalette.textMuted)
            }
            if let f = set.fragmentText {
                Text(f).font(.footnote).foregroundStyle(ProtoPalette.textMuted)
            }
            ForEach(set.notes, id: \.self) { n in
                Text(n).font(.footnote).foregroundStyle(ProtoPalette.textMuted)
            }
        }
    }
    private var isActive: Bool {
        if case .active = set.progressState { return true }
        return false
    }
}

// MARK: - Variant 3 — Free choice
// Best-guess mobile form factor: thumb zones, bottom-anchored CTA,
// per-set tap targets ≥44pt, native Label/Button/Divider rather
// than custom shapes. The active set gets the only chrome — every
// other set is a plain row. The rep identity (a b c d) is a
// segmented ProgressView-style strip, not checkmarks. Insight: the
// active set does most of the cognitive load; the rest can scroll.
private struct FreeChoiceVariant: View {
    let workout: WorkoutFixture

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ProgressHeader(workout: workout)
                ForEach(workout.warmup.indices, id: \.self) { i in
                    sectionHeader(workout.warmup[i].title)
                    SetRowFree(set: workout.warmup[i], isHero: false)
                }
                ForEach(workout.main.indices, id: \.self) { i in
                    sectionHeader(workout.main[i].title)
                    SetRowFree(set: workout.main[i], isHero: isHero(workout.main[i]))
                }
                ForEach(workout.cooldown.indices, id: \.self) { i in
                    sectionHeader(workout.cooldown[i].title)
                    SetRowFree(set: workout.cooldown[i], isHero: false)
                }
                Spacer(minLength: 32)
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
        }
        .background(ProtoPalette.bgBase)
        .safeAreaInset(edge: .bottom) {
            BottomCTA(workout: workout)
        }
    }

    private func isHero(_ s: ProtoSet) -> Bool {
        if case .active = s.progressState { return true }
        return false
    }

    private func sectionHeader(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.footnote.weight(.semibold))
            .foregroundStyle(ProtoPalette.textMuted)
            .monospaced()
    }
}

private struct ProgressHeader: View {
    let workout: WorkoutFixture
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NOW · REP 2 OF 4")
                .font(.system(.title, design: .default).weight(.bold).monospaced())
                .foregroundStyle(ProtoPalette.accent)
            Text("25 m free · descend 1–4 · race rhythm")
                .font(.subheadline)
                .foregroundStyle(ProtoPalette.textMuted)
            // Coach-voice verbatim + math line.
            HStack(spacing: 6) {
                Text("12.5 strong").foregroundStyle(ProtoPalette.textPri)
                Text("+").foregroundStyle(ProtoPalette.textFaint)
                Text("12.5 easy").foregroundStyle(ProtoPalette.textPri)
                Text("= 25 m").foregroundStyle(ProtoPalette.accent)
            }
            .font(.footnote.monospaced())
            Divider().overlay(ProtoPalette.divider).padding(.top, 4)
        }
    }
}

private struct SetRowFree: View {
    let set: ProtoSet
    let isHero: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label {
                    Text("\(set.reps)× \(set.distance) m \(set.stroke)")
                        .font(.headline.monospacedDigit())
                } icon: {
                    Image(systemName: "figure.pool.swim")
                        .foregroundStyle(ProtoPalette.accent)
                }
                Spacer(minLength: 8)
                Text(set.intensity)
                    .font(.footnote.weight(.semibold).monospaced())
                    .foregroundStyle(isHero ? ProtoPalette.accent : ProtoPalette.textMuted)
            }
            if !set.sendOff.isEmpty {
                Text(set.sendOff).font(.footnote.monospaced()).foregroundStyle(ProtoPalette.textMuted)
            }
            if let f = set.fragmentText {
                Text(f).font(.footnote).foregroundStyle(ProtoPalette.textMuted)
            }
            // Per-rep identity strip (only on hero set so the rest can
            // scroll). Each pill is a real Button so haptics + tap
            // targets come for free from UIKit.
            if let reps = set.fragmentReps, isHero {
                HStack(spacing: 6) {
                    ForEach(reps, id: \.ordinal) { r in
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            Text("\(r.ordinal)")
                                .font(.system(.headline, design: .monospaced).weight(.semibold))
                                .frame(width: 48, height: 48)
                                .background(r.isActive ? ProtoPalette.accent : (r.isCompleted ? ProtoPalette.past : ProtoPalette.bgRaised))
                                .foregroundStyle(r.isActive ? ProtoPalette.bgBase : ProtoPalette.textPri)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 2)
            }
            ForEach(set.notes.filter { $0 != set.intensity }, id: \.self) { n in
                Text(n).font(.footnote).foregroundStyle(ProtoPalette.textMuted)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, isHero ? 0 : 0)
        .opacity(isHero ? 1.0 : 0.92)
    }
}
#endif
