import SwiftUI
import Charts

/// TrendChart — bar chart of per-rep times in a single session.
/// X: rep index, Y: timeMs, per-swimmer color grouping.
struct TrendChart: View {
    let times: [RecordedTime]

    private struct RepBucket: Identifiable {
        let id: String
        let repIndex: Int
        let swimmerId: String
        let timeMs: Int
    }

    private var buckets: [RepBucket] {
        times
            .filter { $0.swimmerId != nil }
            .map { t in
                RepBucket(
                    id: "\(t.swimmerId ?? "x")-\(t.repIndex)-\(t.id)",
                    repIndex: t.repIndex,
                    swimmerId: t.swimmerId ?? "unknown",
                    timeMs: t.timeMs
                )
            }
            .sorted { $0.repIndex < $1.repIndex }
    }

    private var swimmerColorMap: [String: Color] {
        let palette: [Color] = [
            Color(hex: "09d4ee"),
            Color(hex: "10b981"),
            Color(hex: "f59e0b"),
            Color(hex: "ef4444"),
            Color(hex: "8b5cf6"),
            Color(hex: "ec4899"),
            Color(hex: "14b8a6")
        ]
        let uniqueIds = Array(Set(buckets.map { $0.swimmerId })).sorted()
        return Dictionary(uniqueKeysWithValues: uniqueIds.enumerated().map { idx, id in
            (id, palette[idx % palette.count])
        })
    }

    var body: some View {
        if buckets.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 32))
                    .foregroundColor(Color(hex: "4a6572"))
                Text("No rep data")
                    .font(.system(size: 14))
                    .foregroundColor(Color(hex: "7a9bb0"))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        } else {
            Chart(buckets) { bucket in
                BarMark(
                    x: .value("Rep", bucket.repIndex),
                    y: .value("Time (ms)", bucket.timeMs)
                )
                .foregroundStyle(by: .value("Swimmer", bucket.swimmerId))
                .position(by: .value("Swimmer", bucket.swimmerId))
            }
            .chartForegroundStyleScale(domain: swimmerColorMap.keys.sorted(),
                                       range: swimmerColorMap.values.sorted(by: { _, _ in true }))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: buckets.map { $0.repIndex }.max() ?? 4)) { _ in
                    AxisGridLine().foregroundStyle(Color(hex: "1a2d42"))
                    AxisValueLabel()
                        .foregroundStyle(Color(hex: "7a9bb0"))
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(Color(hex: "1a2d42"))
                    AxisValueLabel {
                        if let ms = value.as(Int.self) {
                            Text(formatMs(ms))
                                .foregroundColor(Color(hex: "7a9bb0"))
                        }
                    }
                }
            }
            .frame(height: 200)
            .padding(.horizontal, 4)
        }
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
}
