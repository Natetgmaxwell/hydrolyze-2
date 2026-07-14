import SwiftUI

/// WorkoutPreview — renders a parsed Workout tree (Section → NamedSet → RepGroup → Rep).
/// Shared across WorkoutDetailView, TodayView (future), Session screens.
/// Mirrors the RN WorkoutPreview.tsx renderV2Tree structure.
struct WorkoutPreview: View {
    let workout: ParsedWorkout

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if workout.sections.isEmpty {
                Text("No sets defined")
                    .font(.caption)
                    .foregroundColor(Color.textFaint)
                    .italic()
            } else {
                ForEach(Array(workout.sections.enumerated()), id: \.offset) { _, section in
                    SectionView(section: section)
                }
            }
        }
    }
}

private struct SectionView: View {
    let section: ParsedSection

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

            ForEach(Array(section.namedSets.enumerated()), id: \.offset) { _, namedSet in
                VStack(alignment: .leading, spacing: 8) {
                    if let label = namedSet.label, !label.isEmpty {
                        Text(label.uppercased())
                            .font(.eyebrow)
                            .foregroundColor(Color.accentCyan)
                            .tracking(0.8)
                    }

                    ForEach(Array(namedSet.repGroups.enumerated()), id: \.offset) { _, rg in
                        RepGroupRowView(rg: rg)
                    }
                }
                .padding(.leading, 8)
            }
        }
    }
}

private struct RepGroupRowView: View {
    let rg: ParsedRepGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
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

                if let interval = rg.interval {
                    Text(" on \(interval)")
                        .font(.system(size: 12))
                        .foregroundColor(Color.textFaint)
                }

                if let note = rg.note {
                    Text(" \(note)")
                        .font(.system(size: 12))
                        .foregroundColor(Color.textFaint)
                        .italic()
                }

                ForEach(rg.gear ?? [], id: \.self) { gear in
                    GearBadge(gear: gear, optional: rg.gearOptional)
                }

                ForEach(cleanDetails, id: \.self) { detail in
                    DetailBadge(text: detail)
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
    }

    private var spineText: String {
        if let reps = rg.reps, let distance = rg.distance {
            return "\(reps)×\(distance)m"
        } else if let distance = rg.distance {
            return "\(distance)m"
        }
        return ""
    }

    private var cleanDetails: [String] {
        (rg.details ?? []).filter { detail in
            !detail.hasPrefix("~") && detail.lowercased() != "optional" && detail.lowercased() != "as"
        }
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