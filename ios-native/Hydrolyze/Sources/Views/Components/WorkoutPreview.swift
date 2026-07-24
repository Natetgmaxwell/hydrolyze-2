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
                        onRemoveRepGroup: onRemoveRepGroup
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
                            onRemoveRepGroup: onRemoveRepGroup
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
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
                    GearBadge(gear: gear, optional: rg.gearOptional)
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
        guard let dsRep = rg.pattern.first(where: { $0.type == "drill_swim" }),
              case .drillSwim(let ds) = dsRep else { return nil }
        var parts: [String] = []
        if let d = ds.drillMeters { parts.append("\(d) dr") }
        if let s = ds.swimMeters { parts.append("\(s) sw") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var oddEvenLines: [(label: String, text: String)]? {
        guard rg.patternType == "odd_even" else { return nil }
        guard let oeRep = rg.pattern.first(where: { $0.type == "odd_even" }),
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
    var pattern: [ParsedRep]
    var patternType: String?
    var connectors: [String]?
    var note: String?
    var gear: [String]?
    var gearOptional: Bool
    var descend: String?
    var details: [String]?
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
                                        descend: nil, details: nil
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
                                        descend: "1-4", details: nil
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