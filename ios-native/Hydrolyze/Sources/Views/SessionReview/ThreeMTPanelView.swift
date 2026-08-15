import SwiftUI
import Charts

/// ThreeMTPanelView — V0.38 Slice 5 inline 3MT review surface.
///
/// Renders under (or inside) `ReviewRowView` for swimmers who have a
/// `swimmer_test_profiles` row in the active session. The panel
/// shows the three numbers in coach vocabulary ("Top speed",
/// "Threshold pace", "Battery"), the per-split speed curve, the
/// quality flags in coach words, and one colored signal dot per
/// swimmer.
///
/// Spec: V0.38_SPEC.md §Slice 5. Hard constraints from the work
/// order:
///   - Coach vocabulary ONLY. No "anaerobic", no "D'", no confidence
///     percentages, no modal surfaces.
///   - Colors: only the existing tokens in `HydrolyzeColors.swift`.
///   - Types: only existing roles from `HydrolyzeType.swift`.
///   - Non-3MT sessions: never rendered (the VM keeps the
///     `testProfiles` dict empty for non-3MT sessions, so this view
///     is only instantiated when there's a profile row).
///
/// Chart approach mirrors `SwimmerAnalyticsView` /
/// `SpeedCurveChart` / `ProgressionChart`: Apple's `Charts`
/// framework, accentCyan stroke, minimal axes (no legend, no axis
/// labels at this small scale). Sized to ~80pt tall so the panel
/// fits inside the row rhythm without dominating the screen.
struct ThreeMTPanelView: View {
    let profile: SwimmerTestProfile
    let swimmerName: String
    /// V0.38 Slice 5 (2026-08-16): per-split speed array (m/s, in
    /// lap order). The VM derives this from the `recorded_times`
    /// rows for the session (the `swimmer_test_profiles` table
    /// doesn't persist curveShape — see VM's `testProfileCurves`).
    /// When nil, the panel falls back to a two-point sketch from
    /// `profile.peakSpeedMps` and `profile.criticalSpeedMps` so the
    /// chart still reads as "high → low" — defensive against
    /// partial saves or filtered lap rows.
    let curveSpeeds: [Double]?

    init(profile: SwimmerTestProfile, swimmerName: String, curveSpeeds: [Double]? = nil) {
        self.profile = profile
        self.swimmerName = swimmerName
        self.curveSpeeds = curveSpeeds
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow
            curveSection
            statsRow
            if let copy = flagCopy(qualityFlags: profile.qualityFlags) {
                Text(copy)
                    .font(.caption)
                    .foregroundColor(Color.textMuted)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            batteryTrendNote
        }
        .padding(10)
        .background(Color.bgDeep)
        .cornerRadius(8)
        .padding(.top, 4)
    }

