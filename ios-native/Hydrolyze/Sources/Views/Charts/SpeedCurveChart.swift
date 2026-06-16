import SwiftUI
import Charts

/// SpeedCurveChart — scatter plot of a swimmer's recorded times with a
/// fitted linear regression line. Uses least-squares fit on (index, timeMs)
/// to project the trend.
struct SpeedCurveChart: View {
    let times: [RecordedTime]

    private struct Point: Identifiable {
        let id: String
        let xIndex: Int
        let timeMs: Int
    }

    private var parsedPoints: [Point] {
        let sorted = times.sorted { ($0.createdAt) < ($1.createdAt) }
        return sorted.enumerated().map { idx, t in
            Point(id: t.id, xIndex: idx, timeMs: t.timeMs)
        }
    }

    private struct RegressionLine: Identifiable {
        let id: String
        let startX: Int
        let endX: Int
        let startY: Int
        let endY: Int
    }

    private var regression: RegressionLine? {
        let pts = parsedPoints
        guard pts.count >= 2 else { return nil }
        let n = Double(pts.count)
        let xs = pts.map { Double($0.xIndex) }
        let ys = pts.map { Double($0.timeMs) }
        let sumX = xs.reduce(0, +)
        let sumY = ys.reduce(0, +)
        let sumXY = zip(xs, ys).map { $0 * $1 }.reduce(0, +)
        let sumXX = xs.map { $0 * $0 }.reduce(0, +)
        let denom = n * sumXX - sumX * sumX
        guard denom != 0 else { return nil }
        let slope = (n * sumXY - sumX * sumY) / denom
        let intercept = (sumY - slope * sumX) / n
        guard let firstX = pts.first?.xIndex, let lastX = pts.last?.xIndex else { return nil }
        let startY = Int(slope * Double(firstX) + intercept)
        let endY = Int(slope * Double(lastX) + intercept)
        return RegressionLine(
            id: "regression",
            startX: firstX, endX: lastX,
            startY: max(0, startY), endY: max(0, endY)
        )
    }

    var body: some View {
        if parsedPoints.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "chart.dots.scatter")
                    .font(.system(size: 32))
                    .foregroundColor(Color(hex: "4a6572"))
                Text("No data points")
                    .font(.system(size: 14))
                    .foregroundColor(Color(hex: "7a9bb0"))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        } else {
            Chart {
                ForEach(parsedPoints) { p in
                    PointMark(
                        x: .value("Session", p.xIndex),
                        y: .value("Time (ms)", p.timeMs)
                    )
                    .foregroundStyle(Color(hex: "09d4ee"))
                    .symbolSize(40)
                }

                if let reg = regression {
                    LineMark(
                        x: .value("Session", reg.startX),
                        y: .value("Time (ms)", reg.startY),
                        series: .value("Series", "regression")
                    )
                    .foregroundStyle(Color(hex: "f59e0b"))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))

                    LineMark(
                        x: .value("Session", reg.endX),
                        y: .value("Time (ms)", reg.endY),
                        series: .value("Series", "regression")
                    )
                    .foregroundStyle(Color(hex: "f59e0b"))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
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
