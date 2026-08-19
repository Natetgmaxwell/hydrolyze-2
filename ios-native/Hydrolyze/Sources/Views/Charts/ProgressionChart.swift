import SwiftUI
import Charts

/// ProgressionChart — line chart of a swimmer's time history for a specific
/// distance/stroke. Dot mark with size encoded by rep position, color by
/// fatigue gradient, PB shown as a horizontal RuleMark.
struct ProgressionChart: View {
    let times: [RecordedTime]
    let personalBestMs: Int?

    private struct ChartEntry: Identifiable {
        let id = UUID()
        let date: Date
        let timeMs: Int
        let repIndex: Int
        let intensity: String
    }

    private var entries: [ChartEntry] {
        return times.compactMap { t in
            guard let date = ISO8601DateParser.parse(t.createdAt) else { return nil }
            return ChartEntry(
                date: date,
                timeMs: t.timeMs,
                repIndex: t.repIndex,
                intensity: t.intensity
            )
        }
    }

    private var maxRepIndex: Int {
        max(entries.map { $0.repIndex }.max() ?? 1, 1)
    }

    private func fatigueColor(for intensity: String) -> Color {
        let i = intensity.lowercased()
        if i.contains("easy") || i.contains("recovery") || i.contains("warm") {
            return Color.statusSuccess
        } else if i.contains("moderate") || i.contains("tempo") || i.contains("steady") {
            return Color.textMuted
        } else if i.contains("threshold") || i.contains("race") {
            return Color.accentAmber
        } else if i.contains("sprint") || i.contains("max") {
            return Color.statusError
        }
        return Color.textMuted
    }

    private func symbolSize(for repIndex: Int) -> CGFloat {
        let ratio = Double(repIndex) / Double(maxRepIndex)
        return CGFloat(ratio * 120 + 40)
    }

    private func formatMs(_ ms: Int) -> String {
        let totalSeconds = Double(ms) / 1000.0
        let minutes = Int(totalSeconds) / 60
        let seconds = totalSeconds.truncatingRemainder(dividingBy: 60)
        if minutes > 0 {
            return String(format: "%d:%05.2f", minutes, seconds)
        }
        return String(format: "%.2f", seconds)
    }

    var body: some View {
        if entries.isEmpty {
            emptyState
        } else {
            chartContent
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 32))
                .foregroundColor(Color.textFaint)
            Text("No times yet")
                .font(.system(size: 14))
                .foregroundColor(Color.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private var chartContent: some View {
        Chart {
            ForEach(entries) { entry in
                LineMark(
                    x: .value("Date", entry.date),
                    y: .value("Time (ms)", entry.timeMs)
                )
                .foregroundStyle(Color.textMuted)
                .interpolationMethod(.monotone)
            }

            ForEach(entries) { entry in
                PointMark(
                    x: .value("Date", entry.date),
                    y: .value("Time (ms)", entry.timeMs)
                )
                .foregroundStyle(fatigueColor(for: entry.intensity))
                .symbolSize(symbolSize(for: entry.repIndex))
            }

            if let pbMs = personalBestMs {
                RuleMark(y: .value("PB", pbMs))
                    .foregroundStyle(Color.statusSuccess)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("PB \(formatMs(pbMs))")
                            .font(.numericSmall)
                            .foregroundColor(Color.statusSuccess)
                    }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Color.bgInset)
                AxisValueLabel()
                    .font(.numericSmall)
                    .foregroundStyle(Color.textMuted)
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Color.bgInset)
                AxisValueLabel {
                    if let ms = value.as(Int.self) {
                        Text(formatMs(ms))
                            .font(.numericSmall)
                            .foregroundColor(Color.textMuted)
                    }
                }
            }
        }
        .frame(height: 200)
        .padding(.horizontal, 4)
    }
}