    /// V0.38 Slice 5: signal dot (top-left) + swimmer name + trial
    /// caption. One dot per swimmer — the coach scans the review
    /// list and the dot tells them whether the trial is usable at a
    /// glance. Trial number rides next to the name so the coach
    /// knows whether this is a familiarisation run.
    private var headerRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(signalColor)
                .frame(width: 8, height: 8)
            Text(swimmerName)
                .font(.captionStrong)
                .foregroundColor(Color.textPrimary)
                .lineLimit(1)
            Text("Trial \(profile.trialNumber)")
                .font(.caption)
                .foregroundColor(Color.textMuted)
            Spacer()
        }
    }

    /// V0.38 Slice 5: inline speed-vs-time chart from the profile's
    /// per-split speeds. Mirrors the chart approach used in
    /// `SpeedCurveChart` / `ProgressionChart` (Apple Charts
    /// framework, accentCyan stroke, no axes labels beyond minimal).
    /// Sized to ~80pt tall so it reads as a sparkline, not a
    /// full-screen analytics chart.
    private var curveSection: some View {
        let points = curvePoints
        return Chart {
            ForEach(points) { p in
                LineMark(
                    x: .value("Split", p.splitIndex),
                    y: .value("Speed", p.speedMps)
                )
                .foregroundStyle(Color.accentCyan)
                .interpolationMethod(.monotone)
            }
            ForEach(points) { p in
                PointMark(
                    x: .value("Split", p.splitIndex),
                    y: .value("Speed", p.speedMps)
                )
                .foregroundStyle(Color.accentCyan)
                .symbolSize(20)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 80)
    }

    /// V0.38 Slice 5: three numbers stat trio. Compact column-row
    /// layout — Top speed (m/s to 2dp), Threshold pace (per-100m
    /// pace from `thresholdPaceString`), Battery (integer + "m").
    /// All three are pure-function derived from the profile; the
    /// pace string lives in `ThreeMTReviewSupport.swift` so the CLI
    /// test can regression-gate it without a UIKit dependency.
    private var statsRow: some View {
        HStack(alignment: .top, spacing: 12) {
            statTile(
                label: "Top speed",
                value: String(format: "%.2f", profile.peakSpeedMps),
                unit: "m/s"
            )
            statTile(
                label: "Threshold pace",
                value: thresholdPaceString(criticalSpeedMps: profile.criticalSpeedMps)
                    ?? "—",
                unit: ""
            )
            statTile(
                label: "Battery",
                value: String(format: "%.0f", profile.batteryMeters),
                unit: "m"
            )
        }
    }

    /// V0.38 Slice 5: single stat tile — label (caption, textFaint)
    /// over value (numericLarge, textPrimary) with the unit riding
    /// inline as textMuted. Kept private so the panel rhythm stays
    /// in one place.
    private func statTile(label: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.eyebrow)
                .foregroundColor(Color.textFaint)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.numericLarge)
                    .foregroundColor(Color.textPrimary)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.caption)
                        .foregroundColor(Color.textMuted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// V0.38 Slice 5: battery trend note. Single line, eyebrow
    /// style, textFaint. Anchored at the bottom of the panel so the
    /// coach reads it last — the point is "watch the trend, not the
    /// number" (the 3MT D′ underestimates time-trial D′ by ~16%;
    /// mixing test types corrupts the trend).
    private var batteryTrendNote: some View {
        Text("Battery is measured the same way every time — watch the trend, not the number.")
            .font(.caption)
            .foregroundColor(Color.textFaint)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// V0.38 Slice 5: per-split chart points. Sources from the
    /// VM's `testProfileCurves` dict (derived from recorded_times);
    /// falls back to a two-point sketch from peak/CS when the
    /// recorded_times rows are filtered out (defensive). x is the
    /// 1-indexed split number — the coach reads it as "lap N speed".
    private struct ChartPoint: Identifiable {
        let id: Int
        let splitIndex: Int
        let speedMps: Double
    }

    private var curvePoints: [ChartPoint] {
        if let speeds = curveSpeeds, !speeds.isEmpty {
            return speeds.enumerated().map { idx, speed in
                ChartPoint(id: idx, splitIndex: idx + 1, speedMps: speed)
            }
        }
        // Fallback: peak → CS sketch. Two points so the chart reads
        // as "high → low" even when the lap rows aren't available.
        return [
            ChartPoint(id: 0, splitIndex: 1, speedMps: profile.peakSpeedMps),
            ChartPoint(id: 1, splitIndex: 2, speedMps: profile.criticalSpeedMps)
        ]
    }

    /// V0.38 Slice 5: signal color from the coach-facing mapping.
    /// Resolved via `threeMTSignal(profile:)` (in
    /// `ThreeMTReviewSupport.swift`) so the logic is regression-
    /// gated by the CLI test. Only the existing Hydrolyze color
    /// tokens are used: statusSuccess (green), accentAmber,
    /// textFaint (gray), statusError (red).
    private var signalColor: Color {
        switch threeMTSignal(profile: profile) {
        case .green: return Color.statusSuccess
        case .amber: return Color.accentAmber
        case .gray:  return Color.textFaint
        case .red:   return Color.statusError
        }
    }
}
