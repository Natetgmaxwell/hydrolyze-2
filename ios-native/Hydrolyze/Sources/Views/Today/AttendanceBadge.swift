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
        if totalCount == 0 { return Color.textFaint }
        if attendingCount == 0 { return Color.accentAmber }
        return Color.accentActionDim
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
                .foregroundStyle(Color.textMuted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.textPrimary.opacity(0.04))
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
                    .foregroundStyle(Color.textMuted)
            }

            Divider().background(Color.textPrimary.opacity(0.08))

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

    /// v1.17 Slice 4: resolved, not raw. Must agree with the badge that
    /// opened this popover — counting `intent == "in"` here while the badge
    /// counts resolved attendance would show the coach two different numbers
    /// one tap apart.
    private var inCount: Int {
        entries.filter(\.isAttending).count
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
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.swimmerName)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                    // Why this swimmer counts the way they do. "usual
                    // session" vs "said they're in" warrant different
                    // levels of trust when the coach decides to override.
                    Text(entry.provenanceLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.textFaint)
                        .lineLimit(1)
                }
            }
            Spacer()
            // Three-pill toggle
            HStack(spacing: 4) {
                MiniPill(
                    label: "In",
                    isSelected: entry.intent == "in",
                    color: Color.accentActionDim,
                    action: { Task { await onSetIntent(entry.swimmerId, "in") } }
                )
                MiniPill(
                    label: "Out",
                    isSelected: entry.intent == "out",
                    color: Color.textFaint,
                    action: { Task { await onSetIntent(entry.swimmerId, "out") } }
                )
            }
        }
        .padding(.vertical, 4)
    }

    /// v1.17 Slice 4: the dot reflects RESOLVED attendance, so a swimmer
    /// attending via their standing pattern shows the same colour as one
    /// who marked in — matching what the badge counts. Reading raw `intent`
    /// here would show a grey "unmarked" dot next to a swimmer the badge
    /// has already counted as attending.
    ///
    /// The pills above deliberately still key on `intent`: they show what
    /// the coach has explicitly SET, not what was resolved. Neither pill
    /// being filled is the correct rendering of "this is just their usual
    /// session" — the coach hasn't overridden anything.
    private var dotColor: Color {
        switch entry.reason {
        case .explicitIn:   return Color.accentActionDim
        case .standingSlot: return Color.accentActionDim.opacity(0.55)
        case .explicitOut:  return Color.textFaint
        case .noSignal:     return Color.textFaint
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
                .foregroundStyle(isSelected ? Color.textOnAccent : Color.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(isSelected ? color : Color.textPrimary.opacity(0.06))
                )
        }
        .buttonStyle(PressFeedbackStyle())
    }
}