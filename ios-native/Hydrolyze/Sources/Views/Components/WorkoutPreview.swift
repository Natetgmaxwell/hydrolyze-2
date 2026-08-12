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
    var recordedTimesByFragmentId: [String: Int]? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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
                        recordedTimesByFragmentId: recordedTimesByFragmentId
                    )
                }
            }
        }
    }
}

private struct SectionView: View {
    let section: ParsedSection
    let sectionIndex: Int
    let onRemoveRepGroup: ((Int, Int, Int) -> Void)?
    let onFragmentTap: ((Int, Int, Int, Int, ParsedFragment) -> Void)?
    let recordedTimesByFragmentId: [String: Int]?

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
                            .foregroundColor(Color.accentCyan)
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
                            recordedTimesByFragmentId: recordedTimesByFragmentId
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
    let recordedTimesByFragmentId: [String: Int]?

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
                            .foregroundColor(Color.accentCyan)
                    }

                    if let intensity = rg.intensity {
                        Text(" @ \(fmtIntensity(intensity))")
                            .font(.caption)
                            .foregroundColor(Color.accentAmber)
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
                        MetadataBadge(text: "SUIT", color: Color.accentCyan)
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
                        }
                    )
                } else {
                    ForEach(Array(fragments.enumerated()), id: \.offset) { fIdx, f in
                        FragmentCTARow(
                            fragment: f,
                            reps: rg.reps,
                            paceTargetText: rg.interval,
                            recordedMs: recordedMsForFragment(f, in: recordedTimesByFragmentId),
                            onTap: onFragmentTap.map { handler in
                                { handler(sectionIndex, namedSetIndex, repGroupIndex, fIdx, f) }
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
            .foregroundColor(Color.accentCyan)
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
    case easy, aerobic, threshold, race_pace, pace_target, sprint, descend, build, negative_split, percent_range
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
        sourceLine: String? = nil
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
    let recordedMs: Int?
    // V0.35 (2026-08-12): nil = static row (builder preview). Renders
    // the same fragment metadata but is not tappable and shows no play
    // icon — the detail view owns timing.
    let onTap: (() -> Void)?

    var body: some View {
        let content = HStack(spacing: 8) {
            Rectangle()
                .fill(Color.accentCyan)
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
                            .foregroundColor(Color.accentCyan)
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
                    if let start = fragment.startType, !start.isEmpty {
                        MetadataBadge(text: start.uppercased(), color: Color.textMuted)
                    }
                    if let pace = paceTargetText, !pace.isEmpty {
                        // Pace target = the rep group's interval
                        // (send-off or "1:30"). Surfaced as a
                        // cyan badge so it reads as a target, not
                        // a constraint.
                        MetadataBadge(text: "@ \(pace)", color: Color.accentCyan)
                    }
                    if fragment.suit == true {
                        MetadataBadge(text: "SUIT", color: Color.accentCyan)
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
                if let ms = recordedMs {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(Color.statusSuccess)
                        Text("Saved \(formatStopwatchTime(ms))")
                            .font(.captionStrong)
                            .foregroundColor(Color.statusSuccess)
                    }
                }
            }
            Spacer()
            // t_d59998d9 (2026-08-05): if a recording exists, swap
            // the play icon for a dim re-tap icon so the row still
            // reads as actionable ("tap to retime"). The Saved
            // check above carries the affirmative state.
            if onTap != nil {
                Image(systemName: recordedMs != nil ? "arrow.counterclockwise.circle" : "play.circle.fill")
                    .foregroundColor(recordedMs != nil ? Color.textMuted : Color.accentCyan)
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
    let recordedTimesByFragmentId: [String: Int]?
    // V0.35 (2026-08-12): nil = static rows (builder preview).
    let onFragmentTap: ((Int, ParsedFragment) -> Void)?

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
                    recordedMs: recordedMsForFragment(f, in: recordedTimesByFragmentId),
                    onTap: onFragmentTap.map { handler in
                        { handler(fIdx, f) }
                    }
                )
            }
        }
    }
}

// t_d59998d9 (2026-08-05): resolve recorded ms for a fragment from the
// WorkoutDetailView-held map. Looks up by fragment.id, then falls back
// to descriptor+distance+intensity as a soft key so a row that lost its
// id (older builds) still finds its recorded time. nil = no recording.
private func recordedMsForFragment(_ fragment: ParsedFragment, in map: [String: Int]?) -> Int? {
    guard let map = map, !map.isEmpty else { return nil }
    if let id = fragment.id, let ms = map[id] { return ms }
    // Soft-key fallback for rows without an id.
    let softKey = "\(fragment.distance ?? 0)|\(fragment.intensity?.label ?? fragment.descriptor ?? "")|\(fragment.startType ?? "")"
    if let ms = map[softKey] { return ms }
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
            .font(.system(size: 10, weight: .bold))
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