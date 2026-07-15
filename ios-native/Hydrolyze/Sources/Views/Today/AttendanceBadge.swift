import SwiftUI

/// AttendanceBadge — the "X / Y swimmers marked attending" pill
/// that lives below the WorkoutCard on the coach's Today view.
/// Non-intrusive (thin pill, soft colors). Tap opens the
/// AttendancePopover for inline editing.
///
/// ponytail:
///   - The badge is a single horizontal pill. Cyan when swimmers
///     are marked, amber when none have marked yet. Same color
///     vocabulary as the rest of the app.
///   - No haptic on count change. Visual only — the badge is
///     ambient info, not an action surface.
struct AttendanceBadge: View {
    let attendingCount: Int
    let totalCount: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    private var displayText: String {
        if totalCount == 0 {
            return "No swimmers on squad yet"
        }
        return "\(attendingCount) / \(totalCount) attending"
    }

    private var accent: Color {
        if totalCount == 0 { return Color.accentSlate }
        if attendingCount == 0 { return Color.accentAmber }
        return Color.accentCyanDim
    }

    var body: some View {
        HStack(spacing: 8) {
            // ponytail: breathing when swimmers have responded.
            // 1.0 -> 1.15 -> 1.0 on 2s cycle. The dot literally
            // responds to the squad. Same phaseAnimator pattern as
            // SwimmersListView.emptyState.
            Image(systemName: attendingCount > 0 ? "checkmark.circle.fill" : "person.2")
                .font(.caption)
                .foregroundStyle(accent)
                .phaseAnimator([1.0, 1.15, 1.0]) { content, scale in
                    content.scaleEffect(scale)
                } animation: { _ in
                    reduceMotion ? .linear(duration: 0.01) : .easeInOut(duration: 2.0)
                }
            Text(displayText)
                .font(.captionStrong)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.eyebrow)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(accent.opacity(0.3), lineWidth: 1)
        )
    }
}

/// AttendancePopoverContent — the body of the popover that opens
/// when the coach taps the badge. Lists every squad swimmer with
/// three states: marked in / marked out / unmarked. Coach can flip
/// anyone's intent with a single tap.
///
/// ponytail:
///   - The popover is a SwiftUI `.popover()`, not a sheet. Sheet
///     would steal the coach's focus; popover stays inline.
///   - The flip is a single tap on the row's right-side pill.
///     Already-correct intent shows that side filled.
///   - The "Add swimmer not on squad" affordance is NOT in this
///     version. Coach edit stays inside the existing roster.
struct AttendancePopoverContent: View {
    let entries: [CoachAttendanceEntry]
    let onSetIntent: (String, String) async -> Void  // swimmerId, intent

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Attendance")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                Text("\(inCount) / \(entries.count) attending")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Divider().background(Color.white.opacity(0.08))

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(entries) { entry in
                        AttendanceRow(entry: entry, onSetIntent: onSetIntent)
                    }
                }
            }
            .frame(maxHeight: 360)
        }
        .padding(16)
        .frame(minWidth: 320)
        .background(Color.bgSunken)
    }

    private var inCount: Int {
        entries.filter { $0.intent == "in" }.count
    }
}

/// AttendanceRow — one swimmer in the popover. Name on the left,
/// three-state intent toggle on the right.
private struct AttendanceRow: View {
    let entry: CoachAttendanceEntry
    let onSetIntent: (String, String) async -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Name + status indicator
            HStack(spacing: 8) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                Text(entry.swimmerName)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
            }
            Spacer()
            // Three-pill toggle
            HStack(spacing: 4) {
                MiniPill(
                    label: "In",
                    isSelected: entry.intent == "in",
                    color: Color.accentCyanDim,
                    action: { Task { await onSetIntent(entry.swimmerId, "in") } }
                )
                MiniPill(
                    label: "Out",
                    isSelected: entry.intent == "out",
                    color: Color.accentSlate,
                    action: { Task { await onSetIntent(entry.swimmerId, "out") } }
                )
            }
        }
        .padding(.vertical, 4)
    }

    private var dotColor: Color {
        switch entry.intent {
        case "in": return Color.accentCyanDim
        case "out": return Color.accentSlate
        default: return Color.white.opacity(0.2)
        }
    }
}

/// MiniPill — single-segment toggle. Same vocabulary as the
/// swimmer-side IntentPill but smaller (one swimmer per row).
private struct MiniPill: View {
    let label: String
    let isSelected: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? Color.bgBase : .white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(isSelected ? color : Color.white.opacity(0.06))
                )
        }
        .buttonStyle(PressFeedbackStyle())
    }
}