import SwiftUI

/// AttendanceBreadcrumb — the V0.54 PRE-state "👤 N" pill. Non-intrusive,
/// never gates Start Session (decision 7). Tap opens a roster sheet
/// for corrections; the sheet reuses `AttendancePopoverContent` so the
/// edit vocabulary matches the V0.49 `AttendanceBadge` 1:1.
///
/// Rendered inside `SessionConsoleView`'s PRE body. Owns no state —
/// reads `attendingCount`, `totalCount`, and `fetchFailed` from the
/// caller (the VM) so the Console is the single source of truth.
///
/// Edge cases per spec §2:
///   - empty squad (total == 0, not failed) → "👤 0"
///   - all marked out → "👤 0 / N"
///   - RLS / network error → "👤 ?" + retry tap
///   - cold-start squad, no SwimmerAttendanceIntent rows → spec §2
///     says "👤 all" + a confirmation chip (Nathan's R2 ruling). S5
///     wires the cold-start multi-select; S1 renders the same
///     "👤 0 / N" until the cold-start sheet lands, which is honest
///     about not knowing.
struct AttendanceBreadcrumb: View {
    let attendingCount: Int
    let totalCount: Int
    let fetchFailed: Bool
    /// Pre-resolved entries from the VM — passed through to the
    /// roster sheet so the edit vocabulary matches the V0.49
    /// `AttendanceBadge` 1:1.
    let entries: [CoachAttendanceEntry]
    /// Provided by the VM so the breadcrumb can re-run preTickRoster.
    /// S1 wires it; S5 wires the retry button.
    let onRetry: () -> Void
    /// Provided by the VM so the breadcrumb sheet calls into
    /// `CoachIntentService.setIntent` through the same path the
    /// V0.49 AttendanceBadge popover does.
    let onSetIntent: (String, String) async -> Void

    /// Sheet presentation. Sheet (not popover) because the parent
    /// container is a `fullScreenCover` — popovers on full-screen
    /// covers misbehave in iOS 17+ and we already have a known-good
    /// `AttendancePopoverContent` body to reuse.
    @State private var showRosterSheet = false

    private var iconName: String {
        fetchFailed ? "person.crop.circle.badge.questionmark" : "person.crop.circle.fill"
    }

    private var displayText: String {
        if fetchFailed { return "?" }
        return "\(attendingCount)"
    }

    private var captionText: String {
        if fetchFailed { return "tap to retry" }
        if totalCount == 0 { return "no swimmers on squad yet" }
        if attendingCount == 0 { return "no swimmers marked attending" }
        return "/ \(totalCount) squad"
    }

    private var accent: Color {
        if fetchFailed { return Color.accentAmber }
        if totalCount == 0 { return Color.textFaint }
        if attendingCount == 0 { return Color.accentAmber }
        return Color.statusSuccess
    }

    var body: some View {
        Button {
            Haptics.selection()
            showRosterSheet = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .font(.title3)
                    .foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(displayText)
                            .font(.titleSmall)
                            .foregroundStyle(Color.textPrimary)
                        if !fetchFailed {
                            Text(captionText)
                                .font(.captionStrong)
                                .foregroundStyle(Color.textMuted)
                        }
                    }
                    if fetchFailed {
                        Text("Couldn't load attendance")
                            .font(.caption)
                            .foregroundStyle(Color.textFaint)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.eyebrow)
                    .foregroundStyle(Color.textMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.bgRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(accent.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showRosterSheet) {
            // Reuse the V0.49 popover body so the edit vocabulary
            // (row layout, three-pill toggle, provenance label) stays
            // identical to the badge the coach already knows. The
            // CoachIntentService call site is the SAME one AttendanceBadge
            // uses — kept on the VM so S5 can wire the correction-
            // feedback counter.
            RosterSheetHost(
                attendingCount: attendingCount,
                totalCount: totalCount,
                fetchFailed: fetchFailed,
                entries: entries,
                onRetry: onRetry,
                onSetIntent: onSetIntent
            )
        }
    }
}

/// RosterSheetHost — wraps the V0.49 `AttendancePopoverContent` in a
/// sheet so the Console (fullScreenCover) can present it without the
/// popover-cover iOS 17+ presentation bug. Reads its entries from the
/// VM snapshot so corrections stay coherent with the breadcrumb.
private struct RosterSheetHost: View {
    let attendingCount: Int
    let totalCount: Int
    let fetchFailed: Bool
    let entries: [CoachAttendanceEntry]
    let onRetry: () -> Void
    let onSetIntent: (String, String) async -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bgBase.ignoresSafeArea()
                AttendancePopoverContent(
                    entries: entries,
                    onSetIntent: onSetIntent
                )
            }
            .navigationTitle("Attendance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.textPrimary)
                }
            }
        }
    }
}